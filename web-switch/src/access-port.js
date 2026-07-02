'use strict';

const crypto = require('node:crypto');
const path = require('node:path');
const { spawn } = require('node:child_process');

const {
  DEFAULT_MAX_FRAME_SIZE,
  ETHERNET_STREAM_ID,
  FrameDecoder,
  FrameType
} = require('./protocol');
const { AdmissionError } = require('./switch-fabric');

const READY_PREFIX = 'OKRUN_SWITCH_TAP_READY ';

class TapAccessPort {
  constructor(options) {
    this.fabric = options.fabric;
    this.options = {
      networkIdentifier: options.networkIdentifier,
      tapName: options.tapName ?? 'oksw0',
      interfaceName: options.interfaceName ?? options.tapName ?? 'oksw0',
      ipCidr: options.ipCidr ?? null,
      mtu: options.mtu ?? 1500,
      tapFrameSizeLimit: Math.min(options.maxFrameSize ?? DEFAULT_MAX_FRAME_SIZE, (options.mtu ?? 1500) + 64),
      nodeID: options.nodeID ?? crypto.randomUUID(),
      maxFrameSize: options.maxFrameSize ?? DEFAULT_MAX_FRAME_SIZE,
      helperPath: options.helperPath ?? path.resolve(__dirname, '../bin/okrun-switch-tap-helper.py'),
      python: options.python ?? process.env.PYTHON ?? 'python3',
      logger: options.logger ?? console
    };

    this.identity = {
      clientSerial: `access:${this.options.tapName}`,
      clientFingerprint: '',
      kind: 'access'
    };
    this.networkKey = null;
    this.nodeID = null;
    this.interfaceName = null;
    this.negotiatedMaxFrameSize = this.options.maxFrameSize;
    this.session = null;
    this.initialized = false;
    this.closed = false;
    this.child = null;
    this.seqNo = 0;
    this.helperStdout = Buffer.alloc(0);
    this.helperStderr = '';
    this.egressDecoder = new FrameDecoder({
      maxPayloadLength: this.options.maxFrameSize + 4096
    });
  }

  start() {
    if (process.platform !== 'linux') {
      throw new Error('Linux TAP access ports are only supported on Linux');
    }

    const args = [
      this.options.helperPath,
      '--interface',
      this.options.tapName,
      '--mtu',
      String(this.options.mtu),
      '--max-frame-size',
      String(this.options.maxFrameSize)
    ];
    if (this.options.ipCidr) {
      args.push('--ip', this.options.ipCidr);
    }

    this.child = spawn(this.options.python, args, {
      stdio: ['pipe', 'pipe', 'pipe']
    });

    this.child.stdout.on('data', (chunk) => this.handleHelperStdout(chunk));
    this.child.stderr.on('data', (chunk) => this.handleHelperStderr(chunk));
    this.child.once('error', (error) => {
      this.log('access_error', {
        code: error.code,
        message: error.message,
        network: this.options.networkIdentifier,
        interface: this.options.tapName
      });
      this.removeFromFabric();
    });
    this.child.once('exit', (code, signal) => {
      this.log('access_exit', {
        code,
        signal,
        network: this.networkKey ?? this.options.networkIdentifier,
        interface: this.interfaceName ?? this.options.tapName
      });
      this.removeFromFabric();
    });

    this.log('access_starting', {
      network: this.options.networkIdentifier,
      interface: this.options.tapName,
      ip: this.options.ipCidr
    });
  }

  handleHelperStdout(chunk) {
    if (this.closed) {
      return;
    }

    this.helperStdout = this.helperStdout.length === 0
      ? chunk
      : Buffer.concat([this.helperStdout, chunk]);

    while (this.helperStdout.length >= 4) {
      const frameLength = this.helperStdout.readUInt32BE(0);
      if (frameLength > this.options.maxFrameSize) {
        this.closeWithError({
          code: 'tap_frame_too_large',
          message: `TAP frame length ${frameLength} exceeds ${this.options.maxFrameSize}`
        });
        return;
      }

      if (this.helperStdout.length < 4 + frameLength) {
        return;
      }

      const payload = this.helperStdout.subarray(4, 4 + frameLength);
      this.helperStdout = this.helperStdout.subarray(4 + frameLength);
      this.handleTapFrame(payload);
    }
  }

  handleHelperStderr(chunk) {
    this.helperStderr += chunk.toString('utf8');
    let newlineIndex;
    while ((newlineIndex = this.helperStderr.indexOf('\n')) >= 0) {
      const line = this.helperStderr.slice(0, newlineIndex).trim();
      this.helperStderr = this.helperStderr.slice(newlineIndex + 1);
      if (!line) {
        continue;
      }
      this.handleHelperLogLine(line);
    }
  }

  handleHelperLogLine(line) {
    if (line.startsWith(READY_PREFIX)) {
      let payload;
      try {
        payload = JSON.parse(line.slice(READY_PREFIX.length));
      } catch (error) {
        this.closeWithError({
          code: 'tap_helper_bad_ready',
          message: error.message
        });
        return;
      }
      this.admit(payload);
      return;
    }

    this.log('access_helper_log', {
      network: this.options.networkIdentifier,
      interface: this.options.tapName,
      message: line
    });
  }

  admit(helperReady) {
    if (this.initialized || this.closed) {
      return;
    }

    try {
      this.fabric.admitConnection({
        protocol: 'okrun-switch/1',
        nodeID: this.options.nodeID,
        networkIdentifier: this.options.networkIdentifier,
        interface: this.options.interfaceName,
        maxFrameSize: this.options.maxFrameSize
      }, this.identity, this);
    } catch (error) {
      if (error instanceof AdmissionError) {
        this.log('access_reject', {
          code: error.code,
          message: error.message,
          network: this.options.networkIdentifier,
          interface: this.options.tapName
        });
        this.close();
        return;
      }
      throw error;
    }

    this.initialized = true;
    this.fabric.broadcastMemberUpdate(this.networkKey);
    this.log('access_ready', {
      network: this.networkKey,
      nodeID: this.nodeID,
      interface: this.interfaceName,
      tap: helperReady.interface ?? this.options.tapName,
      ip: this.options.ipCidr
    });
  }

  handleTapFrame(payload) {
    if (!this.initialized || this.closed || payload.length === 0) {
      return;
    }

    this.seqNo = this.seqNo >= 0xffffffff ? 1 : this.seqNo + 1;
    const result = this.fabric.handleData(this, {
      streamId: ETHERNET_STREAM_ID,
      type: FrameType.DATA,
      seqNo: this.seqNo,
      payload
    });

    if (process.env.OKRUN_SWITCH_DEBUG === '1') {
      this.log('access_data', {
        network: this.networkKey,
        nodeID: this.nodeID,
        interface: this.interfaceName,
        seqNo: this.seqNo,
        bytes: payload.length,
        duplicate: result.duplicate,
        forwarded: result.forwarded,
        dropped: result.dropped,
        dropReason: result.dropReason
      });
    }
  }

  writeEncodedFrame(encoded) {
    if (this.closed || !this.child || !this.child.stdin.writable) {
      return false;
    }

    let accepted = true;
    let frames;
    try {
      frames = this.egressDecoder.push(encoded);
    } catch (error) {
      this.closeWithError({
        code: error.code ?? 'tap_protocol_error',
        message: error.message
      });
      return false;
    }

    for (const frame of frames) {
      if (frame.type !== FrameType.DATA || frame.streamId !== ETHERNET_STREAM_ID) {
        continue;
      }
      accepted = this.writeTapFrame(frame.payload) && accepted;
    }
    return accepted;
  }

  writeTapFrame(payload) {
    if (payload.length > this.options.tapFrameSizeLimit) {
      this.log('access_drop', {
        code: 'tap_mtu_exceeded',
        network: this.networkKey ?? this.options.networkIdentifier,
        interface: this.interfaceName ?? this.options.tapName,
        bytes: payload.length,
        limit: this.options.tapFrameSizeLimit
      });
      return false;
    }

    const header = Buffer.alloc(4);
    header.writeUInt32BE(payload.length, 0);
    return this.child.stdin.write(Buffer.concat([header, payload]));
  }

  closeWithError(error) {
    this.log('access_close_error', {
      code: error.code,
      message: error.message,
      network: this.networkKey ?? this.options.networkIdentifier,
      interface: this.interfaceName ?? this.options.tapName
    });
    this.close();
  }

  close(callback) {
    if (this.closed) {
      if (callback) {
        callback();
      }
      return;
    }

    this.closed = true;
    this.removeFromFabric();

    if (!this.child || this.child.exitCode != null) {
      if (callback) {
        callback();
      }
      return;
    }

    const child = this.child;
    let done = false;
    const finish = () => {
      if (done) {
        return;
      }
      done = true;
      if (callback) {
        callback();
      }
    };

    child.once('exit', finish);
    child.stdin.end();
    child.kill('SIGTERM');
    setTimeout(() => {
      if (child.exitCode == null) {
        child.kill('SIGKILL');
      }
      finish();
    }, 1000).unref();
  }

  removeFromFabric() {
    if (!this.session) {
      return;
    }

    this.fabric.removeConnection(this);
    this.session = null;
    this.networkKey = null;
    this.nodeID = null;
    this.interfaceName = null;
    this.initialized = false;
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

module.exports = {
  TapAccessPort
};
