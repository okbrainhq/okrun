import AppKit
import Darwin
import Virtualization

private final class RoundedContainerView: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.borderWidth = 0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class TabRailView: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1).cgColor
        layer?.borderWidth = 0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private class HoverIconButton: NSButton {
    var normalTint = NSColor.secondaryLabelColor {
        didSet { updateAppearance() }
    }
    var disabledTint = NSColor.secondaryLabelColor.withAlphaComponent(0.35) {
        didSet { updateAppearance() }
    }
    var hoverBackground = NSColor.white.withAlphaComponent(0.10)
    private var isHovering = false
    private var trackingAreaRef: NSTrackingArea?

    init(symbolName: String, label: String, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        setAccessibilityLabel(label)
        translatesAutoresizingMaskIntoConstraints = false
        bezelStyle = .regularSquare
        isBordered = false
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        image?.isTemplate = true
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        toolTip = label
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsetsZero
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateAppearance()
    }

    private func updateAppearance() {
        contentTintColor = isEnabled ? normalTint : disabledTint
        layer?.backgroundColor = isHovering && isEnabled ? hoverBackground.cgColor : NSColor.clear.cgColor
    }
}

private enum RunningVMCloseAction {
    case shutdown
    case forceQuit
    case cancel
}

private final class CloseAlertButtonHandler: NSObject {
    @objc func shutdown() {
        NSApp.stopModal(withCode: .alertFirstButtonReturn)
    }

    @objc func forceQuit() {
        NSApp.stopModal(withCode: .alertSecondButtonReturn)
    }

    @objc func cancel() {
        NSApp.stopModal(withCode: .alertThirdButtonReturn)
    }
}

private final class DeleteConfirmationActions: NSObject, NSTextFieldDelegate {
    let expectedName: String
    weak var panel: NSPanel?
    weak var deleteButton: NSButton?
    var confirmed = false

    init(expectedName: String) {
        self.expectedName = expectedName
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let textField = notification.object as? NSTextField else { return }
        deleteButton?.isEnabled = textField.stringValue == expectedName
    }

    @objc func delete() {
        confirmed = true
        panel?.close()
        NSApp.stopModal()
    }

    @objc func cancel() {
        panel?.close()
        NSApp.stopModal()
    }
}

private final class VMTabSession {
    let id = UUID()
    let projectPath: String
    let paths: VMPaths
    let vmView = VZVirtualMachineView()

    var config: VMConfig
    var virtualMachine: VZVirtualMachine?
    var fakeRunning = false
    var shutdownRequested = false
    var projectLockFD: Int32?
    var privateNetworkRuntimes: [PrivateNetworkRuntime] = []
    var canStartControls = true
    var canStopControls = false
    var status = "Ready"
    var detail = ""
    weak var tabButton: VMTabItemView?

    init(projectPath: String, paths: VMPaths, config: VMConfig) {
        self.projectPath = projectPath
        self.paths = paths
        self.config = config
        vmView.translatesAutoresizingMaskIntoConstraints = false
        vmView.capturesSystemKeys = true
    }

    var title: String {
        let url = URL(fileURLWithPath: projectPath, isDirectory: true)
        let lastPathComponent = url.lastPathComponent
        return lastPathComponent.isEmpty ? projectPath : lastPathComponent
    }

    var isRunning: Bool {
        virtualMachine != nil || fakeRunning
    }
}

private final class VMTabActionButton: HoverIconButton {
    let sessionID: UUID

    init(sessionID: UUID, symbolName: String, label: String, target: AnyObject?, action: Selector) {
        self.sessionID = sessionID
        super.init(symbolName: symbolName, label: label, target: target, action: action)
        normalTint = NSColor.white.withAlphaComponent(0.72)
        disabledTint = NSColor.white.withAlphaComponent(0.32)
        hoverBackground = NSColor.white.withAlphaComponent(0.16)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class VMTabItemView: NSControl {
    let sessionID: UUID
    private let numberBadge = NSView()
    private let numberLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let settingsButton: VMTabActionButton
    private let deleteButton: VMTabActionButton
    private static let activeColor = NSColor(calibratedRed: 0.02, green: 0.48, blue: 0.95, alpha: 1)

    init(
        sessionID: UUID,
        index: Int,
        title: String,
        target: AnyObject?,
        action: Selector,
        settingsTarget: AnyObject?,
        settingsAction: Selector,
        deleteTarget: AnyObject?,
        deleteAction: Selector
    ) {
        self.sessionID = sessionID
        settingsButton = VMTabActionButton(
            sessionID: sessionID,
            symbolName: "gearshape",
            label: "Edit VM Config",
            target: settingsTarget,
            action: settingsAction
        )
        deleteButton = VMTabActionButton(
            sessionID: sessionID,
            symbolName: "trash",
            label: "Delete VM",
            target: deleteTarget,
            action: deleteAction
        )
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityIdentifier("okrun.vm-tab.item")
        settingsButton.setAccessibilityIdentifier("okrun.vm-tab.settings")
        deleteButton.setAccessibilityIdentifier("okrun.vm-tab.delete")
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.masksToBounds = true

        numberBadge.translatesAutoresizingMaskIntoConstraints = false
        numberBadge.wantsLayer = true
        numberBadge.layer?.cornerRadius = 10
        numberBadge.layer?.backgroundColor = NSColor(calibratedWhite: 0.23, alpha: 1).cgColor

        numberLabel.stringValue = "\(index)"
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        numberLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        numberLabel.textColor = .secondaryLabelColor
        numberLabel.alignment = .center

        titleLabel.stringValue = title
        titleLabel.setAccessibilityIdentifier("okrun.vm-tab.title")
        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        statusLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1

        let textStack = NSStackView(views: [titleLabel, statusLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3

        let actionStack = NSStackView(views: [settingsButton, deleteButton])
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = 2

        numberBadge.addSubview(numberLabel)
        addSubview(numberBadge)
        addSubview(textStack)
        addSubview(actionStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 62),
            numberBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            numberBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            numberBadge.widthAnchor.constraint(equalToConstant: 20),
            numberBadge.heightAnchor.constraint(equalToConstant: 20),
            numberLabel.leadingAnchor.constraint(equalTo: numberBadge.leadingAnchor),
            numberLabel.trailingAnchor.constraint(equalTo: numberBadge.trailingAnchor),
            numberLabel.centerYAnchor.constraint(equalTo: numberBadge.centerYAnchor),
            textStack.leadingAnchor.constraint(equalTo: numberBadge.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: actionStack.leadingAnchor, constant: -8),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actionStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    func update(status: String, isRunning: Bool, isSelected: Bool) {
        statusLabel.stringValue = status
        layer?.backgroundColor = isSelected ? Self.activeColor.cgColor : NSColor.clear.cgColor
        titleLabel.textColor = isSelected ? .white : .labelColor
        statusLabel.textColor = isSelected ? NSColor.white.withAlphaComponent(0.88) : .secondaryLabelColor
        settingsButton.isHidden = !isSelected
        settingsButton.isEnabled = isSelected && !isRunning
        deleteButton.isHidden = !isSelected
        deleteButton.isEnabled = isSelected && !isRunning

        let badgeColor: NSColor
        if isRunning {
            badgeColor = isSelected ? NSColor.white.withAlphaComponent(0.24) : .systemGreen
        } else if status.localizedCaseInsensitiveContains("failed") || status.localizedCaseInsensitiveContains("error") {
            badgeColor = isSelected ? NSColor.white.withAlphaComponent(0.24) : .systemRed
        } else {
            badgeColor = isSelected ? NSColor.white.withAlphaComponent(0.24) : NSColor(calibratedWhite: 0.23, alpha: 1)
        }
        numberBadge.layer?.backgroundColor = badgeColor.cgColor
        numberLabel.textColor = isSelected ? .white : .secondaryLabelColor
    }
}


final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, VZVirtualMachineDelegate {
    private var window: NSWindow!
    private var statusLabel = NSTextField(labelWithString: "Preparing")
    private var detailsLabel = NSTextField(labelWithString: "")
    private var vmContainer: RoundedContainerView!
    private var tabStack: NSStackView!
    private var emptyStateLabel = NSTextField(labelWithString: "Add or import a VM to begin.")
    private var installerButton: NSButton!
    private var startButton: NSButton!
    private var shutdownButton: NSButton!
    private var networkButton: NSButton!
    private let projectStore = ProjectStore()
    private var registry = ProjectRegistry.empty
    private var sessions: [VMTabSession] = []
    private var selectedSessionID: UUID?
    private var isClosingAnyway = false
    private var terminateAfterVMsStop = false
    private var closeWindowAfterVMsStop = false
    private var closeAlertHandler: CloseAlertButtonHandler?
    private var skipAutomaticStartAfterCreate: Bool {
        ProcessInfo.processInfo.environment["OKRUN_UI_E2E_SKIP_AUTOSTART"] == "1"
    }
    private var usesFakeVMBackend: Bool {
        ProcessInfo.processInfo.environment["OKRUN_UI_E2E_FAKE_VM_BACKEND"] == "1"
    }
    private var enablesUITestCommands: Bool {
        ProcessInfo.processInfo.environment["OKRUN_UI_E2E_TEST_COMMANDS"] == "1"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installAppIcon()
        buildWindow()
        installMainMenu()
        AppLog.lifecycle.info(
            "Launching OkrunVM pid=\(getpid()) bundle=\(Bundle.main.bundleURL.path, privacy: .public) executable=\(Bundle.main.executableURL?.path ?? "unknown", privacy: .public)"
        )

        do {
            registry = try projectStore.load(defaultProject: ProjectStore.defaultProjectRoot())
            try reloadSessionsFromRegistry()
        } catch {
            setStatus("Setup failed", detail: error.localizedDescription)
            window?.toolbar?.validateVisibleItems()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard hasRunningVMs, !isClosingAnyway else {
            return .terminateNow
        }

        switch askBeforeClosingRunningVM() {
        case .shutdown:
            return beginShutdownBeforeTermination()
        case .forceQuit:
            return beginForceStopBeforeTermination()
        case .cancel:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        for session in sessions {
            releaseProjectLock(for: session)
            releasePrivateNetworkRuntimes(for: session)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window.makeKeyAndOrderFront(nil)
        }

        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasRunningVMs, !isClosingAnyway else {
            return true
        }

        switch askBeforeClosingRunningVM() {
        case .shutdown:
            beginShutdownBeforeWindowClose()
            return false
        case .forceQuit:
            beginForceStopBeforeWindowClose()
            return false
        case .cancel:
            return false
        }
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        let candidateFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? newFrame
        guard candidateFrame.width >= window.minSize.width,
              candidateFrame.height >= window.minSize.height else {
            var fallbackFrame = window.frame
            fallbackFrame.origin.x = min(fallbackFrame.origin.x, candidateFrame.origin.x)
            fallbackFrame.size.width = max(fallbackFrame.width, candidateFrame.width, window.minSize.width)
            fallbackFrame.size.height = max(fallbackFrame.height, window.minSize.height)
            return fallbackFrame
        }

        return candidateFrame
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
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.065, alpha: 1).cgColor

        let root = NSStackView()
        root.orientation = .horizontal
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false

        let mainPane = NSStackView()
        mainPane.orientation = .vertical
        mainPane.spacing = 0
        mainPane.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        statusLabel.setAccessibilityIdentifier("okrun.status")
        statusLabel.alignment = .left
        detailsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailsLabel.setAccessibilityIdentifier("okrun.status-detail")
        detailsLabel.textColor = .secondaryLabelColor
        detailsLabel.lineBreakMode = .byTruncatingMiddle
        detailsLabel.maximumNumberOfLines = 1
        detailsLabel.alignment = .left
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let detailRow = NSStackView()
        detailRow.orientation = .horizontal
        detailRow.alignment = .firstBaseline
        detailRow.spacing = 10
        detailRow.translatesAutoresizingMaskIntoConstraints = false
        detailRow.addArrangedSubview(statusLabel)
        detailRow.addArrangedSubview(detailsLabel)

        installerButton = makeContextButton(label: "Boot Installer", symbolName: "opticaldiscdrive", action: #selector(startInstaller))
        startButton = makeContextButton(label: "Start", symbolName: "play.fill", action: #selector(startInstalled))
        shutdownButton = makeContextButton(label: "Shutdown", symbolName: "stop.fill", action: #selector(shutdownVM))

        let actionRow = NSStackView(views: [installerButton, startButton, shutdownButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8
        actionRow.translatesAutoresizingMaskIntoConstraints = false

        let statusSpacer = NSView()
        statusSpacer.translatesAutoresizingMaskIntoConstraints = false
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let statusRow = NSStackView(views: [detailRow, statusSpacer, actionRow])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 12
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        let statusContainer = NSView()
        statusContainer.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.wantsLayer = true
        statusContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1).cgColor
        statusContainer.addSubview(statusRow)

        vmContainer = RoundedContainerView()

        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.setAccessibilityIdentifier("okrun.empty-state")
        emptyStateLabel.font = .systemFont(ofSize: 15, weight: .medium)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.alignment = .center
        vmContainer.addSubview(emptyStateLabel)

        let tabPanel = TabRailView()
        tabPanel.setContentHuggingPriority(.required, for: .horizontal)
        tabPanel.setContentCompressionResistancePriority(.required, for: .horizontal)
        mainPane.setContentHuggingPriority(.defaultLow, for: .horizontal)
        mainPane.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        networkButton = makeSidebarNetworkButton()
        let sidebarNewButton = makeSidebarNewVMButton()
        let sidebarImportButton = makeSidebarImportVMButton()
        let sidebarHeader = NSView()
        sidebarHeader.translatesAutoresizingMaskIntoConstraints = false
        let sidebarActionStack = NSStackView(views: [sidebarNewButton, sidebarImportButton, networkButton])
        sidebarActionStack.translatesAutoresizingMaskIntoConstraints = false
        sidebarActionStack.orientation = .horizontal
        sidebarActionStack.alignment = .centerY
        sidebarActionStack.spacing = 8

        tabStack = NSStackView()
        tabStack.orientation = .vertical
        tabStack.alignment = .leading
        tabStack.spacing = 0
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        sidebarHeader.addSubview(sidebarActionStack)
        tabPanel.addSubview(sidebarHeader)
        tabPanel.addSubview(tabStack)

        mainPane.addArrangedSubview(statusContainer)
        mainPane.addArrangedSubview(vmContainer)

        let splitSeparator = NSView()
        splitSeparator.translatesAutoresizingMaskIntoConstraints = false
        splitSeparator.wantsLayer = true
        splitSeparator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.13).cgColor

        root.addArrangedSubview(tabPanel)
        root.addArrangedSubview(splitSeparator)
        root.addArrangedSubview(mainPane)
        content.addSubview(root)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 1040, height: 560)
        window.center()
        window.title = "Okrun VM"
        window.backgroundColor = NSColor(calibratedWhite: 0.065, alpha: 1)
        window.contentView = content
        window.delegate = self

        let contentTopAnchor = (window.contentLayoutGuide as? NSLayoutGuide)?.topAnchor ?? content.safeAreaLayoutGuide.topAnchor
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentTopAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusContainer.heightAnchor.constraint(equalToConstant: 34),
            statusRow.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor, constant: 12),
            statusRow.trailingAnchor.constraint(equalTo: statusContainer.trailingAnchor, constant: -12),
            statusRow.topAnchor.constraint(equalTo: statusContainer.topAnchor, constant: 4),
            statusRow.bottomAnchor.constraint(equalTo: statusContainer.bottomAnchor, constant: -4),
            vmContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 720),
            vmContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 420),
            emptyStateLabel.centerXAnchor.constraint(equalTo: vmContainer.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: vmContainer.centerYAnchor),
            tabPanel.widthAnchor.constraint(equalToConstant: 304),
            splitSeparator.widthAnchor.constraint(equalToConstant: 1),
            sidebarHeader.leadingAnchor.constraint(equalTo: tabPanel.leadingAnchor),
            sidebarHeader.trailingAnchor.constraint(equalTo: tabPanel.trailingAnchor),
            sidebarHeader.topAnchor.constraint(equalTo: tabPanel.topAnchor),
            sidebarHeader.heightAnchor.constraint(equalToConstant: 46),
            sidebarActionStack.trailingAnchor.constraint(equalTo: sidebarHeader.trailingAnchor, constant: -12),
            sidebarActionStack.centerYAnchor.constraint(equalTo: sidebarHeader.centerYAnchor),
            sidebarActionStack.heightAnchor.constraint(equalToConstant: 26),
            sidebarNewButton.topAnchor.constraint(equalTo: sidebarActionStack.topAnchor),
            sidebarNewButton.bottomAnchor.constraint(equalTo: sidebarActionStack.bottomAnchor),
            sidebarImportButton.topAnchor.constraint(equalTo: sidebarActionStack.topAnchor),
            sidebarImportButton.bottomAnchor.constraint(equalTo: sidebarActionStack.bottomAnchor),
            networkButton.topAnchor.constraint(equalTo: sidebarActionStack.topAnchor),
            networkButton.bottomAnchor.constraint(equalTo: sidebarActionStack.bottomAnchor),
            tabStack.leadingAnchor.constraint(equalTo: tabPanel.leadingAnchor),
            tabStack.trailingAnchor.constraint(equalTo: tabPanel.trailingAnchor),
            tabStack.topAnchor.constraint(equalTo: sidebarHeader.bottomAnchor),
            tabStack.bottomAnchor.constraint(equalTo: tabPanel.bottomAnchor)
        ])

        window.makeKeyAndOrderFront(nil)

        window?.toolbar?.validateVisibleItems()
        updateContextControls()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)

        let appMenu = NSMenu(title: "Okrun VM")
        appMenu.addItem(NSMenuItem(title: "Quit Okrun VM", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        let addItem = NSMenuItem(title: "Add VM", action: #selector(createProject), keyEquivalent: "n")
        addItem.target = self
        fileMenu.addItem(addItem)
        let importItem = NSMenuItem(title: "Import VM...", action: #selector(importProject), keyEquivalent: "i")
        importItem.target = self
        fileMenu.addItem(importItem)
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu

        let vmItem = NSMenuItem()
        mainMenu.addItem(vmItem)

        let vmMenu = NSMenu(title: "VM")
        let editConfigItem = NSMenuItem(title: "Edit VM Config", action: #selector(openSelectedConfigEditor), keyEquivalent: ",")
        editConfigItem.target = self
        vmMenu.addItem(editConfigItem)

        let deleteItem = NSMenuItem(title: "Delete VM", action: #selector(deleteProject), keyEquivalent: "")
        deleteItem.target = self
        vmMenu.addItem(deleteItem)

        if enablesUITestCommands {
            vmMenu.addItem(.separator())

            let selectFirstItem = NSMenuItem(title: "Select First VM", action: #selector(selectFirstVMForUITest), keyEquivalent: "")
            selectFirstItem.target = self
            vmMenu.addItem(selectFirstItem)

            let selectLastItem = NSMenuItem(title: "Select Last VM", action: #selector(selectLastVMForUITest), keyEquivalent: "")
            selectLastItem.target = self
            vmMenu.addItem(selectLastItem)

            let zoomItem = NSMenuItem(title: "Zoom Window", action: #selector(zoomWindowForUITest), keyEquivalent: "")
            zoomItem.target = self
            vmMenu.addItem(zoomItem)
        }

        vmItem.submenu = vmMenu
        NSApp.mainMenu = mainMenu
    }

    private func makeContextButton(label: String, symbolName: String, action: Selector) -> NSButton {
        let button = HoverIconButton(symbolName: symbolName, label: label, target: self, action: action)
        button.setAccessibilityIdentifier("okrun.context.\(label.lowercased().replacingOccurrences(of: " ", with: "-"))")
        button.normalTint = .secondaryLabelColor
        button.disabledTint = NSColor.secondaryLabelColor.withAlphaComponent(0.35)
        button.hoverBackground = NSColor.white.withAlphaComponent(0.10)
        return button
    }

    private func makeSidebarNewVMButton() -> NSButton {
        let button = HoverIconButton(symbolName: "plus", label: "New VM", target: self, action: #selector(createProject))
        button.setAccessibilityIdentifier("okrun.new-vm")
        button.normalTint = .labelColor
        button.disabledTint = NSColor.labelColor.withAlphaComponent(0.35)
        button.hoverBackground = NSColor.white.withAlphaComponent(0.12)
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        return button
    }

    private func makeSidebarImportVMButton() -> NSButton {
        let button = HoverIconButton(symbolName: "arrow.down.square", label: "Import VM", target: self, action: #selector(importProject))
        button.setAccessibilityIdentifier("okrun.import-vm")
        button.normalTint = .labelColor
        button.disabledTint = NSColor.labelColor.withAlphaComponent(0.35)
        button.hoverBackground = NSColor.white.withAlphaComponent(0.12)
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        return button
    }

    private func makeSidebarNetworkButton() -> NSButton {
        let button = HoverIconButton(symbolName: "network", label: "Private Network", target: self, action: #selector(openNetworkConfig))
        button.setAccessibilityIdentifier("okrun.network-config")
        button.normalTint = .labelColor
        button.disabledTint = NSColor.labelColor.withAlphaComponent(0.35)
        button.hoverBackground = NSColor.white.withAlphaComponent(0.12)
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        return button
    }

    private func updateContextControls() {
        installerButton?.isEnabled = selectedSession?.canStartControls == true
        startButton?.isEnabled = selectedSession?.canStartControls == true
        shutdownButton?.isEnabled = selectedSession?.canStopControls == true
    }

    private var selectedSession: VMTabSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    private var hasRunningVMs: Bool {
        sessions.contains { $0.isRunning }
    }

    private func reloadSessionsFromRegistry() throws {
        sessions.removeAll()

        for project in registry.projects {
            let projectURL = URL(fileURLWithPath: project, isDirectory: true)
            let paths = VMPaths.project(at: projectURL)
            let config = try VMConfig.load(from: paths.config)
            let session = VMTabSession(projectPath: project, paths: paths, config: config)
            session.status = "Ready"
            session.detail = statusDetail(paths: paths, config: config)
            sessions.append(session)
            AppLog.lifecycle.info(
                "Loaded VM tab path=\(paths.root.path, privacy: .public) cpu=\(config.cpuCount) memoryGB=\(config.memoryGB) diskGB=\(config.diskGB) privateNetwork=\(config.privateNetwork.enabled) sharedDirectories=\(config.sharedDirectories.count)"
            )
        }

        if let selected = registry.selectedProject,
           let session = sessions.first(where: { $0.projectPath == selected }) {
            selectedSessionID = session.id
        } else {
            selectedSessionID = sessions.first?.id
            registry.selectedProject = sessions.first?.projectPath
            try projectStore.save(registry)
        }

        rebuildTabButtons()
        showSelectedSession()
    }

    private func rebuildTabButtons() {
        for view in tabStack.arrangedSubviews {
            tabStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for (index, session) in sessions.enumerated() {
            let button = VMTabItemView(
                sessionID: session.id,
                index: index + 1,
                title: session.title,
                target: self,
                action: #selector(tabButtonPressed(_:)),
                settingsTarget: self,
                settingsAction: #selector(settingsTabButtonPressed(_:)),
                deleteTarget: self,
                deleteAction: #selector(deleteTabButtonPressed(_:))
            )
            button.toolTip = session.projectPath
            session.tabButton = button
            tabStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: tabStack.widthAnchor).isActive = true
        }

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        tabStack.addArrangedSubview(spacer)
        spacer.widthAnchor.constraint(equalTo: tabStack.widthAnchor).isActive = true
        updateTabButtonState()
    }

    private func updateTabButtonState() {
        for session in sessions {
            let isSelected = session.id == selectedSessionID
            session.tabButton?.update(status: session.status, isRunning: session.isRunning, isSelected: isSelected)
        }
    }

    private func showSelectedSession() {
        for subview in vmContainer.subviews where subview !== emptyStateLabel {
            subview.removeFromSuperview()
        }

        guard let session = selectedSession else {
            emptyStateLabel.isHidden = false
            setStatus("No VM selected", detail: "Add or import a VM to create a new tab.")
            window?.toolbar?.validateVisibleItems()
            updateContextControls()
            updateTabButtonState()
            return
        }

        emptyStateLabel.isHidden = true
        vmContainer.addSubview(session.vmView)
        NSLayoutConstraint.activate([
            session.vmView.leadingAnchor.constraint(equalTo: vmContainer.leadingAnchor),
            session.vmView.trailingAnchor.constraint(equalTo: vmContainer.trailingAnchor),
            session.vmView.topAnchor.constraint(equalTo: vmContainer.topAnchor),
            session.vmView.bottomAnchor.constraint(equalTo: vmContainer.bottomAnchor)
        ])
        setStatus(session.status, detail: session.detail)
        window?.toolbar?.validateVisibleItems()
        updateContextControls()
        updateTabButtonState()
    }

    private func selectSession(_ session: VMTabSession) {
        selectedSessionID = session.id
        registry.selectedProject = session.projectPath
        try? projectStore.save(registry)
        showSelectedSession()
    }

    @objc private func tabButtonPressed(_ sender: VMTabItemView) {
        guard let session = sessions.first(where: { $0.id == sender.sessionID }) else { return }
        selectSession(session)
    }

    @objc private func deleteTabButtonPressed(_ sender: NSButton) {
        guard let sender = sender as? VMTabActionButton,
              let session = sessions.first(where: { $0.id == sender.sessionID }) else {
            return
        }

        selectSession(session)
        deleteProject()
    }

    @objc private func settingsTabButtonPressed(_ sender: NSButton) {
        guard let sender = sender as? VMTabActionButton,
              let session = sessions.first(where: { $0.id == sender.sessionID }),
              session.virtualMachine == nil else {
            return
        }

        selectSession(session)
        openConfigEditor(for: session)
    }

    @objc private func openSelectedConfigEditor() {
        guard let session = selectedSession, !session.isRunning else { return }
        openConfigEditor(for: session)
    }

    @objc private func selectFirstVMForUITest() {
        guard let session = sessions.first else { return }
        selectSession(session)
    }

    @objc private func selectLastVMForUITest() {
        guard let session = sessions.last else { return }
        selectSession(session)
    }

    @objc private func zoomWindowForUITest() {
        window?.zoom(nil)
    }

    @objc private func createProject() {
        guard let request = askForNewProject() else { return }

        do {
            try FileManager.default.createDirectory(at: request.projectURL, withIntermediateDirectories: true)
            let paths = VMPaths.project(at: request.projectURL)
            try request.config.save(to: paths.config)
            try provisionPrivateNetworkDHCPIfNeeded(for: request.config)
            _ = try prepareStorage(paths: paths, config: request.config)
            AppLog.lifecycle.info(
                "Created project path=\(paths.root.path, privacy: .public) cpu=\(request.config.cpuCount) memoryGB=\(request.config.memoryGB) diskGB=\(request.config.diskGB)"
            )

            let path = projectStore.standardPath(request.projectURL)
            if !registry.projects.contains(path) {
                registry.projects.append(path)
            }
            registry.selectedProject = path
            try projectStore.save(registry)
            let session = VMTabSession(projectPath: path, paths: paths, config: request.config)
            session.status = "Ready"
            session.detail = statusDetail(paths: paths, config: request.config)
            sessions.append(session)
            rebuildTabButtons()
            selectSession(session)
            if skipAutomaticStartAfterCreate {
                setStatus(for: session, status: "Ready", detail: statusDetail(paths: paths, config: request.config))
            } else {
                start(mode: .installer(request.isoURL))
            }
        } catch {
            setStatus("Add project failed", detail: error.localizedDescription)
            selectedSession?.status = "Add project failed"
            selectedSession?.detail = error.localizedDescription
            window?.toolbar?.validateVisibleItems()
        }
    }

    @objc private func importProject() {
        guard let request = askForASIFImport() else { return }
        setStatus("Importing VM", detail: "Copying \(request.sourceURL.path) to \(request.destinationURL.path)")
        window?.displayIfNeeded()

        let result: ASIFImportResult
        do {
            result = try ASIFImporter.importDisk(request: ASIFImportRequest(
                sourceURL: request.sourceURL,
                destinationURL: request.destinationURL,
                config: request.config
            ))
            try provisionPrivateNetworkDHCPIfNeeded(for: result.config)
        } catch {
            setStatus("Import failed", detail: error.localizedDescription)
            selectedSession?.status = "Import failed"
            selectedSession?.detail = error.localizedDescription
            window?.toolbar?.validateVisibleItems()
            return
        }

        do {
            let path = projectStore.standardPath(result.projectURL)
            if !registry.projects.contains(path) {
                registry.projects.append(path)
            }
            registry.selectedProject = path
            try projectStore.save(registry)

            let paths = VMPaths.project(at: result.projectURL)
            let session = VMTabSession(projectPath: path, paths: paths, config: result.config)
            session.status = "Ready"
            session.detail = importStatusDetail(result: result)
            sessions.append(session)
            rebuildTabButtons()
            selectSession(session)
            AppLog.lifecycle.info(
                "Imported ASIF project path=\(paths.root.path, privacy: .public) source=\(result.sourceURL.path, privacy: .public) diskGB=\(result.diskGB)"
            )
        } catch {
            setStatus("Import saved, registry failed", detail: "Project exists at \(result.projectURL.path). \(error.localizedDescription)")
            window?.toolbar?.validateVisibleItems()
        }
    }

    @objc private func deleteProject() {
        guard let session = selectedSession, session.virtualMachine == nil else { return }
        let selectedProject = session.projectPath

        guard confirmDelete(session: session) else { return }

        do {
            AppLog.lifecycle.warning("Deleting project path=\(selectedProject, privacy: .public)")
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: selectedProject) {
                try fileManager.removeItem(atPath: selectedProject)
            }

            registry.projects.removeAll { $0 == selectedProject }
            registry.selectedProject = registry.projects.first
            try projectStore.save(registry)
            sessions.removeAll { $0.id == session.id }
            selectedSessionID = sessions.first { $0.projectPath == registry.selectedProject }?.id ?? sessions.first?.id
            rebuildTabButtons()
            showSelectedSession()
        } catch {
            setStatus("Delete failed", detail: error.localizedDescription)
            session.status = "Delete failed"
            session.detail = error.localizedDescription
            window?.toolbar?.validateVisibleItems()
        }
    }

    private func confirmDelete(session: VMTabSession) -> Bool {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 310),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Delete VM"
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel
        panel.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Warning"
        ) ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 32, weight: .regular)
        icon.contentTintColor = .systemYellow

        let title = NSTextField(labelWithString: "Delete \(session.title)?")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 18, weight: .semibold)

        let path = NSTextField(labelWithString: session.projectPath)
        path.translatesAutoresizingMaskIntoConstraints = false
        path.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle

        let message = NSTextField(wrappingLabelWithString: "This permanently deletes the VM disk, EFI state, machine identifier, and project config.")
        message.translatesAutoresizingMaskIntoConstraints = false
        message.font = .systemFont(ofSize: 13)
        message.textColor = .secondaryLabelColor

        let prompt = NSTextField(labelWithString: "Type \(session.title) to confirm.")
        prompt.translatesAutoresizingMaskIntoConstraints = false
        prompt.font = .systemFont(ofSize: 12, weight: .medium)

        let textField = NSTextField(string: "")
        textField.setAccessibilityIdentifier("okrun.delete.confirm-name")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.placeholderString = session.title
        textField.font = .systemFont(ofSize: 13)

        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.setAccessibilityIdentifier("okrun.delete.cancel")
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .large
        cancelButton.keyEquivalent = "\u{1b}"

        let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
        deleteButton.setAccessibilityIdentifier("okrun.delete.confirm")
        deleteButton.bezelStyle = .rounded
        deleteButton.controlSize = .large
        deleteButton.keyEquivalent = "\r"
        deleteButton.isEnabled = false

        let buttonRow = NSStackView(views: [cancelButton, deleteButton])
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 12

        let actions = DeleteConfirmationActions(expectedName: session.title)
        actions.panel = panel
        actions.deleteButton = deleteButton
        textField.delegate = actions
        cancelButton.target = actions
        cancelButton.action = #selector(DeleteConfirmationActions.cancel)
        deleteButton.target = actions
        deleteButton.action = #selector(DeleteConfirmationActions.delete)

        content.addSubview(icon)
        content.addSubview(title)
        content.addSubview(path)
        content.addSubview(message)
        content.addSubview(prompt)
        content.addSubview(textField)
        content.addSubview(buttonRow)
        panel.contentView = content

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
            path.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            path.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            path.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            message.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            message.topAnchor.constraint(equalTo: path.bottomAnchor, constant: 12),
            prompt.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            prompt.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            prompt.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 18),
            textField.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            textField.topAnchor.constraint(equalTo: prompt.bottomAnchor, constant: 8),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            cancelButton.widthAnchor.constraint(equalToConstant: 110),
            deleteButton.widthAnchor.constraint(equalToConstant: 110)
        ])

        if let window {
            panel.setFrameOrigin(NSPoint(
                x: window.frame.midX - panel.frame.width / 2,
                y: window.frame.midY - panel.frame.height / 2
            ))
        } else {
            panel.center()
        }

        NSApp.runModal(for: panel)
        _ = actions
        return actions.confirmed
    }

    private func openConfigEditor(for session: VMTabSession) {
        if let logPath = ProcessInfo.processInfo.environment["OKRUN_UI_E2E_CONFIG_OPEN_LOG"], !logPath.isEmpty {
            let logURL = URL(fileURLWithPath: logPath)
            do {
                try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try session.paths.config.path.write(to: logURL, atomically: true, encoding: .utf8)
            } catch {
                setStatus(for: session, status: "Config open failed", detail: error.localizedDescription)
            }
            return
        }

        guard NSWorkspace.shared.open(session.paths.config) else {
            setStatus(for: session, status: "Config open failed", detail: session.paths.config.path)
            return
        }
    }

    private func loadAndPrepareConfiguration(paths: VMPaths) throws -> (
        config: VMConfig,
        preparation: VMStorage.PreparationResult
    ) {
        let config = try VMConfig.load(from: paths.config)
        let preparation = try prepareStorage(paths: paths, config: config)
        return (config, preparation)
    }

    private func reloadConfiguration(for session: VMTabSession) throws -> (
        config: VMConfig,
        preparation: VMStorage.PreparationResult
    ) {
        let loaded = try loadAndPrepareConfiguration(paths: session.paths)
        session.config = loaded.config
        return loaded
    }

    private func prepareStorage(paths: VMPaths, config: VMConfig) throws -> VMStorage.PreparationResult {
        try VMStorage.prepare(paths: paths, config: config)
    }

    private func statusDetail(
        paths: VMPaths,
        config: VMConfig,
        preparation: VMStorage.PreparationResult? = nil
    ) -> String {
        var detail = "\(paths.root.path)  |  CPU \(config.cpuCount)  Memory \(config.memoryGB) GB  Disk \(config.diskGB) GB \(config.diskFormat.displayName)"

        if preparation?.expandedDisk == true {
            detail += "  |  Disk image expanded; grow the Linux partition/filesystem inside the guest."
        }

        if let hostAvailableBytes = preparation?.hostAvailableBytes,
           preparation?.hasLowHostFreeSpace == true {
            let freeSpace = ByteCountFormatter.string(fromByteCount: Int64(hostAvailableBytes), countStyle: .file)
            detail += "  |  Host volume low: \(freeSpace) free."
        }

        return detail
    }

    private func importStatusDetail(result: ASIFImportResult) -> String {
        var detail = "\(result.projectURL.path)  |  Imported \(result.sourceURL.path)  |  CPU \(result.config.cpuCount)  Memory \(result.config.memoryGB) GB  Disk \(result.diskGB) GB ASIF"
        if result.roundedDiskSizeUp {
            detail += "  |  Disk size rounded up to the next GiB."
        }
        detail += "  |  Fresh EFI store generated."
        return detail
    }

    private func runtimeDetail(_ status: String) -> String {
        guard let session = selectedSession else { return status }
        return runtimeDetail(for: session, status)
    }

    private func runtimeDetail(for session: VMTabSession, _ status: String) -> String {
        "\(status)  |  \(statusDetail(paths: session.paths, config: session.config))"
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

        let titleLabel = NSTextField(labelWithString: "One or more VMs are still running")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        let detailLabel = NSTextField(wrappingLabelWithString: """
        Closing Okrun before Linux shuts down cleanly can corrupt the guest disk.

        Ask Linux to shut down, keep Okrun running, or force quit only if the VM is stuck.
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
        let shutdownButton = NSButton(title: "Shutdown VMs", target: nil, action: nil)
        let closeAnywayButton = NSButton(title: "Force Quit", target: nil, action: nil)
        cancelButton.setAccessibilityIdentifier("okrun.close.cancel")
        shutdownButton.setAccessibilityIdentifier("okrun.close.shutdown")
        closeAnywayButton.setAccessibilityIdentifier("okrun.close.anyway")

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
        closeAnywayButton.action = #selector(CloseAlertButtonHandler.forceQuit)

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
            return .shutdown
        case .alertSecondButtonReturn:
            return .forceQuit
        default:
            return .cancel
        }
    }

    @objc private func startInstaller() {
        guard let session = selectedSession else {
            setStatus("Not ready", detail: "No project is selected.")
            return
        }

        let currentConfig: VMConfig
        do {
            currentConfig = try VMConfig.load(from: session.paths.config)
            session.config = currentConfig
            AppLog.lifecycle.info(
                "Reloaded installer config project=\(session.paths.root.path, privacy: .public) cpu=\(currentConfig.cpuCount) memoryGB=\(currentConfig.memoryGB) diskGB=\(currentConfig.diskGB)"
            )
        } catch {
            AppLog.lifecycle.error("Installer config reload failed project=\(session.paths.root.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            setStatus("Config reload failed", detail: error.localizedDescription)
            return
        }

        if let isoPath = currentConfig.installerISOPath, FileManager.default.fileExists(atPath: isoPath) {
            start(mode: .installer(URL(fileURLWithPath: isoPath)))
            return
        }

        guard let iso = chooseInstallerISO() else { return }

        do {
            let updatedConfig = VMConfig(
                cpuCount: currentConfig.cpuCount,
                memoryGB: currentConfig.memoryGB,
                diskGB: currentConfig.diskGB,
                installerISOPath: iso.path,
                diskFormat: currentConfig.diskFormat,
                privateNetwork: currentConfig.privateNetwork,
                sharedDirectories: currentConfig.sharedDirectories,
                diskIO: currentConfig.diskIO
            )
            try updatedConfig.save(to: session.paths.config)
            session.config = updatedConfig
            AppLog.lifecycle.info("Updated installer ISO project=\(session.paths.root.path, privacy: .public) iso=\(iso.path, privacy: .public)")
            start(mode: .installer(iso))
        } catch {
            AppLog.lifecycle.error("ISO update failed project=\(session.paths.root.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            setStatus("ISO update failed", detail: error.localizedDescription)
        }
    }

    @objc private func startInstalled() {
        start(mode: .installed)
    }

    @objc private func shutdownVM() {
        guard let session = selectedSession else { return }
        shutdownSession(session, allowsForcePrompt: true)
    }

    @discardableResult
    private func shutdownRunningVMs() -> Bool {
        var allRunningVMsHandled = true

        for session in sessions where session.isRunning {
            if !shutdownSession(session, allowsForcePrompt: false) {
                allRunningVMsHandled = false
            }
        }

        return allRunningVMsHandled
    }

    @discardableResult
    private func shutdownSession(_ session: VMTabSession, allowsForcePrompt: Bool) -> Bool {
        if session.fakeRunning {
            releaseProjectLock(for: session)
            releasePrivateNetworkRuntimes(for: session)
            session.fakeRunning = false
            session.shutdownRequested = false
            setControlsEnabled(for: session, canStart: true, canStop: false)
            setStatus(for: session, status: "Shutdown", detail: "Fake VM stopped.")
            completePendingCloseIfReady()
            return true
        }

        guard let virtualMachine = session.virtualMachine else {
            completePendingCloseIfReady()
            return true
        }

        if session.shutdownRequested {
            guard allowsForcePrompt else {
                setStatus(for: session, status: "Shutdown requested", detail: "Waiting for Linux to shut down cleanly.")
                return true
            }

            if confirmForceStop(for: session) {
                return forceStopSession(session, virtualMachine: virtualMachine)
            }
            return true
        }

        do {
            if virtualMachine.canRequestStop {
                try virtualMachine.requestStop()
                session.shutdownRequested = true
                AppLog.virtualMachine.info("Requested graceful shutdown project=\(session.paths.root.path, privacy: .public)")
                setStatus(for: session, status: "Shutdown requested", detail: "Waiting for Linux to shut down cleanly.")
                return true
            }
        } catch {
            AppLog.virtualMachine.error("Graceful shutdown failed project=\(session.paths.root.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            setStatus(for: session, status: "Graceful shutdown failed", detail: error.localizedDescription)
            return false
        }

        guard virtualMachine.canStop else {
            setStatus(for: session, status: "Shutdown unavailable", detail: "The VM is not currently in a stoppable state.")
            return false
        }

        guard allowsForcePrompt else {
            AppLog.virtualMachine.warning("Graceful shutdown unavailable project=\(session.paths.root.path, privacy: .public)")
            setStatus(
                for: session,
                status: "Shutdown unavailable",
                detail: "Linux cannot be asked to shut down from this VM state. Force quit only if it is stuck."
            )
            return false
        }

        if confirmForceStop(for: session) {
            return forceStopSession(session, virtualMachine: virtualMachine)
        }

        return false
    }

    private func confirmForceStop(for session: VMTabSession) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Force stop \(session.title)?"
        alert.informativeText = "Force stopping does not let Linux shut down cleanly. It can interrupt guest writes and may corrupt the guest disk."
        alert.addButton(withTitle: "Force Stop")
        alert.addButton(withTitle: "Keep Waiting")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @discardableResult
    private func forceStopRunningVMs() -> Bool {
        var allRunningVMsHandled = true

        for session in sessions where session.isRunning {
            if session.fakeRunning {
                releaseProjectLock(for: session)
                releasePrivateNetworkRuntimes(for: session)
                session.fakeRunning = false
                session.shutdownRequested = false
                setControlsEnabled(for: session, canStart: true, canStop: false)
                setStatus(for: session, status: "Force stopped", detail: "Fake VM stopped.")
                completePendingCloseIfReady()
                continue
            }

            guard let virtualMachine = session.virtualMachine else {
                completePendingCloseIfReady()
                continue
            }

            if !forceStopSession(session, virtualMachine: virtualMachine) {
                allRunningVMsHandled = false
            }
        }

        return allRunningVMsHandled
    }

    @discardableResult
    private func forceStopSession(_ session: VMTabSession, virtualMachine: VZVirtualMachine) -> Bool {
        guard virtualMachine.canStop else {
            setStatus(for: session, status: "Force stop unavailable", detail: "The VM is not currently in a stoppable state.")
            return false
        }

        setStatus(for: session, status: "Force shutdown", detail: "Force-stopping the VM.")
        AppLog.virtualMachine.warning("Force-stopping VM project=\(session.paths.root.path, privacy: .public)")
        virtualMachine.stop { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    AppLog.virtualMachine.error("Force stop failed error=\(error.localizedDescription, privacy: .public)")
                    self?.setStatus(for: session, status: "Shutdown failed", detail: error.localizedDescription)
                    self?.cancelPendingClose()
                } else {
                    AppLog.virtualMachine.info("Force stop completed")
                    self?.releaseProjectLock(for: session)
                    self?.releasePrivateNetworkRuntimes(for: session)
                    session.virtualMachine = nil
                    session.vmView.virtualMachine = nil
                    session.shutdownRequested = false
                    session.canStartControls = true
                    session.canStopControls = false
                    self?.window?.toolbar?.validateVisibleItems()
                    self?.updateTabButtonState()
                    self?.setStatus(for: session, status: "Shutdown", detail: "You can boot the installer or installed system again.")
                    self?.completePendingCloseIfReady()
                }
            }
        }

        return true
    }

    private func beginShutdownBeforeTermination() -> NSApplication.TerminateReply {
        terminateAfterVMsStop = true
        closeWindowAfterVMsStop = false

        guard shutdownRunningVMs() else {
            terminateAfterVMsStop = false
            return .terminateCancel
        }

        if hasRunningVMs {
            return .terminateLater
        }

        terminateAfterVMsStop = false
        return .terminateNow
    }

    private func beginForceStopBeforeTermination() -> NSApplication.TerminateReply {
        terminateAfterVMsStop = true
        closeWindowAfterVMsStop = false

        guard forceStopRunningVMs() else {
            terminateAfterVMsStop = false
            return .terminateCancel
        }

        if hasRunningVMs {
            return .terminateLater
        }

        terminateAfterVMsStop = false
        return .terminateNow
    }

    private func beginShutdownBeforeWindowClose() {
        closeWindowAfterVMsStop = true
        terminateAfterVMsStop = false

        guard shutdownRunningVMs() else {
            closeWindowAfterVMsStop = false
            return
        }

        completePendingCloseIfReady()
    }

    private func beginForceStopBeforeWindowClose() {
        closeWindowAfterVMsStop = true
        terminateAfterVMsStop = false

        guard forceStopRunningVMs() else {
            closeWindowAfterVMsStop = false
            return
        }

        completePendingCloseIfReady()
    }

    private func completePendingCloseIfReady() {
        guard !hasRunningVMs else { return }

        if terminateAfterVMsStop {
            terminateAfterVMsStop = false
            closeWindowAfterVMsStop = false
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }

        if closeWindowAfterVMsStop {
            closeWindowAfterVMsStop = false
            isClosingAnyway = true
            window?.close()
        }
    }

    private func cancelPendingClose() {
        if terminateAfterVMsStop {
            terminateAfterVMsStop = false
            closeWindowAfterVMsStop = false
            NSApp.reply(toApplicationShouldTerminate: false)
            return
        }

        closeWindowAfterVMsStop = false
    }

    private func start(mode: VMMode) {
        guard let session = selectedSession else {
            setStatus("Not ready", detail: "VM paths were not prepared.")
            return
        }
        guard !session.isRunning else { return }

        do {
            try acquireProjectLock(for: session)
            let loaded = try reloadConfiguration(for: session)
            AppLog.virtualMachine.info(
                "Starting VM project=\(session.paths.root.path, privacy: .public) mode=\(mode.logDescription, privacy: .public) cpu=\(loaded.config.cpuCount) memoryGB=\(loaded.config.memoryGB) diskGB=\(loaded.config.diskGB) privateNetwork=\(loaded.config.privateNetwork.enabled) sharedDirectories=\(loaded.config.sharedDirectories.count) diskChange=\(String(describing: loaded.preparation.diskChange), privacy: .public)"
            )
            let modeText: String
            switch mode {
            case .installer(let iso):
                modeText = "installer: \(iso.lastPathComponent)"
            case .installed:
                modeText = "installed system"
            }

            if usesFakeVMBackend {
                session.fakeRunning = true
                session.shutdownRequested = false
                setControlsEnabled(for: session, canStart: false, canStop: true)
                setStatus(for: session, status: "Running", detail: runtimeDetail(for: session, "Mode: \(modeText)"))
                return
            }

            let configuration = try makeConfiguration(paths: session.paths, config: loaded.config, mode: mode, session: session)
            let vm = VZVirtualMachine(configuration: configuration)
            vm.delegate = self
            session.virtualMachine = vm
            session.vmView.virtualMachine = vm
            session.shutdownRequested = false
            setControlsEnabled(for: session, canStart: false, canStop: true)

            setStatus(
                "Starting \(modeText)",
                detail: statusDetail(paths: session.paths, config: loaded.config, preparation: loaded.preparation)
            )

            vm.start { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        AppLog.virtualMachine.info("VM started project=\(session.paths.root.path, privacy: .public)")
                        self?.setControlsEnabled(for: session, canStart: false, canStop: true)
                        self?.setStatus(for: session, status: "Running", detail: self?.runtimeDetail(for: session, "Mode: \(modeText)") ?? "")
                    case .failure(let error):
                        AppLog.virtualMachine.error("VM start failed project=\(session.paths.root.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                        self?.releaseProjectLock(for: session)
                        self?.releasePrivateNetworkRuntimes(for: session)
                        session.virtualMachine = nil
                        session.vmView.virtualMachine = nil
                        session.shutdownRequested = false
                        self?.setControlsEnabled(for: session, canStart: true, canStop: false)
                        self?.setStatus(for: session, status: "Start failed", detail: error.localizedDescription)
                    }
                }
            }
        } catch {
            AppLog.virtualMachine.error("VM configuration failed project=\(session.paths.root.path, privacy: .public) mode=\(mode.logDescription, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            releaseProjectLock(for: session)
            releasePrivateNetworkRuntimes(for: session)
            session.shutdownRequested = false
            setControlsEnabled(for: session, canStart: true, canStop: false)
            setStatus(for: session, status: "Configuration failed", detail: error.localizedDescription)
        }
    }

    private func acquireProjectLock(for session: VMTabSession) throws {
        guard session.projectLockFD == nil else { return }

        try FileManager.default.createDirectory(at: session.paths.vmDirectory, withIntermediateDirectories: true)
        let lockURL = session.paths.vmDirectory.appendingPathComponent("okrun.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard fd >= 0 else {
            throw AppError("Unable to create VM lock at \(lockURL.path).")
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            throw AppError("This project is already running in another Okrun VM instance: \(session.paths.root.path)")
        }

        session.projectLockFD = fd
    }

    private func releaseProjectLock(for session: VMTabSession) {
        guard let fd = session.projectLockFD else { return }
        flock(fd, LOCK_UN)
        close(fd)
        session.projectLockFD = nil
    }

    private func releasePrivateNetworkRuntimes(for session: VMTabSession) {
        PrivateNetworkRuntimeRegistry.shared.release(session.privateNetworkRuntimes)
        session.privateNetworkRuntimes.removeAll()
    }

    private func provisionPrivateNetworkDHCPIfNeeded(for config: VMConfig) throws {
        guard config.privateNetwork.enabled else { return }
        _ = try HostNetworkConfigStore().dhcpConfigForPrivateNetwork(identifier: config.privateNetwork.identifier)
    }

    private func makeConfiguration(paths: VMPaths, config: VMConfig, mode: VMMode, session: VMTabSession) throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()

        let machineIdentifierData = try Data(contentsOf: paths.machineIdentifier)
        guard let machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: machineIdentifierData) else {
            throw AppError("Invalid machine identifier at \(paths.machineIdentifier.path)")
        }
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = machineIdentifier
        configuration.platform = platform

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = try makeEFIVariableStore(paths: paths, mode: mode)
        configuration.bootLoader = bootLoader

        configuration.cpuCount = min(config.cpuCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        configuration.memorySize = min(UInt64(config.memoryGB) * 1024 * 1024 * 1024, VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        configuration.graphicsDevices = [makeGraphicsDevice()]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        configuration.networkDevices = try NetworkDeviceFactory.makeDevices(
            privateNetwork: config.privateNetwork,
            machineIdentifierData: machineIdentifierData
        ) { runtime in
            session.privateNetworkRuntimes.append(runtime)
        }
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.storageDevices = try makeStorageDevices(paths: paths, mode: mode, config: config)
        configuration.directorySharingDevices = try DirectorySharingDeviceFactory.makeDevices(
            for: config.sharedDirectories,
            managedGuestLogsDirectory: ManagedGuestTools.guestLogsDirectory(in: paths)
        )

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

    private func makeStorageDevices(paths: VMPaths, mode: VMMode, config: VMConfig) throws -> [VZStorageDeviceConfiguration] {
        let diskURL = try paths.diskURL(for: config)
        let diskAttachment = try DiskImageAttachmentFactory.make(
            url: diskURL,
            readOnly: false,
            diskIO: config.diskIO
        )
        let diskDevice = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)

        switch mode {
        case .installed:
            return [diskDevice]
        case .installer(let iso):
            let isoAttachment = try DiskImageAttachmentFactory.make(url: iso, readOnly: true)
            let isoDevice = VZVirtioBlockDeviceConfiguration(attachment: isoAttachment)
            return [isoDevice, diskDevice]
        }
    }

    private func setControlsEnabled(for session: VMTabSession, canStart: Bool, canStop: Bool) {
        session.canStartControls = canStart
        session.canStopControls = canStop
        window?.toolbar?.validateVisibleItems()
        updateContextControls()
        updateTabButtonState()
    }

    private func setStatus(_ status: String, detail: String) {
        statusLabel.stringValue = status
        detailsLabel.stringValue = detail
        selectedSession?.status = status
        selectedSession?.detail = detail
        updateTabButtonState()
    }

    private func setStatus(for session: VMTabSession, status: String, detail: String) {
        session.status = status
        session.detail = detail
        if session.id == selectedSessionID {
            statusLabel.stringValue = status
            detailsLabel.stringValue = detail
        }
        updateTabButtonState()
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let session = self.session(for: virtualMachine) else { return }
            AppLog.virtualMachine.info("Guest stopped project=\(session.paths.root.path, privacy: .public)")
            self.releaseProjectLock(for: session)
            self.releasePrivateNetworkRuntimes(for: session)
            session.virtualMachine = nil
            session.vmView.virtualMachine = nil
            session.shutdownRequested = false
            self.setControlsEnabled(for: session, canStart: true, canStop: false)
            self.setStatus(for: session, status: "Shutdown", detail: "The VM has shut down.")
            self.completePendingCloseIfReady()
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let session = self.session(for: virtualMachine) else { return }
            AppLog.virtualMachine.error("VM stopped with error project=\(session.paths.root.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            self.releaseProjectLock(for: session)
            self.releasePrivateNetworkRuntimes(for: session)
            session.virtualMachine = nil
            session.vmView.virtualMachine = nil
            session.shutdownRequested = false
            self.setControlsEnabled(for: session, canStart: true, canStop: false)
            self.setStatus(for: session, status: "Stopped with error", detail: error.localizedDescription)
            self.completePendingCloseIfReady()
        }
    }

    private func session(for virtualMachine: VZVirtualMachine) -> VMTabSession? {
        sessions.first { $0.virtualMachine === virtualMachine }
    }
}
