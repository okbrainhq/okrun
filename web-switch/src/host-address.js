'use strict';

const crypto = require('node:crypto');
const net = require('node:net');

const DEFAULT_SUBNET = '10.77.0.0/24';
const toInt = (ip) => ip.split('.').reduce((n, octet) => n * 256 + Number(octet), 0);
const toIP = (n) => [24, 16, 8, 0].map((shift) => (n >>> shift) & 255).join('.');

function parseSubnet(cidr = DEFAULT_SUBNET) {
  const [ip, prefix, extra] = String(cidr).split('/');
  if (extra !== undefined || net.isIP(ip) !== 4 || !/^\d+$/.test(prefix || '') || +prefix < 16 || +prefix > 30) {
    throw new Error('Automatic host subnet must be an IPv4 CIDR with prefix /16 through /30');
  }
  const base = toInt(ip);
  const size = 2 ** (32 - Number(prefix));
  const privateIP = ip.startsWith('10.') || ip.startsWith('192.168.') || (base >= toInt('172.16.0.0') && base <= toInt('172.31.255.255'));
  if (!privateIP || base % size !== 0) throw new Error('Automatic host subnet must be a canonical RFC1918 network');
  return { cidr: `${ip}/${Number(prefix)}`, base, prefix: Number(prefix), size };
}

// Prefer high host addresses (outside Okrun's usual VM pools), but do not assume
// they are free: switch admission + Ethernet ARP probing decide that at runtime.
function addressCandidates(subnet, seed, previous) {
  const { base, size, prefix } = parseSubnet(subnet);
  const count = size - 3; // exclude network, .1/gateway, and broadcast
  const window = Math.min(54, count);
  const hash = crypto.createHash('sha256').update(seed).digest().readUInt32BE(0);
  const offset = hash % window;
  const result = [];
  if (typeof previous === 'string') {
    const [ip, bits] = previous.split('/');
    const n = net.isIP(ip) === 4 ? toInt(ip) : -1;
    if (Number(bits) === prefix && n >= base + 2 && n < base + size - 1) result.push(previous);
  }
  for (let i = 0; i < window; i++) result.push(`${toIP(base + size - 2 - ((offset + i) % window))}/${prefix}`);
  for (let n = base + size - 2 - window; n >= base + 2; n--) result.push(`${toIP(n)}/${prefix}`);
  return [...new Set(result)];
}

function hostMAC(seed) {
  const mac = crypto.createHash('sha256').update(seed).digest().subarray(0, 6);
  mac[0] = (mac[0] & 0xfe) | 0x02;
  return [...mac].map((n) => n.toString(16).padStart(2, '0')).join(':');
}

function hostReservation(subnet, ip) {
  return { cidr: parseSubnet(subnet).cidr, rangeStart: ip.split('/')[0], rangeEnd: ip.split('/')[0] };
}

module.exports = { DEFAULT_SUBNET, parseSubnet, addressCandidates, hostMAC, hostReservation };
