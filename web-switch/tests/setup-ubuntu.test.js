'use strict';

// Exercise the real deployment wrapper with a harmless installer stand-in.
// No root, credentials, live service, or network access is needed.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'okrun-setup-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const scripts = path.join(root, 'scripts');
  fs.mkdirSync(scripts);
  const wrapper = path.join(scripts, 'setup-ubuntu.sh');
  fs.copyFileSync(path.resolve(__dirname, '../scripts/setup-ubuntu.sh'), wrapper);
  fs.writeFileSync(path.join(scripts, 'install-network-client.sh'), 'printf "%s\\0" "$@"\n');
  return { root, run: (...args) => spawnSync('bash', [wrapper, ...args], { encoding: 'utf8' }) };
}

function forwarded(result) {
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.split('\0').slice(0, -1);
}

const settings = ['auto', 'okrun', 'okrun0', '172.16.0.10:9443'];

test('setup reuses /etc credentials without a checkout bundle', (t) => {
  const { run } = fixture(t);
  assert.deepEqual(forwarded(run()), ['/etc/okrun-network/host.json', ...settings]);
});

test('setup never prefers a stale credential left in the checkout', (t) => {
  const { root, run } = fixture(t);
  fs.writeFileSync(path.join(root, 'okrun-switch-bundle.json'), '{}');
  assert.deepEqual(forwarded(run()), ['/etc/okrun-network/host.json', ...settings]);
});

test('setup accepts an explicit import or rotation path including spaces', (t) => {
  const { run } = fixture(t);
  const bundle = '/private/imported host.json';
  assert.deepEqual(forwarded(run(bundle)), [bundle, ...settings]);
});

test('setup help describes canonical storage without invoking installer', (t) => {
  const { run } = fixture(t);
  const result = run('--help');
  assert.equal(result.status, 0);
  assert.match(result.stdout, /Default bundle: \/etc\/okrun-network\/host\.json/);
  assert.match(result.stdout, /first installation or credential rotation/);
  assert(!result.stdout.includes('\0'));
});

test('setup rejects excess positional arguments without invoking installer', (t) => {
  const { run } = fixture(t);
  const result = run('host.json', 'extra');
  assert.equal(result.status, 1);
  assert.match(result.stdout, /Usage:/);
  assert(!result.stdout.includes('\0'));
});
