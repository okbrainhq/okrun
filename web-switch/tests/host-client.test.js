'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { EventEmitter, once } = require('node:events');
const { PassThrough } = require('node:stream');
const { addressCandidates, parseSubnet, hostMAC, hostReservation } = require('../src/host-address');
const { HostNetworkClient } = require('../src/host-client');
const { NetworkClient, validateConfig } = require('../src/network-client');
const { makeTempDir, prepareCertificates, startServer } = require('./e2e/setup');

const seed = '819763ab-5325-462f-a449-76f8dd6642bf';
test('automatic address planning is deterministic, private and never reserves a pool', () => {
  const addresses = addressCandidates('10.77.0.0/24', seed);
  assert.equal(addresses.length, 253);
  assert.equal(new Set(addresses).size, 253);
  assert(addresses.slice(0, 54).every((ip) => Number(ip.split('.')[3].split('/')[0]) >= 201));
  assert(!addresses.includes('10.77.0.1/24'));
  assert(!addresses.includes('10.77.0.255/24'));
  assert.deepEqual(addressCandidates('10.77.0.0/24', seed), addresses);
  assert.equal(addressCandidates('10.77.0.0/24', seed, '10.77.0.3/24')[0], '10.77.0.3/24');
  assert.equal(addressCandidates('10.77.0.0/24', seed, '172.16.0.1/24')[0], addresses[0]);
  assert.deepEqual(hostReservation('10.77.0.0/24', '10.77.0.205/24'),
    { cidr: '10.77.0.0/24', rangeStart: '10.77.0.205', rangeEnd: '10.77.0.205' });
  assert.equal(parseSubnet().cidr, '10.77.0.0/24');
  assert.equal(addressCandidates('10.77.0.0/30', seed)[0], '10.77.0.2/30');
  for (const bad of ['1.2.3.0/24', '10.77.0.1/24', '10.0.0.0/8', '10.77.0.0/31', 'x', '::1/64']) {
    assert.throws(() => parseSubnet(bad));
  }
  assert.equal(parseInt(hostMAC(seed).split(':')[0], 16) & 3, 2);
});

test('host supervisor retries conflicts, persists the successful address, and cancels retry on stop', async (t) => {
  const root = makeTempDir();
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const stateFile = path.join(root, 'state.json');
  let attempts = 0;
  const configs = [];
  class Client extends EventEmitter {
    constructor(config) { super(); this.config = config; configs.push(config); }
    start() {
      attempts++;
      setImmediate(() => {
        if (attempts === 1) this.emit('failure', Object.assign(new Error('collision'), { code: 'address_conflict' }));
        else this.emit('ready');
      });
    }
    close() {}
  }
  const config = { network: 'okrun', interface: 'nonexistent', subnet: '10.77.0.0/24', stateFile };
  const client = new HostNetworkClient(config, { Client, retryMs: 1 });
  t.after(() => client.close());
  const ready = once(client, 'ready'); client.start(); await ready;
  assert.equal(attempts, 2);
  assert.notEqual(configs[0].ip, configs[1].ip);
  assert.equal(configs[0].mac, configs[1].mac);
  assert.equal(fs.statSync(stateFile).mode & 0o777, 0o600);
  const ip = JSON.parse(fs.readFileSync(stateFile)).ip;
  client.close();
  const restart = new HostNetworkClient(config, { Client, retryMs: 1 });
  t.after(() => restart.close());
  const again = once(restart, 'ready'); restart.start(); await again;
  assert.equal(restart.config.ip, ip);
  restart.client.emit('failure', Object.assign(new Error('collision'), { code: 'dhcp_range_overlap' }));
  restart.close();
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(attempts, 3);
});

test('real mTLS admission protects active VM pools; auto retries rejected address without assigning it', async (t) => {
  const root = makeTempDir();
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const certs = prepareCertificates(root);
  const server = await startServer(certs);
  t.after(() => server.stop());
  const bundle = JSON.parse(fs.readFileSync(`${root}/certs/host-a/okrun-switch-bundle.json`));
  bundle.server = `localhost:${server.tlsPort}`;
  assert.equal(validateConfig({ bundle }).ip, 'auto');
  const blocked = '10.77.0.254/24';
  const reservation = new NetworkClient({ bundle, network: 'okrun', ip: blocked,
    dhcpRange: hostReservation('10.77.0.0/24', blocked) }, { frameOnly: true });
  t.after(() => reservation.close());
  const peerReady = once(reservation, 'ready'); reservation.start(); await peerReady;
  const stateFile = `${root}/state.json`;
  fs.writeFileSync(stateFile, JSON.stringify({ seed: crypto.randomUUID(), ip: blocked, network: 'okrun', subnet: '10.77.0.0/24' }), { mode: 0o600 });
  let tapCount = 0;
  const client = new HostNetworkClient({ bundle, network: 'okrun', interface: 'nonexistent', stateFile }, {
    retryMs: 1, spawn: (_cmd, args) => {
      tapCount++;
      assert.notEqual(args[args.indexOf('--ip') + 1], blocked);
      assert(args.includes('--probe-address'));
      const child = new EventEmitter();
      child.stdin = new PassThrough(); child.stdout = new PassThrough(); child.stderr = new PassThrough();
      child.kill = () => { child.exitCode = 0; child.emit('exit', 0); };
      setImmediate(() => child.stderr.write('OKRUN_SWITCH_TAP_READY {}\n'));
      return child;
    }
  });
  t.after(() => client.close());
  const ready = once(client, 'ready'); client.start(); await ready;
  assert.equal(tapCount, 1);
  assert.notEqual(client.config.ip, blocked);
});
