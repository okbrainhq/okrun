import Foundation
import Network

final class PrivateNetworkHostSSHService: PrivateNetworkLocalEndpoint {
    private static let maxTCPPayloadPerSegment = 1_400

    let privateNetworkMACAddress: EthernetAddress

    private let identifier: String
    private let config: PrivateNetworkHostSSHConfig
    private let hostIP: IPv4Address
    private let queue: DispatchQueue
    private let emitFrame: (Data) -> Void
    private var sessions: [TCPSessionKey: TCPSession] = [:]
    private var nextIPIdentifier: UInt16 = 1

    init(
        identifier: String,
        config: PrivateNetworkHostSSHConfig,
        emitFrame: @escaping (Data) -> Void
    ) throws {
        let validated = try config.validated(dhcp: nil)
        guard validated.enabled else {
            throw AppError("private network host SSH service cannot start when disabled.")
        }
        self.identifier = identifier
        self.config = validated
        hostIP = try IPv4Address(validated.ipAddress)
        privateNetworkMACAddress = Self.deterministicMACAddress(identifier: identifier, ipAddress: hostIP)
        queue = DispatchQueue(label: "okrun.private-network-host-ssh.\(identifier).\(UUID().uuidString)")
        self.emitFrame = emitFrame
    }

    func matches(config other: PrivateNetworkHostSSHConfig) -> Bool {
        config == other
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            for session in self.sessions.values {
                session.connection?.cancel()
            }
            self.sessions.removeAll()
        }
    }

    func receivePrivateNetworkFrame(_ frame: Data) {
        queue.async { [weak self] in
            self?.handle(frame: frame)
        }
    }

    private func handle(frame: Data) {
        guard frame.count >= 14 else { return }
        let bytes = [UInt8](frame)
        let destinationMAC = EthernetAddress(Array(bytes[0..<6]))
        let sourceMAC = EthernetAddress(Array(bytes[6..<12]))
        guard sourceMAC != privateNetworkMACAddress else { return }
        let etherType = readUInt16(bytes, 12)

        switch etherType {
        case 0x0806:
            handleARPFrame(bytes, sourceMAC: sourceMAC)
        case 0x0800:
            guard destinationMAC == privateNetworkMACAddress || destinationMAC == .broadcast else { return }
            handleIPv4Frame(bytes, sourceMAC: sourceMAC)
        default:
            return
        }
    }

    private func handleARPFrame(_ bytes: [UInt8], sourceMAC: EthernetAddress) {
        guard let request = ARPMessage.parse(bytes),
              request.operation == 1,
              request.targetIP == hostIP else {
            return
        }

        var frame = Data()
        frame.append(contentsOf: request.senderMAC.bytes)
        frame.append(contentsOf: privateNetworkMACAddress.bytes)
        appendUInt16(0x0806, to: &frame)
        appendUInt16(1, to: &frame)
        appendUInt16(0x0800, to: &frame)
        frame.append(6)
        frame.append(4)
        appendUInt16(2, to: &frame)
        frame.append(contentsOf: privateNetworkMACAddress.bytes)
        appendUInt32(hostIP.value, to: &frame)
        frame.append(contentsOf: request.senderMAC.bytes)
        appendUInt32(request.senderIP.value, to: &frame)
        emitFrame(frame)
    }

    private func handleIPv4Frame(_ bytes: [UInt8], sourceMAC: EthernetAddress) {
        guard let packet = TCPPacket.parse(bytes, sourceMAC: sourceMAC),
              packet.destinationIP == hostIP,
              packet.destinationPort == config.listenPort else {
            return
        }

        let key = TCPSessionKey(
            clientMAC: packet.sourceMAC,
            clientIP: packet.sourceIP,
            clientPort: packet.sourcePort,
            hostPort: packet.destinationPort
        )

        if packet.isRST {
            closeSession(key)
            return
        }

        if packet.isSYN && !packet.isACK {
            startSession(for: key, packet: packet)
            return
        }

        guard let session = sessions[key] else {
            if packet.isSYN || !packet.payload.isEmpty || packet.isFIN {
                sendReset(for: packet)
            }
            return
        }

        if session.state == .synReceived,
           packet.isACK,
           packet.acknowledgementNumber == session.hostSequenceNumber {
            session.state = .established
            flushPendingUpstreamData(for: session)
            flushPendingClientData(for: session)
        }

        if !packet.payload.isEmpty {
            guard packet.sequenceNumber == session.clientSequenceNumber else {
                sendTCP(flags: TCPFlags.ack, payload: Data(), for: session)
                return
            }
            session.clientSequenceNumber &+= UInt32(packet.payload.count)
            sendTCP(flags: TCPFlags.ack, payload: Data(), for: session)
            sendToUpstream(packet.payload, for: session)
        }

        if packet.isFIN {
            let expectedFINSequence = session.clientSequenceNumber
            if packet.sequenceNumber == expectedFINSequence || packet.sequenceNumber == expectedFINSequence &- UInt32(packet.payload.count) {
                session.clientSequenceNumber &+= 1
            }
            sendTCP(flags: TCPFlags.ack, payload: Data(), for: session)
            sendTCP(flags: TCPFlags.finAck, payload: Data(), for: session)
            session.hostSequenceNumber &+= 1
            closeSession(key)
        }
    }

    private func startSession(for key: TCPSessionKey, packet: TCPPacket) {
        closeSession(key)

        let initialHostSequence = initialSequenceNumber(for: key, clientSequence: packet.sequenceNumber)
        let session = TCPSession(
            key: key,
            clientMAC: packet.sourceMAC,
            clientIP: packet.sourceIP,
            clientPort: packet.sourcePort,
            hostPort: packet.destinationPort,
            clientSequenceNumber: packet.sequenceNumber &+ 1,
            hostSequenceNumber: initialHostSequence &+ 1
        )
        sessions[key] = session

        connectUpstream(for: session)
        sendTCP(flags: TCPFlags.synAck, payload: Data(), for: session, sequenceNumber: initialHostSequence)
    }

    private func connectUpstream(for session: TCPSession) {
        guard let port = NWEndpoint.Port(rawValue: config.targetPort) else {
            failUpstream(for: session.key)
            return
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(config.targetHost),
            port: port,
            using: .tcp
        )
        session.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state, key: session.key)
        }
        connection.start(queue: queue)
    }

    private func handleConnectionState(_ state: NWConnection.State, key: TCPSessionKey) {
        guard let session = sessions[key] else { return }
        switch state {
        case .ready:
            session.upstreamReady = true
            receiveFromUpstream(for: key)
            flushPendingClientData(for: session)
        case .failed, .cancelled:
            failUpstream(for: key)
        default:
            break
        }
    }

    private func receiveFromUpstream(for key: TCPSessionKey) {
        guard let session = sessions[key], let connection = session.connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.deliverUpstreamData(data, for: key)
            }
            if isComplete {
                self.finishUpstream(for: key)
            } else if error != nil {
                self.failUpstream(for: key)
            } else {
                self.receiveFromUpstream(for: key)
            }
        }
    }

    private func sendToUpstream(_ data: Data, for session: TCPSession) {
        guard session.state == .established, session.upstreamReady, let connection = session.connection else {
            session.pendingClientData.append(data)
            return
        }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func flushPendingClientData(for session: TCPSession) {
        guard session.state == .established,
              session.upstreamReady,
              let connection = session.connection,
              !session.pendingClientData.isEmpty else {
            return
        }
        let pending = session.pendingClientData
        session.pendingClientData.removeAll()
        for data in pending {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func deliverUpstreamData(_ data: Data, for key: TCPSessionKey) {
        guard let session = sessions[key] else { return }
        guard session.state == .established else {
            session.pendingUpstreamData.append(data)
            return
        }
        sendApplicationData(data, for: session)
    }

    private func flushPendingUpstreamData(for session: TCPSession) {
        guard session.state == .established, !session.pendingUpstreamData.isEmpty else { return }
        let data = session.pendingUpstreamData
        session.pendingUpstreamData.removeAll()
        sendApplicationData(data, for: session)
    }

    private func sendApplicationData(_ data: Data, for session: TCPSession) {
        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.maxTCPPayloadPerSegment, data.count)
            let chunk = data.subdata(in: offset..<end)
            sendTCP(flags: TCPFlags.pshAck, payload: chunk, for: session)
            session.hostSequenceNumber &+= UInt32(chunk.count)
            offset = end
        }
    }

    private func finishUpstream(for key: TCPSessionKey) {
        guard let session = sessions[key] else { return }
        if session.state == .established {
            sendTCP(flags: TCPFlags.finAck, payload: Data(), for: session)
            session.hostSequenceNumber &+= 1
        }
        closeSession(key)
    }

    private func failUpstream(for key: TCPSessionKey) {
        guard let session = sessions[key] else { return }
        sendTCP(flags: TCPFlags.rstAck, payload: Data(), for: session)
        closeSession(key)
    }

    private func sendReset(for packet: TCPPacket) {
        let acknowledgement = packet.sequenceNumber
            &+ UInt32(packet.payload.count)
            &+ (packet.isSYN ? 1 : 0)
            &+ (packet.isFIN ? 1 : 0)
        let frame = makeTCPFrame(
            destinationMAC: packet.sourceMAC,
            destinationIP: packet.sourceIP,
            destinationPort: packet.sourcePort,
            sourcePort: packet.destinationPort,
            sequenceNumber: packet.acknowledgementNumber,
            acknowledgementNumber: acknowledgement,
            flags: TCPFlags.rstAck,
            payload: Data()
        )
        emitFrame(frame)
    }

    private func sendTCP(
        flags: UInt8,
        payload: Data,
        for session: TCPSession,
        sequenceNumber: UInt32? = nil
    ) {
        let frame = makeTCPFrame(
            destinationMAC: session.clientMAC,
            destinationIP: session.clientIP,
            destinationPort: session.clientPort,
            sourcePort: session.hostPort,
            sequenceNumber: sequenceNumber ?? session.hostSequenceNumber,
            acknowledgementNumber: session.clientSequenceNumber,
            flags: flags,
            payload: payload
        )
        emitFrame(frame)
    }

    private func makeTCPFrame(
        destinationMAC: EthernetAddress,
        destinationIP: IPv4Address,
        destinationPort: UInt16,
        sourcePort: UInt16,
        sequenceNumber: UInt32,
        acknowledgementNumber: UInt32,
        flags: UInt8,
        payload: Data
    ) -> Data {
        var tcp = Data()
        appendUInt16(sourcePort, to: &tcp)
        appendUInt16(destinationPort, to: &tcp)
        appendUInt32(sequenceNumber, to: &tcp)
        appendUInt32(acknowledgementNumber, to: &tcp)
        tcp.append(0x50)
        tcp.append(flags)
        appendUInt16(65_535, to: &tcp)
        appendUInt16(0, to: &tcp)
        appendUInt16(0, to: &tcp)
        tcp.append(payload)
        let tcpChecksum = tcpIPv4Checksum(sourceIP: hostIP, destinationIP: destinationIP, tcpSegment: [UInt8](tcp))
        tcp.replaceSubrange(16..<18, with: [UInt8(tcpChecksum >> 8), UInt8(tcpChecksum & 0xff)])

        let ipLength = UInt16(20 + tcp.count)
        var ip = Data()
        ip.append(0x45)
        ip.append(0)
        appendUInt16(ipLength, to: &ip)
        appendUInt16(nextIPIdentifier, to: &ip)
        nextIPIdentifier &+= 1
        appendUInt16(0x4000, to: &ip)
        ip.append(64)
        ip.append(6)
        appendUInt16(0, to: &ip)
        appendUInt32(hostIP.value, to: &ip)
        appendUInt32(destinationIP.value, to: &ip)
        let ipChecksum = internetChecksum([UInt8](ip))
        ip.replaceSubrange(10..<12, with: [UInt8(ipChecksum >> 8), UInt8(ipChecksum & 0xff)])

        var frame = Data()
        frame.append(contentsOf: destinationMAC.bytes)
        frame.append(contentsOf: privateNetworkMACAddress.bytes)
        appendUInt16(0x0800, to: &frame)
        frame.append(ip)
        frame.append(tcp)
        return frame
    }

    private func closeSession(_ key: TCPSessionKey) {
        if let session = sessions.removeValue(forKey: key) {
            session.connection?.cancel()
        }
    }

    private func initialSequenceNumber(for key: TCPSessionKey, clientSequence: UInt32) -> UInt32 {
        var bytes = Array("okrun-host-ssh-seq:\(identifier):".utf8)
        bytes.append(contentsOf: key.clientMAC.bytes)
        appendUInt32ToBytes(key.clientIP.value, to: &bytes)
        appendUInt16ToBytes(key.clientPort, to: &bytes)
        appendUInt32ToBytes(clientSequence, to: &bytes)
        return UInt32(truncatingIfNeeded: FNV1a64.hash(bytes))
    }

    private static func deterministicMACAddress(identifier: String, ipAddress: IPv4Address) -> EthernetAddress {
        var bytes = Array("okrun-host-ssh-mac:\(identifier):".utf8)
        appendUInt32ToBytes(ipAddress.value, to: &bytes)
        let digest = FNV1a64.hash(bytes)
        return EthernetAddress([
            0x02,
            UInt8((digest >> 32) & 0xff),
            UInt8((digest >> 24) & 0xff),
            UInt8((digest >> 16) & 0xff),
            UInt8((digest >> 8) & 0xff),
            UInt8(digest & 0xff)
        ])
    }
}

private enum TCPFlags {
    static let fin: UInt8 = 0x01
    static let syn: UInt8 = 0x02
    static let rst: UInt8 = 0x04
    static let psh: UInt8 = 0x08
    static let ack: UInt8 = 0x10
    static let synAck: UInt8 = syn | ack
    static let pshAck: UInt8 = psh | ack
    static let finAck: UInt8 = fin | ack
    static let rstAck: UInt8 = rst | ack
}

private struct TCPSessionKey: Hashable {
    var clientMAC: EthernetAddress
    var clientIP: IPv4Address
    var clientPort: UInt16
    var hostPort: UInt16
}

private enum TCPSessionState {
    case synReceived
    case established
}

private final class TCPSession {
    let key: TCPSessionKey
    let clientMAC: EthernetAddress
    let clientIP: IPv4Address
    let clientPort: UInt16
    let hostPort: UInt16
    var clientSequenceNumber: UInt32
    var hostSequenceNumber: UInt32
    var state: TCPSessionState = .synReceived
    var upstreamReady = false
    var pendingClientData: [Data] = []
    var pendingUpstreamData = Data()
    var connection: NWConnection?

    init(
        key: TCPSessionKey,
        clientMAC: EthernetAddress,
        clientIP: IPv4Address,
        clientPort: UInt16,
        hostPort: UInt16,
        clientSequenceNumber: UInt32,
        hostSequenceNumber: UInt32
    ) {
        self.key = key
        self.clientMAC = clientMAC
        self.clientIP = clientIP
        self.clientPort = clientPort
        self.hostPort = hostPort
        self.clientSequenceNumber = clientSequenceNumber
        self.hostSequenceNumber = hostSequenceNumber
    }
}

private struct ARPMessage {
    var operation: UInt16
    var senderMAC: EthernetAddress
    var senderIP: IPv4Address
    var targetIP: IPv4Address

    static func parse(_ bytes: [UInt8]) -> ARPMessage? {
        guard bytes.count >= 42,
              readUInt16(bytes, 12) == 0x0806,
              readUInt16(bytes, 14) == 1,
              readUInt16(bytes, 16) == 0x0800,
              bytes[18] == 6,
              bytes[19] == 4 else {
            return nil
        }
        return ARPMessage(
            operation: readUInt16(bytes, 20),
            senderMAC: EthernetAddress(Array(bytes[22..<28])),
            senderIP: IPv4Address(value: readUInt32(bytes, 28)),
            targetIP: IPv4Address(value: readUInt32(bytes, 38))
        )
    }
}

private struct TCPPacket {
    var sourceMAC: EthernetAddress
    var sourceIP: IPv4Address
    var destinationIP: IPv4Address
    var sourcePort: UInt16
    var destinationPort: UInt16
    var sequenceNumber: UInt32
    var acknowledgementNumber: UInt32
    var flags: UInt8
    var payload: Data

    var isFIN: Bool { (flags & TCPFlags.fin) != 0 }
    var isSYN: Bool { (flags & TCPFlags.syn) != 0 }
    var isRST: Bool { (flags & TCPFlags.rst) != 0 }
    var isACK: Bool { (flags & TCPFlags.ack) != 0 }

    static func parse(_ bytes: [UInt8], sourceMAC: EthernetAddress) -> TCPPacket? {
        guard bytes.count >= 14 + 20,
              readUInt16(bytes, 12) == 0x0800 else {
            return nil
        }
        let ipOffset = 14
        let version = bytes[ipOffset] >> 4
        let ihl = Int(bytes[ipOffset] & 0x0f) * 4
        guard version == 4,
              ihl >= 20,
              bytes.count >= ipOffset + ihl,
              bytes[ipOffset + 9] == 6 else {
            return nil
        }
        let totalLength = Int(readUInt16(bytes, ipOffset + 2))
        guard totalLength >= ihl,
              bytes.count >= ipOffset + totalLength else {
            return nil
        }
        let fragment = readUInt16(bytes, ipOffset + 6) & 0x1fff
        guard fragment == 0 else { return nil }

        let tcpOffset = ipOffset + ihl
        guard totalLength >= ihl + 20,
              bytes.count >= tcpOffset + 20 else {
            return nil
        }
        let dataOffset = Int(bytes[tcpOffset + 12] >> 4) * 4
        guard dataOffset >= 20,
              totalLength >= ihl + dataOffset,
              bytes.count >= tcpOffset + dataOffset else {
            return nil
        }
        let payloadStart = tcpOffset + dataOffset
        let payloadEnd = ipOffset + totalLength
        let payload = payloadEnd > payloadStart
            ? Data(bytes[payloadStart..<payloadEnd])
            : Data()

        return TCPPacket(
            sourceMAC: sourceMAC,
            sourceIP: IPv4Address(value: readUInt32(bytes, ipOffset + 12)),
            destinationIP: IPv4Address(value: readUInt32(bytes, ipOffset + 16)),
            sourcePort: readUInt16(bytes, tcpOffset),
            destinationPort: readUInt16(bytes, tcpOffset + 2),
            sequenceNumber: readUInt32(bytes, tcpOffset + 4),
            acknowledgementNumber: readUInt32(bytes, tcpOffset + 8),
            flags: bytes[tcpOffset + 13],
            payload: payload
        )
    }
}

private func appendUInt16(_ value: UInt16, to data: inout Data) {
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

private func appendUInt16ToBytes(_ value: UInt16, to bytes: inout [UInt8]) {
    bytes.append(UInt8((value >> 8) & 0xff))
    bytes.append(UInt8(value & 0xff))
}

private func appendUInt32ToBytes(_ value: UInt32, to bytes: inout [UInt8]) {
    bytes.append(UInt8((value >> 24) & 0xff))
    bytes.append(UInt8((value >> 16) & 0xff))
    bytes.append(UInt8((value >> 8) & 0xff))
    bytes.append(UInt8(value & 0xff))
}

private func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
}

private func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    (UInt32(bytes[offset]) << 24)
        | (UInt32(bytes[offset + 1]) << 16)
        | (UInt32(bytes[offset + 2]) << 8)
        | UInt32(bytes[offset + 3])
}

private func internetChecksum(_ bytes: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    var index = 0
    while index + 1 < bytes.count {
        sum += UInt32(readUInt16(bytes, index))
        index += 2
    }
    if index < bytes.count {
        sum += UInt32(bytes[index]) << 8
    }
    while (sum >> 16) != 0 {
        sum = (sum & 0xffff) + (sum >> 16)
    }
    return UInt16(~sum & 0xffff)
}

private func tcpIPv4Checksum(sourceIP: IPv4Address, destinationIP: IPv4Address, tcpSegment: [UInt8]) -> UInt16 {
    var pseudo = Data()
    appendUInt32(sourceIP.value, to: &pseudo)
    appendUInt32(destinationIP.value, to: &pseudo)
    pseudo.append(0)
    pseudo.append(6)
    appendUInt16(UInt16(tcpSegment.count), to: &pseudo)
    pseudo.append(contentsOf: tcpSegment)
    let checksum = internetChecksum([UInt8](pseudo))
    return checksum == 0 ? 0xffff : checksum
}
