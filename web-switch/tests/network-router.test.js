'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const tls = require('node:tls');
const { EventEmitter, once } = require('node:events');
const { PassThrough } = require('node:stream');
const { EthernetRouter, RoutedNetworkClient } = require('../src/network-router');
const { parseLocalEndpoint } = require('../src/network-client');
const { makeTempDir, prepareCertificates, startServer, eventually } = require('./e2e/setup');
const { TestSwitchClient, ethernetFrame } = require('./e2e/client');
const own = '02:00:00:00:00:01', peerMAC = '02:00:00:00:00:02';
const outgoing = ethernetFrame(peerMAC, own, 'outgoing');
const incoming = ethernetFrame(own, peerMAC, 'incoming');

test('macOS routing policy: discovery, learning, fallback, recovery, TTL and dedup', () => {
  let now = 0;
  const router = new EthernetRouter(() => now);
  const both = () => true;
  assert.deepEqual(router.destinations(outgoing, both), ['cloud', 'local']);
  assert.equal(router.receive(incoming, 'cloud'), true);
  assert.deepEqual(router.destinations(outgoing, both), ['cloud']);
  assert.equal(router.receive(incoming, 'local'), false);
  assert.deepEqual(router.destinations(outgoing, both), ['local']);
  assert.deepEqual(router.destinations(outgoing, (r) => r === 'cloud'), ['cloud']);
  assert.deepEqual(router.destinations(outgoing, both), ['local']);
  assert.equal(router.receive(incoming, 'local'), true); // same path repeats retained
  assert.equal(router.receive(outgoing, 'cloud'), false); // no self echoes
  now = 251;
  assert.equal(router.receive(incoming, 'cloud'), true);
  now = 300252;
  assert.deepEqual(router.destinations(outgoing, both), ['cloud', 'local']);
  assert.deepEqual(router.destinations(ethernetFrame(own, own, 'self'), both), []);
});

test('discovery flood limiter and endpoint validation', () => {
  let now = 0;
  const router = new EthernetRouter(() => now);
  for (let i = 0; i < 256; i++) assert.equal(router.destinations(outgoing, () => true).length, 2);
  assert.deepEqual(router.destinations(outgoing, () => true), []);
  now = 1000;
  assert.equal(router.destinations(outgoing, () => true).length, 2);
  assert.deepEqual(parseLocalEndpoint('[::1]:9444'), { host: '::1', port: 9444 });
  for (const value of ['0.0.0.0:9444', '[::]:9444', 'host:99999', 'bad;cmd:9444', 'host:9444 extra', 'host:%i', '']) {
    assert.throws(() => parseLocalEndpoint(value));
  }
});

test('real TCP + mTLS, one TAP, local failure and automatic recovery', async (t) => {
  const root = makeTempDir();
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const certs = prepareCertificates(root);
  const server = await startServer(certs, { keepaliveTimeoutMs: 1000 });
  t.after(() => server.stop());
  const bundle = JSON.parse(fs.readFileSync(path.join(root, 'certs/host-a/okrun-switch-bundle.json')));
  bundle.server = `localhost:${server.tlsPort}`;
  const tap = new EventEmitter();
  tap.stdin = new PassThrough(); tap.stdout = new PassThrough(); tap.stderr = new PassThrough();
  tap.kill = () => { tap.exitCode = 0; tap.emit('exit', 0); };
  let spawned = 0;
  const client = new RoutedNetworkClient({ bundle, ip: '10.77.0.2/24', localServer: `127.0.0.1:${server.localPort}` }, {
    connect: (options) => tls.connect({ ...options, host: '127.0.0.1' }), retryMs: 500,
    spawn: () => { spawned++; setImmediate(() => tap.stderr.write('OKRUN_SWITCH_TAP_READY {}\n')); return tap; }
  });
  t.after(() => client.close());
  client.start();
  await eventually(() => assert.ok(client.ready && client.sessions.local.ready && client.sessions.cloud.ready));
  const local = new TestSwitchClient({ port: server.localPort, transport: 'tcp', nodeID: 'ee8b97ce-8f31-40e3-8b67-f2bb2c2662bd', interfaceName: 'local' });
  const cloud = new TestSwitchClient({ port: server.tlsPort, ...certs.hostB, nodeID: 'ee8b97ce-8f31-40e3-8b67-f2bb2c2662bd', interfaceName: 'cloud' });
  t.after(() => { local.close(); cloud.close(); });
  await local.connect(); await cloud.connect();
  const send = (frame) => {
    const header = Buffer.alloc(4); header.writeUInt32BE(frame.length);
    tap.stdout.write(Buffer.concat([header, frame]));
  };
  send(outgoing);
  assert.deepEqual((await local.waitForData()).payload, outgoing);
  assert.deepEqual((await cloud.waitForData()).payload, outgoing);
  const received = [];
  tap.stdin.on('data', (packet) => received.push(packet.subarray(4)));
  local.sendData(incoming);
  await eventually(() => assert.equal(received.length, 1));
  cloud.seqNo = local.seqNo;
  cloud.sendData(incoming);
  await new Promise((r) => setTimeout(r, 50));
  assert.equal(received.length, 1);
  // Remote frames are injected, never forwarded to the other switch.
  await cloud.expectNoData(); await local.expectNoData();
  send(outgoing);
  assert.deepEqual((await local.waitForData()).payload, outgoing);
  await cloud.expectNoData();
  const old = client.sessions.local;
  const failed = once(old, 'failure'); old.socket.destroy(); await failed;
  send(outgoing);
  assert.deepEqual((await cloud.waitForData()).payload, outgoing);
  await eventually(() => assert.ok(client.sessions.local !== old && client.sessions.local.ready), 2000);
  send(outgoing);
  assert.deepEqual((await local.waitForData()).payload, outgoing);
  await cloud.expectNoData();
  assert.equal(spawned, 1);
  assert.equal(client.ready, true);
  client.close();
  assert.equal(client.retries.size, 0);
  assert.equal(client.sessions.cloud.closed, true);
  assert.equal(tap.exitCode, 0);
});
