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

test('fresh cloud traffic relearns the return path when only the peer loses local', () => {
  let now = 0;
  const router = new EthernetRouter(() => now);
  const both = () => true;
  const otherMAC = '02:00:00:00:00:03';
  router.receive(incoming, 'local');
  router.receive(ethernetFrame(own, otherMAC, 'other peer'), 'local');
  assert.deepEqual(router.destinations(outgoing, both), ['local']);
  now = 1000;
  assert.equal(router.receive(incoming, 'cloud'), true);
  assert.deepEqual(router.destinations(outgoing, both), ['cloud']);
  assert.deepEqual(router.destinations(ethernetFrame(otherMAC, own, 'unaffected'), both), ['local']);
  assert.deepEqual(router.destinations(outgoing, (r) => r === 'local'), ['local']);
  now = 2000;
  router.receive(incoming, 'local');
  assert.deepEqual(router.destinations(outgoing, both), ['local']);
  // ARP/broadcast discovery must relearn the return path too. This packet is
  // distinct, so it need not wait for a route TTL or dedup timer to expire.
  router.receive(ethernetFrame('ff:ff:ff:ff:ff:ff', peerMAC, 'ARP discovery'), 'cloud');
  assert.deepEqual(router.destinations(outgoing, both), ['cloud']);
});

test('duplicate discovery preserves local preference in either arrival order', () => {
  for (const order of [['local', 'cloud'], ['cloud', 'local']]) {
    let now = 0;
    const router = new EthernetRouter(() => now);
    const discovery = ethernetFrame('ff:ff:ff:ff:ff:ff', peerMAC, 'discovery');
    assert.equal(router.receive(discovery, order[0]), true);
    now = 200;
    assert.equal(router.receive(discovery, order[1]), false);
    assert.deepEqual(router.destinations(outgoing, () => true), ['local']);
  }
});

test('active unicast fails back without fresh discovery after either end recovers', () => {
  for (const asymmetric of [false, true]) {
    for (const localCopyFirst of [false, true]) {
      let now = 0;
      const a = new EthernetRouter(() => now), b = new EthernetRouter(() => now);
      let aLocal = true, bLocal = true;
      const sent = { a: [], b: [] }, delivered = { a: 0, b: 0 };
      let exchanges = 0;
      const transmit = (router, receiver, name, frame, reachable) => {
        const routes = router.destinations(frame, reachable);
        sent[name].push(routes);
        const preferred = localCopyFirst ? 'local' : 'cloud';
        for (const route of [...routes].sort((x, y) => (y === preferred) - (x === preferred))) {
          if (route === 'cloud' || (aLocal && bLocal)) {
            if (receiver.receive(frame, route)) delivered[name === 'a' ? 'b' : 'a']++;
          }
        }
      };
      const exchange = () => {
        exchanges++;
        transmit(b, a, 'b', ethernetFrame(own, peerMAC, `request ${exchanges}`), (r) => r === 'cloud' || bLocal);
        transmit(a, b, 'a', ethernetFrame(peerMAC, own, `reply ${exchanges}`), (r) => r === 'cloud' || aLocal);
      };
      exchange(); exchange();
      assert.deepEqual(sent.a.at(-1), ['local']);
      assert.deepEqual(sent.b.at(-1), ['local']);
      for (let cycle = 0; cycle < 2; cycle++) {
        bLocal = false; aLocal = asymmetric;
        for (let i = 0; i < 10; i++) { now += 1000; exchange(); }
        assert.ok(sent.a.at(-1).includes('cloud'));
        assert.deepEqual(sent.b.at(-1), ['cloud']);
        aLocal = bLocal = true;
        for (let i = 0; i < 5; i++) { now += 1000; exchange(); }
        exchange();
        assert.deepEqual(sent.a.at(-1), ['local']);
        assert.deepEqual(sent.b.at(-1), ['local']);
      }
      assert.deepEqual(delivered, { a: exchanges, b: exchanges }); // no duplicate delivery
    }
  }
});

test('web-only peers retain delivery; local probes are per-peer and not postponed by fresh cloud traffic', () => {
  let now = 0;
  const router = new EthernetRouter(() => now);
  let probes = 0;
  for (let tick = 0; tick <= 100; tick++) {
    now = tick * 100;
    router.receive(ethernetFrame(own, peerMAC, `fresh ${tick}`), 'cloud');
    const routes = router.destinations(outgoing, () => true);
    assert.ok(routes.includes('cloud'));
    if (routes.includes('local')) probes++;
  }
  assert.equal(probes, 2);
  assert.deepEqual(router.destinations(outgoing, () => true), ['cloud']);

  const other = '02:00:00:00:00:03';
  router.receive(ethernetFrame(own, other, 'other peer'), 'cloud');
  now += 5000;
  assert.deepEqual(router.destinations(outgoing, (r) => r === 'cloud'), ['cloud']);
  // An unavailable local transport must not consume this peer's next probe.
  assert.deepEqual(router.destinations(outgoing, () => true), ['local', 'cloud']);
  assert.deepEqual(router.destinations(ethernetFrame(other, own, 'reply'), () => true), ['local', 'cloud']);
  assert.deepEqual(router.destinations(outgoing, () => true), ['cloud']);
  now += 300001;
  router.prune(now);
  assert.equal(router.remote.size, 0); // probe metadata must not keep stale routes alive
});

test('local probe flood limiting never drops known web traffic', () => {
  let now = 0;
  const router = new EthernetRouter(() => now);
  for (const mac of [peerMAC, '02:00:00:00:00:03']) {
    router.receive(ethernetFrame(own, mac, 'learn'), 'cloud');
  }
  now = 5000;
  router.tokens = 1;
  router.updated = now;
  assert.deepEqual(router.destinations(outgoing, () => true), ['local', 'cloud']);
  assert.deepEqual(router.destinations(ethernetFrame('02:00:00:00:00:03', own, 'reply'), () => true), ['cloud']);
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
  let spawned = 0, now = 0;
  const client = new RoutedNetworkClient({ bundle, ip: '10.77.0.2/24', localServer: `127.0.0.1:${server.localPort}` }, {
    connect: (options) => tls.connect({ ...options, host: '127.0.0.1' }), retryMs: 500, now: () => now,
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
  now += 1000;
  const fallbackReply = ethernetFrame(own, peerMAC, 'reply while local is down');
  cloud.sendData(fallbackReply);
  await eventually(() => assert.deepEqual(received[1], fallbackReply));
  await eventually(() => assert.ok(client.sessions.local !== old && client.sessions.local.ready), 2000);
  // Both peers have now learned the web path, rather than retaining a local
  // route from before the outage. A normal send must rediscover the LAN itself.
  now += 5000;
  send(outgoing);
  assert.deepEqual((await local.waitForData()).payload, outgoing);
  assert.deepEqual((await cloud.waitForData()).payload, outgoing); // keep backup delivery during probe
  local.seqNo = cloud.seqNo;
  const localReply = ethernetFrame(own, peerMAC, 'reply to recovery probe');
  local.sendData(localReply);
  await eventually(() => assert.deepEqual(received[2], localReply));
  send(outgoing);
  assert.deepEqual((await local.waitForData()).payload, outgoing);
  await cloud.expectNoData();
  // Asymmetric failure: the peer disconnects from the LAN, but this Ubuntu
  // host's local socket stays ready. Replies must follow new cloud observations.
  const healthyLocal = client.sessions.local;
  local.close();
  now += 1000;
  const moved = ethernetFrame(own, peerMAC, 'peer lost LAN');
  cloud.seqNo = local.seqNo;
  cloud.sendData(moved);
  await eventually(() => assert.deepEqual(received[3], moved));
  send(outgoing);
  assert.deepEqual((await cloud.waitForData()).payload, outgoing);
  assert.equal(healthyLocal.ready, true);
  assert.equal(client.sessions.local, healthyLocal);

  const recoveredLocal = new TestSwitchClient({
    port: server.localPort, transport: 'tcp', nodeID: cloud.nodeID, interfaceName: 'local'
  });
  t.after(() => recoveredLocal.close());
  await recoveredLocal.connect();
  now += 5000;
  send(outgoing); // recovery is initiated by the router, not unsolicited local traffic
  assert.deepEqual((await recoveredLocal.waitForData()).payload, outgoing);
  assert.deepEqual((await cloud.waitForData()).payload, outgoing);
  recoveredLocal.seqNo = cloud.seqNo;
  const restored = ethernetFrame(own, peerMAC, 'peer LAN restored');
  recoveredLocal.sendData(restored);
  await eventually(() => assert.deepEqual(received[4], restored));
  send(outgoing);
  assert.deepEqual((await recoveredLocal.waitForData()).payload, outgoing);
  await cloud.expectNoData();
  assert.equal(spawned, 1);
  assert.equal(client.ready, true);
  client.close();
  assert.equal(client.retries.size, 0);
  assert.equal(client.sessions.cloud.closed, true);
  assert.equal(tap.exitCode, 0);
});
