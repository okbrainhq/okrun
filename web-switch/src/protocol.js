'use strict';

const FRAME_HEADER_SIZE = 13;
const CONTROL_STREAM_ID = 0;
const ETHERNET_STREAM_ID = 1;
const DEFAULT_MAX_FRAME_SIZE = 70000;

const FrameType = Object.freeze({
  DATA: 0x02,
  ERROR: 0x04,
  INIT: 0x05,
  PING: 0x06,
  PONG: 0x07,
  RESET_SEQ: 0x09
});

class ProtocolError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'ProtocolError';
    this.code = code;
  }
}

class FrameDecoder {
  constructor(options = {}) {
    this.maxPayloadLength = options.maxPayloadLength ?? DEFAULT_MAX_FRAME_SIZE;
    this.buffer = Buffer.alloc(0);
    this.destroyed = false;
  }

  push(chunk) {
    if (this.destroyed) {
      return [];
    }

    if (!Buffer.isBuffer(chunk)) {
      chunk = Buffer.from(chunk);
    }

    this.buffer = this.buffer.length === 0
      ? chunk
      : Buffer.concat([this.buffer, chunk]);

    const frames = [];
    while (this.buffer.length >= FRAME_HEADER_SIZE) {
      const payloadLength = this.buffer.readUInt32BE(9);
      if (payloadLength > this.maxPayloadLength) {
        this.destroyed = true;
        this.buffer = Buffer.alloc(0);
        throw new ProtocolError(
          'frame_too_large',
          `Frame payload length ${payloadLength} exceeds ${this.maxPayloadLength}`
        );
      }

      const frameLength = FRAME_HEADER_SIZE + payloadLength;
      if (this.buffer.length < frameLength) {
        break;
      }

      frames.push({
        streamId: this.buffer.readUInt32BE(0),
        type: this.buffer.readUInt8(4),
        seqNo: this.buffer.readUInt32BE(5),
        payload: this.buffer.subarray(FRAME_HEADER_SIZE, frameLength)
      });

      this.buffer = this.buffer.subarray(frameLength);
    }

    return frames;
  }
}

function assertUInt32(value, name) {
  if (!Number.isInteger(value) || value < 0 || value > 0xffffffff) {
    throw new ProtocolError('invalid_frame', `${name} must be a UInt32`);
  }
}

function encodeFrame({ streamId, type, seqNo = 0, payload = Buffer.alloc(0) }) {
  assertUInt32(streamId, 'streamId');
  assertUInt32(seqNo, 'seqNo');

  if (!Number.isInteger(type) || type < 0 || type > 0xff) {
    throw new ProtocolError('invalid_frame', 'type must be a UInt8');
  }

  if (!Buffer.isBuffer(payload)) {
    payload = Buffer.from(payload);
  }

  assertUInt32(payload.length, 'payloadLength');

  const frame = Buffer.alloc(FRAME_HEADER_SIZE + payload.length);
  frame.writeUInt32BE(streamId, 0);
  frame.writeUInt8(type, 4);
  frame.writeUInt32BE(seqNo, 5);
  frame.writeUInt32BE(payload.length, 9);
  payload.copy(frame, FRAME_HEADER_SIZE);
  return frame;
}

function encodeJsonFrame(type, value) {
  return encodeFrame({
    streamId: CONTROL_STREAM_ID,
    type,
    seqNo: 0,
    payload: Buffer.from(JSON.stringify(value), 'utf8')
  });
}

function decodeJsonPayload(payload) {
  try {
    return JSON.parse(payload.toString('utf8'));
  } catch (error) {
    throw new ProtocolError('invalid_json', 'Frame payload is not valid JSON');
  }
}

module.exports = {
  CONTROL_STREAM_ID,
  DEFAULT_MAX_FRAME_SIZE,
  ETHERNET_STREAM_ID,
  FRAME_HEADER_SIZE,
  FrameDecoder,
  FrameType,
  ProtocolError,
  decodeJsonPayload,
  encodeFrame,
  encodeJsonFrame
};
