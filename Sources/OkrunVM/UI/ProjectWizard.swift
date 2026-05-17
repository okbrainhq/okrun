import AppKit
import UniformTypeIdentifiers

struct NewProjectRequest {
    let projectURL: URL
    let isoURL: URL
    let config: VMConfig
}

struct ImportVMRequest {
    let sourceURL: URL
    let destinationURL: URL
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

private final class ImportDialogActions: NSObject, NSTextFieldDelegate {
    var onChooseSource: (() -> Void)?
    var onChooseLocation: (() -> Void)?
    var onImport: (() -> Void)?
    var onCancel: (() -> Void)?
    var onTextChange: (() -> Void)?

    @objc func chooseSource() {
        onChooseSource?()
    }

    @objc func chooseLocation() {
        onChooseLocation?()
    }

    @objc func importVM() {
        onImport?()
    }

    @objc func cancel() {
        onCancel?()
    }

    func controlTextDidChange(_ notification: Notification) {
        onTextChange?()
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

    private func chooseASIFDisk() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose ASIF Disk"
        panel.message = "Select the Linux .asif disk image to import."
        panel.prompt = "Use Disk"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "asif") ?? .diskImage]
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseImportLocation() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Import Location"
        panel.message = "Choose the folder where the new VM project folder will be created."
        panel.prompt = "Use Location"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func askForASIFImport() -> ImportVMRequest? {
        var sourceURL = environmentURL("OKRUN_UI_E2E_IMPORT_ASIF_PATH")
        let environmentDestinationURL = environmentURL("OKRUN_UI_E2E_IMPORT_PROJECT_PATH")
        var locationURL = environmentDestinationURL?.deletingLastPathComponent() ?? ProjectStore.defaultProjectRoot()
        var diskGB: Int?
        var result: ImportVMRequest?

        let initialName = environmentDestinationURL?.lastPathComponent
            ?? sourceURL.map { suggestedImportProjectName(for: $0) }
            ?? "Imported VM"

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 610, height: 410),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Import VM"
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel
        panel.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor

        let title = NSTextField(labelWithString: "Import VM")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.alignment = .center

        let subtitle = NSTextField(labelWithString: "Copy an existing ASIF Linux disk into a new Okrun project.")
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center

        let sourceButton = makeChooserButton(
            title: sourceURL?.lastPathComponent ?? "Choose ASIF Disk...",
            symbolName: "internaldrive",
            identifier: "okrun.import.source",
            width: 300
        )
        sourceButton.toolTip = sourceURL?.path

        let nameField = NSTextField(string: initialName)
        nameField.setAccessibilityIdentifier("okrun.import.name")
        nameField.controlSize = .large
        nameField.font = .systemFont(ofSize: 13)
        nameField.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let locationButton = makeChooserButton(
            title: locationURL.map { displayName(for: $0) } ?? "Choose Location...",
            symbolName: "folder",
            identifier: "okrun.import.location",
            width: 300
        )
        locationButton.toolTip = locationURL?.path

        let cpuField = makeNumberField(environmentValue("OKRUN_UI_E2E_IMPORT_CPU", default: "4"), identifier: "okrun.import.cpu")
        let memoryField = makeNumberField(environmentValue("OKRUN_UI_E2E_IMPORT_MEMORY_GB", default: "4"), identifier: "okrun.import.memory")

        let diskField = NSTextField(labelWithString: "Choose an ASIF disk")
        diskField.setAccessibilityIdentifier("okrun.import.disk")
        diskField.translatesAutoresizingMaskIntoConstraints = false
        diskField.font = .systemFont(ofSize: 13)
        diskField.textColor = .secondaryLabelColor
        diskField.alignment = .left
        diskField.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let importButton = NSButton(title: "Import", target: nil, action: nil)
        importButton.setAccessibilityIdentifier("okrun.import.confirm")
        importButton.bezelStyle = .rounded
        importButton.controlSize = .large
        importButton.keyEquivalent = "\r"

        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.setAccessibilityIdentifier("okrun.import.cancel")
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .large
        cancelButton.keyEquivalent = "\u{1b}"

        let buttonRow = NSStackView(views: [cancelButton, importButton])
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 12

        func updateDiskSize() {
            guard let sourceURL else {
                diskGB = nil
                diskField.stringValue = "Choose an ASIF disk"
                diskField.textColor = .secondaryLabelColor
                return
            }

            do {
                let virtualSize = try DiskImageCreator.virtualSize(url: sourceURL, format: .asif)
                let detectedDiskGB = try ASIFImporter.diskGB(forVirtualSizeBytes: virtualSize)
                diskGB = detectedDiskGB
                diskField.stringValue = "\(detectedDiskGB) GB"
                diskField.textColor = .labelColor
            } catch {
                diskGB = nil
                diskField.stringValue = error.localizedDescription
                diskField.textColor = .systemRed
            }
        }

        func validateForm() {
            let hasName = !nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasResources = Int(cpuField.stringValue).map { $0 > 0 } == true
                && Int(memoryField.stringValue).map { $0 > 0 } == true
            importButton.isEnabled = sourceURL != nil && locationURL != nil && diskGB != nil && hasName && hasResources
        }

        let actions = ImportDialogActions()
        actions.onChooseSource = { [weak self, weak sourceButton] in
            guard let self, let url = self.chooseASIFDisk() else { return }
            sourceURL = url
            sourceButton?.title = url.lastPathComponent
            sourceButton?.toolTip = url.path
            if nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || nameField.stringValue == "Imported VM" {
                nameField.stringValue = self.suggestedImportProjectName(for: url)
            }
            updateDiskSize()
            validateForm()
        }
        actions.onChooseLocation = { [weak self, weak locationButton] in
            guard let self, let url = self.chooseImportLocation() else { return }
            locationURL = url
            locationButton?.title = self.displayName(for: url)
            locationButton?.toolTip = url.path
            validateForm()
        }
        actions.onTextChange = {
            validateForm()
        }
        actions.onImport = { [weak self, weak panel] in
            guard let self else { return }
            guard let sourceURL,
                  let locationURL,
                  let diskGB,
                  let cpu = Int(cpuField.stringValue),
                  let memory = Int(memoryField.stringValue) else {
                NSSound.beep()
                return
            }

            let name = self.sanitizedImportName(nameField.stringValue)
            guard !name.isEmpty,
                  let config = try? ASIFImporter.importedConfig(diskGB: diskGB, cpuCount: cpu, memoryGB: memory) else {
                NSSound.beep()
                return
            }

            let destinationURL = locationURL.appendingPathComponent(name, isDirectory: true)
            result = ImportVMRequest(sourceURL: sourceURL, destinationURL: destinationURL, config: config)
            panel?.close()
            NSApp.stopModal()
        }
        actions.onCancel = { [weak panel] in
            panel?.close()
            NSApp.stopModal()
        }

        sourceButton.target = actions
        sourceButton.action = #selector(ImportDialogActions.chooseSource)
        locationButton.target = actions
        locationButton.action = #selector(ImportDialogActions.chooseLocation)
        nameField.delegate = actions
        cpuField.delegate = actions
        memoryField.delegate = actions
        importButton.target = actions
        importButton.action = #selector(ImportDialogActions.importVM)
        cancelButton.target = actions
        cancelButton.action = #selector(ImportDialogActions.cancel)

        let grid = NSGridView(views: [
            [makeFieldLabel("ASIF Disk"), sourceButton],
            [makeFieldLabel("Name"), nameField],
            [makeFieldLabel("Location"), locationButton],
            [makeFieldLabel("CPU"), cpuField],
            [makeFieldLabel("Memory GB"), memoryField],
            [makeFieldLabel("Disk Size"), diskField]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 116
        grid.column(at: 1).width = 300
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(title)
        content.addSubview(subtitle)
        content.addSubview(grid)
        content.addSubview(buttonRow)
        panel.contentView = content

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            subtitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            subtitle.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            grid.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 28),
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            buttonRow.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -26),
            cancelButton.widthAnchor.constraint(equalToConstant: 116),
            importButton.widthAnchor.constraint(equalToConstant: 116)
        ])

        updateDiskSize()
        validateForm()
        center(panel)
        NSApp.runModal(for: panel)

        _ = actions
        return result
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
        let diskFormatPopup = makeDiskFormatPopup()

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
        actions.onCreate = { [weak panel, weak cpuField, weak memoryField, weak diskField, weak diskFormatPopup] in
            let diskFormatRaw = diskFormatPopup?.selectedItem?.representedObject as? String
            let diskFormat = diskFormatRaw.flatMap(DiskImageFormat.init(rawValue:)) ?? .raw
            guard let projectURL,
                  let isoURL,
                  let cpu = Int(cpuField?.stringValue ?? ""),
                  let memory = Int(memoryField?.stringValue ?? ""),
                  let disk = Int(diskField?.stringValue ?? ""),
                  let config = try? VMConfig(
                    cpuCount: cpu,
                    memoryGB: memory,
                    diskGB: disk,
                    installerISOPath: isoURL.path,
                    diskFormat: diskFormat,
                    privateNetwork: PrivateNetworkConfig(enabled: true)
                  ).validated() else {
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
            [makeFieldLabel("Disk GB"), diskField],
            [makeFieldLabel("Disk Format"), diskFormatPopup]
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

    private func makeChooserButton(title: String, symbolName: String, identifier: String, width: CGFloat = 280) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.setAccessibilityIdentifier(identifier)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.alignment = .left
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.lineBreakMode = .byTruncatingMiddle
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        return button
    }

    private func makeDiskFormatPopup() -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.setAccessibilityIdentifier("okrun.add.disk-format")
        popup.controlSize = .large
        popup.widthAnchor.constraint(equalToConstant: 280).isActive = true

        let formats: [DiskImageFormat] = DiskImageFormat.asif.isSupported ? [.asif, .raw] : [.raw]
        for format in formats {
            popup.addItem(withTitle: format.displayName)
            popup.lastItem?.representedObject = format.rawValue
        }

        if let index = formats.firstIndex(of: .defaultForNewProjects) {
            popup.selectItem(at: index)
        }

        return popup
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

    private func suggestedImportProjectName(for sourceURL: URL) -> String {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return baseName.isEmpty ? "Imported VM" : baseName
    }

    private func sanitizedImportName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
    }
}
