import Foundation
import Virtualization

enum VMMode {
    case installer(URL)
    case installed
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

struct VMConfig: Codable, Equatable {
    static let defaults = VMConfig(cpuCount: 4, memoryGB: 4, diskGB: 64, installerISOPath: nil)

    let cpuCount: Int
    let memoryGB: Int
    let diskGB: Int
    let installerISOPath: String?
    let sharedDirectories: [SharedDirectoryConfig]

    enum CodingKeys: String, CodingKey {
        case cpuCount
        case memoryGB
        case diskGB
        case installerISOPath
        case sharedDirectories
    }

    init(
        cpuCount: Int,
        memoryGB: Int,
        diskGB: Int,
        installerISOPath: String?,
        sharedDirectories: [SharedDirectoryConfig] = []
    ) {
        self.cpuCount = cpuCount
        self.memoryGB = memoryGB
        self.diskGB = diskGB
        self.installerISOPath = installerISOPath
        self.sharedDirectories = sharedDirectories
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cpuCount = try container.decode(Int.self, forKey: .cpuCount)
        memoryGB = try container.decode(Int.self, forKey: .memoryGB)
        diskGB = try container.decode(Int.self, forKey: .diskGB)
        installerISOPath = try container.decodeIfPresent(String.self, forKey: .installerISOPath)
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
        try SharedDirectoryValidator.validate(sharedDirectories)
        return self
    }
}

struct SharedDirectoryConfig: Codable, Equatable {
    let name: String
    let hostPath: String
    let readOnly: Bool
}

enum SharedDirectoryValidator {
    static let tag = "okrun"

    static func validate(_ sharedDirectories: [SharedDirectoryConfig]) throws {
        var names = Set<String>()

        for directory in sharedDirectories {
            let name = directory.name.trimmingCharacters(in: .whitespacesAndNewlines)
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

enum DirectorySharingDeviceFactory {
    static func makeDevices(for sharedDirectories: [SharedDirectoryConfig]) throws -> [VZDirectorySharingDeviceConfiguration] {
        guard !sharedDirectories.isEmpty else { return [] }
        try SharedDirectoryValidator.validate(sharedDirectories)

        var directories: [String: VZSharedDirectory] = [:]
        for directory in sharedDirectories {
            let name = directory.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = URL(fileURLWithPath: directory.hostPath, isDirectory: true)
            directories[name] = VZSharedDirectory(url: url, readOnly: directory.readOnly)
        }

        let share = VZMultipleDirectoryShare(directories: directories)
        let device = VZVirtioFileSystemDeviceConfiguration(tag: SharedDirectoryValidator.tag)
        device.share = share
        return [device]
    }
}

enum VMStorage {
    static func prepare(paths: VMPaths, config: VMConfig) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.vmDirectory, withIntermediateDirectories: true)

        let configuredDiskSize = UInt64(config.diskGB) * 1024 * 1024 * 1024
        if !fileManager.fileExists(atPath: paths.disk.path) {
            fileManager.createFile(atPath: paths.disk.path, contents: nil)
            let handle = try FileHandle(forWritingTo: paths.disk)
            try handle.truncate(atOffset: configuredDiskSize)
            try handle.close()
        } else {
            let attributes = try fileManager.attributesOfItem(atPath: paths.disk.path)
            let currentSize = attributes[.size] as? UInt64 ?? 0
            if currentSize < configuredDiskSize {
                let handle = try FileHandle(forWritingTo: paths.disk)
                try handle.truncate(atOffset: configuredDiskSize)
                try handle.close()
            } else if currentSize > configuredDiskSize {
                throw AppError("Existing disk is larger than diskGB in the config. Increase diskGB or move \(paths.disk.path).")
            }
        }

        if !fileManager.fileExists(atPath: paths.efiStore.path) {
            _ = try VZEFIVariableStore(creatingVariableStoreAt: paths.efiStore)
        }

        if !fileManager.fileExists(atPath: paths.machineIdentifier.path) {
            let machineIdentifier = VZGenericMachineIdentifier()
            try machineIdentifier.dataRepresentation.write(to: paths.machineIdentifier, options: .atomic)
        }
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
