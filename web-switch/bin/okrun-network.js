#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const { parseArgs } = require('node:util');
const { NetworkClient, validateConfig } = require('../src/network-client');
const { RoutedNetworkClient } = require('../src/network-router');
const { HostNetworkClient } = require('../src/host-client');

try {
  const { values } = parseArgs({ options: {
    'local-server': { type: 'string' },
    subnet: { type: 'string', default: '10.77.0.0/24' }, 'state-file': { type: 'string' },
    bundle: { type: 'string' }, network: { type: 'string', default: 'okrun' },
    interface: { type: 'string', default: 'okrun0' }, ip: { type: 'string' },
    mtu: { type: 'string', default: '1500' }, check: { type: 'boolean' }, help: { type: 'boolean' }
  } });
  if (values.help) {
    console.log('Usage: node web-switch/bin/okrun-network.js --bundle HOST.json [--ip auto|PRIVATE_IP/PREFIX] [--subnet 10.77.0.0/24] [--state-file PATH] [--network okrun] [--interface okrun0] [--mtu 1500] [--local-server LAN_HOST:9444] [--check]\n\nNetwork-only Linux client. Use a unique host bundle. No IP argument is needed: automatic host attachment is the default.\n--check validates configuration without connecting or creating a TAP.\nFor automatic reconnect and startup, use scripts/install-network-client.sh.');
  } else {
    if (!values.bundle) throw new Error('--bundle is required');
    const stat = fs.statSync(values.bundle);
    if (!stat.isFile() || (stat.mode & 0o077)) throw new Error('Host bundle must be a private file (chmod 600)');
    const config = validateConfig({ ...values, localServer: values['local-server'], stateFile: values['state-file'], mtu: Number(values.mtu), bundle: JSON.parse(fs.readFileSync(values.bundle, 'utf8')) });
    if (values.check) {
      console.log('Configuration valid');
    } else {
      if (process.platform !== 'linux') throw new Error('The network client requires Linux /dev/net/tun and CAP_NET_ADMIN');
      if (fs.existsSync(`/sys/class/net/${config.interface}`)) throw new Error(`Interface ${config.interface} already exists; choose an unused name`);
      const client = config.ip === 'auto' ? new HostNetworkClient(config) : config.localServer ? new RoutedNetworkClient(config) : new NetworkClient(config);
      client.on('ready', () => console.log(`Joined ${config.network} on ${config.interface} (${client.config.ip})`));
      client.on('log', (line) => console.error(line));
      client.on('failure', (error) => { console.error(error.message); process.exitCode = 1; });
      process.once('SIGINT', () => client.close());
      process.once('SIGTERM', () => client.close());
      client.start();
    }
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
