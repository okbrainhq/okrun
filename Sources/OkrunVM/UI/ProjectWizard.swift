import AppKit
import UniformTypeIdentifiers
#if arch(arm64)
import Virtualization
#endif

struct NewProjectRequest {
    let projectURL: URL
    let installerURL: URL
    let config: VMConfig
}

struct ImportVMRequest {
    let sourceURL: URL
    let destinationURL: URL
    let config: VMConfig
}

private final class DialogActions: NSObject, NSTextFieldDelegate {
    var onChooseProject: (() -> Void)?
    var onChooseInstaller: (() -> Void)?
    var onGuestOSChange: (() -> Void)?
    var onOpenLatestMacOSDownload: (() -> Void)?
    var onCopyLatestMacOSDownload: (() -> Void)?
    var onCreate: (() -> Void)?
    var onCancel: (() -> Void)?
    var onTextChange: (() -> Void)?

    @objc func chooseProject() {
        onChooseProject?()
    }

    @objc func chooseInstaller() {
        onChooseInstaller?()
    }

    @objc func guestOSChanged() {
        onGuestOSChange?()
    }

    @objc func openLatestMacOSDownload() {
        onOpenLatestMacOSDownload?()
    }

    @objc func copyLatestMacOSDownload() {
        onCopyLatestMacOSDownload?()
    }

    @objc func create() {
        onCreate?()
    }

    @objc func cancel() {
        onCancel?()
    }

    func controlTextDidChange(_ notification: Notification) {
        onTextChange?()
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

    func chooseInstallerImage(for guestOS: GuestOS) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Installer \(guestOS.installerKindName)"
        panel.message = "Select the \(guestOS.displayName) installer \(guestOS.installerKindName) for this project."
        panel.prompt = "Use \(guestOS.installerKindName)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        switch guestOS {
        case .linux:
            panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage]
        case .macOS:
            panel.allowedContentTypes = [UTType(filenameExtension: "ipsw") ?? .data]
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseInstallerISO() -> URL? {
        chooseInstallerImage(for: .linux)
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
                  let config = try? ASIFImporter.importedConfig(diskGB: diskGB, cpuCount: cpu, memoryGB: memory, name: name) else {
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
        var installerURL = environmentURL("OKRUN_UI_E2E_INSTALLER_PATH") ?? environmentURL("OKRUN_UI_E2E_ISO_PATH")
        var guestOS = GuestOS(rawValue: environmentValue("OKRUN_UI_E2E_GUEST_OS", default: GuestOS.linux.rawValue)) ?? .linux
        let environmentVMName = VMConfig.normalizedName(ProcessInfo.processInfo.environment["OKRUN_UI_E2E_VM_NAME"])
        var nameWasEdited = environmentVMName != nil
        let initialVMName = environmentVMName
            ?? projectURL.map { displayName(for: $0) }
            ?? "New VM"
        var result: NewProjectRequest?
        let labelColumnWidth: CGFloat = 116
        let fieldColumnWidth: CGFloat = 360
        let formColumnSpacing: CGFloat = 12
        let macOSDownloadPanelPadding: CGFloat = 14
        let macOSDownloadButtonSpacing: CGFloat = 8
        let macOSDownloadContentWidth = fieldColumnWidth - (macOSDownloadPanelPadding * 2)
        let macOSDownloadActionButtonWidth = (macOSDownloadContentWidth - macOSDownloadButtonSpacing) / 2

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 650),
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

        let subtitle = NSTextField(labelWithString: "Name the VM, choose its project folder, then pick the guest OS, installer image, and starter resources.")
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .systemFont(ofSize: 13, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center

        let nameField = NSTextField(string: initialVMName)
        nameField.setAccessibilityIdentifier("okrun.add.name")
        nameField.controlSize = .large
        nameField.font = .systemFont(ofSize: 13)
        nameField.widthAnchor.constraint(equalToConstant: fieldColumnWidth).isActive = true
        nameField.placeholderString = "VM name"

        let projectButton = makeChooserButton(
            title: projectURL.map { displayName(for: $0) } ?? "Choose VM Folder...",
            symbolName: "folder",
            identifier: "okrun.add.project"
        )
        projectButton.toolTip = projectURL?.path
        let guestOSPopup = makeGuestOSPopup(initialGuestOS: guestOS)
        let installerButton = makeChooserButton(
            title: installerURL?.lastPathComponent ?? "Choose Installer \(guestOS.installerKindName)...",
            symbolName: "opticaldisc",
            identifier: "okrun.add.installer"
        )
        installerButton.toolTip = installerURL?.path
        let defaultMemoryGB = guestOS == .macOS ? "8" : "4"
        let defaultDiskGB = guestOS == .macOS ? "80" : "64"
        let cpuField = makeNumberField(environmentValue("OKRUN_UI_E2E_CPU", default: "4"), identifier: "okrun.add.cpu")
        let memoryField = makeNumberField(environmentValue("OKRUN_UI_E2E_MEMORY_GB", default: defaultMemoryGB), identifier: "okrun.add.memory")
        let diskField = makeNumberField(environmentValue("OKRUN_UI_E2E_DISK_GB", default: defaultDiskGB), identifier: "okrun.add.disk")
        let diskFormatPopup = makeDiskFormatPopup()

        var latestMacOSDownloadURL: URL?
        var isFetchingLatestMacOSDownload = false

        let latestDownloadButton = makeSmallActionButton(
            title: "Open Latest IPSW",
            symbolName: "arrow.down.circle",
            identifier: "okrun.add.macos-download-open",
            width: macOSDownloadActionButtonWidth
        )
        let copyDownloadButton = makeSmallActionButton(
            title: "Copy Link",
            symbolName: "doc.on.doc",
            identifier: "okrun.add.macos-download-copy",
            width: macOSDownloadActionButtonWidth
        )
        let downloadButtonRow = NSStackView(views: [latestDownloadButton, copyDownloadButton])
        downloadButtonRow.translatesAutoresizingMaskIntoConstraints = false
        downloadButtonRow.orientation = .horizontal
        downloadButtonRow.alignment = .centerY
        downloadButtonRow.spacing = macOSDownloadButtonSpacing

        let macOSDownloadStatus = NSTextField(labelWithString: "Finding the latest supported macOS restore image...")
        macOSDownloadStatus.setAccessibilityIdentifier("okrun.add.macos-download-status")
        macOSDownloadStatus.translatesAutoresizingMaskIntoConstraints = false
        macOSDownloadStatus.font = .systemFont(ofSize: 11)
        macOSDownloadStatus.textColor = .secondaryLabelColor
        macOSDownloadStatus.lineBreakMode = .byTruncatingMiddle
        macOSDownloadStatus.maximumNumberOfLines = 1
        macOSDownloadStatus.widthAnchor.constraint(equalToConstant: macOSDownloadContentWidth).isActive = true

        let macOSDownloadIcon = NSImageView(image: NSImage(
            systemSymbolName: "arrow.down.circle",
            accessibilityDescription: "Latest macOS IPSW"
        ) ?? NSImage())
        macOSDownloadIcon.translatesAutoresizingMaskIntoConstraints = false
        macOSDownloadIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        macOSDownloadIcon.contentTintColor = .systemBlue
        macOSDownloadIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        macOSDownloadIcon.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let macOSDownloadTitle = NSTextField(labelWithString: "Latest supported macOS IPSW")
        macOSDownloadTitle.translatesAutoresizingMaskIntoConstraints = false
        macOSDownloadTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        macOSDownloadTitle.textColor = .labelColor

        let macOSDownloadHeader = NSStackView(views: [macOSDownloadIcon, macOSDownloadTitle])
        macOSDownloadHeader.translatesAutoresizingMaskIntoConstraints = false
        macOSDownloadHeader.orientation = .horizontal
        macOSDownloadHeader.alignment = .centerY
        macOSDownloadHeader.spacing = 7

        let macOSDownloadContent = NSStackView(views: [macOSDownloadHeader, downloadButtonRow, macOSDownloadStatus])
        macOSDownloadContent.translatesAutoresizingMaskIntoConstraints = false
        macOSDownloadContent.orientation = .vertical
        macOSDownloadContent.alignment = .leading
        macOSDownloadContent.spacing = 7

        let macOSDownloadPanel = NSView()
        macOSDownloadPanel.translatesAutoresizingMaskIntoConstraints = false
        macOSDownloadPanel.wantsLayer = true
        macOSDownloadPanel.layer?.cornerRadius = 8
        macOSDownloadPanel.layer?.cornerCurve = .continuous
        macOSDownloadPanel.layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1).cgColor
        macOSDownloadPanel.layer?.borderWidth = 1
        macOSDownloadPanel.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.35).cgColor
        macOSDownloadPanel.addSubview(macOSDownloadContent)

        NSLayoutConstraint.activate([
            macOSDownloadPanel.widthAnchor.constraint(equalToConstant: fieldColumnWidth),
            macOSDownloadPanel.heightAnchor.constraint(equalToConstant: 96),
            macOSDownloadContent.leadingAnchor.constraint(equalTo: macOSDownloadPanel.leadingAnchor, constant: macOSDownloadPanelPadding),
            macOSDownloadContent.trailingAnchor.constraint(equalTo: macOSDownloadPanel.trailingAnchor, constant: -macOSDownloadPanelPadding),
            macOSDownloadContent.centerYAnchor.constraint(equalTo: macOSDownloadPanel.centerYAnchor)
        ])

        let macOSDownloadSpacer = NSView()
        macOSDownloadSpacer.translatesAutoresizingMaskIntoConstraints = false
        let macOSDownloadGrid = NSGridView(views: [
            [macOSDownloadSpacer, macOSDownloadPanel]
        ])
        macOSDownloadGrid.column(at: 0).width = labelColumnWidth
        macOSDownloadGrid.column(at: 1).width = fieldColumnWidth
        macOSDownloadGrid.columnSpacing = formColumnSpacing
        macOSDownloadGrid.rowSpacing = 0
        macOSDownloadGrid.translatesAutoresizingMaskIntoConstraints = false
        macOSDownloadGrid.isHidden = guestOS != .macOS

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

        func latestRestoreImageDescription(version: OperatingSystemVersion, build: String, url: URL) -> String {
            let versionText: String
            if version.patchVersion > 0 {
                versionText = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            } else {
                versionText = "\(version.majorVersion).\(version.minorVersion)"
            }
            return "macOS \(versionText) \(build)  \(url.absoluteString)"
        }

        func applyLatestMacOSDownloadURL(open: Bool, copy: Bool) {
            guard let url = latestMacOSDownloadURL else { return }

            if copy {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(url.absoluteString, forType: .string)
                macOSDownloadStatus.stringValue = "Copied \(url.absoluteString)"
                macOSDownloadStatus.toolTip = url.absoluteString
            }

            if open {
                NSWorkspace.shared.open(url)
                macOSDownloadStatus.stringValue = "Opened \(url.absoluteString)"
                macOSDownloadStatus.toolTip = url.absoluteString
            }
        }

        func fetchLatestMacOSDownload(open: Bool, copy: Bool) {
            guard guestOS == .macOS else { return }

            if latestMacOSDownloadURL != nil {
                applyLatestMacOSDownloadURL(open: open, copy: copy)
                return
            }

            guard !isFetchingLatestMacOSDownload else { return }
            isFetchingLatestMacOSDownload = true
            latestDownloadButton.isEnabled = false
            copyDownloadButton.isEnabled = false
            macOSDownloadStatus.textColor = .secondaryLabelColor
            macOSDownloadStatus.stringValue = "Finding the latest supported macOS restore image..."
            macOSDownloadStatus.toolTip = nil

#if arch(arm64)
            VZMacOSRestoreImage.fetchLatestSupported { result in
                DispatchQueue.main.async {
                    isFetchingLatestMacOSDownload = false

                    switch result {
                    case .success(let restoreImage):
                        let url = restoreImage.url
                        latestMacOSDownloadURL = url
                        latestDownloadButton.isEnabled = true
                        copyDownloadButton.isEnabled = true
                        macOSDownloadStatus.textColor = .secondaryLabelColor
                        macOSDownloadStatus.stringValue = latestRestoreImageDescription(
                            version: restoreImage.operatingSystemVersion,
                            build: restoreImage.buildVersion,
                            url: url
                        )
                        macOSDownloadStatus.toolTip = url.absoluteString
                        applyLatestMacOSDownloadURL(open: open, copy: copy)
                    case .failure(let error):
                        latestDownloadButton.isEnabled = true
                        copyDownloadButton.isEnabled = true
                        macOSDownloadStatus.textColor = .systemRed
                        macOSDownloadStatus.stringValue = error.localizedDescription
                        macOSDownloadStatus.toolTip = error.localizedDescription
                    }
                }
            }
#else
            isFetchingLatestMacOSDownload = false
            latestDownloadButton.isEnabled = false
            copyDownloadButton.isEnabled = false
            macOSDownloadStatus.textColor = .systemRed
            macOSDownloadStatus.stringValue = "macOS guests require Apple silicon."
            macOSDownloadStatus.toolTip = macOSDownloadStatus.stringValue
#endif
        }

        func updateMacOSDownloadRow(fetchIfNeeded: Bool) {
            macOSDownloadGrid.isHidden = guestOS != .macOS
            if guestOS == .macOS, fetchIfNeeded {
                fetchLatestMacOSDownload(open: false, copy: false)
            }
        }

        let actions = DialogActions()
        actions.onChooseProject = { [weak self, weak projectButton, weak nameField] in
            guard let self, let url = self.chooseProjectDirectory() else { return }
            projectURL = url
            let projectDisplayName = self.displayName(for: url)
            projectButton?.title = projectDisplayName
            projectButton?.toolTip = url.path
            if !nameWasEdited || VMConfig.normalizedName(nameField?.stringValue) == nil || nameField?.stringValue == "New VM" {
                nameField?.stringValue = projectDisplayName
                nameWasEdited = false
            }
        }
        actions.onChooseInstaller = { [weak self, weak installerButton] in
            guard let url = self?.chooseInstallerImage(for: guestOS) else { return }
            installerURL = url
            installerButton?.title = url.lastPathComponent
            installerButton?.toolTip = url.path
        }
        actions.onGuestOSChange = { [weak guestOSPopup, weak installerButton, weak memoryField, weak diskField] in
            let selectedRaw = guestOSPopup?.selectedItem?.representedObject as? String
            guestOS = selectedRaw.flatMap(GuestOS.init(rawValue:)) ?? .linux
            installerURL = nil
            installerButton?.title = "Choose Installer \(guestOS.installerKindName)..."
            installerButton?.toolTip = nil
            latestMacOSDownloadURL = nil
            if guestOS == .macOS {
                if memoryField?.stringValue == "4" {
                    memoryField?.stringValue = "8"
                }
                if diskField?.stringValue == "64" {
                    diskField?.stringValue = "80"
                }
            }
            updateMacOSDownloadRow(fetchIfNeeded: true)
        }
        actions.onOpenLatestMacOSDownload = {
            fetchLatestMacOSDownload(open: true, copy: false)
        }
        actions.onCopyLatestMacOSDownload = {
            fetchLatestMacOSDownload(open: false, copy: true)
        }
        actions.onTextChange = {
            nameWasEdited = true
        }
        actions.onCreate = { [weak panel, weak nameField, weak cpuField, weak memoryField, weak diskField, weak diskFormatPopup, weak guestOSPopup] in
            let selectedGuestOSRaw = guestOSPopup?.selectedItem?.representedObject as? String
            let selectedGuestOS = selectedGuestOSRaw.flatMap(GuestOS.init(rawValue:)) ?? guestOS
            let diskFormatRaw = diskFormatPopup?.selectedItem?.representedObject as? String
            let diskFormat = diskFormatRaw.flatMap(DiskImageFormat.init(rawValue:)) ?? .raw
            guard let name = VMConfig.normalizedName(nameField?.stringValue),
                  let projectURL,
                  let installerURL,
                  let cpu = Int(cpuField?.stringValue ?? ""),
                  let memory = Int(memoryField?.stringValue ?? ""),
                  let disk = Int(diskField?.stringValue ?? ""),
                  let config = try? VMConfig(
                    name: name,
                    cpuCount: cpu,
                    memoryGB: memory,
                    diskGB: disk,
                    installerISOPath: installerURL.path,
                    diskFormat: diskFormat,
                    privateNetwork: PrivateNetworkConfig(enabled: true),
                    guestOS: selectedGuestOS
                  ).validated() else {
                NSSound.beep()
                return
            }

            result = NewProjectRequest(projectURL: projectURL, installerURL: installerURL, config: config)
            panel?.close()
            NSApp.stopModal()
        }
        actions.onCancel = { [weak panel] in
            panel?.close()
            NSApp.stopModal()
        }
        projectButton.target = actions
        projectButton.action = #selector(DialogActions.chooseProject)
        nameField.delegate = actions
        guestOSPopup.target = actions
        guestOSPopup.action = #selector(DialogActions.guestOSChanged)
        installerButton.target = actions
        installerButton.action = #selector(DialogActions.chooseInstaller)
        latestDownloadButton.target = actions
        latestDownloadButton.action = #selector(DialogActions.openLatestMacOSDownload)
        copyDownloadButton.target = actions
        copyDownloadButton.action = #selector(DialogActions.copyLatestMacOSDownload)
        createButton.target = actions
        createButton.action = #selector(DialogActions.create)
        cancelButton.target = actions
        cancelButton.action = #selector(DialogActions.cancel)

        let topGrid = NSGridView(views: [
            [makeFieldLabel("Name"), nameField],
            [makeFieldLabel("VM Folder"), projectButton],
            [makeFieldLabel("Guest OS"), guestOSPopup]
        ])
        topGrid.column(at: 0).xPlacement = .trailing
        topGrid.column(at: 0).width = labelColumnWidth
        topGrid.column(at: 1).width = fieldColumnWidth
        topGrid.rowSpacing = 14
        topGrid.columnSpacing = formColumnSpacing
        topGrid.translatesAutoresizingMaskIntoConstraints = false

        let lowerGrid = NSGridView(views: [
            [makeFieldLabel("Installer"), installerButton],
            [makeFieldLabel("CPU"), cpuField],
            [makeFieldLabel("Memory GB"), memoryField],
            [makeFieldLabel("Disk GB"), diskField],
            [makeFieldLabel("Disk Format"), diskFormatPopup]
        ])
        lowerGrid.column(at: 0).xPlacement = .trailing
        lowerGrid.column(at: 0).width = labelColumnWidth
        lowerGrid.column(at: 1).width = fieldColumnWidth
        lowerGrid.rowSpacing = 14
        lowerGrid.columnSpacing = formColumnSpacing
        lowerGrid.translatesAutoresizingMaskIntoConstraints = false

        let formStack = NSStackView(views: [topGrid, macOSDownloadGrid, lowerGrid])
        formStack.translatesAutoresizingMaskIntoConstraints = false
        formStack.orientation = .vertical
        formStack.alignment = .centerX
        formStack.spacing = 16

        content.addSubview(title)
        content.addSubview(subtitle)
        content.addSubview(formStack)
        content.addSubview(buttonRow)
        panel.contentView = content

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 34),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            subtitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            subtitle.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            formStack.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 30),
            formStack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            buttonRow.topAnchor.constraint(greaterThanOrEqualTo: formStack.bottomAnchor, constant: 24),
            buttonRow.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -26),
            cancelButton.widthAnchor.constraint(equalToConstant: 116),
            createButton.widthAnchor.constraint(equalToConstant: 116)
        ])

        updateMacOSDownloadRow(fetchIfNeeded: true)
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
        field.widthAnchor.constraint(equalToConstant: 112).isActive = true
        return field
    }

    private func makeChooserButton(title: String, symbolName: String, identifier: String, width: CGFloat = 360) -> NSButton {
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

    private func makeSmallActionButton(title: String, symbolName: String, identifier: String, width: CGFloat = 176) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.setAccessibilityIdentifier(identifier)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        return button
    }

    private func makeGuestOSPopup(initialGuestOS: GuestOS) -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.setAccessibilityIdentifier("okrun.add.guest-os")
        popup.controlSize = .large
        popup.widthAnchor.constraint(equalToConstant: 360).isActive = true

        let guestSystems: [GuestOS] = [.linux, .macOS]
        for guestOS in guestSystems {
            popup.addItem(withTitle: guestOS.displayName)
            popup.lastItem?.representedObject = guestOS.rawValue
        }

        if let index = guestSystems.firstIndex(of: initialGuestOS) {
            popup.selectItem(at: index)
        }

        return popup
    }

    private func makeDiskFormatPopup() -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.setAccessibilityIdentifier("okrun.add.disk-format")
        popup.controlSize = .large
        popup.widthAnchor.constraint(equalToConstant: 360).isActive = true

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
