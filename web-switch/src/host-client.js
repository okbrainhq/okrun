'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { EventEmitter } = require('node:events');
const { NetworkClient } = require('./network-client');
const { RoutedNetworkClient } = require('./network-router');
const { parseSubnet, addressCandidates, hostMAC, hostReservation } = require('./host-address');

// Joins the host's own IP stack to the fabric. Not a DHCP server or a LAN bridge.
// Only one address is reserved using the existing switch admission mechanism.
class HostNetworkClient extends EventEmitter {
  constructor(config, dependencies = {}) {
    super();
    this.config = { ...config, subnet: parseSubnet(config.subnet).cidr };
    this.dependencies = dependencies;
    this.closed = false;
    this.ready = false;
  }

  start() {
    if (this.started || this.closed) return this;
    this.started = true;
    try {
      const c = this.config;
      let state = {};
      if (c.stateFile && fs.existsSync(c.stateFile)) {
        const stat = fs.lstatSync(c.stateFile);
        if (!stat.isFile() || (stat.mode & 0o077)) throw new Error('Host state must be a private regular file');
        state = JSON.parse(fs.readFileSync(c.stateFile, 'utf8'));
      }
      const seed = typeof state.seed === 'string' && /^[0-9a-f-]{36}$/.test(state.seed) ? state.seed : crypto.randomUUID();
      this.state = { version: 1, network: c.network, subnet: c.subnet, seed };
      this.candidates = addressCandidates(c.subnet, seed,
        state.network === c.network && state.subnet === c.subnet ? state.ip : undefined);
      // Save identity before trying an address, so a process crash keeps its MAC.
      this.save();
      this.attempt();
    } catch (error) { this.fail(error); }
    return this;
  }

  save() {
    if (!this.config.stateFile) return;
    fs.mkdirSync(path.dirname(this.config.stateFile), { recursive: true, mode: 0o700 });
    const tmp = `${this.config.stateFile}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(this.state) + '\n', { mode: 0o600 });
    fs.renameSync(tmp, this.config.stateFile);
  }

  attempt() {
    if (this.closed) return;
    // Never attach to another process's TAP, including a helper still exiting.
    if (fs.existsSync(`/sys/class/net/${this.config.interface}`)) {
      return this.fail(new Error(`Interface ${this.config.interface} still exists; refusing to reuse it`));
    }
    const ip = this.candidates.shift();
    if (!ip) return this.fail(new Error('No conflict-free host address available in configured VM subnet'));
    this.config.ip = ip;
    this.ready = false;
    const config = { ...this.config, probeAddress: true, mac: hostMAC(this.state.seed),
      dhcpRange: hostReservation(this.config.subnet, ip) };
    const Client = this.dependencies.Client ?? (config.localServer ? RoutedNetworkClient : NetworkClient);
    const client = this.client = new Client(config, this.dependencies);
    client.on('log', (line) => this.emit('log', line));
    client.on('ready', () => {
      if (this.closed) return;
      try {
        this.state.ip = ip;
        this.save();
        this.ready = true;
        this.emit('ready');
      } catch (error) { this.fail(error); }
    });
    client.on('failure', (error) => {
      if (this.closed) return;
      this.ready = false;
      if (['dhcp_range_overlap', 'address_conflict'].includes(error.code)) {
        this.emit('log', `Host address ${ip} conflicts; automatically trying another`);
        delete this.state.ip;
        try { this.save(); } catch (saveError) { return this.fail(saveError); }
        this.conflicts = (this.conflicts ?? 0) + 1;
        // Allow old helper to exit and reservations to clear; throttle repeated conflicts.
        this.timer = setTimeout(() => {
          try { this.attempt(); } catch (nextError) { this.fail(nextError); }
        }, this.conflicts >= 10 ? 60000 : (this.dependencies.retryMs ?? 2000));
      } else this.fail(error);
    });
    this.emit('log', `Joining host with automatic address on ${this.config.subnet}`);
    try { client.start(); } catch (error) { this.fail(error); }
  }

  fail(error) {
    if (this.closed) return;
    this.close();
    this.emit('failure', error);
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    this.ready = false;
    clearTimeout(this.timer);
    this.client?.close();
  }
}

module.exports = { HostNetworkClient };
