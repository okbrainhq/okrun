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
}

struct PrivateNetworkSwitchConfig: Codable, Equatable {
    var enabled: Bool
    var server: String
    var caCert: String
    var clientCert: String
    var clientKey: String
    var multipath: Bool

    enum CodingKeys: String, CodingKey {
        case enabled
        case server
        case caCert
        case clientCert
        case clientKey
        case multipath
    }

    init(
        enabled: Bool = false,
        server: String = "",
        caCert: String = "",
        clientCert: String = "",
        clientKey: String = "",
        multipath: Bool = false
    ) {
        self.enabled = enabled
        self.server = server
        self.caCert = caCert
        self.clientCert = clientCert
        self.clientKey = clientKey
        self.multipath = multipath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        server = try container.decodeIfPresent(String.self, forKey: .server) ?? ""
        caCert = try container.decodeIfPresent(String.self, forKey: .caCert) ?? ""
        clientCert = try container.decodeIfPresent(String.self, forKey: .clientCert) ?? ""
        clientKey = try container.decodeIfPresent(String.self, forKey: .clientKey) ?? ""
        multipath = try container.decodeIfPresent(Bool.self, forKey: .multipath) ?? false
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
        return self
    }

    func endpoint() throws -> PrivateNetworkSwitchEndpoint {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError("private network switch server must not be empty when enabled.")
        }
        guard trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "\0")) == nil else {
            throw AppError("private network switch server must not contain NUL.")
        }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              let port = UInt16(parts[1]),
              port > 0 else {
            throw AppError("private network switch server must be host:port with port between 1 and 65535.")
        }

        let host = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw AppError("private network switch server host must not be empty.")
        }

        return PrivateNetworkSwitchEndpoint(host: host, port: port)
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

private struct SwitchInitPayload: Codable {
    var `protocol`: String
    var nodeID: String
    var networkIdentifier: String
    var `interface`: String
    var maxFrameSize: Int
    var dhcpRange: PrivateNetworkDHCPLeaseRange?
    var capabilities: [String]
}

private struct SwitchInitAckPayload: Codable {
    var `protocol`: String
    var maxFrameSize: Int
    var maxConnectionsPerHost: Int?
    var keepaliveIntervalMs: Int?
    var keepaliveTimeoutMs: Int?
    var networkMemberCount: Int?
}

private struct SwitchErrorPayload: Codable {
    var code: String?
    var message: String?
}

private struct SwitchResetSeqPayload: Codable {
    var streams: [UInt32]
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
    private let config: PrivateNetworkSwitchConfig
    private let dhcpRange: PrivateNetworkDHCPLeaseRange?
    private let nodeID: UUID
    private let socket: VirtualSwitchSocket

    init(
        identifier: String,
        config: PrivateNetworkSwitchConfig,
        dhcpRange: PrivateNetworkDHCPLeaseRange?,
        nodeID: UUID = UUID()
    ) throws {
        self.identifier = identifier
        self.config = try config.validated()
        self.dhcpRange = dhcpRange
        self.nodeID = nodeID
        socket = try VirtualSwitchSocket(
            identifier: identifier,
            config: self.config,
            dhcpRange: dhcpRange,
            nodeID: nodeID
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

    func matches(config: PrivateNetworkSwitchConfig, dhcpRange: PrivateNetworkDHCPLeaseRange?) -> Bool {
        (try? config.validated()) == self.config && dhcpRange == self.dhcpRange
    }
}

private final class VirtualSwitchSocket {
    var onFrame: ((Data) -> Void)?
    var onStatusChange: ((PrivateNetworkSwitchConnectionState, String, Int, String?) -> Void)?

    private let realSocket: RealSwitchSocket
    private var outgoingSequenceNumber: UInt32 = 0
    private let incomingDedup = SwitchDedupWindow()
    private let queue = DispatchQueue(label: "okrun.switch.virtual.\(UUID().uuidString)")

    init(
        identifier: String,
        config: PrivateNetworkSwitchConfig,
        dhcpRange: PrivateNetworkDHCPLeaseRange?,
        nodeID: UUID
    ) throws {
        realSocket = try RealSwitchSocket(
            identifier: identifier,
            config: config,
            dhcpRange: dhcpRange,
            nodeID: nodeID,
            interfaceName: "default"
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
            do {
                SwitchDebug.log("queue DATA seq=\(outgoingSequenceNumber) bytes=\(frame.count)")
                self.realSocket.sendEncoded(try SwitchFrameProtocol.encode(switchFrame))
            } catch {
                self.onStatusChange?(.failed, error.localizedDescription, 0, error.localizedDescription)
            }
        }
    }
}

private final class RealSwitchSocket {
    var onFrame: ((SwitchFrame) -> Void)?
    var onResetSeq: (([UInt32]) -> Void)?
    var onStatusChange: ((PrivateNetworkSwitchConnectionState, String, Int, String?) -> Void)?

    private let identifier: String
    private let config: PrivateNetworkSwitchConfig
    private let endpoint: PrivateNetworkSwitchEndpoint
    private let dhcpRange: PrivateNetworkDHCPLeaseRange?
    private let nodeID: UUID
    private let interfaceName: String
    private let queue = DispatchQueue(label: "okrun.switch.real.\(UUID().uuidString)")
    private let decoder: SwitchFrameDecoder
    private var connection: NWConnection?
    private var pendingWrites: [Data] = []
    private var initialized = false
    private var stopped = false
    private var maxFrameSize: Int

    init(
        identifier: String,
        config: PrivateNetworkSwitchConfig,
        dhcpRange: PrivateNetworkDHCPLeaseRange?,
        nodeID: UUID,
        interfaceName: String
    ) throws {
        self.identifier = identifier
        self.config = try config.validated()
        endpoint = try self.config.endpoint()
        self.dhcpRange = dhcpRange
        self.nodeID = nodeID
        self.interfaceName = interfaceName
        maxFrameSize = SwitchFrame.defaultMaxFrameSize
        decoder = SwitchFrameDecoder(maxPayloadLength: maxFrameSize)
    }

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            stopped = true
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

    private func startOnQueue() {
        guard !stopped else { return }
        initialized = false
        pendingWrites.removeAll()
        report(.connecting, "Connecting to \(endpoint.description).", connections: 0, error: nil)

        do {
            let identity = try SwitchTLSIdentity.load(config: config)
            let caCertificate = try SwitchTLSIdentity.loadCertificate(path: config.caCert)
            let tlsOptions = NWProtocolTLS.Options()
            configureTLSOptions(tlsOptions, identity: identity, caCertificate: caCertificate)

            let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
            parameters.allowLocalEndpointReuse = true
            let connection = NWConnection(
                host: NWEndpoint.Host(endpoint.host),
                port: NWEndpoint.Port(rawValue: endpoint.port)!,
                using: parameters
            )
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                self?.queue.async {
                    self?.handleState(state)
                }
            }
            connection.start(queue: queue)
        } catch {
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

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            report(.connecting, "Connected to \(endpoint.description). Sending INIT.", connections: 0, error: nil)
            receiveLoop()
            sendInit()
        case .failed(let error):
            initialized = false
            report(.failed, "Switch connection failed: \(error.localizedDescription)", connections: 0, error: error.localizedDescription)
            connection?.cancel()
            connection = nil
        case .cancelled:
            initialized = false
            connection = nil
            if !stopped {
                report(.failed, "Switch connection closed.", connections: 0, error: "Switch connection closed.")
            }
        case .waiting(let error):
            report(.connecting, "Waiting to connect to \(endpoint.description): \(error.localizedDescription)", connections: 0, error: nil)
        case .preparing, .setup:
            report(.connecting, "Connecting to \(endpoint.description).", connections: 0, error: nil)
        @unknown default:
            report(.connecting, "Connecting to \(endpoint.description).", connections: 0, error: nil)
        }
    }

    private func sendInit() {
        let payload = SwitchInitPayload(
            protocol: "okrun-switch/1",
            nodeID: nodeID.uuidString,
            networkIdentifier: identifier,
            interface: interfaceName,
            maxFrameSize: maxFrameSize,
            dhcpRange: dhcpRange,
            capabilities: ["ethernet-frame", "multipath-v1"]
        )

        do {
            let encoded = try SwitchFrameProtocol.encodeJSON(type: .initFrame, value: payload)
            sendNow(encoded)
        } catch {
            report(.failed, error.localizedDescription, connections: 0, error: error.localizedDescription)
            connection?.cancel()
        }
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            queue.async {
                if let content, !content.isEmpty {
                    do {
                        for frame in try self.decoder.push(content) {
                            self.handleFrame(frame)
                        }
                    } catch {
                        self.report(.failed, "Switch protocol error: \(error.localizedDescription)", connections: 0, error: error.localizedDescription)
                        self.connection?.cancel()
                        return
                    }
                }

                if let error {
                    self.initialized = false
                    self.report(.failed, "Switch receive failed: \(error.localizedDescription)", connections: 0, error: error.localizedDescription)
                    self.connection?.cancel()
                    return
                }

                guard !isComplete else {
                    self.initialized = false
                    if !self.stopped {
                        self.report(.failed, "Switch connection closed by server.", connections: 0, error: "Switch connection closed by server.")
                    }
                    self.connection?.cancel()
                    return
                }

                self.receiveLoop()
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
                flushPendingWrites()
                report(.connected, "Connected to \(endpoint.description).", connections: 1, error: nil)
            } catch {
                report(.failed, "Invalid switch INIT ACK: \(error.localizedDescription)", connections: 0, error: error.localizedDescription)
                connection?.cancel()
            }
        case .data:
            guard initialized else { return }
            SwitchDebug.log("received DATA bytes=\(frame.payload.count) seq=\(frame.sequenceNumber)")
            onFrame?(frame)
        case .error:
            let decoded = try? JSONDecoder().decode(SwitchErrorPayload.self, from: frame.payload)
            let message = decoded?.message ?? String(decoding: frame.payload, as: UTF8.self)
            let code = decoded?.code
            report(.rejected, message, connections: 0, error: code)
            connection?.cancel()
        case .ping:
            sendPong()
        case .pong:
            break
        case .resetSeq:
            if let reset = try? JSONDecoder().decode(SwitchResetSeqPayload.self, from: frame.payload) {
                onResetSeq?(reset.streams)
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

    private func sendEncodedOnQueue(_ data: Data) {
        guard initialized else {
            SwitchDebug.log("buffer encoded bytes=\(data.count) until INIT ACK")
            if pendingWrites.count < 512 {
                pendingWrites.append(data)
            }
            return
        }
        SwitchDebug.log("write encoded bytes=\(data.count)")
        sendNow(data)
    }

    private func flushPendingWrites() {
        let writes = pendingWrites
        pendingWrites.removeAll()
        if !writes.isEmpty {
            SwitchDebug.log("flush pending writes count=\(writes.count)")
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
                self.report(.failed, "Switch send failed: \(error.localizedDescription)", connections: 0, error: error.localizedDescription)
                self.connection?.cancel()
            }
        })
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
    static func load(config: PrivateNetworkSwitchConfig) throws -> sec_identity_t {
        let password = UUID().uuidString
        let p12URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("okrun-switch-\(UUID().uuidString).p12")
        defer { try? FileManager.default.removeItem(at: p12URL) }

        try exportPKCS12(config: config, output: p12URL, password: password)
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
        config: PrivateNetworkSwitchConfig,
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
            "-inkey", config.clientKey,
            "-in", config.clientCert,
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
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options, &rawItems)
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

final class PrivateNetworkSwitchBridge {
    private struct WeakRuntime {
        weak var runtime: PrivateNetworkRuntime?
    }

    private let identifier: String
    private let config: PrivateNetworkSwitchConfig
    private let dhcpRange: PrivateNetworkDHCPLeaseRange?
    private let queue: DispatchQueue
    private let client: PrivateNetworkSwitchClient
    private var runtimes: [WeakRuntime] = []
    private var localMACs = Set<EthernetAddress>()
    private var status: PrivateNetworkSwitchStatus

    init(
        identifier: String,
        config: PrivateNetworkSwitchConfig,
        dhcpRange: PrivateNetworkDHCPLeaseRange? = nil
    ) throws {
        self.identifier = identifier
        self.config = try config.validated()
        self.dhcpRange = dhcpRange
        queue = DispatchQueue(label: "okrun.private-network-switch.\(identifier).\(UUID().uuidString)")
        client = try PrivateNetworkSwitchClient(
            identifier: identifier,
            config: self.config,
            dhcpRange: dhcpRange
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
        queue.sync {
            status
        }
    }

    func matches(config switchConfig: PrivateNetworkSwitchConfig, dhcpRange: PrivateNetworkDHCPLeaseRange?) -> Bool {
        client.matches(config: switchConfig, dhcpRange: dhcpRange)
    }

    private func handleLocalFrame(_ frame: Data) {
        if let header = EthernetFrameHeader.parse(frame) {
            localMACs.insert(header.source)
            guard shouldForwardLocalFrameToRemote(destination: header.destination) else {
                SwitchDebug.log("skip local destination=\(header.destination.description) bytes=\(frame.count)")
                return
            }
            SwitchDebug.log("send local destination=\(header.destination.description) source=\(header.source.description) bytes=\(frame.count)")
        } else {
            SwitchDebug.log("send local malformed-ethernet bytes=\(frame.count)")
        }
        client.send(frame)
    }

    private func injectFrameToLocalGuests(_ frame: Data) {
        if let header = EthernetFrameHeader.parse(frame) {
            SwitchDebug.log("inject remote destination=\(header.destination.description) source=\(header.source.description) bytes=\(frame.count)")
        } else {
            SwitchDebug.log("inject remote malformed-ethernet bytes=\(frame.count)")
        }
        runtimes.removeAll { $0.runtime == nil }
        for weakRuntime in runtimes {
            weakRuntime.runtime?.injectFrameToGuest(frame)
        }
    }

    private func shouldForwardLocalFrameToRemote(destination: EthernetAddress) -> Bool {
        guard destination.isUnicast else { return true }
        return !localMACs.contains(destination)
    }
}
