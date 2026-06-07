'use strict';

const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { execFileSync, spawn } = require('node:child_process');

const WEB_SWITCH_ROOT = path.resolve(__dirname, '../..');
const NODE = process.execPath;

function makeTempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'okrun-switch-e2e-'));
}

function runCa(args, cwd = WEB_SWITCH_ROOT) {
  return execFileSync(NODE, [path.join(WEB_SWITCH_ROOT, 'bin/okrun-switch-ca.js'), ...args], {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
}

function prepareCertificates(root) {
  const trustedCa = path.join(root, 'trusted-ca');
  const untrustedCa = path.join(root, 'untrusted-ca');
  const certsDir = path.join(root, 'certs');

  runCa(['init', '--ca-dir', trustedCa]);
  runCa([
    'issue-server',
    '--ca-dir',
    trustedCa,
    '--hostname',
    'localhost',
    '--output',
    path.join(certsDir, 'server')
  ]);

  for (const name of ['host-a', 'host-b', 'host-c', 'host-d', 'revoked-host']) {
    runCa([
      'issue-host',
      '--ca-dir',
      trustedCa,
      '--name',
      name,
      '--output',
      path.join(certsDir, name)
    ]);
  }

  const revokedBundle = readBundle(path.join(certsDir, 'revoked-host'));
  runCa(['revoke', '--ca-dir', trustedCa, '--serial', revokedBundle.serial]);

  runCa(['init', '--ca-dir', untrustedCa]);
  runCa([
    'issue-host',
    '--ca-dir',
    untrustedCa,
    '--name',
    'bad-host',
    '--output',
    path.join(certsDir, 'bad-host')
  ]);

  return {
    caCert: path.join(trustedCa, 'ca-cert.pem'),
    crl: path.join(trustedCa, 'crl.txt'),
    serverBundle: path.join(certsDir, 'server/okrun-switch-server-bundle.json'),
    hostA: hostCert(path.join(certsDir, 'host-a')),
    hostB: hostCert(path.join(certsDir, 'host-b')),
    hostC: hostCert(path.join(certsDir, 'host-c')),
    hostD: hostCert(path.join(certsDir, 'host-d')),
    revokedHost: hostCert(path.join(certsDir, 'revoked-host')),
    badHost: {
      ...hostCert(path.join(certsDir, 'bad-host')),
      ca: path.join(untrustedCa, 'ca-cert.pem')
    }
  };
}

function readBundle(dir) {
  return JSON.parse(fs.readFileSync(path.join(dir, 'okrun-switch-bundle.json'), 'utf8'));
}

function hostCert(dir) {
  const bundle = readBundle(dir);
  return {
    serial: bundle.serial,
    cert: path.join(dir, 'client-cert.pem'),
    key: path.join(dir, 'client-key.pem'),
    ca: path.join(dir, 'ca-cert.pem')
  };
}

async function getUnusedPort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function startServer(certs, options = {}) {
  const tlsPort = await getUnusedPort();
  const localPort = options.localPort === false ? null : await getUnusedPort();
  const statusPort = await getUnusedPort();
  const logs = [];
  const args = [
    path.join(WEB_SWITCH_ROOT, 'src/index.js'),
    '--host',
    '127.0.0.1',
    '--tls-port',
    String(tlsPort),
    ...(localPort == null ? [] : [
      '--local-port',
      String(localPort)
    ]),
    '--status-port',
    String(statusPort),
    '--server-bundle',
    certs.serverBundle,
    '--crl',
    certs.crl,
    '--keepalive-interval-ms',
    String(options.keepaliveIntervalMs ?? 50),
    '--keepalive-timeout-ms',
    String(options.keepaliveTimeoutMs ?? 200),
    '--local-keepalive-interval-ms',
    String(options.localKeepaliveIntervalMs ?? options.keepaliveIntervalMs ?? 50),
    '--local-keepalive-timeout-ms',
    String(options.localKeepaliveTimeoutMs ?? options.keepaliveTimeoutMs ?? 200),
    '--init-timeout-ms',
    String(options.initTimeoutMs ?? 1000),
    '--mac-ttl-ms',
    String(options.macTtlMs ?? 60000),
    ...(options.udpEnabled === false ? [
      '--udp-enabled',
      'false'
    ] : []),
    ...(options.udpPort != null ? [
      '--udp-port',
      String(options.udpPort)
    ] : []),
    ...(options.udpMtu != null ? [
      '--udp-mtu',
      String(options.udpMtu)
    ] : []),
    ...(options.udpInitialMbps != null ? [
      '--udp-initial-mbps',
      String(options.udpInitialMbps)
    ] : [])
  ];

  const child = spawn(NODE, args, {
    cwd: WEB_SWITCH_ROOT,
    stdio: ['ignore', 'pipe', 'pipe']
  });

  child.stdout.on('data', (chunk) => logs.push(chunk.toString('utf8')));
  child.stderr.on('data', (chunk) => logs.push(chunk.toString('utf8')));

  child.once('exit', (code, signal) => {
    logs.push(`server exited code=${code} signal=${signal}\n`);
  });

  await waitForHealth(statusPort, child, logs);

  return {
    tlsPort,
    localPort,
    statusPort,
    logs,
    process: child,
    async stop() {
      if (child.exitCode != null) {
        return;
      }

      child.kill('SIGTERM');
      await Promise.race([
        new Promise((resolve) => child.once('exit', resolve)),
        sleep(1000).then(() => {
          if (child.exitCode == null) {
            child.kill('SIGKILL');
          }
        })
      ]);
    },
    status() {
      return httpJson(statusPort, '/status');
    }
  };
}

async function waitForHealth(statusPort, child, logs) {
  const startedAt = Date.now();
  while (Date.now() - startedAt < 3000) {
    if (child.exitCode != null) {
      throw new Error(`server exited early:\n${logs.join('')}`);
    }

    try {
      const body = await httpText(statusPort, '/healthz');
      if (body.trim() === 'ok') {
        return;
      }
    } catch (_) {
      // Retry until the status listener is ready.
    }

    await sleep(25);
  }

  throw new Error(`Timed out waiting for server health:\n${logs.join('')}`);
}

function httpText(port, pathname) {
  return new Promise((resolve, reject) => {
    const request = http.get({
      hostname: '127.0.0.1',
      port,
      path: pathname,
      timeout: 500
    }, (response) => {
      let text = '';
      response.setEncoding('utf8');
      response.on('data', (chunk) => {
        text += chunk;
      });
      response.on('end', () => {
        if (response.statusCode !== 200) {
          reject(new Error(`HTTP ${response.statusCode}: ${text}`));
          return;
        }
        resolve(text);
      });
    });
    request.on('error', reject);
    request.on('timeout', () => request.destroy(new Error('HTTP timeout')));
  });
}

async function httpJson(port, pathname) {
  return JSON.parse(await httpText(port, pathname));
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function eventually(fn, timeoutMs = 1000, intervalMs = 25) {
  const startedAt = Date.now();
  let lastError;
  while (Date.now() - startedAt < timeoutMs) {
    try {
      return await fn();
    } catch (error) {
      lastError = error;
      await sleep(intervalMs);
    }
  }
  throw lastError ?? new Error('eventually timed out');
}

module.exports = {
  WEB_SWITCH_ROOT,
  eventually,
  makeTempDir,
  prepareCertificates,
  sleep,
  startServer
};
