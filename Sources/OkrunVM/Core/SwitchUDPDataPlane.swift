import CryptoKit
import Foundation
import Network
import Security

struct SwitchUDPPacingAck: Codable, Equatable {
    var initialMbps: Double?
    var minMbps: Double?
    var maxMbps: Double?
}

struct SwitchUDPDataPlaneAck: Codable, Equatable {
    var selected: String
    var udpPort: UInt16?
    var sessionId: String?
    var cipher: String?
    var mtu: Int?
    var minMtu: Int?
    var maxProbeMtu: Int?
    var keyId: UInt8?
    var serverRandom: String?
    var clientIdentity: String?
    var serverIdentity: String?
    var pacing: SwitchUDPPacingAck?
}

private enum SwitchUDPPacketType: UInt8 {
    case probe = 1
    case probeAck = 2
    case data = 3
    case fragment = 4
    case keepalive = 5
    case keepaliveAck = 6
    case pmtuProbe = 7
    case pmtuProbeAck = 8
}

private struct SwitchUDPKeyMaterial {
    var key: SymmetricKey
    var noncePrefix: Data
}

private struct SwitchUDPKeySet {
    var clientToServer: SwitchUDPKeyMaterial
    var serverToClient: SwitchUDPKeyMaterial
}

private struct SwitchUDPParsedPacket {
    var header: Data
    var type: SwitchUDPPacketType
    var keyID: UInt8
    var sessionID: Data
    var packetNumber: UInt64
    var fragmentID: UInt32
    var fragmentIndex: UInt16
    var fragmentCount: UInt16
    var ciphertext: Data
    var tag: Data
}

private struct SwitchUDPQueuedPacket {
    var packet: Data
    var queuedAt: Date
}

private enum SwitchUDPDataPlaneState {
    case probing
    case ready
    case fallback
    case stopped
}

final class SwitchUDPDataPlane {
    static let protocolLabel = "okrun-switch udp-data-v1"
    static let headerSize = 40
    static let authTagSize = 16
    static let packetOverhead = headerSize + authTagSize
    static let defaultMTU = 1200
    static let maxFragments = 16
    static let probeFailureTimeout: TimeInterval = 5
    static let keepaliveInterval: TimeInterval = 15
    static let unhealthyTimeout: TimeInterval = 45

    var onFrame: ((SwitchFrame) -> Void)?
    var onReady: (() -> Void)?
    var onFallback: ((String) -> Void)?
    var onFailed: ((String) -> Void)?

    private let identifier: String
    private let endpointHost: String
    private let udpPort: UInt16
    private let mode: SwitchDataTransportMode
    private let queue: DispatchQueue
    private let sessionID: Data
    private let sessionIDString: String
    private let keyID: UInt8
    private let keys: SwitchUDPKeySet
    private let maxFrameSize: Int
    private var activeMTU: Int
    private var connection: NWConnection?
    private var state: SwitchUDPDataPlaneState = .probing
    private var nextPacketNumber: UInt64 = 1
    private var nextFragmentID: UInt32 = 1
    private var replayWindow = SwitchUDPReplayWindow()
    private lazy var reassembler = SwitchUDPFragmentReassembler(maxFrameSize: maxFrameSize)
    private var probeRetryWorkItems: [DispatchWorkItem] = []
    private var probeTimeoutWorkItem: DispatchWorkItem?
    private var keepaliveWorkItem: DispatchWorkItem?
    private var pacerWorkItem: DispatchWorkItem?
    private var lastValidPacketAt: Date?
    private var currentMbps: Double
    private let minMbps: Double
    private let maxMbps: Double
    private var tokens: Double
    private var lastRefillAt = Date()
    private var sendQueue: [SwitchUDPQueuedPacket] = []
    private var queuedBytes = 0
    private let maxQueuedBytes = 4 * 1024 * 1024
    private let maxQueuedPackets = 4096

    init(
        identifier: String,
        endpointHost: String,
        ack: SwitchUDPDataPlaneAck,
        clientRandom: Data,
        mode: SwitchDataTransportMode,
        maxFrameSize: Int,
        queue: DispatchQueue
    ) throws {
        guard ack.selected == "udp" else {
            throw AppError("Switch UDP data plane was not selected by the server.")
        }
        guard ack.cipher == nil || ack.cipher == "aes-256-gcm" else {
            throw AppError("Switch UDP cipher \(ack.cipher ?? "unknown") is not supported.")
        }
        guard let sessionIDText = ack.sessionId,
              let sessionID = Data(base64URLEncoded: sessionIDText),
              sessionID.count == 16 else {
            throw AppError("Switch UDP session ID is invalid.")
        }
        guard let serverRandomText = ack.serverRandom,
              let serverRandom = Data(base64URLEncoded: serverRandomText),
              serverRandom.count >= 16 else {
            throw AppError("Switch UDP server random is invalid.")
        }
        guard let udpPort = ack.udpPort, udpPort > 0 else {
            throw AppError("Switch UDP port is invalid.")
        }

        self.identifier = identifier
        self.endpointHost = endpointHost
        self.udpPort = udpPort
        self.mode = mode
        self.queue = queue
        self.sessionID = sessionID
        sessionIDString = sessionIDText
        keyID = ack.keyId ?? 1
        activeMTU = max(Self.defaultMTU, ack.mtu ?? Self.defaultMTU)
        self.maxFrameSize = maxFrameSize
        minMbps = max(ack.pacing?.minMbps ?? 0.25, 0.001)
        let initial = max(ack.pacing?.initialMbps ?? 10, minMbps)
        maxMbps = ack.pacing?.maxMbps ?? 0
        currentMbps = maxMbps > 0 ? min(initial, maxMbps) : initial
        tokens = currentMbps * 125_000
        keys = try Self.deriveKeys(
            clientRandom: clientRandom,
            serverRandom: serverRandom,
            sessionID: sessionID,
            keyID: keyID,
            clientIdentity: ack.clientIdentity ?? "client",
            serverIdentity: ack.serverIdentity ?? "server"
        )
    }

    var isReady: Bool {
        state == .ready
    }

    var isFallback: Bool {
        state == .fallback
    }

    func start() {
        guard connection == nil, state == .probing else { return }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let connection = NWConnection(
            host: NWEndpoint.Host(endpointHost),
            port: NWEndpoint.Port(rawValue: udpPort)!,
            using: parameters
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self else { return }
            self.queue.async {
                guard let connection, connection === self.connection else { return }
                self.handleState(state)
            }
        }
        connection.start(queue: queue)
    }

    func stop() {
        state = .stopped
        cancelProbeTimers()
        cancelKeepalive()
        cancelPacer()
        sendQueue.removeAll()
        queuedBytes = 0
        connection?.cancel()
        connection = nil
    }

    func sendData(_ frame: SwitchFrame) -> Bool {
        guard state == .ready, frame.type == .data, frame.streamID == SwitchFrame.ethernetStreamID else {
            return false
        }

        do {
            let packets = try encodeDataPackets(frame)
            guard !packets.isEmpty else { return false }
            for packet in packets {
                guard enqueue(packet) else { return false }
            }
            return true
        } catch {
            AppLog.webSwitch.error(
                "UDP DATA encode failed network=\(self.identifier, privacy: .public) session=\(self.sessionIDString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard self.state == .probing else { return }
            AppLog.webSwitch.info(
                "UDP ready for probe network=\(self.identifier, privacy: .public) port=\(self.udpPort, privacy: .public) session=\(self.sessionIDString, privacy: .public)"
            )
            receiveLoop()
            startProbe()
        case .failed(let error):
            failOrFallback("UDP failed: \(error.localizedDescription)")
        case .cancelled:
            if self.state == .ready {
                self.state = .stopped
            }
        case .waiting(let error):
            AppLog.webSwitch.info(
                "UDP waiting network=\(self.identifier, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func receiveLoop() {
        guard let connection, state != .stopped, state != .fallback else { return }
        connection.receiveMessage { [weak self, weak connection] content, _, _, error in
            guard let self else { return }
            self.queue.async {
                guard let connection,
                      connection === self.connection,
                      self.state != .stopped,
                      self.state != .fallback else { return }
                if let content, !content.isEmpty {
                    self.handleDatagram(content)
                }
                if let error {
                    self.failOrFallback("UDP receive failed: \(error.localizedDescription)")
                    return
                }
                self.receiveLoop()
            }
        }
    }

    private func handleDatagram(_ datagram: Data) {
        guard state != .stopped, state != .fallback else { return }
        guard let parsed = Self.parsePacket(datagram), parsed.sessionID == sessionID, parsed.keyID == keyID else {
            return
        }

        let plaintext: Data
        do {
            plaintext = try Self.decrypt(parsed, keyMaterial: keys.serverToClient)
        } catch {
            return
        }

        guard replayWindow.accept(parsed.packetNumber) else { return }
        lastValidPacketAt = Date()

        switch parsed.type {
        case .probeAck:
            markReady()
        case .data:
            handleDataPlaintext(plaintext)
        case .fragment:
            if let frame = reassembler.accept(parsed: parsed, plaintext: plaintext) {
                onFrame?(frame)
            }
        case .keepaliveAck:
            break
        case .pmtuProbeAck:
            break
        case .probe, .keepalive, .pmtuProbe:
            break
        }
    }

    private func handleDataPlaintext(_ plaintext: Data) {
        guard plaintext.count >= 4 else { return }
        let seqNo = plaintext.readUInt32BE(at: 0)
        let payload = plaintext.subdata(in: 4..<plaintext.count)
        guard !payload.isEmpty, payload.count <= maxFrameSize else { return }
        onFrame?(SwitchFrame(
            streamID: SwitchFrame.ethernetStreamID,
            type: .data,
            sequenceNumber: seqNo,
            payload: payload
        ))
    }

    private func startProbe() {
        cancelProbeTimers()
        let attempts: [TimeInterval] = [0, 0.5, 1.5, 3.5]
        for delay in attempts {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.state == .probing else { return }
                self.sendControl(.probe, plaintext: Data(UUID().uuidString.utf8))
            }
            probeRetryWorkItems.append(workItem)
            queue.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.state == .probing else { return }
            self.failOrFallback("UDP probe timed out; using TCP/TLS fallback.")
        }
        probeTimeoutWorkItem = timeout
        queue.asyncAfter(deadline: .now() + Self.probeFailureTimeout, execute: timeout)
    }

    private func markReady() {
        guard state == .probing else { return }
        state = .ready
        cancelProbeTimers()
        lastValidPacketAt = Date()
        AppLog.webSwitch.info(
            "UDP accelerated transport ready network=\(self.identifier, privacy: .public) port=\(self.udpPort, privacy: .public) session=\(self.sessionIDString, privacy: .public) mtu=\(self.activeMTU, privacy: .public)"
        )
        onReady?()
        scheduleKeepalive()
        flushQueue()
    }

    private func scheduleKeepalive() {
        cancelKeepalive()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.state == .ready else { return }
            let age = Date().timeIntervalSince(self.lastValidPacketAt ?? .distantPast)
            guard age <= Self.unhealthyTimeout else {
                self.failOrFallback("UDP path became unhealthy; using TCP/TLS fallback.")
                return
            }
            self.sendControl(.keepalive, plaintext: Data())
            self.scheduleKeepalive()
        }
        keepaliveWorkItem = workItem
        queue.asyncAfter(deadline: .now() + Self.keepaliveInterval, execute: workItem)
    }

    private func failOrFallback(_ message: String) {
        guard state != .stopped, state != .fallback else { return }
        cancelProbeTimers()
        cancelKeepalive()
        cancelPacer()
        sendQueue.removeAll()
        queuedBytes = 0
        connection?.cancel()
        connection = nil
        if mode == .auto {
            state = .fallback
            onFallback?(message)
        } else {
            state = .stopped
            onFailed?(message)
        }
    }

    private func cancelProbeTimers() {
        for workItem in probeRetryWorkItems {
            workItem.cancel()
        }
        probeRetryWorkItems.removeAll()
        probeTimeoutWorkItem?.cancel()
        probeTimeoutWorkItem = nil
    }

    private func cancelKeepalive() {
        keepaliveWorkItem?.cancel()
        keepaliveWorkItem = nil
    }

    private func sendControl(_ type: SwitchUDPPacketType, plaintext: Data) {
        do {
            let packet = try encodePacket(type: type, plaintext: plaintext)
            _ = enqueue(packet)
        } catch {
            AppLog.webSwitch.error(
                "UDP control encode failed network=\(self.identifier, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func encodeDataPackets(_ frame: SwitchFrame) throws -> [Data] {
        var plaintext = Data(capacity: 4 + frame.payload.count)
        plaintext.appendUInt32BE(frame.sequenceNumber)
        plaintext.append(frame.payload)
        if Self.packetOverhead + plaintext.count <= activeMTU {
            return [try encodePacket(type: .data, plaintext: plaintext)]
        }

        let chunkSize = activeMTU - Self.packetOverhead - 8
        guard chunkSize > 0 else { return [] }
        let fragmentCount = Int(ceil(Double(frame.payload.count) / Double(chunkSize)))
        guard (2...Self.maxFragments).contains(fragmentCount) else { return [] }

        let fragmentID = nextFragmentID
        nextFragmentID = nextFragmentID == UInt32.max ? 1 : nextFragmentID + 1
        var packets: [Data] = []
        for index in 0..<fragmentCount {
            let start = index * chunkSize
            let end = min(frame.payload.count, start + chunkSize)
            var fragmentPlaintext = Data(capacity: 8 + (end - start))
            fragmentPlaintext.appendUInt32BE(frame.sequenceNumber)
            fragmentPlaintext.appendUInt32BE(UInt32(frame.payload.count))
            fragmentPlaintext.append(frame.payload.subdata(in: start..<end))
            packets.append(try encodePacket(
                type: .fragment,
                plaintext: fragmentPlaintext,
                fragmentID: fragmentID,
                fragmentIndex: UInt16(index),
                fragmentCount: UInt16(fragmentCount)
            ))
        }
        return packets
    }

    private func encodePacket(
        type: SwitchUDPPacketType,
        plaintext: Data,
        fragmentID: UInt32 = 0,
        fragmentIndex: UInt16 = 0,
        fragmentCount: UInt16 = 0
    ) throws -> Data {
        let packetNumber = nextPacketNumber
        nextPacketNumber = nextPacketNumber == UInt64.max ? 1 : nextPacketNumber + 1
        let header = Self.encodeHeader(
            type: type,
            keyID: keyID,
            sessionID: sessionID,
            packetNumber: packetNumber,
            fragmentID: fragmentID,
            fragmentIndex: fragmentIndex,
            fragmentCount: fragmentCount
        )
        let nonce = try AES.GCM.Nonce(data: Self.nonce(prefix: keys.clientToServer.noncePrefix, packetNumber: packetNumber))
        let sealed = try AES.GCM.seal(
            plaintext,
            using: keys.clientToServer.key,
            nonce: nonce,
            authenticating: header
        )
        var packet = header
        packet.append(sealed.ciphertext)
        packet.append(sealed.tag)
        return packet
    }

    private func enqueue(_ packet: Data) -> Bool {
        guard let connection, state != .stopped, state != .fallback else { return false }
        refillTokens()
        if sendQueue.isEmpty, tokens >= Double(packet.count) {
            tokens -= Double(packet.count)
            sendRaw(packet, connection: connection)
            return true
        }
        guard sendQueue.count < maxQueuedPackets,
              queuedBytes + packet.count <= maxQueuedBytes else {
            return false
        }
        sendQueue.append(SwitchUDPQueuedPacket(packet: packet, queuedAt: Date()))
        queuedBytes += packet.count
        schedulePacer()
        return true
    }

    private func refillTokens() {
        let now = Date()
        let elapsed = max(0, now.timeIntervalSince(lastRefillAt))
        lastRefillAt = now
        tokens = min(bytesPerSecond, tokens + elapsed * bytesPerSecond)
    }

    private var bytesPerSecond: Double {
        let capped = maxMbps > 0 ? min(currentMbps, maxMbps) : currentMbps
        return max(capped, minMbps) * 125_000
    }

    private func flushQueue() {
        guard let connection, state != .stopped, state != .fallback else { return }
        pacerWorkItem = nil
        refillTokens()
        while let next = sendQueue.first, tokens >= Double(next.packet.count) {
            sendQueue.removeFirst()
            queuedBytes -= next.packet.count
            tokens -= Double(next.packet.count)
            sendRaw(next.packet, connection: connection)
        }
        if !sendQueue.isEmpty {
            schedulePacer()
        }
    }

    private func schedulePacer() {
        guard pacerWorkItem == nil, let next = sendQueue.first else { return }
        let needed = max(0, Double(next.packet.count) - tokens)
        let delay = max(0.001, needed / bytesPerSecond)
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushQueue()
        }
        pacerWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelPacer() {
        pacerWorkItem?.cancel()
        pacerWorkItem = nil
    }

    private func sendRaw(_ packet: Data, connection: NWConnection) {
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.queue.async {
                self.failOrFallback("UDP send failed: \(error.localizedDescription)")
            }
        })
    }

    private static func deriveKeys(
        clientRandom: Data,
        serverRandom: Data,
        sessionID: Data,
        keyID: UInt8,
        clientIdentity: String,
        serverIdentity: String
    ) throws -> SwitchUDPKeySet {
        SwitchUDPKeySet(
            clientToServer: try deriveKeyMaterial(
                clientRandom: clientRandom,
                serverRandom: serverRandom,
                sessionID: sessionID,
                keyID: keyID,
                clientIdentity: clientIdentity,
                serverIdentity: serverIdentity,
                direction: "client-to-server"
            ),
            serverToClient: try deriveKeyMaterial(
                clientRandom: clientRandom,
                serverRandom: serverRandom,
                sessionID: sessionID,
                keyID: keyID,
                clientIdentity: clientIdentity,
                serverIdentity: serverIdentity,
                direction: "server-to-client"
            )
        )
    }

    private static func deriveKeyMaterial(
        clientRandom: Data,
        serverRandom: Data,
        sessionID: Data,
        keyID: UInt8,
        clientIdentity: String,
        serverIdentity: String,
        direction: String
    ) throws -> SwitchUDPKeyMaterial {
        var ikm = Data()
        ikm.append(clientRandom)
        ikm.append(serverRandom)
        var salt = Data(protocolLabel.utf8)
        salt.append(0)
        salt.append(sessionID)
        let info = Data([
            protocolLabel,
            "key=\(keyID)",
            direction,
            "client=\(clientIdentity)",
            "server=\(serverIdentity)"
        ].joined(separator: "\n").utf8)
        let materialKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: 36
        )
        let material = materialKey.withUnsafeBytes { Data($0) }
        guard material.count == 36 else {
            throw AppError("Failed to derive switch UDP key material.")
        }
        return SwitchUDPKeyMaterial(
            key: SymmetricKey(data: material.prefix(32)),
            noncePrefix: material.subdata(in: 32..<36)
        )
    }

    private static func parsePacket(_ datagram: Data) -> SwitchUDPParsedPacket? {
        guard datagram.count >= headerSize + authTagSize else { return nil }
        let bytes = [UInt8](datagram.prefix(headerSize))
        guard bytes[0] == 0x4f, bytes[1] == 0x4b, bytes[2] == 0x53, bytes[3] == 0x55, bytes[4] == 1,
              let type = SwitchUDPPacketType(rawValue: bytes[5]) else {
            return nil
        }
        let ciphertextEnd = datagram.count - authTagSize
        return SwitchUDPParsedPacket(
            header: datagram.subdata(in: 0..<headerSize),
            type: type,
            keyID: bytes[7],
            sessionID: datagram.subdata(in: 8..<24),
            packetNumber: datagram.readUInt64BE(at: 24),
            fragmentID: datagram.readUInt32BE(at: 32),
            fragmentIndex: datagram.readUInt16BE(at: 36),
            fragmentCount: datagram.readUInt16BE(at: 38),
            ciphertext: datagram.subdata(in: headerSize..<ciphertextEnd),
            tag: datagram.subdata(in: ciphertextEnd..<datagram.count)
        )
    }

    private static func decrypt(_ packet: SwitchUDPParsedPacket, keyMaterial: SwitchUDPKeyMaterial) throws -> Data {
        let nonce = try AES.GCM.Nonce(data: nonce(prefix: keyMaterial.noncePrefix, packetNumber: packet.packetNumber))
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: packet.ciphertext, tag: packet.tag)
        return try AES.GCM.open(sealed, using: keyMaterial.key, authenticating: packet.header)
    }

    private static func encodeHeader(
        type: SwitchUDPPacketType,
        keyID: UInt8,
        sessionID: Data,
        packetNumber: UInt64,
        fragmentID: UInt32,
        fragmentIndex: UInt16,
        fragmentCount: UInt16
    ) -> Data {
        var header = Data(capacity: headerSize)
        header.append(contentsOf: [0x4f, 0x4b, 0x53, 0x55, 1, type.rawValue, 0, keyID])
        header.append(sessionID)
        header.appendUInt64BE(packetNumber)
        header.appendUInt32BE(fragmentID)
        header.appendUInt16BE(fragmentIndex)
        header.appendUInt16BE(fragmentCount)
        return header
    }

    private static func nonce(prefix: Data, packetNumber: UInt64) -> Data {
        var nonce = Data(capacity: 12)
        nonce.append(prefix)
        nonce.appendUInt64BE(packetNumber)
        return nonce
    }
}

private final class SwitchUDPReplayWindow {
    private let size: UInt64
    private var highest: UInt64?
    private var seen: Set<UInt64> = []

    init(size: UInt64 = 4096) {
        self.size = size
    }

    func accept(_ packetNumber: UInt64) -> Bool {
        if let currentHighest = highest {
            if packetNumber > currentHighest {
                highest = packetNumber
                prune()
            } else if currentHighest - packetNumber >= size {
                return false
            }
        } else {
            highest = packetNumber
        }
        guard !seen.contains(packetNumber) else { return false }
        seen.insert(packetNumber)
        return true
    }

    private func prune() {
        guard let highest else { return }
        let minimum = highest > size ? highest - size + 1 : 0
        seen = seen.filter { $0 >= minimum }
    }
}

private final class SwitchUDPFragmentReassembler {
    private struct Entry {
        var sequenceNumber: UInt32
        var totalLength: Int
        var fragmentCount: Int
        var createdAt: Date
        var receivedBytes: Int
        var fragments: [Data?]
    }

    private let maxFrameSize: Int
    private var entries: [String: Entry] = [:]
    private var completed: [String: Date] = [:]
    private var reassemblyBytes = 0
    private let maxEntries = 64
    private let maxBytes = 1024 * 1024
    private let timeout: TimeInterval = 1
    private let completedTTL: TimeInterval = 2

    init(maxFrameSize: Int) {
        self.maxFrameSize = maxFrameSize
    }

    func accept(parsed: SwitchUDPParsedPacket, plaintext: Data) -> SwitchFrame? {
        expire()
        let key = "\(parsed.keyID):\(parsed.fragmentID)"
        if completed[key] != nil { return nil }
        guard parsed.fragmentCount > 1,
              parsed.fragmentCount <= SwitchUDPDataPlane.maxFragments,
              parsed.fragmentIndex < parsed.fragmentCount,
              plaintext.count >= 8 else {
            return nil
        }
        let sequenceNumber = plaintext.readUInt32BE(at: 0)
        let totalLength = Int(plaintext.readUInt32BE(at: 4))
        let chunk = plaintext.subdata(in: 8..<plaintext.count)
        guard totalLength > 0, totalLength <= maxFrameSize else { return nil }

        var entry = entries[key]
        if entry == nil {
            guard entries.count < maxEntries, reassemblyBytes + totalLength <= maxBytes else { return nil }
            entry = Entry(
                sequenceNumber: sequenceNumber,
                totalLength: totalLength,
                fragmentCount: Int(parsed.fragmentCount),
                createdAt: Date(),
                receivedBytes: 0,
                fragments: Array(repeating: nil, count: Int(parsed.fragmentCount))
            )
            reassemblyBytes += totalLength
        }
        guard var current = entry,
              current.sequenceNumber == sequenceNumber,
              current.totalLength == totalLength,
              current.fragmentCount == Int(parsed.fragmentCount) else {
            return nil
        }
        let index = Int(parsed.fragmentIndex)
        guard current.fragments[index] == nil else { return nil }
        current.fragments[index] = chunk
        current.receivedBytes += chunk.count
        guard current.receivedBytes <= totalLength else {
            removeEntry(key)
            return nil
        }
        entries[key] = current

        guard current.fragments.allSatisfy({ $0 != nil }) else { return nil }
        let payload = current.fragments.reduce(into: Data()) { partial, fragment in
            partial.append(fragment!)
        }
        removeEntry(key)
        guard payload.count == totalLength else { return nil }
        completed[key] = Date()
        if completed.count > 1024, let oldest = completed.min(by: { $0.value < $1.value })?.key {
            completed.removeValue(forKey: oldest)
        }
        return SwitchFrame(
            streamID: SwitchFrame.ethernetStreamID,
            type: .data,
            sequenceNumber: sequenceNumber,
            payload: payload
        )
    }

    private func expire() {
        let now = Date()
        for (key, entry) in entries where now.timeIntervalSince(entry.createdAt) > timeout {
            removeEntry(key)
        }
        completed = completed.filter { now.timeIntervalSince($0.value) <= completedTTL }
    }

    private func removeEntry(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        reassemblyBytes = max(0, reassemblyBytes - entry.totalLength)
    }
}

extension Data {
    init?(base64URLEncoded text: String) {
        var normalized = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: normalized)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        append(UInt8((value >> 56) & 0xff))
        append(UInt8((value >> 48) & 0xff))
        append(UInt8((value >> 40) & 0xff))
        append(UInt8((value >> 32) & 0xff))
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    func readUInt16BE(at offset: Int) -> UInt16 {
        let bytes = [UInt8](self)
        return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        let bytes = [UInt8](self)
        return (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    func readUInt64BE(at offset: Int) -> UInt64 {
        let bytes = [UInt8](self)
        return (UInt64(bytes[offset]) << 56)
            | (UInt64(bytes[offset + 1]) << 48)
            | (UInt64(bytes[offset + 2]) << 40)
            | (UInt64(bytes[offset + 3]) << 32)
            | (UInt64(bytes[offset + 4]) << 24)
            | (UInt64(bytes[offset + 5]) << 16)
            | (UInt64(bytes[offset + 6]) << 8)
            | UInt64(bytes[offset + 7])
    }

    static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
}
