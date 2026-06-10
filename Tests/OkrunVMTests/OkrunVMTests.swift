import Darwin
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
        #expect(paths.machineIdentifier == vmDirectory.appendingPathComponent("machine.identifier"))
        #expect(paths.macOSRawDisk == vmDirectory.appendingPathComponent("macos.raw"))
        #expect(paths.macOSASIFDisk == vmDirectory.appendingPathComponent("macos.asif"))
        #expect(paths.macOSAuxiliaryStorage == vmDirectory.appendingPathComponent("macos.auxiliary-storage"))
        #expect(paths.macOSHardwareModel == vmDirectory.appendingPathComponent("macos.hardware-model"))
        #expect(paths.macOSMachineIdentifier == vmDirectory.appendingPathComponent("macos.machine-identifier"))
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
    func vmPathsResolveMacOSDiskNamesSeparatelyFromLinuxDisks() throws {
        let project = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(project) }

        let paths = VMPaths.project(at: project)

        #expect(try paths.diskURL(for: .raw, guestOS: .macOS).lastPathComponent == "macos.raw")
        #expect(try paths.diskURL(for: .asif, guestOS: .macOS).lastPathComponent == "macos.asif")
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
    func vmConfigSavesAndLoadsName() throws {
        let project = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(project) }

        let configURL = project.appendingPathComponent("okrun-vm.json")
        let config = try VMConfig(
            name: "  Dev Box  ",
            cpuCount: 4,
            memoryGB: 4,
            diskGB: 64,
            installerISOPath: nil
        ).validated()
        try config.save(to: configURL)

        let loaded = try VMConfig.load(from: configURL)

        #expect(loaded.name == "Dev Box")
        #expect(loaded.displayName(fallbackProjectPath: project.path) == "Dev Box")
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
        #expect(config.guestOS == .linux)
        #expect(config.installerISOPath == nil)
        #expect(config.name == nil)
        #expect(config.displayName(fallbackProjectPath: project.path) == project.lastPathComponent)
        #expect(config.privateNetwork == .enabled)
        #expect(config.sharedDirectories == [])
        #expect(config.diskIO == .defaults)
        #expect(config.startup == .disabled)

        let migratedData = try Data(contentsOf: configURL)
        let migratedJSON = try #require(JSONSerialization.jsonObject(with: migratedData) as? [String: Any])
        #expect(migratedJSON["guestOS"] as? String == "linux")
        #expect(migratedJSON["diskFormat"] as? String == "raw")
        let privateNetwork = try #require(migratedJSON["privateNetwork"] as? [String: Any])
        #expect(privateNetwork["enabled"] as? Bool == true)
        #expect(privateNetwork["identifier"] == nil)
        let diskIO = try #require(migratedJSON["diskIO"] as? [String: Any])
        #expect(diskIO["caching"] as? String == "cached")
        #expect(diskIO["synchronization"] as? String == "full")
        let startup = try #require(migratedJSON["startup"] as? [String: Any])
        #expect(startup["startOnAppLaunch"] as? Bool == false)
        #expect(startup["mode"] as? String == "installed")
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
            privateNetwork: .enabled,
            sharedDirectories: [
                SharedDirectoryConfig(name: "project", hostPath: sharedDirectory.path, readOnly: false)
            ],
            diskIO: DiskIOConfig(caching: .uncached, synchronization: .fsync)
        )
        try config.save(to: configURL)

        #expect(try VMConfig.load(from: configURL) == config)
    }

#if arch(arm64)
    @Test
    func vmConfigSavesAndLoadsMacOSGuestType() throws {
        let project = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(project) }

        let configURL = project.appendingPathComponent("okrun-vm.json")
        let config = VMConfig(
            cpuCount: 4,
            memoryGB: 8,
            diskGB: 80,
            installerISOPath: "/tmp/macos.ipsw",
            privateNetwork: .enabled,
            guestOS: .macOS
        )

        try config.save(to: configURL)

        #expect(try VMConfig.load(from: configURL) == config)
    }
#endif

    @Test
    func vmConfigSavesAndLoadsStartupConfig() throws {
        let project = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(project) }

        let configURL = project.appendingPathComponent("okrun-vm.json")
        let config = VMConfig(
            cpuCount: 4,
            memoryGB: 4,
            diskGB: 64,
            installerISOPath: "/tmp/debian.iso",
            startup: VMStartupConfig(startOnAppLaunch: true, mode: .installer)
        )

        try config.save(to: configURL)

        #expect(try VMConfig.load(from: configURL) == config)
    }

    @Test
    func vmConfigLoadsPartialStartupConfigWithInstalledMode() throws {
        let project = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(project) }

        let configURL = project.appendingPathComponent("okrun-vm.json")
        try Data("""
        {
          "cpuCount": 2,
          "memoryGB": 3,
          "diskGB": 20,
          "installerISOPath": null,
          "startup": {
            "startOnAppLaunch": true
          }
        }
        """.utf8).write(to: configURL)

        let config = try VMConfig.load(from: configURL)

        #expect(config.startup == VMStartupConfig(startOnAppLaunch: true, mode: .installed))
    }

    @Test
    func vmConfigLoadsLegacyPrivateNetworkIdentifierAsDefaultNetwork() throws {
        let project = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(project) }

        let configURL = project.appendingPathComponent("okrun-vm.json")
        try Data("""
        {
          "cpuCount": 2,
          "memoryGB": 3,
          "diskGB": 20,
          "installerISOPath": null,
          "privateNetwork": {
            "enabled": true,
            "identifier": "team"
          }
        }
        """.utf8).write(to: configURL)

        let config = try VMConfig.load(from: configURL)

        #expect(config.privateNetwork == .enabled)
        let migratedData = try Data(contentsOf: configURL)
        let migratedJSON = try #require(JSONSerialization.jsonObject(with: migratedData) as? [String: Any])
        let privateNetwork = try #require(migratedJSON["privateNetwork"] as? [String: Any])
        #expect(privateNetwork["enabled"] as? Bool == true)
        #expect(privateNetwork["identifier"] == nil)
    }

    @Test
    func asifImporterRoundsVirtualSizeUpToGiB() throws {
        #expect(try ASIFImporter.diskGB(forVirtualSizeBytes: 1_073_741_824) == 1)
        #expect(try ASIFImporter.diskGB(forVirtualSizeBytes: 1_073_741_825) == 2)
        #expect(try ASIFImporter.diskGB(forVirtualSizeBytes: 2_147_483_648) == 2)
        #expect(throws: (any Error).self) {
            try ASIFImporter.diskGB(forVirtualSizeBytes: 0)
        }
    }

    @Test
    func asifImporterGeneratedConfigUsesImportDefaults() throws {
        if #available(macOS 26.0, *) {
            let config = try ASIFImporter.importedConfig(diskGB: 9)

            #expect(config.cpuCount == 4)
            #expect(config.memoryGB == 4)
            #expect(config.diskGB == 9)
            #expect(config.guestOS == .linux)
            #expect(config.diskFormat == .asif)
            #expect(config.diskIO == .defaults)
            #expect(config.installerISOPath == nil)
            #expect(config.privateNetwork == .enabled)
            #expect(config.sharedDirectories == [])
            #expect(config.startup == .disabled)
        }
    }

    @Test
    func asifImporterRejectsNonASIFSource() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let source = root.appendingPathComponent("linux.raw")
        try Data("not-asif".utf8).write(to: source)
        let destination = root.appendingPathComponent("imported", isDirectory: true)

        #expect(throws: (any Error).self) {
            try ASIFImporter.importDisk(
                request: ASIFImportRequest(sourceURL: source, destinationURL: destination),
                virtualSizeProvider: { _ in 1_073_741_824 },
                createMachineIdentifier: { url in try Data("machine".utf8).write(to: url) },
                createEFIVariableStore: { url in try Data("efi".utf8).write(to: url) },
                copyDisk: { source, destination in try FileManager.default.copyItem(at: source, to: destination) }
            )
        }
    }

    @Test
    func asifImporterCreatesStagedProjectAndGeneratedMetadata() throws {
        guard #available(macOS 26.0, *) else { return }

        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let source = root.appendingPathComponent("source.asif")
        try Data("asif fixture".utf8).write(to: source)
        let destination = root.appendingPathComponent("imported-vm", isDirectory: true)
        let config = try ASIFImporter.importedConfig(diskGB: 2, cpuCount: 6, memoryGB: 8)

        let result = try ASIFImporter.importDisk(
            request: ASIFImportRequest(sourceURL: source, destinationURL: destination, config: config),
            virtualSizeProvider: { _ in 1_073_741_825 },
            createMachineIdentifier: { url in try Data("machine".utf8).write(to: url) },
            createEFIVariableStore: { url in try Data("efi".utf8).write(to: url) },
            copyDisk: { source, destination in try FileManager.default.copyItem(at: source, to: destination) }
        )

        let paths = VMPaths.project(at: destination)
        #expect(result.diskGB == 2)
        #expect(result.config.cpuCount == 6)
        #expect(result.config.memoryGB == 8)
        #expect(result.roundedDiskSizeUp)
        #expect(try Data(contentsOf: paths.asifDisk) == Data("asif fixture".utf8))
        #expect(try Data(contentsOf: paths.machineIdentifier) == Data("machine".utf8))
        #expect(try Data(contentsOf: paths.efiStore) == Data("efi".utf8))
        #expect(try VMConfig.load(from: paths.config) == result.config)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test
    func asifImporterCleansStagingDirectoryOnFailure() throws {
        guard #available(macOS 26.0, *) else { return }

        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let source = root.appendingPathComponent("source.asif")
        try Data("asif fixture".utf8).write(to: source)
        let destination = root.appendingPathComponent("failed-import", isDirectory: true)

        #expect(throws: (any Error).self) {
            try ASIFImporter.importDisk(
                request: ASIFImportRequest(sourceURL: source, destinationURL: destination),
                virtualSizeProvider: { _ in 1_073_741_824 },
                createMachineIdentifier: { url in try Data("machine".utf8).write(to: url) },
                createEFIVariableStore: { url in try Data("efi".utf8).write(to: url) },
                copyDisk: { _, _ in throw AppError("copy failed") }
            )
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains(".failed-import.importing-") }
        #expect(leftovers.isEmpty)
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

        let home = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(home) }
        let hostNetworkConfigURL = home.appendingPathComponent("private-networks.json")
        let identifier = "test-\(UUID().uuidString)"
        let privateDevices = try NetworkDeviceFactory.makeDevices(
            privateNetwork: PrivateNetworkConfig(enabled: true, identifier: identifier),
            hostNetworkConfigStore: HostNetworkConfigStore(url: hostNetworkConfigURL)
        )
        #expect(privateDevices.count == 2)
        #expect((privateDevices.first as? VZVirtioNetworkDeviceConfiguration)?.attachment is VZNATNetworkDeviceAttachment)
        #expect((privateDevices.last as? VZVirtioNetworkDeviceConfiguration)?.attachment is VZFileHandleNetworkDeviceAttachment)
        #expect(FileManager.default.fileExists(atPath: hostNetworkConfigURL.path))
        let hostConfig = try HostNetworkConfigStore(url: hostNetworkConfigURL).load()
        #expect(hostConfig.privateNetworks[identifier]?.dhcp?.enabled == true)
    }

    @Test
    func networkPathSnapshotReconnectDecisionIgnoresAvailableInterfaceOnlyChanges() throws {
        let previous = NetworkPathSnapshot(
            status: "satisfied",
            usedInterfaces: ["wired-ethernet"],
            availableInterfaces: ["en11:wired-ethernet"]
        )
        let availableOnly = NetworkPathSnapshot(
            status: "satisfied",
            usedInterfaces: ["wired-ethernet"],
            availableInterfaces: ["en11:wired-ethernet", "vmenet1:other"]
        )
        let usedChanged = NetworkPathSnapshot(
            status: "satisfied",
            usedInterfaces: ["wifi"],
            availableInterfaces: ["en11:wired-ethernet", "en0:wifi"]
        )
        let statusChanged = NetworkPathSnapshot(
            status: "unsatisfied",
            usedInterfaces: [],
            availableInterfaces: ["en11:wired-ethernet"]
        )

        #expect(availableOnly.shouldReconnect(comparedTo: previous) == false)
        #expect(usedChanged.shouldReconnect(comparedTo: previous) == true)
        #expect(statusChanged.shouldReconnect(comparedTo: previous) == true)
    }

    @Test
    func projectStoreMigratesLegacyDefaultRegistryFile() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let legacyURL = root.appendingPathComponent(".okrun")
        let registry = ProjectRegistry(selectedProject: "/tmp/a", projects: ["/tmp/a"])
        let encoder = JSONEncoder()
        try encoder.encode(registry).write(to: legacyURL)

        let store = ProjectStore(url: root.appendingPathComponent(".okrun/registry.json"), legacyURL: legacyURL)
        let loaded = try store.load()

        #expect(loaded == registry)
    }

    @Test
    func hostNetworkConfigStoreValidatesDHCPRanges() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let store = HostNetworkConfigStore(url: root.appendingPathComponent("private-networks.json"))

        let validConfig = HostNetworkConfig(version: 1, privateNetworks: [
            "team-a": HostPrivateNetworkConfig(dhcp: PrivateNetworkDHCPConfig(
                enabled: true,
                mode: .range,
                cidr: "10.77.0.0/24",
                rangeStart: "10.77.0.20",
                rangeEnd: "10.77.0.200",
                leaseSeconds: 3600
            ))
        ])
        try store.save(validConfig)
        #expect(try store.load() == validConfig)

        let invalidConfig = HostNetworkConfig(version: 1, privateNetworks: [
            "team-a": HostPrivateNetworkConfig(dhcp: PrivateNetworkDHCPConfig(
                enabled: true,
                mode: .range,
                cidr: "10.77.0.0/24",
                rangeStart: "10.78.0.20",
                rangeEnd: "10.77.0.200",
                leaseSeconds: 3600
            ))
        ])
        #expect(throws: (any Error).self) {
            try store.save(invalidConfig)
        }
    }

    @Test
    func hostNetworkConfigStoreAutoCreatesDHCPConfig() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let configURL = root.appendingPathComponent("private-networks.json")
        let store = HostNetworkConfigStore(url: configURL)

        let defaultDHCP = try #require(try store.dhcpConfigForPrivateNetwork(identifier: "okrun"))
        #expect(defaultDHCP.enabled)
        #expect(defaultDHCP.cidr == "10.77.0.0/24")
        #expect(defaultDHCP.rangeStart == "10.77.0.20")
        #expect(defaultDHCP.rangeEnd == "10.77.0.200")
        #expect(FileManager.default.fileExists(atPath: configURL.path))

        let teamDHCP = try #require(try store.dhcpConfigForPrivateNetwork(identifier: "team-a"))
        #expect(teamDHCP.enabled)
        #expect(teamDHCP.cidr != defaultDHCP.cidr)

        let persisted = try store.load()
        #expect(persisted.privateNetworks["okrun"]?.dhcp == defaultDHCP)
        #expect(persisted.privateNetworks["team-a"]?.dhcp == teamDHCP)
    }

    @Test
    func hostNetworkConfigStoreRespectsDisabledDHCPConfig() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let store = HostNetworkConfigStore(url: root.appendingPathComponent("private-networks.json"))
        let disabledDHCP = PrivateNetworkDHCPConfig(
            enabled: false,
            mode: .range,
            cidr: "10.77.0.0/24",
            rangeStart: "10.77.0.20",
            rangeEnd: "10.77.0.200",
            leaseSeconds: 3600
        )
        try store.save(HostNetworkConfig(version: 1, privateNetworks: [
            "okrun": HostPrivateNetworkConfig(dhcp: disabledDHCP)
        ]))

        #expect(try store.dhcpConfigForPrivateNetwork(identifier: "okrun") == nil)
        #expect(try store.load().privateNetworks["okrun"]?.dhcp == disabledDHCP)
    }

    @Test
    func dhcpLeaseAllocatorReusesIdentityAndExhaustsRange() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let config = PrivateNetworkDHCPConfig(
            enabled: true,
            mode: .range,
            cidr: "10.77.0.0/24",
            rangeStart: "10.77.0.20",
            rangeEnd: "10.77.0.21",
            leaseSeconds: 3600
        )
        let store = DHCPLeaseStore(stateDirectory: root)
        let allocator = try DHCPLeaseAllocator(config: config, store: store)

        let first = try allocator.lease(for: "client-a", requestedIP: try IPv4Address("10.77.0.21"))
        let renewed = try allocator.lease(for: "client-a", requestedIP: nil)
        let second = try allocator.lease(for: "client-b", requestedIP: nil)
        let expectedFirstAddress = try IPv4Address("10.77.0.21")
        let expectedSecondAddress = try IPv4Address("10.77.0.20")

        #expect(first.ipAddress == expectedFirstAddress)
        #expect(renewed.ipAddress == first.ipAddress)
        #expect(second.ipAddress == expectedSecondAddress)
        #expect(throws: (any Error).self) {
            _ = try allocator.lease(for: "client-c", requestedIP: nil)
        }
    }

    @Test
    func dhcpLeaseAllocatorDropsLeasesOutsideCurrentRange() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let config = PrivateNetworkDHCPConfig(
            enabled: true,
            mode: .range,
            cidr: "10.77.0.0/24",
            rangeStart: "10.77.0.110",
            rangeEnd: "10.77.0.200",
            leaseSeconds: 3600
        )
        let store = DHCPLeaseStore(stateDirectory: root)
        try store.save([
            DHCPLease(
                identity: "client-a",
                ipAddress: try IPv4Address("10.77.0.20"),
                expiresAt: Date().addingTimeInterval(3600)
            )
        ])
        let allocator = try DHCPLeaseAllocator(config: config, store: store)

        let lease = try allocator.lease(for: "client-a", requestedIP: nil)

        let expectedAddress = try IPv4Address("10.77.0.110")
        #expect(lease.ipAddress == expectedAddress)
        #expect(try store.load().map(\.ipAddress) == [expectedAddress])
    }

    @Test
    func dhcpLeaseAllocatorCoordinatesAcrossInstances() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let config = PrivateNetworkDHCPConfig(
            enabled: true,
            mode: .range,
            cidr: "10.77.0.0/24",
            rangeStart: "10.77.0.20",
            rangeEnd: "10.77.0.21",
            leaseSeconds: 3600
        )
        let store = DHCPLeaseStore(stateDirectory: root)
        let firstAllocator = try DHCPLeaseAllocator(config: config, store: store)
        let secondAllocator = try DHCPLeaseAllocator(config: config, store: store)

        let first = try firstAllocator.lease(for: "client-a", requestedIP: nil)
        let second = try secondAllocator.lease(for: "client-b", requestedIP: nil)
        let expectedFirst = try IPv4Address("10.77.0.20")
        let expectedSecond = try IPv4Address("10.77.0.21")
        let persistedAddresses = try store.load().map(\.ipAddress).sorted()

        #expect(first.ipAddress == expectedFirst)
        #expect(second.ipAddress == expectedSecond)
        #expect(persistedAddresses == [expectedFirst, expectedSecond])
    }

    @Test
    func dhcpLeaseAllocatorCoordinatesConcurrentInstances() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let config = PrivateNetworkDHCPConfig(
            enabled: true,
            mode: .range,
            cidr: "10.77.0.0/24",
            rangeStart: "10.77.0.20",
            rangeEnd: "10.77.0.80",
            leaseSeconds: 3600
        )
        let store = DHCPLeaseStore(stateDirectory: root)
        let allocationCount = 32
        var leases = Array<DHCPLease?>(repeating: nil, count: allocationCount)
        var failures: [any Error] = []
        let resultLock = NSLock()

        DispatchQueue.concurrentPerform(iterations: allocationCount) { index in
            do {
                let allocator = try DHCPLeaseAllocator(config: config, store: store)
                let lease = try allocator.lease(for: "client-\(index)", requestedIP: nil)
                resultLock.lock()
                leases[index] = lease
                resultLock.unlock()
            } catch {
                resultLock.lock()
                failures.append(error)
                resultLock.unlock()
            }
        }

        if let failure = failures.first {
            throw failure
        }

        let addresses = leases.compactMap { $0?.ipAddress }
        #expect(addresses.count == allocationCount)
        #expect(Set(addresses).count == allocationCount)
        #expect(try store.load().count == allocationCount)
    }

    @Test
    func dhcpLeaseAllocatorRejectsConflictsAndReservesDeclines() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let config = PrivateNetworkDHCPConfig(
            enabled: true,
            mode: .range,
            cidr: "10.77.0.0/24",
            rangeStart: "10.77.0.20",
            rangeEnd: "10.77.0.21",
            leaseSeconds: 3600
        )
        let allocator = try DHCPLeaseAllocator(config: config, store: DHCPLeaseStore(stateDirectory: root))
        let declinedAddress = try IPv4Address("10.77.0.20")

        _ = try allocator.requestedLease(for: "client-a", requestedIP: declinedAddress)
        #expect(throws: (any Error).self) {
            _ = try allocator.requestedLease(for: "client-b", requestedIP: declinedAddress)
        }

        try allocator.decline(identity: "client-a", address: declinedAddress)
        let replacement = try allocator.lease(for: "client-b", requestedIP: nil)
        let expectedReplacement = try IPv4Address("10.77.0.21")

        #expect(replacement.ipAddress == expectedReplacement)
    }

    @Test
    func dhcpLeaseAllocatorReservesHostSSHAddressInsideRange() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let config = PrivateNetworkDHCPConfig(
            enabled: true,
            mode: .range,
            cidr: "10.77.0.0/24",
            rangeStart: "10.77.0.20",
            rangeEnd: "10.77.0.22",
            leaseSeconds: 3600
        )
        let store = DHCPLeaseStore(stateDirectory: root)
        let allocator = try DHCPLeaseAllocator(config: config, store: store)
        let identity = HostNetworkConfigStore.hostSSHReservationIdentity(identifier: "okrun")

        let reservation = try allocator.reserve(for: identity, requestedIP: nil)
        let firstClient = try allocator.lease(for: "client-a", requestedIP: nil)
        let reservedAddress = try IPv4Address("10.77.0.20")
        let firstClientAddress = try IPv4Address("10.77.0.21")

        #expect(reservation.identity == identity)
        #expect(reservation.ipAddress == reservedAddress)
        #expect(firstClient.ipAddress == firstClientAddress)
        #expect(throws: (any Error).self) {
            _ = try allocator.requestedLease(for: "client-b", requestedIP: reservedAddress)
        }

        let movedHostAddress = try IPv4Address("10.77.0.22")
        let movedReservation = try allocator.reserve(for: identity, requestedIP: movedHostAddress)
        #expect(movedReservation.ipAddress == movedHostAddress)
        #expect(try store.load().contains { $0.identity == identity && $0.ipAddress == movedReservation.ipAddress })
    }

    @Test
    func dhcpLeaseIdentityUsesHardwareAddressForClonedGuests() throws {
        let sharedClientIdentifier = Data([1, 2, 3, 4])
        let first = DHCPMessage(
            messageType: .discover,
            transactionID: 1,
            flags: 0x8000,
            clientHardwareAddress: EthernetAddress([0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0x01]),
            clientIPAddress: IPv4Address(value: 0),
            yourIPAddress: IPv4Address(value: 0),
            requestedIPAddress: nil,
            serverIdentifier: nil,
            clientIdentifier: sharedClientIdentifier,
            options: []
        )
        let second = DHCPMessage(
            messageType: .discover,
            transactionID: 2,
            flags: 0x8000,
            clientHardwareAddress: EthernetAddress([0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0x02]),
            clientIPAddress: IPv4Address(value: 0),
            yourIPAddress: IPv4Address(value: 0),
            requestedIPAddress: nil,
            serverIdentifier: nil,
            clientIdentifier: sharedClientIdentifier,
            options: []
        )

        #expect(first.identity == "mac:02:aa:bb:cc:dd:01")
        #expect(second.identity == "mac:02:aa:bb:cc:dd:02")
        #expect(first.identity != second.identity)
    }

    @Test
    func dhcpPacketParserAndEncoderRoundTrip() throws {
        let clientMAC = EthernetAddress([0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee])
        let clientIdentifier = Data([1, 2, 3, 4])
        let discover = DHCPMessage(
            messageType: .discover,
            transactionID: 0x1234_5678,
            flags: 0x8000,
            clientHardwareAddress: clientMAC,
            clientIPAddress: IPv4Address(value: 0),
            yourIPAddress: IPv4Address(value: 0),
            requestedIPAddress: nil,
            serverIdentifier: nil,
            clientIdentifier: clientIdentifier,
            options: [
                .messageType(.discover),
                .clientIdentifier(clientIdentifier)
            ]
        ).ethernetFrame(
            sourceMAC: clientMAC,
            destinationMAC: .broadcast,
            sourceIP: IPv4Address(value: 0),
            destinationIP: IPv4Address(value: 0xffff_ffff),
            sourcePort: 68,
            destinationPort: 67,
            bootpOperation: 1
        )

        let parsed = try #require(DHCPMessage.parse(fromEthernetFrame: discover))
        #expect(parsed.messageType == .discover)
        #expect(parsed.transactionID == 0x1234_5678)
        #expect(parsed.clientHardwareAddress == clientMAC)
        #expect(parsed.clientIdentifier == clientIdentifier)

        let requestedAddress = try IPv4Address("10.77.0.20")
        let serverAddress = try IPv4Address("10.77.0.1")
        let request = DHCPMessage(
            messageType: .request,
            transactionID: 0x1234_5679,
            flags: 0x8000,
            clientHardwareAddress: clientMAC,
            clientIPAddress: IPv4Address(value: 0),
            yourIPAddress: IPv4Address(value: 0),
            requestedIPAddress: requestedAddress,
            serverIdentifier: serverAddress,
            clientIdentifier: clientIdentifier,
            options: [
                .messageType(.request),
                .requestedIPAddress(requestedAddress),
                .serverIdentifier(serverAddress),
                .clientIdentifier(clientIdentifier)
            ]
        ).ethernetFrame(
            sourceMAC: clientMAC,
            destinationMAC: .broadcast,
            sourceIP: IPv4Address(value: 0),
            destinationIP: IPv4Address(value: 0xffff_ffff),
            sourcePort: 68,
            destinationPort: 67,
            bootpOperation: 1
        )

        let parsedRequest = try #require(DHCPMessage.parse(fromEthernetFrame: request))
        #expect(parsedRequest.messageType == .request)
        #expect(parsedRequest.requestedIPAddress == requestedAddress)
        #expect(parsedRequest.serverIdentifier == serverAddress)
        #expect(parsedRequest.clientIdentifier == clientIdentifier)

        let offer = DHCPMessage(
            messageType: .offer,
            transactionID: parsed.transactionID,
            flags: parsed.flags,
            clientHardwareAddress: parsed.clientHardwareAddress,
            clientIPAddress: IPv4Address(value: 0),
            yourIPAddress: try IPv4Address("10.77.0.20"),
            requestedIPAddress: nil,
            serverIdentifier: try IPv4Address("10.77.0.1"),
            clientIdentifier: parsed.clientIdentifier,
            options: [
                .messageType(.offer),
                .serverIdentifier(try IPv4Address("10.77.0.1")),
                .subnetMask(try IPv4Address("255.255.255.0")),
                .broadcastAddress(try IPv4Address("10.77.0.255")),
                .leaseTime(3600),
                .renewalTime(1800),
                .rebindingTime(3150)
            ]
        ).ethernetFrame(
            sourceMAC: EthernetAddress([0x02, 0x6f, 0x6b, 0x72, 0x75, 0x6e]),
            destinationMAC: .broadcast,
            sourceIP: try IPv4Address("10.77.0.1"),
            destinationIP: IPv4Address(value: 0xffff_ffff)
        )

        #expect(offer.count > discover.count - 32)
        #expect(offer[12] == 0x08)
        #expect(offer[13] == 0x00)
        #expect(dhcpIPv4ChecksumIsValid(offer))
        #expect(dhcpUDPChecksumIsValid(offer))
        let optionCodes = dhcpOptionCodes(in: offer)
        #expect(optionCodes.contains(1))
        #expect(optionCodes.contains(28))
        #expect(optionCodes.contains(51))
        #expect(optionCodes.contains(54))
        #expect(optionCodes.contains(58))
        #expect(optionCodes.contains(59))
        #expect(!optionCodes.contains(3))
        #expect(!optionCodes.contains(6))
    }

    @Test
    func projectStoreCreatesEmptyRegistry() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let registryURL = root.appendingPathComponent(".okrun")
        let store = ProjectStore(url: registryURL)

        let createdRegistry = try store.load()
        #expect(createdRegistry.projects.isEmpty)
        #expect(createdRegistry.selectedProject == nil)
    }

    @Test
    func projectStoreNormalizesDuplicatePaths() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let registryURL = root.appendingPathComponent(".okrun")
        let defaultProject = root.appendingPathComponent("devbox", isDirectory: true)
        let store = ProjectStore(url: registryURL)

        // Load to create the file, then save duplicates
        _ = try store.load()

        let duplicateRegistry = ProjectRegistry(
            selectedProject: defaultProject.appendingPathComponent("..").appendingPathComponent("devbox").path,
            projects: [
                defaultProject.path,
                defaultProject.appendingPathComponent("..").appendingPathComponent("devbox").path
            ]
        )
        try store.save(duplicateRegistry)

        let normalizedRegistry = try store.load()
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

#if arch(arm64)
    @Test
    func storagePrepareMacOSRequiresInstallerBeforeMetadataExists() throws {
        let project = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(project) }

        let paths = VMPaths.project(at: project)
        let config = VMConfig(
            cpuCount: 4,
            memoryGB: 8,
            diskGB: 1,
            installerISOPath: nil,
            guestOS: .macOS
        )

        #expect(throws: (any Error).self) {
            try VMStorage.prepare(paths: paths, config: config)
        }
        #expect(FileManager.default.fileExists(atPath: paths.macOSRawDisk.path))
        #expect(!FileManager.default.fileExists(atPath: paths.macOSAuxiliaryStorage.path))
    }
#endif

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

    private func dhcpIPv4ChecksumIsValid(_ frame: Data) -> Bool {
        let bytes = [UInt8](frame)
        let ipOffset = 14
        guard bytes.count >= ipOffset + 20 else { return false }
        let headerLength = Int(bytes[ipOffset] & 0x0f) * 4
        guard headerLength >= 20, bytes.count >= ipOffset + headerLength else { return false }
        return dhcpInternetChecksum(Array(bytes[ipOffset..<(ipOffset + headerLength)])) == 0
    }

    private func dhcpUDPChecksumIsValid(_ frame: Data) -> Bool {
        let bytes = [UInt8](frame)
        let ipOffset = 14
        guard bytes.count >= ipOffset + 20 else { return false }
        let headerLength = Int(bytes[ipOffset] & 0x0f) * 4
        let udpOffset = ipOffset + headerLength
        guard bytes.count >= udpOffset + 8 else { return false }
        let udpLength = Int(dhcpReadUInt16(bytes, udpOffset + 4))
        guard udpLength >= 8, bytes.count >= udpOffset + udpLength else { return false }

        var checksumBytes = [UInt8]()
        checksumBytes.append(contentsOf: bytes[(ipOffset + 12)..<(ipOffset + 20)])
        checksumBytes.append(0)
        checksumBytes.append(17)
        checksumBytes.append(UInt8((udpLength >> 8) & 0xff))
        checksumBytes.append(UInt8(udpLength & 0xff))
        checksumBytes.append(contentsOf: bytes[udpOffset..<(udpOffset + udpLength)])
        return dhcpInternetChecksum(checksumBytes) == 0
    }

    private func dhcpOptionCodes(in frame: Data) -> [UInt8] {
        let bytes = [UInt8](frame)
        let ipOffset = 14
        guard bytes.count >= ipOffset + 20 else { return [] }
        let headerLength = Int(bytes[ipOffset] & 0x0f) * 4
        let optionStart = ipOffset + headerLength + 8 + 240
        guard bytes.count > optionStart else { return [] }

        var codes: [UInt8] = []
        var offset = optionStart
        while offset < bytes.count {
            let code = bytes[offset]
            offset += 1
            if code == 255 { break }
            if code == 0 { continue }
            guard offset < bytes.count else { break }
            let length = Int(bytes[offset])
            offset += 1
            guard offset + length <= bytes.count else { break }
            codes.append(code)
            offset += length
        }
        return codes
    }

    private func dhcpInternetChecksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(dhcpReadUInt16(bytes, index))
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

    private func dhcpReadUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private func ethernetFrame(destination: [UInt8], source: [UInt8], payload: [UInt8]) -> Data {
        var frame = Data()
        frame.append(contentsOf: destination.prefix(6))
        frame.append(contentsOf: source.prefix(6))
        frame.append(contentsOf: [0x08, 0x00])
        frame.append(contentsOf: payload)
        return frame
    }

    private func waitForFrame(on descriptor: Int32, timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = readFrame(on: descriptor) {
                return frame
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        throw AppError("Timed out waiting for private network frame.")
    }

    @Test
    func switchFrameProtocolRoundTripsAndHandlesPartialReads() throws {
        let frame = SwitchFrame(
            streamID: SwitchFrame.ethernetStreamID,
            type: .data,
            sequenceNumber: 42,
            payload: Data([0xaa, 0xbb, 0xcc])
        )
        let encoded = try SwitchFrameProtocol.encode(frame)
        let decoder = SwitchFrameDecoder(maxPayloadLength: 16)

        #expect(try decoder.push(Data(encoded.prefix(5))).isEmpty)
        #expect(try decoder.push(Data(encoded.dropFirst(5))) == [frame])

        let secondFrame = SwitchFrame(
            streamID: SwitchFrame.ethernetStreamID,
            type: .data,
            sequenceNumber: 43,
            payload: Data([0xdd])
        )
        #expect(try decoder.push(try SwitchFrameProtocol.encode(secondFrame)) == [secondFrame])
    }

    @Test
    func switchFrameDecoderRejectsOversizedPayloads() throws {
        let encoded = try SwitchFrameProtocol.encode(SwitchFrame(
            streamID: SwitchFrame.ethernetStreamID,
            type: .data,
            sequenceNumber: 1,
            payload: Data(repeating: 0x01, count: 11)
        ))
        let decoder = SwitchFrameDecoder(maxPayloadLength: 10)

        #expect(throws: (any Error).self) {
            try decoder.push(encoded)
        }
    }

    @Test
    func switchDedupWindowDropsDuplicatesAndOldFrames() {
        let window = SwitchDedupWindow()

        #expect(window.accept(10))
        #expect(!window.accept(10))
        #expect(window.accept(12))
        #expect(window.accept(11))
        #expect(window.accept(140))
        #expect(!window.accept(11))

        window.reset()
        #expect(window.accept(1))
    }

    @Test
    func pendingSwitchWriteBufferDropsFullAndExpiredFrames() {
        let now = Date(timeIntervalSince1970: 100)
        let buffer = PendingSwitchWriteBuffer(limit: 2, maxAge: 10)

        #expect(buffer.append(Data([0x01]), at: now))
        #expect(buffer.append(Data([0x02]), at: now))
        #expect(!buffer.append(Data([0x03]), at: now))

        var result = buffer.flush(at: now.addingTimeInterval(5))
        #expect(result.writes == [Data([0x01]), Data([0x02])])
        #expect(result.dropped == 0)

        #expect(buffer.append(Data([0x04]), at: now))
        #expect(buffer.append(Data([0x05]), at: now.addingTimeInterval(9)))
        result = buffer.flush(at: now.addingTimeInterval(11))
        #expect(result.writes == [Data([0x05])])
        #expect(result.dropped == 1)
    }

    @Test
    func switchServerErrorRetryPolicySlowsRecoverableRejections() {
        #expect(SwitchServerErrorRetryPolicy.policy(for: "certificate_revoked") == .delayed(60))
        #expect(SwitchServerErrorRetryPolicy.policy(for: "same_node_different_certificate") == .delayed(60))
        #expect(SwitchServerErrorRetryPolicy.policy(for: "too_many_connections") == .delayed(60))
        #expect(SwitchServerErrorRetryPolicy.policy(for: "dhcp_range_overlap") == .delayed(60))
        #expect(SwitchServerErrorRetryPolicy.policy(for: nil) == .delayed(60))
        #expect(SwitchServerErrorRetryPolicy.policy(for: "invalid_init") == .none)
        #expect(SwitchServerErrorRetryPolicy.policy(for: "frame_too_large") == .none)
    }

    @Test
    func privateNetworkRouterSendsKnownRemoteFramesToWebSwitch() throws {
        let router = PrivateNetworkTransportRouter(identifier: "router-\(UUID().uuidString)")
        let webSwitch = MockRoutableTransport()
        router.setWebSwitch(webSwitch)

        let localMAC: [UInt8] = [0x02, 0xaa, 0xaa, 0xaa, 0xaa, 0x01]
        let remoteMAC: [UInt8] = [0x02, 0xcc, 0xcc, 0xcc, 0xcc, 0x01]
        let remoteFrame = ethernetFrame(destination: localMAC, source: remoteMAC, payload: [0x02])

        router.receiveRemoteFrame(remoteFrame, via: .webSwitch)

        let reply = ethernetFrame(destination: remoteMAC, source: localMAC, payload: [0x03])
        router.routeLocalFrame(reply)

        #expect(webSwitch.sentFrames == [reply])
    }

    @Test
    func privateNetworkRouterInjectsWebSwitchFramesIntoLocalRuntimes() throws {
        let router = PrivateNetworkTransportRouter(identifier: "router-\(UUID().uuidString)")
        let runtime = try PrivateNetworkRuntime(identifier: "router-runtime-\(UUID().uuidString)")
        router.addRuntime(runtime)

        let localMAC: [UInt8] = [0x02, 0xaa, 0xaa, 0xaa, 0xaa, 0x10]
        let remoteMAC: [UInt8] = [0x02, 0xbb, 0xbb, 0xbb, 0xbb, 0x10]
        let switchFrame = ethernetFrame(destination: localMAC, source: remoteMAC, payload: [0x02])

        router.receiveRemoteFrame(switchFrame, via: .webSwitch)

        #expect(try waitForFrame(on: runtime.fileHandle.fileDescriptor, timeout: 1) == switchFrame)
        withExtendedLifetime((router, runtime)) {}
    }

    @Test
    func privateNetworkRouterInjectsLocalSwitchFramesIntoLocalRuntimes() throws {
        let router = PrivateNetworkTransportRouter(identifier: "router-\(UUID().uuidString)")
        let runtime = try PrivateNetworkRuntime(identifier: "router-runtime-\(UUID().uuidString)")
        router.addRuntime(runtime)

        let localMAC: [UInt8] = [0x02, 0xaa, 0xaa, 0xaa, 0xaa, 0x11]
        let remoteMAC: [UInt8] = [0x02, 0xbb, 0xbb, 0xbb, 0xbb, 0x11]
        let switchFrame = ethernetFrame(destination: localMAC, source: remoteMAC, payload: [0x02])

        router.receiveRemoteFrame(switchFrame, via: .localSwitch)

        #expect(try waitForFrame(on: runtime.fileHandle.fileDescriptor, timeout: 1) == switchFrame)
        withExtendedLifetime((router, runtime)) {}
    }

    @Test
    func privateNetworkRouterSendsDiscoveryFramesToWebSwitch() throws {
        let router = PrivateNetworkTransportRouter(identifier: "router-\(UUID().uuidString)")
        let webSwitch = MockRoutableTransport()
        router.setWebSwitch(webSwitch)

        let frame = ethernetFrame(
            destination: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
            source: [0x02, 0xdd, 0xdd, 0xdd, 0xdd, 0x01],
            payload: [0x05]
        )

        router.routeLocalFrame(frame)

        #expect(webSwitch.sentFrames == [frame])
    }

    @Test
    func privateNetworkRouterSendsDiscoveryFramesToWebAndLocalSwitchesWhenBothAreAvailable() throws {
        let router = PrivateNetworkTransportRouter(identifier: "router-\(UUID().uuidString)")
        let localSwitch = MockRoutableTransport()
        let webSwitch = MockRoutableTransport()
        router.setLocalSwitch(localSwitch)
        router.setWebSwitch(webSwitch)

        let frame = ethernetFrame(
            destination: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
            source: [0x02, 0xdd, 0xdd, 0xdd, 0xdd, 0x03],
            payload: [0x07]
        )

        router.routeLocalFrame(frame)

        #expect(localSwitch.sentFrames == [frame])
        #expect(webSwitch.sentFrames == [frame])
    }

    @Test
    func privateNetworkRouterFallsBackToWebSwitchWhenLocalSwitchIsUnavailable() throws {
        let router = PrivateNetworkTransportRouter(identifier: "router-\(UUID().uuidString)")
        let localSwitch = MockRoutableTransport()
        let webSwitch = MockRoutableTransport()
        localSwitch.canSendPrivateNetworkFrames = false
        router.setLocalSwitch(localSwitch)
        router.setWebSwitch(webSwitch)

        let frame = ethernetFrame(
            destination: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
            source: [0x02, 0xdd, 0xdd, 0xdd, 0xdd, 0x04],
            payload: [0x08]
        )

        router.routeLocalFrame(frame)

        #expect(localSwitch.sentFrames.isEmpty)
        #expect(webSwitch.sentFrames == [frame])
    }

    @Test
    func privateNetworkRouterProbesLocalSwitchWhenItReturns() throws {
        let router = PrivateNetworkTransportRouter(identifier: "router-\(UUID().uuidString)")
        let localSwitch = MockRoutableTransport()
        let webSwitch = MockRoutableTransport()
        localSwitch.canSendPrivateNetworkFrames = false
        router.setLocalSwitch(localSwitch)
        router.setWebSwitch(webSwitch)

        let whileLocalDown = ethernetFrame(
            destination: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
            source: [0x02, 0xdd, 0xdd, 0xdd, 0xdd, 0x05],
            payload: [0x09]
        )
        router.routeLocalFrame(whileLocalDown)

        localSwitch.canSendPrivateNetworkFrames = true
        let afterLocalReturn = ethernetFrame(
            destination: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
            source: [0x02, 0xdd, 0xdd, 0xdd, 0xdd, 0x06],
            payload: [0x0a]
        )
        router.routeLocalFrame(afterLocalReturn)

        #expect(webSwitch.sentFrames == [whileLocalDown, afterLocalReturn])
        #expect(localSwitch.sentFrames == [afterLocalReturn])
    }

    @Test
    func privateNetworkRouterKeepsWebLearnedRemoteFramesOnWebSwitch() throws {
        let router = PrivateNetworkTransportRouter(identifier: "router-\(UUID().uuidString)")
        let localSwitch = MockRoutableTransport()
        let webSwitch = MockRoutableTransport()
        router.setLocalSwitch(localSwitch)
        router.setWebSwitch(webSwitch)

        let localMAC: [UInt8] = [0x02, 0xaa, 0xaa, 0xaa, 0xaa, 0x20]
        let remoteMAC: [UInt8] = [0x02, 0xcc, 0xcc, 0xcc, 0xcc, 0x20]
        let remoteFrame = ethernetFrame(destination: localMAC, source: remoteMAC, payload: [0x02])
        router.receiveRemoteFrame(remoteFrame, via: .webSwitch)

        let reply = ethernetFrame(destination: remoteMAC, source: localMAC, payload: [0x03])
        router.routeLocalFrame(reply)

        #expect(localSwitch.sentFrames.isEmpty)
        #expect(webSwitch.sentFrames == [reply])
    }

    @Test
    func privateNetworkRouterFallsBackToLocalSwitchForWebLearnedRemoteWhenWebIsUnavailable() throws {
        let router = PrivateNetworkTransportRouter(identifier: "router-\(UUID().uuidString)")
        let localSwitch = MockRoutableTransport()
        let webSwitch = MockRoutableTransport()
        router.setLocalSwitch(localSwitch)
        router.setWebSwitch(webSwitch)

        let localMAC: [UInt8] = [0x02, 0xaa, 0xaa, 0xaa, 0xaa, 0x24]
        let remoteMAC: [UInt8] = [0x02, 0xcc, 0xcc, 0xcc, 0xcc, 0x24]
        let remoteFrame = ethernetFrame(destination: localMAC, source: remoteMAC, payload: [0x02])
        router.receiveRemoteFrame(remoteFrame, via: .webSwitch)

        webSwitch.canSendPrivateNetworkFrames = false
        let reply = ethernetFrame(destination: remoteMAC, source: localMAC, payload: [0x03])
        router.routeLocalFrame(reply)

        #expect(localSwitch.sentFrames == [reply])
        #expect(webSwitch.sentFrames.isEmpty)
    }

    @Test
    func privateNetworkRouterUsesLocalSwitchForLocalLearnedRemoteFrames() throws {
        let router = PrivateNetworkTransportRouter(identifier: "router-\(UUID().uuidString)")
        let localSwitch = MockRoutableTransport()
        let webSwitch = MockRoutableTransport()
        router.setLocalSwitch(localSwitch)
        router.setWebSwitch(webSwitch)

        let localMAC: [UInt8] = [0x02, 0xaa, 0xaa, 0xaa, 0xaa, 0x21]
        let remoteMAC: [UInt8] = [0x02, 0xcc, 0xcc, 0xcc, 0xcc, 0x21]
        let remoteFrame = ethernetFrame(destination: localMAC, source: remoteMAC, payload: [0x02])
        router.receiveRemoteFrame(remoteFrame, via: .localSwitch)

        let reply = ethernetFrame(destination: remoteMAC, source: localMAC, payload: [0x03])
        router.routeLocalFrame(reply)

        #expect(localSwitch.sentFrames == [reply])
        #expect(webSwitch.sentFrames.isEmpty)
    }

    @Test
    func privateNetworkRouterDeduplicatesSameRemoteFrameAcrossSwitches() throws {
        let router = PrivateNetworkTransportRouter(identifier: "router-\(UUID().uuidString)")
        let runtime = try PrivateNetworkRuntime(identifier: "router-runtime-\(UUID().uuidString)")
        router.addRuntime(runtime)

        let localMAC: [UInt8] = [0x02, 0xaa, 0xaa, 0xaa, 0xaa, 0x30]
        let remoteMAC: [UInt8] = [0x02, 0xbb, 0xbb, 0xbb, 0xbb, 0x30]
        let frame = ethernetFrame(destination: localMAC, source: remoteMAC, payload: [0x02])

        router.receiveRemoteFrame(frame, via: .webSwitch)
        router.receiveRemoteFrame(frame, via: .localSwitch)

        #expect(try waitForFrame(on: runtime.fileHandle.fileDescriptor, timeout: 1) == frame)
        #expect(readFrame(on: runtime.fileHandle.fileDescriptor) == nil)
        withExtendedLifetime((router, runtime)) {}
    }

    @Test
    func privateNetworkRouterAllowsSameRemoteFrameTwiceOnSameSwitch() throws {
        let router = PrivateNetworkTransportRouter(identifier: "router-\(UUID().uuidString)")
        let runtime = try PrivateNetworkRuntime(identifier: "router-runtime-\(UUID().uuidString)")
        router.addRuntime(runtime)

        let localMAC: [UInt8] = [0x02, 0xaa, 0xaa, 0xaa, 0xaa, 0x31]
        let remoteMAC: [UInt8] = [0x02, 0xbb, 0xbb, 0xbb, 0xbb, 0x31]
        let frame = ethernetFrame(destination: localMAC, source: remoteMAC, payload: [0x02])

        router.receiveRemoteFrame(frame, via: .webSwitch)
        router.receiveRemoteFrame(frame, via: .webSwitch)

        #expect(try waitForFrame(on: runtime.fileHandle.fileDescriptor, timeout: 1) == frame)
        #expect(try waitForFrame(on: runtime.fileHandle.fileDescriptor, timeout: 1) == frame)
        withExtendedLifetime((router, runtime)) {}
    }

    @Test
    func privateNetworkRouterPrefersLocalSwitchAfterSameRemoteIsLearnedLocally() throws {
        let router = PrivateNetworkTransportRouter(identifier: "router-\(UUID().uuidString)")
        let localSwitch = MockRoutableTransport()
        let webSwitch = MockRoutableTransport()
        router.setLocalSwitch(localSwitch)
        router.setWebSwitch(webSwitch)

        let localMAC: [UInt8] = [0x02, 0xaa, 0xaa, 0xaa, 0xaa, 0x23]
        let remoteMAC: [UInt8] = [0x02, 0xcc, 0xcc, 0xcc, 0xcc, 0x23]
        let webFrame = ethernetFrame(destination: localMAC, source: remoteMAC, payload: [0x02])
        let localFrame = ethernetFrame(destination: localMAC, source: remoteMAC, payload: [0x04])
        router.receiveRemoteFrame(webFrame, via: .webSwitch)
        router.receiveRemoteFrame(localFrame, via: .localSwitch)

        let reply = ethernetFrame(destination: remoteMAC, source: localMAC, payload: [0x03])
        router.routeLocalFrame(reply)

        #expect(localSwitch.sentFrames == [reply])
        #expect(webSwitch.sentFrames.isEmpty)
    }

    @Test
    func privateNetworkRouterFallsBackToWebSwitchForLocalLearnedRemoteWhenLocalIsUnavailable() throws {
        let router = PrivateNetworkTransportRouter(identifier: "router-\(UUID().uuidString)")
        let localSwitch = MockRoutableTransport()
        let webSwitch = MockRoutableTransport()
        router.setLocalSwitch(localSwitch)
        router.setWebSwitch(webSwitch)

        let localMAC: [UInt8] = [0x02, 0xaa, 0xaa, 0xaa, 0xaa, 0x22]
        let remoteMAC: [UInt8] = [0x02, 0xcc, 0xcc, 0xcc, 0xcc, 0x22]
        let remoteFrame = ethernetFrame(destination: localMAC, source: remoteMAC, payload: [0x02])
        router.receiveRemoteFrame(remoteFrame, via: .localSwitch)

        localSwitch.canSendPrivateNetworkFrames = false
        let reply = ethernetFrame(destination: remoteMAC, source: localMAC, payload: [0x03])
        router.routeLocalFrame(reply)

        #expect(localSwitch.sentFrames.isEmpty)
        #expect(webSwitch.sentFrames == [reply])
    }

    @Test
    func privateNetworkRouterSkipsUnreachableWebSwitch() throws {
        let router = PrivateNetworkTransportRouter(identifier: "router-\(UUID().uuidString)")
        let webSwitch = MockRoutableTransport()
        router.setWebSwitch(webSwitch)
        webSwitch.canSendPrivateNetworkFrames = false

        let frame = ethernetFrame(
            destination: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
            source: [0x02, 0xdd, 0xdd, 0xdd, 0xdd, 0x02],
            payload: [0x06]
        )

        router.routeLocalFrame(frame)

        #expect(webSwitch.sentFrames.isEmpty)
    }

    @Test
    func privateNetworkRouterDoesNotDeadlockWhenSwitchCallbackRacesWithLocalSend() throws {
        let router = PrivateNetworkTransportRouter(identifier: "router-\(UUID().uuidString)")
        let webSwitch = BlockingRoutableTransport()
        router.setWebSwitch(webSwitch)

        let localMAC: [UInt8] = [0x02, 0xee, 0xee, 0xee, 0xee, 0x01]
        let remoteMAC: [UInt8] = [0x02, 0xee, 0xee, 0xee, 0xee, 0x02]
        let otherRemoteMAC: [UInt8] = [0x02, 0xee, 0xee, 0xee, 0xee, 0x03]
        let learnedRemoteFrame = ethernetFrame(destination: localMAC, source: remoteMAC, payload: [0x01])
        router.receiveRemoteFrame(learnedRemoteFrame, via: .webSwitch)

        let switchQueueEntered = DispatchSemaphore(value: 0)
        let releaseSwitchCallback = DispatchSemaphore(value: 0)
        let callbackFinished = DispatchSemaphore(value: 0)
        webSwitch.runOnTransportQueue {
            switchQueueEntered.signal()
            _ = releaseSwitchCallback.wait(timeout: .now() + 2)
            router.receiveRemoteFrame(
                ethernetFrame(destination: localMAC, source: otherRemoteMAC, payload: [0x02]),
                via: .webSwitch
            )
            callbackFinished.signal()
        }
        #expect(switchQueueEntered.wait(timeout: .now() + 1) == .success)

        let toRemote = ethernetFrame(destination: remoteMAC, source: localMAC, payload: [0x03])
        let routeFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            router.routeLocalFrame(toRemote)
            routeFinished.signal()
        }

        #expect(webSwitch.canSendAttempted.wait(timeout: .now() + 1) == .success)
        releaseSwitchCallback.signal()
        #expect(callbackFinished.wait(timeout: .now() + 2) == .success)
        #expect(routeFinished.wait(timeout: .now() + 2) == .success)
        #expect(webSwitch.sentFrames == [toRemote])
    }

    @Test
    func privateNetworkRouterExpiresLocalMacs() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 200))
        let router = PrivateNetworkTransportRouter(
            identifier: "router-\(UUID().uuidString)",
            macTtl: 1,
            now: { clock.now }
        )
        let webSwitch = MockRoutableTransport()
        router.setWebSwitch(webSwitch)

        let firstLocalMAC: [UInt8] = [0x02, 0xfa, 0xfa, 0xfa, 0xfa, 0x01]
        let secondLocalMAC: [UInt8] = [0x02, 0xfa, 0xfa, 0xfa, 0xfa, 0x02]
        let thirdLocalMAC: [UInt8] = [0x02, 0xfa, 0xfa, 0xfa, 0xfa, 0x03]
        let discovery = ethernetFrame(
            destination: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
            source: firstLocalMAC,
            payload: [0x01]
        )
        router.routeLocalFrame(discovery)
        #expect(webSwitch.sentFrames == [discovery])
        webSwitch.sentFrames.removeAll()

        let stillLocal = ethernetFrame(destination: firstLocalMAC, source: secondLocalMAC, payload: [0x02])
        router.routeLocalFrame(stillLocal)
        #expect(webSwitch.sentFrames.isEmpty)

        clock.advance(by: 2)
        let expiredLocal = ethernetFrame(destination: firstLocalMAC, source: thirdLocalMAC, payload: [0x03])
        router.routeLocalFrame(expiredLocal)
        #expect(webSwitch.sentFrames == [expiredLocal])
    }

    @Test
    func privateNetworkRouterDeliversRemoteFramesToLocalEndpointsAndRoutesReplies() throws {
        let router = PrivateNetworkTransportRouter(identifier: "router-\(UUID().uuidString)")
        let webSwitch = MockRoutableTransport()
        router.setWebSwitch(webSwitch)

        let endpointMAC = EthernetAddress([0x02, 0x48, 0x6f, 0x73, 0x74, 0x01])
        let endpoint = MockLocalEndpoint(macAddress: endpointMAC)
        let remoteMAC: [UInt8] = [0x02, 0xcc, 0xcc, 0xcc, 0xcc, 0x40]
        router.addLocalEndpoint(endpoint)

        let remoteFrame = ethernetFrame(destination: endpointMAC.bytes, source: remoteMAC, payload: [0x02])
        router.receiveRemoteFrame(remoteFrame, via: .webSwitch)

        #expect(endpoint.receivedFrames == [remoteFrame])

        let reply = ethernetFrame(destination: remoteMAC, source: endpointMAC.bytes, payload: [0x03])
        router.routeLocalEndpointFrame(reply)

        #expect(webSwitch.sentFrames == [reply])
    }

    @Test
    func hostSSHServiceAnswersARPAndProxiesTCPToLoopback() throws {
        let greeting = Data("SSH-2.0-okrun-test\r\n".utf8)
        let server = try LoopbackTCPServer(greeting: greeting)
        defer { server.stop() }

        let collector = FrameCollector()
        let config = PrivateNetworkHostSSHConfig(
            enabled: true,
            ipAddress: "10.77.0.2",
            targetPort: server.port,
            allowedPorts: [22]
        )
        let service = try PrivateNetworkHostSSHService(identifier: "host-ssh-test", config: config) { frame in
            collector.append(frame)
        }
        defer { service.stop() }

        let hostIP = try IPv4Address("10.77.0.2")
        let clientIP = try IPv4Address("10.77.0.20")
        let clientMAC: [UInt8] = [0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0x40]
        let hostMAC = service.privateNetworkMACAddress.bytes

        service.receivePrivateNetworkFrame(arpRequest(
            sourceMAC: clientMAC,
            sourceIP: clientIP,
            targetIP: hostIP
        ))
        let arpReply = try collector.waitForFrame(timeout: 1) { frameEtherType($0) == 0x0806 }
        #expect(Array([UInt8](arpReply)[0..<6]) == clientMAC)
        #expect(Array([UInt8](arpReply)[6..<12]) == hostMAC)
        #expect(dhcpReadUInt16([UInt8](arpReply), 20) == 2)

        let clientPort: UInt16 = 40_123
        let clientInitialSequence: UInt32 = 1_000
        service.receivePrivateNetworkFrame(tcpFrame(
            sourceMAC: clientMAC,
            destinationMAC: hostMAC,
            sourceIP: clientIP,
            destinationIP: hostIP,
            sourcePort: clientPort,
            destinationPort: 22,
            sequenceNumber: clientInitialSequence,
            acknowledgementNumber: 0,
            flags: 0x02,
            payload: Data()
        ))

        let synAck = try collector.waitForFrame(timeout: 1) { tcpFlags($0) == 0x12 }
        let hostInitialSequence = try tcpSequenceNumber(synAck)
        #expect(try tcpAcknowledgementNumber(synAck) == clientInitialSequence + 1)

        service.receivePrivateNetworkFrame(tcpFrame(
            sourceMAC: clientMAC,
            destinationMAC: hostMAC,
            sourceIP: clientIP,
            destinationIP: hostIP,
            sourcePort: clientPort,
            destinationPort: 22,
            sequenceNumber: clientInitialSequence + 1,
            acknowledgementNumber: hostInitialSequence + 1,
            flags: 0x10,
            payload: Data()
        ))

        let bannerFrame = try collector.waitForFrame(timeout: 2) { frame in
            (try? tcpPayload(frame)) == greeting
        }
        #expect(try tcpSequenceNumber(bannerFrame) == hostInitialSequence + 1)
        #expect(try tcpPayload(bannerFrame) == greeting)

        let clientPayload = Data("hello from vm\n".utf8)
        service.receivePrivateNetworkFrame(tcpFrame(
            sourceMAC: clientMAC,
            destinationMAC: hostMAC,
            sourceIP: clientIP,
            destinationIP: hostIP,
            sourcePort: clientPort,
            destinationPort: 22,
            sequenceNumber: clientInitialSequence + 1,
            acknowledgementNumber: hostInitialSequence + 1 + UInt32(greeting.count),
            flags: 0x18,
            payload: clientPayload
        ))

        #expect(try server.waitForReceived(clientPayload, timeout: 2))
    }

    @Test
    func hostSSHServiceProxiesWhitelistedHostPorts() throws {
        let greeting = Data("HTTP/1.1 200 OK\r\n\r\n".utf8)
        let server = try LoopbackTCPServer(greeting: greeting)
        defer { server.stop() }

        let collector = FrameCollector()
        let config = PrivateNetworkHostSSHConfig(
            enabled: true,
            ipAddress: "10.77.0.2",
            allowedPorts: [22, server.port]
        )
        let service = try PrivateNetworkHostSSHService(identifier: "host-port-test", config: config) { frame in
            collector.append(frame)
        }
        defer { service.stop() }

        let hostIP = try IPv4Address("10.77.0.2")
        let clientIP = try IPv4Address("10.77.0.20")
        let clientMAC: [UInt8] = [0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0x41]
        let hostMAC = service.privateNetworkMACAddress.bytes
        let clientPort: UInt16 = 40_124
        let clientInitialSequence: UInt32 = 2_000

        service.receivePrivateNetworkFrame(tcpFrame(
            sourceMAC: clientMAC,
            destinationMAC: hostMAC,
            sourceIP: clientIP,
            destinationIP: hostIP,
            sourcePort: clientPort,
            destinationPort: server.port,
            sequenceNumber: clientInitialSequence,
            acknowledgementNumber: 0,
            flags: 0x02,
            payload: Data()
        ))

        let synAck = try collector.waitForFrame(timeout: 1) { tcpFlags($0) == 0x12 }
        let hostInitialSequence = try tcpSequenceNumber(synAck)
        #expect(try tcpAcknowledgementNumber(synAck) == clientInitialSequence + 1)

        service.receivePrivateNetworkFrame(tcpFrame(
            sourceMAC: clientMAC,
            destinationMAC: hostMAC,
            sourceIP: clientIP,
            destinationIP: hostIP,
            sourcePort: clientPort,
            destinationPort: server.port,
            sequenceNumber: clientInitialSequence + 1,
            acknowledgementNumber: hostInitialSequence + 1,
            flags: 0x10,
            payload: Data()
        ))

        let responseFrame = try collector.waitForFrame(timeout: 2) { frame in
            (try? tcpPayload(frame)) == greeting
        }
        #expect(try tcpPayload(responseFrame) == greeting)

        let clientPayload = Data("GET / HTTP/1.1\r\n\r\n".utf8)
        service.receivePrivateNetworkFrame(tcpFrame(
            sourceMAC: clientMAC,
            destinationMAC: hostMAC,
            sourceIP: clientIP,
            destinationIP: hostIP,
            sourcePort: clientPort,
            destinationPort: server.port,
            sequenceNumber: clientInitialSequence + 1,
            acknowledgementNumber: hostInitialSequence + 1 + UInt32(greeting.count),
            flags: 0x18,
            payload: clientPayload
        ))

        #expect(try server.waitForReceived(clientPayload, timeout: 2))
    }

    @Test
    func hostSSHServiceFallsBackToIPv6LoopbackForWhitelistedPorts() throws {
        let greeting = Data("HTTP/1.1 200 OK\r\n\r\nipv6".utf8)
        let server = try LoopbackTCPServer(greeting: greeting, usesIPv6Loopback: true)
        defer { server.stop() }

        let collector = FrameCollector()
        let config = PrivateNetworkHostSSHConfig(
            enabled: true,
            ipAddress: "10.77.0.2",
            allowedPorts: [server.port]
        )
        let service = try PrivateNetworkHostSSHService(identifier: "host-port-ipv6-test", config: config) { frame in
            collector.append(frame)
        }
        defer { service.stop() }

        let hostIP = try IPv4Address("10.77.0.2")
        let clientIP = try IPv4Address("10.77.0.20")
        let clientMAC: [UInt8] = [0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0x42]
        let hostMAC = service.privateNetworkMACAddress.bytes
        let clientPort: UInt16 = 40_125
        let clientInitialSequence: UInt32 = 3_000

        service.receivePrivateNetworkFrame(tcpFrame(
            sourceMAC: clientMAC,
            destinationMAC: hostMAC,
            sourceIP: clientIP,
            destinationIP: hostIP,
            sourcePort: clientPort,
            destinationPort: server.port,
            sequenceNumber: clientInitialSequence,
            acknowledgementNumber: 0,
            flags: 0x02,
            payload: Data()
        ))

        let synAck = try collector.waitForFrame(timeout: 1) { tcpFlags($0) == 0x12 }
        let hostInitialSequence = try tcpSequenceNumber(synAck)

        service.receivePrivateNetworkFrame(tcpFrame(
            sourceMAC: clientMAC,
            destinationMAC: hostMAC,
            sourceIP: clientIP,
            destinationIP: hostIP,
            sourcePort: clientPort,
            destinationPort: server.port,
            sequenceNumber: clientInitialSequence + 1,
            acknowledgementNumber: hostInitialSequence + 1,
            flags: 0x10,
            payload: Data()
        ))

        let responseFrame = try collector.waitForFrame(timeout: 2) { frame in
            (try? tcpPayload(frame)) == greeting
        }
        #expect(try tcpPayload(responseFrame) == greeting)
    }

    @Test
    func hostSSHServiceAnswersMDNSHostnameQueries() throws {
        let collector = FrameCollector()
        let config = PrivateNetworkHostSSHConfig(
            enabled: true,
            ipAddress: "10.77.0.20",
            hostname: "Test Mac.local"
        )
        let service = try PrivateNetworkHostSSHService(identifier: "host-ssh-mdns-test", config: config) { frame in
            collector.append(frame)
        }
        defer { service.stop() }

        let hostIP = try IPv4Address("10.77.0.20")
        let clientIP = try IPv4Address("10.77.0.21")
        let clientMAC: [UInt8] = [0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0x41]
        let multicastMAC: [UInt8] = [0x01, 0x00, 0x5e, 0x00, 0x00, 0xfb]

        service.receivePrivateNetworkFrame(udpFrame(
            sourceMAC: clientMAC,
            destinationMAC: multicastMAC,
            sourceIP: clientIP,
            destinationIP: try IPv4Address("224.0.0.251"),
            sourcePort: 5353,
            destinationPort: 5353,
            payload: mdnsQuery(name: "test-mac.local", qtype: 1)
        ))

        let response = try collector.waitForFrame(timeout: 1) { frame in
            (try? mdnsAnswerAddress(frame, name: "test-mac.local")) == hostIP
        }
        let responseBytes = [UInt8](response)
        #expect(Array(responseBytes[0..<6]) == multicastMAC)
        #expect(Array(responseBytes[6..<12]) == service.privateNetworkMACAddress.bytes)
        #expect(try udpDestinationPort(response) == 5353)
        #expect(try mdnsAnswerAddress(response, name: "test-mac.local") == hostIP)
    }

    @Test
    func privateNetworkRuntimeRegistryStartsStoredHostMDNSBeforeAnyRuntime() throws {
        let registry = PrivateNetworkRuntimeRegistry()
        defer { registry.releaseAll() }

        let identifier = "stored-host-mdns-\(UUID().uuidString)"
        let hostIP = try IPv4Address("10.77.0.20")
        let hostSSHConfig = try PrivateNetworkHostSSHConfig(
            enabled: true,
            ipAddress: hostIP.description,
            hostname: "Test Mac.local"
        ).validated(dhcp: nil)

        let statuses = try registry.configureStoredHostService(StoredPrivateNetworkHostServiceConfig(
            identifier: identifier,
            hostSSHConfig: hostSSHConfig,
            localSwitchConfig: nil,
            switchConfig: nil,
            dhcpRange: nil
        ))

        #expect(registry.hasHostSSHService(identifier: identifier))
        #expect(registry.hasRuntime(identifier: identifier) == false)
        #expect(statuses.localSwitchStatus == .disabled(identifier: identifier))
        #expect(statuses.switchStatus == .disabled(identifier: identifier))

        let runtime = try PrivateNetworkRuntime(identifier: identifier)
        try registry.retain(runtime, hostSSHConfig: hostSSHConfig)
        #expect(registry.hasRuntime(identifier: identifier))

        let clientIP = try IPv4Address("10.77.0.21")
        let clientMAC: [UInt8] = [0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0x42]
        let multicastMAC: [UInt8] = [0x01, 0x00, 0x5e, 0x00, 0x00, 0xfb]
        runtime.fileHandle.write(udpFrame(
            sourceMAC: clientMAC,
            destinationMAC: multicastMAC,
            sourceIP: clientIP,
            destinationIP: try IPv4Address("224.0.0.251"),
            sourcePort: 5353,
            destinationPort: 5353,
            payload: mdnsQuery(name: "test-mac.local", qtype: 1)
        ))

        let response = try waitForFrame(on: runtime.fileHandle.fileDescriptor, timeout: 1)
        #expect(try mdnsAnswerAddress(response, name: "test-mac.local") == hostIP)
        withExtendedLifetime((registry, runtime)) {}
    }

    @Test
    func hostNetworkConfigLoadsAndValidatesHostSSHConfig() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let store = HostNetworkConfigStore(url: root.appendingPathComponent("private-networks.json"))
        let dhcp = PrivateNetworkDHCPConfig(
            enabled: true,
            mode: .range,
            cidr: "10.77.0.0/24",
            rangeStart: "10.77.0.20",
            rangeEnd: "10.77.0.200",
            leaseSeconds: 3600
        )
        let hostSSH = try PrivateNetworkHostSSHConfig(
            enabled: true,
            ipAddress: "10.77.0.20",
            allowedPorts: [8080, 22, 8080],
            hostname: "Test Mac.local"
        ).validated(dhcp: dhcp)
        try store.save(HostNetworkConfig(version: 1, privateNetworks: [
            "okrun": HostPrivateNetworkConfig(dhcp: dhcp, hostSSH: hostSSH)
        ]))

        #expect(try store.hostSSHConfigForPrivateNetwork(identifier: "okrun") == hostSSH)
        #expect(hostSSH.hostname == "test-mac")
        #expect(hostSSH.allowedPorts == [22, 8080])
        #expect(hostSSH.targetPort(forHostPort: 8080) == 8080)
        #expect(hostSSH.targetPort(forHostPort: 443) == nil)
        #expect(try PrivateNetworkHostSSHConfig.parseAllowedPorts("3000, 8080\n22") == [22, 3000, 8080])
        #expect(try PrivateNetworkHostSSHConfig.parseAllowedPorts("") == [])
        #expect(PrivateNetworkHostSSHConfig.formatAllowedPorts(hostSSH.allowedPorts) == "22, 8080")
        #expect(try PrivateNetworkHostSSHConfig(enabled: true, ipAddress: "10.77.0.20").validated(dhcp: dhcp).allowedPorts == [])
        let legacyHostSSH = try JSONDecoder().decode(
            PrivateNetworkHostSSHConfig.self,
            from: Data("""
            {"enabled":true,"ipAddress":"10.77.0.20","listenPort":2222,"targetPort":22,"hostname":"legacy"}
            """.utf8)
        )
        #expect(legacyHostSSH.allowedPorts == [2222])
        #expect(try PrivateNetworkHostSSHConfig.defaultIPAddress(dhcp: dhcp) == "10.77.0.20")
        #expect(throws: (any Error).self) {
            _ = try PrivateNetworkHostSSHConfig(enabled: true, ipAddress: "10.77.0.2").validated(dhcp: dhcp)
        }
        #expect(throws: (any Error).self) {
            _ = try PrivateNetworkHostSSHConfig(enabled: true, ipAddress: "10.77.0.20", allowedPorts: [0]).validated(dhcp: dhcp)
        }
        #expect(throws: (any Error).self) {
            _ = try PrivateNetworkHostSSHConfig.parseAllowedPorts("22, nope")
        }
    }

    @Test
    func hostNetworkConfigAutoPicksAndReservesHostSSHAddress() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let store = HostNetworkConfigStore(url: root.appendingPathComponent("private-networks.json"))
        let dhcp = PrivateNetworkDHCPConfig(
            enabled: true,
            mode: .range,
            cidr: "10.77.0.0/24",
            rangeStart: "10.77.0.20",
            rangeEnd: "10.77.0.22",
            leaseSeconds: 3600
        )
        let leaseStore = DHCPLeaseStore(stateDirectory: store.home.privateNetworkStateDirectory(identifier: "okrun"))
        try leaseStore.save([
            DHCPLease(
                identity: "client-a",
                ipAddress: try IPv4Address("10.77.0.20"),
                expiresAt: Date().addingTimeInterval(3600)
            )
        ])

        var privateNetwork = HostPrivateNetworkConfig(
            dhcp: dhcp,
            hostSSH: PrivateNetworkHostSSHConfig(enabled: true, ipAddress: "")
        )
        try store.prepareHostSSHConfigForPrivateNetwork(identifier: "okrun", privateNetwork: &privateNetwork)
        try store.save(HostNetworkConfig(version: 1, privateNetworks: ["okrun": privateNetwork]))

        let reservedHostIP = try IPv4Address("10.77.0.21")
        let loadedHostSSH = try #require(try store.hostSSHConfigForPrivateNetwork(identifier: "okrun"))
        #expect(privateNetwork.hostSSH?.ipAddress == reservedHostIP.description)
        #expect(loadedHostSSH.ipAddress == reservedHostIP.description)

        let allocator = try DHCPLeaseAllocator(config: dhcp, store: leaseStore)
        let nextGuestLease = try allocator.lease(for: "client-b", requestedIP: nil)
        let expectedGuestIP = try IPv4Address("10.77.0.22")
        #expect(nextGuestLease.ipAddress == expectedGuestIP)
    }

    @Test
    func hostNetworkConfigBuildsStoredHostServiceConfigs() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let store = HostNetworkConfigStore(url: root.appendingPathComponent("private-networks.json"))
        let dhcp = PrivateNetworkDHCPConfig(
            enabled: true,
            mode: .range,
            cidr: "10.77.0.0/24",
            rangeStart: "10.77.0.20",
            rangeEnd: "10.77.0.22",
            leaseSeconds: 3600
        )
        let switchConfig = PrivateNetworkSwitchConfig(
            enabled: true,
            server: "localhost:9443",
            caCert: "/tmp/ca-cert.pem",
            clientCert: "/tmp/client-cert.pem",
            clientKey: "/tmp/client-key.pem",
            credentialFingerprint: "bundle-a"
        )
        let localSwitchConfig = PrivateNetworkLocalSwitchConfig(
            enabled: true,
            server: "127.0.0.1:9444"
        )
        try store.save(HostNetworkConfig(version: 1, privateNetworks: [
            "okrun": HostPrivateNetworkConfig(
                dhcp: dhcp,
                switch: switchConfig,
                localSwitch: localSwitchConfig,
                hostSSH: PrivateNetworkHostSSHConfig(
                    enabled: true,
                    ipAddress: "",
                    allowedPorts: [22, 8080],
                    hostname: "Test Mac.local"
                )
            ),
            "switch-only": HostPrivateNetworkConfig(
                dhcp: nil,
                switch: switchConfig,
                localSwitch: localSwitchConfig,
                hostSSH: nil
            )
        ]))

        let services = try store.storedHostServiceConfigs()
        let service = try #require(services.first)
        let expectedDHCPRange = try PrivateNetworkDHCPLeaseRange(config: dhcp)

        #expect(services.count == 1)
        #expect(service.identifier == "okrun")
        #expect(service.hostSSHConfig.ipAddress == "10.77.0.20")
        #expect(service.hostSSHConfig.hostname == "test-mac")
        #expect(service.hostSSHConfig.allowedPorts == [22, 8080])
        #expect(service.localSwitchConfig == localSwitchConfig)
        #expect(service.switchConfig == switchConfig)
        #expect(service.dhcpRange == expectedDHCPRange)
        #expect(try store.load().privateNetworks["okrun"]?.hostSSH?.ipAddress == "10.77.0.20")
    }

    @Test
    func hostNetworkConfigMigratesLegacyOutOfRangeHostSSHAddress() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let configURL = root.appendingPathComponent("private-networks.json")
        let store = HostNetworkConfigStore(url: configURL)
        let dhcp = PrivateNetworkDHCPConfig(
            enabled: true,
            mode: .range,
            cidr: "10.77.0.0/24",
            rangeStart: "10.77.0.20",
            rangeEnd: "10.77.0.22",
            leaseSeconds: 3600
        )
        let legacyConfig = HostNetworkConfig(version: 1, privateNetworks: [
            "okrun": HostPrivateNetworkConfig(
                dhcp: dhcp,
                hostSSH: PrivateNetworkHostSSHConfig(enabled: true, ipAddress: "10.77.0.2")
            )
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(legacyConfig).write(to: configURL, options: .atomic)

        let migratedHostSSH = try #require(try store.hostSSHConfigForPrivateNetwork(identifier: "okrun"))
        let savedMigratedHostSSH = try #require(try store.load().privateNetworks["okrun"]?.hostSSH)
        #expect(migratedHostSSH.ipAddress == "10.77.0.20")
        #expect(savedMigratedHostSSH.ipAddress == "10.77.0.20")
    }

    @Test
    func hostNetworkConfigLoadsAndValidatesSwitchConfig() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let store = HostNetworkConfigStore(url: root.appendingPathComponent("private-networks.json"))
        let switchConfig = PrivateNetworkSwitchConfig(
            enabled: true,
            server: "localhost:9443",
            caCert: "/tmp/ca-cert.pem",
            clientCert: "/tmp/client-cert.pem",
            clientKey: "/tmp/client-key.pem",
            credentialFingerprint: "bundle-a"
        )
        let localSwitchConfig = PrivateNetworkLocalSwitchConfig(
            enabled: true,
            server: "127.0.0.1:9444"
        )
        try store.save(HostNetworkConfig(version: 1, privateNetworks: [
            "okrun": HostPrivateNetworkConfig(dhcp: nil, switch: switchConfig, localSwitch: localSwitchConfig)
        ]))

        #expect(try store.switchConfigForPrivateNetwork(identifier: "okrun") == switchConfig)
        #expect(try store.localSwitchConfigForPrivateNetwork(identifier: "okrun") == localSwitchConfig)
        #expect(try store.load().privateNetworks["okrun"]?.switch == switchConfig)
        #expect(try store.load().privateNetworks["okrun"]?.localSwitch == localSwitchConfig)

        let changedCredentials = PrivateNetworkSwitchConfig(
            enabled: true,
            server: "localhost:9443",
            caCert: "/tmp/ca-cert.pem",
            clientCert: "/tmp/client-cert.pem",
            clientKey: "/tmp/client-key.pem",
            credentialFingerprint: "bundle-b"
        )
        #expect(changedCredentials != switchConfig)

        let legacyJSON = """
        {
          "enabled": true,
          "server": "localhost:9443",
          "caCert": "/tmp/ca-cert.pem",
          "clientCert": "/tmp/client-cert.pem",
          "clientKey": "/tmp/client-key.pem",
          "multipath": true
        }
        """
        let legacySwitchConfig = try JSONDecoder().decode(PrivateNetworkSwitchConfig.self, from: Data(legacyJSON.utf8))
        #expect(legacySwitchConfig.credentialFingerprint == "")
    }

    @Test
    func localSwitchConfigRejectsWildcardBindAddressAsServer() throws {
        #expect(throws: (any Error).self) {
            try PrivateNetworkLocalSwitchConfig(
                enabled: true,
                server: "0.0.0.0:9444"
            ).validated()
        }
    }

    private func arpRequest(sourceMAC: [UInt8], sourceIP: IPv4Address, targetIP: IPv4Address) -> Data {
        var frame = Data()
        frame.append(contentsOf: EthernetAddress.broadcast.bytes)
        frame.append(contentsOf: sourceMAC.prefix(6))
        frame.append(contentsOf: [0x08, 0x06])
        appendTestUInt16(1, to: &frame)
        appendTestUInt16(0x0800, to: &frame)
        frame.append(6)
        frame.append(4)
        appendTestUInt16(1, to: &frame)
        frame.append(contentsOf: sourceMAC.prefix(6))
        appendTestUInt32(sourceIP.value, to: &frame)
        frame.append(contentsOf: [0, 0, 0, 0, 0, 0])
        appendTestUInt32(targetIP.value, to: &frame)
        return frame
    }

    private func tcpFrame(
        sourceMAC: [UInt8],
        destinationMAC: [UInt8],
        sourceIP: IPv4Address,
        destinationIP: IPv4Address,
        sourcePort: UInt16,
        destinationPort: UInt16,
        sequenceNumber: UInt32,
        acknowledgementNumber: UInt32,
        flags: UInt8,
        payload: Data
    ) -> Data {
        var tcp = Data()
        appendTestUInt16(sourcePort, to: &tcp)
        appendTestUInt16(destinationPort, to: &tcp)
        appendTestUInt32(sequenceNumber, to: &tcp)
        appendTestUInt32(acknowledgementNumber, to: &tcp)
        tcp.append(0x50)
        tcp.append(flags)
        appendTestUInt16(65_535, to: &tcp)
        appendTestUInt16(0, to: &tcp)
        appendTestUInt16(0, to: &tcp)
        tcp.append(payload)

        var ip = Data()
        ip.append(0x45)
        ip.append(0)
        appendTestUInt16(UInt16(20 + tcp.count), to: &ip)
        appendTestUInt16(0, to: &ip)
        appendTestUInt16(0x4000, to: &ip)
        ip.append(64)
        ip.append(6)
        appendTestUInt16(0, to: &ip)
        appendTestUInt32(sourceIP.value, to: &ip)
        appendTestUInt32(destinationIP.value, to: &ip)

        var frame = Data()
        frame.append(contentsOf: destinationMAC.prefix(6))
        frame.append(contentsOf: sourceMAC.prefix(6))
        frame.append(contentsOf: [0x08, 0x00])
        frame.append(ip)
        frame.append(tcp)
        return frame
    }

    private func udpFrame(
        sourceMAC: [UInt8],
        destinationMAC: [UInt8],
        sourceIP: IPv4Address,
        destinationIP: IPv4Address,
        sourcePort: UInt16,
        destinationPort: UInt16,
        payload: Data
    ) -> Data {
        var udp = Data()
        appendTestUInt16(sourcePort, to: &udp)
        appendTestUInt16(destinationPort, to: &udp)
        appendTestUInt16(UInt16(8 + payload.count), to: &udp)
        appendTestUInt16(0, to: &udp)
        udp.append(payload)

        var ip = Data()
        ip.append(0x45)
        ip.append(0)
        appendTestUInt16(UInt16(20 + udp.count), to: &ip)
        appendTestUInt16(0, to: &ip)
        appendTestUInt16(0x4000, to: &ip)
        ip.append(255)
        ip.append(17)
        appendTestUInt16(0, to: &ip)
        appendTestUInt32(sourceIP.value, to: &ip)
        appendTestUInt32(destinationIP.value, to: &ip)

        var frame = Data()
        frame.append(contentsOf: destinationMAC.prefix(6))
        frame.append(contentsOf: sourceMAC.prefix(6))
        frame.append(contentsOf: [0x08, 0x00])
        frame.append(ip)
        frame.append(udp)
        return frame
    }

    private func mdnsQuery(name: String, qtype: UInt16, unicast: Bool = false) -> Data {
        var payload = Data()
        appendTestUInt16(0, to: &payload)
        appendTestUInt16(0, to: &payload)
        appendTestUInt16(1, to: &payload)
        appendTestUInt16(0, to: &payload)
        appendTestUInt16(0, to: &payload)
        appendTestUInt16(0, to: &payload)
        appendDNSName(name, to: &payload)
        appendTestUInt16(qtype, to: &payload)
        appendTestUInt16(unicast ? 0x8001 : 1, to: &payload)
        return payload
    }

    private func appendDNSName(_ name: String, to data: inout Data) {
        for label in name.split(separator: ".", omittingEmptySubsequences: true) {
            let bytes = Array(label.utf8.prefix(63))
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        data.append(0)
    }

    private func frameEtherType(_ frame: Data) -> UInt16? {
        let bytes = [UInt8](frame)
        guard bytes.count >= 14 else { return nil }
        return dhcpReadUInt16(bytes, 12)
    }

    private func tcpFlags(_ frame: Data) -> UInt8? {
        let bytes = [UInt8](frame)
        guard let tcpOffset = tcpHeaderOffset(bytes), bytes.count > tcpOffset + 13 else { return nil }
        return bytes[tcpOffset + 13]
    }

    private func tcpSequenceNumber(_ frame: Data) throws -> UInt32 {
        let bytes = [UInt8](frame)
        let offset = try #require(tcpHeaderOffset(bytes))
        return testReadUInt32(bytes, offset + 4)
    }

    private func tcpAcknowledgementNumber(_ frame: Data) throws -> UInt32 {
        let bytes = [UInt8](frame)
        let offset = try #require(tcpHeaderOffset(bytes))
        return testReadUInt32(bytes, offset + 8)
    }

    private func tcpPayload(_ frame: Data) throws -> Data {
        let bytes = [UInt8](frame)
        let ipOffset = 14
        let tcpOffset = try #require(tcpHeaderOffset(bytes))
        let ipLength = Int(dhcpReadUInt16(bytes, ipOffset + 2))
        let dataOffset = Int(bytes[tcpOffset + 12] >> 4) * 4
        let payloadStart = tcpOffset + dataOffset
        let payloadEnd = ipOffset + ipLength
        guard payloadEnd >= payloadStart, bytes.count >= payloadEnd else { return Data() }
        return Data(bytes[payloadStart..<payloadEnd])
    }

    private func udpDestinationPort(_ frame: Data) throws -> UInt16 {
        let bytes = [UInt8](frame)
        let offset = try #require(udpHeaderOffset(bytes))
        return dhcpReadUInt16(bytes, offset + 2)
    }

    private func udpPayload(_ frame: Data) throws -> Data {
        let bytes = [UInt8](frame)
        let udpOffset = try #require(udpHeaderOffset(bytes))
        let udpLength = Int(dhcpReadUInt16(bytes, udpOffset + 4))
        let payloadStart = udpOffset + 8
        let payloadEnd = udpOffset + udpLength
        guard payloadEnd >= payloadStart, bytes.count >= payloadEnd else { return Data() }
        return Data(bytes[payloadStart..<payloadEnd])
    }

    private func mdnsAnswerAddress(_ frame: Data, name: String) throws -> IPv4Address? {
        let payload = try udpPayload(frame)
        let bytes = [UInt8](payload)
        guard bytes.count >= 12 else { return nil }
        var offset = 12
        let questionCount = Int(dhcpReadUInt16(bytes, 4))
        let answerCount = Int(dhcpReadUInt16(bytes, 6))

        for _ in 0..<questionCount {
            _ = try #require(readDNSName(bytes, offset: &offset))
            guard offset + 4 <= bytes.count else { return nil }
            offset += 4
        }

        for _ in 0..<answerCount {
            let labels = try #require(readDNSName(bytes, offset: &offset))
            guard offset + 10 <= bytes.count else { return nil }
            let answerName = labels.map { $0.lowercased() }.joined(separator: ".")
            let answerType = dhcpReadUInt16(bytes, offset)
            let answerClass = dhcpReadUInt16(bytes, offset + 2)
            let dataLength = Int(dhcpReadUInt16(bytes, offset + 8))
            offset += 10
            guard offset + dataLength <= bytes.count else { return nil }
            if answerName == name.lowercased(),
               answerType == 1,
               (answerClass & 0x7fff) == 1,
               dataLength == 4 {
                return IPv4Address(value: testReadUInt32(bytes, offset))
            }
            offset += dataLength
        }
        return nil
    }

    private func tcpHeaderOffset(_ bytes: [UInt8]) -> Int? {
        let ipOffset = 14
        guard bytes.count >= ipOffset + 20,
              dhcpReadUInt16(bytes, 12) == 0x0800 else {
            return nil
        }
        let headerLength = Int(bytes[ipOffset] & 0x0f) * 4
        guard headerLength >= 20, bytes.count >= ipOffset + headerLength + 20 else { return nil }
        return ipOffset + headerLength
    }

    private func udpHeaderOffset(_ bytes: [UInt8]) -> Int? {
        let ipOffset = 14
        guard bytes.count >= ipOffset + 20,
              dhcpReadUInt16(bytes, 12) == 0x0800,
              bytes[ipOffset + 9] == 17 else {
            return nil
        }
        let headerLength = Int(bytes[ipOffset] & 0x0f) * 4
        guard headerLength >= 20, bytes.count >= ipOffset + headerLength + 8 else { return nil }
        return ipOffset + headerLength
    }

    private func readDNSName(_ bytes: [UInt8], offset: inout Int, depth: Int = 0) -> [String]? {
        guard depth < 8 else { return nil }
        var labels: [String] = []
        var cursor = offset
        var jumped = false

        while true {
            guard cursor < bytes.count else { return nil }
            let length = bytes[cursor]
            if length == 0 {
                cursor += 1
                if !jumped { offset = cursor }
                return labels
            }
            if (length & 0xc0) == 0xc0 {
                guard cursor + 1 < bytes.count else { return nil }
                let pointer = Int(dhcpReadUInt16(bytes, cursor) & 0x3fff)
                cursor += 2
                if !jumped {
                    offset = cursor
                    jumped = true
                }
                var pointerOffset = pointer
                guard let suffix = readDNSName(bytes, offset: &pointerOffset, depth: depth + 1) else {
                    return nil
                }
                labels.append(contentsOf: suffix)
                return labels
            }
            guard (length & 0xc0) == 0 else { return nil }
            let labelLength = Int(length)
            guard cursor + 1 + labelLength <= bytes.count else { return nil }
            guard let label = String(data: Data(bytes[(cursor + 1)..<(cursor + 1 + labelLength)]), encoding: .utf8) else {
                return nil
            }
            labels.append(label)
            cursor += 1 + labelLength
            if !jumped { offset = cursor }
        }
    }

    private func appendTestUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private func appendTestUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private func testReadUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private final class FrameCollector {
        private let lock = NSLock()
        private var frames: [Data] = []
        private var readIndex = 0

        func append(_ frame: Data) {
            lock.lock()
            frames.append(frame)
            lock.unlock()
        }

        func waitForFrame(timeout: TimeInterval, matching predicate: (Data) -> Bool) throws -> Data {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                lock.lock()
                if readIndex < frames.count {
                    for index in readIndex..<frames.count where predicate(frames[index]) {
                        readIndex = index + 1
                        let frame = frames[index]
                        lock.unlock()
                        return frame
                    }
                }
                lock.unlock()
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            throw AppError("Timed out waiting for collected private network frame.")
        }
    }

    private final class MockLocalEndpoint: PrivateNetworkLocalEndpoint {
        let privateNetworkMACAddress: EthernetAddress
        var receivedFrames: [Data] = []

        init(macAddress: EthernetAddress) {
            privateNetworkMACAddress = macAddress
        }

        func receivePrivateNetworkFrame(_ frame: Data) {
            receivedFrames.append(frame)
        }
    }

    private final class LoopbackTCPServer {
        let port: UInt16

        private let descriptor: Int32
        private let greeting: Data
        private let lock = NSLock()
        private var acceptedDescriptor: Int32 = -1
        private var isStopped = false
        private var received = Data()

        init(greeting: Data, usesIPv6Loopback: Bool = false) throws {
            self.greeting = greeting
            descriptor = socket(usesIPv6Loopback ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
            let socketDescriptor = descriptor
            guard socketDescriptor >= 0 else {
                throw AppError("Failed to create TCP test server socket: \(String(cString: strerror(errno))).")
            }

            var one: Int32 = 1
            _ = setsockopt(socketDescriptor, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

            if usesIPv6Loopback {
                port = try Self.bindIPv6Loopback(socketDescriptor)
            } else {
                port = try Self.bindIPv4Loopback(socketDescriptor)
            }

            guard listen(socketDescriptor, 1) == 0 else {
                let message = String(cString: strerror(errno))
                close(socketDescriptor)
                throw AppError("Failed to listen on TCP test server socket: \(message).")
            }

            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.acceptOneClient()
            }
        }

        private static func bindIPv4Loopback(_ socketDescriptor: Int32) throws -> UInt16 {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(0).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            var bindAddress = address
            let bindResult = withUnsafePointer(to: &bindAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else {
                let message = String(cString: strerror(errno))
                close(socketDescriptor)
                throw AppError("Failed to bind TCP test server socket: \(message).")
            }

            var boundAddress = sockaddr_in()
            var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(socketDescriptor, $0, &boundLength)
                }
            }
            guard nameResult == 0 else {
                let message = String(cString: strerror(errno))
                close(socketDescriptor)
                throw AppError("Failed to inspect TCP test server socket: \(message).")
            }
            return UInt16(bigEndian: boundAddress.sin_port)
        }

        private static func bindIPv6Loopback(_ socketDescriptor: Int32) throws -> UInt16 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(0).bigEndian
            address.sin6_addr = in6addr_loopback

            var bindAddress = address
            let bindResult = withUnsafePointer(to: &bindAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            guard bindResult == 0 else {
                let message = String(cString: strerror(errno))
                close(socketDescriptor)
                throw AppError("Failed to bind TCP test server socket: \(message).")
            }

            var boundAddress = sockaddr_in6()
            var boundLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(socketDescriptor, $0, &boundLength)
                }
            }
            guard nameResult == 0 else {
                let message = String(cString: strerror(errno))
                close(socketDescriptor)
                throw AppError("Failed to inspect TCP test server socket: \(message).")
            }
            return UInt16(bigEndian: boundAddress.sin6_port)
        }

        deinit {
            stop()
        }

        func stop() {
            lock.lock()
            guard !isStopped else {
                lock.unlock()
                return
            }
            isStopped = true
            let client = acceptedDescriptor
            acceptedDescriptor = -1
            lock.unlock()

            if client >= 0 {
                close(client)
            }
            close(descriptor)
        }

        func waitForReceived(_ expected: Data, timeout: TimeInterval) throws -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                lock.lock()
                let hasExpected = received.range(of: expected) != nil
                lock.unlock()
                if hasExpected { return true }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            return false
        }

        private func acceptOneClient() {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }

            lock.lock()
            acceptedDescriptor = client
            let stopped = isStopped
            lock.unlock()
            guard !stopped else {
                close(client)
                return
            }

            greeting.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var sent = 0
                while sent < greeting.count {
                    let result = write(client, baseAddress.advanced(by: sent), greeting.count - sent)
                    guard result > 0 else { return }
                    sent += result
                }
            }

            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = recv(client, &buffer, buffer.count, 0)
                if count > 0 {
                    lock.lock()
                    received.append(contentsOf: buffer.prefix(count))
                    lock.unlock()
                    continue
                }
                if count < 0 && errno == EINTR {
                    continue
                }
                break
            }
            close(client)
        }
    }

    private func readFrame(on descriptor: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 65_535)
        let count = recv(descriptor, &buffer, buffer.count, MSG_DONTWAIT)
        guard count > 0 else { return nil }
        return Data(buffer.prefix(count))
    }

    private final class MockRoutableTransport: PrivateNetworkRoutableTransport {
        var canSendPrivateNetworkFrames = true
        var sentFrames: [Data] = []

        func sendFrameToRemote(_ frame: Data) {
            sentFrames.append(frame)
        }
    }

    private final class TestClock {
        var now: Date

        init(now: Date) {
            self.now = now
        }

        func advance(by interval: TimeInterval) {
            now = now.addingTimeInterval(interval)
        }
    }

    private final class BlockingRoutableTransport: PrivateNetworkRoutableTransport {
        let canSendAttempted = DispatchSemaphore(value: 0)

        private let queue = DispatchQueue(label: "okrun.tests.blocking-routable.\(UUID().uuidString)")
        private var storedSentFrames: [Data] = []

        var canSendPrivateNetworkFrames: Bool {
            canSendAttempted.signal()
            return queue.sync { true }
        }

        var sentFrames: [Data] {
            queue.sync { storedSentFrames }
        }

        func sendFrameToRemote(_ frame: Data) {
            queue.sync {
                storedSentFrames.append(frame)
            }
        }

        func runOnTransportQueue(_ work: @escaping () -> Void) {
            queue.async(execute: work)
        }
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
