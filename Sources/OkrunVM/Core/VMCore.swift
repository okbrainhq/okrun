import Foundation
import Darwin
import Virtualization

enum VMMode {
    case installer(URL)
    case installed

    var logDescription: String {
        switch self {
        case .installer(let url):
            return "installer:\(url.lastPathComponent)"
        case .installed:
            return "installed"
        }
    }
}

struct VMPaths {
    let root: URL
    let config: URL
    let vmDirectory: URL
    let disk: URL
    let rawDisk: URL
    let asifDisk: URL
    let legacyDisk: URL
    let savedStateDisk: URL
    let efiStore: URL
    let savedStateEfiStore: URL
    let installerEfiStore: URL
    let machineIdentifier: URL
    let machineState: URL

    static func project(at root: URL) -> VMPaths {
        let vmDirectory = root.appendingPathComponent("vm", isDirectory: true)
        let rawDisk = vmDirectory.appendingPathComponent("linux.raw")
        let asifDisk = vmDirectory.appendingPathComponent("linux.asif")
        let legacyDisk = vmDirectory.appendingPathComponent("debian.raw")
        let disk = preferredDisk(rawDisk: rawDisk, asifDisk: asifDisk, legacyDisk: legacyDisk)
        return VMPaths(
            root: root,
            config: root.appendingPathComponent("okrun-vm.json"),
            vmDirectory: vmDirectory,
            disk: disk,
            rawDisk: rawDisk,
            asifDisk: asifDisk,
            legacyDisk: legacyDisk,
            savedStateDisk: vmDirectory.appendingPathComponent("machine-state.raw"),
            efiStore: vmDirectory.appendingPathComponent("efi.variables"),
            savedStateEfiStore: vmDirectory.appendingPathComponent("efi.variables.machine-state"),
            installerEfiStore: vmDirectory.appendingPathComponent("installer.efi.variables"),
            machineIdentifier: vmDirectory.appendingPathComponent("machine.identifier"),
            machineState: vmDirectory.appendingPathComponent("machine.state")
        )
    }

    private static func preferredDisk(rawDisk: URL, asifDisk: URL, legacyDisk: URL) -> URL {
        if FileManager.default.fileExists(atPath: asifDisk.path),
           !FileManager.default.fileExists(atPath: rawDisk.path),
           !FileManager.default.fileExists(atPath: legacyDisk.path) {
            return asifDisk
        }

        if FileManager.default.fileExists(atPath: legacyDisk.path),
           !FileManager.default.fileExists(atPath: rawDisk.path),
           !FileManager.default.fileExists(atPath: asifDisk.path) {
            return legacyDisk
        }

        return rawDisk
    }

    func diskURL(for config: VMConfig) throws -> URL {
        try diskURL(for: config.diskFormat)
    }

    func diskURL(for format: DiskImageFormat) throws -> URL {
        let fileManager = FileManager.default
        let rawExists = fileManager.fileExists(atPath: rawDisk.path)
        let asifExists = fileManager.fileExists(atPath: asifDisk.path)
        let legacyExists = fileManager.fileExists(atPath: legacyDisk.path)

        if [rawExists, asifExists, legacyExists].filter({ $0 }).count > 1 {
            throw AppError("Multiple VM disks exist in \(vmDirectory.path). Keep only one of linux.raw, linux.asif, or debian.raw.")
        }

        if asifExists {
            guard format == .asif else {
                throw AppError("Existing disk is linux.asif but diskFormat is '\(format.rawValue)'. Set diskFormat to 'asif' or move \(asifDisk.path).")
            }
            return asifDisk
        }

        if rawExists {
            guard format == .raw else {
                throw AppError("Existing disk is linux.raw but diskFormat is '\(format.rawValue)'. Set diskFormat to 'raw' or move \(rawDisk.path).")
            }
            return rawDisk
        }

        if legacyExists {
            guard format == .raw else {
                throw AppError("Existing legacy disk is debian.raw but diskFormat is '\(format.rawValue)'. Set diskFormat to 'raw' or migrate the disk manually.")
            }
            return legacyDisk
        }

        switch format {
        case .raw:
            return rawDisk
        case .asif:
            return asifDisk
        }
    }
}

struct ProjectRegistry: Codable, Equatable {
    var selectedProject: String?
    var projects: [String]

    static let empty = ProjectRegistry(selectedProject: nil, projects: [])
}

struct OkrunHome {
    let root: URL

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else if let environmentRoot = ProcessInfo.processInfo.environment["OKRUN_HOME"], !environmentRoot.isEmpty {
            self.root = URL(fileURLWithPath: environmentRoot, isDirectory: true)
        } else {
            self.root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".okrun", isDirectory: true)
        }
    }

    var registryURL: URL {
        root.appendingPathComponent("registry.json")
    }

    var privateNetworksURL: URL {
        root.appendingPathComponent("private-networks.json")
    }

    func privateNetworkStateDirectory(identifier: String) -> URL {
        root
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("private-networks", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
    }
}

final class ProjectStore {
    private let url: URL
    private let legacyURL: URL?

    init(url: URL? = nil, legacyURL explicitLegacyURL: URL? = nil) {
        if let url {
            self.url = url
            legacyURL = explicitLegacyURL
        } else if let registryPath = ProcessInfo.processInfo.environment["OKRUN_REGISTRY_PATH"], !registryPath.isEmpty {
            self.url = URL(fileURLWithPath: registryPath)
            legacyURL = nil
        } else {
            let home = OkrunHome()
            self.url = home.registryURL
            legacyURL = home.root
        }
    }

    func load(defaultProject: URL?) throws -> ProjectRegistry {
        let fileManager = FileManager.default
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try migrateLegacyRegistryIfNeeded(fileManager: fileManager)

        if !fileManager.fileExists(atPath: url.path) {
            var registry = ProjectRegistry.empty
            if let defaultProject {
                registry.projects = [standardPath(defaultProject)]
                registry.selectedProject = registry.projects.first
            }
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(registry)
            try data.write(to: url, options: .atomic)
            return registry
        }

        let data = try Data(contentsOf: url)
        var registry = try JSONDecoder().decode(ProjectRegistry.self, from: data)
        registry.projects = uniqueStandardPaths(registry.projects)

        if let selected = registry.selectedProject {
            registry.selectedProject = standardPath(URL(fileURLWithPath: selected, isDirectory: true))
        }

        if registry.selectedProject == nil || !registry.projects.contains(registry.selectedProject ?? "") {
            registry.selectedProject = registry.projects.first
        }

        return registry
    }

    func save(_ registry: ProjectRegistry) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(registry)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    var path: String {
        url.path
    }

    func standardPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func uniqueStandardPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for path in paths {
            let standard = standardPath(URL(fileURLWithPath: path, isDirectory: true))
            guard !seen.contains(standard) else { continue }
            seen.insert(standard)
            result.append(standard)
        }

        return result
    }

    private func migrateLegacyRegistryIfNeeded(fileManager: FileManager) throws {
        guard let legacyURL,
              legacyURL.path != url.path,
              fileManager.fileExists(atPath: legacyURL.path),
              !fileManager.fileExists(atPath: url.path) else {
            return
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacyURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return
        }

        let data = try Data(contentsOf: legacyURL)
        _ = try JSONDecoder().decode(ProjectRegistry.self, from: data)
        try fileManager.removeItem(at: legacyURL)
        try fileManager.createDirectory(at: legacyURL, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func defaultProjectRoot() -> URL? {
        let environmentRoot = ProcessInfo.processInfo.environment["OKRUN_HOME"].flatMap { value -> URL? in
            guard !value.isEmpty else { return nil }
            return URL(fileURLWithPath: value, isDirectory: true)
        }

        return environmentRoot ?? bundleRoot() ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    private static func bundleRoot() -> URL? {
        let candidates = [
            Bundle.main.bundleURL.path,
            Bundle.main.executableURL?.path ?? "",
            CommandLine.arguments.first ?? ""
        ]

        for path in candidates where !path.isEmpty {
            let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
            guard let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) else {
                continue
            }

            let appComponents = components.prefix(appIndex + 1)
            let appPath = NSString.path(withComponents: Array(appComponents))
            return URL(fileURLWithPath: appPath, isDirectory: true).deletingLastPathComponent()
        }

        return nil
    }
}

struct AppError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

struct DiskImageInfo: Equatable {
    let apparentSize: UInt64
    let allocatedSize: UInt64?

    static func load(from url: URL) throws -> DiskImageInfo {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let apparentSize = attributes[.size] as? UInt64 ?? 0
        let values = try url.resourceValues(forKeys: [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey])
        let allocatedSize = values.totalFileAllocatedSize ?? values.fileAllocatedSize
        return DiskImageInfo(apparentSize: apparentSize, allocatedSize: allocatedSize.map(UInt64.init))
    }
}

enum DiskImageFormat: String, Codable, Equatable {
    case raw
    case asif

    static var defaultForNewProjects: DiskImageFormat {
        if #available(macOS 26.0, *) {
            return .asif
        }
        return .raw
    }

    var isSupported: Bool {
        switch self {
        case .raw:
            return true
        case .asif:
            if #available(macOS 26.0, *) {
                return true
            }
            return false
        }
    }

    var displayName: String {
        switch self {
        case .raw:
            return "RAW"
        case .asif:
            return "ASIF"
        }
    }
}

enum DiskCachingMode: String, Codable, Equatable {
    case automatic
    case cached
    case uncached

    var virtualizationMode: VZDiskImageCachingMode {
        switch self {
        case .automatic:
            return .automatic
        case .cached:
            return .cached
        case .uncached:
            return .uncached
        }
    }
}

enum DiskSynchronizationMode: String, Codable, Equatable {
    case none
    case fsync
    case full

    var virtualizationMode: VZDiskImageSynchronizationMode {
        switch self {
        case .none:
            return .none
        case .fsync:
            return .fsync
        case .full:
            return .full
        }
    }
}

struct DiskIOConfig: Codable, Equatable {
    static let defaults = DiskIOConfig(caching: .cached, synchronization: .full)
    static let readOnlyDefaults = DiskIOConfig(caching: .automatic, synchronization: .fsync)

    let caching: DiskCachingMode
    let synchronization: DiskSynchronizationMode
}

struct VMConfig: Codable, Equatable {
    static var defaults: VMConfig {
        VMConfig(
            cpuCount: 4,
            memoryGB: 4,
            diskGB: 64,
            installerISOPath: nil,
            diskFormat: .defaultForNewProjects,
            privateNetwork: .enabled
        )
    }

    let cpuCount: Int
    let memoryGB: Int
    let diskGB: Int
    let diskFormat: DiskImageFormat
    let installerISOPath: String?
    let privateNetwork: PrivateNetworkConfig
    let sharedDirectories: [SharedDirectoryConfig]
    let diskIO: DiskIOConfig

    enum CodingKeys: String, CodingKey {
        case cpuCount
        case memoryGB
        case diskGB
        case diskFormat
        case installerISOPath
        case privateNetwork
        case sharedDirectories
        case diskIO
    }

    init(
        cpuCount: Int,
        memoryGB: Int,
        diskGB: Int,
        installerISOPath: String?,
        diskFormat: DiskImageFormat = .raw,
        privateNetwork: PrivateNetworkConfig = .enabled,
        sharedDirectories: [SharedDirectoryConfig] = [],
        diskIO: DiskIOConfig = .defaults
    ) {
        self.cpuCount = cpuCount
        self.memoryGB = memoryGB
        self.diskGB = diskGB
        self.diskFormat = diskFormat
        self.installerISOPath = installerISOPath
        self.privateNetwork = privateNetwork
        self.sharedDirectories = sharedDirectories
        self.diskIO = diskIO
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cpuCount = try container.decode(Int.self, forKey: .cpuCount)
        memoryGB = try container.decode(Int.self, forKey: .memoryGB)
        diskGB = try container.decode(Int.self, forKey: .diskGB)
        diskFormat = try container.decodeIfPresent(DiskImageFormat.self, forKey: .diskFormat) ?? .raw
        installerISOPath = try container.decodeIfPresent(String.self, forKey: .installerISOPath)
        privateNetwork = try container.decodeIfPresent(PrivateNetworkConfig.self, forKey: .privateNetwork) ?? .enabled
        sharedDirectories = try container.decodeIfPresent([SharedDirectoryConfig].self, forKey: .sharedDirectories) ?? []
        diskIO = try container.decodeIfPresent(DiskIOConfig.self, forKey: .diskIO) ?? .defaults
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cpuCount, forKey: .cpuCount)
        try container.encode(memoryGB, forKey: .memoryGB)
        try container.encode(diskGB, forKey: .diskGB)
        try container.encode(diskFormat, forKey: .diskFormat)
        if let installerISOPath {
            try container.encode(installerISOPath, forKey: .installerISOPath)
        } else {
            try container.encodeNil(forKey: .installerISOPath)
        }
        try container.encode(privateNetwork, forKey: .privateNetwork)
        try container.encode(sharedDirectories, forKey: .sharedDirectories)
        try container.encode(diskIO, forKey: .diskIO)
    }

    static func load(from url: URL) throws -> VMConfig {
        let fileManager = FileManager.default
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if !fileManager.fileExists(atPath: url.path) {
            let data = try encoder.encode(Self.defaults)
            try data.write(to: url, options: .atomic)
            return Self.defaults
        }

        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(VMConfig.self, from: data).validated()
        if !Self.configDataContainsDiskFormat(data)
            || !Self.configDataContainsDiskIO(data)
            || !Self.configDataContainsPrivateNetwork(data) {
            try config.save(to: url)
        }
        return config
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(validated())
        try data.write(to: url, options: .atomic)
    }

    func validated() throws -> VMConfig {
        guard cpuCount > 0 else {
            throw AppError("cpuCount must be greater than 0.")
        }
        guard memoryGB > 0 else {
            throw AppError("memoryGB must be greater than 0.")
        }
        guard diskGB > 0 else {
            throw AppError("diskGB must be greater than 0.")
        }
        guard diskFormat.isSupported else {
            throw AppError("diskFormat 'asif' requires macOS 26 Tahoe or later.")
        }
        try PrivateNetworkValidator.validate(privateNetwork)
        try SharedDirectoryValidator.validate(sharedDirectories)
        return self
    }

    private static func configDataContainsDiskFormat(_ data: Data) -> Bool {
        configData(data, contains: CodingKeys.diskFormat.rawValue)
    }

    private static func configDataContainsDiskIO(_ data: Data) -> Bool {
        configData(data, contains: CodingKeys.diskIO.rawValue)
    }

    private static func configDataContainsPrivateNetwork(_ data: Data) -> Bool {
        configData(data, contains: CodingKeys.privateNetwork.rawValue)
    }

    private static func configData(_ data: Data, contains key: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return false
        }
        return dictionary.keys.contains(key)
    }
}

struct PrivateNetworkConfig: Codable, Equatable {
    static let disabled = PrivateNetworkConfig(enabled: false)
    static let enabled = PrivateNetworkConfig(enabled: true)
    static let defaultIdentifier = "okrun"

    let enabled: Bool
    let identifier: String

    init(enabled: Bool, identifier: String = Self.defaultIdentifier) {
        self.enabled = enabled
        self.identifier = identifier
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case identifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        identifier = Self.defaultIdentifier
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
    }

    func validated() throws -> PrivateNetworkConfig {
        try PrivateNetworkValidator.validate(self)
        return self
    }
}

enum PrivateNetworkValidator {
    static func validate(_ config: PrivateNetworkConfig) throws {
        guard !config.enabled || !config.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError("privateNetwork identifier must not be empty when enabled.")
        }
        guard config.identifier.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\0")) == nil else {
            throw AppError("privateNetwork identifier must not contain '/', ':', or NUL.")
        }
        guard config.identifier.utf8.count <= 48 else {
            throw AppError("privateNetwork identifier must be 48 bytes or fewer.")
        }
    }
}

struct SharedDirectoryConfig: Codable, Equatable {
    let name: String
    let hostPath: String
    let readOnly: Bool
}

enum NetworkDeviceFactory {
    static func makeDevices(
        privateNetwork: PrivateNetworkConfig,
        machineIdentifierData: Data? = nil,
        hostNetworkConfigStore: HostNetworkConfigStore = HostNetworkConfigStore(),
        onRetainPrivateNetworkRuntime: ((PrivateNetworkRuntime) -> Void)? = nil
    ) throws -> [VZNetworkDeviceConfiguration] {
        var devices: [VZNetworkDeviceConfiguration] = [makeNATDevice()]

        if privateNetwork.enabled {
            devices.append(try makePrivateNetworkDevice(
                identifier: privateNetwork.identifier,
                machineIdentifierData: machineIdentifierData,
                hostNetworkConfigStore: hostNetworkConfigStore,
                onRetainPrivateNetworkRuntime: onRetainPrivateNetworkRuntime
            ))
        }

        return devices
    }

    static func makeNATDevice() -> VZNetworkDeviceConfiguration {
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        return networkDevice
    }

    private static func makePrivateNetworkDevice(
        identifier: String,
        machineIdentifierData: Data?,
        hostNetworkConfigStore: HostNetworkConfigStore,
        onRetainPrivateNetworkRuntime: ((PrivateNetworkRuntime) -> Void)?
    ) throws -> VZNetworkDeviceConfiguration {
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        if let macAddress = deterministicMACAddress(machineIdentifierData: machineIdentifierData, privateNetworkIdentifier: identifier) {
            networkDevice.macAddress = macAddress
        }
        let runtime = try PrivateNetworkRuntime(identifier: identifier)
        if let dhcpConfig = try hostNetworkConfigStore.dhcpConfigForPrivateNetwork(identifier: identifier) {
            let server = try HostDHCPServer(
                privateNetworkIdentifier: identifier,
                config: dhcpConfig,
                runtime: runtime,
                leaseStore: DHCPLeaseStore(stateDirectory: hostNetworkConfigStore.home.privateNetworkStateDirectory(identifier: identifier))
            )
            runtime.retainHostService(server)
        }
        let dhcpRange = try hostNetworkConfigStore.dhcpConfigForPrivateNetwork(identifier: identifier)
            .map { try PrivateNetworkDHCPLeaseRange(config: $0) }
        let localSwitchConfig = try hostNetworkConfigStore.localSwitchConfigForPrivateNetwork(identifier: identifier)
        let switchConfig = try hostNetworkConfigStore.switchConfigForPrivateNetwork(identifier: identifier)
        networkDevice.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: runtime.fileHandle)
        try PrivateNetworkRuntimeRegistry.shared.retain(
            runtime,
            localSwitchConfig: localSwitchConfig,
            switchConfig: switchConfig,
            dhcpRange: dhcpRange
        )
        onRetainPrivateNetworkRuntime?(runtime)
        return networkDevice
    }

    static func deterministicMACAddress(machineIdentifierData: Data?, privateNetworkIdentifier: String) -> VZMACAddress? {
        var bytes = [UInt8]("okrun-private-network:".utf8)
        if let machineIdentifierData {
            bytes.append(contentsOf: machineIdentifierData)
        }
        bytes.append(contentsOf: privateNetworkIdentifier.utf8)
        let digest = FNV1a64.hash(bytes)
        let macBytes: [UInt8] = [
            0x02,
            UInt8((digest >> 32) & 0xff),
            UInt8((digest >> 24) & 0xff),
            UInt8((digest >> 16) & 0xff),
            UInt8((digest >> 8) & 0xff),
            UInt8(digest & 0xff)
        ]
        let string = macBytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        return VZMACAddress(string: string)
    }
}

final class PrivateNetworkRuntimeRegistry {
    static let shared = PrivateNetworkRuntimeRegistry()

    private var runtimes: [PrivateNetworkRuntime] = []
    private var switches: [String: PrivateNetworkSwitchTransport] = [:]
    private var localSwitches: [String: PrivateNetworkSwitchTransport] = [:]
    private var switchFailures: [String: PrivateNetworkSwitchStatus] = [:]
    private var localSwitchFailures: [String: PrivateNetworkSwitchStatus] = [:]
    private var routers: [String: PrivateNetworkTransportRouter] = [:]
    private var nodeIDs: [String: UUID] = [:]

    private init() {}

    func retain(
        _ runtime: PrivateNetworkRuntime,
        localSwitchConfig: PrivateNetworkLocalSwitchConfig? = nil,
        switchConfig: PrivateNetworkSwitchConfig? = nil,
        dhcpRange: PrivateNetworkDHCPLeaseRange? = nil
    ) throws {
        runtimes.append(runtime)
        let router = router(for: runtime.identifier)
        router.addRuntime(runtime)

        var retainedTransport = false
        var retainedError: Error?
        if let localSwitchConfig {
            do {
                _ = try retainLocalSwitch(identifier: runtime.identifier, localSwitchConfig: localSwitchConfig, dhcpRange: dhcpRange)
                retainedTransport = true
            } catch {
                localSwitchFailures[runtime.identifier] = .failed(
                    identifier: runtime.identifier,
                    server: localSwitchConfig.server,
                    error: error.localizedDescription
                )
                retainedError = error
            }
        }

        if let switchConfig {
            do {
                _ = try retainSwitch(identifier: runtime.identifier, switchConfig: switchConfig, dhcpRange: dhcpRange)
                retainedTransport = true
            } catch {
                switchFailures[runtime.identifier] = .failed(
                    identifier: runtime.identifier,
                    server: switchConfig.server,
                    error: error.localizedDescription
                )
                retainedError = error
            }
        }

        if !retainedTransport, let retainedError {
            throw retainedError
        }
    }

    func configureLocalSwitch(
        identifier: String,
        localSwitchConfig: PrivateNetworkLocalSwitchConfig?,
        dhcpRange: PrivateNetworkDHCPLeaseRange?
    ) -> PrivateNetworkSwitchStatus {
        guard let localSwitchConfig else {
            localSwitches[identifier] = nil
            localSwitchFailures[identifier] = nil
            routers[identifier]?.setLocalSwitch(nil)
            return .disabled(identifier: identifier)
        }
        if let existingSwitch = localSwitches[identifier],
           canReuseLocalSwitch(existingSwitch, config: localSwitchConfig, dhcpRange: dhcpRange) {
            router(for: identifier).setLocalSwitch(existingSwitch)
            return existingSwitch.statusSnapshot()
        }
        localSwitches[identifier] = nil
        router(for: identifier).setLocalSwitch(nil)
        do {
            let switchTransport = try makeLocalSwitch(identifier: identifier, localSwitchConfig: localSwitchConfig, dhcpRange: dhcpRange)
            localSwitches[identifier] = switchTransport
            router(for: identifier).setLocalSwitch(switchTransport)
            localSwitchFailures[identifier] = nil
            return switchTransport.statusSnapshot()
        } catch {
            let status = PrivateNetworkSwitchStatus.failed(
                identifier: identifier,
                server: localSwitchConfig.server,
                error: error.localizedDescription
            )
            localSwitchFailures[identifier] = status
            return status
        }
    }

    func configureSwitch(
        identifier: String,
        switchConfig: PrivateNetworkSwitchConfig?,
        dhcpRange: PrivateNetworkDHCPLeaseRange?
    ) -> PrivateNetworkSwitchStatus {
        guard let switchConfig else {
            switches[identifier] = nil
            switchFailures[identifier] = nil
            routers[identifier]?.setWebSwitch(nil)
            return .disabled(identifier: identifier)
        }
        if let existingSwitch = switches[identifier],
           canReuseSwitch(existingSwitch, config: switchConfig, dhcpRange: dhcpRange) {
            router(for: identifier).setWebSwitch(existingSwitch)
            return existingSwitch.statusSnapshot()
        }
        switches[identifier] = nil
        router(for: identifier).setWebSwitch(nil)
        do {
            let switchTransport = try makeSwitch(identifier: identifier, switchConfig: switchConfig, dhcpRange: dhcpRange)
            switches[identifier] = switchTransport
            router(for: identifier).setWebSwitch(switchTransport)
            switchFailures[identifier] = nil
            return switchTransport.statusSnapshot()
        } catch {
            let status = PrivateNetworkSwitchStatus.failed(
                identifier: identifier,
                server: switchConfig.server,
                error: error.localizedDescription
            )
            switchFailures[identifier] = status
            return status
        }
    }

    func hasSwitch(identifier: String) -> Bool {
        switches[identifier] != nil
    }

    func hasLocalSwitch(identifier: String) -> Bool {
        localSwitches[identifier] != nil
    }

    func switchStatus(identifier: String) -> PrivateNetworkSwitchStatus {
        switches[identifier]?.statusSnapshot()
            ?? switchFailures[identifier]
            ?? .disabled(identifier: identifier)
    }

    func localSwitchStatus(identifier: String) -> PrivateNetworkSwitchStatus {
        localSwitches[identifier]?.statusSnapshot()
            ?? localSwitchFailures[identifier]
            ?? .disabled(identifier: identifier)
    }

    func releaseAll() {
        for runtime in runtimes {
            routers[runtime.identifier]?.removeRuntime(runtime)
        }
        runtimes.removeAll()
        switches.removeAll()
        localSwitches.removeAll()
        switchFailures.removeAll()
        localSwitchFailures.removeAll()
        routers.removeAll()
        nodeIDs.removeAll()
    }

    func release(_ ownedRuntimes: [PrivateNetworkRuntime]) {
        guard !ownedRuntimes.isEmpty else { return }
        for runtime in ownedRuntimes {
            routers[runtime.identifier]?.removeRuntime(runtime)
        }
        runtimes.removeAll { runtime in
            ownedRuntimes.contains { $0 === runtime }
        }
        for identifier in Array(switches.keys) where !runtimes.contains(where: { $0.identifier == identifier }) {
            switches[identifier] = nil
        }
        for identifier in Array(localSwitches.keys) where !runtimes.contains(where: { $0.identifier == identifier }) {
            localSwitches[identifier] = nil
        }
        for identifier in Array(routers.keys) where routers[identifier]?.hasRuntimes() != true {
            routers[identifier] = nil
        }
        for identifier in Array(nodeIDs.keys) where !runtimes.contains(where: { $0.identifier == identifier }) {
            nodeIDs[identifier] = nil
        }
    }

    @discardableResult
    private func retainLocalSwitch(
        identifier: String,
        localSwitchConfig: PrivateNetworkLocalSwitchConfig,
        dhcpRange: PrivateNetworkDHCPLeaseRange?
    ) throws -> PrivateNetworkSwitchTransport {
        let transportRouter = router(for: identifier)
        if let existingSwitch = localSwitches[identifier],
           canReuseLocalSwitch(existingSwitch, config: localSwitchConfig, dhcpRange: dhcpRange) {
            transportRouter.setLocalSwitch(existingSwitch)
            return existingSwitch
        }

        localSwitches[identifier] = nil
        transportRouter.setLocalSwitch(nil)
        let switchTransport = try makeLocalSwitch(identifier: identifier, localSwitchConfig: localSwitchConfig, dhcpRange: dhcpRange)
        localSwitches[identifier] = switchTransport
        localSwitchFailures[identifier] = nil
        transportRouter.setLocalSwitch(switchTransport)
        return switchTransport
    }

    @discardableResult
    private func retainSwitch(
        identifier: String,
        switchConfig: PrivateNetworkSwitchConfig,
        dhcpRange: PrivateNetworkDHCPLeaseRange?
    ) throws -> PrivateNetworkSwitchTransport {
        let transportRouter = router(for: identifier)
        if let existingSwitch = switches[identifier],
           canReuseSwitch(existingSwitch, config: switchConfig, dhcpRange: dhcpRange) {
            transportRouter.setWebSwitch(existingSwitch)
            return existingSwitch
        }

        switches[identifier] = nil
        transportRouter.setWebSwitch(nil)
        let switchTransport = try makeSwitch(identifier: identifier, switchConfig: switchConfig, dhcpRange: dhcpRange)
        switches[identifier] = switchTransport
        switchFailures[identifier] = nil
        transportRouter.setWebSwitch(switchTransport)
        return switchTransport
    }

    private func canReuseSwitch(
        _ existingSwitch: PrivateNetworkSwitchTransport,
        config switchConfig: PrivateNetworkSwitchConfig,
        dhcpRange: PrivateNetworkDHCPLeaseRange?
    ) -> Bool {
        guard existingSwitch.matches(config: switchConfig, dhcpRange: dhcpRange) else {
            return false
        }
        let state = existingSwitch.statusSnapshot().state
        return state == .connecting || state == .connected
    }

    private func canReuseLocalSwitch(
        _ existingSwitch: PrivateNetworkSwitchTransport,
        config localSwitchConfig: PrivateNetworkLocalSwitchConfig,
        dhcpRange: PrivateNetworkDHCPLeaseRange?
    ) -> Bool {
        guard existingSwitch.matches(localConfig: localSwitchConfig, dhcpRange: dhcpRange) else {
            return false
        }
        let state = existingSwitch.statusSnapshot().state
        return state == .connecting || state == .connected
    }

    private func makeLocalSwitch(
        identifier: String,
        localSwitchConfig: PrivateNetworkLocalSwitchConfig,
        dhcpRange: PrivateNetworkDHCPLeaseRange?
    ) throws -> PrivateNetworkSwitchTransport {
        let transportRouter = router(for: identifier)
        return try PrivateNetworkSwitchTransport(
            identifier: identifier,
            localConfig: localSwitchConfig,
            dhcpRange: dhcpRange,
            nodeID: nodeID(for: identifier),
            onRemoteFrame: { [weak transportRouter] frame in
                transportRouter?.receiveRemoteFrame(frame, via: .localSwitch)
            }
        )
    }

    private func makeSwitch(
        identifier: String,
        switchConfig: PrivateNetworkSwitchConfig,
        dhcpRange: PrivateNetworkDHCPLeaseRange?
    ) throws -> PrivateNetworkSwitchTransport {
        let transportRouter = router(for: identifier)
        return try PrivateNetworkSwitchTransport(
            identifier: identifier,
            config: switchConfig,
            dhcpRange: dhcpRange,
            nodeID: nodeID(for: identifier),
            onRemoteFrame: { [weak transportRouter] frame in
                transportRouter?.receiveRemoteFrame(frame, via: .webSwitch)
            }
        )
    }

    private func nodeID(for identifier: String) -> UUID {
        if let nodeID = nodeIDs[identifier] {
            return nodeID
        }
        let nodeID = UUID()
        nodeIDs[identifier] = nodeID
        return nodeID
    }

    private func router(for identifier: String) -> PrivateNetworkTransportRouter {
        if let router = routers[identifier] {
            return router
        }
        let router = PrivateNetworkTransportRouter(identifier: identifier)
        if let localSwitchTransport = localSwitches[identifier] {
            router.setLocalSwitch(localSwitchTransport)
        }
        if let switchTransport = switches[identifier] {
            router.setWebSwitch(switchTransport)
        }
        routers[identifier] = router
        return router
    }
}

final class PrivateNetworkRuntime {
    let identifier: String
    let fileHandle: FileHandle

    private let hostDescriptor: Int32
    private let peerDescriptor: Int32
    private let peerURL: URL
    private let networkDirectory: URL
    private let hostSource: DispatchSourceRead
    private let peerSource: DispatchSourceRead
    private let queue: DispatchQueue
    private let observerLock = NSLock()
    private var frameObservers: [(PrivateNetworkFrameDirection, Data) -> Void] = []
    private var hostServices: [AnyObject] = []

    init(identifier: String) throws {
        self.identifier = identifier
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors) == 0 else {
            throw AppError("Failed to create private network socket pair: \(String(cString: strerror(errno))).")
        }

        hostDescriptor = descriptors[1]
        let guestDescriptor = descriptors[0]

        let sendBufferSize = 1_048_576
        let receiveBufferSize = 4_194_304
        try Self.setSocketOption(guestDescriptor, SO_SNDBUF, sendBufferSize)
        try Self.setSocketOption(guestDescriptor, SO_RCVBUF, receiveBufferSize)
        try Self.setSocketOption(hostDescriptor, SO_SNDBUF, sendBufferSize)
        try Self.setSocketOption(hostDescriptor, SO_RCVBUF, receiveBufferSize)

        let socketRoot = ProcessInfo.processInfo.environment["OKRUN_PRIVATE_NETWORK_SOCKET_ROOT"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "/tmp/okrun-vnet"
        let root = URL(fileURLWithPath: socketRoot, isDirectory: true)
        networkDirectory = root.appendingPathComponent(identifier, isDirectory: true)
        try FileManager.default.createDirectory(at: networkDirectory, withIntermediateDirectories: true)

        peerDescriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard peerDescriptor >= 0 else {
            close(guestDescriptor)
            close(hostDescriptor)
            throw AppError("Failed to create private network peer socket: \(String(cString: strerror(errno))).")
        }
        try Self.setSocketOption(peerDescriptor, SO_SNDBUF, sendBufferSize)
        try Self.setSocketOption(peerDescriptor, SO_RCVBUF, receiveBufferSize)

        peerURL = networkDirectory.appendingPathComponent("\(Self.shortPeerIdentifier()).sock")
        try Self.bindUnixDatagramSocket(peerDescriptor, to: peerURL.path)

        fileHandle = FileHandle(fileDescriptor: guestDescriptor, closeOnDealloc: true)
        queue = DispatchQueue(label: "okrun.private-network.\(identifier).\(UUID().uuidString)")

        hostSource = DispatchSource.makeReadSource(fileDescriptor: hostDescriptor, queue: queue)
        peerSource = DispatchSource.makeReadSource(fileDescriptor: peerDescriptor, queue: queue)

        hostSource.setEventHandler { [weak self] in
            self?.readGuestFrames()
        }
        peerSource.setEventHandler { [weak self] in
            self?.readPeerFrames()
        }
        hostSource.resume()
        peerSource.resume()
    }

    deinit {
        hostSource.cancel()
        peerSource.cancel()
        close(hostDescriptor)
        close(peerDescriptor)
        try? FileManager.default.removeItem(at: peerURL)
    }

    private func readGuestFrames() {
        var buffer = [UInt8](repeating: 0, count: 65_535)

        while true {
            let count = recv(hostDescriptor, &buffer, buffer.count, MSG_DONTWAIT)
            if count > 0 {
                notifyObservers(direction: .fromGuest, frame: Data(buffer.prefix(count)))
                broadcastFrame(buffer, count: count)
                continue
            }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return
            }
            return
        }
    }

    private func readPeerFrames() {
        var buffer = [UInt8](repeating: 0, count: 65_535)

        while true {
            let count = recv(peerDescriptor, &buffer, buffer.count, MSG_DONTWAIT)
            if count > 0 {
                notifyObservers(direction: .fromPeer, frame: Data(buffer.prefix(count)))
                _ = buffer.withUnsafeBufferPointer { pointer in
                    write(hostDescriptor, pointer.baseAddress, count)
                }
                continue
            }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return
            }
            return
        }
    }

    private func broadcastFrame(_ frame: [UInt8], count: Int) {
        guard let peers = try? FileManager.default.contentsOfDirectory(at: networkDirectory, includingPropertiesForKeys: nil) else {
            return
        }

        for peer in peers where peer.pathExtension == "sock" && peer != peerURL {
            _ = frame.withUnsafeBufferPointer { pointer in
                Self.sendUnixDatagram(
                    descriptor: peerDescriptor,
                    buffer: pointer.baseAddress,
                    count: count,
                    to: peer.path
                )
            }
        }
    }

    func addFrameObserver(_ observer: @escaping (PrivateNetworkFrameDirection, Data) -> Void) {
        observerLock.lock()
        frameObservers.append(observer)
        observerLock.unlock()
    }

    func injectFrameToGuest(_ frame: Data) {
        frame.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            _ = write(hostDescriptor, baseAddress, frame.count)
        }
    }

    func retainHostService(_ service: AnyObject) {
        hostServices.append(service)
    }

    private func notifyObservers(direction: PrivateNetworkFrameDirection, frame: Data) {
        observerLock.lock()
        let observers = frameObservers
        observerLock.unlock()
        for observer in observers {
            observer(direction, frame)
        }
    }

    private static func setSocketOption(_ descriptor: Int32, _ option: Int32, _ value: Int) throws {
        var socketValue = Int32(value)
        guard setsockopt(descriptor, SOL_SOCKET, option, &socketValue, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw AppError("Failed to configure private network socket: \(String(cString: strerror(errno))).")
        }
    }

    private static func shortPeerIdentifier() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    }

    private static func bindUnixDatagramSocket(_ descriptor: Int32, to path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < pathCapacity else {
            throw AppError("Private network socket path is too long: \(path)")
        }

        try? FileManager.default.removeItem(atPath: path)
        _ = withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
            path.withCString { source in
                strncpy(pointer, source, pathCapacity - 1)
            }
        }

        let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, length)
            }
        }
        guard result == 0 else {
            throw AppError("Failed to bind private network socket: \(String(cString: strerror(errno))).")
        }
    }

    private static func sendUnixDatagram(
        descriptor: Int32,
        buffer: UnsafePointer<UInt8>?,
        count: Int,
        to path: String
    ) -> Int {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < pathCapacity else {
            return -1
        }

        _ = withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
            path.withCString { source in
                strncpy(pointer, source, pathCapacity - 1)
            }
        }

        let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(descriptor, buffer, count, MSG_DONTWAIT, $0, length)
            }
        }
    }
}

enum PrivateNetworkFrameDirection {
    case fromGuest
    case fromPeer
}

enum FNV1a64 {
    static func hash(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }
}

enum SharedDirectoryValidator {
    static let tag = "okrun"

    static func validate(_ sharedDirectories: [SharedDirectoryConfig]) throws {
        var names = Set<String>()

        for directory in sharedDirectories {
            let name = directory.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == ManagedGuestTools.logShareName {
                continue
            }

            guard !name.isEmpty else {
                throw AppError("sharedDirectories name must not be empty.")
            }
            guard name.rangeOfCharacter(from: CharacterSet(charactersIn: "/:")) == nil else {
                throw AppError("sharedDirectories name must not contain '/' or ':'.")
            }
            guard names.insert(name).inserted else {
                throw AppError("sharedDirectories contains duplicate name '\(name)'.")
            }

            let url = URL(fileURLWithPath: directory.hostPath, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw AppError("Shared directory does not exist: \(url.path)")
            }
            guard isDirectory.boolValue else {
                throw AppError("Shared directory path is not a directory: \(url.path)")
            }
        }

        try VZVirtioFileSystemDeviceConfiguration.validateTag(tag)
    }
}

enum ManagedGuestTools {
    static let logShareName = "okrun-guest-logs"

    static func guestLogsDirectory(in paths: VMPaths) -> URL {
        paths.vmDirectory.appendingPathComponent("guest-logs", isDirectory: true)
    }
}

enum DirectorySharingDeviceFactory {
    static func makeDevices(
        for sharedDirectories: [SharedDirectoryConfig],
        managedGuestLogsDirectory: URL? = nil
    ) throws -> [VZDirectorySharingDeviceConfiguration] {
        try SharedDirectoryValidator.validate(sharedDirectories)

        var directories: [String: VZSharedDirectory] = [:]
        for directory in sharedDirectories {
            let name = directory.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == ManagedGuestTools.logShareName {
                continue
            }

            let url = URL(fileURLWithPath: directory.hostPath, isDirectory: true)
            directories[name] = VZSharedDirectory(url: url, readOnly: directory.readOnly)
        }

        if let managedGuestLogsDirectory {
            try FileManager.default.createDirectory(at: managedGuestLogsDirectory, withIntermediateDirectories: true)
            directories[ManagedGuestTools.logShareName] = VZSharedDirectory(url: managedGuestLogsDirectory, readOnly: false)
        }

        guard !directories.isEmpty else { return [] }

        let share = VZMultipleDirectoryShare(directories: directories)
        let device = VZVirtioFileSystemDeviceConfiguration(tag: SharedDirectoryValidator.tag)
        device.share = share
        return [device]
    }
}

enum DiskImageCreator {
    private struct DiskutilImageInfo: Decodable {
        let sizeInfo: SizeInfo?
        let size: UInt64?

        enum CodingKeys: String, CodingKey {
            case sizeInfo = "Size Info"
            case size = "Size"
        }

        func virtualSizeBytes() throws -> UInt64 {
            if let totalBytes = sizeInfo?.totalBytes {
                return totalBytes
            }
            if let size {
                return size
            }
            throw AppError("Could not read ASIF disk size from diskutil image info.")
        }
    }

    private struct SizeInfo: Decodable {
        let totalBytes: UInt64?

        enum CodingKeys: String, CodingKey {
            case totalBytes = "Total Bytes"
        }
    }

    static func create(url: URL, sizeBytes: UInt64, format: DiskImageFormat) throws {
        switch format {
        case .raw:
            FileManager.default.createFile(atPath: url.path, contents: nil)
            try resizeRawDisk(url: url, sizeBytes: sizeBytes)
        case .asif:
            try validateASIFSupport()
            _ = try runDiskutil([
                "image", "create", "blank",
                "--fs", "none",
                "--format", "ASIF",
                "--size", sizeArgument(sizeBytes),
                url.path
            ])
        }
    }

    static func resize(url: URL, sizeBytes: UInt64, format: DiskImageFormat) throws {
        switch format {
        case .raw:
            try resizeRawDisk(url: url, sizeBytes: sizeBytes)
        case .asif:
            try validateASIFSupport()
            _ = try runDiskutil([
                "image", "resize",
                "--size", sizeArgument(sizeBytes),
                url.path
            ])
        }
    }

    static func virtualSize(url: URL, format: DiskImageFormat) throws -> UInt64 {
        switch format {
        case .raw:
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.size] as? UInt64 ?? 0
        case .asif:
            try validateASIFSupport()
            let output = try runDiskutil(["image", "info", "--plist", url.path])
            return try PropertyListDecoder().decode(DiskutilImageInfo.self, from: output.stdout).virtualSizeBytes()
        }
    }

    private static func resizeRawDisk(url: URL, sizeBytes: UInt64) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: sizeBytes)
        try handle.close()
    }

    static func validateASIFSupport() throws {
        guard DiskImageFormat.asif.isSupported else {
            throw AppError("ASIF disk images require macOS 26 Tahoe or later.")
        }
    }

    private static func sizeArgument(_ bytes: UInt64) -> String {
        "\(bytes)b"
    }

    private static func runDiskutil(_ arguments: [String]) throws -> (stdout: Data, stderr: Data) {
        let diskutilURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        guard FileManager.default.isExecutableFile(atPath: diskutilURL.path) else {
            throw AppError("diskutil is not available at \(diskutilURL.path).")
        }

        let process = Process()
        process.executableURL = diskutilURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw AppError("Failed to run diskutil \(arguments.joined(separator: " ")): \(error.localizedDescription)")
        }

        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = firstNonEmptyLine(stderr, stdout) ?? "exit code \(process.terminationStatus)"
            throw AppError("diskutil \(arguments.joined(separator: " ")) failed: \(message)")
        }

        return (stdout, stderr)
    }

    private static func firstNonEmptyLine(_ outputs: Data...) -> String? {
        for output in outputs {
            guard let string = String(data: output, encoding: .utf8) else { continue }
            if let line = string.split(separator: "\n").first(where: { !$0.isEmpty }) {
                return String(line)
            }
        }
        return nil
    }
}

enum VMStorage {
    struct PreparationResult: Equatable {
        static let lowHostFreeSpaceThreshold: UInt64 = 16 * 1024 * 1024 * 1024

        enum DiskChange: Equatable {
            case created(size: UInt64)
            case expanded(from: UInt64, to: UInt64)
            case unchanged(size: UInt64)
        }

        let diskChange: DiskChange
        let hostAvailableBytes: UInt64?

        var expandedDisk: Bool {
            if case .expanded = diskChange {
                return true
            }
            return false
        }

        var hasLowHostFreeSpace: Bool {
            guard let hostAvailableBytes else { return false }
            return hostAvailableBytes < Self.lowHostFreeSpaceThreshold
        }
    }

    @discardableResult
    static func prepare(paths: VMPaths, config: VMConfig) throws -> PreparationResult {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.vmDirectory, withIntermediateDirectories: true)

        let diskURL = try paths.diskURL(for: config)
        let configuredDiskSize = UInt64(config.diskGB) * 1024 * 1024 * 1024
        let diskChange: PreparationResult.DiskChange
        if !fileManager.fileExists(atPath: diskURL.path) {
            try DiskImageCreator.create(url: diskURL, sizeBytes: configuredDiskSize, format: config.diskFormat)
            diskChange = .created(size: configuredDiskSize)
        } else {
            let currentSize = try DiskImageCreator.virtualSize(url: diskURL, format: config.diskFormat)
            if currentSize < configuredDiskSize {
                try DiskImageCreator.resize(url: diskURL, sizeBytes: configuredDiskSize, format: config.diskFormat)
                diskChange = .expanded(from: currentSize, to: configuredDiskSize)
            } else if currentSize > configuredDiskSize {
                throw AppError("Existing disk is larger than diskGB in the config. Increase diskGB or move \(diskURL.path).")
            } else {
                diskChange = .unchanged(size: currentSize)
            }
        }

        if !fileManager.fileExists(atPath: paths.efiStore.path) {
            _ = try VZEFIVariableStore(creatingVariableStoreAt: paths.efiStore)
        }

        if !fileManager.fileExists(atPath: paths.machineIdentifier.path) {
            let machineIdentifier = VZGenericMachineIdentifier()
            try machineIdentifier.dataRepresentation.write(to: paths.machineIdentifier, options: .atomic)
        }

        let hostAvailableBytes = hostAvailableBytes(for: paths.vmDirectory)
        let result = PreparationResult(diskChange: diskChange, hostAvailableBytes: hostAvailableBytes)
        let diskInfo = try? DiskImageInfo.load(from: diskURL)
        AppLog.storage.info(
            """
            Prepared storage project=\(paths.root.path, privacy: .public) disk=\(diskURL.path, privacy: .public) format=\(config.diskFormat.rawValue, privacy: .public) configuredGB=\(config.diskGB) change=\(String(describing: diskChange), privacy: .public) apparentBytes=\(diskInfo?.apparentSize ?? 0) allocatedBytes=\(diskInfo?.allocatedSize ?? 0) hostAvailableBytes=\(hostAvailableBytes ?? 0)
            """
        )

        if result.expandedDisk {
            AppLog.storage.warning(
                "Disk image expanded for project=\(paths.root.path, privacy: .public). Guest partition/filesystem still needs to be grown inside Linux."
            )
        }

        if result.hasLowHostFreeSpace {
            AppLog.storage.warning(
                "Host volume is low on free space for project=\(paths.root.path, privacy: .public) availableBytes=\(hostAvailableBytes ?? 0)"
            )
        }

        return result
    }

    private static func hostAvailableBytes(for url: URL) -> UInt64? {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]) else {
            return nil
        }

        if let importantCapacity = values.volumeAvailableCapacityForImportantUsage, importantCapacity >= 0 {
            return UInt64(importantCapacity)
        }

        if let capacity = values.volumeAvailableCapacity, capacity >= 0 {
            return UInt64(capacity)
        }

        return nil
    }
}

enum DiskImageAttachmentFactory {
    static func make(url: URL, readOnly: Bool, diskIO: DiskIOConfig? = nil) throws -> VZDiskImageStorageDeviceAttachment {
        let options = diskIO ?? (readOnly ? DiskIOConfig.readOnlyDefaults : DiskIOConfig.defaults)
        return try VZDiskImageStorageDeviceAttachment(
            url: url,
            readOnly: readOnly,
            cachingMode: options.caching.virtualizationMode,
            synchronizationMode: options.synchronization.virtualizationMode
        )
    }
}

enum EFIVariableStoreFactory {
    static func make(paths: VMPaths, mode: VMMode) throws -> VZEFIVariableStore {
        switch mode {
        case .installed:
            return VZEFIVariableStore(url: paths.efiStore)
        case .installer:
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: paths.installerEfiStore.path) {
                try fileManager.removeItem(at: paths.installerEfiStore)
            }
            return try VZEFIVariableStore(creatingVariableStoreAt: paths.installerEfiStore)
        }
    }
}
