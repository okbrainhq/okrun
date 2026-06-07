'use strict';

const { DedupWindow } = require('./dedup-window');
const {
  ETHERNET_STREAM_ID,
  FrameType,
  encodeFrame,
  encodeJsonFrame
} = require('./protocol');

const SEQ_RESET_THRESHOLD = 0xffffff0f;

class HostSession {
  constructor(options) {
    this.networkKey = options.networkKey;
    this.nodeID = options.nodeID;
    this.clientSerial = options.clientSerial;
    this.clientFingerprint = options.clientFingerprint;
    this.identityKind = options.identityKind ?? 'tls';
    this.dhcpRange = options.dhcpRange ?? null;
    this.maxConnectionsPerHost = options.maxConnectionsPerHost;
    this.connections = new Map();
    this.incomingDedup = new Map();
    this.outgoingSeqByStream = new Map();
    this.lastSeenAt = Date.now();
    this.droppedFrames = 0;
    this.droppedBytes = 0;
    this.dropReasons = new Map();
  }

  get connectionCount() {
    return this.connections.size;
  }

  hasConnectionKind(kind) {
    for (const connection of this.connections.values()) {
      if ((connection.identity?.kind ?? 'tls') === kind) {
        return true;
      }
    }

    return false;
  }

  canAddInterface(interfaceName) {
    return this.connections.has(interfaceName)
      || this.connections.size < this.maxConnectionsPerHost;
  }

  addConnection(interfaceName, connection) {
    const oldConnection = this.connections.get(interfaceName);
    if (oldConnection && oldConnection !== connection) {
      oldConnection.closeWithError({
        code: 'connection_replaced',
        message: `Interface ${interfaceName} reconnected`
      });
    }

    this.connections.set(interfaceName, connection);
    this.lastSeenAt = Date.now();
  }

  removeConnection(connection) {
    if (!connection.interfaceName) {
      return false;
    }

    if (this.connections.get(connection.interfaceName) !== connection) {
      return false;
    }

    this.connections.delete(connection.interfaceName);
    this.lastSeenAt = Date.now();
    return true;
  }

  acceptIncoming(streamId, seqNo) {
    let window = this.incomingDedup.get(streamId);
    if (!window) {
      window = new DedupWindow();
      this.incomingDedup.set(streamId, window);
    }

    this.lastSeenAt = Date.now();
    return window.accept(seqNo);
  }

  resetIncoming(streamIds) {
    for (const streamId of streamIds) {
      const window = this.incomingDedup.get(streamId);
      if (window) {
        window.reset();
      }
    }
  }

  recordDrop(reason, byteCount) {
    this.droppedFrames += 1;
    this.droppedBytes += byteCount;
    this.dropReasons.set(reason, (this.dropReasons.get(reason) ?? 0) + 1);
    this.lastSeenAt = Date.now();
  }

  nextSeqNo(streamId) {
    const current = this.outgoingSeqByStream.get(streamId) ?? 0;
    const next = current >= 0xffffffff ? 1 : current + 1;
    this.outgoingSeqByStream.set(streamId, next);
    return next;
  }

  sendData(payload, sourceConnection) {
    let seqNo = this.nextSeqNo(ETHERNET_STREAM_ID);
    if (seqNo > SEQ_RESET_THRESHOLD) {
      this.sendResetSeq([ETHERNET_STREAM_ID]);
      seqNo = 0;
      this.outgoingSeqByStream.set(ETHERNET_STREAM_ID, seqNo);
    }

    const encoded = encodeFrame({
      streamId: ETHERNET_STREAM_ID,
      type: FrameType.DATA,
      seqNo,
      payload
    });

    for (const connection of this.dataConnectionOrder(sourceConnection)) {
      const sent = typeof connection.writeDataFrame === 'function'
        ? connection.writeDataFrame(payload, seqNo, encoded)
        : connection.writeEncodedFrame(encoded);
      if (sent) {
        return 1;
      }
    }

    return 0;
  }

  dataConnectionOrder(sourceConnection) {
    const connections = Array.from(this.connections.values());
    const sourceKind = sourceConnection?.identity?.kind ?? 'tls';
    if (sourceKind === 'local') {
      return connections.filter((connection) => (connection.identity?.kind ?? 'tls') === 'local');
    }
    return connections.filter((connection) => (connection.identity?.kind ?? 'tls') !== 'local');
  }

  sendResetSeq(streams) {
    const encoded = encodeJsonFrame(FrameType.RESET_SEQ, { streams });
    for (const connection of this.connections.values()) {
      connection.writeEncodedFrame(encoded);
    }
  }

  sendMemberUpdate(payload) {
    const encoded = encodeJsonFrame(FrameType.MEMBER_UPDATE, payload);
    for (const connection of this.connections.values()) {
      connection.writeEncodedFrame(encoded);
    }
  }

  toStatus() {
    return {
      nodeID: this.nodeID,
      clientSerial: this.clientSerial,
      connections: Array.from(this.connections.keys()).sort(),
      dhcpRange: this.dhcpRange
        ? {
            cidr: this.dhcpRange.cidr,
            rangeStart: this.dhcpRange.rangeStart,
            rangeEnd: this.dhcpRange.rangeEnd
          }
        : null,
      droppedFrames: this.droppedFrames,
      droppedBytes: this.droppedBytes,
      dropReasons: Object.fromEntries(Array.from(this.dropReasons.entries()).sort()),
      lastSeenAt: this.lastSeenAt
    };
  }
}

module.exports = {
  HostSession
};
