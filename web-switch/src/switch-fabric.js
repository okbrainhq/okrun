'use strict';

const { HostSession } = require('./host-session');
const {
  DEFAULT_MAX_FRAME_SIZE,
  ETHERNET_STREAM_ID,
  FrameType,
  ProtocolError,
  decodeJsonPayload
} = require('./protocol');

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const NETWORK_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/;
const INTERFACE_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$/;

class AdmissionError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'AdmissionError';
    this.code = code;
  }
}

class SwitchFabric {
  constructor(options = {}) {
    this.maxFrameSize = options.maxFrameSize ?? DEFAULT_MAX_FRAME_SIZE;
    this.maxConnectionsPerHost = options.maxConnectionsPerHost ?? 8;
    this.macTtlMs = options.macTtlMs ?? 5 * 60 * 1000;
    this.networks = new Map();
  }

  admitConnection(initPayload, identity, connection) {
    const init = validateInit(initPayload, this.maxFrameSize);
    let network = this.networks.get(init.networkIdentifier);
    if (!network) {
      network = {
        identifier: init.networkIdentifier,
        hosts: new Map(),
        macTable: new Map()
      };
      this.networks.set(init.networkIdentifier, network);
    }

    let session = network.hosts.get(init.nodeID);
    if (
      session
      && session.clientSerial !== identity.clientSerial
      && session.identityKind !== 'local'
      && identity.kind !== 'local'
    ) {
      throw new AdmissionError(
        'same_node_different_certificate',
        'A host with this nodeID is already attached using a different certificate'
      );
    }

    if (session && session.identityKind === 'local' && identity.kind !== 'local') {
      session.clientSerial = identity.clientSerial;
      session.clientFingerprint = identity.clientFingerprint;
      session.identityKind = identity.kind ?? 'tls';
    }

    if (!session) {
      assertNoDhcpOverlap(network, init.nodeID, init.dhcpRange);
      session = new HostSession({
        networkKey: init.networkIdentifier,
        nodeID: init.nodeID,
        clientSerial: identity.clientSerial,
        clientFingerprint: identity.clientFingerprint,
        identityKind: identity.kind ?? 'tls',
        dhcpRange: init.dhcpRange,
        maxConnectionsPerHost: this.maxConnectionsPerHost
      });
      network.hosts.set(init.nodeID, session);
    } else {
      assertNoDhcpOverlap(network, init.nodeID, init.dhcpRange);
      if (init.dhcpRange) {
        session.dhcpRange = init.dhcpRange;
      }
    }

    if (!session.canAddInterface(init.interfaceName)) {
      throw new AdmissionError(
        'too_many_connections',
        `Host already has ${this.maxConnectionsPerHost} active interfaces`
      );
    }

    connection.networkKey = init.networkIdentifier;
    connection.nodeID = init.nodeID;
    connection.interfaceName = init.interfaceName;
    connection.negotiatedMaxFrameSize = Math.min(init.maxFrameSize, this.maxFrameSize);
    connection.session = session;
    session.addConnection(init.interfaceName, connection);

    return {
      init,
      session,
      networkMemberCount: network.hosts.size
    };
  }

  broadcastMemberUpdate(networkKey) {
    const network = this.networks.get(networkKey);
    if (!network) {
      return;
    }

    for (const host of network.hosts.values()) {
      host.sendMemberUpdate(network.hosts.size);
    }
  }

  removeConnection(connection) {
    const session = connection.session;
    if (!session || !connection.networkKey) {
      return;
    }

    const removed = session.removeConnection(connection);
    if (!removed || session.connectionCount > 0) {
      return;
    }

    const network = this.networks.get(connection.networkKey);
    if (!network) {
      return;
    }

    network.hosts.delete(session.nodeID);
    removeMacsForHost(network, session.nodeID);

    if (network.hosts.size === 0) {
      this.networks.delete(connection.networkKey);
      return;
    }

    this.broadcastMemberUpdate(connection.networkKey);
  }

  handleData(connection, frame) {
    if (!connection.session || !connection.networkKey) {
      throw new ProtocolError('data_before_init', 'DATA received before INIT');
    }

    if (frame.streamId !== ETHERNET_STREAM_ID) {
      throw new ProtocolError('bad_stream', 'DATA frames must use streamId 1');
    }

    if (frame.type !== FrameType.DATA) {
      throw new ProtocolError('bad_frame_type', 'Expected DATA frame');
    }

    if (frame.payload.length === 0) {
      throw new ProtocolError('empty_frame', 'DATA payload must not be empty');
    }

    if (frame.payload.length > connection.negotiatedMaxFrameSize) {
      throw new ProtocolError(
        'frame_too_large',
        `DATA payload length ${frame.payload.length} exceeds ${connection.negotiatedMaxFrameSize}`
      );
    }

    if (!connection.session.acceptIncoming(frame.streamId, frame.seqNo)) {
      return { duplicate: true, forwarded: 0 };
    }

    const network = this.networks.get(connection.networkKey);
    if (!network) {
      return { duplicate: false, forwarded: 0 };
    }

    this.expireMacs(network);

    const targets = chooseTargets(network, connection.session, frame.payload);
    let forwarded = 0;
    for (const target of targets) {
      forwarded += target.sendData(frame.payload);
    }

    return { duplicate: false, forwarded };
  }

  handleResetSeq(connection, frame) {
    if (!connection.session) {
      throw new ProtocolError('reset_before_init', 'RESET_SEQ received before INIT');
    }

    const payload = decodeJsonPayload(frame.payload);
    if (!Array.isArray(payload.streams)) {
      throw new ProtocolError('invalid_reset_seq', 'RESET_SEQ payload must include streams');
    }

    const streamIds = payload.streams.filter((streamId) => Number.isInteger(streamId));
    connection.session.resetIncoming(streamIds);
  }

  expireMacs(network = null, now = Date.now()) {
    if (network) {
      expireNetworkMacs(network, now, this.macTtlMs);
      return;
    }

    for (const current of this.networks.values()) {
      expireNetworkMacs(current, now, this.macTtlMs);
    }
  }

  status() {
    this.expireMacs();

    const networks = [];
    let hostCount = 0;
    let connectionCount = 0;
    let macCount = 0;

    for (const network of this.networks.values()) {
      const hosts = Array.from(network.hosts.values()).map((host) => host.toStatus());
      hosts.sort((a, b) => a.nodeID.localeCompare(b.nodeID));

      const networkConnectionCount = hosts.reduce(
        (total, host) => total + host.connections.length,
        0
      );

      hostCount += hosts.length;
      connectionCount += networkConnectionCount;
      macCount += network.macTable.size;

      networks.push({
        identifier: network.identifier,
        hostCount: hosts.length,
        connectionCount: networkConnectionCount,
        macCount: network.macTable.size,
        hosts
      });
    }

    networks.sort((a, b) => a.identifier.localeCompare(b.identifier));

    return {
      ok: true,
      networkCount: networks.length,
      hostCount,
      connectionCount,
      macCount,
      networks
    };
  }
}

function validateInit(init, serverMaxFrameSize) {
  if (!init || typeof init !== 'object') {
    throw new AdmissionError('invalid_init', 'INIT payload must be a JSON object');
  }

  if (init.protocol !== 'okrun-switch/1') {
    throw new AdmissionError('unsupported_protocol', 'Unsupported switch protocol');
  }

  if (typeof init.nodeID !== 'string' || !UUID_PATTERN.test(init.nodeID)) {
    throw new AdmissionError('invalid_node_id', 'INIT nodeID must be a UUID');
  }

  if (
    typeof init.networkIdentifier !== 'string'
    || !NETWORK_PATTERN.test(init.networkIdentifier)
  ) {
    throw new AdmissionError(
      'invalid_network_identifier',
      'INIT networkIdentifier contains unsupported characters'
    );
  }

  const interfaceName = init.interface || 'default';
  if (typeof interfaceName !== 'string' || !INTERFACE_PATTERN.test(interfaceName)) {
    throw new AdmissionError('invalid_interface', 'INIT interface is invalid');
  }

  const maxFrameSize = init.maxFrameSize ?? serverMaxFrameSize;
  if (
    !Number.isInteger(maxFrameSize)
    || maxFrameSize < 1500
    || maxFrameSize > serverMaxFrameSize
  ) {
    throw new AdmissionError(
      'invalid_max_frame_size',
      `INIT maxFrameSize must be between 1500 and ${serverMaxFrameSize}`
    );
  }

  return {
    protocol: init.protocol,
    nodeID: init.nodeID.toLowerCase(),
    networkIdentifier: init.networkIdentifier,
    interfaceName,
    maxFrameSize,
    dhcpRange: parseDhcpRange(init.dhcpRange)
  };
}

function parseDhcpRange(range) {
  if (range == null) {
    return null;
  }

  if (typeof range !== 'object') {
    throw new AdmissionError('invalid_dhcp_range', 'dhcpRange must be an object');
  }

  const cidr = range.cidr;
  const rangeStart = range.rangeStart;
  const rangeEnd = range.rangeEnd;
  if (
    typeof cidr !== 'string'
    || typeof rangeStart !== 'string'
    || typeof rangeEnd !== 'string'
  ) {
    throw new AdmissionError(
      'invalid_dhcp_range',
      'dhcpRange must include cidr, rangeStart, and rangeEnd'
    );
  }

  const cidrParts = cidr.split('/');
  if (cidrParts.length !== 2) {
    throw new AdmissionError('invalid_dhcp_range', 'dhcpRange cidr is invalid');
  }

  const networkAddress = parseIPv4(cidrParts[0]);
  const prefix = Number(cidrParts[1]);
  if (!Number.isInteger(prefix) || prefix < 0 || prefix > 32) {
    throw new AdmissionError('invalid_dhcp_range', 'dhcpRange cidr prefix is invalid');
  }

  const startInt = parseIPv4(rangeStart);
  const endInt = parseIPv4(rangeEnd);
  if (startInt > endInt) {
    throw new AdmissionError('invalid_dhcp_range', 'dhcpRange start must be <= end');
  }

  const mask = prefix === 0 ? 0 : (0xffffffff << (32 - prefix)) >>> 0;
  if (((startInt & mask) >>> 0) !== ((networkAddress & mask) >>> 0)) {
    throw new AdmissionError('invalid_dhcp_range', 'rangeStart is outside cidr');
  }

  if (((endInt & mask) >>> 0) !== ((networkAddress & mask) >>> 0)) {
    throw new AdmissionError('invalid_dhcp_range', 'rangeEnd is outside cidr');
  }

  return {
    cidr,
    rangeStart,
    rangeEnd,
    startInt,
    endInt
  };
}

function parseIPv4(value) {
  if (typeof value !== 'string') {
    throw new AdmissionError('invalid_ipv4', 'IPv4 address must be a string');
  }

  const parts = value.split('.');
  if (parts.length !== 4) {
    throw new AdmissionError('invalid_ipv4', `Invalid IPv4 address ${value}`);
  }

  let result = 0;
  for (const part of parts) {
    if (!/^\d+$/.test(part)) {
      throw new AdmissionError('invalid_ipv4', `Invalid IPv4 address ${value}`);
    }

    const octet = Number(part);
    if (!Number.isInteger(octet) || octet < 0 || octet > 255) {
      throw new AdmissionError('invalid_ipv4', `Invalid IPv4 address ${value}`);
    }

    result = ((result << 8) | octet) >>> 0;
  }

  return result;
}

function assertNoDhcpOverlap(network, nodeID, candidateRange) {
  if (!candidateRange) {
    return;
  }

  for (const host of network.hosts.values()) {
    if (host.nodeID === nodeID || !host.dhcpRange) {
      continue;
    }

    if (rangesOverlap(candidateRange, host.dhcpRange)) {
      throw new AdmissionError(
        'dhcp_range_overlap',
        `DHCP range overlaps active host in network ${network.identifier}`
      );
    }
  }
}

function rangesOverlap(left, right) {
  return left.startInt <= right.endInt && right.startInt <= left.endInt;
}

function chooseTargets(network, sourceHost, payload) {
  if (payload.length >= 14) {
    const destinationMac = formatMac(payload, 0);
    const sourceMac = formatMac(payload, 6);

    if (!isMulticastMac(sourceMac) && sourceMac !== '00:00:00:00:00:00') {
      network.macTable.set(sourceMac, {
        nodeID: sourceHost.nodeID,
        updatedAt: Date.now()
      });
    }

    if (!isMulticastMac(destinationMac)) {
      const known = network.macTable.get(destinationMac);
      if (known) {
        const target = network.hosts.get(known.nodeID);
        if (!target || target === sourceHost) {
          return [];
        }
        return [target];
      }
    }
  }

  return Array.from(network.hosts.values()).filter((host) => host !== sourceHost);
}

function isMulticastMac(macAddress) {
  const firstOctet = Number.parseInt(macAddress.slice(0, 2), 16);
  return (firstOctet & 0x01) === 0x01;
}

function formatMac(payload, offset) {
  const parts = [];
  for (let index = offset; index < offset + 6; index += 1) {
    parts.push(payload[index].toString(16).padStart(2, '0'));
  }
  return parts.join(':');
}

function removeMacsForHost(network, nodeID) {
  for (const [macAddress, entry] of network.macTable.entries()) {
    if (entry.nodeID === nodeID) {
      network.macTable.delete(macAddress);
    }
  }
}

function expireNetworkMacs(network, now, ttlMs) {
  for (const [macAddress, entry] of network.macTable.entries()) {
    if (now - entry.updatedAt > ttlMs) {
      network.macTable.delete(macAddress);
    }
  }
}

module.exports = {
  AdmissionError,
  SwitchFabric,
  parseDhcpRange,
  parseIPv4,
  rangesOverlap
};
