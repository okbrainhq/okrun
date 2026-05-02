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

private enum VMMode {
    case installer(URL)
    case installed
}

private struct VMPaths {
    let root: URL
    let config: URL
    let vmDirectory: URL
    let disk: URL
    let efiStore: URL
    let machineIdentifier: URL

    static func project(at root: URL) -> VMPaths {
        let vmDirectory = root.appendingPathComponent("vm", isDirectory: true)
        return VMPaths(
            root: root,
            config: root.appendingPathComponent("okrun-vm.json"),
            vmDirectory: vmDirectory,
            disk: vmDirectory.appendingPathComponent("debian.raw"),
            efiStore: vmDirectory.appendingPathComponent("efi.variables"),
            machineIdentifier: vmDirectory.appendingPathComponent("machine.identifier")
        )
    }
}

private struct ProjectRegistry: Codable {
    var selectedProject: String?
    var projects: [String]

    static let empty = ProjectRegistry(selectedProject: nil, projects: [])
}

private final class ProjectStore {
    private let url: URL

    init() {
        url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".okrun")
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

private struct AppError: LocalizedError {
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

private struct VMConfig: Codable {
    static let defaults = VMConfig(cpuCount: 4, memoryGB: 4, diskGB: 64, installerISOPath: nil)

    let cpuCount: Int
    let memoryGB: Int
    let diskGB: Int
    let installerISOPath: String?

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
        return self
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, VZVirtualMachineDelegate {
    private var window: NSWindow!
    private var vmView = VZVirtualMachineView()
    private var projectPopUp = NSPopUpButton()
    private var createProjectButton = NSButton(title: "New", target: nil, action: nil)
    private var deleteProjectButton = NSButton(title: "Delete", target: nil, action: nil)
    private var statusLabel = NSTextField(labelWithString: "Preparing")
    private var detailsLabel = NSTextField(labelWithString: "")
    private var startInstallerButton = NSButton(title: "Boot Installer", target: nil, action: nil)
    private var startInstalledButton = NSButton(title: "Start", target: nil, action: nil)
    private var shutdownButton = NSButton(title: "Shutdown", target: nil, action: nil)
    private let projectStore = ProjectStore()
    private var registry = ProjectRegistry.empty
    private var virtualMachine: VZVirtualMachine?
    private var paths: VMPaths?
    private var vmConfig: VMConfig?

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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        do {
            try InstanceLauncher.spawnChild()
        } catch {
            setStatus("Launch failed", detail: error.localizedDescription)
        }

        return false
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
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false

        projectPopUp.target = self
        projectPopUp.action = #selector(projectSelectionChanged)
        projectPopUp.setContentHuggingPriority(.defaultLow, for: .horizontal)

        createProjectButton.target = self
        createProjectButton.action = #selector(createProject)
        createProjectButton.bezelStyle = .rounded
        configureButton(createProjectButton, symbolName: "plus")

        deleteProjectButton.target = self
        deleteProjectButton.action = #selector(deleteProject)
        deleteProjectButton.bezelStyle = .rounded
        configureButton(deleteProjectButton, symbolName: "trash")

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        detailsLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailsLabel.textColor = .secondaryLabelColor
        detailsLabel.lineBreakMode = .byWordWrapping
        detailsLabel.maximumNumberOfLines = 1

        startInstallerButton.target = self
        startInstallerButton.action = #selector(startInstaller)
        startInstallerButton.bezelStyle = .rounded
        configureButton(startInstallerButton, symbolName: "opticaldiscdrive")

        startInstalledButton.target = self
        startInstalledButton.action = #selector(startInstalled)
        startInstalledButton.bezelStyle = .rounded
        configureButton(startInstalledButton, symbolName: "play.fill")

        shutdownButton.target = self
        shutdownButton.action = #selector(shutdownVM)
        shutdownButton.bezelStyle = .rounded
        configureButton(shutdownButton, symbolName: "stop.fill")

        vmView.translatesAutoresizingMaskIntoConstraints = false
        vmView.capturesSystemKeys = true

        let topBar = NSStackView()
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.spacing = 8
        topBar.addArrangedSubview(projectPopUp)
        topBar.addArrangedSubview(createProjectButton)
        topBar.addArrangedSubview(deleteProjectButton)
        topBar.addArrangedSubview(makeSeparator())
        topBar.addArrangedSubview(startInstallerButton)
        topBar.addArrangedSubview(startInstalledButton)
        topBar.addArrangedSubview(shutdownButton)

        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.alignment = .firstBaseline
        statusRow.spacing = 8
        statusRow.addArrangedSubview(statusLabel)
        statusRow.addArrangedSubview(detailsLabel)

        root.addArrangedSubview(topBar)
        root.addArrangedSubview(statusRow)
        root.addArrangedSubview(vmView)
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Okrun VM"
        window.contentView = content
        window.makeKeyAndOrderFront(nil)

        setControlsEnabled(canStart: true, canStop: false)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    private func configureButton(_ button: NSButton, symbolName: String) {
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: button.title)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
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
        projectPopUp.removeAllItems()

        if registry.projects.isEmpty {
            projectPopUp.addItem(withTitle: "No projects")
            projectPopUp.isEnabled = false
            return
        }

        for project in registry.projects {
            let url = URL(fileURLWithPath: project, isDirectory: true)
            let label = url.lastPathComponent.isEmpty ? project : url.lastPathComponent
            projectPopUp.addItem(withTitle: label)
            projectPopUp.lastItem?.representedObject = project
        }

        if let selected = registry.selectedProject,
           let index = registry.projects.firstIndex(of: selected) {
            projectPopUp.selectItem(at: index)
        }
    }

    @objc private func projectSelectionChanged() {
        guard virtualMachine == nil else {
            refreshProjectMenu()
            return
        }

        guard let selected = projectPopUp.selectedItem?.representedObject as? String else {
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
        panel.message = "Select the Debian .iso file for this project."
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

        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 170))
        wrapper.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            content.topAnchor.constraint(equalTo: wrapper.topAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: wrapper.bottomAnchor)
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
        field.widthAnchor.constraint(equalToConstant: 80).isActive = true
        return field
    }

    private func prepareStorage(paths: VMPaths, config: VMConfig) throws {
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
                installerISOPath: iso.path
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
                setStatus("Shutdown requested", detail: "Waiting for Debian to shut down cleanly.")
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
                        self?.virtualMachine = nil
                        self?.vmView.virtualMachine = nil
                        self?.setControlsEnabled(canStart: true, canStop: false)
                        self?.setStatus("Start failed", detail: error.localizedDescription)
                    }
                }
            }
        } catch {
            setControlsEnabled(canStart: true, canStop: false)
            setStatus("Configuration failed", detail: error.localizedDescription)
        }
    }

    private func makeConfiguration(paths: VMPaths, config: VMConfig, mode: VMMode) throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = try loadMachineIdentifier(from: paths.machineIdentifier)
        configuration.platform = platform

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = VZEFIVariableStore(url: paths.efiStore)
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

        try configuration.validate()
        return configuration
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
        let hasProject = registry.selectedProject != nil
        startInstallerButton.isEnabled = canStart && hasProject
        startInstalledButton.isEnabled = canStart && hasProject
        shutdownButton.isEnabled = canStop
        createProjectButton.isEnabled = !canStop
        deleteProjectButton.isEnabled = canStart && hasProject
        projectPopUp.isEnabled = canStart && !registry.projects.isEmpty
    }

    private func setStatus(_ status: String, detail: String) {
        statusLabel.stringValue = status
        detailsLabel.stringValue = detail
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        DispatchQueue.main.async { [weak self] in
            self?.virtualMachine = nil
            self?.vmView.virtualMachine = nil
            self?.setControlsEnabled(canStart: true, canStop: false)
            self?.setStatus("Shutdown", detail: "The VM has shut down.")
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
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
        InstanceLauncher.continueOrSpawnChild()

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        _ = delegate
    }
}
