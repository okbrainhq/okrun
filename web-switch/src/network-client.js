'use strict';

const crypto = require('node:crypto');
const net = require('node:net');
const tls = require('node:tls');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { EventEmitter } = require('node:events');
const { parseSubnet } = require('./host-address');
const { FrameDecoder, FrameType, encodeFrame, encodeJsonFrame, decodeJsonPayload } = require('./protocol');

function parseLocalEndpoint(server) {
  const match = /^(\[[0-9a-fA-F:]+\]|[a-zA-Z0-9][a-zA-Z0-9.-]*):(\d+)$/.exec(server);
  if (!match || +match[2] < 1 || +match[2] > 65535) throw new Error('Invalid local switch host:port');
  const host = match[1].replace(/^\[|\]$/g, '');
  if (host === '0.0.0.0' || host === '::' || (match[1][0] === '[' && net.isIP(host) !== 6)) {
    throw new Error('Local switch must use a reachable address');
  }
  return { host, port: +match[2] };
}

function validateConfig(config) {
  if (config.localServer !== undefined) parseLocalEndpoint(config.localServer);
  const bundle = config.bundle;
  if (!bundle || bundle.type !== 'host') throw new Error('A host certificate bundle is required');
  for (const key of ['caCertPem', 'clientCertPem', 'clientKeyPem']) {
    if (typeof bundle[key] !== 'string' || !bundle[key].trim()) throw new Error(`Missing bundle field: ${key}`);
  }
  const match = /^(\[[^\]]+\]|[^\s/:]+):(\d+)$/.exec(bundle.server || '');
  if (!match || +match[2] < 1 || +match[2] > 65535) throw new Error('Bundle server must be host:port or [IPv6]:port');
  const host = match[1].replace(/^\[|\]$/g, '');
  const network = config.network ?? 'okrun';
  if (!/^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,127}$/.test(network)) throw new Error('Invalid network identifier');
  const iface = config.interface ?? 'okrun0';
  if (!/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,14}$/.test(iface)) throw new Error('Invalid TAP interface name');
  const address = config.ip ?? 'auto';
  if (address === 'auto') parseSubnet(config.subnet);
  else {
    const [ip, prefix, extra] = String(address).split('/');
    const family = net.isIP(ip);
    if (!family || extra !== undefined || !/^\d+$/.test(prefix || '') || +prefix > (family === 4 ? 32 : 128)) {
      throw new Error('IP must be auto or an address in CIDR notation');
    }
  }
  if (config.mac && !/^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/i.test(config.mac)) throw new Error('Invalid MAC');
  const mtu = config.mtu ?? 1500;
  if (!Number.isInteger(mtu) || mtu < 1280 || mtu > 9000) throw new Error('MTU must be between 1280 and 9000');
  // Validate key/certificate material before creating a privileged interface.
  tls.createSecureContext({ ca: bundle.caCertPem, cert: bundle.clientCertPem, key: bundle.clientKeyPem });
  return { ...config, ip: address, bundle, host, port: +match[2], network, interface: iface, mtu };
}

// One outbound mTLS connection. The service manager restarts on failure, avoiding
// stale sequence state and rebuilding the non-persistent TAP on each attempt.
class NetworkClient extends EventEmitter {
  constructor(config, dependencies = {}) {
    super();
    this.config = validateConfig(config);
    this.spawn = dependencies.spawn ?? spawn;
    this.localEndpoint = dependencies.localEndpoint;
    this.frameOnly = dependencies.frameOnly ?? false;
    this.connect = dependencies.connect ?? (this.localEndpoint ? net.connect : tls.connect);
    this.nodeID = crypto.randomUUID();
    this.tapFrameSizeLimit = this.config.mtu + 64;
    this.maxFrameSize = Math.max(1500, this.tapFrameSizeLimit);
    this.decoder = new FrameDecoder({ maxPayloadLength: 74096 });
    this.tapBuffer = Buffer.alloc(0);
    this.logBuffer = '';
    this.seqNo = 0;
    this.ready = false;
    this.closed = false;
  }

  start() {
    const c = this.config;
    this.socket = this.connect(this.localEndpoint ?? {
      host: c.host, port: c.port,
      servername: net.isIP(c.host) ? undefined : c.host,
      rejectUnauthorized: true, minVersion: 'TLSv1.2',
      ca: c.bundle.caCertPem, cert: c.bundle.clientCertPem, key: c.bundle.clientKeyPem
    });
    this.timer = setTimeout(() => this.fail(new Error('Connection/INIT timed out')), 15000);
    this.socket.on('error', (error) => this.fail(error));
    this.socket.on('close', () => this.fail(new Error('Switch disconnected')));
    this.socket.on(this.localEndpoint ? 'connect' : 'secureConnect', () => {
      this.write(encodeJsonFrame(FrameType.INIT, {
        protocol: 'okrun-switch/1', nodeID: this.nodeID,
        networkIdentifier: c.network, interface: c.interface,
        maxFrameSize: this.maxFrameSize, capabilities: ['ethernet-frame'],
        ...(c.dhcpRange ? { dhcpRange: c.dhcpRange } : {})
      }));
    });
    this.socket.on('data', (chunk) => {
      try {
        for (const frame of this.decoder.push(chunk)) this.handleFrame(frame);
      } catch (error) { this.fail(error); }
    });
    return this;
  }

  write(frame) {
    if (this.closed) return;
    if (this.socket.writableLength + frame.length > 4194304) {
      this.fail(new Error('Switch write queue exceeded 4 MiB'));
      return;
    }
    this.socket.write(frame);
  }

  handleFrame(frame) {
    if (this.closed) return;
    if (frame.type === FrameType.ERROR) {
      const payload = decodeJsonPayload(frame.payload);
      const code = typeof payload.code === 'string' && /^[a-z_]{1,80}$/.test(payload.code) ? payload.code : 'switch_rejected';
      throw Object.assign(new Error(`Switch rejected the connection (${code})`), { code });
    }
    if (frame.type === FrameType.PING && frame.streamId === 0) {
      this.write(encodeFrame({ streamId: 0, type: FrameType.PONG }));
    } else if (frame.type === FrameType.INIT && frame.streamId === 0) {
      if (this.acknowledged) throw new Error('Duplicate INIT');
      const ack = decodeJsonPayload(frame.payload);
      if (ack.protocol !== 'okrun-switch/1' || !Number.isInteger(ack.maxFrameSize)
          || ack.maxFrameSize < 1500 || ack.maxFrameSize > this.maxFrameSize
          || !Number.isInteger(ack.keepaliveTimeoutMs) || ack.keepaliveTimeoutMs < 1
          || ack.keepaliveTimeoutMs > 3600000) throw new Error('Invalid INIT acknowledgment');
      this.acknowledged = true;
      this.maxFrameSize = ack.maxFrameSize;
      this.socket.setTimeout(Math.max(1000, ack.keepaliveTimeoutMs * 2), () => this.fail(new Error('Switch keepalive timed out')));
      if (this.frameOnly) {
        clearTimeout(this.timer);
        this.ready = true;
        this.emit('ready');
      } else this.startTap();
    } else if (frame.type === FrameType.DATA) {
      if (frame.streamId !== 1 || !this.acknowledged) throw new Error('Unexpected DATA frame');
      if (!(this.ready || this.probing) || frame.payload.length < 14
          || frame.payload.length > Math.min(this.maxFrameSize, this.tapFrameSizeLimit)) return;
      if (this.frameOnly) this.emit('frame', frame.payload);
      else this.injectFrame(frame.payload);
    }
  }

  injectFrame(payload) {
    const header = Buffer.alloc(4);
    header.writeUInt32BE(payload.length);
    if (this.child.stdin.writableLength + payload.length + 4 > 4194304) {
      throw new Error('TAP write queue exceeded 4 MiB');
    }
    this.child.stdin.write(Buffer.concat([header, payload]));
  }

  startTap() {
    const c = this.config;
    this.child = this.spawn('python3', [path.resolve(__dirname, '../bin/okrun-switch-tap-helper.py'),
      '--interface', c.interface, '--ip', c.ip, '--mtu', String(c.mtu),
      '--max-frame-size', String(this.maxFrameSize),
      ...(c.mac ? ['--mac', c.mac] : []), ...(c.probeAddress ? ['--probe-address'] : [])], { stdio: ['pipe', 'pipe', 'pipe'] });
    this.probing = Boolean(c.probeAddress);
    this.child.on('error', (error) => this.fail(error));
    this.child.on('exit', () => this.fail(new Error('TAP helper exited')));
    this.child.stdin.on('error', (error) => this.fail(error));
    this.child.stdout.on('data', (chunk) => {
      try { this.handleTap(chunk); } catch (error) { this.fail(error); }
    });
    this.child.stderr.on('data', (chunk) => {
      this.logBuffer += chunk.toString('utf8');
      if (this.logBuffer.length > 65536) return this.fail(new Error('TAP helper log overflow'));
      let end;
      while ((end = this.logBuffer.indexOf('\n')) >= 0) {
        const line = this.logBuffer.slice(0, end);
        this.logBuffer = this.logBuffer.slice(end + 1);
        if (line.startsWith('OKRUN_SWITCH_ADDRESS_CONFLICT')) {
          return this.fail(Object.assign(new Error('Automatic host address is already in use'), { code: 'address_conflict' }));
        }
        if (line.startsWith('OKRUN_SWITCH_TAP_READY ') && !this.ready && !this.closed) {
          clearTimeout(this.timer);
          this.probing = false;
          this.ready = true;
          this.emit('ready');
        } else { this.emit('log', line); }
      }
    });
  }

  handleTap(chunk) {
    if (this.closed) return;
    this.tapBuffer = Buffer.concat([this.tapBuffer, chunk]);
    while (this.tapBuffer.length >= 4) {
      const length = this.tapBuffer.readUInt32BE(0);
      if (length > this.maxFrameSize) throw new Error('Oversized TAP frame');
      if (this.tapBuffer.length < length + 4) return;
      const payload = this.tapBuffer.subarray(4, length + 4);
      this.tapBuffer = this.tapBuffer.subarray(length + 4);
      if (length < 14 || !(this.ready || this.probing)) continue;
      this.sendEthernet(payload);
    }
  }

  sendEthernet(payload) {
    if (!(this.ready || this.probing) || this.closed || payload.length > this.maxFrameSize) return;
    if (this.seqNo === 0xffffffff) return this.fail(new Error('Sequence exhausted; reconnect required'));
    this.write(encodeFrame({ streamId: 1, type: FrameType.DATA, seqNo: ++this.seqNo, payload }));
  }

  fail(error) {
    if (this.closed) return;
    this.close();
    this.emit('failure', error);
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    this.ready = false;
    this.probing = false;
    clearTimeout(this.timer);
    this.socket?.destroy();
    if (this.child) {
      const child = this.child;
      child.stdin.destroy();
      child.kill('SIGTERM');
      const timer = setTimeout(() => {
        if (child.exitCode == null && child.signalCode == null) child.kill('SIGKILL');
      }, 1000);
      timer.unref();
      child.once('exit', () => clearTimeout(timer));
    }
  }
}

module.exports = { NetworkClient, validateConfig, parseLocalEndpoint };
