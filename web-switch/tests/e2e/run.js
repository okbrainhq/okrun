#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
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
  ETHERNET_STREAM_ID,
  FrameType,
  encodeFrame,
  encodeJsonFrame
} = require('../../src/protocol');

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

async function closeAll(clients) {
  for (const current of clients) {
    current.close();
  }
  await sleep(50);
}

test('valid mTLS client can INIT and join', async ({ server, certs }) => {
  const a = client(server, certs, 'hostA', {
    networkIdentifier: networkName('valid-init')
  });

  try {
    const ack = await a.connect();
    assert.equal(ack.protocol, 'okrun-switch/1');
    assert.equal(ack.maxFrameSize, 70000);

    const status = await server.status();
    assert.equal(status.hostCount, 1);
    assert.equal(status.connectionCount, 1);
  } finally {
    await closeAll([a]);
  }
});

test('local switch client can INIT without TLS credentials', async ({ server }) => {
  const a = localClient(server, {
    networkIdentifier: networkName('local-init')
  });

  try {
    const ack = await a.connect();
    assert.equal(ack.protocol, 'okrun-switch/1');
    assert.equal(ack.maxFrameSize, 70000);

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

test('local switch and mTLS clients share the same fabric', async ({ server, certs }) => {
  const net = networkName('mixed-fabric');
  const local = localClient(server, { name: 'mixed-local', networkIdentifier: net });
  const remote = client(server, certs, 'hostA', { name: 'mixed-tls', networkIdentifier: net });

  try {
    await local.connect();
    await remote.connect();

    const frame = ethernetFrame('ff:ff:ff:ff:ff:ff', '02:00:00:00:20:01', 'hello-mixed');
    local.sendData(frame);

    assert.deepEqual((await remote.waitForData()).payload, frame);
  } finally {
    await closeAll([local, remote]);
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

test('duplicate DATA frames from multipath sockets are delivered once', async ({ server, certs }) => {
  const net = networkName('multipath');
  const nodeID = '11111111-1111-4111-8111-111111111111';
  const a1 = client(server, certs, 'hostA', {
    name: 'multi-a-en0',
    networkIdentifier: net,
    nodeID,
    interfaceName: 'en0'
  });
  const a2 = client(server, certs, 'hostA', {
    name: 'multi-a-en1',
    networkIdentifier: net,
    nodeID,
    interfaceName: 'en1'
  });
  const b = client(server, certs, 'hostB', { name: 'multi-b', networkIdentifier: net });
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
