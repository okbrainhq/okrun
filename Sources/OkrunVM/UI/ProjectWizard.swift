import AppKit
import UniformTypeIdentifiers

struct NewProjectRequest {
    let projectURL: URL
    let isoURL: URL
    let config: VMConfig
}

private final class DialogActions: NSObject {
    var onChooseProject: (() -> Void)?
    var onChooseISO: (() -> Void)?
    var onCreate: (() -> Void)?
    var onCancel: (() -> Void)?

    @objc func chooseProject() {
        onChooseProject?()
    }

    @objc func chooseISO() {
        onChooseISO?()
    }

    @objc func create() {
        onCreate?()
    }

    @objc func cancel() {
        onCancel?()
    }
}

extension AppDelegate {
    private func chooseProjectDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose VM Directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseInstallerISO() -> URL? {
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

    func askForNewProject() -> NewProjectRequest? {
        var projectURL = environmentURL("OKRUN_UI_E2E_PROJECT_PATH")
        var isoURL = environmentURL("OKRUN_UI_E2E_ISO_PATH")
        var result: NewProjectRequest?

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 390),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Add VM"
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel
        panel.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor

        let title = NSTextField(labelWithString: "Add VM")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.alignment = .center

        let subtitle = NSTextField(labelWithString: "Choose the VM folder, installer ISO, and starter resources.")
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .systemFont(ofSize: 13, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center

        let projectButton = makeChooserButton(
            title: projectURL.map { displayName(for: $0) } ?? "Choose VM Folder...",
            symbolName: "folder",
            identifier: "okrun.add.project"
        )
        projectButton.toolTip = projectURL?.path
        let isoButton = makeChooserButton(
            title: isoURL?.lastPathComponent ?? "Choose Installer ISO...",
            symbolName: "opticaldisc",
            identifier: "okrun.add.iso"
        )
        isoButton.toolTip = isoURL?.path
        let cpuField = makeNumberField(environmentValue("OKRUN_UI_E2E_CPU", default: "4"), identifier: "okrun.add.cpu")
        let memoryField = makeNumberField(environmentValue("OKRUN_UI_E2E_MEMORY_GB", default: "4"), identifier: "okrun.add.memory")
        let diskField = makeNumberField(environmentValue("OKRUN_UI_E2E_DISK_GB", default: "64"), identifier: "okrun.add.disk")

        let createButton = NSButton(title: "Create", target: nil, action: nil)
        createButton.setAccessibilityIdentifier("okrun.add.create")
        createButton.bezelStyle = .rounded
        createButton.controlSize = .large
        createButton.keyEquivalent = "\r"

        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.setAccessibilityIdentifier("okrun.add.cancel")
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .large
        cancelButton.keyEquivalent = "\u{1b}"

        let buttonRow = NSStackView(views: [cancelButton, createButton])
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 12

        let actions = DialogActions()
        actions.onChooseProject = { [weak self, weak projectButton] in
            guard let url = self?.chooseProjectDirectory() else { return }
            projectURL = url
            projectButton?.title = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
            projectButton?.toolTip = url.path
        }
        actions.onChooseISO = { [weak self, weak isoButton] in
            guard let url = self?.chooseInstallerISO() else { return }
            isoURL = url
            isoButton?.title = url.lastPathComponent
            isoButton?.toolTip = url.path
        }
        actions.onCreate = { [weak panel, weak cpuField, weak memoryField, weak diskField] in
            guard let projectURL,
                  let isoURL,
                  let cpu = Int(cpuField?.stringValue ?? ""),
                  let memory = Int(memoryField?.stringValue ?? ""),
                  let disk = Int(diskField?.stringValue ?? ""),
                  let config = try? VMConfig(cpuCount: cpu, memoryGB: memory, diskGB: disk, installerISOPath: isoURL.path).validated() else {
                NSSound.beep()
                return
            }

            result = NewProjectRequest(projectURL: projectURL, isoURL: isoURL, config: config)
            panel?.close()
            NSApp.stopModal()
        }
        actions.onCancel = { [weak panel] in
            panel?.close()
            NSApp.stopModal()
        }
        projectButton.target = actions
        projectButton.action = #selector(DialogActions.chooseProject)
        isoButton.target = actions
        isoButton.action = #selector(DialogActions.chooseISO)
        createButton.target = actions
        createButton.action = #selector(DialogActions.create)
        cancelButton.target = actions
        cancelButton.action = #selector(DialogActions.cancel)

        let grid = NSGridView(views: [
            [makeFieldLabel("VM Folder"), projectButton],
            [makeFieldLabel("ISO"), isoButton],
            [makeFieldLabel("CPU"), cpuField],
            [makeFieldLabel("Memory GB"), memoryField],
            [makeFieldLabel("Disk GB"), diskField]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 116
        grid.column(at: 1).width = 280
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(title)
        content.addSubview(subtitle)
        content.addSubview(grid)
        content.addSubview(buttonRow)
        panel.contentView = content

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 34),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            subtitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            subtitle.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            grid.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 30),
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            buttonRow.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -26),
            cancelButton.widthAnchor.constraint(equalToConstant: 116),
            createButton.widthAnchor.constraint(equalToConstant: 116)
        ])

        center(panel)
        NSApp.runModal(for: panel)

        _ = actions
        return result
    }

    private func makeNumberField(_ value: String, identifier: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.setAccessibilityIdentifier(identifier)
        field.alignment = .right
        field.controlSize = .large
        field.font = .systemFont(ofSize: 13)
        field.widthAnchor.constraint(equalToConstant: 80).isActive = true
        return field
    }

    private func makeChooserButton(title: String, symbolName: String, identifier: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.setAccessibilityIdentifier(identifier)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.alignment = .left
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.lineBreakMode = .byTruncatingMiddle
        button.widthAnchor.constraint(equalToConstant: 280).isActive = true
        return button
    }

    private func makeFieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .right
        return label
    }

    private func center(_ panel: NSPanel) {
        guard let hostWindow = NSApp.keyWindow else {
            panel.center()
            return
        }

        panel.setFrameOrigin(NSPoint(
            x: hostWindow.frame.midX - panel.frame.width / 2,
            y: hostWindow.frame.midY - panel.frame.height / 2
        ))
    }

    private func environmentURL(_ name: String) -> URL? {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: value)
    }

    private func environmentValue(_ name: String, default defaultValue: String) -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            return defaultValue
        }
        return value
    }

    private func displayName(for url: URL) -> String {
        url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }
}
