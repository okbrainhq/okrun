'use strict';

const crypto = require('node:crypto');
const dgram = require('node:dgram');

const { ETHERNET_STREAM_ID, FrameType } = require('./protocol');

const UDP_MAGIC = Buffer.from('OKSU');
const UDP_VERSION = 1;
const UDP_HEADER_SIZE = 40;
const UDP_AUTH_TAG_SIZE = 16;
const UDP_PACKET_OVERHEAD = UDP_HEADER_SIZE + UDP_AUTH_TAG_SIZE;
const UDP_PROTOCOL_LABEL = 'okrun-switch udp-data-v1';
const DEFAULT_SESSION_ID_BYTES = 16;
const DEFAULT_REPLAY_WINDOW = 4096;

const UdpPacketType = Object.freeze({
  PROBE: 1,
  PROBE_ACK: 2,
  DATA: 3,
  FRAGMENT: 4,
  KEEPALIVE: 5,
  KEEPALIVE_ACK: 6,
  PMTU_PROBE: 7,
  PMTU_PROBE_ACK: 8
});

class SwitchUDPDataPlane {
  constructor(options = {}) {
    this.options = {
      enabled: options.enabled === true,
      host: options.host ?? '0.0.0.0',
      port: options.port ?? 9443,
      mtu: options.mtu ?? 1200,
      minMtu: options.minMtu ?? 1200,
      maxProbeMtu: options.maxProbeMtu ?? 1450,
      initialMbps: options.initialMbps ?? 10,
      minMbps: options.minMbps ?? 0.25,
      maxMbps: options.maxMbps ?? 0,
      queueBytes: options.queueBytes ?? 4 * 1024 * 1024,
      queueFrames: options.queueFrames ?? 4096,
      reassemblySessionBytes: options.reassemblySessionBytes ?? 1024 * 1024,
      reassemblySessionFrames: options.reassemblySessionFrames ?? 64,
      reassemblyGlobalBytes: options.reassemblyGlobalBytes ?? 64 * 1024 * 1024,
      reassemblyGlobalFrames: options.reassemblyGlobalFrames ?? 4096,
      fragmentTimeoutMs: options.fragmentTimeoutMs ?? 1000,
      duplicateFragmentTtlMs: options.duplicateFragmentTtlMs ?? 2000,
      replayWindow: options.replayWindow ?? DEFAULT_REPLAY_WINDOW,
      unhealthyTimeoutMs: options.unhealthyTimeoutMs ?? 45000,
      cleanupGraceMs: options.cleanupGraceMs ?? 10000,
      recvBufferBytes: options.recvBufferBytes ?? 4 * 1024 * 1024,
      sendBufferBytes: options.sendBufferBytes ?? 4 * 1024 * 1024,
      logger: options.logger ?? console,
      serverIdentity: options.serverIdentity ?? 'server'
    };

    this.socket = null;
    this.sessions = new Map();
    this.globalReassemblyBytes = 0;
    this.globalReassemblyFrames = 0;
    this.started = false;
    this.boundAddress = null;
    this.bindError = null;
    this.socketBuffers = { recv: null, send: null };
    this.counters = {
      rxPackets: 0,
      rxBytes: 0,
      txPackets: 0,
      txBytes: 0,
      rxDataFrames: 0,
      txDataFrames: 0,
      unknownSessionDrops: 0,
      invalidPacketDrops: 0,
      invalidTagDrops: 0,
      replayDrops: 0,
      endpointDrops: 0,
      queueDrops: 0,
      fragmentDrops: 0,
      fragmentTimeoutDrops: 0,
      duplicateDrops: 0,
      pmtuProbeSuccess: 0,
      pmtuProbeFailure: 0,
      fallbackSends: 0
    };
  }

  get enabled() {
    return this.options.enabled;
  }

  listen(callback) {
    if (!this.options.enabled) {
      if (callback) {
        process.nextTick(callback);
      }
      return;
    }

    if (this.started) {
      if (callback) {
        process.nextTick(callback);
      }
      return;
    }

    if (this.socket) {
      if (callback) {
        process.nextTick(() => callback(this.bindError));
      }
      return;
    }

    const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true });
    let callbackCalled = false;
    const finish = (error = null) => {
      if (callback && !callbackCalled) {
        callbackCalled = true;
        callback(error);
      }
    };
    this.socket = socket;
    this.bindError = null;

    socket.on('message', (message, remoteInfo) => this.handleMessage(message, remoteInfo));
    socket.on('error', (error) => {
      this.log('udp_error', { code: error.code, message: error.message });
      if (!this.started) {
        this.bindError = { code: error.code, message: error.message };
        this.options.enabled = false;
        this.socket = null;
        this.boundAddress = null;
        try {
          socket.close();
        } catch (_) {
          // Socket may already be closed after a bind failure.
        }
        finish(error);
      }
    });
    socket.on('listening', () => {
      trySetSocketBuffer(socket, 'recv', this.options.recvBufferBytes);
      trySetSocketBuffer(socket, 'send', this.options.sendBufferBytes);
      this.socketBuffers.recv = tryGetSocketBuffer(socket, 'recv');
      this.socketBuffers.send = tryGetSocketBuffer(socket, 'send');
      this.boundAddress = socket.address();
      this.started = true;
      this.bindError = null;
      this.log('udp_listening', {
        host: this.boundAddress.address,
        port: this.boundAddress.port,
        recvBufferBytes: this.socketBuffers.recv,
        sendBufferBytes: this.socketBuffers.send
      });
      finish();
    });

    socket.bind(this.options.port, this.options.host);
  }

  close(callback) {
    for (const session of this.sessions.values()) {
      session.close();
    }
    this.sessions.clear();

    if (!this.socket) {
      if (callback) {
        process.nextTick(callback);
      }
      return;
    }

    const socket = this.socket;
    this.socket = null;
    this.started = false;
    try {
      socket.close(callback);
    } catch (_) {
      if (callback) {
        process.nextTick(callback);
      }
    }
  }

  createSession(connection, initPayload) {
    if (!this.options.enabled || !this.started || !this.socket || connection.identity?.kind !== 'tls') {
      return null;
    }

    const capabilities = Array.isArray(initPayload?.capabilities)
      ? initPayload.capabilities
      : [];
    const preference = normalizeTransportPreference(initPayload?.transportPreference);
    if (preference === 'tcp' || !capabilities.includes('udp-data-v1')) {
      return null;
    }

    const clientRandom = decodeBase64Url(initPayload?.clientRandom);
    if (!clientRandom || clientRandom.length < 16) {
      this.log('udp_declined', {
        code: 'missing_client_random',
        clientSerial: connection.identity?.clientSerial,
        nodeID: connection.nodeID
      });
      return null;
    }

    const sessionId = crypto.randomBytes(DEFAULT_SESSION_ID_BYTES);
    const serverRandom = crypto.randomBytes(32);
    const clientIdentity = connection.identity?.clientFingerprint || connection.identity?.clientSerial || 'client';
    const keys = deriveUDPKeys({
      clientRandom,
      serverRandom,
      sessionId,
      keyId: 1,
      clientIdentity,
      serverIdentity: this.options.serverIdentity
    });

    const session = new SwitchUDPSession({
      dataPlane: this,
      connection,
      preference,
      sessionId,
      keyId: 1,
      keys,
      clientRandom,
      serverRandom,
      clientIdentity,
      serverIdentity: this.options.serverIdentity,
      mtu: this.options.mtu,
      minMtu: this.options.minMtu,
      maxProbeMtu: this.options.maxProbeMtu
    });

    this.sessions.set(session.sessionIdString, session);
    return session;
  }

  closeSession(session) {
    if (!session) {
      return;
    }

    session.ready = false;
    session.connection = null;
    session.close();
    const sessionIdString = session.sessionIdString;
    setTimeout(() => {
      if (this.sessions.get(sessionIdString) === session) {
        this.sessions.delete(sessionIdString);
      }
    }, this.options.cleanupGraceMs).unref();
  }

  sendData(session, payload, seqNo) {
    if (!session || !session.ready || !this.started || !this.socket) {
      this.counters.fallbackSends += 1;
      return false;
    }

    if (session.isUnhealthy()) {
      session.ready = false;
      session.lastFallbackReason = 'udp_unhealthy';
      this.counters.fallbackSends += 1;
      return false;
    }

    const packets = session.encodeDataPackets(payload, seqNo);
    if (!packets || packets.length === 0) {
      return false;
    }

    for (const packet of packets) {
      if (!session.pacer.enqueue(packet, session.endpoint)) {
        session.counters.queueDrops += 1;
        this.counters.queueDrops += 1;
        return false;
      }
    }

    session.counters.txDataFrames += 1;
    this.counters.txDataFrames += 1;
    return true;
  }

  sendPacket(packet, endpoint) {
    if (!this.started || !this.socket || !endpoint) {
      return false;
    }

    this.socket.send(packet, endpoint.port, endpoint.address, (error) => {
      if (error) {
        this.log('udp_send_error', { code: error.code, message: error.message });
      }
    });
    this.counters.txPackets += 1;
    this.counters.txBytes += packet.length;
    return true;
  }

  handleMessage(message, remoteInfo) {
    this.counters.rxPackets += 1;
    this.counters.rxBytes += message.length;

    const parsed = parseUDPPacket(message);
    if (!parsed) {
      this.counters.invalidPacketDrops += 1;
      return;
    }

    const session = this.sessions.get(base64UrlEncode(parsed.sessionId));
    if (!session) {
      this.counters.unknownSessionDrops += 1;
      return;
    }

    let plaintext;
    try {
      plaintext = decryptPacket(parsed, session.keys.c2s);
    } catch (_) {
      session.counters.invalidTagDrops += 1;
      this.counters.invalidTagDrops += 1;
      return;
    }

    if (!session.replayWindow.accept(parsed.packetNumber)) {
      session.counters.replayDrops += 1;
      this.counters.replayDrops += 1;
      return;
    }

    if (!session.acceptEndpoint(remoteInfo, parsed.type)) {
      session.counters.endpointDrops += 1;
      this.counters.endpointDrops += 1;
      return;
    }

    session.lastValidUdpAt = Date.now();
    session.counters.rxPackets += 1;
    session.counters.rxBytes += message.length;

    switch (parsed.type) {
    case UdpPacketType.PROBE:
      session.learnEndpoint(remoteInfo);
      session.ready = true;
      session.lastFallbackReason = null;
      session.sendControl(UdpPacketType.PROBE_ACK, Buffer.from('ok'));
      break;
    case UdpPacketType.DATA:
      this.handleDataPacket(session, plaintext);
      break;
    case UdpPacketType.FRAGMENT:
      this.handleFragmentPacket(session, parsed, plaintext);
      break;
    case UdpPacketType.KEEPALIVE:
      session.sendControl(UdpPacketType.KEEPALIVE_ACK, Buffer.alloc(0));
      break;
    case UdpPacketType.PMTU_PROBE:
      // Adaptive PMTU probing is intentionally disabled in v1. Use the fixed
      // configured MTU until padded probe/ACK packets are implemented safely.
      session.counters.invalidPacketDrops += 1;
      this.counters.pmtuProbeFailure += 1;
      break;
    case UdpPacketType.PROBE_ACK:
    case UdpPacketType.KEEPALIVE_ACK:
    case UdpPacketType.PMTU_PROBE_ACK:
      // Server does not initiate these in v1.
      break;
    default:
      this.counters.invalidPacketDrops += 1;
      break;
    }
  }

  handleDataPacket(session, plaintext) {
    if (plaintext.length < 4) {
      session.counters.invalidPacketDrops += 1;
      this.counters.invalidPacketDrops += 1;
      return;
    }

    const seqNo = plaintext.readUInt32BE(0);
    const payload = plaintext.subarray(4);
    if (payload.length === 0) {
      session.counters.invalidPacketDrops += 1;
      this.counters.invalidPacketDrops += 1;
      return;
    }

    this.deliverFrame(session, seqNo, payload);
  }

  handleFragmentPacket(session, parsed, plaintext) {
    const result = session.reassembler.accept(parsed, plaintext);
    if (result.dropReason) {
      session.counters.fragmentDrops += 1;
      this.counters.fragmentDrops += 1;
      if (result.dropReason === 'duplicate_completed_fragment') {
        session.counters.duplicateDrops += 1;
        this.counters.duplicateDrops += 1;
      }
      return;
    }

    if (result.frame) {
      this.deliverFrame(session, result.frame.seqNo, result.frame.payload);
    }
  }

  deliverFrame(session, seqNo, payload) {
    const connection = session.connection;
    if (!connection || connection.closed || !connection.initialized) {
      return;
    }

    const result = connection.fabric.handleData(connection, {
      streamId: ETHERNET_STREAM_ID,
      type: FrameType.DATA,
      seqNo,
      payload
    });
    session.counters.rxDataFrames += 1;
    this.counters.rxDataFrames += 1;

    if (process.env.OKRUN_SWITCH_DEBUG === '1') {
      connection.log('udp_data', {
        clientSerial: connection.identity.clientSerial,
        nodeID: connection.nodeID,
        network: connection.networkKey,
        seqNo,
        bytes: payload.length,
        duplicate: result.duplicate,
        forwarded: result.forwarded
      });
    }
  }

  addGlobalReassembly(bytes) {
    if (
      this.globalReassemblyFrames + 1 > this.options.reassemblyGlobalFrames
      || this.globalReassemblyBytes + bytes > this.options.reassemblyGlobalBytes
    ) {
      return false;
    }
    this.globalReassemblyFrames += 1;
    this.globalReassemblyBytes += bytes;
    return true;
  }

  releaseGlobalReassembly(bytes) {
    this.globalReassemblyFrames = Math.max(0, this.globalReassemblyFrames - 1);
    this.globalReassemblyBytes = Math.max(0, this.globalReassemblyBytes - bytes);
  }

  status() {
    const sessions = Array.from(this.sessions.values()).map((session) => session.status());
    return {
      enabled: this.options.enabled,
      bound: this.started,
      bindError: this.bindError,
      sockets: this.boundAddress ? [this.boundAddress] : [],
      recvBufferBytes: this.socketBuffers.recv,
      sendBufferBytes: this.socketBuffers.send,
      activeSessions: sessions.length,
      mtu: this.options.mtu,
      minMtu: this.options.minMtu,
      maxProbeMtu: this.options.maxProbeMtu,
      reassemblyBytes: this.globalReassemblyBytes,
      reassemblyFrames: this.globalReassemblyFrames,
      counters: { ...this.counters },
      sessions
    };
  }

  log(event, fields) {
    if (!this.options.logger || typeof this.options.logger.log !== 'function') {
      return;
    }

    this.options.logger.log(JSON.stringify({ event, ...fields }));
  }
}

class SwitchUDPSession {
  constructor(options) {
    this.dataPlane = options.dataPlane;
    this.connection = options.connection;
    this.preference = options.preference;
    this.sessionId = options.sessionId;
    this.sessionIdString = base64UrlEncode(options.sessionId);
    this.keyId = options.keyId;
    this.keys = options.keys;
    this.clientRandom = options.clientRandom;
    this.serverRandom = options.serverRandom;
    this.clientIdentity = options.clientIdentity;
    this.serverIdentity = options.serverIdentity;
    this.activeMtu = options.mtu;
    this.minMtu = options.minMtu;
    this.maxProbeMtu = options.maxProbeMtu;
    this.ready = false;
    this.endpoint = null;
    this.nextPacketNumber = 1n;
    this.nextFragmentId = 1;
    this.replayWindow = new UDPReplayWindow(this.dataPlane.options.replayWindow);
    this.reassembler = new UDPFragmentReassembler(this);
    this.pacer = new UDPPacer({
      dataPlane: this.dataPlane,
      session: this,
      initialMbps: this.dataPlane.options.initialMbps,
      minMbps: this.dataPlane.options.minMbps,
      maxMbps: this.dataPlane.options.maxMbps,
      maxQueuedBytes: this.dataPlane.options.queueBytes,
      maxQueuedFrames: this.dataPlane.options.queueFrames
    });
    this.createdAt = Date.now();
    this.lastValidUdpAt = 0;
    this.lastFallbackReason = null;
    this.counters = {
      rxPackets: 0,
      rxBytes: 0,
      txPackets: 0,
      txBytes: 0,
      rxDataFrames: 0,
      txDataFrames: 0,
      queueDrops: 0,
      invalidPacketDrops: 0,
      invalidTagDrops: 0,
      replayDrops: 0,
      endpointDrops: 0,
      fragmentDrops: 0,
      duplicateDrops: 0
    };
  }

  ackDataPlane() {
    return {
      selected: 'udp',
      udpPort: this.dataPlane.boundAddress?.port ?? this.dataPlane.options.port,
      sessionId: this.sessionIdString,
      cipher: 'aes-256-gcm',
      mtu: this.activeMtu,
      minMtu: this.minMtu,
      keyId: this.keyId,
      serverRandom: base64UrlEncode(this.serverRandom),
      clientIdentity: this.clientIdentity,
      serverIdentity: this.serverIdentity,
      pacing: {
        initialMbps: this.dataPlane.options.initialMbps,
        minMbps: this.dataPlane.options.minMbps,
        maxMbps: this.dataPlane.options.maxMbps
      }
    };
  }

  close() {
    this.pacer.close();
    this.reassembler.close();
  }

  learnEndpoint(remoteInfo) {
    this.endpoint = endpointFromRemoteInfo(remoteInfo);
  }

  acceptEndpoint(remoteInfo, packetType) {
    const candidate = endpointFromRemoteInfo(remoteInfo);
    if (!this.endpoint) {
      return packetType === UdpPacketType.PROBE;
    }

    if (sameEndpoint(this.endpoint, candidate)) {
      return true;
    }

    if (packetType === UdpPacketType.PROBE) {
      this.endpoint = candidate;
      this.ready = false;
      return true;
    }

    return false;
  }

  isUnhealthy() {
    return this.ready
      && this.lastValidUdpAt > 0
      && Date.now() - this.lastValidUdpAt > this.dataPlane.options.unhealthyTimeoutMs;
  }

  encodeDataPackets(payload, seqNo) {
    const dataPlaintext = Buffer.alloc(4 + payload.length);
    dataPlaintext.writeUInt32BE(seqNo >>> 0, 0);
    payload.copy(dataPlaintext, 4);

    if (UDP_PACKET_OVERHEAD + dataPlaintext.length <= this.activeMtu) {
      return [this.encrypt(UdpPacketType.DATA, dataPlaintext)];
    }

    const fragmentPlaintextOverhead = 8; // seqNo + totalLength per fragment.
    const maxChunkSize = this.activeMtu - UDP_PACKET_OVERHEAD - fragmentPlaintextOverhead;
    if (maxChunkSize <= 0) {
      return [];
    }

    const fragmentCount = Math.ceil(payload.length / maxChunkSize);
    if (fragmentCount > 16) {
      this.counters.fragmentDrops += 1;
      this.dataPlane.counters.fragmentDrops += 1;
      return [];
    }

    const fragmentId = this.nextFragmentId >>> 0;
    this.nextFragmentId = this.nextFragmentId >= 0xffffffff ? 1 : this.nextFragmentId + 1;
    const packets = [];
    for (let index = 0; index < fragmentCount; index += 1) {
      const start = index * maxChunkSize;
      const end = Math.min(payload.length, start + maxChunkSize);
      const chunk = payload.subarray(start, end);
      const plaintext = Buffer.alloc(fragmentPlaintextOverhead + chunk.length);
      plaintext.writeUInt32BE(seqNo >>> 0, 0);
      plaintext.writeUInt32BE(payload.length >>> 0, 4);
      chunk.copy(plaintext, fragmentPlaintextOverhead);
      packets.push(this.encrypt(UdpPacketType.FRAGMENT, plaintext, {
        fragmentId,
        fragmentIndex: index,
        fragmentCount
      }));
    }
    return packets;
  }

  sendControl(type, plaintext) {
    if (!this.endpoint) {
      return false;
    }

    const packet = this.encrypt(type, plaintext);
    return this.pacer.enqueue(packet, this.endpoint);
  }

  encrypt(type, plaintext, fragment = {}) {
    const packetNumber = this.nextPacketNumber;
    this.nextPacketNumber += 1n;
    const header = encodeUDPHeader({
      type,
      keyId: this.keyId,
      sessionId: this.sessionId,
      packetNumber,
      fragmentId: fragment.fragmentId ?? 0,
      fragmentIndex: fragment.fragmentIndex ?? 0,
      fragmentCount: fragment.fragmentCount ?? 0
    });
    const encrypted = encryptPacket(header, plaintext, this.keys.s2c, packetNumber);
    const packet = Buffer.concat([header, encrypted.ciphertext, encrypted.authTag]);
    this.counters.txPackets += 1;
    this.counters.txBytes += packet.length;
    return packet;
  }

  status() {
    return {
      sessionId: this.sessionIdString,
      nodeID: this.connection?.nodeID ?? null,
      network: this.connection?.networkKey ?? null,
      preference: this.preference,
      ready: this.ready,
      endpoint: this.endpoint,
      activeMtu: this.activeMtu,
      pacingMbps: this.pacer.currentMbps,
      queueBytes: this.pacer.queuedBytes,
      queueFrames: this.pacer.queue.length,
      lastValidUdpAt: this.lastValidUdpAt || null,
      lastFallbackReason: this.lastFallbackReason,
      counters: { ...this.counters }
    };
  }
}

class UDPPacer {
  constructor(options) {
    this.dataPlane = options.dataPlane;
    this.session = options.session;
    this.minMbps = options.minMbps;
    this.maxMbps = options.maxMbps;
    this.currentMbps = Math.max(this.minMbps, options.initialMbps);
    this.queue = [];
    this.queuedBytes = 0;
    this.maxQueuedBytes = options.maxQueuedBytes;
    this.maxQueuedFrames = options.maxQueuedFrames;
    this.tokens = this.bytesPerSecond;
    this.lastRefillAt = Date.now();
    this.timer = null;
  }

  get bytesPerSecond() {
    const capped = this.maxMbps > 0
      ? Math.min(this.currentMbps, this.maxMbps)
      : this.currentMbps;
    return Math.max(this.minMbps, capped) * 125000;
  }

  enqueue(packet, endpoint) {
    this.refill();
    if (this.queue.length === 0 && this.tokens >= packet.length) {
      this.tokens -= packet.length;
      this.dataPlane.sendPacket(packet, endpoint);
      return true;
    }

    if (
      this.queue.length >= this.maxQueuedFrames
      || this.queuedBytes + packet.length > this.maxQueuedBytes
    ) {
      return false;
    }

    this.queue.push({ packet, endpoint, queuedAt: Date.now() });
    this.queuedBytes += packet.length;
    this.schedule();
    return true;
  }

  refill() {
    const now = Date.now();
    const elapsedSeconds = Math.max(0, now - this.lastRefillAt) / 1000;
    this.lastRefillAt = now;
    this.tokens = Math.min(this.bytesPerSecond, this.tokens + elapsedSeconds * this.bytesPerSecond);
  }

  flush() {
    this.timer = null;
    this.refill();
    while (this.queue.length > 0) {
      const next = this.queue[0];
      if (this.tokens < next.packet.length) {
        break;
      }
      this.queue.shift();
      this.queuedBytes -= next.packet.length;
      this.tokens -= next.packet.length;
      this.dataPlane.sendPacket(next.packet, next.endpoint);
    }
    if (this.queue.length > 0) {
      this.schedule();
    }
  }

  schedule() {
    if (this.timer || this.queue.length === 0) {
      return;
    }
    const needed = Math.max(0, this.queue[0].packet.length - this.tokens);
    const delayMs = Math.max(1, Math.ceil((needed / this.bytesPerSecond) * 1000));
    this.timer = setTimeout(() => this.flush(), delayMs);
    this.timer.unref();
  }

  close() {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    this.queue = [];
    this.queuedBytes = 0;
  }
}

class UDPReplayWindow {
  constructor(size = DEFAULT_REPLAY_WINDOW) {
    this.size = BigInt(size);
    this.highest = null;
    this.seen = new Set();
  }

  accept(packetNumber) {
    if (this.highest == null) {
      this.highest = packetNumber;
      this.seen.add(packetNumber.toString());
      return true;
    }

    if (packetNumber > this.highest) {
      this.highest = packetNumber;
      this.prune();
    } else if (this.highest - packetNumber >= this.size) {
      return false;
    }

    const key = packetNumber.toString();
    if (this.seen.has(key)) {
      return false;
    }
    this.seen.add(key);
    return true;
  }

  prune() {
    const minimum = this.highest - this.size + 1n;
    for (const value of this.seen) {
      if (BigInt(value) < minimum) {
        this.seen.delete(value);
      }
    }
  }
}

class UDPFragmentReassembler {
  constructor(session) {
    this.session = session;
    this.incomplete = new Map();
    this.completed = new Map();
    this.timer = setInterval(() => this.expire(), Math.max(100, session.dataPlane.options.fragmentTimeoutMs));
    this.timer.unref();
    this.sessionBytes = 0;
  }

  accept(parsed, plaintext) {
    const key = `${parsed.keyId}:${parsed.fragmentId}`;
    this.expire();
    this.pruneCompleted();

    if (this.completed.has(key)) {
      return { dropReason: 'duplicate_completed_fragment' };
    }

    if (parsed.fragmentCount <= 1 || parsed.fragmentCount > 16) {
      return { dropReason: 'bad_fragment_count' };
    }
    if (parsed.fragmentIndex >= parsed.fragmentCount) {
      return { dropReason: 'bad_fragment_index' };
    }
    if (plaintext.length < 8) {
      return { dropReason: 'bad_fragment_plaintext' };
    }

    const seqNo = plaintext.readUInt32BE(0);
    const totalLength = plaintext.readUInt32BE(4);
    const chunk = plaintext.subarray(8);
    if (totalLength === 0 || totalLength > this.session.connection?.negotiatedMaxFrameSize) {
      return { dropReason: 'bad_fragment_total_length' };
    }

    let entry = this.incomplete.get(key);
    if (!entry) {
      const estimatedBytes = totalLength;
      if (
        this.incomplete.size + 1 > this.session.dataPlane.options.reassemblySessionFrames
        || this.sessionBytes + estimatedBytes > this.session.dataPlane.options.reassemblySessionBytes
        || !this.session.dataPlane.addGlobalReassembly(estimatedBytes)
      ) {
        return { dropReason: 'reassembly_limit' };
      }

      entry = {
        key,
        seqNo,
        totalLength,
        fragmentCount: parsed.fragmentCount,
        createdAt: Date.now(),
        receivedBytes: 0,
        fragments: new Array(parsed.fragmentCount),
        estimatedBytes
      };
      this.incomplete.set(key, entry);
      this.sessionBytes += estimatedBytes;
    } else if (
      entry.seqNo !== seqNo
      || entry.totalLength !== totalLength
      || entry.fragmentCount !== parsed.fragmentCount
    ) {
      return { dropReason: 'inconsistent_fragment_metadata' };
    }

    if (entry.fragments[parsed.fragmentIndex]) {
      return { dropReason: 'duplicate_fragment' };
    }

    entry.fragments[parsed.fragmentIndex] = chunk;
    entry.receivedBytes += chunk.length;
    if (entry.receivedBytes > totalLength) {
      this.removeEntry(key, 'bad_fragment_size');
      return { dropReason: 'bad_fragment_size' };
    }

    for (const fragment of entry.fragments) {
      if (!fragment) {
        return {};
      }
    }

    const payload = Buffer.concat(entry.fragments);
    this.removeEntry(key);
    if (payload.length !== totalLength) {
      return { dropReason: 'bad_reassembled_size' };
    }

    this.completed.set(key, Date.now());
    while (this.completed.size > 1024) {
      const first = this.completed.keys().next().value;
      this.completed.delete(first);
    }

    return { frame: { seqNo, payload } };
  }

  removeEntry(key, dropReason = null) {
    const entry = this.incomplete.get(key);
    if (!entry) {
      return;
    }
    this.incomplete.delete(key);
    this.sessionBytes = Math.max(0, this.sessionBytes - entry.estimatedBytes);
    this.session.dataPlane.releaseGlobalReassembly(entry.estimatedBytes);
    if (dropReason === 'timeout') {
      this.session.counters.fragmentDrops += 1;
      this.session.dataPlane.counters.fragmentDrops += 1;
      this.session.dataPlane.counters.fragmentTimeoutDrops += 1;
    }
  }

  expire() {
    const now = Date.now();
    const timeout = this.session.dataPlane.options.fragmentTimeoutMs;
    for (const [key, entry] of this.incomplete.entries()) {
      if (now - entry.createdAt > timeout) {
        this.removeEntry(key, 'timeout');
      }
    }
    this.pruneCompleted(now);
  }

  pruneCompleted(now = Date.now()) {
    const ttl = this.session.dataPlane.options.duplicateFragmentTtlMs;
    for (const [key, completedAt] of this.completed.entries()) {
      if (now - completedAt > ttl) {
        this.completed.delete(key);
      }
    }
  }

  close() {
    clearInterval(this.timer);
    for (const key of Array.from(this.incomplete.keys())) {
      this.removeEntry(key);
    }
    this.completed.clear();
  }
}

function encodeUDPHeader({ type, keyId, sessionId, packetNumber, fragmentId = 0, fragmentIndex = 0, fragmentCount = 0 }) {
  const header = Buffer.alloc(UDP_HEADER_SIZE);
  UDP_MAGIC.copy(header, 0);
  header.writeUInt8(UDP_VERSION, 4);
  header.writeUInt8(type, 5);
  header.writeUInt8(0, 6);
  header.writeUInt8(keyId, 7);
  sessionId.copy(header, 8);
  header.writeBigUInt64BE(packetNumber, 24);
  header.writeUInt32BE(fragmentId >>> 0, 32);
  header.writeUInt16BE(fragmentIndex, 36);
  header.writeUInt16BE(fragmentCount, 38);
  return header;
}

function parseUDPPacket(packet) {
  if (packet.length < UDP_HEADER_SIZE + UDP_AUTH_TAG_SIZE) {
    return null;
  }
  if (!packet.subarray(0, 4).equals(UDP_MAGIC) || packet.readUInt8(4) !== UDP_VERSION) {
    return null;
  }

  const ciphertextEnd = packet.length - UDP_AUTH_TAG_SIZE;
  return {
    header: packet.subarray(0, UDP_HEADER_SIZE),
    type: packet.readUInt8(5),
    flags: packet.readUInt8(6),
    keyId: packet.readUInt8(7),
    sessionId: packet.subarray(8, 24),
    packetNumber: packet.readBigUInt64BE(24),
    fragmentId: packet.readUInt32BE(32),
    fragmentIndex: packet.readUInt16BE(36),
    fragmentCount: packet.readUInt16BE(38),
    ciphertext: packet.subarray(UDP_HEADER_SIZE, ciphertextEnd),
    authTag: packet.subarray(ciphertextEnd)
  };
}

function encryptPacket(header, plaintext, keyMaterial, packetNumber) {
  const nonce = nonceForPacket(keyMaterial.noncePrefix, packetNumber);
  const cipher = crypto.createCipheriv('aes-256-gcm', keyMaterial.key, nonce);
  cipher.setAAD(header);
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const authTag = cipher.getAuthTag();
  return { ciphertext, authTag };
}

function decryptPacket(parsed, keyMaterial) {
  const nonce = nonceForPacket(keyMaterial.noncePrefix, parsed.packetNumber);
  const decipher = crypto.createDecipheriv('aes-256-gcm', keyMaterial.key, nonce);
  decipher.setAAD(parsed.header);
  decipher.setAuthTag(parsed.authTag);
  return Buffer.concat([decipher.update(parsed.ciphertext), decipher.final()]);
}

function nonceForPacket(prefix, packetNumber) {
  const nonce = Buffer.alloc(12);
  prefix.copy(nonce, 0);
  nonce.writeBigUInt64BE(packetNumber, 4);
  return nonce;
}

function deriveUDPKeys({ clientRandom, serverRandom, sessionId, keyId, clientIdentity, serverIdentity }) {
  return {
    c2s: deriveUDPKeyMaterial({
      clientRandom,
      serverRandom,
      sessionId,
      keyId,
      clientIdentity,
      serverIdentity,
      direction: 'client-to-server'
    }),
    s2c: deriveUDPKeyMaterial({
      clientRandom,
      serverRandom,
      sessionId,
      keyId,
      clientIdentity,
      serverIdentity,
      direction: 'server-to-client'
    })
  };
}

function deriveUDPKeyMaterial({ clientRandom, serverRandom, sessionId, keyId, clientIdentity, serverIdentity, direction }) {
  const ikm = Buffer.concat([clientRandom, serverRandom]);
  const salt = Buffer.concat([Buffer.from(UDP_PROTOCOL_LABEL, 'utf8'), Buffer.from([0]), sessionId]);
  const info = Buffer.from([
    UDP_PROTOCOL_LABEL,
    `key=${keyId}`,
    direction,
    `client=${clientIdentity}`,
    `server=${serverIdentity}`
  ].join('\n'), 'utf8');
  const material = Buffer.from(crypto.hkdfSync('sha256', ikm, salt, info, 36));
  return {
    key: material.subarray(0, 32),
    noncePrefix: material.subarray(32, 36)
  };
}

function normalizeTransportPreference(value) {
  return value === 'udp' || value === 'auto' || value === 'tcp' ? value : 'tcp';
}

function base64UrlEncode(buffer) {
  return Buffer.from(buffer).toString('base64url');
}

function decodeBase64Url(value) {
  if (typeof value !== 'string' || value.length === 0) {
    return null;
  }
  try {
    return Buffer.from(value, 'base64url');
  } catch (_) {
    return null;
  }
}

function endpointFromRemoteInfo(remoteInfo) {
  return {
    address: remoteInfo.address,
    port: remoteInfo.port,
    family: remoteInfo.family
  };
}

function sameEndpoint(left, right) {
  return left.address === right.address
    && left.port === right.port
    && left.family === right.family;
}

function trySetSocketBuffer(socket, which, bytes) {
  try {
    if (which === 'recv' && typeof socket.setRecvBufferSize === 'function') {
      socket.setRecvBufferSize(bytes);
    } else if (which === 'send' && typeof socket.setSendBufferSize === 'function') {
      socket.setSendBufferSize(bytes);
    }
  } catch (_) {
    // OSes may clamp or reject buffer sizes. Status reports actual values when available.
  }
}

function tryGetSocketBuffer(socket, which) {
  try {
    if (which === 'recv' && typeof socket.getRecvBufferSize === 'function') {
      return socket.getRecvBufferSize();
    }
    if (which === 'send' && typeof socket.getSendBufferSize === 'function') {
      return socket.getSendBufferSize();
    }
  } catch (_) {
    return null;
  }
  return null;
}

module.exports = {
  SwitchUDPDataPlane,
  UDP_AUTH_TAG_SIZE,
  UDP_HEADER_SIZE,
  UDP_MAGIC,
  UDP_PROTOCOL_LABEL,
  UDP_VERSION,
  UdpPacketType,
  base64UrlEncode,
  decodeBase64Url,
  deriveUDPKeys,
  encodeUDPHeader,
  encryptPacket,
  parseUDPPacket,
  decryptPacket
};
