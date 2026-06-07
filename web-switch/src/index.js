'use strict';

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const crypto = require('node:crypto');

const { SwitchLocalServer, SwitchTLSServer } = require('./tls-server');
const { SwitchFabric } = require('./switch-fabric');
const { DEFAULT_MAX_FRAME_SIZE } = require('./protocol');
const { SwitchUDPDataPlane } = require('./udp-data-plane');

function parseArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (!arg.startsWith('--')) {
      throw new Error(`Unexpected argument ${arg}`);
    }

    const key = arg.slice(2);
    const value = argv[index + 1];
    if (value == null || value.startsWith('--')) {
      throw new Error(`Missing value for ${arg}`);
    }
    args[key] = value;
    index += 1;
  }

  return args;
}

function numberOption(value, fallback, name) {
  if (value == null || value === '') {
    return fallback;
  }

  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0) {
    throw new Error(`${name} must be a non-negative integer`);
  }
  return parsed;
}

function optionalNumberOption(value, name) {
  if (value == null || value === '') {
    return null;
  }

  return numberOption(value, null, name);
}

function floatOption(value, fallback, name) {
  if (value == null || value === '') {
    return fallback;
  }

  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0) {
    throw new Error(`${name} must be a non-negative number`);
  }
  return parsed;
}

function booleanOption(value, fallback, name) {
  if (value == null || value === '') {
    return fallback;
  }

  if (value === true || value === 'true' || value === '1' || value === 'yes') {
    return true;
  }

  if (value === false || value === 'false' || value === '0' || value === 'no') {
    return false;
  }

  throw new Error(`${name} must be true or false`);
}

function buildConfig(argv = process.argv.slice(2), env = process.env) {
  const args = parseArgs(argv);
  const root = path.resolve(__dirname, '..');
  const tlsEnabled = booleanOption(
    args['tls-enabled'] ?? env.OKRUN_SWITCH_TLS_ENABLED,
    true,
    'tls-enabled'
  );
  const localPort = optionalNumberOption(
    args['local-port'] ?? env.OKRUN_SWITCH_LOCAL_PORT,
    'local-port'
  );
  if (!tlsEnabled && localPort == null) {
    throw new Error('At least one switch listener must be enabled');
  }

  const serverBundlePath = tlsEnabled
    ? args['server-bundle'] ?? env.OKRUN_SWITCH_SERVER_BUNDLE
    : null;
  const serverBundle = serverBundlePath ? readServerBundle(serverBundlePath) : {};
  const tlsPort = tlsEnabled
    ? numberOption(args['tls-port'] ?? env.OKRUN_SWITCH_TLS_PORT, 9443, 'tls-port')
    : null;
  const defaultHost = tlsEnabled ? '0.0.0.0' : '127.0.0.1';

  return {
    host: args.host ?? env.OKRUN_SWITCH_HOST ?? defaultHost,
    tlsEnabled,
    tlsPort,
    localPort,
    statusPort: numberOption(
      args['status-port'] ?? env.OKRUN_SWITCH_STATUS_PORT,
      8080,
      'status-port'
    ),
    serverBundlePath: serverBundlePath ? path.resolve(serverBundlePath) : null,
    serverKeyPem: serverBundle.serverKeyPem,
    serverCertPem: serverBundle.serverCertPem,
    caCertPem: serverBundle.caCertPem,
    serverKeyPath: !tlsEnabled || serverBundlePath ? null : args['server-key'] ?? env.OKRUN_SWITCH_SERVER_KEY ?? path.join(root, '.certs/server/server-key.pem'),
    serverCertPath: !tlsEnabled || serverBundlePath ? null : args['server-cert'] ?? env.OKRUN_SWITCH_SERVER_CERT ?? path.join(root, '.certs/server/server-cert.pem'),
    caCertPath: !tlsEnabled || serverBundlePath ? null : args['ca-cert'] ?? env.OKRUN_SWITCH_CA_CERT ?? path.join(root, '.ca/ca-cert.pem'),
    crlPath: tlsEnabled ? args.crl ?? env.OKRUN_SWITCH_CRL ?? path.join(root, '.ca/crl.txt') : null,
    keepaliveIntervalMs: numberOption(
      args['keepalive-interval-ms'] ?? env.OKRUN_SWITCH_KEEPALIVE_INTERVAL_MS,
      10000,
      'keepalive-interval-ms'
    ),
    keepaliveTimeoutMs: numberOption(
      args['keepalive-timeout-ms'] ?? env.OKRUN_SWITCH_KEEPALIVE_TIMEOUT_MS,
      25000,
      'keepalive-timeout-ms'
    ),
    localKeepaliveIntervalMs: numberOption(
      args['local-keepalive-interval-ms'] ?? env.OKRUN_SWITCH_LOCAL_KEEPALIVE_INTERVAL_MS,
      500,
      'local-keepalive-interval-ms'
    ),
    localKeepaliveTimeoutMs: numberOption(
      args['local-keepalive-timeout-ms'] ?? env.OKRUN_SWITCH_LOCAL_KEEPALIVE_TIMEOUT_MS,
      1500,
      'local-keepalive-timeout-ms'
    ),
    initTimeoutMs: numberOption(
      args['init-timeout-ms'] ?? env.OKRUN_SWITCH_INIT_TIMEOUT_MS,
      10000,
      'init-timeout-ms'
    ),
    macTtlMs: numberOption(
      args['mac-ttl-ms'] ?? env.OKRUN_SWITCH_MAC_TTL_MS,
      5 * 60 * 1000,
      'mac-ttl-ms'
    ),
    maxFrameSize: numberOption(
      args['max-frame-size'] ?? env.OKRUN_SWITCH_MAX_FRAME_SIZE,
      DEFAULT_MAX_FRAME_SIZE,
      'max-frame-size'
    ),
    rateLimitFramesPerSecond: numberOption(
      args['rate-limit-frames-per-second'] ?? env.OKRUN_SWITCH_RATE_LIMIT_FRAMES_PER_SECOND,
      20000,
      'rate-limit-frames-per-second'
    ),
    rateLimitBytesPerSecond: numberOption(
      args['rate-limit-bytes-per-second'] ?? env.OKRUN_SWITCH_RATE_LIMIT_BYTES_PER_SECOND,
      128 * 1024 * 1024,
      'rate-limit-bytes-per-second'
    ),
    rateLimitBroadcastFramesPerSecond: numberOption(
      args['rate-limit-broadcast-frames-per-second'] ?? env.OKRUN_SWITCH_RATE_LIMIT_BROADCAST_FRAMES_PER_SECOND,
      2000,
      'rate-limit-broadcast-frames-per-second'
    ),
    rateLimitMulticastFramesPerSecond: numberOption(
      args['rate-limit-multicast-frames-per-second'] ?? env.OKRUN_SWITCH_RATE_LIMIT_MULTICAST_FRAMES_PER_SECOND,
      5000,
      'rate-limit-multicast-frames-per-second'
    ),
    rateLimitUnknownUnicastFramesPerSecond: numberOption(
      args['rate-limit-unknown-unicast-frames-per-second'] ?? env.OKRUN_SWITCH_RATE_LIMIT_UNKNOWN_UNICAST_FRAMES_PER_SECOND,
      5000,
      'rate-limit-unknown-unicast-frames-per-second'
    ),
    maxPendingWrites: numberOption(
      args['max-pending-writes'] ?? env.OKRUN_SWITCH_MAX_PENDING_WRITES,
      256,
      'max-pending-writes'
    ),
    maxPendingBytes: numberOption(
      args['max-pending-bytes'] ?? env.OKRUN_SWITCH_MAX_PENDING_BYTES,
      4 * 1024 * 1024,
      'max-pending-bytes'
    ),
    udpEnabled: booleanOption(
      args['udp-enabled'] ?? env.OKRUN_SWITCH_UDP_ENABLED,
      tlsEnabled,
      'udp-enabled'
    ),
    udpPort: numberOption(
      args['udp-port'] ?? env.OKRUN_SWITCH_UDP_PORT,
      tlsPort ?? 9443,
      'udp-port'
    ),
    udpMtu: numberOption(
      args['udp-mtu'] ?? env.OKRUN_SWITCH_UDP_MTU,
      1200,
      'udp-mtu'
    ),
    udpMinMtu: numberOption(
      args['udp-min-mtu'] ?? env.OKRUN_SWITCH_UDP_MIN_MTU,
      1200,
      'udp-min-mtu'
    ),
    udpMaxProbeMtu: numberOption(
      args['udp-max-probe-mtu'] ?? env.OKRUN_SWITCH_UDP_MAX_PROBE_MTU,
      1450,
      'udp-max-probe-mtu'
    ),
    udpInitialMbps: floatOption(
      args['udp-initial-mbps'] ?? env.OKRUN_SWITCH_UDP_INITIAL_MBPS,
      10,
      'udp-initial-mbps'
    ),
    udpMinMbps: floatOption(
      args['udp-min-mbps'] ?? env.OKRUN_SWITCH_UDP_MIN_MBPS,
      0.25,
      'udp-min-mbps'
    ),
    udpMaxMbps: floatOption(
      args['udp-max-mbps'] ?? env.OKRUN_SWITCH_UDP_MAX_MBPS,
      0,
      'udp-max-mbps'
    ),
    udpQueueBytes: numberOption(
      args['udp-queue-bytes'] ?? env.OKRUN_SWITCH_UDP_QUEUE_BYTES,
      4 * 1024 * 1024,
      'udp-queue-bytes'
    ),
    udpReassemblySessionBytes: numberOption(
      args['udp-reassembly-session-bytes'] ?? env.OKRUN_SWITCH_UDP_REASSEMBLY_SESSION_BYTES,
      1024 * 1024,
      'udp-reassembly-session-bytes'
    ),
    udpReassemblyGlobalBytes: numberOption(
      args['udp-reassembly-global-bytes'] ?? env.OKRUN_SWITCH_UDP_REASSEMBLY_GLOBAL_BYTES,
      64 * 1024 * 1024,
      'udp-reassembly-global-bytes'
    ),
    udpRecvBufferBytes: numberOption(
      args['udp-recv-buffer-bytes'] ?? env.OKRUN_SWITCH_UDP_RECV_BUFFER_BYTES,
      4 * 1024 * 1024,
      'udp-recv-buffer-bytes'
    ),
    udpSendBufferBytes: numberOption(
      args['udp-send-buffer-bytes'] ?? env.OKRUN_SWITCH_UDP_SEND_BUFFER_BYTES,
      4 * 1024 * 1024,
      'udp-send-buffer-bytes'
    )
  };
}

function readServerBundle(file) {
  const bundlePath = path.resolve(file);
  const bundle = JSON.parse(fs.readFileSync(bundlePath, 'utf8'));
  return {
    caCertPem: requiredBundleString(bundle, 'caCertPem', bundlePath),
    serverCertPem: requiredBundleString(bundle, 'serverCertPem', bundlePath),
    serverKeyPem: requiredBundleString(bundle, 'serverKeyPem', bundlePath)
  };
}

function requiredBundleString(bundle, key, file) {
  const value = bundle[key];
  if (typeof value !== 'string' || value.trim() === '') {
    throw new Error(`${file} is missing ${key}`);
  }
  return value;
}

function serverIdentity(config) {
  let certificate = config.serverCertPem;
  if (!certificate && config.serverCertPath) {
    try {
      certificate = fs.readFileSync(config.serverCertPath);
    } catch (_) {
      certificate = null;
    }
  }
  if (!certificate) {
    return 'server';
  }
  return crypto.createHash('sha256').update(certificate).digest('hex');
}

function createStatusServer(fabric, udpDataPlane = null) {
  return http.createServer((request, response) => {
    if (request.url === '/healthz') {
      response.writeHead(200, { 'content-type': 'text/plain' });
      response.end('ok\n');
      return;
    }

    if (request.url === '/status') {
      const status = fabric.status();
      status.udp = udpDataPlane
        ? udpDataPlane.status()
        : { enabled: false };
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(`${JSON.stringify(status)}\n`);
      return;
    }

    response.writeHead(404, { 'content-type': 'text/plain' });
    response.end('not found\n');
  });
}

function start(config) {
  const fabric = new SwitchFabric({
    maxFrameSize: config.maxFrameSize,
    macTtlMs: config.macTtlMs,
    rateLimitFramesPerSecond: config.rateLimitFramesPerSecond,
    rateLimitBytesPerSecond: config.rateLimitBytesPerSecond,
    rateLimitBroadcastFramesPerSecond: config.rateLimitBroadcastFramesPerSecond,
    rateLimitMulticastFramesPerSecond: config.rateLimitMulticastFramesPerSecond,
    rateLimitUnknownUnicastFramesPerSecond: config.rateLimitUnknownUnicastFramesPerSecond
  });

  const udpDataPlane = config.udpEnabled && config.tlsEnabled !== false
    ? new SwitchUDPDataPlane({
      enabled: true,
      host: config.host,
      port: config.udpPort,
      mtu: config.udpMtu,
      minMtu: config.udpMinMtu,
      maxProbeMtu: config.udpMaxProbeMtu,
      initialMbps: config.udpInitialMbps,
      minMbps: config.udpMinMbps,
      maxMbps: config.udpMaxMbps,
      queueBytes: config.udpQueueBytes,
      reassemblySessionBytes: config.udpReassemblySessionBytes,
      reassemblyGlobalBytes: config.udpReassemblyGlobalBytes,
      recvBufferBytes: config.udpRecvBufferBytes,
      sendBufferBytes: config.udpSendBufferBytes,
      serverIdentity: serverIdentity(config),
      logger: console
    })
    : null;

  if (udpDataPlane) {
    udpDataPlane.listen();
  }

  const tlsServer = config.tlsEnabled !== false
    ? new SwitchTLSServer({
      ...config,
      fabric,
      udpDataPlane
    })
    : null;

  const localServer = config.localPort == null
    ? null
    : new SwitchLocalServer({
      ...config,
      fabric
    });

  const statusServer = createStatusServer(fabric, udpDataPlane);

  if (tlsServer) {
    tlsServer.listen(() => {
      const address = tlsServer.address();
      console.log(JSON.stringify({
        event: 'tls_listening',
        host: address.address,
        port: address.port,
        serverBundle: config.serverBundlePath,
        serverCert: config.serverCertPath,
        caCert: config.caCertPath,
        crl: config.crlPath
      }));
    });
  }

  if (localServer) {
    localServer.listen(() => {
      const address = localServer.address();
      console.log(JSON.stringify({
        event: 'local_listening',
        host: address.address,
        port: address.port
      }));
    });
  }

  statusServer.listen(config.statusPort, config.host, () => {
    const address = statusServer.address();
    console.log(JSON.stringify({
      event: 'status_listening',
      host: address.address,
      port: address.port
    }));
  });

  return {
    fabric,
    tlsServer,
    localServer,
    statusServer,
    close(callback) {
      const servers = [tlsServer, localServer, statusServer, udpDataPlane].filter(Boolean);
      let pending = servers.length;
      if (pending === 0) {
        if (callback) {
          callback();
        }
        return;
      }
      const done = () => {
        pending -= 1;
        if (pending === 0 && callback) {
          callback();
        }
      };
      for (const server of servers) {
        server.close(done);
      }
    }
  };
}

if (require.main === module) {
  let running;
  try {
    running = start(buildConfig());
  } catch (error) {
    console.error(error.stack || error.message);
    process.exit(1);
  }

  const shutdown = () => {
    running.close(() => process.exit(0));
    setTimeout(() => process.exit(1), 3000).unref();
  };

  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

module.exports = {
  buildConfig,
  createStatusServer,
  start
};
