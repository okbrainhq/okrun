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
        #expect(config.privateNetwork == .enabled)
        #expect(config.sharedDirectories == [])
        #expect(config.diskIO == .defaults)

        let migratedData = try Data(contentsOf: configURL)
        let migratedJSON = try #require(JSONSerialization.jsonObject(with: migratedData) as? [String: Any])
        #expect(migratedJSON["diskFormat"] as? String == "raw")
        let privateNetwork = try #require(migratedJSON["privateNetwork"] as? [String: Any])
        #expect(privateNetwork["enabled"] as? Bool == true)
        #expect(privateNetwork["identifier"] == nil)
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
            privateNetwork: .enabled,
            sharedDirectories: [
                SharedDirectoryConfig(name: "project", hostPath: sharedDirectory.path, readOnly: false)
            ],
            diskIO: DiskIOConfig(caching: .uncached, synchronization: .fsync)
        )
        try config.save(to: configURL)

        #expect(try VMConfig.load(from: configURL) == config)
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
            #expect(config.diskFormat == .asif)
            #expect(config.diskIO == .defaults)
            #expect(config.installerISOPath == nil)
            #expect(config.privateNetwork == .enabled)
            #expect(config.sharedDirectories == [])
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
    func projectStoreMigratesLegacyDefaultRegistryFile() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let legacyURL = root.appendingPathComponent(".okrun")
        let registry = ProjectRegistry(selectedProject: "/tmp/a", projects: ["/tmp/a"])
        let encoder = JSONEncoder()
        try encoder.encode(registry).write(to: legacyURL)

        let store = ProjectStore(url: root.appendingPathComponent(".okrun/registry.json"), legacyURL: legacyURL)
        let loaded = try store.load(defaultProject: nil)

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
    func hostNetworkConfigStoreValidatesBridgeConfig() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let store = HostNetworkConfigStore(url: root.appendingPathComponent("private-networks.json"))

        let validBridge = PrivateNetworkBridgeConfig(
            bind: PrivateNetworkBridgeEndpoint(host: "127.0.0.1", port: 41000),
            peers: [
                PrivateNetworkBridgeEndpoint(host: "127.0.0.1", port: 41001)
            ]
        )
        let validConfig = HostNetworkConfig(version: 1, privateNetworks: [
            "okrun": HostPrivateNetworkConfig(dhcp: nil, bridge: validBridge)
        ])

        try store.save(validConfig)
        #expect(try store.bridgeConfigForPrivateNetwork(identifier: "okrun") == validBridge)
        #expect(try store.load() == validConfig)

        let clientOnlyBridge = PrivateNetworkBridgeConfig(
            bind: nil,
            peers: [
                PrivateNetworkBridgeEndpoint(host: "127.0.0.1", port: 41000)
            ]
        )
        let clientOnlyConfig = HostNetworkConfig(version: 1, privateNetworks: [
            "okrun": HostPrivateNetworkConfig(dhcp: nil, bridge: clientOnlyBridge)
        ])
        try store.save(clientOnlyConfig)
        #expect(try store.bridgeConfigForPrivateNetwork(identifier: "okrun") == clientOnlyBridge)

        let invalidPort = HostNetworkConfig(version: 1, privateNetworks: [
            "okrun": HostPrivateNetworkConfig(
                dhcp: nil,
                bridge: PrivateNetworkBridgeConfig(
                    bind: PrivateNetworkBridgeEndpoint(host: "127.0.0.1", port: 0),
                    peers: []
                )
            )
        ])
        #expect(throws: (any Error).self) {
            try store.save(invalidPort)
        }

        let invalidHost = HostNetworkConfig(version: 1, privateNetworks: [
            "okrun": HostPrivateNetworkConfig(
                dhcp: nil,
                bridge: PrivateNetworkBridgeConfig(
                    bind: PrivateNetworkBridgeEndpoint(host: "localhost", port: 41000),
                    peers: []
                )
            )
        ])
        #expect(throws: (any Error).self) {
            try store.save(invalidHost)
        }

        let emptyBridge = HostNetworkConfig(version: 1, privateNetworks: [
            "okrun": HostPrivateNetworkConfig(
                dhcp: nil,
                bridge: PrivateNetworkBridgeConfig(bind: nil, peers: [])
            )
        ])
        #expect(throws: (any Error).self) {
            try store.save(emptyBridge)
        }
    }

    @Test
    func privateNetworkBridgeMessageRoundTripsFramedMessages() throws {
        let nodeID = UUID()
        let frame = Data([0xde, 0xad, 0xbe, 0xef])
        let dhcpRange = PrivateNetworkDHCPLeaseRange(
            cidr: "10.77.0.0/24",
            rangeStart: "10.77.0.20",
            rangeEnd: "10.77.0.109"
        )
        var buffer = Data()
        buffer.append(PrivateNetworkBridgeMessage.encodeHello(
            nodeID: nodeID,
            networkIdentifier: "okrun",
            dhcpRange: dhcpRange
        ))
        buffer.append(PrivateNetworkBridgeMessage.encodeFrame(frame))

        let messages = try PrivateNetworkBridgeMessage.decodeMessages(from: &buffer)

        #expect(messages == [
            .hello(nodeID: nodeID, networkIdentifier: "okrun", dhcpRange: dhcpRange),
            .frame(frame)
        ])
        #expect(buffer.isEmpty)

        var partial = PrivateNetworkBridgeMessage.encodeFrame(frame)
        partial.removeLast()
        let partialMessages = try PrivateNetworkBridgeMessage.decodeMessages(from: &partial)
        #expect(partialMessages.isEmpty)
        #expect(!partial.isEmpty)
    }

    @Test
    func privateNetworkBridgeTransfersFramesBetweenHostBridges() throws {
        let network = "bridge-\(UUID().uuidString)"
        let portA = try unusedLoopbackPort()
        let runtimeA = try PrivateNetworkRuntime(identifier: "\(network)-a")
        let runtimeB = try PrivateNetworkRuntime(identifier: "\(network)-b")
        let bridgeA = try PrivateNetworkBridge(
            identifier: network,
            config: PrivateNetworkBridgeConfig(bind: PrivateNetworkBridgeEndpoint(host: "127.0.0.1", port: portA), peers: [])
        )
        let bridgeB = try PrivateNetworkBridge(
            identifier: network,
            config: PrivateNetworkBridgeConfig(
                bind: nil,
                peers: [PrivateNetworkBridgeEndpoint(host: "127.0.0.1", port: portA)]
            )
        )
        bridgeA.addRuntime(runtimeA)
        bridgeB.addRuntime(runtimeB)

        let frame = ethernetFrame(
            destination: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
            source: [0x02, 0xaa, 0xaa, 0xaa, 0xaa, 0x01],
            payload: [0x01, 0x02, 0x03, 0x04]
        )

        try sendFrame(frame, from: runtimeA.fileHandle, untilReceivedOn: runtimeB.fileHandle.fileDescriptor, timeout: 5)
        try sendFrame(frame, from: runtimeB.fileHandle, untilReceivedOn: runtimeA.fileHandle.fileDescriptor, timeout: 5)
        withExtendedLifetime((bridgeA, bridgeB, runtimeA, runtimeB)) {}
    }

    @Test
    func privateNetworkRouterTransfersFramesAcrossBridgeTransport() throws {
        let network = "router-bridge-\(UUID().uuidString)"
        let portA = try unusedLoopbackPort()
        let runtimeA = try PrivateNetworkRuntime(identifier: "\(network)-a")
        let runtimeB = try PrivateNetworkRuntime(identifier: "\(network)-b")
        let routerA = PrivateNetworkTransportRouter(identifier: network)
        let routerB = PrivateNetworkTransportRouter(identifier: network)
        let bridgeA = try PrivateNetworkBridge(
            identifier: network,
            config: PrivateNetworkBridgeConfig(bind: PrivateNetworkBridgeEndpoint(host: "127.0.0.1", port: portA), peers: []),
            onRemoteFrame: { [weak routerA] frame in
                routerA?.receiveRemoteFrame(frame, via: .bridge)
            }
        )
        let bridgeB = try PrivateNetworkBridge(
            identifier: network,
            config: PrivateNetworkBridgeConfig(
                bind: nil,
                peers: [PrivateNetworkBridgeEndpoint(host: "127.0.0.1", port: portA)]
            ),
            onRemoteFrame: { [weak routerB] frame in
                routerB?.receiveRemoteFrame(frame, via: .bridge)
            }
        )
        routerA.setBridge(bridgeA)
        routerB.setBridge(bridgeB)
        routerA.addRuntime(runtimeA)
        routerB.addRuntime(runtimeB)

        let frame = ethernetFrame(
            destination: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
            source: [0x02, 0xab, 0xab, 0xab, 0xab, 0x01],
            payload: [0x05, 0x06, 0x07, 0x08]
        )

        try sendFrame(frame, from: runtimeA.fileHandle, untilReceivedOn: runtimeB.fileHandle.fileDescriptor, timeout: 5)
        try sendFrame(frame, from: runtimeB.fileHandle, untilReceivedOn: runtimeA.fileHandle.fileDescriptor, timeout: 5)
        withExtendedLifetime((routerA, routerB, bridgeA, bridgeB, runtimeA, runtimeB)) {}
    }

    @Test
    func privateNetworkBridgeRejectsOverlappingDHCPRanges() throws {
        let network = "bridge-\(UUID().uuidString)"
        let portA = try unusedLoopbackPort()
        let endpointA = PrivateNetworkBridgeEndpoint(host: "127.0.0.1", port: portA)
        let bridgeA = try PrivateNetworkBridge(
            identifier: network,
            config: PrivateNetworkBridgeConfig(bind: endpointA, peers: []),
            dhcpRange: PrivateNetworkDHCPLeaseRange(
                cidr: "10.77.0.0/24",
                rangeStart: "10.77.0.20",
                rangeEnd: "10.77.0.120"
            )
        )
        let bridgeB = try PrivateNetworkBridge(
            identifier: network,
            config: PrivateNetworkBridgeConfig(bind: nil, peers: [endpointA]),
            dhcpRange: PrivateNetworkDHCPLeaseRange(
                cidr: "10.77.0.0/24",
                rangeStart: "10.77.0.110",
                rangeEnd: "10.77.0.200"
            )
        )

        let status = try waitForPeerState(
            bridgeB,
            endpoint: endpointA,
            state: .rejected,
            timeout: 5
        )

        #expect(status.message.localizedCaseInsensitiveContains("overlaps"))
        withExtendedLifetime((bridgeA, bridgeB)) {}
    }

    @Test
    func privateNetworkBridgeReportsPeerConnectionFailureDetails() throws {
        let network = "bridge-\(UUID().uuidString)"
        let endpoint = PrivateNetworkBridgeEndpoint(host: "127.0.0.1", port: try unusedLoopbackPort())
        let bridge = try PrivateNetworkBridge(
            identifier: network,
            config: PrivateNetworkBridgeConfig(bind: nil, peers: [endpoint])
        )

        let status = try waitForPeerState(
            bridge,
            endpoint: endpoint,
            state: .failed,
            timeout: 5
        )

        #expect(status.message.contains("Failed to connect to \(endpoint.description)"))
        #expect(status.message.contains("Retrying"))
        #expect(status.message.contains("Bridge and Bind"))
        withExtendedLifetime(bridge) {}
    }

    @Test
    func privateNetworkBridgeReportsConfiguredPeerConnectedViaInboundConnection() throws {
        let network = "bridge-\(UUID().uuidString)"
        let endpointA = PrivateNetworkBridgeEndpoint(host: "127.0.0.1", port: try unusedLoopbackPort())
        let endpointB = PrivateNetworkBridgeEndpoint(host: "127.0.0.1", port: try unusedLoopbackPort())
        let bridgeA = try PrivateNetworkBridge(
            identifier: network,
            config: PrivateNetworkBridgeConfig(bind: endpointA, peers: [endpointB])
        )
        let bridgeB = try PrivateNetworkBridge(
            identifier: network,
            config: PrivateNetworkBridgeConfig(bind: nil, peers: [endpointA])
        )

        let status = try waitForPeerState(
            bridgeA,
            endpoint: endpointB,
            state: .connected,
            timeout: 5
        )
        #expect(status.message.contains("inbound bridge connection"))

        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1.2))
        let statusAfterRetryWindow = bridgeA.statusSnapshot().peers.first { $0.endpoint == endpointB }
        #expect(statusAfterRetryWindow?.state == .connected)
        withExtendedLifetime((bridgeA, bridgeB)) {}
    }

    @Test
    func privateNetworkBridgeDoesNotRelayRemoteFramesToOtherHosts() throws {
        let network = "bridge-\(UUID().uuidString)"
        let portB = try unusedLoopbackPort()
        let runtimeA = try PrivateNetworkRuntime(identifier: "\(network)-a")
        let runtimeB = try PrivateNetworkRuntime(identifier: "\(network)-b")
        let runtimeC = try PrivateNetworkRuntime(identifier: "\(network)-c")
        let endpointB = PrivateNetworkBridgeEndpoint(host: "127.0.0.1", port: portB)
        let bridgeA = try PrivateNetworkBridge(
            identifier: network,
            config: PrivateNetworkBridgeConfig(bind: nil, peers: [endpointB])
        )
        let bridgeB = try PrivateNetworkBridge(
            identifier: network,
            config: PrivateNetworkBridgeConfig(bind: endpointB, peers: [])
        )
        let bridgeC = try PrivateNetworkBridge(
            identifier: network,
            config: PrivateNetworkBridgeConfig(bind: nil, peers: [endpointB])
        )
        bridgeA.addRuntime(runtimeA)
        bridgeB.addRuntime(runtimeB)
        bridgeC.addRuntime(runtimeC)

        let warmup = ethernetFrame(
            destination: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
            source: [0x02, 0xcc, 0xcc, 0xcc, 0xcc, 0x01],
            payload: [0x09]
        )
        try sendFrame(warmup, from: runtimeC.fileHandle, untilReceivedOn: runtimeB.fileHandle.fileDescriptor, timeout: 5)
        #expect(waitForNoFrame(on: runtimeA.fileHandle.fileDescriptor, duration: 0.5))
        drainFrames(on: runtimeC.fileHandle.fileDescriptor)

        let frame = ethernetFrame(
            destination: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
            source: [0x02, 0xaa, 0xaa, 0xaa, 0xaa, 0x01],
            payload: [0x01, 0x02, 0x03, 0x04]
        )

        try sendFrame(frame, from: runtimeA.fileHandle, untilReceivedOn: runtimeB.fileHandle.fileDescriptor, timeout: 5)
        #expect(waitForNoFrame(on: runtimeC.fileHandle.fileDescriptor, duration: 0.5))
        withExtendedLifetime((bridgeA, bridgeB, bridgeC, runtimeA, runtimeB, runtimeC)) {}
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
        throw AppError("Timed out waiting for private network bridge frame.")
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
    }

    @Test
    func privateNetworkRouterPrefersBridgeAndFallsBackToSwitch() throws {
        let router = PrivateNetworkTransportRouter(identifier: "router-\(UUID().uuidString)")
        let bridge = MockRoutableTransport()
        let webSwitch = MockRoutableTransport()
        router.setBridge(bridge)
        router.setWebSwitch(webSwitch)

        let localMAC: [UInt8] = [0x02, 0xaa, 0xaa, 0xaa, 0xaa, 0x01]
        let bridgeRemoteMAC: [UInt8] = [0x02, 0xbb, 0xbb, 0xbb, 0xbb, 0x01]
        let switchRemoteMAC: [UInt8] = [0x02, 0xcc, 0xcc, 0xcc, 0xcc, 0x01]
        let bridgeFrame = ethernetFrame(destination: localMAC, source: bridgeRemoteMAC, payload: [0x01])
        let switchFrame = ethernetFrame(destination: localMAC, source: switchRemoteMAC, payload: [0x02])

        router.receiveRemoteFrame(bridgeFrame, via: .bridge)
        router.receiveRemoteFrame(switchFrame, via: .webSwitch)

        let toBridgeRemote = ethernetFrame(destination: bridgeRemoteMAC, source: localMAC, payload: [0x03])
        router.routeLocalFrame(toBridgeRemote)
        #expect(bridge.sentFrames == [toBridgeRemote])
        #expect(webSwitch.sentFrames.isEmpty)

        let toSwitchRemote = ethernetFrame(destination: switchRemoteMAC, source: localMAC, payload: [0x04])
        router.routeLocalFrame(toSwitchRemote)
        #expect(webSwitch.sentFrames == [toSwitchRemote])

        bridge.canSendPrivateNetworkFrames = false
        router.routeLocalFrame(toBridgeRemote)
        #expect(bridge.sentFrames == [toBridgeRemote])
        #expect(webSwitch.sentFrames == [toSwitchRemote, toBridgeRemote])
    }

    @Test
    func privateNetworkRouterSendsDiscoveryFramesAcrossReachableTransports() throws {
        let router = PrivateNetworkTransportRouter(identifier: "router-\(UUID().uuidString)")
        let bridge = MockRoutableTransport()
        let webSwitch = MockRoutableTransport()
        router.setBridge(bridge)
        router.setWebSwitch(webSwitch)

        let frame = ethernetFrame(
            destination: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
            source: [0x02, 0xdd, 0xdd, 0xdd, 0xdd, 0x01],
            payload: [0x05]
        )

        router.routeLocalFrame(frame)

        #expect(bridge.sentFrames == [frame])
        #expect(webSwitch.sentFrames == [frame])
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
            multipath: false
        )
        try store.save(HostNetworkConfig(version: 1, privateNetworks: [
            "okrun": HostPrivateNetworkConfig(dhcp: nil, switch: switchConfig)
        ]))

        #expect(try store.switchConfigForPrivateNetwork(identifier: "okrun") == switchConfig)
        #expect(try store.load().privateNetworks["okrun"]?.switch == switchConfig)

        let bridge = PrivateNetworkBridgeConfig(
            bind: nil,
            peers: [PrivateNetworkBridgeEndpoint(host: "127.0.0.1", port: 9444)]
        )
        let invalidConfig = HostNetworkConfig(version: 1, privateNetworks: [
            "okrun": HostPrivateNetworkConfig(dhcp: nil, bridge: bridge, switch: switchConfig)
        ])
        try store.save(invalidConfig)
        let combined = try store.load().privateNetworks["okrun"]
        #expect(combined?.bridge == bridge)
        #expect(combined?.switch == switchConfig)
    }

    private func sendFrame(
        _ frame: Data,
        from source: FileHandle,
        untilReceivedOn destinationDescriptor: Int32,
        timeout: TimeInterval
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try source.write(contentsOf: frame)
            let attemptDeadline = min(Date().addingTimeInterval(0.05), deadline)
            while Date() < attemptDeadline {
                if let received = readFrame(on: destinationDescriptor), received == frame {
                    return
                }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
        }
        throw AppError("Timed out sending private network bridge frame.")
    }

    private func waitForPeerState(
        _ bridge: PrivateNetworkBridge,
        endpoint: PrivateNetworkBridgeEndpoint,
        state: PrivateNetworkBridgePeerState,
        timeout: TimeInterval
    ) throws -> PrivateNetworkBridgePeerStatus {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let status = bridge.statusSnapshot().peers.first(where: { $0.endpoint == endpoint }),
               status.state == state {
                return status
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        throw AppError("Timed out waiting for private network bridge peer state.")
    }

    private func waitForNoFrame(on descriptor: Int32, duration: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            if readFrame(on: descriptor) != nil {
                return false
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return true
    }

    private func readFrame(on descriptor: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 65_535)
        let count = recv(descriptor, &buffer, buffer.count, MSG_DONTWAIT)
        guard count > 0 else { return nil }
        return Data(buffer.prefix(count))
    }

    private func drainFrames(on descriptor: Int32) {
        while readFrame(on: descriptor) != nil {}
    }

    private final class MockRoutableTransport: PrivateNetworkRoutableTransport {
        var canSendPrivateNetworkFrames = true
        var sentFrames: [Data] = []

        func sendFrameToRemote(_ frame: Data) {
            sentFrames.append(frame)
        }
    }

    private func unusedLoopbackPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw AppError("Failed to create test socket: \(String(cString: strerror(errno))).")
        }
        defer { close(descriptor) }

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        let parseResult = "127.0.0.1".withCString {
            inet_pton(AF_INET, $0, &address.sin_addr)
        }
        guard parseResult == 1 else {
            throw AppError("Failed to parse loopback address for test socket.")
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw AppError("Failed to bind test socket: \(String(cString: strerror(errno))).")
        }

        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &addressLength)
            }
        }
        guard nameResult == 0 else {
            throw AppError("Failed to inspect test socket port: \(String(cString: strerror(errno))).")
        }

        return Int(UInt16(bigEndian: address.sin_port))
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
