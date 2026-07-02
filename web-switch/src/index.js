'use strict';

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const { TapAccessPort } = require('./access-port');
const { SwitchLocalServer, SwitchTLSServer } = require('./tls-server');
const { SwitchFabric } = require('./switch-fabric');
const { DEFAULT_MAX_FRAME_SIZE } = require('./protocol');

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
  const accessNetwork = args['access-network'] ?? env.OKRUN_SWITCH_ACCESS_NETWORK ?? null;
  const accessEnabled = booleanOption(
    args['access-enabled'] ?? env.OKRUN_SWITCH_ACCESS_ENABLED,
    Boolean(accessNetwork),
    'access-enabled'
  );
  if (accessEnabled && !accessNetwork) {
    throw new Error('access-network is required when access-enabled is true');
  }

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
    access: accessEnabled
      ? {
        enabled: true,
        networkIdentifier: accessNetwork,
        tapName: args['access-iface'] ?? env.OKRUN_SWITCH_ACCESS_IFACE ?? 'oksw0',
        interfaceName: args['access-interface'] ?? env.OKRUN_SWITCH_ACCESS_INTERFACE ?? args['access-iface'] ?? env.OKRUN_SWITCH_ACCESS_IFACE ?? 'oksw0',
        ipCidr: args['access-ip'] ?? env.OKRUN_SWITCH_ACCESS_IP ?? null,
        mtu: numberOption(args['access-mtu'] ?? env.OKRUN_SWITCH_ACCESS_MTU, 1500, 'access-mtu'),
        nodeID: args['access-node-id'] ?? env.OKRUN_SWITCH_ACCESS_NODE_ID ?? null,
        helperPath: path.resolve(args['access-helper'] ?? env.OKRUN_SWITCH_ACCESS_HELPER ?? path.join(root, 'bin/okrun-switch-tap-helper.py')),
        python: args['access-python'] ?? env.OKRUN_SWITCH_ACCESS_PYTHON ?? 'python3'
      }
      : { enabled: false }
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

function createStatusServer(fabric) {
  return http.createServer((request, response) => {
    if (request.url === '/healthz') {
      response.writeHead(200, { 'content-type': 'text/plain' });
      response.end('ok\n');
      return;
    }

    if (request.url === '/status') {
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(`${JSON.stringify(fabric.status())}\n`);
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

  const tlsServer = config.tlsEnabled !== false
    ? new SwitchTLSServer({
      ...config,
      fabric
    })
    : null;

  const localServer = config.localPort == null
    ? null
    : new SwitchLocalServer({
      ...config,
      fabric
    });

  const accessPort = config.access?.enabled
    ? new TapAccessPort({
      ...config.access,
      fabric,
      maxFrameSize: config.maxFrameSize,
      logger: config.logger ?? console
    })
    : null;

  const statusServer = createStatusServer(fabric);

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

  if (accessPort) {
    accessPort.start();
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
    accessPort,
    statusServer,
    close(callback) {
      const closers = [tlsServer, localServer, statusServer, accessPort].filter(Boolean);
      let pending = closers.length;
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
      for (const closer of closers) {
        closer.close(done);
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
