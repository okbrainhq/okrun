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
    let savedStateDisk: URL
    let efiStore: URL
    let savedStateEfiStore: URL
    let installerEfiStore: URL
    let machineIdentifier: URL
    let machineState: URL

    static func project(at root: URL) -> VMPaths {
        let vmDirectory = root.appendingPathComponent("vm", isDirectory: true)
        let disk = preferredDisk(in: vmDirectory)
        return VMPaths(
            root: root,
            config: root.appendingPathComponent("okrun-vm.json"),
            vmDirectory: vmDirectory,
            disk: disk,
            savedStateDisk: vmDirectory.appendingPathComponent("machine-state.raw"),
            efiStore: vmDirectory.appendingPathComponent("efi.variables"),
            savedStateEfiStore: vmDirectory.appendingPathComponent("efi.variables.machine-state"),
            installerEfiStore: vmDirectory.appendingPathComponent("installer.efi.variables"),
            machineIdentifier: vmDirectory.appendingPathComponent("machine.identifier"),
            machineState: vmDirectory.appendingPathComponent("machine.state")
        )
    }

    private static func preferredDisk(in vmDirectory: URL) -> URL {
        let linuxDisk = vmDirectory.appendingPathComponent("linux.raw")
        let legacyDisk = vmDirectory.appendingPathComponent("debian.raw")

        if FileManager.default.fileExists(atPath: legacyDisk.path),
           !FileManager.default.fileExists(atPath: linuxDisk.path) {
            return legacyDisk
        }

        return linuxDisk
    }
}

struct ProjectRegistry: Codable, Equatable {
    var selectedProject: String?
    var projects: [String]

    static let empty = ProjectRegistry(selectedProject: nil, projects: [])
}

final class ProjectStore {
    private let url: URL

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".okrun")) {
        self.url = url
    }

    func load(defaultProject: URL?) throws -> ProjectRegistry {
        let fileManager = FileManager.default
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if !fileManager.fileExists(atPath: url.path) {
            var registry = ProjectRegistry.empty
            if let defaultProject {
                registry.projects = [standardPath(defaultProject)]
                registry.selectedProject = registry.projects.first
            }
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

struct VMConfig: Codable, Equatable {
    static let defaults = VMConfig(cpuCount: 4, memoryGB: 4, diskGB: 64, installerISOPath: nil)

    let cpuCount: Int
    let memoryGB: Int
    let diskGB: Int
    let installerISOPath: String?
    let privateNetwork: PrivateNetworkConfig
    let sharedDirectories: [SharedDirectoryConfig]

    enum CodingKeys: String, CodingKey {
        case cpuCount
        case memoryGB
        case diskGB
        case installerISOPath
        case privateNetwork
        case sharedDirectories
    }

    init(
        cpuCount: Int,
        memoryGB: Int,
        diskGB: Int,
        installerISOPath: String?,
        privateNetwork: PrivateNetworkConfig = .disabled,
        sharedDirectories: [SharedDirectoryConfig] = []
    ) {
        self.cpuCount = cpuCount
        self.memoryGB = memoryGB
        self.diskGB = diskGB
        self.installerISOPath = installerISOPath
        self.privateNetwork = privateNetwork
        self.sharedDirectories = sharedDirectories
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cpuCount = try container.decode(Int.self, forKey: .cpuCount)
        memoryGB = try container.decode(Int.self, forKey: .memoryGB)
        diskGB = try container.decode(Int.self, forKey: .diskGB)
        installerISOPath = try container.decodeIfPresent(String.self, forKey: .installerISOPath)
        privateNetwork = try container.decodeIfPresent(PrivateNetworkConfig.self, forKey: .privateNetwork) ?? .disabled
        sharedDirectories = try container.decodeIfPresent([SharedDirectoryConfig].self, forKey: .sharedDirectories) ?? []
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
        return try JSONDecoder().decode(VMConfig.self, from: data).validated()
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
        try PrivateNetworkValidator.validate(privateNetwork)
        try SharedDirectoryValidator.validate(sharedDirectories)
        return self
    }
}

struct PrivateNetworkConfig: Codable, Equatable {
    static let disabled = PrivateNetworkConfig(enabled: false)
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
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier) ?? Self.defaultIdentifier
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
    static func makeDevices(privateNetwork: PrivateNetworkConfig) throws -> [VZNetworkDeviceConfiguration] {
        var devices: [VZNetworkDeviceConfiguration] = [makeNATDevice()]

        if privateNetwork.enabled {
            devices.append(try makePrivateNetworkDevice(identifier: privateNetwork.identifier))
        }

        return devices
    }

    static func makeNATDevice() -> VZNetworkDeviceConfiguration {
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        return networkDevice
    }

    private static func makePrivateNetworkDevice(identifier: String) throws -> VZNetworkDeviceConfiguration {
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        let runtime = try PrivateNetworkRuntime(identifier: identifier)
        networkDevice.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: runtime.fileHandle)
        PrivateNetworkRuntimeRegistry.shared.retain(runtime)
        return networkDevice
    }
}

final class PrivateNetworkRuntimeRegistry {
    static let shared = PrivateNetworkRuntimeRegistry()

    private var runtimes: [PrivateNetworkRuntime] = []

    private init() {}

    func retain(_ runtime: PrivateNetworkRuntime) {
        runtimes.append(runtime)
    }

    func releaseAll() {
        runtimes.removeAll()
    }
}

final class PrivateNetworkRuntime {
    let fileHandle: FileHandle

    private let bridgeDescriptor: Int32
    private let peerDescriptor: Int32
    private let peerURL: URL
    private let networkDirectory: URL
    private let bridgeSource: DispatchSourceRead
    private let peerSource: DispatchSourceRead
    private let queue: DispatchQueue

    init(identifier: String) throws {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors) == 0 else {
            throw AppError("Failed to create private network socket pair: \(String(cString: strerror(errno))).")
        }

        bridgeDescriptor = descriptors[1]
        let guestDescriptor = descriptors[0]

        let sendBufferSize = 1_048_576
        let receiveBufferSize = 4_194_304
        try Self.setSocketOption(guestDescriptor, SO_SNDBUF, sendBufferSize)
        try Self.setSocketOption(guestDescriptor, SO_RCVBUF, receiveBufferSize)
        try Self.setSocketOption(bridgeDescriptor, SO_SNDBUF, sendBufferSize)
        try Self.setSocketOption(bridgeDescriptor, SO_RCVBUF, receiveBufferSize)

        let root = URL(fileURLWithPath: "/tmp/okrun-vnet", isDirectory: true)
        networkDirectory = root.appendingPathComponent(identifier, isDirectory: true)
        try FileManager.default.createDirectory(at: networkDirectory, withIntermediateDirectories: true)

        peerDescriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard peerDescriptor >= 0 else {
            close(guestDescriptor)
            close(bridgeDescriptor)
            throw AppError("Failed to create private network peer socket: \(String(cString: strerror(errno))).")
        }
        try Self.setSocketOption(peerDescriptor, SO_SNDBUF, sendBufferSize)
        try Self.setSocketOption(peerDescriptor, SO_RCVBUF, receiveBufferSize)

        peerURL = networkDirectory.appendingPathComponent("\(Self.shortPeerIdentifier()).sock")
        try Self.bindUnixDatagramSocket(peerDescriptor, to: peerURL.path)

        fileHandle = FileHandle(fileDescriptor: guestDescriptor, closeOnDealloc: true)
        queue = DispatchQueue(label: "okrun.private-network.\(identifier).\(UUID().uuidString)")

        bridgeSource = DispatchSource.makeReadSource(fileDescriptor: bridgeDescriptor, queue: queue)
        peerSource = DispatchSource.makeReadSource(fileDescriptor: peerDescriptor, queue: queue)

        bridgeSource.setEventHandler { [weak self] in
            self?.readGuestFrames()
        }
        peerSource.setEventHandler { [weak self] in
            self?.readPeerFrames()
        }
        bridgeSource.resume()
        peerSource.resume()
    }

    deinit {
        bridgeSource.cancel()
        peerSource.cancel()
        close(bridgeDescriptor)
        close(peerDescriptor)
        try? FileManager.default.removeItem(at: peerURL)
    }

    private func readGuestFrames() {
        var buffer = [UInt8](repeating: 0, count: 65_535)

        while true {
            let count = recv(bridgeDescriptor, &buffer, buffer.count, MSG_DONTWAIT)
            if count > 0 {
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
                _ = buffer.withUnsafeBufferPointer { pointer in
                    write(bridgeDescriptor, pointer.baseAddress, count)
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

enum VMStorage {
    struct PreparationResult: Equatable {
        enum DiskChange: Equatable {
            case created(size: UInt64)
            case expanded(from: UInt64, to: UInt64)
            case unchanged(size: UInt64)
        }

        let diskChange: DiskChange

        var expandedDisk: Bool {
            if case .expanded = diskChange {
                return true
            }
            return false
        }
    }

    @discardableResult
    static func prepare(paths: VMPaths, config: VMConfig) throws -> PreparationResult {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.vmDirectory, withIntermediateDirectories: true)

        let configuredDiskSize = UInt64(config.diskGB) * 1024 * 1024 * 1024
        let diskChange: PreparationResult.DiskChange
        if !fileManager.fileExists(atPath: paths.disk.path) {
            fileManager.createFile(atPath: paths.disk.path, contents: nil)
            let handle = try FileHandle(forWritingTo: paths.disk)
            try handle.truncate(atOffset: configuredDiskSize)
            try handle.close()
            diskChange = .created(size: configuredDiskSize)
        } else {
            let attributes = try fileManager.attributesOfItem(atPath: paths.disk.path)
            let currentSize = attributes[.size] as? UInt64 ?? 0
            if currentSize < configuredDiskSize {
                let handle = try FileHandle(forWritingTo: paths.disk)
                try handle.truncate(atOffset: configuredDiskSize)
                try handle.close()
                diskChange = .expanded(from: currentSize, to: configuredDiskSize)
            } else if currentSize > configuredDiskSize {
                throw AppError("Existing disk is larger than diskGB in the config. Increase diskGB or move \(paths.disk.path).")
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

        let result = PreparationResult(diskChange: diskChange)
        let diskInfo = try? DiskImageInfo.load(from: paths.disk)
        AppLog.storage.info(
            """
            Prepared storage project=\(paths.root.path, privacy: .public) disk=\(paths.disk.path, privacy: .public) configuredGB=\(config.diskGB) change=\(String(describing: diskChange), privacy: .public) apparentBytes=\(diskInfo?.apparentSize ?? 0) allocatedBytes=\(diskInfo?.allocatedSize ?? 0)
            """
        )

        if result.expandedDisk {
            AppLog.storage.warning(
                "Disk image expanded for project=\(paths.root.path, privacy: .public). Guest partition/filesystem still needs to be grown inside Linux."
            )
        }

        return result
    }
}

enum DiskImageAttachmentFactory {
    static func make(url: URL, readOnly: Bool) throws -> VZDiskImageStorageDeviceAttachment {
        try VZDiskImageStorageDeviceAttachment(
            url: url,
            readOnly: readOnly,
            cachingMode: .automatic,
            synchronizationMode: readOnly ? .fsync : .full
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
