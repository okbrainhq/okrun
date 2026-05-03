import AppKit
import Darwin
import UniformTypeIdentifiers
import Virtualization

private enum InstanceLauncher {
    private static let childEnvironmentKey = "OKRUN_VM_CHILD_INSTANCE"

    static func continueOrSpawnChild() {
        guard ProcessInfo.processInfo.environment[childEnvironmentKey] != "1" else {
            return
        }

        do {
            try spawnChild()
            exit(0)
        } catch {
            return
        }
    }

    static func spawnChild() throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw AppError("Unable to locate app executable.")
        }

        var environment = ProcessInfo.processInfo.environment
        environment[childEnvironmentKey] = "1"

        let process = Process()
        process.executableURL = executableURL
        process.arguments = Array(CommandLine.arguments.dropFirst())
        process.environment = environment
        try process.run()
    }
}

enum VMMode {
    case installer(URL)
    case installed
}

struct VMPaths {
    let root: URL
    let config: URL
    let vmDirectory: URL
    let disk: URL
    let efiStore: URL
    let installerEfiStore: URL
    let machineIdentifier: URL

    static func project(at root: URL) -> VMPaths {
        let vmDirectory = root.appendingPathComponent("vm", isDirectory: true)
        let disk = preferredDisk(in: vmDirectory)
        return VMPaths(
            root: root,
            config: root.appendingPathComponent("okrun-vm.json"),
            vmDirectory: vmDirectory,
            disk: disk,
            efiStore: vmDirectory.appendingPathComponent("efi.variables"),
            installerEfiStore: vmDirectory.appendingPathComponent("installer.efi.variables"),
            machineIdentifier: vmDirectory.appendingPathComponent("machine.identifier")
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

private struct NewProjectRequest {
    let projectURL: URL
    let isoURL: URL
    let config: VMConfig
}

private final class DialogActions: NSObject {
    var onChooseProject: (() -> Void)?
    var onChooseISO: (() -> Void)?

    @objc func chooseProject() {
        onChooseProject?()
    }

    @objc func chooseISO() {
        onChooseISO?()
    }
}

private final class GlassPanelView: NSVisualEffectView {
    init(material: NSVisualEffectView.Material = .hudWindow, cornerRadius: CGFloat = 18) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        blendingMode = .withinWindow
        self.material = material
        state = .active
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class RoundedContainerView: NSView {
    init(cornerRadius: CGFloat = 24) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private extension NSToolbarItem.Identifier {
    static let newInstance = NSToolbarItem.Identifier("OkrunVM.newInstance")
    static let projectPicker = NSToolbarItem.Identifier("OkrunVM.projectPicker")
    static let newProject = NSToolbarItem.Identifier("OkrunVM.newProject")
    static let deleteProject = NSToolbarItem.Identifier("OkrunVM.deleteProject")
    static let installer = NSToolbarItem.Identifier("OkrunVM.installer")
    static let start = NSToolbarItem.Identifier("OkrunVM.start")
    static let shutdown = NSToolbarItem.Identifier("OkrunVM.shutdown")
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

private final class HeadlessBootTest: NSObject, VZVirtualMachineDelegate {
    private let kernelURL: URL
    private let initialRamdiskURL: URL
    private let timeout: TimeInterval
    private let sharedDirectory: SharedDirectoryConfig?
    private var expectedOutput: String {
        sharedDirectory == nil ? "OKRUN_E2E_BOOTED" : "OKRUN_E2E_SHARED_DIRS_PASSED"
    }
    private let completion = DispatchSemaphore(value: 0)
    private var virtualMachine: VZVirtualMachine?
    private var serialOutput = Data()
    private var result: Result<Void, Error>?

    init(kernelURL: URL, initialRamdiskURL: URL, timeout: TimeInterval, sharedDirectory: SharedDirectoryConfig?) {
        self.kernelURL = kernelURL
        self.initialRamdiskURL = initialRamdiskURL
        self.timeout = timeout
        self.sharedDirectory = sharedDirectory
    }

    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Int32? {
        guard arguments.contains("--headless-boot-test") else { return nil }

        do {
            let options = try parseOptions(arguments: arguments)
            let test = HeadlessBootTest(
                kernelURL: options.kernel,
                initialRamdiskURL: options.initialRamdisk,
                timeout: options.timeout,
                sharedDirectory: options.sharedDirectory
            )
            try test.run()
            print("Headless boot E2E passed: \(test.expectedOutput)")
            return 0
        } catch {
            fputs("Headless boot E2E failed: \(describeError(error))\n", stderr)
            return 1
        }
    }

    private static func describeError(_ error: Error) -> String {
        let nsError = error as NSError
        var message = error.localizedDescription
        message += " [domain: \(nsError.domain), code: \(nsError.code)]"
        if !nsError.userInfo.isEmpty {
            message += " userInfo: \(nsError.userInfo)"
        }
        return message
    }

    private static func parseOptions(arguments: [String]) throws -> (kernel: URL, initialRamdisk: URL, timeout: TimeInterval, sharedDirectory: SharedDirectoryConfig?) {
        var kernelPath: String?
        var initialRamdiskPath: String?
        var timeout: TimeInterval = 30
        var sharedDirectoryPath: String?
        var iterator = arguments.dropFirst().makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--kernel":
                kernelPath = iterator.next()
            case "--initramfs":
                initialRamdiskPath = iterator.next()
            case "--timeout":
                guard let value = iterator.next(), let parsed = TimeInterval(value), parsed > 0 else {
                    throw AppError("--timeout must be a positive number of seconds.")
                }
                timeout = parsed
            case "--shared-directory":
                sharedDirectoryPath = iterator.next()
            default:
                continue
            }
        }

        guard let kernelPath else {
            throw AppError("Missing --kernel path.")
        }
        guard let initialRamdiskPath else {
            throw AppError("Missing --initramfs path.")
        }

        let kernel = URL(fileURLWithPath: kernelPath)
        let initialRamdisk = URL(fileURLWithPath: initialRamdiskPath)
        guard FileManager.default.fileExists(atPath: kernel.path) else {
            throw AppError("Kernel does not exist: \(kernel.path)")
        }
        guard FileManager.default.fileExists(atPath: initialRamdisk.path) else {
            throw AppError("Initramfs does not exist: \(initialRamdisk.path)")
        }

        let sharedDirectory = sharedDirectoryPath.map {
            SharedDirectoryConfig(name: "e2e", hostPath: $0, readOnly: false)
        }

        return (kernel, initialRamdisk, timeout, sharedDirectory)
    }

    private func run() throws {
        let outputPipe = Pipe()
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.appendSerialOutput(data)
        }

        let configuration = try makeConfiguration(serialOutput: outputPipe.fileHandleForWriting)
        let vm = VZVirtualMachine(configuration: configuration)
        vm.delegate = self
        virtualMachine = vm

        vm.start { [weak self] result in
            DispatchQueue.main.async {
                if case .failure(let error) = result {
                    self?.finish(.failure(error))
                }
            }
        }

        let runLoopDeadline = Date().addingTimeInterval(timeout)
        while result == nil && Date() < runLoopDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        try stopVM()

        guard let result else {
            let output = String(decoding: serialOutput, as: UTF8.self)
            throw AppError("Timed out waiting for \(expectedOutput). Serial output:\n\(output)")
        }

        try result.get()
    }

    private func makeConfiguration(serialOutput: FileHandle) throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = VZGenericMachineIdentifier()
        configuration.platform = platform

        let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
        bootLoader.initialRamdiskURL = initialRamdiskURL
        bootLoader.commandLine = "console=hvc0 panic=-1"
        configuration.bootLoader = bootLoader

        configuration.cpuCount = 1
        configuration.memorySize = 1024 * 1024 * 1024
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
        serialPort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil,
            fileHandleForWriting: serialOutput
        )
        configuration.serialPorts = [serialPort]
        configuration.directorySharingDevices = try DirectorySharingDeviceFactory.makeDevices(
            for: sharedDirectory.map { [$0] } ?? []
        )

        try configuration.validate()
        return configuration
    }

    private func appendSerialOutput(_ data: Data) {
        serialOutput.append(data)
        let output = String(decoding: serialOutput, as: UTF8.self)
        if output.contains(expectedOutput) {
            finish(.success(()))
        }
    }

    private func stopVM() throws {
        guard let virtualMachine else { return }
        if virtualMachine.canRequestStop {
            try? virtualMachine.requestStop()
            return
        }
        if virtualMachine.canStop {
            let stopSemaphore = DispatchSemaphore(value: 0)
            virtualMachine.stop { _ in
                stopSemaphore.signal()
            }
            _ = stopSemaphore.wait(timeout: .now() + 5)
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        completion.signal()
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        finish(.failure(AppError("VM stopped before emitting \(expectedOutput).")))
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        finish(.failure(error))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate, NSToolbarItemValidation, VZVirtualMachineDelegate {
    private var window: NSWindow!
    private var vmView = VZVirtualMachineView()
    private var statusLabel = NSTextField(labelWithString: "Preparing")
    private var detailsLabel = NSTextField(labelWithString: "")
    private let projectStore = ProjectStore()
    private var registry = ProjectRegistry.empty
    private var virtualMachine: VZVirtualMachine?
    private var paths: VMPaths?
    private var vmConfig: VMConfig?
    private var projectLockFD: Int32?
    private var canStartControls = true
    private var canStopControls = false
    private weak var projectMenuButton: NSPopUpButton?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installAppIcon()
        buildWindow()

        do {
            registry = try projectStore.load(defaultProject: ProjectStore.defaultProjectRoot())
            refreshProjectMenu()
            try loadSelectedProject()
        } catch {
            setStatus("Setup failed", detail: error.localizedDescription)
            setControlsEnabled(canStart: false, canStop: false)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        releaseProjectLock()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window.makeKeyAndOrderFront(nil)
        }

        return true
    }

    private func installAppIcon() {
        guard let iconURL = Bundle.main.url(forResource: "OkrunVM", withExtension: "png"),
              let icon = NSImage(contentsOf: iconURL) else {
            return
        }

        NSApp.applicationIconImage = icon
    }

    private func buildWindow() {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.alignment = .right
        detailsLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailsLabel.textColor = .secondaryLabelColor
        detailsLabel.lineBreakMode = .byWordWrapping
        detailsLabel.maximumNumberOfLines = 1
        detailsLabel.alignment = .right

        vmView.translatesAutoresizingMaskIntoConstraints = false
        vmView.capturesSystemKeys = true

        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.alignment = .firstBaseline
        statusRow.spacing = 8
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusRow.addArrangedSubview(statusLabel)
        statusRow.addArrangedSubview(detailsLabel)

        let statusContainer = NSView()
        statusContainer.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.addSubview(statusRow)

        let vmContainer = RoundedContainerView()
        vmContainer.addSubview(vmView)

        root.addArrangedSubview(statusContainer)
        root.addArrangedSubview(vmContainer)
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            statusContainer.heightAnchor.constraint(equalToConstant: 24),
            statusRow.trailingAnchor.constraint(equalTo: statusContainer.trailingAnchor),
            statusRow.centerYAnchor.constraint(equalTo: statusContainer.centerYAnchor),
            statusRow.leadingAnchor.constraint(greaterThanOrEqualTo: statusContainer.leadingAnchor),
            vmContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 720),
            vmContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 420),
            vmView.leadingAnchor.constraint(equalTo: vmContainer.leadingAnchor),
            vmView.trailingAnchor.constraint(equalTo: vmContainer.trailingAnchor),
            vmView.topAnchor.constraint(equalTo: vmContainer.topAnchor),
            vmView.bottomAnchor.constraint(equalTo: vmContainer.bottomAnchor)
        ])

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 820, height: 560)
        window.center()
        window.title = "Okrun VM"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        window.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1)
        window.contentView = content
        installToolbar()
        window.makeKeyAndOrderFront(nil)

        setControlsEnabled(canStart: true, canStop: false)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "OkrunVM.mainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.showsBaselineSeparator = false

        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
        }

        window.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .newInstance,
            .flexibleSpace,
            .flexibleSpace,
            .projectPicker,
            .newProject,
            .deleteProject,
            .space,
            .installer,
            .start,
            .shutdown
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .newInstance:
            return makeToolbarItem(
                itemIdentifier,
                label: "New Instance",
                symbolName: "plus.square.on.square",
                action: #selector(createInstance)
            )
        case .projectPicker:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Project"
            item.paletteLabel = "Project"
            item.toolTip = "Select project"
            let button = makeProjectMenuButton()
            item.view = button
            projectMenuButton = button
            return item
        case .newProject:
            return makeToolbarItem(itemIdentifier, label: "New Project", symbolName: "plus", action: #selector(createProject))
        case .deleteProject:
            return makeToolbarItem(itemIdentifier, label: "Delete Project", symbolName: "trash", action: #selector(deleteProject))
        case .installer:
            return makeToolbarItem(itemIdentifier, label: "Boot Installer", symbolName: "opticaldiscdrive", action: #selector(startInstaller))
        case .start:
            return makeToolbarItem(itemIdentifier, label: "Start", symbolName: "play.fill", action: #selector(startInstalled))
        case .shutdown:
            return makeToolbarItem(itemIdentifier, label: "Shutdown", symbolName: "stop.fill", action: #selector(shutdownVM))
        default:
            return nil
        }
    }

    private func makeToolbarItem(
        _ identifier: NSToolbarItem.Identifier,
        label: String,
        symbolName: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.target = self
        item.action = action
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        item.isBordered = true
        return item
    }

    private func makeProjectMenuButton() -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = #selector(projectMenuButtonChanged(_:))
        button.controlSize = .regular
        button.bezelStyle = .texturedRounded
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 136).isActive = true
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 190).isActive = true
        populateProjectMenuButton(button)
        return button
    }

    private func populateProjectMenuButton(_ button: NSPopUpButton) {
        button.removeAllItems()

        if registry.projects.isEmpty {
            button.addItem(withTitle: "No Project")
            button.isEnabled = false
            return
        }

        for project in registry.projects {
            let url = URL(fileURLWithPath: project, isDirectory: true)
            let label = url.lastPathComponent.isEmpty ? project : url.lastPathComponent
            button.addItem(withTitle: label)
            button.lastItem?.representedObject = project
        }

        if let selected = registry.selectedProject,
           let index = registry.projects.firstIndex(of: selected) {
            button.selectItem(at: index)
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let hasProject = registry.selectedProject != nil

        switch item.itemIdentifier {
        case .newInstance, .installer, .start:
            return canStartControls && hasProject
        case .projectPicker:
            return canStartControls && !registry.projects.isEmpty
        case .deleteProject:
            return canStartControls && hasProject
        case .newProject:
            return !canStopControls
        case .shutdown:
            return canStopControls
        default:
            return true
        }
    }

    private func makeGlassPanel(
        containing child: NSView,
        material: NSVisualEffectView.Material = .hudWindow,
        horizontalInset: CGFloat,
        verticalInset: CGFloat
    ) -> NSView {
        let panel = GlassPanelView(material: material)
        panel.addSubview(child)

        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: horizontalInset),
            child.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -horizontalInset),
            child.topAnchor.constraint(equalTo: panel.topAnchor, constant: verticalInset),
            child.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -verticalInset)
        ])

        return panel
    }

    private func configureButton(_ button: NSButton, symbolName: String) {
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: button.title)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.controlSize = .large
    }

    private func loadSelectedProject() throws {
        guard let selectedProject = registry.selectedProject else {
            paths = nil
            vmConfig = nil
            setStatus("No project selected", detail: "Registry: \(projectStore.path)")
            setControlsEnabled(canStart: false, canStop: false)
            return
        }

        let projectURL = URL(fileURLWithPath: selectedProject, isDirectory: true)
        let discoveredPaths = VMPaths.project(at: projectURL)
        let config = try VMConfig.load(from: discoveredPaths.config)

        paths = discoveredPaths
        vmConfig = config
        try prepareStorage(paths: discoveredPaths, config: config)
        setStatus("Ready", detail: statusDetail(paths: discoveredPaths, config: config))
        setControlsEnabled(canStart: true, canStop: false)
    }

    private func refreshProjectMenu() {
        if let projectMenuButton {
            populateProjectMenuButton(projectMenuButton)
        }
        window?.toolbar?.validateVisibleItems()
    }

    @objc private func projectMenuButtonChanged(_ sender: NSPopUpButton) {
        guard virtualMachine == nil else {
            refreshProjectMenu()
            return
        }

        guard let selected = sender.selectedItem?.representedObject as? String else {
            return
        }

        do {
            registry.selectedProject = selected
            try projectStore.save(registry)
            try loadSelectedProject()
        } catch {
            setStatus("Project load failed", detail: error.localizedDescription)
            setControlsEnabled(canStart: false, canStop: false)
        }
    }

    @objc private func createProject() {
        guard virtualMachine == nil else { return }
        guard let request = askForNewProject() else { return }

        do {
            try FileManager.default.createDirectory(at: request.projectURL, withIntermediateDirectories: true)
            let paths = VMPaths.project(at: request.projectURL)
            try request.config.save(to: paths.config)
            try prepareStorage(paths: paths, config: request.config)

            let path = projectStore.standardPath(request.projectURL)
            if !registry.projects.contains(path) {
                registry.projects.append(path)
            }
            registry.selectedProject = path
            try projectStore.save(registry)
            refreshProjectMenu()
            try loadSelectedProject()
            start(mode: .installer(request.isoURL))
        } catch {
            setStatus("Add project failed", detail: error.localizedDescription)
            setControlsEnabled(canStart: false, canStop: false)
        }
    }

    @objc private func deleteProject() {
        guard virtualMachine == nil else { return }
        guard let selectedProject = registry.selectedProject else { return }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete Project?"
        alert.informativeText = """
        This will permanently delete everything in this folder:

        \(selectedProject)

        This includes the VM disk, EFI state, machine identifier, and project config.
        """
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: selectedProject) {
                try fileManager.removeItem(atPath: selectedProject)
            }

            registry.projects.removeAll { $0 == selectedProject }
            registry.selectedProject = registry.projects.first
            try projectStore.save(registry)
            refreshProjectMenu()

            if registry.selectedProject == nil {
                paths = nil
                vmConfig = nil
                vmView.virtualMachine = nil
                setStatus("No project selected", detail: "Registry: \(projectStore.path)")
                setControlsEnabled(canStart: false, canStop: false)
            } else {
                try loadSelectedProject()
            }
        } catch {
            setStatus("Delete failed", detail: error.localizedDescription)
            setControlsEnabled(canStart: true, canStop: false)
        }
    }

    private func chooseProjectDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Project Directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseInstallerISO() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Installer ISO"
        panel.message = "Select the Linux .iso file for this project."
        panel.prompt = "Use ISO"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage]
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func askForNewProject() -> NewProjectRequest? {
        var projectURL: URL?
        var isoURL: URL?
        var result: NewProjectRequest?

        let projectPath = NSTextField(labelWithString: "Not selected")
        let isoPath = NSTextField(labelWithString: "Not selected")
        projectPath.lineBreakMode = .byTruncatingMiddle
        isoPath.lineBreakMode = .byTruncatingMiddle
        projectPath.textColor = .secondaryLabelColor
        isoPath.textColor = .secondaryLabelColor

        let projectButton = NSButton(title: "Choose...", target: nil, action: nil)
        let isoButton = NSButton(title: "Choose...", target: nil, action: nil)
        projectButton.bezelStyle = .rounded
        isoButton.bezelStyle = .rounded
        configureButton(projectButton, symbolName: "folder")
        configureButton(isoButton, symbolName: "opticaldisc")
        let cpuField = makeNumberField("4")
        let memoryField = makeNumberField("4")
        let diskField = makeNumberField("64")

        let actions = DialogActions()
        actions.onChooseProject = { [weak self, weak projectPath] in
            guard let url = self?.chooseProjectDirectory() else { return }
            projectURL = url
            projectPath?.stringValue = url.path
        }
        actions.onChooseISO = { [weak self, weak isoPath] in
            guard let url = self?.chooseInstallerISO() else { return }
            isoURL = url
            isoPath?.stringValue = url.path
        }
        projectButton.target = actions
        projectButton.action = #selector(DialogActions.chooseProject)
        isoButton.target = actions
        isoButton.action = #selector(DialogActions.chooseISO)

        let subtitle = NSTextField(labelWithString: "Select where the project lives, the installer ISO, and the VM resources.")
        subtitle.font = .systemFont(ofSize: 12, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 2

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Project"), projectPath, projectButton],
            [NSTextField(labelWithString: "ISO"), isoPath, isoButton],
            [NSTextField(labelWithString: "CPU"), cpuField, NSView()],
            [NSTextField(labelWithString: "Memory GB"), memoryField, NSView()],
            [NSTextField(labelWithString: "Disk GB"), diskField, NSView()]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 90
        grid.column(at: 1).width = 440
        grid.column(at: 2).width = 90
        grid.rowSpacing = 10
        grid.columnSpacing = 12

        let content = NSStackView(views: [subtitle, grid])
        content.orientation = .vertical
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = GlassPanelView(material: .contentBackground, cornerRadius: 16)
        wrapper.frame = NSRect(x: 0, y: 0, width: 680, height: 190)
        wrapper.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 16),
            content.bottomAnchor.constraint(lessThanOrEqualTo: wrapper.bottomAnchor, constant: -16)
        ])

        let alert = NSAlert()
        alert.messageText = "New Project"
        alert.informativeText = ""
        alert.accessoryView = wrapper
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        while alert.runModal() == .alertFirstButtonReturn {
            guard let projectURL,
                  let isoURL,
                  let cpu = Int(cpuField.stringValue),
                  let memory = Int(memoryField.stringValue),
                  let disk = Int(diskField.stringValue),
                  let config = try? VMConfig(cpuCount: cpu, memoryGB: memory, diskGB: disk, installerISOPath: isoURL.path).validated() else {
                NSSound.beep()
                continue
            }

            result = NewProjectRequest(projectURL: projectURL, isoURL: isoURL, config: config)
            break
        }

        return result
    }

    private func makeNumberField(_ value: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.alignment = .right
        field.controlSize = .large
        field.font = .systemFont(ofSize: 13)
        field.widthAnchor.constraint(equalToConstant: 80).isActive = true
        return field
    }

    @objc private func createInstance() {
        guard registry.selectedProject != nil else {
            setStatus("No project selected", detail: "Create or select a project before opening a second VM instance.")
            return
        }

        do {
            try InstanceLauncher.spawnChild()
        } catch {
            setStatus("Launch failed", detail: error.localizedDescription)
        }
    }

    private func prepareStorage(paths: VMPaths, config: VMConfig) throws {
        try VMStorage.prepare(paths: paths, config: config)
    }

    private func statusDetail(paths: VMPaths, config: VMConfig) -> String {
        "\(paths.root.path)  |  CPU \(config.cpuCount)  Memory \(config.memoryGB) GB  Disk \(config.diskGB) GB"
    }

    private func runtimeDetail(_ status: String) -> String {
        guard let paths, let vmConfig else { return status }

        return """
        \(status)

        \(statusDetail(paths: paths, config: vmConfig))
        """
    }

    @objc private func startInstaller() {
        guard let paths, let vmConfig else {
            setStatus("Not ready", detail: "No project is selected.")
            return
        }

        if let isoPath = vmConfig.installerISOPath, FileManager.default.fileExists(atPath: isoPath) {
            start(mode: .installer(URL(fileURLWithPath: isoPath)))
            return
        }

        guard let iso = chooseInstallerISO() else { return }

        do {
            let updatedConfig = VMConfig(
                cpuCount: vmConfig.cpuCount,
                memoryGB: vmConfig.memoryGB,
                diskGB: vmConfig.diskGB,
                installerISOPath: iso.path,
                sharedDirectories: vmConfig.sharedDirectories
            )
            try updatedConfig.save(to: paths.config)
            self.vmConfig = updatedConfig
            start(mode: .installer(iso))
        } catch {
            setStatus("ISO update failed", detail: error.localizedDescription)
        }
    }

    @objc private func startInstalled() {
        start(mode: .installed)
    }

    @objc private func shutdownVM() {
        guard let virtualMachine else { return }
        do {
            if virtualMachine.canRequestStop {
                try virtualMachine.requestStop()
                setStatus("Shutdown requested", detail: "Waiting for Linux to shut down cleanly.")
                return
            }
        } catch {
            setStatus("Graceful shutdown failed", detail: error.localizedDescription)
            return
        }

        guard virtualMachine.canStop else {
            setStatus("Shutdown unavailable", detail: "The VM is not currently in a stoppable state.")
            return
        }

        setStatus("Force shutdown", detail: "Force-stopping the VM.")
        virtualMachine.stop { [weak self] error in
            if let error {
                self?.setStatus("Shutdown failed", detail: error.localizedDescription)
            } else {
                self?.releaseProjectLock()
                self?.virtualMachine = nil
                self?.vmView.virtualMachine = nil
                self?.setControlsEnabled(canStart: true, canStop: false)
                self?.setStatus("Shutdown", detail: "You can boot the installer or installed system again.")
            }
        }
    }

    private func start(mode: VMMode) {
        guard virtualMachine == nil else { return }
        guard let paths else {
            setStatus("Not ready", detail: "VM paths were not prepared.")
            return
        }
        guard let vmConfig else {
            setStatus("Not ready", detail: "VM config was not loaded.")
            return
        }

        do {
            try acquireProjectLock(paths: paths)
            let configuration = try makeConfiguration(paths: paths, config: vmConfig, mode: mode)
            let vm = VZVirtualMachine(configuration: configuration)
            vm.delegate = self
            virtualMachine = vm
            vmView.virtualMachine = vm
            setControlsEnabled(canStart: false, canStop: true)

            let modeText: String
            switch mode {
            case .installer(let iso):
                modeText = "installer: \(iso.lastPathComponent)"
            case .installed:
                modeText = "installed system"
            }
            setStatus("Starting \(modeText)", detail: statusDetail(paths: paths, config: vmConfig))

            vm.start { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        self?.setStatus("Running", detail: self?.runtimeDetail("Mode: \(modeText)") ?? "")
                    case .failure(let error):
                        self?.releaseProjectLock()
                        self?.virtualMachine = nil
                        self?.vmView.virtualMachine = nil
                        self?.setControlsEnabled(canStart: true, canStop: false)
                        self?.setStatus("Start failed", detail: error.localizedDescription)
                    }
                }
            }
        } catch {
            releaseProjectLock()
            setControlsEnabled(canStart: true, canStop: false)
            setStatus("Configuration failed", detail: error.localizedDescription)
        }
    }

    private func acquireProjectLock(paths: VMPaths) throws {
        guard projectLockFD == nil else { return }

        try FileManager.default.createDirectory(at: paths.vmDirectory, withIntermediateDirectories: true)
        let lockURL = paths.vmDirectory.appendingPathComponent("okrun.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard fd >= 0 else {
            throw AppError("Unable to create VM lock at \(lockURL.path).")
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            throw AppError("This project is already running in another Okrun VM instance: \(paths.root.path)")
        }

        projectLockFD = fd
    }

    private func releaseProjectLock() {
        guard let fd = projectLockFD else { return }
        flock(fd, LOCK_UN)
        close(fd)
        projectLockFD = nil
    }

    private func makeConfiguration(paths: VMPaths, config: VMConfig, mode: VMMode) throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = try loadMachineIdentifier(from: paths.machineIdentifier)
        configuration.platform = platform

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = try makeEFIVariableStore(paths: paths, mode: mode)
        configuration.bootLoader = bootLoader

        configuration.cpuCount = min(config.cpuCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        configuration.memorySize = min(UInt64(config.memoryGB) * 1024 * 1024 * 1024, VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        configuration.graphicsDevices = [makeGraphicsDevice()]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        configuration.networkDevices = [makeNetworkDevice()]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        configuration.storageDevices = try makeStorageDevices(paths: paths, mode: mode)
        configuration.directorySharingDevices = try DirectorySharingDeviceFactory.makeDevices(for: config.sharedDirectories)

        try configuration.validate()
        return configuration
    }

    private func makeEFIVariableStore(paths: VMPaths, mode: VMMode) throws -> VZEFIVariableStore {
        try EFIVariableStoreFactory.make(paths: paths, mode: mode)
    }

    private func loadMachineIdentifier(from url: URL) throws -> VZGenericMachineIdentifier {
        let data = try Data(contentsOf: url)
        guard let machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: data) else {
            throw AppError("Invalid machine identifier at \(url.path)")
        }
        return machineIdentifier
    }

    private func makeGraphicsDevice() -> VZGraphicsDeviceConfiguration {
        let graphicsDevice = VZVirtioGraphicsDeviceConfiguration()
        graphicsDevice.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 800)
        ]
        return graphicsDevice
    }

    private func makeNetworkDevice() -> VZNetworkDeviceConfiguration {
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        return networkDevice
    }

    private func makeStorageDevices(paths: VMPaths, mode: VMMode) throws -> [VZStorageDeviceConfiguration] {
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: paths.disk, readOnly: false)
        let diskDevice = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)

        switch mode {
        case .installed:
            return [diskDevice]
        case .installer(let iso):
            let isoAttachment = try VZDiskImageStorageDeviceAttachment(url: iso, readOnly: true)
            let isoDevice = VZVirtioBlockDeviceConfiguration(attachment: isoAttachment)
            return [isoDevice, diskDevice]
        }
    }

    private func setControlsEnabled(canStart: Bool, canStop: Bool) {
        canStartControls = canStart
        canStopControls = canStop
        projectMenuButton?.isEnabled = canStart && !registry.projects.isEmpty
        window?.toolbar?.validateVisibleItems()
    }

    private func setStatus(_ status: String, detail: String) {
        statusLabel.stringValue = status
        detailsLabel.stringValue = detail
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        DispatchQueue.main.async { [weak self] in
            self?.releaseProjectLock()
            self?.virtualMachine = nil
            self?.vmView.virtualMachine = nil
            self?.setControlsEnabled(canStart: true, canStop: false)
            self?.setStatus("Shutdown", detail: "The VM has shut down.")
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.releaseProjectLock()
            self?.virtualMachine = nil
            self?.vmView.virtualMachine = nil
            self?.setControlsEnabled(canStart: true, canStop: false)
            self?.setStatus("Stopped with error", detail: error.localizedDescription)
        }
    }
}

@main
enum OkrunVMApp {
    static func main() {
        if let exitCode = HeadlessBootTest.runIfRequested() {
            exit(exitCode)
        }

        InstanceLauncher.continueOrSpawnChild()

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        _ = delegate
    }
}
