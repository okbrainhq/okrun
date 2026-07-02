#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const tls = require('node:tls');
const { spawn } = require('node:child_process');

const {
  CONTROL_STREAM_ID,
  DEFAULT_MAX_FRAME_SIZE,
  ETHERNET_STREAM_ID,
  FrameDecoder,
  FrameType,
  decodeJsonPayload,
  encodeFrame,
  encodeJsonFrame
} = require('../../src/protocol');

const READY_PREFIX = 'OKRUN_SWITCH_TAP_READY ';

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

function required(args, key) {
  const value = args[key];
  if (!value) {
    throw new Error(`Missing --${key}`);
  }
  return value;
}

class HelperTap {
  constructor(options) {
    this.options = options;
    this.child = null;
    this.stdout = Buffer.alloc(0);
    this.stderr = '';
    this.ready = false;
    this.closing = false;
    this.onFrame = () => {};
  }

  start() {
    const args = [
      this.options.helperPath,
      '--interface',
      this.options.tapName,
      '--ip',
      this.options.ipCidr,
      '--mtu',
      String(this.options.mtu),
      '--max-frame-size',
      String(this.options.maxFrameSize)
    ];

    this.child = spawn(this.options.python, args, {
      stdio: ['pipe', 'pipe', 'pipe']
    });
    this.child.stdout.on('data', (chunk) => this.handleStdout(chunk));
    this.child.stderr.on('data', (chunk) => this.handleStderr(chunk));
    this.child.once('error', (error) => {
      console.error(`OKRUN_TAP_CLIENT_HELPER_ERROR ${error.stack || error.message}`);
      process.exit(1);
    });
    this.child.once('exit', (code, signal) => {
      if (this.closing) {
        return;
      }
      console.error(`OKRUN_TAP_CLIENT_HELPER_EXIT code=${code} signal=${signal}`);
      process.exit(code || 1);
    });
  }

  handleStdout(chunk) {
    this.stdout = this.stdout.length === 0 ? chunk : Buffer.concat([this.stdout, chunk]);
    while (this.stdout.length >= 4) {
      const frameLength = this.stdout.readUInt32BE(0);
      if (frameLength > this.options.maxFrameSize) {
        throw new Error(`TAP frame too large: ${frameLength}`);
      }
      if (this.stdout.length < 4 + frameLength) {
        return;
      }
      const frame = this.stdout.subarray(4, 4 + frameLength);
      this.stdout = this.stdout.subarray(4 + frameLength);
      this.onFrame(frame);
    }
  }

  handleStderr(chunk) {
    this.stderr += chunk.toString('utf8');
    let newlineIndex;
    while ((newlineIndex = this.stderr.indexOf('\n')) >= 0) {
      const line = this.stderr.slice(0, newlineIndex).trim();
      this.stderr = this.stderr.slice(newlineIndex + 1);
      if (!line) {
        continue;
      }
      if (line.startsWith(READY_PREFIX)) {
        this.ready = true;
        console.log(`OKRUN_TAP_CLIENT_TAP_READY ${line.slice(READY_PREFIX.length)}`);
      } else {
        console.error(`OKRUN_TAP_CLIENT_HELPER_LOG ${line}`);
      }
    }
  }

  write(frame) {
    if (!this.child || !this.child.stdin.writable) {
      return false;
    }
    const header = Buffer.alloc(4);
    header.writeUInt32BE(frame.length, 0);
    return this.child.stdin.write(Buffer.concat([header, frame]));
  }

  close() {
    this.closing = true;
    if (!this.child || this.child.exitCode != null) {
      return;
    }
    this.child.stdin.end();
    this.child.kill('SIGTERM');
  }
}

class TapSwitchClient {
  constructor(options) {
    this.options = options;
    this.decoder = new FrameDecoder({ maxPayloadLength: options.maxFrameSize + 4096 });
    this.socket = null;
    this.tap = new HelperTap(options);
    this.seqNo = 0;
    this.initialized = false;
    this.closing = false;
  }

  start() {
    this.tap.onFrame = (frame) => this.sendData(frame);
    this.tap.start();
    this.connect();
  }

  connect() {
    this.socket = tls.connect({
      host: this.options.host,
      port: this.options.port,
      servername: this.options.servername,
      rejectUnauthorized: true,
      ca: fs.readFileSync(this.options.ca),
      cert: fs.readFileSync(this.options.cert),
      key: fs.readFileSync(this.options.key)
    });
    this.socket.once('secureConnect', () => this.sendInit());
    this.socket.on('data', (chunk) => this.handleSwitchChunk(chunk));
    this.socket.once('error', (error) => {
      console.error(`OKRUN_TAP_CLIENT_TLS_ERROR ${error.stack || error.message}`);
      process.exit(1);
    });
    this.socket.once('close', () => {
      if (this.closing) {
        return;
      }
      console.error('OKRUN_TAP_CLIENT_TLS_CLOSED');
      process.exit(1);
    });
  }

  sendInit() {
    this.socket.write(encodeJsonFrame(FrameType.INIT, {
      protocol: 'okrun-switch/1',
      nodeID: this.options.nodeID,
      networkIdentifier: this.options.networkIdentifier,
      interface: this.options.interfaceName,
      maxFrameSize: this.options.maxFrameSize,
      capabilities: ['ethernet-frame', 'tap-e2e-client']
    }));
  }

  handleSwitchChunk(chunk) {
    for (const frame of this.decoder.push(chunk)) {
      this.handleSwitchFrame(frame);
    }
  }

  handleSwitchFrame(frame) {
    if (frame.type === FrameType.PING) {
      this.socket.write(encodeFrame({
        streamId: CONTROL_STREAM_ID,
        type: FrameType.PONG,
        seqNo: 0,
        payload: Buffer.alloc(0)
      }));
      return;
    }

    if (frame.type === FrameType.INIT) {
      const ack = decodeJsonPayload(frame.payload);
      this.initialized = true;
      console.log(`OKRUN_TAP_CLIENT_SWITCH_READY ${JSON.stringify(ack)}`);
      this.waitTapReadyThenAnnounce();
      return;
    }

    if (frame.type === FrameType.DATA && frame.streamId === ETHERNET_STREAM_ID) {
      this.tap.write(frame.payload);
      return;
    }

    if (frame.type === FrameType.ERROR) {
      console.error(`OKRUN_TAP_CLIENT_SWITCH_ERROR ${frame.payload.toString('utf8')}`);
      process.exit(1);
    }
  }

  waitTapReadyThenAnnounce() {
    const startedAt = Date.now();
    const check = () => {
      if (this.tap.ready) {
        console.log('OKRUN_TAP_CLIENT_READY');
        return;
      }
      if (Date.now() - startedAt > 5000) {
        console.error('OKRUN_TAP_CLIENT_READY_TIMEOUT');
        process.exit(1);
      }
      setTimeout(check, 25).unref();
    };
    check();
  }

  sendData(payload) {
    if (!this.initialized || !this.socket || this.socket.destroyed) {
      return;
    }
    this.seqNo = this.seqNo >= 0xffffffff ? 1 : this.seqNo + 1;
    this.socket.write(encodeFrame({
      streamId: ETHERNET_STREAM_ID,
      type: FrameType.DATA,
      seqNo: this.seqNo,
      payload
    }));
  }

  close() {
    this.closing = true;
    this.tap.close();
    if (this.socket && !this.socket.destroyed) {
      this.socket.end();
    }
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const root = path.resolve(__dirname, '../..');
  const client = new TapSwitchClient({
    host: required(args, 'host'),
    port: Number(required(args, 'port')),
    servername: args.servername ?? 'localhost',
    ca: required(args, 'ca'),
    cert: required(args, 'cert'),
    key: required(args, 'key'),
    networkIdentifier: required(args, 'network'),
    nodeID: args['node-id'] ?? crypto.randomUUID(),
    interfaceName: args.interface ?? args['tap-iface'] ?? 'okhost0',
    tapName: args['tap-iface'] ?? 'okhost0',
    ipCidr: required(args, 'ip'),
    mtu: Number(args.mtu ?? 1500),
    maxFrameSize: Number(args['max-frame-size'] ?? DEFAULT_MAX_FRAME_SIZE),
    helperPath: path.resolve(args.helper ?? path.join(root, 'bin/okrun-switch-tap-helper.py')),
    python: args.python ?? process.env.PYTHON ?? 'python3'
  });

  const shutdown = () => {
    client.close();
    setTimeout(() => process.exit(0), 100).unref();
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
  client.start();
}

main();
