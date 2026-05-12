import Foundation
import Testing
import Virtualization
@testable import OkrunVM

@Suite("Okrun VM")
struct OkrunVMTests {
    @Test
    func vmPathsPreferLegacyDebianDiskWhenLinuxDiskIsMissing() throws {
        let project = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(project) }

        let vmDirectory = project.appendingPathComponent("vm", isDirectory: true)
        try FileManager.default.createDirectory(at: vmDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: vmDirectory.appendingPathComponent("debian.raw").path, contents: Data())

        let paths = VMPaths.project(at: project)

        #expect(paths.disk.lastPathComponent == "debian.raw")
        #expect(paths.config == project.appendingPathComponent("okrun-vm.json"))
        #expect(paths.savedStateDisk == vmDirectory.appendingPathComponent("machine-state.raw"))
        #expect(paths.efiStore == vmDirectory.appendingPathComponent("efi.variables"))
        #expect(paths.savedStateEfiStore == vmDirectory.appendingPathComponent("efi.variables.machine-state"))
        #expect(paths.installerEfiStore == vmDirectory.appendingPathComponent("installer.efi.variables"))
        #expect(paths.machineState == vmDirectory.appendingPathComponent("machine.state"))
    }

    @Test
    func vmPathsPreferLinuxDiskWhenPresent() throws {
        let project = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(project) }

        let vmDirectory = project.appendingPathComponent("vm", isDirectory: true)
        try FileManager.default.createDirectory(at: vmDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: vmDirectory.appendingPathComponent("debian.raw").path, contents: Data())
        FileManager.default.createFile(atPath: vmDirectory.appendingPathComponent("linux.raw").path, contents: Data())

        #expect(VMPaths.project(at: project).disk.lastPathComponent == "linux.raw")
    }

    @Test
    func vmPathsResolveASIFDiskForASIFFormat() throws {
        let project = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(project) }

        let paths = VMPaths.project(at: project)

        #expect(try paths.diskURL(for: .asif).lastPathComponent == "linux.asif")
    }

    @Test
    func vmPathsRejectDiskFormatMismatch() throws {
        let project = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(project) }

        let paths = VMPaths.project(at: project)
        try FileManager.default.createDirectory(at: paths.vmDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.rawDisk.path, contents: Data())

        #expect(throws: (any Error).self) {
            try paths.diskURL(for: .asif)
        }
    }

    @Test
    func vmConfigLoadCreatesDefaultConfigAndValidatesSavedValues() throws {
        let project = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(project) }

        let configURL = project.appendingPathComponent("okrun-vm.json")
        let defaultConfig = try VMConfig.load(from: configURL)
        #expect(defaultConfig == .defaults)

        let customConfig = VMConfig(cpuCount: 6, memoryGB: 8, diskGB: 64, installerISOPath: "/tmp/debian.iso")
        try customConfig.save(to: configURL)

        #expect(try VMConfig.load(from: configURL) == customConfig)
    }

    @Test
    func vmConfigLoadsLegacyConfigWithoutSharedDirectories() throws {
        let project = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(project) }

        let configURL = project.appendingPathComponent("okrun-vm.json")
        try Data("""
        {
          "cpuCount": 2,
          "memoryGB": 3,
          "diskGB": 20,
          "installerISOPath": null
        }
        """.utf8).write(to: configURL)

        let config = try VMConfig.load(from: configURL)

        #expect(config.cpuCount == 2)
        #expect(config.memoryGB == 3)
        #expect(config.diskGB == 20)
        #expect(config.installerISOPath == nil)
        #expect(config.privateNetwork == .disabled)
        #expect(config.sharedDirectories == [])
        #expect(config.diskIO == .defaults)

        let migratedData = try Data(contentsOf: configURL)
        let migratedJSON = try #require(JSONSerialization.jsonObject(with: migratedData) as? [String: Any])
        #expect(migratedJSON["diskFormat"] as? String == "raw")
        let diskIO = try #require(migratedJSON["diskIO"] as? [String: Any])
        #expect(diskIO["caching"] as? String == "cached")
        #expect(diskIO["synchronization"] as? String == "full")
    }

    @Test
    func vmConfigSavesAndLoadsPrivateNetworkAndSharedDirectories() throws {
        let project = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(project) }

        let sharedDirectory = project.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)

        let configURL = project.appendingPathComponent("okrun-vm.json")
        let config = VMConfig(
            cpuCount: 6,
            memoryGB: 8,
            diskGB: 64,
            installerISOPath: "/tmp/debian.iso",
            diskFormat: .raw,
            privateNetwork: PrivateNetworkConfig(enabled: true, identifier: "team"),
            sharedDirectories: [
                SharedDirectoryConfig(name: "project", hostPath: sharedDirectory.path, readOnly: false)
            ],
            diskIO: DiskIOConfig(caching: .uncached, synchronization: .fsync)
        )
        try config.save(to: configURL)

        #expect(try VMConfig.load(from: configURL) == config)
    }

    @Test
    func vmConfigRejectsInvalidValues() {
        #expect(throws: (any Error).self) {
            try VMConfig(cpuCount: 0, memoryGB: 4, diskGB: 64, installerISOPath: nil).validated()
        }
        #expect(throws: (any Error).self) {
            try VMConfig(cpuCount: 4, memoryGB: 0, diskGB: 64, installerISOPath: nil).validated()
        }
        #expect(throws: (any Error).self) {
            try VMConfig(cpuCount: 4, memoryGB: 4, diskGB: 0, installerISOPath: nil).validated()
        }
        if #unavailable(macOS 26.0) {
            #expect(throws: (any Error).self) {
                try VMConfig(cpuCount: 4, memoryGB: 4, diskGB: 64, installerISOPath: nil, diskFormat: .asif).validated()
            }
        }
        #expect(throws: (any Error).self) {
            try VMConfig(
                cpuCount: 4,
                memoryGB: 4,
                diskGB: 64,
                installerISOPath: nil,
                privateNetwork: PrivateNetworkConfig(enabled: true, identifier: "")
            ).validated()
        }
        #expect(throws: (any Error).self) {
            try VMConfig(
                cpuCount: 4,
                memoryGB: 4,
                diskGB: 64,
                installerISOPath: nil,
                privateNetwork: PrivateNetworkConfig(enabled: true, identifier: "bad/network")
            ).validated()
        }
    }

    @Test
    func vmConfigRejectsInvalidSharedDirectories() throws {
        let project = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(project) }

        let sharedDirectory = project.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        let fileURL = project.appendingPathComponent("not-a-directory")
        try Data().write(to: fileURL)

        #expect(throws: (any Error).self) {
            try VMConfig(
                cpuCount: 4,
                memoryGB: 4,
                diskGB: 64,
                installerISOPath: nil,
                sharedDirectories: [SharedDirectoryConfig(name: "", hostPath: sharedDirectory.path, readOnly: false)]
            ).validated()
        }
        #expect(throws: (any Error).self) {
            try VMConfig(
                cpuCount: 4,
                memoryGB: 4,
                diskGB: 64,
                installerISOPath: nil,
                sharedDirectories: [
                    SharedDirectoryConfig(name: "shared", hostPath: sharedDirectory.path, readOnly: false),
                    SharedDirectoryConfig(name: "shared", hostPath: sharedDirectory.path, readOnly: true)
                ]
            ).validated()
        }
        #expect(throws: (any Error).self) {
            try VMConfig(
                cpuCount: 4,
                memoryGB: 4,
                diskGB: 64,
                installerISOPath: nil,
                sharedDirectories: [SharedDirectoryConfig(name: "missing", hostPath: project.appendingPathComponent("missing").path, readOnly: false)]
            ).validated()
        }
        #expect(throws: (any Error).self) {
            try VMConfig(
                cpuCount: 4,
                memoryGB: 4,
                diskGB: 64,
                installerISOPath: nil,
                sharedDirectories: [SharedDirectoryConfig(name: "file", hostPath: fileURL.path, readOnly: false)]
            ).validated()
        }

        #expect(try VMConfig(
            cpuCount: 4,
            memoryGB: 4,
            diskGB: 64,
            installerISOPath: nil,
            sharedDirectories: [
                SharedDirectoryConfig(
                    name: ManagedGuestTools.logShareName,
                    hostPath: project.appendingPathComponent("ignored-missing").path,
                    readOnly: true
                )
            ]
        ).validated().sharedDirectories.count == 1)
    }

    @Test
    func directorySharingDeviceFactoryBuildsVirtioFSDevice() throws {
        let project = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(project) }

        let writableDirectory = project.appendingPathComponent("writable", isDirectory: true)
        let readOnlyDirectory = project.appendingPathComponent("readonly", isDirectory: true)
        try FileManager.default.createDirectory(at: writableDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readOnlyDirectory, withIntermediateDirectories: true)

        let devices = try DirectorySharingDeviceFactory.makeDevices(for: [
            SharedDirectoryConfig(name: "writable", hostPath: writableDirectory.path, readOnly: false),
            SharedDirectoryConfig(name: "readonly", hostPath: readOnlyDirectory.path, readOnly: true)
        ])

        #expect(devices.count == 1)
        let device = try #require(devices.first as? VZVirtioFileSystemDeviceConfiguration)
        #expect(device.tag == SharedDirectoryValidator.tag)
        #expect(device.share is VZMultipleDirectoryShare)
    }

    @Test
    func directorySharingDeviceFactoryAddsManagedGuestLogsShare() throws {
        let project = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(project) }

        let managedLogsDirectory = project.appendingPathComponent("vm/guest-logs", isDirectory: true)
        let ignoredDirectory = project.appendingPathComponent("ignored", isDirectory: true)
        try FileManager.default.createDirectory(at: ignoredDirectory, withIntermediateDirectories: true)

        let devices = try DirectorySharingDeviceFactory.makeDevices(
            for: [
                SharedDirectoryConfig(
                    name: ManagedGuestTools.logShareName,
                    hostPath: ignoredDirectory.path,
                    readOnly: true
                )
            ],
            managedGuestLogsDirectory: managedLogsDirectory
        )

        #expect(FileManager.default.fileExists(atPath: managedLogsDirectory.path))
        #expect(devices.count == 1)
        let device = try #require(devices.first as? VZVirtioFileSystemDeviceConfiguration)
        #expect(device.tag == SharedDirectoryValidator.tag)
        #expect(device.share is VZMultipleDirectoryShare)
    }

    @Test
    func networkDeviceFactoryAddsPrivateNetworkAdapterWhenEnabled() throws {
        let natOnlyDevices = try NetworkDeviceFactory.makeDevices(privateNetwork: .disabled)
        #expect(natOnlyDevices.count == 1)
        #expect((natOnlyDevices.first as? VZVirtioNetworkDeviceConfiguration)?.attachment is VZNATNetworkDeviceAttachment)

        let privateDevices = try NetworkDeviceFactory.makeDevices(
            privateNetwork: PrivateNetworkConfig(enabled: true, identifier: "test")
        )
        #expect(privateDevices.count == 2)
        #expect((privateDevices.first as? VZVirtioNetworkDeviceConfiguration)?.attachment is VZNATNetworkDeviceAttachment)
        #expect((privateDevices.last as? VZVirtioNetworkDeviceConfiguration)?.attachment is VZFileHandleNetworkDeviceAttachment)
    }

    @Test
    func projectStoreCreatesAndNormalizesRegistry() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let registryURL = root.appendingPathComponent(".okrun")
        let defaultProject = root.appendingPathComponent("devbox", isDirectory: true)
        let store = ProjectStore(url: registryURL)

        let createdRegistry = try store.load(defaultProject: defaultProject)
        #expect(createdRegistry.projects == [defaultProject.standardizedFileURL.path])
        #expect(createdRegistry.selectedProject == defaultProject.standardizedFileURL.path)

        let duplicateRegistry = ProjectRegistry(
            selectedProject: defaultProject.appendingPathComponent("..").appendingPathComponent("devbox").path,
            projects: [
                defaultProject.path,
                defaultProject.appendingPathComponent("..").appendingPathComponent("devbox").path
            ]
        )
        try store.save(duplicateRegistry)

        let normalizedRegistry = try store.load(defaultProject: nil)
        #expect(normalizedRegistry.projects == [defaultProject.standardizedFileURL.path])
        #expect(normalizedRegistry.selectedProject == defaultProject.standardizedFileURL.path)
    }

    @Test
    func storagePrepareCreatesSparseDiskAndPersistentBootFiles() throws {
        let project = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(project) }

        let paths = VMPaths.project(at: project)
        let config = VMConfig(cpuCount: 2, memoryGB: 2, diskGB: 1, installerISOPath: nil)

        let result = try VMStorage.prepare(paths: paths, config: config)

        #expect(FileManager.default.fileExists(atPath: paths.disk.path))
        #expect(FileManager.default.fileExists(atPath: paths.efiStore.path))
        #expect(FileManager.default.fileExists(atPath: paths.machineIdentifier.path))
        #expect(result.diskChange == .created(size: 1_073_741_824))

        let attributes = try FileManager.default.attributesOfItem(atPath: paths.disk.path)
        #expect(attributes[.size] as? UInt64 == 1_073_741_824)
    }

    @Test
    func storagePrepareCreatesASIFDiskOnSupportedHosts() throws {
        guard #available(macOS 26.0, *) else { return }

        let project = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(project) }

        let paths = VMPaths.project(at: project)
        let config = VMConfig(cpuCount: 2, memoryGB: 2, diskGB: 1, installerISOPath: nil, diskFormat: .asif)

        let result = try VMStorage.prepare(paths: paths, config: config)

        #expect(FileManager.default.fileExists(atPath: paths.asifDisk.path))
        #expect(result.diskChange == .created(size: 1_073_741_824))
        #expect(try DiskImageCreator.virtualSize(url: paths.asifDisk, format: .asif) == 1_073_741_824)

        let expanded = try VMStorage.prepare(
            paths: paths,
            config: VMConfig(cpuCount: 2, memoryGB: 2, diskGB: 2, installerISOPath: nil, diskFormat: .asif)
        )

        #expect(expanded.diskChange == .expanded(from: 1_073_741_824, to: 2_147_483_648))
        #expect(try DiskImageCreator.virtualSize(url: paths.asifDisk, format: .asif) == 2_147_483_648)
    }

    @Test
    func storagePrepareExpandsButDoesNotShrinkExistingDisk() throws {
        let project = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(project) }

        let paths = VMPaths.project(at: project)
        try FileManager.default.createDirectory(at: paths.vmDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.disk.path, contents: nil)

        let handle = try FileHandle(forWritingTo: paths.disk)
        try handle.truncate(atOffset: 1_073_741_824)
        try handle.close()

        let result = try VMStorage.prepare(
            paths: paths,
            config: VMConfig(cpuCount: 2, memoryGB: 2, diskGB: 2, installerISOPath: nil)
        )
        var attributes = try FileManager.default.attributesOfItem(atPath: paths.disk.path)
        #expect(attributes[.size] as? UInt64 == 2_147_483_648)
        #expect(result.diskChange == .expanded(from: 1_073_741_824, to: 2_147_483_648))

        #expect(throws: (any Error).self) {
            try VMStorage.prepare(paths: paths, config: VMConfig(cpuCount: 2, memoryGB: 2, diskGB: 1, installerISOPath: nil))
        }

        attributes = try FileManager.default.attributesOfItem(atPath: paths.disk.path)
        #expect(attributes[.size] as? UInt64 == 2_147_483_648)
    }

    @Test
    func diskImageAttachmentFactoryUsesCachedWritableDiskDefault() throws {
        let project = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(project) }

        let disk = project.appendingPathComponent("disk.raw")
        FileManager.default.createFile(atPath: disk.path, contents: nil)
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: 1_048_576)
        try handle.close()

        let attachment = try DiskImageAttachmentFactory.make(url: disk, readOnly: false)

        #expect(attachment.cachingMode == .cached)
        #expect(attachment.synchronizationMode == .full)
    }

    @Test
    func diskImageAttachmentFactoryAppliesConfiguredDiskIO() throws {
        let project = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(project) }

        let disk = project.appendingPathComponent("disk.raw")
        FileManager.default.createFile(atPath: disk.path, contents: nil)
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: 1_048_576)
        try handle.close()

        let attachment = try DiskImageAttachmentFactory.make(
            url: disk,
            readOnly: false,
            diskIO: DiskIOConfig(caching: .uncached, synchronization: .fsync)
        )

        #expect(attachment.cachingMode == .uncached)
        #expect(attachment.synchronizationMode == .fsync)
    }

    @Test
    func installerBootUsesFreshSeparateEFIVariableStore() throws {
        let project = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(project) }

        let paths = VMPaths.project(at: project)
        try VMStorage.prepare(paths: paths, config: VMConfig(cpuCount: 2, memoryGB: 2, diskGB: 1, installerISOPath: nil))

        try Data("stale installer boot order".utf8).write(to: paths.installerEfiStore)
        _ = try EFIVariableStoreFactory.make(paths: paths, mode: .installer(project.appendingPathComponent("installer.iso")))

        let installerAttributes = try FileManager.default.attributesOfItem(atPath: paths.installerEfiStore.path)
        #expect(installerAttributes[.size] as? UInt64 == 131_072)
        #expect(FileManager.default.fileExists(atPath: paths.efiStore.path))
    }

    @Test
    func installedBootUsesPersistentEFIVariableStore() throws {
        let project = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(project) }

        let paths = VMPaths.project(at: project)
        try VMStorage.prepare(paths: paths, config: VMConfig(cpuCount: 2, memoryGB: 2, diskGB: 1, installerISOPath: nil))

        let before = try FileManager.default.attributesOfItem(atPath: paths.efiStore.path)[.size] as? UInt64
        _ = try EFIVariableStoreFactory.make(paths: paths, mode: .installed)
        let after = try FileManager.default.attributesOfItem(atPath: paths.efiStore.path)[.size] as? UInt64

        #expect(before == after)
        #expect(!FileManager.default.fileExists(atPath: paths.installerEfiStore.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OkrunVMTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func removeTemporaryDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
