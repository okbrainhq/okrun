import AppKit
import Darwin
import Virtualization

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
    init(cornerRadius: CGFloat = 20) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
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

private enum RunningVMCloseAction {
    case stop
    case closeAnyway
    case cancel
}

private final class CloseAlertButtonHandler: NSObject {
    @objc func shutdown() {
        NSApp.stopModal(withCode: .alertFirstButtonReturn)
    }

    @objc func closeAnyway() {
        NSApp.stopModal(withCode: .alertSecondButtonReturn)
    }

    @objc func cancel() {
        NSApp.stopModal(withCode: .alertThirdButtonReturn)
    }
}


final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation, VZVirtualMachineDelegate {
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
    private var isClosingAnyway = false
    private var closeAlertHandler: CloseAlertButtonHandler?
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard virtualMachine != nil, !isClosingAnyway else {
            return .terminateNow
        }

        switch askBeforeClosingRunningVM() {
        case .stop:
            shutdownVM()
            return .terminateCancel
        case .closeAnyway:
            isClosingAnyway = true
            return .terminateNow
        case .cancel:
            return .terminateCancel
        }
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard virtualMachine != nil, !isClosingAnyway else {
            return true
        }

        switch askBeforeClosingRunningVM() {
        case .stop:
            shutdownVM()
            return false
        case .closeAnyway:
            isClosingAnyway = true
            return true
        case .cancel:
            return false
        }
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
        window.delegate = self
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
        case .newInstance:
            return hasProject
        case .installer, .start:
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

    private func askBeforeClosingRunningVM() -> RunningVMCloseAction {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 210),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "VM Running"
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "exclamationmark.triangle",
            accessibilityDescription: "Warning"
        ) ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        icon.contentTintColor = .systemYellow

        let titleLabel = NSTextField(labelWithString: "The VM is still running")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        let detailLabel = NSTextField(wrappingLabelWithString: """
        Closing Okrun while the VM is running can stop guest services abruptly and may risk disk consistency.

        Shutdown the VM first, keep Okrun running, or close anyway.
        """)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 8

        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        let shutdownButton = NSButton(title: "Shutdown VM", target: nil, action: nil)
        let closeAnywayButton = NSButton(title: "Close Anyway", target: nil, action: nil)

        cancelButton.bezelStyle = .rounded
        shutdownButton.bezelStyle = .rounded
        closeAnywayButton.bezelStyle = .rounded
        shutdownButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [cancelButton, spacer, shutdownButton, closeAnywayButton])
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        content.addSubview(icon)
        content.addSubview(textStack)
        content.addSubview(buttonRow)
        panel.contentView = content

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),

            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            textStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            textStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),

            buttonRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 20)
        ])

        cancelButton.action = #selector(CloseAlertButtonHandler.cancel)
        shutdownButton.action = #selector(CloseAlertButtonHandler.shutdown)
        closeAnywayButton.action = #selector(CloseAlertButtonHandler.closeAnyway)

        let handler = CloseAlertButtonHandler()
        cancelButton.target = handler
        shutdownButton.target = handler
        closeAnywayButton.target = handler
        closeAlertHandler = handler

        panel.center()
        if let window {
            panel.setFrameOrigin(NSPoint(
                x: window.frame.midX - panel.frame.width / 2,
                y: window.frame.midY - panel.frame.height / 2
            ))
        }

        let response = NSApp.runModal(for: panel)
        panel.close()
        closeAlertHandler = nil

        switch response {
        case .alertFirstButtonReturn:
            return .stop
        case .alertSecondButtonReturn:
            return .closeAnyway
        default:
            return .cancel
        }
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
                privateNetwork: vmConfig.privateNetwork,
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
                PrivateNetworkRuntimeRegistry.shared.releaseAll()
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
                        self?.setControlsEnabled(canStart: false, canStop: true)
                        self?.setStatus("Running", detail: self?.runtimeDetail("Mode: \(modeText)") ?? "")
                    case .failure(let error):
                        self?.releaseProjectLock()
                        PrivateNetworkRuntimeRegistry.shared.releaseAll()
                        self?.virtualMachine = nil
                        self?.vmView.virtualMachine = nil
                        self?.setControlsEnabled(canStart: true, canStop: false)
                        self?.setStatus("Start failed", detail: error.localizedDescription)
                    }
                }
            }
        } catch {
            releaseProjectLock()
            PrivateNetworkRuntimeRegistry.shared.releaseAll()
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
        configuration.networkDevices = try NetworkDeviceFactory.makeDevices(privateNetwork: config.privateNetwork)
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
            PrivateNetworkRuntimeRegistry.shared.releaseAll()
            self?.virtualMachine = nil
            self?.vmView.virtualMachine = nil
            self?.setControlsEnabled(canStart: true, canStop: false)
            self?.setStatus("Shutdown", detail: "The VM has shut down.")
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.releaseProjectLock()
            PrivateNetworkRuntimeRegistry.shared.releaseAll()
            self?.virtualMachine = nil
            self?.vmView.virtualMachine = nil
            self?.setControlsEnabled(canStart: true, canStop: false)
            self?.setStatus("Stopped with error", detail: error.localizedDescription)
        }
    }
}
