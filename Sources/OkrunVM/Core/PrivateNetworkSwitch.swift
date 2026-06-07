import Foundation
import Network
import Security

enum SwitchFrameType: UInt8, Equatable {
    case data = 0x02
    case error = 0x04
    case initFrame = 0x05
    case ping = 0x06
    case pong = 0x07
    case resetSeq = 0x09
    case memberUpdate = 0x0a
}

struct SwitchFrame: Equatable {
    static let headerSize = 13
    static let controlStreamID: UInt32 = 0
    static let ethernetStreamID: UInt32 = 1
    static let defaultMaxFrameSize = 70_000

    var streamID: UInt32
    var type: SwitchFrameType
    var sequenceNumber: UInt32
    var payload: Data
}

enum SwitchFrameProtocol {
    static func encode(_ frame: SwitchFrame) throws -> Data {
        guard frame.payload.count <= UInt32.max else {
            throw AppError("Switch frame payload is too large.")
        }

        var data = Data(capacity: SwitchFrame.headerSize + frame.payload.count)
        appendUInt32(frame.streamID, to: &data)
        data.append(frame.type.rawValue)
        appendUInt32(frame.sequenceNumber, to: &data)
        appendUInt32(UInt32(frame.payload.count), to: &data)
        data.append(frame.payload)
        return data
    }

    static func encodeJSON<T: Encodable>(
        type: SwitchFrameType,
        value: T,
        sequenceNumber: UInt32 = 0
    ) throws -> Data {
        let encoder = JSONEncoder()
        let payload = try encoder.encode(value)
        return try encode(SwitchFrame(
            streamID: SwitchFrame.controlStreamID,
            type: type,
            sequenceNumber: sequenceNumber,
            payload: payload
        ))
    }

    fileprivate static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    fileprivate static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }
}

final class SwitchFrameDecoder {
    private let maxPayloadLength: Int
    private var buffer = Data()
    private(set) var isDestroyed = false

    init(maxPayloadLength: Int = SwitchFrame.defaultMaxFrameSize) {
        self.maxPayloadLength = maxPayloadLength
    }

    func push(_ chunk: Data) throws -> [SwitchFrame] {
        guard !isDestroyed else { return [] }
        buffer.append(chunk)

        var frames: [SwitchFrame] = []
        while buffer.count >= SwitchFrame.headerSize {
            let bytes = [UInt8](buffer.prefix(SwitchFrame.headerSize))
            let payloadLength = Int(SwitchFrameProtocol.readUInt32(bytes, 9))
            guard payloadLength <= maxPayloadLength else {
                isDestroyed = true
                buffer.removeAll()
                throw AppError("Switch frame payload length \(payloadLength) exceeds \(maxPayloadLength).")
            }

            let frameLength = SwitchFrame.headerSize + payloadLength
            guard buffer.count >= frameLength else {
                break
            }

            guard let type = SwitchFrameType(rawValue: bytes[4]) else {
                isDestroyed = true
                buffer.removeAll()
                throw AppError("Unsupported switch frame type \(bytes[4]).")
            }

            let payloadStart = buffer.index(buffer.startIndex, offsetBy: SwitchFrame.headerSize)
            let payloadEnd = buffer.index(buffer.startIndex, offsetBy: frameLength)
            let payload = Data(buffer[payloadStart..<payloadEnd])
            frames.append(SwitchFrame(
                streamID: SwitchFrameProtocol.readUInt32(bytes, 0),
                type: type,
                sequenceNumber: SwitchFrameProtocol.readUInt32(bytes, 5),
                payload: payload
            ))
            buffer.removeSubrange(buffer.startIndex..<payloadEnd)
        }

        return frames
    }
}

final class SwitchDedupWindow {
    private let size: Int
    private let byteCount: Int
    private var base: UInt32?
    private var bits: [UInt8]

    init(size: Int = 128) {
        precondition((1...1024).contains(size), "Dedup window size must be between 1 and 1024.")
        self.size = size
        byteCount = Int(ceil(Double(size) / 8.0))
        bits = Array(repeating: 0, count: byteCount)
    }

    func reset() {
        base = nil
        bits = Array(repeating: 0, count: byteCount)
    }

    func accept(_ sequenceNumber: UInt32) -> Bool {
        guard let currentBase = base else {
            base = sequenceNumber
            set(0)
            return true
        }

        var offset = sequenceNumber &- currentBase
        if offset > 0x8000_0000 {
            return false
        }

        if offset >= UInt32(size) {
            let shift = Int(offset - UInt32(size) + 1)
            base = currentBase &+ UInt32(shift)
            shiftLeft(shift)
            offset = sequenceNumber &- (base ?? sequenceNumber)
        }

        let intOffset = Int(offset)
        guard !isSet(intOffset) else { return false }
        set(intOffset)
        return true
    }

    private func set(_ offset: Int) {
        bits[offset >> 3] |= UInt8(1 << (offset & 7))
    }

    private func isSet(_ offset: Int) -> Bool {
        (bits[offset >> 3] & UInt8(1 << (offset & 7))) != 0
    }

    private func shiftLeft(_ count: Int) {
        guard count > 0 else { return }
        guard count < size else {
            bits = Array(repeating: 0, count: byteCount)
            return
        }

        let byteShift = count >> 3
        let bitShift = count & 7

        if byteShift > 0 {
            for index in 0..<(byteCount - byteShift) {
                bits[index] = bits[index + byteShift]
            }
            for index in (byteCount - byteShift)..<byteCount {
                bits[index] = 0
            }
        }

        if bitShift > 0 {
            for index in 0..<(byteCount - 1) {
                bits[index] = UInt8((UInt16(bits[index]) >> UInt16(bitShift))
                    | ((UInt16(bits[index + 1]) << UInt16(8 - bitShift)) & 0xff))
            }
            bits[byteCount - 1] >>= UInt8(bitShift)
        }
    }
}

struct PrivateNetworkSwitchEndpoint: Equatable {
    var host: String
    var port: UInt16

    var description: String {
        "\(host):\(port)"
    }

    static func parse(_ server: String, label: String) throws -> PrivateNetworkSwitchEndpoint {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError("\(label) server must not be empty when enabled.")
        }
        guard trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "\0")) == nil else {
            throw AppError("\(label) server must not contain NUL.")
        }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              let port = UInt16(parts[1]),
              port > 0 else {
            throw AppError("\(label) server must be host:port with port between 1 and 65535.")
        }

        let host = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw AppError("\(label) server host must not be empty.")
        }

        return PrivateNetworkSwitchEndpoint(host: host, port: port)
    }
}

enum SwitchDataTransportMode: String, Codable, Equatable, CaseIterable {
    case auto
    case tcp
    case udp

    var transportPreference: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .auto:
            return "Auto"
        case .tcp:
            return "TCP/TLS Compatibility"
        case .udp:
            return "UDP Accelerated"
        }
    }
}

struct PrivateNetworkSwitchConfig: Codable, Equatable {
    var enabled: Bool
    var server: String
    var caCert: String
    var clientCert: String
    var clientKey: String
    var credentialFingerprint: String
    var transportMode: SwitchDataTransportMode

    enum CodingKeys: String, CodingKey {
        case enabled
        case server
        case caCert
        case clientCert
        case clientKey
        case credentialFingerprint
        case transportMode
    }

    init(
        enabled: Bool = false,
        server: String = "",
        caCert: String = "",
        clientCert: String = "",
        clientKey: String = "",
        credentialFingerprint: String = "",
        transportMode: SwitchDataTransportMode = .auto
    ) {
        self.enabled = enabled
        self.server = server
        self.caCert = caCert
        self.clientCert = clientCert
        self.clientKey = clientKey
        self.credentialFingerprint = credentialFingerprint
        self.transportMode = transportMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        server = try container.decodeIfPresent(String.self, forKey: .server) ?? ""
        caCert = try container.decodeIfPresent(String.self, forKey: .caCert) ?? ""
        clientCert = try container.decodeIfPresent(String.self, forKey: .clientCert) ?? ""
        clientKey = try container.decodeIfPresent(String.self, forKey: .clientKey) ?? ""
        credentialFingerprint = try container.decodeIfPresent(String.self, forKey: .credentialFingerprint) ?? ""
        // Existing saved Web Switch configs predate UDP and must remain TCP/TLS-only until users opt in.
        transportMode = try container.decodeIfPresent(SwitchDataTransportMode.self, forKey: .transportMode) ?? .tcp
    }

    func validated() throws -> PrivateNetworkSwitchConfig {
        guard enabled else { return self }
        _ = try endpoint()
        for (label, path) in [
            ("caCert", caCert),
            ("clientCert", clientCert),
            ("clientKey", clientKey)
        ] {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw AppError("private network switch \(label) path must not be empty when enabled.")
            }
            guard trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "\0")) == nil else {
                throw AppError("private network switch \(label) path must not contain NUL.")
            }
        }
        guard credentialFingerprint.rangeOfCharacter(from: CharacterSet(charactersIn: "\0")) == nil else {
            throw AppError("private network switch credential fingerprint must not contain NUL.")
        }
        return self
    }

    func endpoint() throws -> PrivateNetworkSwitchEndpoint {
        try PrivateNetworkSwitchEndpoint.parse(server, label: "private network switch")
    }
}

struct PrivateNetworkLocalSwitchConfig: Codable, Equatable {
    var enabled: Bool
    var server: String

    init(
        enabled: Bool = false,
        server: String = ""
    ) {
        self.enabled = enabled
        self.server = server
    }

    func validated() throws -> PrivateNetworkLocalSwitchConfig {
        guard enabled else { return self }
        let endpoint = try endpoint()
        let host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard host != "0.0.0.0", host != "::", host != "*" else {
            throw AppError("private network local switch server must be a reachable host, not a wildcard bind address.")
        }
        return self
    }

    func endpoint() throws -> PrivateNetworkSwitchEndpoint {
        try PrivateNetworkSwitchEndpoint.parse(server, label: "private network local switch")
    }
}

struct SwitchTLSCredentials: Equatable {
    var caCert: String
    var clientCert: String
    var clientKey: String
}

enum SwitchConnectionSecurity: Equatable {
    case tls(SwitchTLSCredentials)
    case none
}

struct PrivateNetworkSwitchConnectionConfig: Equatable {
    var server: String
    var credentialFingerprint: String
    var security: SwitchConnectionSecurity
    var transportMode: SwitchDataTransportMode

    static func webSwitch(_ config: PrivateNetworkSwitchConfig) throws -> PrivateNetworkSwitchConnectionConfig {
        let validated = try config.validated()
        return PrivateNetworkSwitchConnectionConfig(
            server: validated.server,
            credentialFingerprint: validated.credentialFingerprint,
            security: .tls(SwitchTLSCredentials(
                caCert: validated.caCert,
                clientCert: validated.clientCert,
                clientKey: validated.clientKey
            )),
            transportMode: validated.transportMode
        )
    }

    static func localSwitch(_ config: PrivateNetworkLocalSwitchConfig) throws -> PrivateNetworkSwitchConnectionConfig {
        let validated = try config.validated()
        return PrivateNetworkSwitchConnectionConfig(
            server: validated.server,
            credentialFingerprint: "",
            security: .none,
            transportMode: .tcp
        )
    }

    func endpoint() throws -> PrivateNetworkSwitchEndpoint {
        let label: String
        switch security {
        case .tls:
            label = "private network switch"
        case .none:
            label = "private network local switch"
        }
        return try PrivateNetworkSwitchEndpoint.parse(server, label: label)
    }
}

enum PrivateNetworkSwitchConnectionState: String, Equatable {
    case disabled
    case connecting
    case connected
    case failed
    case rejected
}

struct PrivateNetworkSwitchStatus: Equatable {
    var identifier: String
    var server: String?
    var state: PrivateNetworkSwitchConnectionState
    var activeConnections: Int
    var message: String
    var errorMessage: String?

    var isConnected: Bool {
        state == .connected
    }

    static func disabled(identifier: String) -> PrivateNetworkSwitchStatus {
        PrivateNetworkSwitchStatus(
            identifier: identifier,
            server: nil,
            state: .disabled,
            activeConnections: 0,
            message: "Switch disabled",
            errorMessage: nil
        )
    }

    static func failed(identifier: String, server: String?, error: String) -> PrivateNetworkSwitchStatus {
        PrivateNetworkSwitchStatus(
            identifier: identifier,
            server: server,
            state: .failed,
            activeConnections: 0,
            message: "Switch failed",
            errorMessage: error
        )
    }
}

final class PendingSwitchWriteBuffer {
    static let defaultLimit = 512
    static let defaultMaxAge: TimeInterval = 15

    private struct Entry {
        var data: Data
        var queuedAt: Date
    }

    private let limit: Int
    private let maxAge: TimeInterval
    private var entries: [Entry] = []

    init(limit: Int = defaultLimit, maxAge: TimeInterval = defaultMaxAge) {
        precondition(limit > 0, "Pending write buffer limit must be positive.")
        precondition(maxAge >= 0, "Pending write max age must not be negative.")
        self.limit = limit
        self.maxAge = maxAge
    }

    var count: Int {
        entries.count
    }

    @discardableResult
    func append(_ data: Data, at now: Date = Date()) -> Bool {
        pruneExpired(at: now)
        guard entries.count < limit else { return false }
        entries.append(Entry(data: data, queuedAt: now))
        return true
    }

    func flush(at now: Date = Date()) -> (writes: [Data], dropped: Int) {
        let freshEntries = entries.filter { now.timeIntervalSince($0.queuedAt) <= maxAge }
        let dropped = entries.count - freshEntries.count
        entries.removeAll()
        return (freshEntries.map(\.data), dropped)
    }

    func removeAll() {
        entries.removeAll()
    }

    private func pruneExpired(at now: Date) {
        entries.removeAll { now.timeIntervalSince($0.queuedAt) > maxAge }
    }
}

private struct SwitchInitPayload: Codable {
    var `protocol`: String
    var nodeID: String
    var networkIdentifier: String
    var `interface`: String
    var maxFrameSize: Int
    var dhcpRange: PrivateNetworkDHCPLeaseRange?
    var capabilities: [String]
    var transportPreference: String?
    var clientRandom: String?
}

private struct SwitchInitAckPayload: Codable {
    var `protocol`: String
    var maxFrameSize: Int
    var maxConnectionsPerHost: Int?
    var keepaliveIntervalMs: Int?
    var keepaliveTimeoutMs: Int?
    var networkMemberCount: Int?
    var localMemberCount: Int?
    var dataPlane: SwitchUDPDataPlaneAck?
}

private struct SwitchErrorPayload: Codable {
    var code: String?
    var message: String?
}

enum SwitchServerErrorRetryPolicy: Equatable {
    case none
    case delayed(TimeInterval)

    static let rejectedReconnectDelay: TimeInterval = 60

    static func policy(for code: String?) -> SwitchServerErrorRetryPolicy {
        guard let code else {
            return .delayed(rejectedReconnectDelay)
        }

        switch code {
        case "certificate_revoked",
             "same_node_different_certificate",
             "too_many_connections",
             "dhcp_range_overlap":
            return .delayed(rejectedReconnectDelay)
        case "invalid_init",
             "unsupported_protocol",
             "invalid_node_id",
             "invalid_network_identifier",
             "invalid_interface",
             "invalid_max_frame_size",
             "invalid_dhcp_range",
             "invalid_ipv4",
             "data_before_init",
             "duplicate_init",
             "bad_stream",
             "bad_frame_type",
             "empty_frame",
             "frame_too_large",
             "reset_before_init",
             "invalid_reset_seq",
             "unsupported_frame_type",
             "protocol_error":
            return .none
        default:
            return .delayed(rejectedReconnectDelay)
        }
    }
}

private struct SwitchResetSeqPayload: Codable {
    var streams: [UInt32]
}

private struct SwitchMemberUpdatePayload: Codable {
    var networkMemberCount: Int
    var localMemberCount: Int?
}

private enum SwitchDebug {
    static let enabled = ProcessInfo.processInfo.environment["OKRUN_SWITCH_DEBUG"] == "1"

    static func log(_ message: String) {
        guard enabled else { return }
        let line = "OKRUN_SWITCH_DEBUG \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

final class PrivateNetworkSwitchClient {
    var onFrame: ((Data) -> Void)?
    var onStatusChange: ((PrivateNetworkSwitchConnectionState, String, Int, String?) -> Void)?

    private let identifier: String
    private let config: PrivateNetworkSwitchConnectionConfig
    private let dhcpRange: PrivateNetworkDHCPLeaseRange?
    private let nodeID: UUID
    private let interfaceName: String
    private let socket: VirtualSwitchSocket

    init(
        identifier: String,
        config: PrivateNetworkSwitchConnectionConfig,
        dhcpRange: PrivateNetworkDHCPLeaseRange?,
        interfaceName: String,
        nodeID: UUID = UUID()
    ) throws {
        self.identifier = identifier
        self.config = config
        self.dhcpRange = dhcpRange
        self.nodeID = nodeID
        self.interfaceName = interfaceName
        socket = try VirtualSwitchSocket(
            identifier: identifier,
            config: self.config,
            dhcpRange: dhcpRange,
            nodeID: nodeID,
            interfaceName: interfaceName
        )

        socket.onFrame = { [weak self] frame in
            self?.onFrame?(frame)
        }
        socket.onStatusChange = { [weak self] state, message, connections, error in
            self?.onStatusChange?(state, message, connections, error)
        }
    }

    func start() {
        socket.start()
    }

    func stop() {
        socket.stop()
    }

    func send(_ frame: Data) {
        socket.send(frame)
    }

    func matches(config: PrivateNetworkSwitchConnectionConfig, dhcpRange: PrivateNetworkDHCPLeaseRange?) -> Bool {
        config == self.config && dhcpRange == self.dhcpRange
    }
}

private final class VirtualSwitchSocket {
    var onFrame: ((Data) -> Void)?
    var onStatusChange: ((PrivateNetworkSwitchConnectionState, String, Int, String?) -> Void)?

    private let identifier: String
    private let realSocket: RealSwitchSocket
    private var outgoingSequenceNumber: UInt32 = 0
    private let incomingDedup = SwitchDedupWindow()
    private let queue = DispatchQueue(label: "okrun.switch.virtual.\(UUID().uuidString)")

    init(
        identifier: String,
        config: PrivateNetworkSwitchConnectionConfig,
        dhcpRange: PrivateNetworkDHCPLeaseRange?,
        nodeID: UUID,
        interfaceName: String
    ) throws {
        self.identifier = identifier
        realSocket = try RealSwitchSocket(
            identifier: identifier,
            config: config,
            dhcpRange: dhcpRange,
            nodeID: nodeID,
            interfaceName: interfaceName
        )

        realSocket.onFrame = { [weak self] frame in
            guard frame.type == .data, frame.streamID == SwitchFrame.ethernetStreamID else { return }
            self?.queue.async {
                guard self?.incomingDedup.accept(frame.sequenceNumber) == true else { return }
                self?.onFrame?(frame.payload)
            }
        }
        realSocket.onResetSeq = { [weak self] streams in
            self?.queue.async {
                if streams.contains(SwitchFrame.ethernetStreamID) {
                    self?.incomingDedup.reset()
                }
            }
        }
        realSocket.onInitialized = { [weak self] in
            self?.queue.async {
                guard let self else { return }
                self.incomingDedup.reset()
                AppLog.webSwitch.info(
                    "reset incoming dedup after init network=\(self.identifier, privacy: .public)"
                )
            }
        }
        realSocket.onStatusChange = { [weak self] state, message, connections, error in
            self?.onStatusChange?(state, message, connections, error)
        }
    }

    func start() {
        realSocket.start()
    }

    func stop() {
        realSocket.stop()
    }

    func send(_ frame: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            outgoingSequenceNumber = outgoingSequenceNumber == UInt32.max ? 1 : outgoingSequenceNumber + 1
            let switchFrame = SwitchFrame(
                streamID: SwitchFrame.ethernetStreamID,
                type: .data,
                sequenceNumber: outgoingSequenceNumber,
                payload: frame
            )
            SwitchDebug.log("queue DATA seq=\(outgoingSequenceNumber) bytes=\(frame.count)")
            self.realSocket.sendDataFrame(switchFrame)
        }
    }
}

private final class RealSwitchSocket {
    private static let initialReconnectDelay: TimeInterval = 0.5
    private static let maxReconnectDelay: TimeInterval = 3
    private static let networkPathReconnectDelay: TimeInterval = 2
    private static let webConnectionTimeout: TimeInterval = 25
    private static let localConnectionTimeout: TimeInterval = 3
    private static let initResponseTimeout: TimeInterval = 10
    private static let defaultWebKeepaliveInterval: TimeInterval = 10
    private static let defaultWebKeepaliveTimeout: TimeInterval = 25
    private static let defaultLocalKeepaliveInterval: TimeInterval = 0.5
    private static let defaultLocalKeepaliveTimeout: TimeInterval = 1.5

    var onFrame: ((SwitchFrame) -> Void)?
    var onResetSeq: (([UInt32]) -> Void)?
    var onInitialized: (() -> Void)?
    var onStatusChange: ((PrivateNetworkSwitchConnectionState, String, Int, String?) -> Void)?

    private let identifier: String
    private let config: PrivateNetworkSwitchConnectionConfig
    private let endpoint: PrivateNetworkSwitchEndpoint
    private let dhcpRange: PrivateNetworkDHCPLeaseRange?
    private let nodeID: UUID
    private let interfaceName: String
    private let queue = DispatchQueue(label: "okrun.switch.real.\(UUID().uuidString)")
    private var decoder: SwitchFrameDecoder
    private var connection: NWConnection?
    private var pendingWrites = PendingSwitchWriteBuffer()
    private var initialized = false
    private var stopped = false
    private var maxFrameSize: Int
    private var reconnectDelay = RealSwitchSocket.initialReconnectDelay
    private var reconnectAttempts = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var initResponseWorkItem: DispatchWorkItem?
    private var clientKeepaliveWorkItem: DispatchWorkItem?
    private var networkPathReconnectWorkItem: DispatchWorkItem?
    private var lastPongAt: Date?
    private var clientKeepaliveInterval = RealSwitchSocket.defaultLocalKeepaliveInterval
    private var clientKeepaliveTimeout = RealSwitchSocket.defaultLocalKeepaliveTimeout
    private var pathMonitor: NWPathMonitor?
    private var pathSnapshot: NetworkPathSnapshot?
    private var udpClientRandom: Data?
    private var udpDataPlane: SwitchUDPDataPlane?
    private var lastMemberCount = 0

    init(
        identifier: String,
        config: PrivateNetworkSwitchConnectionConfig,
        dhcpRange: PrivateNetworkDHCPLeaseRange?,
        nodeID: UUID,
        interfaceName: String
    ) throws {
        self.identifier = identifier
        self.config = config
        endpoint = try self.config.endpoint()
        self.dhcpRange = dhcpRange
        self.nodeID = nodeID
        self.interfaceName = interfaceName
        maxFrameSize = SwitchFrame.defaultMaxFrameSize
        decoder = SwitchFrameDecoder(maxPayloadLength: maxFrameSize)
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            stopped = false
            reconnectDelay = Self.initialReconnectDelay
            reconnectAttempts = 0
            pendingWrites.removeAll()
            startNetworkPathMonitorOnQueue()
            startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            stopped = true
            AppLog.webSwitch.info(
                "stop network=\(self.identifier, privacy: .public) server=\(self.endpoint.description, privacy: .public)"
            )
            cancelReconnect()
            cancelNetworkPathReconnect()
            cancelConnectionTimeout()
            cancelInitResponseTimeout()
            cancelClientKeepalive()
            stopNetworkPathMonitorOnQueue()
            stopUDPDataPlaneOnQueue()
            connection?.cancel()
            connection = nil
            pendingWrites.removeAll()
        }
    }

    func sendEncoded(_ data: Data) {
        queue.async { [weak self] in
            self?.sendEncodedOnQueue(data)
        }
    }

    func sendDataFrame(_ frame: SwitchFrame) {
        queue.async { [weak self] in
            self?.sendDataFrameOnQueue(frame)
        }
    }

    private func startOnQueue() {
        guard !stopped else { return }
        initialized = false
        stopUDPDataPlaneOnQueue()
        maxFrameSize = SwitchFrame.defaultMaxFrameSize
        let keepaliveDefaults = defaultKeepaliveTiming
        clientKeepaliveInterval = keepaliveDefaults.interval
        clientKeepaliveTimeout = keepaliveDefaults.timeout
        decoder = SwitchFrameDecoder(maxPayloadLength: maxFrameSize)
        AppLog.webSwitch.info(
            "connect start network=\(self.identifier, privacy: .public) server=\(self.endpoint.description, privacy: .public) attempt=\(self.reconnectAttempts, privacy: .public)"
        )
        report(.connecting, "Connecting to \(endpoint.description).", connections: 0, error: nil)

        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            let parameters: NWParameters
            switch config.security {
            case .tls(let credentials):
                let identity = try SwitchTLSIdentity.load(credentials: credentials)
                let caCertificate = try SwitchTLSIdentity.loadCertificate(path: credentials.caCert)
                let tlsOptions = NWProtocolTLS.Options()
                configureTLSOptions(tlsOptions, identity: identity, caCertificate: caCertificate)
                parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
            case .none:
                parameters = NWParameters(tls: nil, tcp: tcpOptions)
            }
            parameters.allowLocalEndpointReuse = true
            let connection = NWConnection(
                host: NWEndpoint.Host(endpoint.host),
                port: NWEndpoint.Port(rawValue: endpoint.port)!,
                using: parameters
            )
            self.connection = connection
            scheduleConnectionTimeout(for: connection)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                self?.queue.async {
                    guard let self, let connection, connection === self.connection else { return }
                    self.handleState(state, for: connection)
                }
            }
            connection.start(queue: queue)
        } catch {
            AppLog.webSwitch.error(
                "connect preparation failed network=\(self.identifier, privacy: .public) server=\(self.endpoint.description, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            report(.failed, error.localizedDescription, connections: 0, error: error.localizedDescription)
        }
    }

    private func configureTLSOptions(
        _ tlsOptions: NWProtocolTLS.Options,
        identity: sec_identity_t,
        caCertificate: SecCertificate
    ) {
        let securityOptions = tlsOptions.securityProtocolOptions
        sec_protocol_options_set_tls_server_name(securityOptions, endpoint.host)
        sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv12)
        sec_protocol_options_set_local_identity(securityOptions, identity)

        let verifyQueue = DispatchQueue(label: "okrun.switch.tls.verify.\(UUID().uuidString)")
        sec_protocol_options_set_verify_block(securityOptions, { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            let policy = SecPolicyCreateSSL(true, self.endpoint.host as CFString)
            SecTrustSetPolicies(trust, policy)
            SecTrustSetAnchorCertificates(trust, [caCertificate] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)

            var error: CFError?
            let accepted = SecTrustEvaluateWithError(trust, &error)
            complete(accepted)
        }, verifyQueue)
    }

    private func startNetworkPathMonitorOnQueue() {
        guard pathMonitor == nil else { return }
        pathSnapshot = nil
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handleNetworkPathUpdate(path)
        }
        pathMonitor = monitor
        monitor.start(queue: queue)
    }

    private func stopNetworkPathMonitorOnQueue() {
        pathMonitor?.cancel()
        pathMonitor = nil
        pathSnapshot = nil
    }

    private func handleNetworkPathUpdate(_ path: NWPath) {
        guard pathMonitor != nil, !stopped else { return }

        let snapshot = NetworkPathSnapshot(path: path)
        guard let previousSnapshot = pathSnapshot else {
            pathSnapshot = snapshot
            AppLog.webSwitch.info(
                "network path initial network=\(self.identifier, privacy: .public) server=\(self.endpoint.description, privacy: .public) path=\(snapshot.description, privacy: .public)"
            )
            if !snapshot.isSatisfied {
                suspendForUnsatisfiedNetworkPath(snapshot: snapshot)
            }
            return
        }

        guard snapshot != previousSnapshot else { return }
        pathSnapshot = snapshot
        AppLog.webSwitch.info(
            "network path changed network=\(self.identifier, privacy: .public) server=\(self.endpoint.description, privacy: .public) previous=\(previousSnapshot.description, privacy: .public) current=\(snapshot.description, privacy: .public)"
        )

        guard snapshot.shouldReconnect(comparedTo: previousSnapshot) else {
            AppLog.webSwitch.info(
                "network path metadata changed without reconnect network=\(self.identifier, privacy: .public) server=\(self.endpoint.description, privacy: .public) current=\(snapshot.description, privacy: .public)"
            )
            return
        }

        if snapshot.isSatisfied {
            scheduleReconnectAfterNetworkPathChange(snapshot: snapshot)
        } else {
            suspendForUnsatisfiedNetworkPath(snapshot: snapshot)
        }
    }

    private func scheduleReconnectAfterNetworkPathChange(snapshot: NetworkPathSnapshot) {
        guard !stopped else { return }
        cancelNetworkPathReconnect()
        let delay = Self.networkPathReconnectDelay
        let milliseconds = Int(delay * 1000)
        let message = "Host network changed (\(snapshot.description)). Reconnecting to \(endpoint.description) in \(milliseconds)ms."
        AppLog.webSwitch.info(
            "network path reconnect scheduled network=\(self.identifier, privacy: .public) server=\(self.endpoint.description, privacy: .public) delayMs=\(milliseconds, privacy: .public) path=\(snapshot.description, privacy: .public)"
        )
        report(.connecting, message, connections: initialized ? 1 : 0, error: nil)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            networkPathReconnectWorkItem = nil
            reconnectImmediatelyAfterNetworkPathChange(snapshot: snapshot)
        }
        networkPathReconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func reconnectImmediatelyAfterNetworkPathChange(snapshot: NetworkPathSnapshot) {
        guard !stopped else { return }
        networkPathReconnectWorkItem = nil
        let message = "Host network changed (\(snapshot.description)). Reconnecting to \(endpoint.description)."
        reconnectDelay = Self.initialReconnectDelay
        cancelReconnect()
        cancelConnectionTimeout()
        cancelInitResponseTimeout()
        cancelClientKeepalive()
        pendingWrites.removeAll()
        initialized = false
        stopUDPDataPlaneOnQueue()
        if let activeConnection = connection {
            connection = nil
            activeConnection.cancel()
        }
        AppLog.webSwitch.info(
            "network path reconnect network=\(self.identifier, privacy: .public) server=\(self.endpoint.description, privacy: .public) path=\(snapshot.description, privacy: .public)"
        )
        report(.connecting, message, connections: 0, error: nil)
        startOnQueue()
    }

    private func suspendForUnsatisfiedNetworkPath(snapshot: NetworkPathSnapshot) {
        guard !stopped else { return }
        let message = "Host network unavailable (\(snapshot.description)). Waiting for network availability."
        reconnectDelay = Self.initialReconnectDelay
        cancelReconnect()
        cancelNetworkPathReconnect()
        cancelConnectionTimeout()
        cancelInitResponseTimeout()
        cancelClientKeepalive()
        pendingWrites.removeAll()
        initialized = false
        stopUDPDataPlaneOnQueue()
        if let activeConnection = connection {
            connection = nil
            activeConnection.cancel()
        }
        AppLog.webSwitch.warning(
            "network path unavailable network=\(self.identifier, privacy: .public) server=\(self.endpoint.description, privacy: .public) path=\(snapshot.description, privacy: .public)"
        )
        report(.connecting, message, connections: 0, error: nil)
    }

    private func handleState(_ state: NWConnection.State, for connection: NWConnection) {
        switch state {
        case .ready:
            cancelConnectionTimeout()
            AppLog.webSwitch.info(
                "tls ready network=\(self.identifier, privacy: .public) server=\(self.endpoint.description, privacy: .public)"
            )
            report(.connecting, "Connected to \(endpoint.description). Sending INIT.", connections: 0, error: nil)
            receiveLoop(connection)
            sendInit()
            scheduleInitResponseTimeout(for: connection)
        case .failed(let error):
            initialized = false
            AppLog.webSwitch.error(
                "connection failed network=\(self.identifier, privacy: .public) server=\(self.endpoint.description, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            closeConnection(
                connection,
                message: "Switch connection failed: \(error.localizedDescription)",
                error: error.localizedDescription,
                retry: true
            )
        case .cancelled:
            initialized = false
            if !stopped {
                AppLog.webSwitch.warning(
                    "connection cancelled network=\(self.identifier, privacy: .public) server=\(self.endpoint.description, privacy: .public)"
                )
                closeConnection(
                    connection,
                    message: "Switch connection closed.",
                    error: "Switch connection closed.",
                    retry: true
                )
            } else if connection === self.connection {
                self.connection = nil
            }
        case .waiting(let error):
            AppLog.webSwitch.info(
                "connection waiting network=\(self.identifier, privacy: .public) server=\(self.endpoint.description, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            closeConnection(
                connection,
                message: "Waiting to connect to \(endpoint.description): \(error.localizedDescription)",
                error: error.localizedDescription,
                retry: true
            )
        case .preparing, .setup:
            report(.connecting, "Connecting to \(endpoint.description).", connections: 0, error: nil)
        @unknown default:
            report(.connecting, "Connecting to \(endpoint.description).", connections: 0, error: nil)
        }
    }

    private func sendInit() {
        let udpCapable = shouldAttemptUDP
        let clientRandom = udpCapable ? Data.randomBytes(count: 32) : nil
        udpClientRandom = clientRandom
        var capabilities = ["ethernet-frame"]
        if udpCapable {
            capabilities.append("udp-data-v1")
        }
        let payload = SwitchInitPayload(
            protocol: "okrun-switch/1",
            nodeID: nodeID.uuidString,
            networkIdentifier: identifier,
            interface: interfaceName,
            maxFrameSize: maxFrameSize,
            dhcpRange: dhcpRange,
            capabilities: capabilities,
            transportPreference: udpCapable ? config.transportMode.transportPreference : "tcp",
            clientRandom: clientRandom?.base64URLEncodedString()
        )

        do {
            let encoded = try SwitchFrameProtocol.encodeJSON(type: .initFrame, value: payload)
            sendNow(encoded)
        } catch {
            if let connection {
                closeConnection(connection, message: error.localizedDescription, error: error.localizedDescription, retry: false)
            } else {
                report(.failed, error.localizedDescription, connections: 0, error: error.localizedDescription)
            }
        }
    }

    private func receiveLoop(_ activeConnection: NWConnection) {
        activeConnection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak activeConnection] content, _, isComplete, error in
            guard let self else { return }
            queue.async {
                guard let activeConnection, activeConnection === self.connection else { return }
                if let content, !content.isEmpty {
                    do {
                        for frame in try self.decoder.push(content) {
                            self.handleFrame(frame)
                        }
                    } catch {
                        AppLog.webSwitch.error(
                            "protocol error network=\(self.identifier, privacy: .public) server=\(self.endpoint.description, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                        )
                        self.closeConnection(
                            activeConnection,
                            message: "Switch protocol error: \(error.localizedDescription)",
                            error: error.localizedDescription,
                            retry: true
                        )
                        return
                    }
                }

                if let error {
                    self.initialized = false
                    AppLog.webSwitch.error(
                        "receive failed network=\(self.identifier, privacy: .public) server=\(self.endpoint.description, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                    self.closeConnection(
                        activeConnection,
                        message: "Switch receive failed: \(error.localizedDescription)",
                        error: error.localizedDescription,
                        retry: true
                    )
                    return
                }

                guard !isComplete else {
                    self.initialized = false
                    if !self.stopped {
                        AppLog.webSwitch.warning(
                            "connection closed by server network=\(self.identifier, privacy: .public) server=\(self.endpoint.description, privacy: .public)"
                        )
                        self.closeConnection(
                            activeConnection,
                            message: "Switch connection closed by server.",
                            error: "Switch connection closed by server.",
                            retry: true
                        )
                    } else {
                        self.connection = nil
                    }
                    return
                }

                self.receiveLoop(activeConnection)
            }
        }
    }

    private func handleFrame(_ frame: SwitchFrame) {
        switch frame.type {
        case .initFrame:
            do {
                let ack = try JSONDecoder().decode(SwitchInitAckPayload.self, from: frame.payload)
                guard ack.protocol == "okrun-switch/1" else {
                    throw AppError("Switch server returned unsupported protocol \(ack.protocol).")
                }
                maxFrameSize = ack.maxFrameSize
                initialized = true
                cancelInitResponseTimeout()
                let completedAttempts = reconnectAttempts
                reconnectDelay = Self.initialReconnectDelay
                reconnectAttempts = 0
                AppLog.webSwitch.info(
                    "init complete network=\(self.identifier, privacy: .public) server=\(self.endpoint.description, privacy: .public) reconnectAttempts=\(completedAttempts, privacy: .public) maxFrameSize=\(self.maxFrameSize, privacy: .public)"
                )
                onInitialized?()
                startClientKeepaliveIfNeeded(ack: ack)
                let connections = memberCount(network: ack.networkMemberCount, local: ack.localMemberCount)
                lastMemberCount = connections
                handleUDPDataPlaneAck(ack, connections: connections)
                flushPendingWrites()
                if udpDataPlane?.isReady == true {
                    report(
                        .connected,
                        "UDP Accelerated to \(endpoint.description).",
                        connections: connections,
                        error: nil
                    )
                } else if shouldAttemptUDP, ack.dataPlane?.selected == "udp" {
                    report(
                        .connected,
                        "Connected to \(endpoint.description). UDP probing.",
                        connections: connections,
                        error: nil
                    )
                } else {
                    report(
                        .connected,
                        shouldAttemptUDP && config.transportMode == .auto
                            ? "Connected to \(endpoint.description). TCP/TLS fallback."
                            : "Connected to \(endpoint.description).",
                        connections: connections,
                        error: nil
                    )
                }
            } catch {
                AppLog.webSwitch.error(
                    "invalid init ack network=\(self.identifier, privacy: .public) server=\(self.endpoint.description, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                if let connection {
                    closeConnection(
                        connection,
                        message: "Invalid switch INIT ACK: \(error.localizedDescription)",
                        error: error.localizedDescription,
                        retry: true
                    )
                } else {
                    report(.failed, "Invalid switch INIT ACK: \(error.localizedDescription)", connections: 0, error: error.localizedDescription)
                }
            }
        case .data:
            guard initialized else { return }
            SwitchDebug.log("received DATA bytes=\(frame.payload.count) seq=\(frame.sequenceNumber)")
            onFrame?(frame)
        case .error:
            let decoded = try? JSONDecoder().decode(SwitchErrorPayload.self, from: frame.payload)
            let message = decoded?.message ?? String(decoding: frame.payload, as: UTF8.self)
            let code = decoded?.code
            AppLog.webSwitch.error(
                "server rejected switch connection network=\(self.identifier, privacy: .public) server=\(self.endpoint.description, privacy: .public) code=\(code ?? "unknown", privacy: .public) message=\(message, privacy: .public)"
            )
            report(.rejected, message, connections: 0, error: code)
            if let connection {
                closeRejectedConnection(connection, message: message, error: code)
            }
        case .ping:
            sendPong()
        case .pong:
            lastPongAt = Date()
        case .resetSeq:
            if let reset = try? JSONDecoder().decode(SwitchResetSeqPayload.self, from: frame.payload) {
                onResetSeq?(reset.streams)
            }
        case .memberUpdate:
            guard initialized,
                  let update = try? JSONDecoder().decode(SwitchMemberUpdatePayload.self, from: frame.payload) else {
                return
            }
            let connections = memberCount(network: update.networkMemberCount, local: update.localMemberCount)
            lastMemberCount = connections
            report(
                .connected,
                udpDataPlane?.isReady == true
                    ? "UDP Accelerated to \(endpoint.description)."
                    : "Connected to \(endpoint.description).",
                connections: connections,
                error: nil
            )
        }
    }

    private func handleUDPDataPlaneAck(_ ack: SwitchInitAckPayload, connections: Int) {
        guard shouldAttemptUDP else { return }
        guard let dataPlane = ack.dataPlane, dataPlane.selected == "udp" else {
            if config.transportMode == .udp, let connection {
                closeConnection(
                    connection,
                    message: "Switch server did not provide a UDP data plane.",
                    error: "UDP data plane unavailable.",
                    retry: false
                )
            }
            return
        }
        guard let clientRandom = udpClientRandom else { return }
        do {
            let udp = try SwitchUDPDataPlane(
                identifier: identifier,
                endpointHost: endpoint.host,
                ack: dataPlane,
                clientRandom: clientRandom,
                mode: config.transportMode,
                maxFrameSize: maxFrameSize,
                queue: queue
            )
            udp.onFrame = { [weak self] frame in
                guard let self, self.initialized else { return }
                SwitchDebug.log("received UDP DATA bytes=\(frame.payload.count) seq=\(frame.sequenceNumber)")
                self.onFrame?(frame)
            }
            udp.onReady = { [weak self] in
                guard let self else { return }
                self.report(
                    .connected,
                    "UDP Accelerated to \(self.endpoint.description).",
                    connections: self.lastMemberCount,
                    error: nil
                )
            }
            udp.onFallback = { [weak self] message in
                guard let self else { return }
                self.report(
                    .connected,
                    message,
                    connections: self.lastMemberCount,
                    error: nil
                )
            }
            udp.onFailed = { [weak self] message in
                guard let self, let connection = self.connection else { return }
                self.closeConnection(
                    connection,
                    message: message,
                    error: message,
                    retry: false
                )
            }
            udpDataPlane = udp
            udp.start()
        } catch {
            if config.transportMode == .udp, let connection {
                closeConnection(
                    connection,
                    message: "Failed to start switch UDP data plane: \(error.localizedDescription)",
                    error: error.localizedDescription,
                    retry: false
                )
            } else {
                report(
                    .connected,
                    "Connected to \(endpoint.description). TCP/TLS fallback: \(error.localizedDescription)",
                    connections: connections,
                    error: nil
                )
            }
        }
    }

    private func sendPong() {
        do {
            let encoded = try SwitchFrameProtocol.encode(SwitchFrame(
                streamID: SwitchFrame.controlStreamID,
                type: .pong,
                sequenceNumber: 0,
                payload: Data()
            ))
            sendNow(encoded)
        } catch {
            report(.failed, error.localizedDescription, connections: initialized ? 1 : 0, error: error.localizedDescription)
        }
    }

    private func sendPing() {
        do {
            let encoded = try SwitchFrameProtocol.encode(SwitchFrame(
                streamID: SwitchFrame.controlStreamID,
                type: .ping,
                sequenceNumber: 0,
                payload: Data()
            ))
            sendNow(encoded)
        } catch {
            report(.failed, error.localizedDescription, connections: initialized ? 1 : 0, error: error.localizedDescription)
        }
    }

    private func sendEncodedOnQueue(_ data: Data) {
        guard initialized else {
            SwitchDebug.log("buffer encoded bytes=\(data.count) until INIT ACK")
            if !pendingWrites.append(data) {
                SwitchDebug.log("drop pending encoded bytes=\(data.count) reason=buffer-full")
            }
            return
        }
        SwitchDebug.log("write encoded bytes=\(data.count)")
        sendNow(data)
    }

    private func sendDataFrameOnQueue(_ frame: SwitchFrame) {
        guard initialized else {
            do {
                let encoded = try SwitchFrameProtocol.encode(frame)
                SwitchDebug.log("buffer DATA bytes=\(frame.payload.count) until INIT ACK")
                if !pendingWrites.append(encoded) {
                    SwitchDebug.log("drop pending DATA bytes=\(frame.payload.count) reason=buffer-full")
                }
            } catch {
                report(.failed, error.localizedDescription, connections: 0, error: error.localizedDescription)
            }
            return
        }

        if udpDataPlane?.sendData(frame) == true {
            SwitchDebug.log("write UDP DATA bytes=\(frame.payload.count) seq=\(frame.sequenceNumber)")
            return
        }

        guard config.transportMode != .udp else {
            SwitchDebug.log("drop DATA bytes=\(frame.payload.count) reason=udp-not-ready")
            return
        }

        do {
            SwitchDebug.log("write TCP DATA bytes=\(frame.payload.count) seq=\(frame.sequenceNumber)")
            sendNow(try SwitchFrameProtocol.encode(frame))
        } catch {
            report(.failed, error.localizedDescription, connections: initialized ? 1 : 0, error: error.localizedDescription)
        }
    }

    private func flushPendingWrites() {
        let result = pendingWrites.flush()
        let writes = result.writes
        if !writes.isEmpty {
            SwitchDebug.log("flush pending writes count=\(writes.count) droppedExpired=\(result.dropped)")
        } else if result.dropped > 0 {
            SwitchDebug.log("drop pending writes count=\(result.dropped) reason=expired")
        }
        for write in writes {
            sendNow(write)
        }
    }

    private func sendNow(_ data: Data) {
        guard let connection else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            queue.async {
                guard let connection = self.connection else { return }
                AppLog.webSwitch.error(
                    "send failed network=\(self.identifier, privacy: .public) server=\(self.endpoint.description, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                self.closeConnection(
                    connection,
                    message: "Switch send failed: \(error.localizedDescription)",
                    error: error.localizedDescription,
                    retry: true
                )
            }
        })
    }

    private func scheduleConnectionTimeout(for connection: NWConnection) {
        cancelConnectionTimeout()
        let timeout = connectionTimeout
        let workItem = DispatchWorkItem { [weak self, weak connection] in
            guard let self,
                  let connection,
                  !self.stopped,
                  connection === self.connection,
                  !self.initialized else { return }
            AppLog.webSwitch.warning(
                "connection timeout network=\(self.identifier, privacy: .public) server=\(self.endpoint.description, privacy: .public) timeoutSeconds=\(Int(timeout), privacy: .public)"
            )
            self.closeConnection(
                connection,
                message: "Switch connection timed out after \(Int(timeout))s.",
                error: "Switch connection timed out.",
                retry: true
            )
        }
        connectionTimeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    private func cancelConnectionTimeout() {
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
    }

    private func scheduleInitResponseTimeout(for connection: NWConnection) {
        cancelInitResponseTimeout()
        let workItem = DispatchWorkItem { [weak self, weak connection] in
            guard let self,
                  let connection,
                  !self.stopped,
                  connection === self.connection,
                  !self.initialized else { return }
            AppLog.webSwitch.warning(
                "init timeout network=\(self.identifier, privacy: .public) server=\(self.endpoint.description, privacy: .public) timeoutSeconds=\(Int(Self.initResponseTimeout), privacy: .public)"
            )
            self.closeConnection(
                connection,
                message: "Switch INIT response timed out after \(Int(Self.initResponseTimeout))s.",
                error: "Switch INIT response timed out.",
                retry: true
            )
        }
        initResponseWorkItem = workItem
        queue.asyncAfter(deadline: .now() + Self.initResponseTimeout, execute: workItem)
    }

    private func cancelInitResponseTimeout() {
        initResponseWorkItem?.cancel()
        initResponseWorkItem = nil
    }

    private func startClientKeepaliveIfNeeded(ack: SwitchInitAckPayload) {
        let keepaliveDefaults = defaultKeepaliveTiming
        clientKeepaliveInterval = Self.seconds(
            fromMilliseconds: ack.keepaliveIntervalMs,
            fallback: keepaliveDefaults.interval
        )
        clientKeepaliveTimeout = Self.seconds(
            fromMilliseconds: ack.keepaliveTimeoutMs,
            fallback: keepaliveDefaults.timeout
        )
        lastPongAt = Date()
        scheduleClientKeepalive()
    }

    private func scheduleClientKeepalive() {
        cancelClientKeepalive(resetLastPong: false)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, self.initialized else { return }

            let age = Date().timeIntervalSince(self.lastPongAt ?? .distantPast)
            guard age <= self.clientKeepaliveTimeout else {
                if let connection = self.connection {
                    AppLog.webSwitch.warning(
                        "switch keepalive timeout network=\(self.identifier, privacy: .public) server=\(self.endpoint.description, privacy: .public) timeoutMs=\(Int(self.clientKeepaliveTimeout * 1000), privacy: .public)"
                    )
                    self.closeConnection(
                        connection,
                        message: "Switch keepalive timed out.",
                        error: "Switch keepalive timed out.",
                        retry: true
                    )
                }
                return
            }

            self.sendPing()
            self.scheduleClientKeepalive()
        }
        clientKeepaliveWorkItem = workItem
        queue.asyncAfter(deadline: .now() + clientKeepaliveInterval, execute: workItem)
    }

    private func cancelClientKeepalive(resetLastPong: Bool = true) {
        clientKeepaliveWorkItem?.cancel()
        clientKeepaliveWorkItem = nil
        if resetLastPong {
            lastPongAt = nil
        }
    }

    private func stopUDPDataPlaneOnQueue() {
        udpDataPlane?.stop()
        udpDataPlane = nil
        udpClientRandom = nil
    }

    private static func seconds(fromMilliseconds milliseconds: Int?, fallback: TimeInterval) -> TimeInterval {
        guard let milliseconds, milliseconds > 0 else { return fallback }
        return TimeInterval(milliseconds) / 1000
    }

    private var shouldAttemptUDP: Bool {
        switch config.security {
        case .tls:
            return config.transportMode != .tcp
        case .none:
            return false
        }
    }

    private var connectionTimeout: TimeInterval {
        switch config.security {
        case .none:
            return Self.localConnectionTimeout
        case .tls:
            return Self.webConnectionTimeout
        }
    }

    private var defaultKeepaliveTiming: (interval: TimeInterval, timeout: TimeInterval) {
        switch config.security {
        case .none:
            return (Self.defaultLocalKeepaliveInterval, Self.defaultLocalKeepaliveTimeout)
        case .tls:
            return (Self.defaultWebKeepaliveInterval, Self.defaultWebKeepaliveTimeout)
        }
    }

    private func memberCount(network: Int?, local: Int?) -> Int {
        switch config.security {
        case .none:
            return max(1, local ?? network ?? 1)
        case .tls:
            return max(1, network ?? 1)
        }
    }

    private func closeConnection(
        _ activeConnection: NWConnection,
        message: String,
        error: String?,
        retry: Bool,
        reportFinalFailure: Bool = true
    ) {
        guard activeConnection === connection else { return }
        initialized = false
        cancelConnectionTimeout()
        cancelInitResponseTimeout()
        cancelClientKeepalive()
        stopUDPDataPlaneOnQueue()
        connection = nil
        activeConnection.cancel()

        guard retry, !stopped else {
            if reportFinalFailure {
                report(.failed, message, connections: 0, error: error)
            }
            return
        }
        scheduleReconnect(message: message, error: error)
    }

    private func closeRejectedConnection(
        _ activeConnection: NWConnection,
        message: String,
        error: String?
    ) {
        guard activeConnection === connection else { return }
        initialized = false
        cancelConnectionTimeout()
        cancelInitResponseTimeout()
        cancelClientKeepalive()
        stopUDPDataPlaneOnQueue()
        connection = nil
        activeConnection.cancel()

        guard !stopped else { return }

        switch SwitchServerErrorRetryPolicy.policy(for: error) {
        case .none:
            return
        case .delayed(let delay):
            scheduleReconnect(
                message: message,
                error: error,
                delayOverride: delay,
                reportState: .rejected
            )
        }
    }

    private func scheduleReconnect(
        message: String,
        error: String?,
        delayOverride: TimeInterval? = nil,
        reportState: PrivateNetworkSwitchConnectionState = .connecting
    ) {
        guard reconnectWorkItem == nil, !stopped else { return }
        cancelNetworkPathReconnect()
        reconnectAttempts += 1
        let delay = delayOverride ?? reconnectDelay
        let milliseconds = Int(delay * 1000)
        AppLog.webSwitch.warning(
            "schedule reconnect network=\(self.identifier, privacy: .public) server=\(self.endpoint.description, privacy: .public) attempt=\(self.reconnectAttempts, privacy: .public) delayMs=\(milliseconds, privacy: .public) reason=\(message, privacy: .public)"
        )
        let reconnectMessage: String
        switch reportState {
        case .rejected:
            reconnectMessage = "\(message) Retrying rejected connection in \(milliseconds)ms."
        default:
            reconnectMessage = "\(message) Reconnect attempt #\(reconnectAttempts) in \(milliseconds)ms."
        }
        report(
            reportState,
            reconnectMessage,
            connections: 0,
            error: error
        )

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            reconnectWorkItem = nil
            startOnQueue()
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
        if delayOverride == nil {
            reconnectDelay = min(reconnectDelay * 2, Self.maxReconnectDelay)
        }
    }

    private func cancelReconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
    }

    private func cancelNetworkPathReconnect() {
        networkPathReconnectWorkItem?.cancel()
        networkPathReconnectWorkItem = nil
    }

    private func report(
        _ state: PrivateNetworkSwitchConnectionState,
        _ message: String,
        connections: Int,
        error: String?
    ) {
        onStatusChange?(state, message, connections, error)
    }
}

private enum SwitchTLSIdentity {
    static func load(credentials: SwitchTLSCredentials) throws -> sec_identity_t {
        let password = UUID().uuidString
        let p12URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("okrun-switch-\(UUID().uuidString).p12")
        defer { try? FileManager.default.removeItem(at: p12URL) }

        try exportPKCS12(credentials: credentials, output: p12URL, password: password)
        let data = try Data(contentsOf: p12URL)
        let identity = try importPKCS12(data: data, password: password)
        guard let protocolIdentity = sec_identity_create(identity) else {
            throw AppError("Failed to create switch TLS identity.")
        }
        return protocolIdentity
    }

    static func loadCertificate(path: String) throws -> SecCertificate {
        let data = try derDataFromPEM(path: path, marker: "CERTIFICATE")
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw AppError("Failed to load switch CA certificate: \(path)")
        }
        return certificate
    }

    private static func exportPKCS12(
        credentials: SwitchTLSCredentials,
        output: URL,
        password: String
    ) throws {
        let openssl = URL(fileURLWithPath: "/usr/bin/openssl")
        guard FileManager.default.fileExists(atPath: openssl.path) else {
            throw AppError("OpenSSL is required to import PEM switch client certificates.")
        }

        let process = Process()
        process.executableURL = openssl
        process.arguments = [
            "pkcs12",
            "-export",
            "-inkey", credentials.clientKey,
            "-in", credentials.clientCert,
            "-out", output.path,
            "-passout", "pass:\(password)"
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let error = String(decoding: errorData, as: UTF8.self)
            throw AppError("Failed to prepare switch TLS identity: \(error)")
        }
    }

    private static func importPKCS12(data: Data, password: String) throws -> SecIdentity {
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        if #available(macOS 15.0, *) {
            options[kSecImportToMemoryOnly as String] = true
        } else {
            throw AppError("Web Switch certificate import without Keychain requires macOS 15 or later.")
        }

        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess,
              let items = rawItems as? [[String: Any]],
              let rawIdentity = items.first?[kSecImportItemIdentity as String] else {
            throw AppError("Failed to import switch client certificate identity (Security status \(status)).")
        }
        return rawIdentity as! SecIdentity
    }

    private static func derDataFromPEM(path: String, marker: String) throws -> Data {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let begin = "-----BEGIN \(marker)-----"
        let end = "-----END \(marker)-----"
        guard let beginRange = text.range(of: begin),
              let endRange = text.range(of: end, range: beginRange.upperBound..<text.endIndex) else {
            throw AppError("Missing \(marker) PEM block in \(path).")
        }
        let body = text[beginRange.upperBound..<endRange.lowerBound]
            .filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(body)) else {
            throw AppError("Invalid base64 in \(marker) PEM block: \(path)")
        }
        return data
    }
}

final class PrivateNetworkSwitchTransport {
    private struct WeakRuntime {
        weak var runtime: PrivateNetworkRuntime?
    }

    enum RouteAvailability {
        case allowConnecting
        case connectedOnly
    }

    private static let queueKey = DispatchSpecificKey<UUID>()
    private static let localMacTtl: TimeInterval = 5 * 60

    private let identifier: String
    private let config: PrivateNetworkSwitchConnectionConfig
    private let dhcpRange: PrivateNetworkDHCPLeaseRange?
    private let onRemoteFrame: ((Data) -> Void)?
    private let routeAvailability: RouteAvailability
    private let interfaceName: String
    private let queueID = UUID()
    private let queue: DispatchQueue
    private let client: PrivateNetworkSwitchClient
    private var runtimes: [WeakRuntime] = []
    private var localMACs: [EthernetAddress: Date] = [:]
    private var status: PrivateNetworkSwitchStatus

    convenience init(
        identifier: String,
        config: PrivateNetworkSwitchConfig,
        dhcpRange: PrivateNetworkDHCPLeaseRange? = nil,
        nodeID: UUID = UUID(),
        onRemoteFrame: ((Data) -> Void)? = nil
    ) throws {
        try self.init(
            identifier: identifier,
            connectionConfig: .webSwitch(config),
            dhcpRange: dhcpRange,
            routeAvailability: .allowConnecting,
            interfaceName: "web",
            nodeID: nodeID,
            onRemoteFrame: onRemoteFrame
        )
    }

    convenience init(
        identifier: String,
        localConfig: PrivateNetworkLocalSwitchConfig,
        dhcpRange: PrivateNetworkDHCPLeaseRange? = nil,
        nodeID: UUID = UUID(),
        onRemoteFrame: ((Data) -> Void)? = nil
    ) throws {
        try self.init(
            identifier: identifier,
            connectionConfig: .localSwitch(localConfig),
            dhcpRange: dhcpRange,
            routeAvailability: .connectedOnly,
            interfaceName: "local",
            nodeID: nodeID,
            onRemoteFrame: onRemoteFrame
        )
    }

    private init(
        identifier: String,
        connectionConfig: PrivateNetworkSwitchConnectionConfig,
        dhcpRange: PrivateNetworkDHCPLeaseRange?,
        routeAvailability: RouteAvailability,
        interfaceName: String,
        nodeID: UUID,
        onRemoteFrame: ((Data) -> Void)?
    ) throws {
        self.identifier = identifier
        self.config = connectionConfig
        self.dhcpRange = dhcpRange
        self.onRemoteFrame = onRemoteFrame
        self.routeAvailability = routeAvailability
        self.interfaceName = interfaceName
        queue = DispatchQueue(label: "okrun.private-network-switch.\(identifier).\(UUID().uuidString)")
        queue.setSpecific(key: Self.queueKey, value: queueID)
        client = try PrivateNetworkSwitchClient(
            identifier: identifier,
            config: self.config,
            dhcpRange: dhcpRange,
            interfaceName: interfaceName,
            nodeID: nodeID
        )
        status = PrivateNetworkSwitchStatus(
            identifier: identifier,
            server: self.config.server,
            state: .connecting,
            activeConnections: 0,
            message: "Connecting to \(self.config.server).",
            errorMessage: nil
        )

        client.onFrame = { [weak self] frame in
            self?.queue.async {
                self?.injectFrameToLocalGuests(frame)
            }
        }
        client.onStatusChange = { [weak self] state, message, activeConnections, error in
            self?.queue.async {
                guard let self else { return }
                self.status = PrivateNetworkSwitchStatus(
                    identifier: self.identifier,
                    server: self.config.server,
                    state: state,
                    activeConnections: activeConnections,
                    message: message,
                    errorMessage: error
                )
            }
        }
        client.start()
    }

    deinit {
        client.stop()
    }

    func addRuntime(_ runtime: PrivateNetworkRuntime) {
        runtime.addFrameObserver { [weak self] direction, frame in
            guard direction == .fromGuest else { return }
            self?.queue.async {
                self?.handleLocalFrame(frame)
            }
        }

        queue.async { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            self.runtimes.removeAll { $0.runtime == nil || $0.runtime === runtime }
            self.runtimes.append(WeakRuntime(runtime: runtime))
        }
    }

    func removeRuntime(_ runtime: PrivateNetworkRuntime) {
        queue.async { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            self.runtimes.removeAll { $0.runtime == nil || $0.runtime === runtime }
        }
    }

    func statusSnapshot() -> PrivateNetworkSwitchStatus {
        runOnQueue {
            status
        }
    }

    func matches(config switchConfig: PrivateNetworkSwitchConfig, dhcpRange: PrivateNetworkDHCPLeaseRange?) -> Bool {
        guard let connectionConfig = try? PrivateNetworkSwitchConnectionConfig.webSwitch(switchConfig) else {
            return false
        }
        return client.matches(config: connectionConfig, dhcpRange: dhcpRange)
    }

    func matches(localConfig: PrivateNetworkLocalSwitchConfig, dhcpRange: PrivateNetworkDHCPLeaseRange?) -> Bool {
        guard let connectionConfig = try? PrivateNetworkSwitchConnectionConfig.localSwitch(localConfig) else {
            return false
        }
        return client.matches(config: connectionConfig, dhcpRange: dhcpRange)
    }

    func canSendFrames() -> Bool {
        runOnQueue {
            switch routeAvailability {
            case .allowConnecting:
                return status.state == .connecting || status.state == .connected
            case .connectedOnly:
                // A local switch is only a useful route once another local member is present.
                return status.state == .connected && status.activeConnections > 1
            }
        }
    }

    func sendFrameToRemote(_ frame: Data) {
        client.send(frame)
    }

    private func handleLocalFrame(_ frame: Data) {
        let currentDate = Date()
        expireLocalMACsOnQueue(now: currentDate)
        if let header = EthernetFrameHeader.parse(frame) {
            localMACs[header.source] = currentDate
            guard shouldForwardLocalFrameToRemote(destination: header.destination) else {
                SwitchDebug.log("skip local destination=\(header.destination.description) bytes=\(frame.count)")
                return
            }
            SwitchDebug.log("send local destination=\(header.destination.description) source=\(header.source.description) bytes=\(frame.count)")
        } else {
            SwitchDebug.log("send local malformed-ethernet bytes=\(frame.count)")
        }
        sendFrameToRemote(frame)
    }

    private func injectFrameToLocalGuests(_ frame: Data) {
        if let header = EthernetFrameHeader.parse(frame) {
            SwitchDebug.log("inject remote destination=\(header.destination.description) source=\(header.source.description) bytes=\(frame.count)")
        } else {
            SwitchDebug.log("inject remote malformed-ethernet bytes=\(frame.count)")
        }
        if let onRemoteFrame {
            onRemoteFrame(frame)
        } else {
            runtimes.removeAll { $0.runtime == nil }
            for weakRuntime in runtimes {
                weakRuntime.runtime?.injectFrameToGuest(frame)
            }
        }
    }

    private func shouldForwardLocalFrameToRemote(destination: EthernetAddress) -> Bool {
        guard destination.isUnicast else { return true }
        return localMACs[destination] == nil
    }

    private func expireLocalMACsOnQueue(now currentDate: Date) {
        localMACs = localMACs.filter { currentDate.timeIntervalSince($0.value) <= Self.localMacTtl }
    }

    private func runOnQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) == queueID {
            return work()
        }
        return queue.sync(execute: work)
    }
}
