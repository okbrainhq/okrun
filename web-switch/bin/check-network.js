#!/usr/bin/env node
'use strict';

// Protocol admission only: no TAP, IP assignment, Ethernet traffic, or sudo.
const fs = require('node:fs');
const { parseArgs } = require('node:util');
const { NetworkClient, parseLocalEndpoint } = require('../src/network-client');

async function main() {
  const { values } = parseArgs({ options: {
    bundle: { type: 'string' }, 'local-server': { type: 'string' },
    network: { type: 'string', default: 'okrun' }, help: { type: 'boolean' }
  } });
  if (values.help) {
    console.log('Usage: node bin/check-network.js --bundle HOST.json [--local-server HOST:PORT] [--network okrun]');
    return;
  }
  if (!values.bundle) throw new Error('--bundle is required');
  const stat = fs.statSync(values.bundle);
  if (!stat.isFile() || (stat.mode & 0o077)) throw new Error('Host bundle must be a private file (chmod 600)');
  const bundle = JSON.parse(fs.readFileSync(values.bundle, 'utf8'));
  const localEndpoint = values['local-server'] ? parseLocalEndpoint(values['local-server']) : undefined;
  const routes = [['cloud', undefined], ...(localEndpoint ? [['local', localEndpoint]] : [])];
  const results = await Promise.all(routes.map(([route, endpoint]) => new Promise((resolve) => {
    // Required by shared config validation; this address is NEVER assigned.
    const client = new NetworkClient({ bundle, network: values.network, ip: '192.0.2.1/32' },
      { frameOnly: true, localEndpoint: endpoint });
    client.once('ready', () => {
      console.log(`${route}: protocol INIT accepted${route === 'cloud' ? ' (verified mTLS)' : ' (plain TCP)'}`);
      client.close(); resolve(true);
    });
    client.once('failure', (error) => {
      console.error(`${route}: ${error.message}`); resolve(false);
    });
    client.start();
  })));
  if (results.some((ok) => !ok)) process.exitCode = 1;
}
main().catch((error) => { console.error(error.message); process.exitCode = 1; });
