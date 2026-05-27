import Darwin
import Foundation
import Virtualization

struct ASIFImportRequest {
    let sourceURL: URL
    let destinationURL: URL
    let config: VMConfig?

    init(sourceURL: URL, destinationURL: URL, config: VMConfig? = nil) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.config = config
    }
}

struct ASIFImportResult: Equatable {
    let sourceURL: URL
    let projectURL: URL
    let virtualSizeBytes: UInt64
    let diskGB: Int
    let roundedDiskSizeUp: Bool
    let config: VMConfig
}

enum ASIFImporter {
    typealias VirtualSizeProvider = (URL) throws -> UInt64
    typealias MachineIdentifierCreator = (URL) throws -> Void
    typealias EFIVariableStoreCreator = (URL) throws -> Void
    typealias DiskCopier = (URL, URL) throws -> Void

    static func diskGB(forVirtualSizeBytes bytes: UInt64) throws -> Int {
        guard bytes > 0 else {
            throw AppError("ASIF virtual size must be greater than zero.")
        }

        let gib: UInt64 = 1024 * 1024 * 1024
        let rounded = bytes / gib + (bytes % gib == 0 ? 0 : 1)
        guard rounded <= UInt64(Int.max) else {
            throw AppError("ASIF virtual size is too large to represent in GiB.")
        }
        return Int(rounded)
    }

    static func importedConfig(diskGB: Int, cpuCount: Int = 4, memoryGB: Int = 4) throws -> VMConfig {
        try VMConfig(
            cpuCount: cpuCount,
            memoryGB: memoryGB,
            diskGB: diskGB,
            installerISOPath: nil,
            diskFormat: .asif,
            privateNetwork: .enabled,
            sharedDirectories: [],
            diskIO: .defaults
        ).validated()
    }

    static func importDisk(
        request: ASIFImportRequest,
        virtualSizeProvider: VirtualSizeProvider = { try DiskImageCreator.virtualSize(url: $0, format: .asif) },
        createMachineIdentifier: MachineIdentifierCreator = Self.createMachineIdentifier,
        createEFIVariableStore: EFIVariableStoreCreator = Self.createEFIVariableStore,
        copyDisk: DiskCopier = Self.copyDiskWithCloneFallback
    ) throws -> ASIFImportResult {
        let fileManager = FileManager.default
        let sourceURL = request.sourceURL.standardizedFileURL
        let destinationURL = request.destinationURL.standardizedFileURL
        try validateSource(sourceURL)
        try DiskImageCreator.validateASIFSupport()
        try validateDestination(destinationURL, sourceURL: sourceURL)

        let virtualSizeBytes = try virtualSizeProvider(sourceURL)
        let diskGB = try diskGB(forVirtualSizeBytes: virtualSizeBytes)
        let config = try (request.config ?? importedConfig(diskGB: diskGB)).validated()
        guard config.guestOS == .linux else {
            throw AppError("ASIF import currently supports Linux guests.")
        }
        guard config.diskFormat == .asif else {
            throw AppError("Imported VM config must use diskFormat 'asif'.")
        }
        guard config.diskGB == diskGB else {
            throw AppError("Imported VM config diskGB must match the detected ASIF disk size.")
        }
        let estimatedRequiredBytes = try estimatedRequiredBytes(for: sourceURL)
        try validateFreeSpace(requiredBytes: estimatedRequiredBytes, destinationURL: destinationURL)

        let stagingURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).importing-\(UUID().uuidString)", isDirectory: true)
        let stagedPaths = VMPaths.project(at: stagingURL)

        do {
            try fileManager.createDirectory(at: stagedPaths.vmDirectory, withIntermediateDirectories: true)
            try copyDisk(sourceURL, stagedPaths.asifDisk)
            try config.save(to: stagedPaths.config)
            try createMachineIdentifier(stagedPaths.machineIdentifier)
            try createEFIVariableStore(stagedPaths.efiStore)
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        } catch {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
            throw error
        }

        let gib: UInt64 = 1024 * 1024 * 1024
        let roundedDiskSizeUp = virtualSizeBytes % gib != 0
        if roundedDiskSizeUp {
            AppLog.storage.info(
                "Imported ASIF virtual size was rounded up project=\(destinationURL.path, privacy: .public) virtualBytes=\(virtualSizeBytes) diskGB=\(diskGB)"
            )
        }

        return ASIFImportResult(
            sourceURL: sourceURL,
            projectURL: destinationURL,
            virtualSizeBytes: virtualSizeBytes,
            diskGB: diskGB,
            roundedDiskSizeUp: roundedDiskSizeUp,
            config: config
        )
    }

    private static func validateSource(_ sourceURL: URL) throws {
        guard sourceURL.pathExtension.lowercased() == "asif" else {
            throw AppError("Import only supports .asif disk images.")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw AppError("ASIF source does not exist: \(sourceURL.path)")
        }

        guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            throw AppError("ASIF source is not readable: \(sourceURL.path)")
        }
    }

    private static func validateDestination(_ destinationURL: URL, sourceURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            let configURL = destinationURL.appendingPathComponent("okrun-vm.json")
            if fileManager.fileExists(atPath: configURL.path) {
                throw AppError("Destination already contains an Okrun project: \(destinationURL.path)")
            }
            throw AppError("Destination already exists. Choose a new project folder: \(destinationURL.path)")
        }

        let parent = destinationURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AppError("Destination parent folder does not exist: \(parent.path)")
        }

        let sourcePath = sourceURL.path
        let destinationPath = destinationURL.path
        if sourcePath == destinationPath || sourcePath.hasPrefix(destinationPath + "/") || destinationPath.hasPrefix(sourcePath + "/") {
            throw AppError("Destination overlaps the source ASIF path.")
        }
    }

    private static func estimatedRequiredBytes(for sourceURL: URL) throws -> UInt64 {
        let info = try DiskImageInfo.load(from: sourceURL)
        return info.allocatedSize ?? info.apparentSize
    }

    private static func validateFreeSpace(requiredBytes: UInt64, destinationURL: URL) throws {
        guard requiredBytes > 0,
              let availableBytes = hostAvailableBytes(for: destinationURL.deletingLastPathComponent()),
              availableBytes < requiredBytes else {
            return
        }

        let required = formattedByteCount(requiredBytes)
        let available = formattedByteCount(availableBytes)
        throw AppError("Not enough free space to import ASIF. Required \(required), available \(available).")
    }

    private static func formattedByteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
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

    private static func createMachineIdentifier(at url: URL) throws {
        let machineIdentifier = VZGenericMachineIdentifier()
        try machineIdentifier.dataRepresentation.write(to: url, options: .atomic)
    }

    private static func createEFIVariableStore(at url: URL) throws {
        _ = try VZEFIVariableStore(creatingVariableStoreAt: url)
    }

    private static func copyDiskWithCloneFallback(from sourceURL: URL, to destinationURL: URL) throws {
        let cloneResult = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                clonefile(sourcePath, destinationPath, 0)
            }
        }

        if cloneResult == 0 {
            return
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }
}
