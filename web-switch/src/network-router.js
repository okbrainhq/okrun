'use strict';

const crypto = require('node:crypto');
const { performance } = require('node:perf_hooks');
const { NetworkClient, parseLocalEndpoint } = require('./network-client');

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
      for (const route of Object.keys(routes)) if (now - routes[route] > 300000) delete routes[route];
      if (!Object.keys(routes).length) this.remote.delete(mac);
    }
    for (const [hash, entry] of this.seen) if (now - entry.at > 250) this.seen.delete(hash);
  }

  remember(map, key, value) {
    // Bound tables even on a hostile LAN.
    if (!map.has(key) && map.size >= 16384) map.delete(map.keys().next().value);
    map.set(key, value);
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
      const order = entry.local !== undefined ? ['local', 'cloud'] : ['cloud', 'local'];
      return order.filter((route) => reachable(route)).slice(0, 1);
    }
    const routes = ['cloud', 'local'].filter((route) => reachable(route));
    if (!routes.length) return [];
    this.tokens = Math.min(256, this.tokens + (now - this.updated) * 64 / 1000);
    this.updated = now;
    if (this.tokens < 1) return [];
    this.tokens--;
    return routes;
  }

  receive(frame, route) {
    if (frame.length < 14) return false;
    const now = this.now();
    this.prune(now);
    const source = frame.subarray(6, 12).toString('hex');
    if (this.local.has(source)) return false;
    const routes = this.remote.get(source) || {};
    routes[route] = now;
    this.remember(this.remote, source, routes);
    const hash = crypto.createHash('sha256').update(frame).digest('hex');
    const previous = this.seen.get(hash);
    this.remember(this.seen, hash, { route, at: now });
    return !previous || previous.route === route || now - previous.at > 250;
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
      if (this.ready && frame.length <= this.tapFrameSizeLimit && this.router.receive(frame, route)) {
        try { this.injectFrame(frame); } catch (error) { this.fail(error); }
      }
    });
    session.on('failure', (error) => {
      if (this.closed) return;
      this.emit('log', `${route} switch unavailable: ${error.message}; retrying`);
      // Keep learned routes until TTL, so recovery automatically restores local
      // preference; readiness gates forwarding while a transport is disconnected.
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
