'use strict';

const crypto = require('node:crypto');
const { performance } = require('node:perf_hooks');
const { NetworkClient, parseLocalEndpoint } = require('./network-client');
const LOCAL_RECOVERY_PROBE_MS = 5000;
const LOCAL_ROUTE_FRESHNESS_MS = 5000;

// Mirrors PrivateNetworkTransportRouter: per-MAC local preference, discovery
// on both transports, cross-transport duplicate suppression, and no bridging.
class EthernetRouter {
  constructor(now = () => performance.now()) {
    this.now = now;
    this.local = new Map();
    this.remote = new Map();
    this.seen = new Map();
    this.tokens = 256;
    this.updated = now();
  }

  prune(now) {
    for (const [mac, at] of this.local) if (now - at > 300000) this.local.delete(mac);
    for (const [mac, routes] of this.remote) {
      for (const route of ['local', 'cloud']) if (now - routes[route] > 300000) delete routes[route];
      if (routes.local === undefined && routes.cloud === undefined) this.remote.delete(mac);
    }
    for (const [hash, entry] of this.seen) if (now - entry.at > 250) this.seen.delete(hash);
  }

  remember(map, key, value) {
    // Bound tables even on a hostile LAN.
    if (!map.has(key) && map.size >= 16384) map.delete(map.keys().next().value);
    map.set(key, value);
  }

  prefersLocal(entry, now) {
    // Session readiness alone cannot establish per-peer LAN reachability.
    return entry.local !== undefined && now - entry.local < LOCAL_ROUTE_FRESHNESS_MS;
  }

  destinations(frame, reachable) {
    if (frame.length < 14) return [];
    const now = this.now();
    this.prune(now);
    const source = frame.subarray(6, 12).toString('hex');
    const dest = frame.subarray(0, 6).toString('hex');
    this.remember(this.local, source, now);
    const unicast = !(frame[0] & 1);
    if (unicast && this.local.has(dest)) return [];
    const entry = unicast && this.remote.get(dest);
    if (entry) {
      const prefersLocal = this.prefersLocal(entry, now);
      const order = prefersLocal ? ['local', 'cloud'] : ['cloud', 'local'];
      const routes = order.filter((route) => reachable(route));
      if (!prefersLocal && routes.length === 2 && now - entry.localProbeAt >= LOCAL_RECOVERY_PROBE_MS) {
        entry.localProbeAt = now;
        // A bounded copy of ordinary traffic discovers recovered LAN peers.
        // Never replace the working cloud path until local traffic is observed,
        // and never let the probe flood budget drop the original cloud packet.
        if (this.allowFlood(now)) return ['local', 'cloud'];
      }
      return routes.slice(0, 1);
    }
    const routes = ['local', 'cloud'].filter((route) => reachable(route));
    return routes.length && this.allowFlood(now) ? routes : [];
  }

  allowFlood(now) {
    this.tokens = Math.min(256, this.tokens + (now - this.updated) * 64 / 1000);
    this.updated = now;
    if (this.tokens < 1) return false;
    this.tokens--;
    return true;
  }

  receive(frame, route) {
    if (frame.length < 14) return false;
    const now = this.now();
    this.prune(now);
    const source = frame.subarray(6, 12).toString('hex');
    if (this.local.has(source)) return false;
    const hash = crypto.createHash('sha256').update(frame).digest('hex');
    const previous = this.seen.get(hash);
    this.remember(this.seen, hash, { route, at: now });
    const fresh = !previous || previous.route === route || now - previous.at > 250;
    const routes = this.remote.get(source) || {};
    // Keep the probe clock independent of fresh cloud traffic, otherwise active
    // connections remain on the fallback forever after a local-switch outage.
    if (route === 'local' || routes.localProbeAt === undefined) routes.localProbeAt = now;
    routes[route] = now;
    // Distinct cloud packets and late duplicates do not disprove a local path.
    // Only stale local observations or an unavailable session trigger fallback.
    this.remember(this.remote, source, routes);
    return fresh;
  }
}

class RoutedNetworkClient extends NetworkClient {
  constructor(config, dependencies = {}) {
    super(config, dependencies);
    this.dependencies = dependencies;
    this.router = new EthernetRouter(dependencies.now);
    this.sessions = {};
    this.retries = new Map();
    this.retryMs = dependencies.retryMs ?? 5000;
  }

  start() {
    if (this.started || this.closed) return this;
    this.started = true;
    this.join('local');
    this.join('cloud');
    return this;
  }

  join(route) {
    if (this.closed) return;
    const localEndpoint = route === 'local' ? parseLocalEndpoint(this.config.localServer) : undefined;
    const session = new NetworkClient({ ...this.config, interface: route === 'local' ? 'local' : 'cloud' }, {
      frameOnly: true, localEndpoint,
      connect: route === 'local' ? this.dependencies.localConnect : this.dependencies.connect
    });
    session.nodeID = this.nodeID;
    this.sessions[route] = session;
    session.on('ready', () => {
      if (this.closed) return;
      this.emit('log', `${route} switch connected`);
      if (!this.child) {
        this.timer = setTimeout(() => this.fail(new Error('TAP startup timed out')), 15000);
        try { this.startTap(); } catch (error) { this.fail(error); }
      }
      this.emit('transport-ready', route);
    });
    session.on('frame', (frame) => {
      if ((this.ready || this.probing) && frame.length <= this.tapFrameSizeLimit && this.router.receive(frame, route)) {
        try { this.injectFrame(frame); } catch (error) { this.fail(error); }
      }
    });
    session.on('failure', (error) => {
      if (this.closed) return;
      if (error.code === 'dhcp_range_overlap' && this.config.probeAddress) return this.fail(error);
      this.emit('log', `${route} switch unavailable: ${error.message}; retrying`);
      // Readiness gates forwarding while disconnected. Retain route observations
      // across retries; per-peer freshness determines whether to revalidate.
      this.retries.set(route, setTimeout(() => {
        this.retries.delete(route);
        this.join(route);
      }, this.retryMs));
    });
    try { session.start(); } catch (error) { session.fail(error); }
  }

  sendEthernet(frame) {
    const routes = this.router.destinations(frame, (route) => this.sessions[route]?.ready);
    for (const route of routes) {
      if (this.seqNo === 0xffffffff) return this.fail(new Error('Sequence exhausted; restart required'));
      // Shared identity requires globally unique sequences, including reconnects.
      // Use distinct numbers for discovery copies so a shared switch forwards
      // each copy within its ingress transport class.
      this.sessions[route].seqNo = this.seqNo++;
      this.sessions[route].sendEthernet(frame);
    }
  }

  close() {
    if (this.closed) return;
    super.close();
    for (const timer of this.retries.values()) clearTimeout(timer);
    this.retries.clear();
    for (const session of Object.values(this.sessions)) session.close();
  }
}

module.exports = { EthernetRouter, RoutedNetworkClient };
