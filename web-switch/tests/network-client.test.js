'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { EventEmitter, once } = require('node:events');
const { PassThrough } = require('node:stream');
const { NetworkClient, validateConfig } = require('../src/network-client');
const { FrameType, encodeJsonFrame, FrameDecoder } = require('../src/protocol');
const { makeTempDir, prepareCertificates, startServer } = require('./e2e/setup');
const { TestSwitchClient, ethernetFrame } = require('./e2e/client');

function fakeTap() {
  const child = new EventEmitter();
  child.stdin = new PassThrough();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.kill = () => { child.exitCode = 0; child.emit('exit', 0); };
  return child;
}
function deadline(promise) {
  let timer;
  return Promise.race([promise, new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error('Test timed out')), 4000);
  })]).finally(() => clearTimeout(timer));
}

test('network-only client: real mTLS switch, simulated TAP boundary', async (t) => {
  const root = makeTempDir();
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const certs = prepareCertificates(root);
  const server = await startServer(certs, { keepaliveIntervalMs: 100, keepaliveTimeoutMs: 1000 });
  t.after(() => server.stop());
  const bundle = JSON.parse(fs.readFileSync(path.join(root, 'certs/host-a/okrun-switch-bundle.json')));
  bundle.server = `localhost:${server.tlsPort}`;
  // Force loopback IPv4 for the test listener while retaining hostname checks.
  const tls = require('node:tls');
  const connect = (options) => tls.connect({ ...options, host: '127.0.0.1' });
  const config = { bundle, ip: '10.77.0.2/24', network: 'okrun' };

  await t.test('configuration rejects bad credentials and unsafe inputs', () => {
    for (const patch of [{ ip: 'bad' }, { ip: '10.1.2.3/33' }, { interface: '../bad' },
      { network: 'bad network' }, { mtu: 99999 }, { bundle: { ...bundle, clientKeyPem: '' } },
      { bundle: { ...bundle, server: 'host:99999' } }, { bundle: { ...bundle, type: 'server' } }]) {
      assert.throws(() => validateConfig({ ...config, ...patch }));
    }
    assert.equal(validateConfig({ ...config, bundle: { ...bundle, server: '[::1]:9443' } }).host, '::1');
  });

  await t.test('malformed ACK, buffer limits, and helper errors fail closed', () => {
    const invalid = new NetworkClient(config);
    const frame = new FrameDecoder().push(encodeJsonFrame(FrameType.INIT, { protocol: 'wrong' }))[0];
    assert.throws(() => invalid.handleFrame(frame), /Invalid INIT/);
    const bounded = new NetworkClient(config);
    bounded.socket = { writableLength: 4194304, destroy() {}, write() { assert.fail('must not queue'); } };
    let failure;
    bounded.on('failure', (error) => { failure = error; });
    bounded.write(Buffer.alloc(1));
    assert.match(failure.message, /queue exceeded/);
    const child = fakeTap();
    const broken = new NetworkClient(config, { spawn: () => child });
    broken.on('failure', (error) => { failure = error; });
    broken.startTap();
    child.stdin.emit('error', new Error('broken pipe'));
    assert.equal(broken.closed, true);
    assert.match(failure.message, /broken pipe/);
    const small = new NetworkClient({ ...config, mtu: 1280 });
    assert.equal(small.maxFrameSize, 1500);
    assert.equal(small.tapFrameSizeLimit, 1344);
  });

  const tap = fakeTap();
  const failures = [];
  const client = new NetworkClient(config, { connect, spawn: () => {
    setImmediate(() => tap.stderr.write('OKRUN_SWITCH_TAP_READY {}\n'));
    return tap;
  } });
  client.on('failure', (error) => failures.push(error));
  t.after(() => client.close());
  const ready = once(client, 'ready');
  client.start();
  await deadline(ready);
  const peer = new TestSwitchClient({ port: server.tlsPort, ...certs.hostB });
  t.after(() => peer.close());
  await peer.connect();
  const isolated = new TestSwitchClient({ port: server.tlsPort, ...certs.hostC, networkIdentifier: 'other' });
  t.after(() => isolated.close());
  await isolated.connect();

  await t.test('bidirectional Ethernet and network isolation', async () => {
    const outgoing = ethernetFrame('ff:ff:ff:ff:ff:ff', '02:00:00:00:00:01', 'from Ubuntu');
    const header = Buffer.alloc(4); header.writeUInt32BE(outgoing.length);
    const packet = Buffer.concat([header, outgoing]);
    tap.stdout.write(packet.subarray(0, 2));
    tap.stdout.write(packet.subarray(2, 10));
    tap.stdout.write(packet.subarray(10));
    assert.deepEqual((await peer.waitForData()).payload, outgoing);
    await isolated.expectNoData();
    const incoming = ethernetFrame('02:00:00:00:00:01', '02:00:00:00:00:02', 'from VM');
    const received = once(tap.stdin, 'data');
    peer.sendData(incoming);
    const [bytes] = await deadline(received);
    assert.equal(bytes.readUInt32BE(0), incoming.length);
    assert.deepEqual(bytes.subarray(4), incoming);
  });

  await t.test('responds to keepalives and stops on disconnect', async () => {
    await new Promise((resolve) => setTimeout(resolve, 1200));
    assert.equal(client.ready, true);
    assert.equal(failures.length, 0);
    const failed = once(client, 'failure');
    client.socket.destroy();
    await deadline(failed);
    assert.equal(client.closed, true);
    assert.equal(tap.exitCode, 0);
  });

  await t.test('fresh connection rejoins after disconnect', async () => {
    const child = fakeTap();
    const retry = new NetworkClient(config, { connect, spawn: () => {
      setImmediate(() => child.stderr.write('OKRUN_SWITCH_TAP_READY {}\n'));
      return child;
    } });
    t.after(() => retry.close());
    const readyAgain = once(retry, 'ready');
    retry.start();
    await deadline(readyAgain);
    assert.notEqual(retry.nodeID, client.nodeID);
    const failed = once(retry, 'failure');
    child.stdout.write(Buffer.from([0, 2, 0, 0]));
    await deadline(failed);
    assert.equal(retry.closed, true);
  });

  await t.test('revoked certificate never starts TAP', async () => {
    const revoked = JSON.parse(fs.readFileSync(path.join(root, 'certs/revoked-host/okrun-switch-bundle.json')));
    revoked.server = bundle.server;
    let spawned = false;
    const rejected = new NetworkClient({ ...config, bundle: revoked }, { connect, spawn: () => { spawned = true; return fakeTap(); } });
    t.after(() => rejected.close());
    const failed = once(rejected, 'failure');
    rejected.start();
    await deadline(failed);
    assert.equal(spawned, false);
  });

  await t.test('wrong server hostname fails TLS verification', async () => {
    const rejected = new NetworkClient({ ...config, bundle: { ...bundle, server: `wrong.invalid:${server.tlsPort}` } }, { connect });
    t.after(() => rejected.close());
    const failed = once(rejected, 'failure');
    rejected.start();
    const [error] = await deadline(failed);
    assert.match(error.message, /Hostname\/IP does not match/);
  });
});
