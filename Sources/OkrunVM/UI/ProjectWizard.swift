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
        var projectURL: URL?
        var isoURL: URL?
        var result: NewProjectRequest?

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
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

        let projectPath = makeValueLabel("Not selected")
        let isoPath = makeValueLabel("Not selected")
        let projectButton = makeChooserButton(title: "Choose...", symbolName: "folder")
        let isoButton = makeChooserButton(title: "Choose...", symbolName: "opticaldisc")
        let cpuField = makeNumberField("4")
        let memoryField = makeNumberField("4")
        let diskField = makeNumberField("64")

        let createButton = NSButton(title: "Create", target: nil, action: nil)
        createButton.bezelStyle = .rounded
        createButton.controlSize = .large
        createButton.keyEquivalent = "\r"

        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .large
        cancelButton.keyEquivalent = "\u{1b}"

        let buttonRow = NSStackView(views: [cancelButton, createButton])
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 12

        let actions = DialogActions()
        actions.onChooseProject = { [weak self, weak projectPath] in
            guard let url = self?.chooseProjectDirectory() else { return }
            projectURL = url
            projectPath?.stringValue = url.path
            projectPath?.textColor = .labelColor
        }
        actions.onChooseISO = { [weak self, weak isoPath] in
            guard let url = self?.chooseInstallerISO() else { return }
            isoURL = url
            isoPath?.stringValue = url.path
            isoPath?.textColor = .labelColor
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
            [makeFieldLabel("VM Folder"), projectPath, projectButton],
            [makeFieldLabel("ISO"), isoPath, isoButton],
            [makeFieldLabel("CPU"), cpuField, NSView()],
            [makeFieldLabel("Memory GB"), memoryField, NSView()],
            [makeFieldLabel("Disk GB"), diskField, NSView()]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 116
        grid.column(at: 1).width = 310
        grid.column(at: 2).width = 112
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

    private func makeNumberField(_ value: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.alignment = .right
        field.controlSize = .large
        field.font = .systemFont(ofSize: 13)
        field.widthAnchor.constraint(equalToConstant: 80).isActive = true
        return field
    }

    private func makeChooserButton(title: String, symbolName: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.widthAnchor.constraint(equalToConstant: 112).isActive = true
        return button
    }

    private func makeFieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .right
        return label
    }

    private func makeValueLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingMiddle
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
}
