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
        #expect(paths.efiStore == vmDirectory.appendingPathComponent("efi.variables"))
        #expect(paths.installerEfiStore == vmDirectory.appendingPathComponent("installer.efi.variables"))
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

        try VMStorage.prepare(paths: paths, config: config)

        #expect(FileManager.default.fileExists(atPath: paths.disk.path))
        #expect(FileManager.default.fileExists(atPath: paths.efiStore.path))
        #expect(FileManager.default.fileExists(atPath: paths.machineIdentifier.path))

        let attributes = try FileManager.default.attributesOfItem(atPath: paths.disk.path)
        #expect(attributes[.size] as? UInt64 == 1_073_741_824)
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

        try VMStorage.prepare(paths: paths, config: VMConfig(cpuCount: 2, memoryGB: 2, diskGB: 2, installerISOPath: nil))
        var attributes = try FileManager.default.attributesOfItem(atPath: paths.disk.path)
        #expect(attributes[.size] as? UInt64 == 2_147_483_648)

        #expect(throws: (any Error).self) {
            try VMStorage.prepare(paths: paths, config: VMConfig(cpuCount: 2, memoryGB: 2, diskGB: 1, installerISOPath: nil))
        }

        attributes = try FileManager.default.attributesOfItem(atPath: paths.disk.path)
        #expect(attributes[.size] as? UInt64 == 2_147_483_648)
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
