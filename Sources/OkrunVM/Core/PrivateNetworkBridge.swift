import Darwin
import Foundation

final class PrivateNetworkBridge {
    private struct WeakRuntime {
        weak var runtime: PrivateNetworkRuntime?
    }

    fileprivate let identifier: String
    private let config: PrivateNetworkBridgeConfig
    fileprivate let nodeID = UUID()
    private let queue: DispatchQueue
    private let listenerDescriptor: Int32
    private let listenerSource: DispatchSourceRead
    private var runtimes: [WeakRuntime] = []
    private var connections: [UUID: PrivateNetworkBridgeConnection] = [:]
    private var connectionsByRemoteNode: [UUID: UUID] = [:]
    private var pendingConnects: [UUID: (descriptor: Int32, source: DispatchSourceWrite)] = [:]
    private var localMACs = Set<EthernetAddress>()
    private var isStopped = false

    init(identifier: String, config: PrivateNetworkBridgeConfig) throws {
        self.identifier = identifier
        self.config = try config.validated()
        queue = DispatchQueue(label: "okrun.private-network-bridge.\(identifier).\(UUID().uuidString)")
        listenerDescriptor = try Self.makeIPv4Socket()
        try Self.bind(listenerDescriptor, to: self.config.bind)
        guard listen(listenerDescriptor, SOMAXCONN) == 0 else {
            close(listenerDescriptor)
            throw AppError("Failed to listen for private network bridge peers on \(self.config.bind.description): \(String(cString: strerror(errno))).")
        }
        try Self.setNonBlocking(listenerDescriptor)

        listenerSource = DispatchSource.makeReadSource(fileDescriptor: listenerDescriptor, queue: queue)
        listenerSource.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        listenerSource.resume()

        AppLog.virtualMachine.info(
            "Private network bridge listening privateNetwork=\(identifier, privacy: .public) endpoint=\(self.config.bind.description, privacy: .public)"
        )

        for peer in self.config.peers where peer != self.config.bind {
            scheduleOutboundConnection(to: peer, retryDelay: 0.1)
        }
    }

    deinit {
        stop()
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

    private func stop() {
        guard !isStopped else { return }
        isStopped = true

        listenerSource.cancel()
        close(listenerDescriptor)

        for (_, pending) in pendingConnects {
            pending.source.cancel()
            close(pending.descriptor)
        }
        pendingConnects.removeAll()

        for connection in Array(connections.values) {
            connection.close()
        }
        connections.removeAll()
        connectionsByRemoteNode.removeAll()
    }

    private func acceptConnections() {
        while true {
            var address = sockaddr_storage()
            var addressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let acceptedDescriptor = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenerDescriptor, $0, &addressLength)
                }
            }

            if acceptedDescriptor >= 0 {
                do {
                    try Self.configureConnectedSocket(acceptedDescriptor)
                    try Self.setNonBlocking(acceptedDescriptor)
                    addConnection(descriptor: acceptedDescriptor, isOutbound: false)
                } catch {
                    close(acceptedDescriptor)
                    AppLog.virtualMachine.error(
                        "Failed to configure accepted private network bridge connection privateNetwork=\(self.identifier, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                }
                continue
            }

            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }

            AppLog.virtualMachine.error(
                "Failed to accept private network bridge connection privateNetwork=\(self.identifier, privacy: .public) error=\(String(cString: strerror(errno)), privacy: .public)"
            )
            return
        }
    }

    private func scheduleOutboundConnection(to peer: PrivateNetworkBridgeEndpoint, retryDelay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            self?.startOutboundConnection(to: peer, retryDelay: min(max(retryDelay * 2, 1), 30))
        }
    }

    private func startOutboundConnection(to peer: PrivateNetworkBridgeEndpoint, retryDelay: TimeInterval) {
        guard !isStopped else { return }

        do {
            let descriptor = try Self.makeIPv4Socket()
            try Self.setNonBlocking(descriptor)

            let connectResult = try Self.connect(descriptor, to: peer)
            if connectResult == 0 {
                addConnection(descriptor: descriptor, isOutbound: true)
                AppLog.virtualMachine.info(
                    "Private network bridge connected privateNetwork=\(self.identifier, privacy: .public) peer=\(peer.description, privacy: .public)"
                )
                return
            }

            guard errno == EINPROGRESS else {
                let message = String(cString: strerror(errno))
                close(descriptor)
                AppLog.virtualMachine.error(
                    "Private network bridge peer connect failed privateNetwork=\(self.identifier, privacy: .public) peer=\(peer.description, privacy: .public) error=\(message, privacy: .public)"
                )
                scheduleOutboundConnection(to: peer, retryDelay: retryDelay)
                return
            }

            let token = UUID()
            let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
            pendingConnects[token] = (descriptor, source)
            source.setEventHandler { [weak self] in
                self?.completeOutboundConnection(token: token, peer: peer, retryDelay: retryDelay)
            }
            source.resume()
        } catch {
            AppLog.virtualMachine.error(
                "Private network bridge peer connect setup failed privateNetwork=\(self.identifier, privacy: .public) peer=\(peer.description, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            scheduleOutboundConnection(to: peer, retryDelay: retryDelay)
        }
    }

    private func completeOutboundConnection(
        token: UUID,
        peer: PrivateNetworkBridgeEndpoint,
        retryDelay: TimeInterval
    ) {
        guard let pending = pendingConnects.removeValue(forKey: token) else { return }
        pending.source.cancel()

        var socketError: Int32 = 0
        var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
        let result = getsockopt(
            pending.descriptor,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &socketErrorLength
        )

        guard result == 0, socketError == 0 else {
            let errorCode = result == 0 ? socketError : errno
            let message = String(cString: strerror(errorCode))
            close(pending.descriptor)
            AppLog.virtualMachine.error(
                "Private network bridge peer connect failed privateNetwork=\(self.identifier, privacy: .public) peer=\(peer.description, privacy: .public) error=\(message, privacy: .public)"
            )
            scheduleOutboundConnection(to: peer, retryDelay: retryDelay)
            return
        }

        addConnection(descriptor: pending.descriptor, isOutbound: true)
        AppLog.virtualMachine.info(
            "Private network bridge connected privateNetwork=\(self.identifier, privacy: .public) peer=\(peer.description, privacy: .public)"
        )
    }

    private func addConnection(descriptor: Int32, isOutbound: Bool) {
        let connection = PrivateNetworkBridgeConnection(
            descriptor: descriptor,
            isOutbound: isOutbound,
            bridge: self,
            queue: queue
        )
        connections[connection.id] = connection
    }

    fileprivate func receiveHello(from connection: PrivateNetworkBridgeConnection, remoteNodeID: UUID, networkIdentifier: String) {
        guard networkIdentifier == identifier else {
            AppLog.virtualMachine.error(
                "Closing private network bridge connection with mismatched network local=\(self.identifier, privacy: .public) remote=\(networkIdentifier, privacy: .public)"
            )
            connection.close()
            return
        }

        guard remoteNodeID != nodeID else {
            connection.close()
            return
        }

        if let existingID = connectionsByRemoteNode[remoteNodeID],
           let existing = connections[existingID],
           existing !== connection {
            let preferOutbound = nodeID.uuidString < remoteNodeID.uuidString
            if connection.isOutbound == preferOutbound {
                existing.close()
            } else {
                connection.close()
                return
            }
        }

        connection.activate(remoteNodeID: remoteNodeID)
        connectionsByRemoteNode[remoteNodeID] = connection.id
    }

    fileprivate func receiveFrame(_ frame: Data, from connection: PrivateNetworkBridgeConnection) {
        guard connection.isActive else { return }
        injectFrameToLocalGuests(frame)
    }

    fileprivate func connectionDidClose(_ connection: PrivateNetworkBridgeConnection) {
        connections.removeValue(forKey: connection.id)
        if let remoteNodeID = connection.remoteNodeID,
           connectionsByRemoteNode[remoteNodeID] == connection.id {
            connectionsByRemoteNode.removeValue(forKey: remoteNodeID)
        }
    }

    private func handleLocalFrame(_ frame: Data) {
        if let header = EthernetFrameHeader.parse(frame) {
            localMACs.insert(header.source)
            guard shouldForwardLocalFrameToRemote(destination: header.destination) else {
                return
            }
        }

        for connection in Array(connections.values) where connection.isActive {
            connection.sendFrame(frame)
        }
    }

    private func injectFrameToLocalGuests(_ frame: Data) {
        runtimes.removeAll { $0.runtime == nil }
        for weakRuntime in runtimes {
            weakRuntime.runtime?.injectFrameToGuest(frame)
        }
    }

    private func shouldForwardLocalFrameToRemote(destination: EthernetAddress) -> Bool {
        guard destination.isUnicast else { return true }
        return !localMACs.contains(destination)
    }

    private static func makeIPv4Socket() throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw AppError("Failed to create private network bridge socket: \(String(cString: strerror(errno))).")
        }
        do {
            try configureConnectedSocket(descriptor)
            var reuse: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func configureConnectedSocket(_ descriptor: Int32) throws {
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func setNonBlocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw AppError("Failed to configure private network bridge socket as nonblocking: \(String(cString: strerror(errno))).")
        }
    }

    private static func bind(_ descriptor: Int32, to endpoint: PrivateNetworkBridgeEndpoint) throws {
        var address = try ipv4Address(for: endpoint)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            throw AppError("Failed to bind private network bridge to \(endpoint.description): \(String(cString: strerror(errno))).")
        }
    }

    private static func connect(_ descriptor: Int32, to endpoint: PrivateNetworkBridgeEndpoint) throws -> Int32 {
        var address = try ipv4Address(for: endpoint)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private static func ipv4Address(for endpoint: PrivateNetworkBridgeEndpoint) throws -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(endpoint.port).bigEndian
        let result = endpoint.host.withCString {
            inet_pton(AF_INET, $0, &address.sin_addr)
        }
        guard result == 1 else {
            throw AppError("private network bridge endpoint must use an IPv4 address: \(endpoint.description)")
        }
        return address
    }
}

fileprivate final class PrivateNetworkBridgeConnection {
    enum State {
        case awaitingHello
        case active(remoteNodeID: UUID)
    }

    let id = UUID()
    let isOutbound: Bool
    private(set) var state: State = .awaitingHello

    var remoteNodeID: UUID? {
        if case .active(let remoteNodeID) = state {
            return remoteNodeID
        }
        return nil
    }

    var isActive: Bool {
        remoteNodeID != nil
    }

    private let descriptor: Int32
    private weak var bridge: PrivateNetworkBridge?
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var inputBuffer = Data()
    private var outputBuffer = Data()
    private var isClosed = false

    init(
        descriptor: Int32,
        isOutbound: Bool,
        bridge: PrivateNetworkBridge,
        queue: DispatchQueue
    ) {
        self.descriptor = descriptor
        self.isOutbound = isOutbound
        self.bridge = bridge
        self.queue = queue

        readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        readSource?.setEventHandler { [weak self] in
            self?.readAvailableData()
        }
        readSource?.resume()

        enqueue(PrivateNetworkBridgeMessage.encodeHello(
            nodeID: bridge.nodeID,
            networkIdentifier: bridge.identifier
        ))
    }

    func activate(remoteNodeID: UUID) {
        state = .active(remoteNodeID: remoteNodeID)
    }

    func sendFrame(_ frame: Data) {
        guard isActive else { return }
        enqueue(PrivateNetworkBridgeMessage.encodeFrame(frame))
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        readSource?.cancel()
        writeSource?.cancel()
        Darwin.close(descriptor)
        bridge?.connectionDidClose(self)
    }

    private func enqueue(_ data: Data) {
        guard !isClosed else { return }
        outputBuffer.append(data)
        ensureWriteSource()
        flushOutput()
    }

    private func ensureWriteSource() {
        guard writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.flushOutput()
        }
        writeSource = source
        source.resume()
    }

    private func flushOutput() {
        guard !isClosed else { return }

        while !outputBuffer.isEmpty {
            let sent = outputBuffer.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return send(descriptor, baseAddress, outputBuffer.count, 0)
            }

            if sent > 0 {
                outputBuffer.removeFirst(sent)
                continue
            }

            if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return
            }

            close()
            return
        }

        writeSource?.cancel()
        writeSource = nil
    }

    private func readAvailableData() {
        guard !isClosed else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)

        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count > 0 {
                inputBuffer.append(contentsOf: buffer.prefix(count))
                do {
                    for message in try PrivateNetworkBridgeMessage.decodeMessages(from: &inputBuffer) {
                        handle(message)
                    }
                } catch {
                    AppLog.virtualMachine.error(
                        "Closing private network bridge connection after protocol error: \(error.localizedDescription, privacy: .public)"
                    )
                    close()
                    return
                }
                continue
            }

            if count == 0 {
                close()
                return
            }

            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }

            close()
            return
        }
    }

    private func handle(_ message: PrivateNetworkBridgeMessage) {
        switch message {
        case .hello(let remoteNodeID, let networkIdentifier):
            bridge?.receiveHello(from: self, remoteNodeID: remoteNodeID, networkIdentifier: networkIdentifier)
        case .frame(let frame):
            bridge?.receiveFrame(frame, from: self)
        }
    }
}

enum PrivateNetworkBridgeMessage: Equatable {
    case hello(nodeID: UUID, networkIdentifier: String)
    case frame(Data)

    private static let helloType: UInt8 = 1
    private static let frameType: UInt8 = 2
    private static let maxPayloadLength = 70_000

    static func encodeHello(nodeID: UUID, networkIdentifier: String) -> Data {
        var payload = Data([helloType])
        payload.append(contentsOf: uuidBytes(nodeID))
        let identifierBytes = Array(networkIdentifier.utf8)
        appendUInt16(UInt16(identifierBytes.count), to: &payload)
        payload.append(contentsOf: identifierBytes)
        return encodePayload(payload)
    }

    static func encodeFrame(_ frame: Data) -> Data {
        var payload = Data([frameType])
        payload.append(frame)
        return encodePayload(payload)
    }

    static func decodeMessages(from buffer: inout Data) throws -> [PrivateNetworkBridgeMessage] {
        let bytes = [UInt8](buffer)
        var offset = 0
        var messages: [PrivateNetworkBridgeMessage] = []

        while bytes.count - offset >= 4 {
            let length = Int(readUInt32(bytes, offset))
            guard length > 0, length <= maxPayloadLength else {
                throw AppError("Invalid private network bridge message length \(length).")
            }
            guard bytes.count - offset - 4 >= length else {
                break
            }

            let payloadStart = offset + 4
            let payloadEnd = payloadStart + length
            messages.append(try decodePayload(Array(bytes[payloadStart..<payloadEnd])))
            offset = payloadEnd
        }

        if offset > 0 {
            buffer.removeFirst(offset)
        }

        return messages
    }

    private static func encodePayload(_ payload: Data) -> Data {
        var data = Data()
        appendUInt32(UInt32(payload.count), to: &data)
        data.append(payload)
        return data
    }

    private static func decodePayload(_ payload: [UInt8]) throws -> PrivateNetworkBridgeMessage {
        guard let messageType = payload.first else {
            throw AppError("Empty private network bridge message.")
        }

        switch messageType {
        case helloType:
            guard payload.count >= 19 else {
                throw AppError("Invalid private network bridge hello message.")
            }
            let nodeID = uuid(from: Array(payload[1..<17]))
            let identifierLength = Int(readUInt16(payload, 17))
            guard payload.count == 19 + identifierLength else {
                throw AppError("Invalid private network bridge hello identifier length.")
            }
            guard let networkIdentifier = String(
                data: Data(payload[19..<(19 + identifierLength)]),
                encoding: .utf8
            ) else {
                throw AppError("Invalid private network bridge hello identifier.")
            }
            return .hello(nodeID: nodeID, networkIdentifier: networkIdentifier)
        case frameType:
            return .frame(Data(payload.dropFirst()))
        default:
            throw AppError("Unknown private network bridge message type \(messageType).")
        }
    }

    private static func uuidBytes(_ uuid: UUID) -> [UInt8] {
        let value = uuid.uuid
        return [
            value.0, value.1, value.2, value.3,
            value.4, value.5, value.6, value.7,
            value.8, value.9, value.10, value.11,
            value.12, value.13, value.14, value.15
        ]
    }

    private static func uuid(from bytes: [UInt8]) -> UUID {
        UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }
}

struct EthernetFrameHeader: Equatable {
    let destination: EthernetAddress
    let source: EthernetAddress

    static func parse(_ frame: Data) -> EthernetFrameHeader? {
        guard frame.count >= 14 else { return nil }
        let bytes = [UInt8](frame.prefix(12))
        return EthernetFrameHeader(
            destination: EthernetAddress(Array(bytes[0..<6])),
            source: EthernetAddress(Array(bytes[6..<12]))
        )
    }
}

extension EthernetAddress {
    var isBroadcast: Bool {
        self == .broadcast
    }

    var isMulticast: Bool {
        (bytes.first ?? 0) & 1 == 1
    }

    var isUnicast: Bool {
        !isBroadcast && !isMulticast
    }
}
