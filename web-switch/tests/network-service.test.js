'use strict';

// Opt-in root/systemd integration test. Uses disposable /run files and a unique
// unit/TAP; never installs, enables, or replaces the production service.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { NetworkClient } = require('../src/network-client');
const { prepareCertificates, startServer } = require('./e2e/setup');
const root = path.resolve(__dirname, '..');
const systemctl = (...args) => execFileSync('systemctl', args, { encoding: 'utf8' }).trim();
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function waitFor(check, label) {
  for (let i = 0; i < 150; i++) {
    if (await check()) return;
    await sleep(100);
  }
  throw new Error(`Timed out: ${label}`);
}

async function main() {
  const auto = process.argv.includes('--auto');
  const subnet = '10.253.239.0/24';
  assert.equal(process.getuid(), 0, 'Run with sudo node on a systemd Linux host');
  const work = fs.mkdtempSync('/run/okrun-service-test-');
  const id = path.basename(work);
  const iface = `okt${process.pid}`;
  const unit = `${id}.service`;
  const unitPath = `/run/systemd/system/${unit}`;
  let server;
  let peer;
  try {
    assert(!fs.existsSync(`/sys/class/net/${iface}`));
    const certs = prepareCertificates(work);
    server = await startServer(certs, { keepaliveIntervalMs: 1000, keepaliveTimeoutMs: 5000 });
    const bundle = JSON.parse(fs.readFileSync(`${work}/certs/host-a/okrun-switch-bundle.json`));
    bundle.server = `localhost:${server.tlsPort}`;
    fs.writeFileSync(`${work}/host.json`, JSON.stringify(bundle), { mode: 0o600 });
    for (const dir of ['src', 'bin']) fs.mkdirSync(`${work}/${dir}`);
    for (const file of ['src/network-client.js', 'src/network-router.js', 'src/protocol.js', 'src/host-address.js', 'src/host-client.js',
      'bin/okrun-network.js', 'bin/okrun-switch-tap-helper.py']) {
      fs.copyFileSync(`${root}/${file}`, `${work}/${file}`);
    }
    const text = fs.readFileSync(`${root}/systemd/okrun-network.service.in`, 'utf8')
      .replaceAll('@NODE@', process.execPath).replaceAll('@NETWORK@', id)
      .replaceAll('@SUBNET@', subnet).replaceAll('StateDirectory=okrun-network', `StateDirectory=${id}`)
      .replaceAll('/var/lib/okrun-network/', `/var/lib/${id}/`)
      .replaceAll('@IFACE@', iface).replaceAll('@IP@', auto ? 'auto' : '192.0.2.254/32')
      .replaceAll('@LOCAL_ARGS@', `--local-server 127.0.0.1:${server.localPort}`)
      .replaceAll('/opt/okrun-network', work).replaceAll('/etc/okrun-network/host.json', `${work}/host.json`);
    fs.writeFileSync(unitPath, text);
    execFileSync('systemd-analyze', ['verify', unitPath]);
    const stateFile = `/var/lib/${id}/host-state.json`;
    const peerBundle = JSON.parse(fs.readFileSync(`${work}/certs/host-b/okrun-switch-bundle.json`));
    peerBundle.server = bundle.server;
    peer = new NetworkClient({ bundle: peerBundle, network: id, ip: '192.0.2.253/32' }, { frameOnly: true });
    await new Promise((resolve, reject) => {
      peer.once('ready', resolve); peer.once('failure', reject); peer.start();
    });
    let conflicts = 0;
    if (auto) {
      // Simulate an unadvertised static owner on the fabric, not a DHCP pool.
      // The real hardened TAP helper must see its ARP and choose a different IP.
      fs.mkdirSync(`/var/lib/${id}`, { mode: 0o700 });
      fs.writeFileSync(stateFile, JSON.stringify({ seed: require('node:crypto').randomUUID(),
        network: id, subnet, ip: '10.253.239.254/24' }), { mode: 0o600 });
      peer.on('frame', (frame) => {
        if (frame.length < 42 || frame.readUInt16BE(12) !== 0x0806
            || !frame.subarray(38, 42).equals(Buffer.from([10, 253, 239, 254]))) return;
        const owner = Buffer.from('ffffffffffff02aabbccddee0806000108000604000102aabbccddee0afdeffe0000000000000afdeffe', 'hex');
        peer.sendEthernet(owner);
        conflicts++;
      });
    }
    systemctl('daemon-reload');
    systemctl('start', unit);
    await waitFor(() => fs.existsSync(`/sys/class/net/${iface}`), 'real TAP created');
    if (auto) await waitFor(() => fs.existsSync(stateFile) && JSON.parse(fs.readFileSync(stateFile)).ip, 'automatic host address');
    const hostIP = auto ? JSON.parse(fs.readFileSync(stateFile)).ip.split('/')[0] : '192.0.2.254';
    if (auto) {
      assert(conflicts > 0, 'ARP conflict was injected through the live switch');
      assert.notEqual(hostIP, '10.253.239.254', 'conflicting address was not assigned');
    }
    // Broadcast ARP: ask the real Linux TAP's IP for its MAC, via cloud mTLS.
    const arp = Buffer.from('ffffffffffff02aabbccddee0806000108000604000102aabbccddeec00002fd000000000000c00002fe', 'hex');
    Buffer.from(hostIP.split('.').map(Number)).copy(arp, 38);
    let replies = 0;
    peer.on('frame', (frame) => {
      if (frame.length >= 42 && frame.readUInt16BE(12) === 0x0806 && frame.readUInt16BE(20) === 2
          && frame.subarray(28, 32).equals(Buffer.from(hostIP.split('.').map(Number)))) replies++;
    });
    await waitFor(() => { peer.sendEthernet(arp); return replies > 0; }, 'ARP reply from real TAP');
    const oldPID = systemctl('show', unit, '-p', 'MainPID', '--value');
    systemctl('kill', '--kill-whom=main', '--signal=SIGKILL', unit);
    await waitFor(() => {
      const pid = systemctl('show', unit, '-p', 'MainPID', '--value');
      return pid !== '0' && pid !== oldPID && fs.existsSync(`/sys/class/net/${iface}`);
    }, 'automatic restart after process failure');
    replies = 0;
    await waitFor(() => { peer.sendEthernet(arp); return replies > 0; }, 'ARP after restart');
    if (auto) assert.equal(JSON.parse(fs.readFileSync(stateFile)).ip.split('/')[0], hostIP, 'address persists across restart');
    const logs = execFileSync('journalctl', ['-u', unit, '--no-pager', '-o', 'cat'], { encoding: 'utf8' });
    assert.match(logs, /local switch connected/);
    assert.match(logs, /cloud switch connected/);
    if (auto) assert.match(logs, /automatically trying another/);
    systemctl('stop', unit);
    await waitFor(() => !fs.existsSync(`/sys/class/net/${iface}`), 'TAP cleanup on stop');
    console.log(`Mode: ${auto ? 'automatic host (real ARP conflict recovery + persisted address)' : 'static address'}`);
    console.log('PASS: hardened systemd unit, real TAP, local + mTLS cloud, ARP exchange, automatic restart, stop cleanup');
  } finally {
    peer?.close();
    try { systemctl('stop', unit); } catch {}
    fs.rmSync(unitPath, { force: true });
    systemctl('daemon-reload');
    try { execFileSync('systemctl', ['reset-failed', unit], { stdio: 'ignore' }); } catch {}
    await server?.stop();
    fs.rmSync(work, { recursive: true, force: true });
    fs.rmSync(`/var/lib/${id}`, { recursive: true, force: true });
  }
}
main().catch((error) => { console.error(error); process.exitCode = 1; });
