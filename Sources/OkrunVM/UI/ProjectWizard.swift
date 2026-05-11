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

    @objc func chooseProject() {
        onChooseProject?()
    }

    @objc func chooseISO() {
        onChooseISO?()
    }
}

extension AppDelegate {
    private func configureButton(_ button: NSButton, symbolName: String) {
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: button.title)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.controlSize = .large
    }

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

        let projectPath = makePathLabel("Not selected")
        let isoPath = makePathLabel("Not selected")
        projectPath.lineBreakMode = .byTruncatingMiddle
        isoPath.lineBreakMode = .byTruncatingMiddle

        let projectButton = NSButton(title: "Choose...", target: nil, action: nil)
        let isoButton = NSButton(title: "Choose...", target: nil, action: nil)
        projectButton.bezelStyle = .rounded
        isoButton.bezelStyle = .rounded
        projectButton.controlSize = .regular
        isoButton.controlSize = .regular
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
            projectPath?.textColor = .labelColor
        }
        actions.onChooseISO = { [weak self, weak isoPath] in
            guard let url = self?.chooseInstallerISO() else { return }
            isoURL = url
            isoPath?.stringValue = url.path
            isoPath?.textColor = .labelColor
        }
        projectButton.target = actions
        projectButton.action = #selector(DialogActions.chooseProject)
        isoButton.target = actions
        isoButton.action = #selector(DialogActions.chooseISO)

        let subtitle = NSTextField(labelWithString: "Select the VM folder, installer ISO, and starter resources.")
        subtitle.font = .systemFont(ofSize: 12, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 2
        subtitle.alignment = .center

        let grid = NSGridView(views: [
            [makeFieldLabel("VM Folder"), projectPath, projectButton],
            [makeFieldLabel("ISO"), isoPath, isoButton],
            [makeFieldLabel("CPU"), cpuField, NSView()],
            [makeFieldLabel("Memory GB"), memoryField, NSView()],
            [makeFieldLabel("Disk GB"), diskField, NSView()]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 100
        grid.column(at: 1).width = 420
        grid.column(at: 2).width = 112
        grid.rowSpacing = 12
        grid.columnSpacing = 14

        let content = NSStackView(views: [subtitle, grid])
        content.orientation = .vertical
        content.spacing = 18
        content.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 190))
        wrapper.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            content.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 4),
            content.bottomAnchor.constraint(lessThanOrEqualTo: wrapper.bottomAnchor, constant: -4)
        ])

        let alert = NSAlert()
        alert.messageText = "Add VM"
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

    private func makeFieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .right
        return label
    }

    private func makePathLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 1
        return label
    }
}
