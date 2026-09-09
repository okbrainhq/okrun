#!/usr/bin/env node
'use strict';

// Live, opt-in verification: a VM-like Linux IP stack, connected ONLY to the
// fabric, must discover and reach the physical host. Never bridges the LAN.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const crypto = require('node:crypto');
const { execFileSync, execFile, spawn } = require('node:child_process');
const { parseArgs, promisify } = require('node:util');
const { HostNetworkClient } = require('../src/host-client');
const { parseLocalEndpoint } = require('../src/network-client');
const run = promisify(execFile);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function main() {
  const { values } = parseArgs({ options: {
    bundle: { type: 'string' }, 'local-server': { type: 'string' },
    network: { type: 'string', default: 'okrun' },
    interface: { type: 'string', default: 'okrun0' },
    name: { type: 'string', default: `${os.hostname()}.local` }, help: { type: 'boolean' }
  } });
  if (values.help) {
    console.log('Usage: sudo node web-switch/bin/verify-host.js --bundle HOST.json [--local-server HOST:PORT] [--name azero.local]');
    return;
  }
  if (process.getuid() !== 0) throw new Error('Run with sudo: this test uses a temporary network namespace/TAP');
  if (!values.bundle || !/^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}\.local$/.test(values.name)) throw new Error('A private host bundle and valid .local name are required');
  const stat = fs.statSync(values.bundle);
  if (!stat.isFile() || (stat.mode & 0o077)) throw new Error('Bundle must be a private file (chmod 600)');
  const bundle = JSON.parse(fs.readFileSync(values.bundle, 'utf8'));
  const info = JSON.parse(execFileSync('ip', ['-j', '-4', 'address', 'show', 'dev', values.interface]));
  const addr = info[0]?.addr_info.find((entry) => entry.family === 'inet');
  if (!addr) throw new Error('The host network service must already have an IPv4 address');
  const hostIP = addr.local;
  const number = hostIP.split('.').reduce((n, octet) => n * 256 + Number(octet), 0);
  const base = (number & (0xffffffff << (32 - addr.prefixlen))) >>> 0;
  const subnet = `${[24, 16, 8, 0].map((shift) => (base >>> shift) & 255).join('.')}/${addr.prefixlen}`;
  const routes = [...(values['local-server'] ? [['local', parseLocalEndpoint(values['local-server'])]] : []), ['cloud', undefined]];
  const token = crypto.randomBytes(24).toString('hex');
  const server = http.createServer((_req, res) => res.end(token));
  server.requestTimeout = 5000;
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, hostIP, resolve); });
  try {
    for (const [route, localEndpoint] of routes) {
      const ns = `okrun-verify-${process.pid}-${route}`;
      let peer, created = false, failure;
      try {
        execFileSync('ip', ['netns', 'add', ns]); created = true;
        execFileSync('ip', ['-n', ns, 'link', 'set', 'lo', 'up']);
        peer = new HostNetworkClient({ bundle, network: values.network, subnet, interface: 'vmprobe0' }, {
          localEndpoint,
          spawn: (cmd, args, options) => spawn('ip', ['netns', 'exec', ns, cmd, ...args], options)
        });
        peer.on('failure', (error) => { failure = error; });
        peer.start();
        for (let i = 0; i < 450 && !peer.ready && !failure; i++) await sleep(100);
        if (failure) throw failure;
        if (!peer.ready) throw new Error('Verification peer did not join');
        // No physical NIC, NAT, veth, default gateway or resolver-cache shortcut.
        const source = peer.config.ip.split('/')[0];
        const { stdout } = await run('ip', ['netns', 'exec', ns, 'python3',
          path.resolve(__dirname, '../tests/peer-discovery.py'), source, values.name, hostIP,
          String(server.address().port), token], { timeout: 30000 });
        console.log(`${route}: ${stdout.trim()}`);
      } finally {
        peer?.close();
        await sleep(1500);
        if (created) execFileSync('ip', ['netns', 'del', ns]);
      }
    }
  } finally {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
}
main().catch((error) => { console.error(error.message); process.exitCode = 1; });
