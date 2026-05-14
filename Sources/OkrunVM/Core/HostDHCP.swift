import Darwin
import Foundation

struct HostNetworkConfig: Codable, Equatable {
    var version: Int
    var privateNetworks: [String: HostPrivateNetworkConfig]

    static let empty = HostNetworkConfig(version: 1, privateNetworks: [:])
}

struct HostPrivateNetworkConfig: Codable, Equatable {
    var dhcp: PrivateNetworkDHCPConfig?
    var bridge: PrivateNetworkBridgeConfig?
}

struct PrivateNetworkBridgeConfig: Codable, Equatable {
    var bind: PrivateNetworkBridgeEndpoint
    var peers: [PrivateNetworkBridgeEndpoint]

    func validated() throws -> PrivateNetworkBridgeConfig {
        _ = try bind.validated(context: "private network bridge bind")
        var seen = Set<PrivateNetworkBridgeEndpoint>()
        for peer in peers {
            let validatedPeer = try peer.validated(context: "private network bridge peer")
            guard seen.insert(validatedPeer).inserted else {
                throw AppError("private network bridge peers contains duplicate endpoint \(validatedPeer.description).")
            }
        }
        return self
    }
}

struct PrivateNetworkBridgeEndpoint: Codable, Equatable, Hashable {
    var host: String
    var port: Int

    var description: String {
        "\(host):\(port)"
    }

    func validated(context: String) throws -> PrivateNetworkBridgeEndpoint {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw AppError("\(context) host must not be empty.")
        }
        guard trimmedHost.rangeOfCharacter(from: CharacterSet(charactersIn: "\0")) == nil else {
            throw AppError("\(context) host must not contain NUL.")
        }
        var address = in_addr()
        guard trimmedHost.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
            throw AppError("\(context) host must be an IPv4 address.")
        }
        guard (1...65_535).contains(port) else {
            throw AppError("\(context) port must be between 1 and 65535.")
        }
        return PrivateNetworkBridgeEndpoint(host: trimmedHost, port: port)
    }
}

struct PrivateNetworkDHCPConfig: Codable, Equatable {
    enum Mode: String, Codable {
        case range
    }

    var enabled: Bool
    var mode: Mode
    var cidr: String
    var rangeStart: String
    var rangeEnd: String
    var leaseSeconds: UInt32

    func validated() throws -> PrivateNetworkDHCPConfig {
        guard enabled else { return self }
        guard mode == .range else {
            throw AppError("private network DHCP mode must be 'range'.")
        }
        let network = try IPv4CIDR(cidr)
        let start = try IPv4Address(rangeStart)
        let end = try IPv4Address(rangeEnd)
        guard network.contains(start), network.contains(end) else {
            throw AppError("private network DHCP lease range must be inside \(cidr).")
        }
        guard start.value <= end.value else {
            throw AppError("private network DHCP rangeStart must be less than or equal to rangeEnd.")
        }
        guard start.value != network.networkAddress.value,
              end.value != network.broadcastAddress.value else {
            throw AppError("private network DHCP lease range must not include the network or broadcast address.")
        }
        guard leaseSeconds >= 60 else {
            throw AppError("private network DHCP leaseSeconds must be at least 60.")
        }
        return self
    }
}

final class HostNetworkConfigStore {
    let home: OkrunHome
    private let url: URL

    init(home: OkrunHome = OkrunHome()) {
        self.home = home
        url = home.privateNetworksURL
    }

    init(url: URL) {
        home = OkrunHome(root: url.deletingLastPathComponent())
        self.url = url
    }

    func load() throws -> HostNetworkConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(HostNetworkConfig.self, from: data)
        for (_, privateNetwork) in config.privateNetworks {
            _ = try privateNetwork.dhcp?.validated()
            _ = try privateNetwork.bridge?.validated()
        }
        return config
    }

    func dhcpConfigForPrivateNetwork(identifier: String) throws -> PrivateNetworkDHCPConfig? {
        var config = try load()
        if let dhcp = config.privateNetworks[identifier]?.dhcp {
            let validated = try dhcp.validated()
            return validated.enabled ? validated : nil
        }

        let dhcp = Self.defaultDHCPConfig(identifier: identifier, existingConfig: config)
        var privateNetwork = config.privateNetworks[identifier] ?? HostPrivateNetworkConfig(dhcp: nil)
        privateNetwork.dhcp = dhcp
        config.privateNetworks[identifier] = privateNetwork
        try save(config)
        return dhcp
    }

    func bridgeConfigForPrivateNetwork(identifier: String) throws -> PrivateNetworkBridgeConfig? {
        guard let bridge = try load().privateNetworks[identifier]?.bridge else {
            return nil
        }
        return try bridge.validated()
    }

    func save(_ config: HostNetworkConfig) throws {
        for (_, privateNetwork) in config.privateNetworks {
            _ = try privateNetwork.dhcp?.validated()
            _ = try privateNetwork.bridge?.validated()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(config).write(to: url, options: .atomic)
    }

    private static func defaultDHCPConfig(identifier: String, existingConfig: HostNetworkConfig) -> PrivateNetworkDHCPConfig {
        let usedCIDRs = Set(existingConfig.privateNetworks.values.compactMap { $0.dhcp?.cidr })
        let cidr = defaultCIDR(identifier: identifier, usedCIDRs: usedCIDRs)
        let prefix = cidr.split(separator: "/").first.map(String.init) ?? "10.77.0.0"
        let octets = prefix.split(separator: ".")
        let base = octets.count == 4
            ? "\(octets[0]).\(octets[1]).\(octets[2])"
            : "10.77.0"
        return PrivateNetworkDHCPConfig(
            enabled: true,
            mode: .range,
            cidr: cidr,
            rangeStart: "\(base).20",
            rangeEnd: "\(base).200",
            leaseSeconds: 3600
        )
    }

    private static func defaultCIDR(identifier: String, usedCIDRs: Set<String>) -> String {
        if identifier == PrivateNetworkConfig.defaultIdentifier && !usedCIDRs.contains("10.77.0.0/24") {
            return "10.77.0.0/24"
        }

        let hash = FNV1a64.hash(Array(identifier.utf8))
        let start = Int(hash % 16_384)
        for offset in 0..<16_384 {
            let value = (start + offset) % 16_384
            let secondOctet = 64 + (value / 256)
            let thirdOctet = value % 256
            let cidr = "10.\(secondOctet).\(thirdOctet).0/24"
            if !usedCIDRs.contains(cidr) {
                return cidr
            }
        }

        return "10.77.0.0/24"
    }
}

struct IPv4Address: Codable, Equatable, Hashable, Comparable {
    let value: UInt32

    init(_ string: String) throws {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            throw AppError("Invalid IPv4 address: \(string)")
        }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else {
                throw AppError("Invalid IPv4 address: \(string)")
            }
            value = (value << 8) | UInt32(octet)
        }
        self.value = value
    }

    init(value: UInt32) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = try IPv4Address(container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    var description: String {
        [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ].map(String.init).joined(separator: ".")
    }

    static func < (lhs: IPv4Address, rhs: IPv4Address) -> Bool {
        lhs.value < rhs.value
    }
}

struct IPv4CIDR: Equatable {
    let networkAddress: IPv4Address
    let prefixLength: Int

    init(_ string: String) throws {
        let parts = string.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), (1...30).contains(prefix) else {
            throw AppError("Invalid IPv4 CIDR: \(string)")
        }
        let address = try IPv4Address(String(parts[0]))
        let mask = UInt32.max << UInt32(32 - prefix)
        networkAddress = IPv4Address(value: address.value & mask)
        prefixLength = prefix
    }

    var subnetMask: IPv4Address {
        IPv4Address(value: UInt32.max << UInt32(32 - prefixLength))
    }

    var broadcastAddress: IPv4Address {
        IPv4Address(value: networkAddress.value | ~subnetMask.value)
    }

    var serverAddress: IPv4Address {
        IPv4Address(value: networkAddress.value + 1)
    }

    func contains(_ address: IPv4Address) -> Bool {
        (address.value & subnetMask.value) == networkAddress.value
    }
}

final class DHCPLeaseStore {
    private struct LeaseFile: Codable {
        var version: Int
        var leases: [DHCPLease]
    }

    private let url: URL
    private let lockURL: URL

    init(stateDirectory: URL) {
        url = stateDirectory.appendingPathComponent("leases.json")
        lockURL = stateDirectory.appendingPathComponent("leases.lock")
    }

    func load() throws -> [DHCPLease] {
        try withFileLock {
            try loadUnlocked()
        }
    }

    func save(_ leases: [DHCPLease]) throws {
        try withFileLock {
            try saveUnlocked(leases)
        }
    }

    func update<T>(_ body: (inout [DHCPLease]) throws -> T) throws -> T {
        try withFileLock {
            var leases = try loadUnlocked()
            let result = try body(&leases)
            try saveUnlocked(leases)
            return result
        }
    }

    private func loadUnlocked() throws -> [DHCPLease] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(LeaseFile.self, from: data).leases
    }

    private func saveUnlocked(_ leases: [DHCPLease]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(LeaseFile(version: 1, leases: leases)).write(to: url, options: .atomic)
    }

    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw AppError("Failed to open DHCP lease lock: \(String(cString: strerror(errno))).")
        }
        defer { close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw AppError("Failed to lock DHCP leases: \(String(cString: strerror(errno))).")
        }
        defer { flock(descriptor, LOCK_UN) }

        return try body()
    }
}

struct DHCPLease: Codable, Equatable {
    var identity: String
    var ipAddress: IPv4Address
    var expiresAt: Date
}

final class DHCPLeaseAllocator {
    private let rangeStart: IPv4Address
    private let rangeEnd: IPv4Address
    private let leaseSeconds: UInt32
    private let store: DHCPLeaseStore

    init(config: PrivateNetworkDHCPConfig, store: DHCPLeaseStore) throws {
        let validated = try config.validated()
        rangeStart = try IPv4Address(validated.rangeStart)
        rangeEnd = try IPv4Address(validated.rangeEnd)
        leaseSeconds = validated.leaseSeconds
        self.store = store
    }

    func lease(for identity: String, requestedIP: IPv4Address?, now: Date = Date()) throws -> DHCPLease {
        try store.update { leases in
            pruneExpired(&leases, now: now)
            if let existing = leases.first(where: { $0.identity == identity }) {
                let renewed = DHCPLease(
                    identity: identity,
                    ipAddress: existing.ipAddress,
                    expiresAt: now.addingTimeInterval(TimeInterval(leaseSeconds))
                )
                replace(renewed, in: &leases)
                return renewed
            }

            let selectedIP: IPv4Address
            if let requestedIP, isInRange(requestedIP), !isLeased(requestedIP, in: leases) {
                selectedIP = requestedIP
            } else if let available = firstAvailableAddress(in: leases) {
                selectedIP = available
            } else {
                throw AppError("private network DHCP range is exhausted.")
            }

            let lease = DHCPLease(
                identity: identity,
                ipAddress: selectedIP,
                expiresAt: now.addingTimeInterval(TimeInterval(leaseSeconds))
            )
            leases.append(lease)
            return lease
        }
    }

    func requestedLease(for identity: String, requestedIP: IPv4Address?, now: Date = Date()) throws -> DHCPLease {
        try store.update { leases in
            pruneExpired(&leases, now: now)
            if let requestedIP {
                guard isInRange(requestedIP) else {
                    throw AppError("Requested DHCP address \(requestedIP.description) is outside the configured range.")
                }
                if let existing = leases.first(where: { $0.identity == identity }) {
                    guard existing.ipAddress == requestedIP else {
                        throw AppError("Requested DHCP address does not match the existing lease.")
                    }
                    let renewed = DHCPLease(
                        identity: identity,
                        ipAddress: existing.ipAddress,
                        expiresAt: now.addingTimeInterval(TimeInterval(leaseSeconds))
                    )
                    replace(renewed, in: &leases)
                    return renewed
                }
                guard !isLeased(requestedIP, in: leases) else {
                    throw AppError("Requested DHCP address \(requestedIP.description) is already leased.")
                }
                let lease = DHCPLease(
                    identity: identity,
                    ipAddress: requestedIP,
                    expiresAt: now.addingTimeInterval(TimeInterval(leaseSeconds))
                )
                leases.append(lease)
                return lease
            }

            if let existing = leases.first(where: { $0.identity == identity }) {
                let renewed = DHCPLease(
                    identity: identity,
                    ipAddress: existing.ipAddress,
                    expiresAt: now.addingTimeInterval(TimeInterval(leaseSeconds))
                )
                replace(renewed, in: &leases)
                return renewed
            }

            guard let available = firstAvailableAddress(in: leases) else {
                throw AppError("private network DHCP range is exhausted.")
            }
            let lease = DHCPLease(
                identity: identity,
                ipAddress: available,
                expiresAt: now.addingTimeInterval(TimeInterval(leaseSeconds))
            )
            leases.append(lease)
            return lease
        }
    }

    func release(identity: String) throws {
        try store.update { leases in
            leases.removeAll { $0.identity == identity }
        }
    }

    func decline(identity: String, address: IPv4Address, now: Date = Date()) throws {
        guard isInRange(address) else { return }
        try store.update { leases in
            pruneExpired(&leases, now: now)
            leases.removeAll { $0.identity == identity || $0.ipAddress == address }
            leases.append(DHCPLease(
                identity: "declined:\(address.description)",
                ipAddress: address,
                expiresAt: now.addingTimeInterval(TimeInterval(min(leaseSeconds, 600)))
            ))
        }
    }

    private func pruneExpired(_ leases: inout [DHCPLease], now: Date) {
        leases.removeAll { $0.expiresAt <= now }
    }

    private func replace(_ lease: DHCPLease, in leases: inout [DHCPLease]) {
        leases.removeAll { $0.identity == lease.identity }
        leases.append(lease)
    }

    private func isInRange(_ address: IPv4Address) -> Bool {
        address.value >= rangeStart.value && address.value <= rangeEnd.value
    }

    private func isLeased(_ address: IPv4Address, in leases: [DHCPLease]) -> Bool {
        leases.contains { $0.ipAddress == address }
    }

    private func firstAvailableAddress(in leases: [DHCPLease]) -> IPv4Address? {
        var value = rangeStart.value
        while value <= rangeEnd.value {
            let address = IPv4Address(value: value)
            if !isLeased(address, in: leases) {
                return address
            }
            if value == UInt32.max { break }
            value += 1
        }
        return nil
    }
}

final class HostDHCPServer {
    private let identifier: String
    private let network: IPv4CIDR
    private let leaseSeconds: UInt32
    private let runtime: PrivateNetworkRuntime
    private let allocator: DHCPLeaseAllocator
    private let queue: DispatchQueue
    private let serverMAC = EthernetAddress([0x02, 0x6f, 0x6b, 0x72, 0x75, 0x6e])

    init(
        privateNetworkIdentifier: String,
        config: PrivateNetworkDHCPConfig,
        runtime: PrivateNetworkRuntime,
        leaseStore: DHCPLeaseStore
    ) throws {
        let validated = try config.validated()
        identifier = privateNetworkIdentifier
        network = try IPv4CIDR(validated.cidr)
        leaseSeconds = validated.leaseSeconds
        self.runtime = runtime
        allocator = try DHCPLeaseAllocator(config: validated, store: leaseStore)
        queue = DispatchQueue(label: "okrun.dhcp.\(privateNetworkIdentifier)")

        runtime.addFrameObserver { [weak self] direction, frame in
            guard direction == .fromGuest else { return }
            self?.queue.async {
                self?.handle(frame: frame)
            }
        }
    }

    private func handle(frame: Data) {
        guard let request = DHCPMessage.parse(fromEthernetFrame: frame) else { return }
        do {
            switch request.messageType {
            case .discover:
                let lease = try allocator.lease(
                    for: request.identity,
                    requestedIP: request.requestedIPAddress
                )
                sendReply(to: request, messageType: .offer, leasedAddress: lease.ipAddress)
            case .request:
                if let requestedServer = request.serverIdentifier,
                   requestedServer != network.serverAddress {
                    return
                }
                let requestedAddress = request.requestedIPAddress ?? request.nonZeroClientIPAddress
                let lease = try allocator.requestedLease(
                    for: request.identity,
                    requestedIP: requestedAddress
                )
                sendReply(to: request, messageType: .ack, leasedAddress: lease.ipAddress)
            case .release:
                try allocator.release(identity: request.identity)
            case .decline:
                if let declinedAddress = request.requestedIPAddress ?? request.nonZeroClientIPAddress {
                    try allocator.decline(identity: request.identity, address: declinedAddress)
                    AppLog.virtualMachine.info(
                        "Declined DHCP lease privateNetwork=\(self.identifier, privacy: .public) ip=\(declinedAddress.description, privacy: .public)"
                    )
                }
            case .inform:
                sendReply(to: request, messageType: .ack, leasedAddress: IPv4Address(value: 0))
            case .offer, .ack, .nak:
                break
            }
        } catch {
            AppLog.virtualMachine.error(
                "DHCP lease conflict privateNetwork=\(self.identifier, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            sendReply(to: request, messageType: .nak, leasedAddress: IPv4Address(value: 0))
        }
    }

    private func sendReply(to request: DHCPMessage, messageType: DHCPMessageType, leasedAddress: IPv4Address) {
        let reply = DHCPMessage(
            messageType: messageType,
            transactionID: request.transactionID,
            flags: request.flags,
            clientHardwareAddress: request.clientHardwareAddress,
            clientIPAddress: IPv4Address(value: 0),
            yourIPAddress: leasedAddress,
            requestedIPAddress: nil,
            serverIdentifier: network.serverAddress,
            clientIdentifier: request.clientIdentifier,
            options: replyOptions(messageType: messageType)
        )
        runtime.injectFrameToGuest(reply.ethernetFrame(
            sourceMAC: serverMAC,
            destinationMAC: .broadcast,
            sourceIP: network.serverAddress,
            destinationIP: IPv4Address(value: 0xffff_ffff)
        ))
        if messageType == .offer || messageType == .ack {
            AppLog.virtualMachine.info(
                "Assigned DHCP lease privateNetwork=\(self.identifier, privacy: .public) ip=\(leasedAddress.description, privacy: .public)"
            )
        }
    }

    private func replyOptions(messageType: DHCPMessageType) -> [DHCPOption] {
        [
            .messageType(messageType),
            .serverIdentifier(network.serverAddress),
            .subnetMask(network.subnetMask),
            .broadcastAddress(network.broadcastAddress),
            .leaseTime(leaseSeconds),
            .renewalTime(leaseSeconds / 2),
            .rebindingTime((leaseSeconds * 7) / 8)
        ]
    }
}

struct EthernetAddress: Equatable, Hashable, Codable {
    static let broadcast = EthernetAddress([0xff, 0xff, 0xff, 0xff, 0xff, 0xff])

    let bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = Array(bytes.prefix(6))
    }

    var description: String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

enum DHCPMessageType: UInt8, Codable {
    case discover = 1
    case offer = 2
    case request = 3
    case decline = 4
    case ack = 5
    case nak = 6
    case release = 7
    case inform = 8
}

enum DHCPOption {
    case messageType(DHCPMessageType)
    case requestedIPAddress(IPv4Address)
    case subnetMask(IPv4Address)
    case leaseTime(UInt32)
    case renewalTime(UInt32)
    case rebindingTime(UInt32)
    case serverIdentifier(IPv4Address)
    case broadcastAddress(IPv4Address)
    case clientIdentifier(Data)
}

struct DHCPMessage {
    let messageType: DHCPMessageType
    let transactionID: UInt32
    let flags: UInt16
    let clientHardwareAddress: EthernetAddress
    let clientIPAddress: IPv4Address
    let yourIPAddress: IPv4Address
    let requestedIPAddress: IPv4Address?
    let serverIdentifier: IPv4Address?
    let clientIdentifier: Data?
    let options: [DHCPOption]

    var nonZeroClientIPAddress: IPv4Address? {
        clientIPAddress.value == 0 ? nil : clientIPAddress
    }

    var identity: String {
        if let clientIdentifier, !clientIdentifier.isEmpty {
            return clientIdentifier.map { String(format: "%02x", $0) }.joined()
        }
        return clientHardwareAddress.description
    }

    static func parse(fromEthernetFrame frame: Data) -> DHCPMessage? {
        let bytes = [UInt8](frame)
        guard bytes.count >= 14,
              bytes[12] == 0x08,
              bytes[13] == 0x00 else {
            return nil
        }
        let ipOffset = 14
        guard bytes.count >= ipOffset + 20 else { return nil }
        let ihl = Int(bytes[ipOffset] & 0x0f) * 4
        guard ihl >= 20,
              bytes[ipOffset + 9] == 17,
              bytes.count >= ipOffset + ihl + 8 else {
            return nil
        }
        let udpOffset = ipOffset + ihl
        let destinationPort = readUInt16(bytes, udpOffset + 2)
        guard destinationPort == 67 else { return nil }
        let bootpOffset = udpOffset + 8
        guard bytes.count >= bootpOffset + 240,
              bytes[bootpOffset] == 1,
              bytes[bootpOffset + 1] == 1,
              bytes[bootpOffset + 2] == 6,
              bytes[bootpOffset + 236] == 0x63,
              bytes[bootpOffset + 237] == 0x82,
              bytes[bootpOffset + 238] == 0x53,
              bytes[bootpOffset + 239] == 0x63 else {
            return nil
        }

        var messageType: DHCPMessageType?
        var requestedIP: IPv4Address?
        var serverID: IPv4Address?
        var clientID: Data?
        var optionOffset = bootpOffset + 240
        while optionOffset < bytes.count {
            let code = bytes[optionOffset]
            optionOffset += 1
            if code == 255 { break }
            if code == 0 { continue }
            guard optionOffset < bytes.count else { break }
            let length = Int(bytes[optionOffset])
            optionOffset += 1
            guard optionOffset + length <= bytes.count else { break }
            let value = Array(bytes[optionOffset..<optionOffset + length])
            switch code {
            case 53 where length == 1:
                messageType = DHCPMessageType(rawValue: value[0])
            case 50 where length == 4:
                requestedIP = IPv4Address(value: readUInt32(value, 0))
            case 54 where length == 4:
                serverID = IPv4Address(value: readUInt32(value, 0))
            case 61:
                clientID = Data(value)
            default:
                break
            }
            optionOffset += length
        }

        guard let messageType else { return nil }
        return DHCPMessage(
            messageType: messageType,
            transactionID: readUInt32(bytes, bootpOffset + 4),
            flags: readUInt16(bytes, bootpOffset + 10),
            clientHardwareAddress: EthernetAddress(Array(bytes[(bootpOffset + 28)..<(bootpOffset + 34)])),
            clientIPAddress: IPv4Address(value: readUInt32(bytes, bootpOffset + 12)),
            yourIPAddress: IPv4Address(value: readUInt32(bytes, bootpOffset + 16)),
            requestedIPAddress: requestedIP,
            serverIdentifier: serverID,
            clientIdentifier: clientID,
            options: []
        )
    }

    func ethernetFrame(
        sourceMAC: EthernetAddress,
        destinationMAC: EthernetAddress,
        sourceIP: IPv4Address,
        destinationIP: IPv4Address,
        sourcePort: UInt16 = 67,
        destinationPort: UInt16 = 68,
        bootpOperation: UInt8 = 2
    ) -> Data {
        let udpPayload = bootpPayload(operation: bootpOperation)
        let udpLength = UInt16(8 + udpPayload.count)
        let ipLength = UInt16(20 + Int(udpLength))

        var frame = Data()
        frame.append(contentsOf: destinationMAC.bytes)
        frame.append(contentsOf: sourceMAC.bytes)
        appendUInt16(0x0800, to: &frame)

        var ipHeader = Data()
        ipHeader.append(0x45)
        ipHeader.append(0)
        appendUInt16(ipLength, to: &ipHeader)
        appendUInt16(0, to: &ipHeader)
        appendUInt16(0, to: &ipHeader)
        ipHeader.append(64)
        ipHeader.append(17)
        appendUInt16(0, to: &ipHeader)
        appendUInt32(sourceIP.value, to: &ipHeader)
        appendUInt32(destinationIP.value, to: &ipHeader)
        let ipChecksum = internetChecksum([UInt8](ipHeader))
        ipHeader.replaceSubrange(10..<12, with: [UInt8(ipChecksum >> 8), UInt8(ipChecksum & 0xff)])

        var udp = Data()
        appendUInt16(sourcePort, to: &udp)
        appendUInt16(destinationPort, to: &udp)
        appendUInt16(udpLength, to: &udp)
        appendUInt16(0, to: &udp)
        udp.append(udpPayload)
        let udpChecksum = udpIPv4Checksum(
            sourceIP: sourceIP,
            destinationIP: destinationIP,
            udpPacket: [UInt8](udp)
        )
        udp.replaceSubrange(6..<8, with: [UInt8(udpChecksum >> 8), UInt8(udpChecksum & 0xff)])

        frame.append(ipHeader)
        frame.append(udp)
        return frame
    }

    private func bootpPayload(operation: UInt8) -> Data {
        var data = Data()
        data.append(operation)
        data.append(1)
        data.append(6)
        data.append(0)
        appendUInt32(transactionID, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(flags, to: &data)
        appendUInt32(clientIPAddress.value, to: &data)
        appendUInt32(yourIPAddress.value, to: &data)
        appendUInt32(serverIdentifier?.value ?? 0, to: &data)
        appendUInt32(0, to: &data)
        data.append(contentsOf: clientHardwareAddress.bytes)
        data.append(contentsOf: Array(repeating: 0, count: 10))
        data.append(contentsOf: Array(repeating: 0, count: 64))
        data.append(contentsOf: Array(repeating: 0, count: 128))
        data.append(contentsOf: [0x63, 0x82, 0x53, 0x63])
        for option in options {
            append(option: option, to: &data)
        }
        data.append(255)
        return data
    }

    private func append(option: DHCPOption, to data: inout Data) {
        switch option {
        case .messageType(let messageType):
            data.append(53)
            data.append(1)
            data.append(messageType.rawValue)
        case .requestedIPAddress(let address):
            appendIPOption(50, address, to: &data)
        case .subnetMask(let address):
            appendIPOption(1, address, to: &data)
        case .leaseTime(let seconds):
            appendUInt32Option(51, seconds, to: &data)
        case .renewalTime(let seconds):
            appendUInt32Option(58, seconds, to: &data)
        case .rebindingTime(let seconds):
            appendUInt32Option(59, seconds, to: &data)
        case .serverIdentifier(let address):
            appendIPOption(54, address, to: &data)
        case .broadcastAddress(let address):
            appendIPOption(28, address, to: &data)
        case .clientIdentifier(let identifier):
            data.append(61)
            data.append(UInt8(min(identifier.count, Int(UInt8.max))))
            data.append(identifier.prefix(Int(UInt8.max)))
        }
    }
}

private func appendIPOption(_ code: UInt8, _ address: IPv4Address, to data: inout Data) {
    data.append(code)
    data.append(4)
    appendUInt32(address.value, to: &data)
}

private func appendUInt32Option(_ code: UInt8, _ value: UInt32, to data: inout Data) {
    data.append(code)
    data.append(4)
    appendUInt32(value, to: &data)
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

private func udpIPv4Checksum(sourceIP: IPv4Address, destinationIP: IPv4Address, udpPacket: [UInt8]) -> UInt16 {
    var pseudo = Data()
    appendUInt32(sourceIP.value, to: &pseudo)
    appendUInt32(destinationIP.value, to: &pseudo)
    pseudo.append(0)
    pseudo.append(17)
    appendUInt16(UInt16(udpPacket.count), to: &pseudo)
    pseudo.append(contentsOf: udpPacket)
    let checksum = internetChecksum([UInt8](pseudo))
    return checksum == 0 ? 0xffff : checksum
}
