#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const dgram = require('node:dgram');
const fs = require('node:fs');

const {
  eventually,
  makeTempDir,
  prepareCertificates,
  sleep,
  startServer
} = require('./setup');
const {
  LogicalHost,
  TestSwitchClient,
  ethernetFrame,
  expectTlsRejected,
  parseErrorFrame
} = require('./client');
const {
  DEFAULT_MAX_FRAME_SIZE,
  ETHERNET_STREAM_ID,
  FrameType,
  encodeFrame,
  encodeJsonFrame
} = require('../../src/protocol');
const { buildConfig } = require('../../src/index');
const { SwitchFabric } = require('../../src/switch-fabric');
const { SwitchConnection } = require('../../src/tls-server');
const {
  SwitchUDPDataPlane,
  UdpPacketType,
  deriveUDPKeys,
  encodeUDPHeader,
  encryptPacket,
  parseUDPPacket,
  decryptPacket
} = require('../../src/udp-data-plane');

const tests = [];
let testCounter = 0;

function test(name, fn) {
  tests.push({ name, fn });
}

function networkName(label) {
  testCounter += 1;
  return `${label}-${testCounter}`;
}

function client(server, certs, certName, options = {}) {
  const identity = certs[certName];
  return new TestSwitchClient({
    name: options.name ?? certName,
    port: server.tlsPort,
    cert: identity.cert,
    key: identity.key,
    ca: certs.caCert,
    ...options
  });
}

function localClient(server, options = {}) {
  return new TestSwitchClient({
    name: options.name ?? 'local-client',
    port: server.localPort,
    transport: 'tcp',
    ...options
  });
}

function dhcp(start, end, cidr = '10.77.0.0/24') {
  return {
    cidr,
    rangeStart: start,
    rangeEnd: end
  };
}

function memberUpdatePredicate({ networkMemberCount, localMemberCount }) {
  return (candidate) => {
    if (candidate.type !== FrameType.MEMBER_UPDATE) {
      return false;
    }

    const update = JSON.parse(candidate.payload.toString('utf8'));
    return update.networkMemberCount === networkMemberCount
      && update.localMemberCount === localMemberCount;
  };
}

function parseMemberUpdate(frame) {
  return JSON.parse(frame.payload.toString('utf8'));
}

function mockFabricConnection(name, kind = 'tls') {
  return {
    name,
    identity: {
      clientSerial: name,
      clientFingerprint: '',
      kind
    },
    sent: [],
    writeEncodedFrame(encoded) {
      this.sent.push(encoded);
      return true;
    },
    closeWithError(error) {
      this.closedWithError = error;
    }
  };
}

function admitFabricHost(fabric, connection, { networkIdentifier, nodeID, interfaceName = 'default' }) {
  fabric.admitConnection({
    protocol: 'okrun-switch/1',
    nodeID,
    networkIdentifier,
    interface: interfaceName,
    maxFrameSize: DEFAULT_MAX_FRAME_SIZE
  }, connection.identity, connection);
}

async function closeAll(clients) {
  for (const current of clients) {
    current.close();
  }
  await sleep(50);
}

class TestUDPDataPlane {
  constructor(tcpClient, dataPlane) {
    this.tcpClient = tcpClient;
    this.dataPlane = dataPlane;
    this.sessionId = Buffer.from(dataPlane.sessionId, 'base64url');
    this.keyId = dataPlane.keyId;
    this.nextPacketNumber = 1n;
    this.socket = dgram.createSocket('udp4');
    this.messages = [];
    this.waiters = [];
    this.keys = deriveUDPKeys({
      clientRandom: Buffer.from(tcpClient.clientRandom, 'base64url'),
      serverRandom: Buffer.from(dataPlane.serverRandom, 'base64url'),
      sessionId: this.sessionId,
      keyId: dataPlane.keyId,
      clientIdentity: dataPlane.clientIdentity,
      serverIdentity: dataPlane.serverIdentity
    });
    this.socket.on('message', (message) => this.handleMessage(message));
  }

  bind() {
    return new Promise((resolve, reject) => {
      this.socket.once('error', reject);
      this.socket.bind(0, '127.0.0.1', () => {
        this.socket.off('error', reject);
        resolve();
      });
    });
  }

  close() {
    this.socket.close();
  }

  handleMessage(message) {
    const parsed = parseUDPPacket(message);
    assert.ok(parsed, 'expected a valid UDP data-plane packet');
    const plaintext = decryptPacket(parsed, this.keys.s2c);
    const decoded = { parsed, plaintext };
    for (let index = 0; index < this.waiters.length; index += 1) {
      const waiter = this.waiters[index];
      if (waiter.predicate(decoded)) {
        this.waiters.splice(index, 1);
        clearTimeout(waiter.timer);
        waiter.resolve(decoded);
        return;
      }
    }
    this.messages.push(decoded);
  }

  waitFor(predicate, timeoutMs = 1000, label = 'UDP packet') {
    for (let index = 0; index < this.messages.length; index += 1) {
      const message = this.messages[index];
      if (predicate(message)) {
        this.messages.splice(index, 1);
        return Promise.resolve(message);
      }
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`Timed out waiting for ${label}`)), timeoutMs);
      this.waiters.push({ predicate, resolve, reject, timer });
    });
  }

  send(type, plaintext, fragment = {}) {
    const packetNumber = this.nextPacketNumber;
    this.nextPacketNumber += 1n;
    const header = encodeUDPHeader({
      type,
      keyId: this.keyId,
      sessionId: this.sessionId,
      packetNumber,
      fragmentId: fragment.fragmentId ?? 0,
      fragmentIndex: fragment.fragmentIndex ?? 0,
      fragmentCount: fragment.fragmentCount ?? 0
    });
    const encrypted = encryptPacket(header, plaintext, this.keys.c2s, packetNumber);
    const packet = Buffer.concat([header, encrypted.ciphertext, encrypted.authTag]);
    this.socket.send(packet, this.dataPlane.udpPort, '127.0.0.1');
    return packet;
  }

  async probe() {
    this.send(UdpPacketType.PROBE, crypto.randomBytes(8));
    await this.waitFor(
      ({ parsed }) => parsed.type === UdpPacketType.PROBE_ACK,
      1000,
      'UDP PROBE_ACK'
    );
  }

  sendData(payload, seqNo = 1) {
    const plaintext = Buffer.alloc(4 + payload.length);
    plaintext.writeUInt32BE(seqNo >>> 0, 0);
    payload.copy(plaintext, 4);
    this.send(UdpPacketType.DATA, plaintext);
  }
}

test('valid mTLS client can INIT and join', async ({ server, certs }) => {
  const a = client(server, certs, 'hostA', {
    networkIdentifier: networkName('valid-init')
  });

  try {
    const ack = await a.connect();
    assert.equal(ack.protocol, 'okrun-switch/1');
    assert.equal(ack.maxFrameSize, 70000);
    assert.equal(ack.networkMemberCount, 1);
    assert.equal(ack.localMemberCount, 0);

    const status = await server.status();
    assert.equal(status.hostCount, 1);
    assert.equal(status.connectionCount, 1);
  } finally {
    await closeAll([a]);
  }
});

test('local-only switch defaults to loopback host', async () => {
  const config = buildConfig(['--tls-enabled', 'false', '--local-port', '9444'], {});
  assert.equal(config.host, '127.0.0.1');
  assert.equal(config.tlsEnabled, false);
  assert.equal(config.localPort, 9444);
});

test('web switch default host remains public-listener friendly', async () => {
  const config = buildConfig([], {});
  assert.equal(config.host, '0.0.0.0');
  assert.equal(config.tlsEnabled, true);
});

test('TLS Web Switch enables UDP transport by default', async () => {
  const config = buildConfig([], {});
  assert.equal(config.udpEnabled, true);
  assert.equal(config.udpPort, config.tlsPort);
  assert.equal(config.udpMtu, 1200);
  assert.equal(config.udpInitialMbps, 10);
});

test('local-only switch does not enable UDP data plane by default', async () => {
  const config = buildConfig(['--tls-enabled', 'false', '--local-port', '9444'], {});
  assert.equal(config.udpEnabled, false);
});

test('UDP sessions are not negotiated until the UDP socket is bound', async () => {
  const dataPlane = new SwitchUDPDataPlane({
    enabled: true,
    host: '127.0.0.1',
    port: 0,
    logger: { log() {} },
    serverIdentity: 'test-server'
  });
  const connection = {
    identity: {
      kind: 'tls',
      clientSerial: 'test-client',
      clientFingerprint: 'test-client-fingerprint'
    },
    nodeID: 'test-node'
  };
  const initPayload = {
    capabilities: ['ethernet-frame', 'udp-data-v1'],
    transportPreference: 'udp',
    clientRandom: crypto.randomBytes(32).toString('base64url')
  };
  const listening = new Promise((resolve, reject) => {
    dataPlane.listen((error) => (error ? reject(error) : resolve()));
  });

  assert.equal(dataPlane.createSession(connection, initPayload), null);
  await listening;
  const session = dataPlane.createSession(connection, initPayload);
  assert.ok(session);
  await new Promise((resolve) => dataPlane.close(resolve));
});

test('UDP-capable clients negotiate, probe, and exchange encrypted DATA', async ({ certs }) => {
  const udpServer = await startServer(certs);
  const net = networkName('udp-data');
  const a = client(udpServer, certs, 'hostA', {
    name: 'udp-a',
    networkIdentifier: net,
    udpPreference: 'auto'
  });
  const b = client(udpServer, certs, 'hostB', {
    name: 'udp-b',
    networkIdentifier: net
  });
  let udp = null;

  try {
    const ack = await a.connect();
    assert.equal(ack.dataPlane.selected, 'udp');
    assert.equal(ack.dataPlane.cipher, 'aes-256-gcm');
    assert.equal(ack.dataPlane.mtu, 1200);
    await b.connect();

    udp = new TestUDPDataPlane(a, ack.dataPlane);
    await udp.bind();
    await udp.probe();

    const fromA = ethernetFrame('ff:ff:ff:ff:ff:ff', '02:00:00:00:71:01', 'hello-over-udp');
    udp.sendData(fromA, 101);
    assert.deepEqual((await b.waitForData()).payload, fromA);

    const fromB = ethernetFrame('ff:ff:ff:ff:ff:ff', '02:00:00:00:71:02', 'server-to-udp-client');
    b.sendData(fromB);
    const udpData = await udp.waitFor(
      ({ parsed }) => parsed.type === UdpPacketType.DATA,
      1000,
      'server UDP DATA'
    );
    assert.deepEqual(udpData.plaintext.subarray(4), fromB);
  } finally {
    if (udp) {
      udp.close();
    }
    await closeAll([a, b]);
    await udpServer.stop();
  }
});

test('PMTU probes are ignored in fixed-MTU v1', async ({ certs }) => {
  const udpServer = await startServer(certs);
  const a = client(udpServer, certs, 'hostA', {
    name: 'pmtu-v1-a',
    networkIdentifier: networkName('pmtu-v1'),
    udpPreference: 'auto'
  });
  let udp = null;

  try {
    const ack = await a.connect();
    assert.equal(ack.dataPlane.selected, 'udp');
    udp = new TestUDPDataPlane(a, ack.dataPlane);
    await udp.bind();
    await udp.probe();

    udp.send(UdpPacketType.PMTU_PROBE, Buffer.from('pmtu-disabled'));
    await assert.rejects(
      () => udp.waitFor(
        ({ parsed }) => parsed.type === UdpPacketType.PMTU_PROBE_ACK,
        150,
        'PMTU_PROBE_ACK'
      ),
      /Timed out waiting/
    );

    await eventually(async () => {
      const status = await udpServer.status();
      assert.equal(status.udp.counters.pmtuProbeFailure, 1);
    });
  } finally {
    if (udp) {
      udp.close();
    }
    await closeAll([a]);
    await udpServer.stop();
  }
});

test('UDP-only clients do not receive TCP DATA fallback before UDP probe succeeds', async ({ certs }) => {
  const udpServer = await startServer(certs);
  const net = networkName('udp-only-no-tcp');
  const a = client(udpServer, certs, 'hostA', {
    name: 'udp-only-a',
    networkIdentifier: net,
    udpPreference: 'udp'
  });
  const b = client(udpServer, certs, 'hostB', {
    name: 'tcp-b',
    networkIdentifier: net
  });

  try {
    const ack = await a.connect();
    assert.equal(ack.dataPlane.selected, 'udp');
    await b.connect();

    b.sendData(ethernetFrame('ff:ff:ff:ff:ff:ff', '02:00:00:00:72:01', 'must-not-leak-to-tcp'));
    await a.expectNoData(200);
  } finally {
    await closeAll([a, b]);
    await udpServer.stop();
  }
});

test('UDP-only clients are closed if they send TCP DATA', async ({ certs }) => {
  const udpServer = await startServer(certs);
  const net = networkName('udp-only-tcp-data-rejected');
  const a = client(udpServer, certs, 'hostA', {
    name: 'udp-only-tcp-sender',
    networkIdentifier: net,
    udpPreference: 'udp'
  });
  const b = client(udpServer, certs, 'hostB', {
    name: 'tcp-receiver',
    networkIdentifier: net
  });

  try {
    const ack = await a.connect();
    assert.equal(ack.dataPlane.selected, 'udp');
    await b.connect();

    a.sendData(ethernetFrame('ff:ff:ff:ff:ff:ff', '02:00:00:00:72:02', 'must-not-send-over-tcp'));
    const error = parseErrorFrame(await a.waitForFrame(
      (candidate) => candidate.type === FrameType.ERROR,
      1000,
      'UDP-only TCP DATA ERROR'
    ));
    assert.equal(error.code, 'tcp_data_forbidden');
    await a.waitForClose();
    await b.expectNoData(200);
  } finally {
    await closeAll([a, b]);
    await udpServer.stop();
  }
});

test('UDP-only clients are rejected when the server data plane is unavailable', async ({ certs }) => {
  const tcpOnlyServer = await startServer(certs, { udpEnabled: false });
  const a = client(tcpOnlyServer, certs, 'hostA', {
    name: 'udp-only-rejected',
    networkIdentifier: networkName('udp-only-rejected'),
    udpPreference: 'udp'
  });

  try {
    await assert.rejects(() => a.connect(), /closed while waiting|Timed out waiting/);
  } finally {
    await closeAll([a]);
    await tcpOnlyServer.stop();
  }
});

test('old clients keep TCP/TLS behavior when UDP server is enabled by default', async ({ certs }) => {
  const udpServer = await startServer(certs);
  const a = client(udpServer, certs, 'hostA', {
    networkIdentifier: networkName('udp-old-client')
  });

  try {
    const ack = await a.connect();
    assert.equal(ack.dataPlane, undefined);
    const status = await udpServer.status();
    assert.equal(status.udp.enabled, true);
    assert.equal(status.udp.activeSessions, 0);
  } finally {
    await closeAll([a]);
    await udpServer.stop();
  }
});

test('fabric rate-limits broadcast storms per host', async () => {
  let now = 1_000;
  const fabric = new SwitchFabric({
    now: () => now,
    rateLimitFramesPerSecond: 0,
    rateLimitBytesPerSecond: 0,
    rateLimitBroadcastFramesPerSecond: 2,
    rateLimitMulticastFramesPerSecond: 0,
    rateLimitUnknownUnicastFramesPerSecond: 0
  });
  const net = networkName('broadcast-rate-limit');
  const a = mockFabricConnection('rate-a');
  const b = mockFabricConnection('rate-b');
  admitFabricHost(fabric, a, {
    networkIdentifier: net,
    nodeID: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
  });
  admitFabricHost(fabric, b, {
    networkIdentifier: net,
    nodeID: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
  });

  const frame = ethernetFrame('ff:ff:ff:ff:ff:ff', '02:00:00:00:55:01', 'storm');
  assert.equal(fabric.handleData(a, {
    streamId: ETHERNET_STREAM_ID,
    type: FrameType.DATA,
    seqNo: 1,
    payload: frame
  }).forwarded, 1);
  assert.equal(fabric.handleData(a, {
    streamId: ETHERNET_STREAM_ID,
    type: FrameType.DATA,
    seqNo: 2,
    payload: frame
  }).forwarded, 1);

  const dropped = fabric.handleData(a, {
    streamId: ETHERNET_STREAM_ID,
    type: FrameType.DATA,
    seqNo: 3,
    payload: frame
  });
  assert.equal(dropped.dropped, true);
  assert.equal(dropped.dropReason, 'rate_limit_broadcast');
  assert.equal(b.sent.length, 2);

  const status = fabric.status();
  const host = status.networks[0].hosts.find((candidate) => candidate.nodeID === a.nodeID);
  assert.equal(host.droppedFrames, 1);
  assert.equal(host.dropReasons.rate_limit_broadcast, 1);

  now += 1_001;
  const afterWindow = fabric.handleData(a, {
    streamId: ETHERNET_STREAM_ID,
    type: FrameType.DATA,
    seqNo: 4,
    payload: frame
  });
  assert.equal(afterWindow.dropped, false);
  assert.equal(afterWindow.forwarded, 1);
});

test('switch connection bounds pending writes while backpressured', async () => {
  const logs = [];
  const socket = new (require('node:events').EventEmitter)();
  socket.destroyed = false;
  socket.writable = true;
  socket.writes = [];
  socket.acceptWrites = false;
  socket.write = (encoded) => {
    socket.writes.push(encoded);
    return socket.acceptWrites;
  };
  socket.end = () => {};

  const connection = new SwitchConnection({
    socket,
    identity: {
      clientSerial: 'backpressure-client',
      clientFingerprint: '',
      kind: 'tls'
    },
    fabric: null,
    options: {
      initTimeoutMs: 1000,
      keepaliveIntervalMs: 1000,
      keepaliveTimeoutMs: 2000,
      maxFrameSize: DEFAULT_MAX_FRAME_SIZE,
      maxPendingWrites: 1,
      maxPendingBytes: 1024
    },
    logger: {
      log(line) {
        logs.push(JSON.parse(line));
      }
    }
  });

  assert.equal(connection.writeEncodedFrame(Buffer.alloc(10)), true);
  assert.equal(connection.writeEncodedFrame(Buffer.alloc(10)), true);
  assert.equal(connection.writeEncodedFrame(Buffer.alloc(10)), false);
  assert.equal(logs.some((entry) => entry.event === 'drop' && entry.code === 'pending_write_count_limit'), true);

  socket.acceptWrites = true;
  socket.emit('drain');
  assert.equal(socket.writes.length, 2);
});

test('local switch client can INIT without TLS credentials', async ({ server }) => {
  const a = localClient(server, {
    networkIdentifier: networkName('local-init')
  });

  try {
    const ack = await a.connect();
    assert.equal(ack.protocol, 'okrun-switch/1');
    assert.equal(ack.maxFrameSize, 70000);
    assert.equal(ack.networkMemberCount, 1);
    assert.equal(ack.localMemberCount, 1);

    const status = await server.status();
    assert.equal(status.hostCount, 1);
    assert.equal(status.connectionCount, 1);
  } finally {
    await closeAll([a]);
  }
});

test('local switch clients exchange frames without certificates', async ({ server }) => {
  const net = networkName('local-broadcast');
  const a = localClient(server, { name: 'local-a', networkIdentifier: net });
  const b = localClient(server, { name: 'local-b', networkIdentifier: net });

  try {
    await a.connect();
    await b.connect();

    const frame = ethernetFrame('ff:ff:ff:ff:ff:ff', '02:00:00:00:10:01', 'hello-local');
    a.sendData(frame);

    assert.deepEqual((await b.waitForData()).payload, frame);
    await a.expectNoData();
  } finally {
    await closeAll([a, b]);
  }
});

test('local switch sends member updates when peers leave', async ({ server }) => {
  const net = networkName('local-member-update');
  const a = localClient(server, { name: 'member-a', networkIdentifier: net });
  const b = localClient(server, { name: 'member-b', networkIdentifier: net });

  try {
    await a.connect();
    await b.connect();

    const joined = await a.waitForFrame(
      memberUpdatePredicate({ networkMemberCount: 2, localMemberCount: 2 }),
      1000,
      'member join update'
    );
    assert.deepEqual(parseMemberUpdate(joined), {
      networkMemberCount: 2,
      localMemberCount: 2
    });

    b.close();
    const left = await a.waitForFrame(
      memberUpdatePredicate({ networkMemberCount: 1, localMemberCount: 1 }),
      1000,
      'member leave update'
    );
    assert.deepEqual(parseMemberUpdate(left), {
      networkMemberCount: 1,
      localMemberCount: 1
    });
  } finally {
    await closeAll([a, b]);
  }
});

test('local switch removes silent peers on local keepalive timeout', async ({ server }) => {
  const net = networkName('local-keepalive-timeout');
  const a = localClient(server, { name: 'keepalive-a', networkIdentifier: net });
  const b = localClient(server, {
    name: 'keepalive-b',
    networkIdentifier: net,
    autoPong: false
  });

  try {
    await a.connect();
    await b.connect();

    await a.waitForFrame(
      memberUpdatePredicate({ networkMemberCount: 2, localMemberCount: 2 }),
      1000,
      'member join update'
    );

    await b.waitForClose(1500);
    const left = await a.waitForFrame(
      memberUpdatePredicate({ networkMemberCount: 1, localMemberCount: 1 }),
      1500,
      'keepalive member leave update'
    );
    assert.deepEqual(parseMemberUpdate(left), {
      networkMemberCount: 1,
      localMemberCount: 1
    });
  } finally {
    await closeAll([a, b]);
  }
});

test('local switch and mTLS clients share membership but do not bridge DATA', async ({ server, certs }) => {
  const net = networkName('mixed-fabric');
  const local = localClient(server, { name: 'mixed-local', networkIdentifier: net });
  const remote = client(server, certs, 'hostA', { name: 'mixed-tls', networkIdentifier: net });

  try {
    await local.connect();
    await remote.connect();

    const frame = ethernetFrame('ff:ff:ff:ff:ff:ff', '02:00:00:00:20:01', 'hello-mixed');
    local.sendData(frame);

    await remote.expectNoData();
  } finally {
    await closeAll([local, remote]);
  }
});

test('local member count ignores WebSwitch-only peers', async ({ server, certs }) => {
  const net = networkName('local-count-web-peer');
  const local = localClient(server, { name: 'count-local', networkIdentifier: net });
  const remote = client(server, certs, 'hostA', { name: 'count-tls', networkIdentifier: net });

  try {
    const ack = await local.connect();
    assert.equal(ack.networkMemberCount, 1);
    assert.equal(ack.localMemberCount, 1);

    await remote.connect();
    const update = await local.waitForFrame(
      memberUpdatePredicate({ networkMemberCount: 2, localMemberCount: 1 }),
      1000,
      'local count update for web-only peer'
    );
    assert.deepEqual(parseMemberUpdate(update), {
      networkMemberCount: 2,
      localMemberCount: 1
    });
  } finally {
    await closeAll([local, remote]);
  }
});

test('local member count drops when local interface leaves but host stays on mTLS', async ({ server, certs }) => {
  const net = networkName('local-count-interface-leave');
  const remoteNodeID = '44444444-4444-4444-8444-444444444444';
  const local = localClient(server, { name: 'interface-local-a', networkIdentifier: net });
  const remoteLocal = localClient(server, {
    name: 'interface-local-b',
    networkIdentifier: net,
    nodeID: remoteNodeID,
    interfaceName: 'local'
  });
  const remoteTls = client(server, certs, 'hostA', {
    name: 'interface-tls-b',
    networkIdentifier: net,
    nodeID: remoteNodeID,
    interfaceName: 'web'
  });

  try {
    await local.connect();
    await remoteLocal.connect();

    await local.waitForFrame(
      memberUpdatePredicate({ networkMemberCount: 2, localMemberCount: 2 }),
      1000,
      'local peer join update'
    );

    await remoteTls.connect();
    remoteLocal.close();

    const update = await local.waitForFrame(
      memberUpdatePredicate({ networkMemberCount: 2, localMemberCount: 1 }),
      1000,
      'local interface leave update'
    );
    assert.deepEqual(parseMemberUpdate(update), {
      networkMemberCount: 2,
      localMemberCount: 1
    });
  } finally {
    await closeAll([local, remoteLocal, remoteTls]);
  }
});

test('same host can attach over local switch and mTLS without DHCP overlap', async ({ server, certs }) => {
  const net = networkName('same-host-mixed');
  const nodeID = '33333333-3333-4333-8333-333333333333';
  const dhcpRange = dhcp('10.77.0.20', '10.77.0.30');
  const local = localClient(server, {
    name: 'same-host-local',
    networkIdentifier: net,
    nodeID,
    interfaceName: 'local',
    dhcpRange
  });
  const remote = client(server, certs, 'hostA', {
    name: 'same-host-tls',
    networkIdentifier: net,
    nodeID,
    interfaceName: 'web',
    dhcpRange
  });

  try {
    await local.connect();
    await remote.connect();

    await eventually(async () => {
      const status = await server.status();
      const network = status.networks.find((candidate) => candidate.identifier === net);
      assert.equal(network.hostCount, 1);
      assert.equal(network.connectionCount, 2);
    });
  } finally {
    await closeAll([local, remote]);
  }
});

test('missing client certificate is rejected', async ({ server, certs }) => {
  await expectTlsRejected({
    port: server.tlsPort,
    ca: certs.caCert
  });
});

test('client certificate signed by another CA is rejected', async ({ server, certs }) => {
  await expectTlsRejected({
    port: server.tlsPort,
    ca: certs.caCert,
    cert: certs.badHost.cert,
    key: certs.badHost.key
  });
});

test('revoked client certificate is rejected', async ({ server, certs }) => {
  const revoked = client(server, certs, 'revokedHost', {
    networkIdentifier: networkName('revoked')
  });

  try {
    await revoked.connectTls();
    const frame = await revoked.waitForFrame(
      (candidate) => candidate.type === FrameType.ERROR,
      1000,
      'revocation ERROR'
    );
    const error = parseErrorFrame(frame);
    assert.equal(error.code, 'certificate_revoked');
    await revoked.waitForClose();
  } finally {
    revoked.close();
  }
});

test('DATA before INIT closes the connection', async ({ server, certs }) => {
  const a = client(server, certs, 'hostA', {
    networkIdentifier: networkName('data-before-init')
  });

  try {
    await a.connectTls();
    a.sendData(ethernetFrame(
      'ff:ff:ff:ff:ff:ff',
      '02:00:00:00:00:01',
      'too-soon'
    ));
    await a.waitForClose();
  } finally {
    a.close();
  }
});

test('oversized frames close the connection', async ({ server, certs }) => {
  const a = client(server, certs, 'hostA', {
    networkIdentifier: networkName('oversized')
  });

  try {
    await a.connect();
    a.sendData(Buffer.alloc(70001, 1));
    await a.waitForClose();
  } finally {
    a.close();
  }
});

test('two hosts on the same network exchange broadcast frames', async ({ server, certs }) => {
  const net = networkName('broadcast');
  const a = client(server, certs, 'hostA', { name: 'broadcast-a', networkIdentifier: net });
  const b = client(server, certs, 'hostB', { name: 'broadcast-b', networkIdentifier: net });

  try {
    await a.connect();
    await b.connect();

    const frame = ethernetFrame('ff:ff:ff:ff:ff:ff', '02:00:00:00:00:01', 'hello-b');
    a.sendData(frame);

    assert.deepEqual((await b.waitForData()).payload, frame);
    await a.expectNoData();
  } finally {
    await closeAll([a, b]);
  }
});

test('learned unicast goes only to the target host', async ({ server, certs }) => {
  const net = networkName('known-unicast');
  const a = client(server, certs, 'hostA', { name: 'unicast-a', networkIdentifier: net });
  const b = client(server, certs, 'hostB', { name: 'unicast-b', networkIdentifier: net });
  const c = client(server, certs, 'hostC', { name: 'unicast-c', networkIdentifier: net });

  try {
    await a.connect();
    await b.connect();
    await c.connect();

    const learnB = ethernetFrame('ff:ff:ff:ff:ff:ff', '02:00:00:00:00:02', 'learn-b');
    b.sendData(learnB);
    await a.waitForData();
    await c.waitForData();

    const toB = ethernetFrame('02:00:00:00:00:02', '02:00:00:00:00:01', 'only-b');
    a.sendData(toB);

    assert.deepEqual((await b.waitForData()).payload, toB);
    await c.expectNoData();
    await a.expectNoData();
  } finally {
    await closeAll([a, b, c]);
  }
});

test('unknown unicast floods to peers except the sender', async ({ server, certs }) => {
  const net = networkName('unknown-unicast');
  const a = client(server, certs, 'hostA', { name: 'unknown-a', networkIdentifier: net });
  const b = client(server, certs, 'hostB', { name: 'unknown-b', networkIdentifier: net });
  const c = client(server, certs, 'hostC', { name: 'unknown-c', networkIdentifier: net });

  try {
    await a.connect();
    await b.connect();
    await c.connect();

    const frame = ethernetFrame('02:00:00:00:99:99', '02:00:00:00:00:01', 'flood');
    a.sendData(frame);

    assert.deepEqual((await b.waitForData()).payload, frame);
    assert.deepEqual((await c.waitForData()).payload, frame);
    await a.expectNoData();
  } finally {
    await closeAll([a, b, c]);
  }
});

test('hosts on different networks are isolated', async ({ server, certs }) => {
  const a = client(server, certs, 'hostA', {
    name: 'isolated-a',
    networkIdentifier: networkName('network-a')
  });
  const b = client(server, certs, 'hostB', {
    name: 'isolated-b',
    networkIdentifier: networkName('network-b')
  });

  try {
    await a.connect();
    await b.connect();

    a.sendData(ethernetFrame('ff:ff:ff:ff:ff:ff', '02:00:00:00:00:01', 'isolated'));
    await b.expectNoData();
  } finally {
    await closeAll([a, b]);
  }
});

test('duplicate DATA frames from one logical host are delivered once', async ({ server, certs }) => {
  const net = networkName('same-host-duplicate');
  const nodeID = '11111111-1111-4111-8111-111111111111';
  const a1 = client(server, certs, 'hostA', {
    name: 'logical-a-en0',
    networkIdentifier: net,
    nodeID,
    interfaceName: 'en0'
  });
  const a2 = client(server, certs, 'hostA', {
    name: 'logical-a-en1',
    networkIdentifier: net,
    nodeID,
    interfaceName: 'en1'
  });
  const b = client(server, certs, 'hostB', { name: 'logical-b', networkIdentifier: net });
  const logicalA = new LogicalHost([a1, a2]);

  try {
    await a1.connect();
    await a2.connect();
    await b.connect();

    const fromA = ethernetFrame('ff:ff:ff:ff:ff:ff', '02:00:00:00:00:0a', 'one-logical-frame');
    const encoded = encodeFrame({
      streamId: ETHERNET_STREAM_ID,
      type: FrameType.DATA,
      seqNo: 77,
      payload: fromA
    });
    a1.writeFrame(encoded);
    a2.writeFrame(encoded);

    assert.deepEqual((await b.waitForData()).payload, fromA);
    await b.expectNoData();

    const fromB = ethernetFrame('ff:ff:ff:ff:ff:ff', '02:00:00:00:00:0b', 'server-duplicates');
    b.sendData(fromB);
    assert.deepEqual((await logicalA.waitForData()).payload, fromB);
    await logicalA.expectNoData();
  } finally {
    await closeAll([a1, a2, b]);
  }
});

test('same-host DATA stays on the ingress transport class', async ({ server, certs }) => {
  const net = networkName('local-shortcut');
  const nodeID = '33333333-3333-4333-8333-333333333333';
  const web = client(server, certs, 'hostA', {
    name: 'shortcut-web',
    networkIdentifier: net,
    nodeID,
    interfaceName: 'web'
  });
  const local = localClient(server, {
    name: 'shortcut-local',
    networkIdentifier: net,
    nodeID,
    interfaceName: 'local'
  });
  const b = client(server, certs, 'hostB', { name: 'shortcut-b', networkIdentifier: net });
  let localPeer = null;

  try {
    await web.connect();
    await local.connect();
    await b.connect();

    const toWeb = ethernetFrame('ff:ff:ff:ff:ff:ff', '02:00:00:00:33:02', 'fallback-web');
    b.sendData(toWeb);
    assert.deepEqual((await web.waitForData()).payload, toWeb);
    await local.expectNoData();

    localPeer = localClient(server, { name: 'shortcut-local-peer', networkIdentifier: net });
    await localPeer.connect();
    const toLocal = ethernetFrame('ff:ff:ff:ff:ff:ff', '02:00:00:00:33:01', 'prefer-local');
    localPeer.sendData(toLocal);
    assert.deepEqual((await local.waitForData()).payload, toLocal);
    await web.expectNoData();
    localPeer.close();
  } finally {
    await closeAll([web, local, b, localPeer].filter(Boolean));
  }
});

test('same host/interface reconnect replaces the stale socket', async ({ server, certs }) => {
  const net = networkName('reconnect');
  const nodeID = '22222222-2222-4222-8222-222222222222';
  const stale = client(server, certs, 'hostA', {
    name: 'stale-default',
    networkIdentifier: net,
    nodeID,
    interfaceName: 'default'
  });
  const replacement = client(server, certs, 'hostA', {
    name: 'replacement-default',
    networkIdentifier: net,
    nodeID,
    interfaceName: 'default'
  });
  const b = client(server, certs, 'hostB', { name: 'reconnect-b', networkIdentifier: net });

  try {
    await stale.connect();
    await b.connect();
    await replacement.connect();
    await stale.waitForClose();

    await eventually(async () => {
      const status = await server.status();
      const network = status.networks.find((candidate) => candidate.identifier === net);
      assert.equal(network.hostCount, 2);
      assert.equal(network.connectionCount, 2);
    });

    const frame = ethernetFrame('ff:ff:ff:ff:ff:ff', '02:00:00:00:00:0b', 'after-reconnect');
    b.sendData(frame);
    assert.deepEqual((await replacement.waitForData()).payload, frame);
  } finally {
    await closeAll([stale, replacement, b]);
  }
});

test('overlapping DHCP range is rejected', async ({ server, certs }) => {
  const net = networkName('dhcp-overlap');
  const a = client(server, certs, 'hostA', {
    name: 'dhcp-a',
    networkIdentifier: net,
    dhcpRange: dhcp('10.77.0.20', '10.77.0.30')
  });
  const b = client(server, certs, 'hostB', {
    name: 'dhcp-b',
    networkIdentifier: net,
    dhcpRange: dhcp('10.77.0.25', '10.77.0.40')
  });
  const c = client(server, certs, 'hostC', {
    name: 'dhcp-c',
    networkIdentifier: net,
    dhcpRange: dhcp('10.77.0.31', '10.77.0.40')
  });

  try {
    await a.connect();
    await b.connectTls();
    b.writeFrame(encodeJsonFrame(FrameType.INIT, {
      protocol: 'okrun-switch/1',
      nodeID: b.nodeID,
      networkIdentifier: b.networkIdentifier,
      interface: b.interfaceName,
      maxFrameSize: b.maxFrameSize,
      dhcpRange: b.dhcpRange
    }));
    const error = parseErrorFrame(await b.waitForFrame(
      (candidate) => candidate.type === FrameType.ERROR,
      1000,
      'DHCP overlap ERROR'
    ));
    assert.equal(error.code, 'dhcp_range_overlap');
    await b.waitForClose();

    const ack = await c.connect();
    assert.equal(ack.protocol, 'okrun-switch/1');
  } finally {
    await closeAll([a, b, c]);
  }
});

test('keepalive timeout removes dead hosts and cleans MAC table entries', async ({ server, certs }) => {
  const net = networkName('keepalive');
  const a = client(server, certs, 'hostA', {
    name: 'silent-a',
    networkIdentifier: net,
    autoPong: false
  });
  const b = client(server, certs, 'hostB', {
    name: 'alive-b',
    networkIdentifier: net
  });

  try {
    await a.connect();
    await b.connect();

    const frame = ethernetFrame('ff:ff:ff:ff:ff:ff', '02:00:00:00:00:aa', 'learn-a');
    a.sendData(frame);
    assert.deepEqual((await b.waitForData()).payload, frame);

    await eventually(async () => {
      const status = await server.status();
      const network = status.networks.find((candidate) => candidate.identifier === net);
      assert.equal(network.hostCount, 2);
      assert.equal(network.macCount, 1);
    });

    await a.waitForClose(1500);

    await eventually(async () => {
      const status = await server.status();
      const network = status.networks.find((candidate) => candidate.identifier === net);
      assert.equal(network.hostCount, 1);
      assert.equal(network.connectionCount, 1);
      assert.equal(network.macCount, 0);
    });
  } finally {
    await closeAll([a, b]);
  }
});

async function main() {
  const tempRoot = makeTempDir();
  const certs = prepareCertificates(tempRoot);
  const server = await startServer(certs);
  let failed = 0;

  try {
    for (const current of tests) {
      process.stdout.write(`- ${current.name} ... `);
      try {
        await current.fn({ server, certs, tempRoot });
        process.stdout.write('ok\n');
      } catch (error) {
        failed += 1;
        process.stdout.write('FAILED\n');
        console.error(error.stack || error.message);
      }
    }
  } finally {
    await server.stop();
    if (failed === 0) {
      fs.rmSync(tempRoot, { recursive: true, force: true });
    } else {
      console.error(`Keeping e2e temp files at ${tempRoot}`);
      console.error('Server logs:');
      console.error(server.logs.join(''));
    }
  }

  if (failed > 0) {
    process.exit(1);
  }
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exit(1);
});
