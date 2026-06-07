'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const tls = require('node:tls');
const { EventEmitter } = require('node:events');

const { DedupWindow } = require('../../src/dedup-window');
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

class TestSwitchClient extends EventEmitter {
  constructor(options) {
    super();
    this.name = options.name ?? 'client';
    this.port = options.port;
    this.transport = options.transport ?? 'tls';
    this.cert = options.cert;
    this.key = options.key;
    this.ca = options.ca;
    this.nodeID = options.nodeID ?? crypto.randomUUID();
    this.networkIdentifier = options.networkIdentifier ?? 'okrun';
    this.interfaceName = options.interfaceName ?? 'default';
    this.dhcpRange = options.dhcpRange;
    this.maxFrameSize = options.maxFrameSize ?? DEFAULT_MAX_FRAME_SIZE;
    this.autoPong = options.autoPong ?? true;
    this.udpPreference = options.udpPreference ?? 'tcp';
    this.clientRandom = options.clientRandom ?? crypto.randomBytes(32).toString('base64url');
    this.initAck = null;
    this.decoder = new FrameDecoder({ maxPayloadLength: Math.max(this.maxFrameSize, DEFAULT_MAX_FRAME_SIZE) + 4096 });
    this.seqNo = 0;
    this.frames = [];
    this.waiters = [];
    this.closed = false;
    this.socket = null;
  }

  async connect() {
    if (this.transport === 'tcp') {
      await this.connectTcp();
    } else {
      await this.connectTls();
    }
    return this.sendInit();
  }

  connectTls() {
    return new Promise((resolve, reject) => {
      const options = {
        host: '127.0.0.1',
        port: this.port,
        servername: 'localhost',
        rejectUnauthorized: true,
        ca: this.ca ? fs.readFileSync(this.ca) : undefined,
        cert: this.cert ? fs.readFileSync(this.cert) : undefined,
        key: this.key ? fs.readFileSync(this.key) : undefined
      };

      this.socket = tls.connect(options);
      this.socket.once('secureConnect', resolve);
      this.socket.once('error', reject);
      this.socket.on('data', (chunk) => this.handleChunk(chunk));
      this.socket.on('close', () => this.handleClose());
    });
  }

  connectTcp() {
    return new Promise((resolve, reject) => {
      const socket = net.connect({
        host: '127.0.0.1',
        port: this.port
      });

      this.socket = socket;
      socket.once('connect', resolve);
      socket.once('error', reject);
      socket.on('data', (chunk) => this.handleChunk(chunk));
      socket.on('close', () => this.handleClose());
    });
  }

  async sendInit() {
    const capabilities = ['ethernet-frame'];
    if (this.udpPreference !== 'tcp') {
      capabilities.push('udp-data-v1');
    }
    const payload = {
      protocol: 'okrun-switch/1',
      nodeID: this.nodeID,
      networkIdentifier: this.networkIdentifier,
      interface: this.interfaceName,
      maxFrameSize: this.maxFrameSize,
      dhcpRange: this.dhcpRange,
      capabilities,
      transportPreference: this.udpPreference
    };
    if (this.udpPreference !== 'tcp') {
      payload.clientRandom = this.clientRandom;
    }

    this.writeFrame(encodeJsonFrame(FrameType.INIT, payload));

    const frame = await this.waitForFrame(
      (candidate) => candidate.type === FrameType.INIT,
      1000,
      'INIT ACK'
    );
    this.initAck = decodeJsonPayload(frame.payload);
    return this.initAck;
  }

  handleChunk(chunk) {
    const frames = this.decoder.push(chunk);
    for (const frame of frames) {
      if (frame.type === FrameType.PING && this.autoPong) {
        this.writeFrame(encodeFrame({
          streamId: CONTROL_STREAM_ID,
          type: FrameType.PONG,
          seqNo: 0,
          payload: Buffer.alloc(0)
        }));
      }
      this.enqueueFrame(frame);
    }
  }

  enqueueFrame(frame) {
    for (let index = 0; index < this.waiters.length; index += 1) {
      const waiter = this.waiters[index];
      if (waiter.predicate(frame)) {
        this.waiters.splice(index, 1);
        clearTimeout(waiter.timer);
        waiter.resolve(frame);
        return;
      }
    }

    this.frames.push(frame);
    this.emit('frame', frame);
    if (frame.type === FrameType.DATA) {
      this.emit('dataFrame', frame);
    }
  }

  waitForFrame(predicate, timeoutMs = 1000, label = 'frame') {
    for (let index = 0; index < this.frames.length; index += 1) {
      const frame = this.frames[index];
      if (predicate(frame)) {
        this.frames.splice(index, 1);
        return Promise.resolve(frame);
      }
    }

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const waiterIndex = this.waiters.findIndex((waiter) => waiter.resolve === resolve);
        if (waiterIndex >= 0) {
          this.waiters.splice(waiterIndex, 1);
        }
        reject(new Error(`Timed out waiting for ${label} on ${this.name}`));
      }, timeoutMs);

      this.waiters.push({
        predicate,
        resolve,
        reject,
        timer
      });
    });
  }

  async waitForData(timeoutMs = 1000) {
    const frame = await this.waitForFrame(
      (candidate) => candidate.type === FrameType.DATA,
      timeoutMs,
      'DATA'
    );
    return frame;
  }

  async expectNoData(timeoutMs = 150) {
    try {
      const frame = await this.waitForData(timeoutMs);
      assert.fail(`Expected no DATA on ${this.name}, got seq ${frame.seqNo}`);
    } catch (error) {
      if (!/Timed out waiting/.test(error.message)) {
        throw error;
      }
    }
  }

  writeFrame(frame) {
    this.socket.write(frame);
  }

  sendData(payload, seqNo = null) {
    if (seqNo == null) {
      this.seqNo = this.seqNo >= 0xffffffff ? 1 : this.seqNo + 1;
      seqNo = this.seqNo;
    }

    const frame = encodeFrame({
      streamId: ETHERNET_STREAM_ID,
      type: FrameType.DATA,
      seqNo,
      payload
    });
    this.writeFrame(frame);
    return frame;
  }

  waitForClose(timeoutMs = 1000) {
    if (this.closed) {
      return Promise.resolve();
    }

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error(`Timed out waiting for ${this.name} to close`));
      }, timeoutMs);
      this.once('closed', () => {
        clearTimeout(timer);
        resolve();
      });
    });
  }

  handleClose() {
    this.closed = true;
    for (const waiter of this.waiters.splice(0)) {
      clearTimeout(waiter.timer);
      waiter.reject(new Error(`${this.name} closed while waiting for frame`));
    }
    this.emit('closed');
  }

  close() {
    if (!this.socket || this.socket.destroyed) {
      return;
    }
    this.socket.end();
    setTimeout(() => {
      if (this.socket && !this.socket.destroyed) {
        this.socket.destroy();
      }
    }, 25).unref();
  }
}

class LogicalHost {
  constructor(clients) {
    this.clients = clients;
    this.dedupByStream = new Map();
    this.frames = [];
    this.waiters = [];

    for (const client of clients) {
      client.on('dataFrame', (frame) => this.handleDataFrame(frame));
    }
  }

  handleDataFrame(frame) {
    let dedup = this.dedupByStream.get(frame.streamId);
    if (!dedup) {
      dedup = new DedupWindow();
      this.dedupByStream.set(frame.streamId, dedup);
    }

    if (!dedup.accept(frame.seqNo)) {
      return;
    }

    for (let index = 0; index < this.waiters.length; index += 1) {
      const waiter = this.waiters[index];
      this.waiters.splice(index, 1);
      clearTimeout(waiter.timer);
      waiter.resolve(frame);
      return;
    }

    this.frames.push(frame);
  }

  waitForData(timeoutMs = 1000) {
    if (this.frames.length > 0) {
      return Promise.resolve(this.frames.shift());
    }

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const index = this.waiters.findIndex((waiter) => waiter.resolve === resolve);
        if (index >= 0) {
          this.waiters.splice(index, 1);
        }
        reject(new Error('Timed out waiting for logical DATA'));
      }, timeoutMs);
      this.waiters.push({ resolve, reject, timer });
    });
  }

  async expectNoData(timeoutMs = 150) {
    try {
      await this.waitForData(timeoutMs);
      assert.fail('Expected no logical DATA');
    } catch (error) {
      if (!/Timed out waiting/.test(error.message)) {
        throw error;
      }
    }
  }
}

function ethernetFrame(destination, source, payload = 'payload') {
  return Buffer.concat([
    mac(destination),
    mac(source),
    Buffer.from([0x08, 0x00]),
    Buffer.isBuffer(payload) ? payload : Buffer.from(payload)
  ]);
}

function mac(value) {
  return Buffer.from(value.split(':').map((part) => Number.parseInt(part, 16)));
}

function parseErrorFrame(frame) {
  return decodeJsonPayload(frame.payload);
}

async function expectTlsRejected(options) {
  const decoder = new FrameDecoder();
  const socket = tls.connect({
    host: '127.0.0.1',
    port: options.port,
    servername: 'localhost',
    rejectUnauthorized: true,
    ca: fs.readFileSync(options.ca),
    cert: options.cert ? fs.readFileSync(options.cert) : undefined,
    key: options.key ? fs.readFileSync(options.key) : undefined
  });

  let secure = false;
  let closed = false;
  let errorSeen = false;
  let accepted = false;

  socket.once('secureConnect', () => {
    secure = true;
    socket.write(encodeJsonFrame(FrameType.INIT, {
      protocol: 'okrun-switch/1',
      nodeID: crypto.randomUUID(),
      networkIdentifier: 'rejected-client',
      interface: 'default',
      maxFrameSize: DEFAULT_MAX_FRAME_SIZE,
      capabilities: ['ethernet-frame']
    }));
  });
  socket.on('data', (chunk) => {
    for (const frame of decoder.push(chunk)) {
      if (frame.type === FrameType.INIT) {
        accepted = true;
      }
    }
  });
  socket.once('error', () => {
    errorSeen = true;
  });
  socket.once('close', () => {
    closed = true;
  });

  await new Promise((resolve, reject) => {
    const timer = setTimeout(resolve, 750);
    socket.once('close', () => {
      clearTimeout(timer);
      resolve();
    });
    socket.once('error', () => {
      clearTimeout(timer);
      resolve();
    });
    socket.once('timeout', reject);
  });

  assert.equal(accepted, false, 'rejected TLS client must not receive INIT ACK');
  assert.ok(errorSeen || closed || secure, 'TLS connection should not be usable');

  if (!closed) {
    socket.destroy();
  }
}

module.exports = {
  LogicalHost,
  TestSwitchClient,
  ethernetFrame,
  expectTlsRejected,
  parseErrorFrame
};
