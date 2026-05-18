#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { randomBytes } = require('node:crypto');
const { execFileSync } = require('node:child_process');

function main(argv) {
  const [command, ...rest] = argv;
  const options = parseOptions(rest);
  const caDir = path.resolve(options['ca-dir'] ?? '.ca');

  switch (command) {
    case 'init':
      initCa(caDir);
      break;
    case 'issue-server':
      issueServer(caDir, options);
      break;
    case 'issue-host':
      issueHost(caDir, options);
      break;
    case 'print-host-bundle':
      printHostBundle(options);
      break;
    case 'print-server-bundle':
      printServerBundle(options);
      break;
    case 'revoke':
      revoke(caDir, options);
      break;
    case 'list':
      list(caDir);
      break;
    default:
      usage();
      process.exit(command ? 1 : 0);
  }
}

function parseOptions(args) {
  const options = {};
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (!arg.startsWith('--')) {
      throw new Error(`Unexpected argument ${arg}`);
    }
    const key = arg.slice(2);
    const value = args[index + 1];
    if (value == null || value.startsWith('--')) {
      throw new Error(`Missing value for ${arg}`);
    }
    options[key] = value;
    index += 1;
  }
  return options;
}

function usage() {
  console.log(`Usage:
  okrun-switch-ca init [--ca-dir <dir>]
  okrun-switch-ca issue-server --hostname <host> [--output <dir>] [--ca-dir <dir>]
  okrun-switch-ca issue-host --name <name> [--server <host:port>] [--output <dir>] [--ca-dir <dir>]
  okrun-switch-ca print-host-bundle --input <dir> [--server <host:port>]
  okrun-switch-ca print-server-bundle --input <dir>
  okrun-switch-ca revoke --serial <serial> [--ca-dir <dir>]
  okrun-switch-ca list [--ca-dir <dir>]`);
}

function initCa(caDir) {
  ensureDir(caDir);
  const keyPath = path.join(caDir, 'ca-key.pem');
  const certPath = path.join(caDir, 'ca-cert.pem');

  if (!fs.existsSync(keyPath)) {
    openssl([
      'genrsa',
      '-out',
      keyPath,
      '4096'
    ]);
    fs.chmodSync(keyPath, 0o600);
  }

  if (!fs.existsSync(certPath)) {
    openssl([
      'req',
      '-x509',
      '-new',
      '-nodes',
      '-key',
      keyPath,
      '-sha256',
      '-days',
      '3650',
      '-out',
      certPath,
      '-subj',
      '/CN=okrun-switch-local-ca'
    ]);
  }

  writeIfMissing(path.join(caDir, 'serial-counter.txt'), '1\n');
  writeIfMissing(path.join(caDir, 'issued.txt'), '');
  writeIfMissing(path.join(caDir, 'crl.txt'), '');
  console.log(`Initialized CA in ${caDir}`);
}

function issueServer(caDir, options) {
  const hostname = required(options, 'hostname');
  if (!isValidHostname(hostname)) {
    throw new Error(`Invalid hostname: ${hostname}`);
  }

  const output = path.resolve(options.output ?? '.certs/server');
  initCa(caDir);
  ensureDir(output);

  const keyPath = path.join(output, 'server-key.pem');
  const csrPath = path.join(output, 'server.csr');
  const certPath = path.join(output, 'server-cert.pem');
  const configPath = makeServerOpenSSLConfig(hostname);
  const serial = nextSerial(caDir);

  openssl(['genrsa', '-out', keyPath, '2048']);
  fs.chmodSync(keyPath, 0o600);
  openssl(['req', '-new', '-key', keyPath, '-out', csrPath, '-subj', `/CN=${hostname}`]);
  const tempCAFile = createTempCAFile(caDir);
  try {
    openssl([
      'x509',
      '-req',
      '-in',
      csrPath,
      '-CA',
      tempCAFile,
      '-out',
      certPath,
      '-days',
      '825',
      '-sha256',
      '-set_serial',
      String(serial),
      '-extfile',
      configPath,
      '-extensions',
      'v3_req'
    ]);
  } finally {
    fs.rmSync(tempCAFile, { force: true });
    fs.rmSync(csrPath, { force: true });
    fs.rmSync(configPath, { force: true });
  }

  recordIssued(caDir, { serial, type: 'server', name: hostname, certPath });
  const bundlePath = writeServerBundle(caDir, output, { hostname, serial, certPath, keyPath });
  console.log(JSON.stringify({ type: 'server', serial, bundle: bundlePath }));
}

function issueHost(caDir, options) {
  const name = required(options, 'name');
  if (!isValidHostName(name)) {
    throw new Error('Host name must contain only letters, numbers, dots, underscores, or hyphens');
  }

  const output = path.resolve(options.output ?? path.join('.certs/hosts', name));
  const server = options.server ?? 'localhost:9443';
  initCa(caDir);
  ensureDir(output);

  const keyPath = path.join(output, 'client-key.pem');
  const csrPath = path.join(output, 'client.csr');
  const certPath = path.join(output, 'client-cert.pem');
  const caCertPath = path.join(output, 'ca-cert.pem');
  const configPath = makeClientOpenSSLConfig();
  const serial = nextSerial(caDir);

  openssl(['genrsa', '-out', keyPath, '2048']);
  fs.chmodSync(keyPath, 0o600);
  openssl(['req', '-new', '-key', keyPath, '-out', csrPath, '-subj', `/CN=okrun-host:${name}`]);
  const tempCAFile = createTempCAFile(caDir);
  try {
    openssl([
      'x509',
      '-req',
      '-in',
      csrPath,
      '-CA',
      tempCAFile,
      '-out',
      certPath,
      '-days',
      '825',
      '-sha256',
      '-set_serial',
      String(serial),
      '-extfile',
      configPath,
      '-extensions',
      'v3_req'
    ]);
  } finally {
    fs.rmSync(tempCAFile, { force: true });
  }

  fs.copyFileSync(path.join(caDir, 'ca-cert.pem'), caCertPath);
  fs.rmSync(csrPath, { force: true });
  fs.rmSync(configPath, { force: true });

  const bundlePath = writeHostBundle(output, { name, serial, server, caCertPath, certPath, keyPath });
  recordIssued(caDir, { serial, type: 'host', name, certPath });
  console.log(JSON.stringify({ type: 'host', serial, bundle: bundlePath }));
}

function printHostBundle(options) {
  const input = path.resolve(required(options, 'input'));
  const bundlePath = path.join(input, 'okrun-switch-bundle.json');
  const bundle = fs.existsSync(bundlePath)
    ? JSON.parse(fs.readFileSync(bundlePath, 'utf8'))
    : makeHostBundle({
      name: path.basename(input),
      serial: null,
      server: options.server ?? 'localhost:9443',
      caCertPath: path.join(input, 'ca-cert.pem'),
      certPath: path.join(input, 'client-cert.pem'),
      keyPath: path.join(input, 'client-key.pem')
    });
  if (options.server) {
    bundle.server = options.server;
  }
  console.log(JSON.stringify(bundle, null, 2));
}

function printServerBundle(options) {
  const input = path.resolve(required(options, 'input'));
  const bundlePath = path.join(input, 'okrun-switch-server-bundle.json');
  const bundle = fs.existsSync(bundlePath)
    ? JSON.parse(fs.readFileSync(bundlePath, 'utf8'))
    : makeServerBundle({
      hostname: path.basename(input),
      serial: null,
      caCertPath: path.join(input, 'ca-cert.pem'),
      certPath: path.join(input, 'server-cert.pem'),
      keyPath: path.join(input, 'server-key.pem')
    });
  console.log(JSON.stringify(bundle, null, 2));
}

function writeServerBundle(caDir, output, { hostname, serial, certPath, keyPath }) {
  const bundlePath = path.join(output, 'okrun-switch-server-bundle.json');
  const bundle = makeServerBundle({
    hostname,
    serial,
    caCertPath: path.join(caDir, 'ca-cert.pem'),
    certPath,
    keyPath
  });
  writePrivateJSON(bundlePath, bundle);
  return bundlePath;
}

function writeHostBundle(output, { name, serial, server, caCertPath, certPath, keyPath }) {
  const bundlePath = path.join(output, 'okrun-switch-bundle.json');
  const bundle = makeHostBundle({ name, serial, server, caCertPath, certPath, keyPath });
  writePrivateJSON(bundlePath, bundle);
  return bundlePath;
}

function makeServerBundle({ hostname, serial, caCertPath, certPath, keyPath }) {
  return {
    type: 'server',
    hostname,
    serial,
    caCertPem: fs.readFileSync(caCertPath, 'utf8'),
    serverCertPem: fs.readFileSync(certPath, 'utf8'),
    serverKeyPem: fs.readFileSync(keyPath, 'utf8')
  };
}

function makeHostBundle({ name, serial, server, caCertPath, certPath, keyPath }) {
  return {
    type: 'host',
    name,
    serial,
    server,
    caCertPem: fs.readFileSync(caCertPath, 'utf8'),
    clientCertPem: fs.readFileSync(certPath, 'utf8'),
    clientKeyPem: fs.readFileSync(keyPath, 'utf8')
  };
}

function writePrivateJSON(file, value) {
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  fs.chmodSync(file, 0o600);
}

function revoke(caDir, options) {
  initCa(caDir);
  const serial = normalizeSerialForCrl(required(options, 'serial'));
  const crlPath = path.join(caDir, 'crl.txt');
  const existing = new Set(fs.readFileSync(crlPath, 'utf8')
    .split(/\r?\n/)
    .map((line) => normalizeSerialForCrl(line.trim()))
    .filter(Boolean));
  existing.add(serial);
  fs.writeFileSync(crlPath, `${Array.from(existing).sort().join('\n')}\n`);
  console.log(`Revoked ${serial}`);
}

function list(caDir) {
  initCa(caDir);
  process.stdout.write(fs.readFileSync(path.join(caDir, 'issued.txt'), 'utf8'));
}

function required(options, key) {
  if (!options[key]) {
    throw new Error(`Missing --${key}`);
  }
  return options[key];
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function writeIfMissing(file, text) {
  if (!fs.existsSync(file)) {
    fs.writeFileSync(file, text);
  }
}

function openssl(args) {
  execFileSync('openssl', args, { stdio: ['ignore', 'pipe', 'pipe'] });
}

function createTempCAFile(caDir) {
  const tempCAPath = path.join(
    os.tmpdir(),
    `.okrun-switch-ca-${process.pid}-${randomBytes(8).toString('hex')}.pem`
  );
  const combined = fs.readFileSync(path.join(caDir, 'ca-cert.pem'), 'utf8')
    + fs.readFileSync(path.join(caDir, 'ca-key.pem'), 'utf8');
  fs.writeFileSync(tempCAPath, combined, { mode: 0o600 });
  return tempCAPath;
}

function nextSerial(caDir) {
  const file = path.join(caDir, 'serial-counter.txt');
  const current = Number.parseInt(fs.readFileSync(file, 'utf8').trim(), 10);
  if (!Number.isInteger(current)) {
    throw new Error(`Invalid serial counter in ${file}`);
  }
  const next = current + 1;
  fs.writeFileSync(file, `${next}\n`);
  return current;
}

function recordIssued(caDir, record) {
  fs.appendFileSync(
    path.join(caDir, 'issued.txt'),
    `${record.serial}\t${record.type}\t${record.name}\t${record.certPath}\n`
  );
}

function makeServerOpenSSLConfig(hostname) {
  const file = path.join(
    os.tmpdir(),
    `okrun-switch-server-${process.pid}-${randomBytes(8).toString('hex')}.cnf`
  );
  const altLines = [];
  if (/^\d+\.\d+\.\d+\.\d+$/.test(hostname)) {
    altLines.push(`IP.1 = ${hostname}`);
  } else {
    altLines.push(`DNS.1 = ${hostname}`);
    if (hostname === 'localhost') {
      altLines.push('IP.1 = 127.0.0.1');
    }
  }

  fs.writeFileSync(file, `[v3_req]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
${altLines.join('\n')}
`);
  return file;
}

function makeClientOpenSSLConfig() {
  const file = path.join(
    os.tmpdir(),
    `okrun-switch-client-${process.pid}-${randomBytes(8).toString('hex')}.cnf`
  );
  fs.writeFileSync(file, `[v3_req]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
`);
  return file;
}

function normalizeSerialForCrl(serial) {
  const value = String(serial ?? '').trim();
  if (!value) {
    return '';
  }

  if (/^\d+$/.test(value)) {
    return String(Number.parseInt(value, 10));
  }

  const clean = value.replace(/[^0-9a-f]/gi, '');
  if (!clean) {
    return '';
  }

  const parsed = Number.parseInt(clean, 16);
  return Number.isFinite(parsed) ? String(parsed) : '';
}

function isValidHostName(name) {
  return /^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/.test(name);
}

function isValidHostname(hostname) {
  if (hostname === 'localhost') {
    return true;
  }

  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(hostname)) {
    return hostname.split('.').every((part) => Number(part) >= 0 && Number(part) <= 255);
  }

  return /^[A-Za-z0-9][A-Za-z0-9.-]{0,251}[A-Za-z0-9]$/.test(hostname)
    && !hostname.includes('..')
    && !hostname.split('.').some((part) => part.startsWith('-') || part.endsWith('-'));
}

try {
  main(process.argv.slice(2));
} catch (error) {
  console.error(error.message);
  process.exit(1);
}
