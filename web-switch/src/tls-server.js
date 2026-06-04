'use strict';

const fs = require('node:fs');
const net = require('node:net');
const tls = require('node:tls');

const { SwitchFabric, AdmissionError } = require('./switch-fabric');
const {
  CONTROL_STREAM_ID,
  DEFAULT_MAX_FRAME_SIZE,
  FrameDecoder,
  FrameType,
  ProtocolError,
  decodeJsonPayload,
  encodeFrame,
  encodeJsonFrame
} = require('./protocol');

class RevocationList {
  constructor(path) {
    this.path = path;
    this.mtimeMs = null;
    this.serials = new Set();
  }

  isRevoked(serial) {
    this.reloadIfNeeded();
    return this.serials.has(normalizeSerial(serial));
  }

  reloadIfNeeded() {
    if (!this.path) {
      return;
    }

    let stat;
    try {
      stat = fs.statSync(this.path);
    } catch (error) {
      if (error.code === 'ENOENT') {
        this.mtimeMs = null;
        this.serials = new Set();
        return;
      }
      throw error;
    }

    if (this.mtimeMs === stat.mtimeMs) {
      return;
    }

    const text = fs.readFileSync(this.path, 'utf8');
    const serials = new Set();
    for (const line of text.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) {
        continue;
      }
      serials.add(normalizeSerial(trimmed.split(/\s+/)[0]));
    }

    this.mtimeMs = stat.mtimeMs;
    this.serials = serials;
  }
}

class SwitchTLSServer {
  constructor(options) {
    this.options = {
      host: options.host ?? '0.0.0.0',
      tlsPort: options.tlsPort ?? 9443,
      keepaliveIntervalMs: options.keepaliveIntervalMs ?? 10000,
      keepaliveTimeoutMs: options.keepaliveTimeoutMs ?? 25000,
      initTimeoutMs: options.initTimeoutMs ?? 10000,
      maxFrameSize: options.maxFrameSize ?? DEFAULT_MAX_FRAME_SIZE,
      maxPendingWrites: options.maxPendingWrites ?? 256,
      maxPendingBytes: options.maxPendingBytes ?? 4 * 1024 * 1024,
      logger: options.logger ?? console
    };

    this.fabric = options.fabric ?? new SwitchFabric({
      maxFrameSize: this.options.maxFrameSize,
      maxConnectionsPerHost: options.maxConnectionsPerHost,
      macTtlMs: options.macTtlMs
    });

    this.revocationList = new RevocationList(options.crlPath);

    this.server = tls.createServer(
      {
        key: readPEMOption(options.serverKeyPem, options.serverKeyPath, 'server key'),
        cert: readPEMOption(options.serverCertPem, options.serverCertPath, 'server certificate'),
        ca: readPEMOption(options.caCertPem, options.caCertPath, 'CA certificate'),
        requestCert: true,
        rejectUnauthorized: true,
        minVersion: 'TLSv1.2'
      },
      (socket) => this.handleSocket(socket)
    );

    this.server.on('tlsClientError', (error) => {
      this.log('reject', { code: 'tls_client_error', message: error.message });
    });
  }

  listen(callback) {
    this.server.listen(this.options.tlsPort, this.options.host, callback);
  }

  close(callback) {
    this.server.close(callback);
  }

  address() {
    return this.server.address();
  }

  handleSocket(socket) {
    socket.setNoDelay(true);

    const peer = socket.getPeerCertificate();
    const identity = {
      clientSerial: normalizeSerial(peer.serialNumber),
      clientFingerprint: peer.fingerprint256 ?? '',
      kind: 'tls'
    };

    if (!socket.authorized) {
      this.log('reject', {
        code: 'unauthorized_client_certificate',
        message: socket.authorizationError
      });
      socket.destroy();
      return;
    }

    if (this.revocationList.isRevoked(identity.clientSerial)) {
      this.log('reject', {
        code: 'certificate_revoked',
        clientSerial: identity.clientSerial
      });
      writeErrorAndEnd(socket, {
        code: 'certificate_revoked',
        message: 'Client certificate is revoked'
      });
      return;
    }

    const connection = new SwitchConnection({
      socket,
      identity,
      fabric: this.fabric,
      options: this.options,
      logger: this.options.logger
    });
    connection.start();
  }

  log(event, fields) {
    if (!this.options.logger || typeof this.options.logger.log !== 'function') {
      return;
    }

    this.options.logger.log(JSON.stringify({
      event,
      ...fields
    }));
  }
}

class SwitchLocalServer {
  constructor(options) {
    this.options = {
      host: options.host ?? '0.0.0.0',
      localPort: options.localPort,
      keepaliveIntervalMs: options.localKeepaliveIntervalMs ?? 500,
      keepaliveTimeoutMs: options.localKeepaliveTimeoutMs ?? 1500,
      initTimeoutMs: options.initTimeoutMs ?? 10000,
      maxFrameSize: options.maxFrameSize ?? DEFAULT_MAX_FRAME_SIZE,
      maxPendingWrites: options.maxPendingWrites ?? 256,
      maxPendingBytes: options.maxPendingBytes ?? 4 * 1024 * 1024,
      logger: options.logger ?? console
    };

    this.fabric = options.fabric ?? new SwitchFabric({
      maxFrameSize: this.options.maxFrameSize,
      maxConnectionsPerHost: options.maxConnectionsPerHost,
      macTtlMs: options.macTtlMs
    });

    this.server = net.createServer((socket) => this.handleSocket(socket));
    this.server.on('error', (error) => {
      this.log('local_error', { code: error.code, message: error.message });
    });
  }

  listen(callback) {
    this.server.listen(this.options.localPort, this.options.host, callback);
  }

  close(callback) {
    this.server.close(callback);
  }

  address() {
    return this.server.address();
  }

  handleSocket(socket) {
    socket.setNoDelay(true);

    const connection = new SwitchConnection({
      socket,
      identity: {
        clientSerial: 'local-switch',
        clientFingerprint: '',
        kind: 'local'
      },
      fabric: this.fabric,
      options: this.options,
      logger: this.options.logger
    });
    connection.start();
  }

  log(event, fields) {
    if (!this.options.logger || typeof this.options.logger.log !== 'function') {
      return;
    }

    this.options.logger.log(JSON.stringify({
      event,
      ...fields
    }));
  }
}

class SwitchConnection {
  constructor({ socket, identity, fabric, options, logger }) {
    this.socket = socket;
    this.identity = identity;
    this.fabric = fabric;
    this.options = options;
    this.logger = logger;
    this.decoder = new FrameDecoder({ maxPayloadLength: options.maxFrameSize });
    this.initialized = false;
    this.closed = false;
    this.session = null;
    this.networkKey = null;
    this.nodeID = null;
    this.interfaceName = null;
    this.negotiatedMaxFrameSize = options.maxFrameSize;
    this.lastPongAt = Date.now();
    this.initTimer = null;
    this.keepaliveTimer = null;
    this.closing = false;
    this.backpressured = false;
    this.drainHandlerAttached = false;
    this.pendingWrites = [];
    this.pendingWriteBytes = 0;
    this.droppedWrites = 0;
  }

  start() {
    this.initTimer = setTimeout(() => {
      this.closeWithError({
        code: 'init_timeout',
        message: 'INIT was not received before the timeout'
      });
    }, this.options.initTimeoutMs);

    this.socket.on('data', (chunk) => this.handleDataChunk(chunk));
    this.socket.on('close', () => this.handleClose());
    this.socket.on('error', () => {});
  }

  handleDataChunk(chunk) {
    if (this.closing) {
      return;
    }

    let frames;
    try {
      frames = this.decoder.push(chunk);
      for (const frame of frames) {
        this.handleFrame(frame);
      }
    } catch (error) {
      const code = error.code || 'protocol_error';
      this.log('reject', {
        code,
        clientSerial: this.identity.clientSerial,
        nodeID: this.nodeID,
        network: this.networkKey,
        message: error.message
      });
      this.closeWithError({ code, message: error.message });
    }
  }

  handleFrame(frame) {
    if (frame.type === FrameType.PING) {
      this.sendFrame({
        streamId: CONTROL_STREAM_ID,
        type: FrameType.PONG,
        seqNo: 0,
        payload: Buffer.alloc(0)
      });
      return;
    }

    if (frame.type === FrameType.PONG) {
      this.lastPongAt = Date.now();
      return;
    }

    if (!this.initialized) {
      if (frame.type !== FrameType.INIT || frame.streamId !== CONTROL_STREAM_ID) {
        throw new ProtocolError('data_before_init', 'INIT must be the first non-keepalive frame');
      }

      this.handleInit(frame);
      return;
    }

    if (frame.type === FrameType.INIT) {
      throw new ProtocolError('duplicate_init', 'INIT has already been accepted');
    }

    if (frame.type === FrameType.DATA) {
      const result = this.fabric.handleData(this, frame);
      if (process.env.OKRUN_SWITCH_DEBUG === '1') {
        this.log('data', {
          clientSerial: this.identity.clientSerial,
          nodeID: this.nodeID,
          network: this.networkKey,
          seqNo: frame.seqNo,
          bytes: frame.payload.length,
          duplicate: result.duplicate,
          forwarded: result.forwarded
        });
      }
      return;
    }

    if (frame.type === FrameType.RESET_SEQ) {
      this.fabric.handleResetSeq(this, frame);
      return;
    }

    if (frame.type === FrameType.MEMBER_UPDATE) {
      return;
    }

    throw new ProtocolError('unsupported_frame_type', `Unsupported frame type ${frame.type}`);
  }

  handleInit(frame) {
    let initPayload;
    try {
      initPayload = decodeJsonPayload(frame.payload);
    } catch (error) {
      throw new ProtocolError(error.code, error.message);
    }

    let result;
    try {
      result = this.fabric.admitConnection(initPayload, this.identity, this);
    } catch (error) {
      if (error instanceof AdmissionError) {
        this.log('reject', {
          code: error.code,
          clientSerial: this.identity.clientSerial,
          message: error.message
        });
        this.closeWithError({ code: error.code, message: error.message });
        return;
      }
      throw error;
    }

    this.initialized = true;
    clearTimeout(this.initTimer);
    this.initTimer = null;

    this.sendEncodedFrame(encodeJsonFrame(FrameType.INIT, {
      protocol: 'okrun-switch/1',
      maxFrameSize: this.negotiatedMaxFrameSize,
      maxConnectionsPerHost: this.fabric.maxConnectionsPerHost,
      keepaliveIntervalMs: this.options.keepaliveIntervalMs,
      keepaliveTimeoutMs: this.options.keepaliveTimeoutMs,
      networkMemberCount: result.memberCounts.networkMemberCount,
      localMemberCount: result.memberCounts.localMemberCount
    }));

    this.log('connect', {
      clientSerial: this.identity.clientSerial,
      nodeID: this.nodeID,
      interface: this.interfaceName,
      network: this.networkKey
    });

    this.fabric.broadcastMemberUpdate(this.networkKey);
    this.startKeepalive();
  }

  startKeepalive() {
    this.keepaliveTimer = setInterval(() => {
      const age = Date.now() - this.lastPongAt;
      if (age > this.options.keepaliveTimeoutMs) {
        this.closeWithError({
          code: 'keepalive_timeout',
          message: 'PONG was not received before the keepalive timeout'
        });
        return;
      }

      this.sendFrame({
        streamId: CONTROL_STREAM_ID,
        type: FrameType.PING,
        seqNo: 0,
        payload: Buffer.alloc(0)
      });
    }, this.options.keepaliveIntervalMs);
  }

  writeEncodedFrame(encoded) {
    if (this.closed || this.socket.destroyed || !this.socket.writable) {
      return false;
    }

    if (this.backpressured || this.pendingWrites.length > 0) {
      return this.enqueueEncodedFrame(encoded);
    }

    const accepted = this.socket.write(encoded);
    if (!accepted) {
      this.backpressured = true;
      this.attachDrainHandler();
    }
    return true;
  }

  sendEncodedFrame(encoded) {
    this.writeEncodedFrame(encoded);
  }

  sendFrame(frame) {
    this.sendEncodedFrame(encodeFrame(frame));
  }

  enqueueEncodedFrame(encoded) {
    if (
      this.options.maxPendingWrites > 0
      && this.pendingWrites.length >= this.options.maxPendingWrites
    ) {
      this.recordDroppedWrite('pending_write_count_limit', encoded.length);
      return false;
    }

    if (
      this.options.maxPendingBytes > 0
      && this.pendingWriteBytes + encoded.length > this.options.maxPendingBytes
    ) {
      this.recordDroppedWrite('pending_write_byte_limit', encoded.length);
      return false;
    }

    this.pendingWrites.push(encoded);
    this.pendingWriteBytes += encoded.length;
    this.attachDrainHandler();
    return true;
  }

  attachDrainHandler() {
    if (this.drainHandlerAttached || this.closed || this.socket.destroyed) {
      return;
    }

    this.drainHandlerAttached = true;
    this.socket.once('drain', () => {
      this.drainHandlerAttached = false;
      this.backpressured = false;
      this.flushPendingWrites();
    });
  }

  flushPendingWrites() {
    while (
      this.pendingWrites.length > 0
      && !this.closed
      && !this.socket.destroyed
      && this.socket.writable
    ) {
      const encoded = this.pendingWrites.shift();
      this.pendingWriteBytes -= encoded.length;
      const accepted = this.socket.write(encoded);
      if (!accepted) {
        this.backpressured = true;
        this.attachDrainHandler();
        return;
      }
    }
  }

  clearPendingWrites() {
    this.pendingWrites = [];
    this.pendingWriteBytes = 0;
    this.backpressured = false;
  }

  recordDroppedWrite(reason, byteCount) {
    this.droppedWrites += 1;
    if (this.droppedWrites === 1 || this.droppedWrites % 100 === 0) {
      this.log('drop', {
        code: reason,
        clientSerial: this.identity.clientSerial,
        nodeID: this.nodeID,
        network: this.networkKey,
        interface: this.interfaceName,
        droppedWrites: this.droppedWrites,
        bytes: byteCount
      });
    }
  }

  closeWithError(error) {
    if (this.closed || this.closing || this.socket.destroyed) {
      return;
    }

    this.closing = true;

    try {
      this.sendEncodedFrame(encodeJsonFrame(FrameType.ERROR, error));
    } catch (_) {
      // Closing is best-effort once protocol state is already bad.
    }

    this.socket.end();
    setTimeout(() => {
      if (!this.socket.destroyed) {
        this.socket.destroy();
      }
    }, 100).unref();
  }

  handleClose() {
    if (this.closed) {
      return;
    }

    this.closed = true;
    clearTimeout(this.initTimer);
    clearInterval(this.keepaliveTimer);
    this.clearPendingWrites();
    this.fabric.removeConnection(this);

    if (this.initialized) {
      this.log('disconnect', {
        clientSerial: this.identity.clientSerial,
        nodeID: this.nodeID,
        interface: this.interfaceName,
        network: this.networkKey
      });
    }
  }

  log(event, fields) {
    if (!this.logger || typeof this.logger.log !== 'function') {
      return;
    }

    this.logger.log(JSON.stringify({
      event,
      ...fields
    }));
  }
}

function writeErrorAndEnd(socket, error) {
  socket.write(encodeJsonFrame(FrameType.ERROR, error), () => {
    socket.end();
  });
  setTimeout(() => {
    if (!socket.destroyed) {
      socket.destroy();
    }
  }, 100).unref();
}

function readPEMOption(inlinePEM, filePath, label) {
  if (inlinePEM) {
    return inlinePEM;
  }
  if (filePath) {
    return fs.readFileSync(filePath);
  }
  throw new Error(`Missing ${label}`);
}

function normalizeSerial(serial) {
  const clean = String(serial ?? '').replace(/[^0-9a-f]/gi, '');
  if (!clean) {
    return '0';
  }

  const parsed = Number.parseInt(clean, 16);
  return Number.isFinite(parsed) ? String(parsed) : '0';
}

module.exports = {
  RevocationList,
  SwitchConnection,
  SwitchLocalServer,
  SwitchTLSServer,
  normalizeSerial
};
