'use strict';

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const { SwitchTLSServer } = require('./tls-server');
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

function buildConfig(argv = process.argv.slice(2), env = process.env) {
  const args = parseArgs(argv);
  const root = path.resolve(__dirname, '..');
  const serverBundlePath = args['server-bundle'] ?? env.OKRUN_SWITCH_SERVER_BUNDLE;
  const serverBundle = serverBundlePath ? readServerBundle(serverBundlePath) : {};

  return {
    host: args.host ?? env.OKRUN_SWITCH_HOST ?? '0.0.0.0',
    tlsPort: numberOption(args['tls-port'] ?? env.OKRUN_SWITCH_TLS_PORT, 9443, 'tls-port'),
    statusPort: numberOption(
      args['status-port'] ?? env.OKRUN_SWITCH_STATUS_PORT,
      8080,
      'status-port'
    ),
    serverBundlePath: serverBundlePath ? path.resolve(serverBundlePath) : null,
    serverKeyPem: serverBundle.serverKeyPem,
    serverCertPem: serverBundle.serverCertPem,
    caCertPem: serverBundle.caCertPem,
    serverKeyPath: serverBundlePath ? null : args['server-key'] ?? env.OKRUN_SWITCH_SERVER_KEY ?? path.join(root, '.certs/server/server-key.pem'),
    serverCertPath: serverBundlePath ? null : args['server-cert'] ?? env.OKRUN_SWITCH_SERVER_CERT ?? path.join(root, '.certs/server/server-cert.pem'),
    caCertPath: serverBundlePath ? null : args['ca-cert'] ?? env.OKRUN_SWITCH_CA_CERT ?? path.join(root, '.ca/ca-cert.pem'),
    crlPath: args.crl ?? env.OKRUN_SWITCH_CRL ?? path.join(root, '.ca/crl.txt'),
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
    macTtlMs: config.macTtlMs
  });

  const tlsServer = new SwitchTLSServer({
    ...config,
    fabric
  });

  const statusServer = createStatusServer(fabric);

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
    statusServer,
    close(callback) {
      let pending = 2;
      const done = () => {
        pending -= 1;
        if (pending === 0 && callback) {
          callback();
        }
      };
      tlsServer.close(done);
      statusServer.close(done);
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
