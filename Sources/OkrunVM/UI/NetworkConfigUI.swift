import AppKit

private enum NetworkConfigPalette {
    static let panelBackground = NSColor(calibratedWhite: 0.11, alpha: 1)
    static let sectionBackground = NSColor(calibratedWhite: 0.13, alpha: 1)
    static let rowBackground = NSColor(calibratedWhite: 0.15, alpha: 1)
    static let fieldBackground = NSColor(calibratedWhite: 0.08, alpha: 1)
    static let primaryText = NSColor.white.withAlphaComponent(0.92)
    static let secondaryText = NSColor.white.withAlphaComponent(0.58)
    static let disabledText = NSColor.white.withAlphaComponent(0.36)
    static let border = NSColor.white.withAlphaComponent(0.13)
    static let separator = NSColor.white.withAlphaComponent(0.11)
    static let infoBackground = NSColor.white.withAlphaComponent(0.07)
    static let infoBorder = NSColor.white.withAlphaComponent(0.12)
    static let errorBackground = NSColor.systemRed.withAlphaComponent(0.11)
    static let errorBorder = NSColor.systemRed.withAlphaComponent(0.24)
    static let errorText = NSColor(calibratedRed: 1, green: 0.38, blue: 0.38, alpha: 1)
}

private final class NetworkConfigPanelActions: NSObject {
    var onApply: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onClose: (() -> Void)?
    var onSwitchToggle: (() -> Void)?
    var onLocalSwitchToggle: (() -> Void)?
    var onHostSSHToggle: (() -> Void)?

    @objc func apply() {
        onApply?()
    }

    @objc func refresh() {
        onRefresh?()
    }

    @objc func close() {
        onClose?()
    }

    @objc func switchToggle() {
        onSwitchToggle?()
    }

    @objc func localSwitchToggle() {
        onLocalSwitchToggle?()
    }

    @objc func hostSSHToggle() {
        onHostSSHToggle?()
    }
}

private struct SwitchCertificateBundle: Decodable {
    var server: String
    var caCertPem: String
    var clientCertPem: String
    var clientKeyPem: String
}

extension AppDelegate {
    @objc func openNetworkConfig() {
        let identifier = PrivateNetworkConfig.defaultIdentifier
        let store = HostNetworkConfigStore()
        var timer: DispatchSourceTimer?

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 850),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Private Network"
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NetworkConfigPalette.panelBackground

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        content.layer?.backgroundColor = NetworkConfigPalette.panelBackground.cgColor

        let title = NSTextField(labelWithString: "Private Network")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = NetworkConfigPalette.primaryText

        let pathLabel = NSTextField(labelWithString: store.home.privateNetworksURL.path)
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = NetworkConfigPalette.secondaryText
        pathLabel.lineBreakMode = .byTruncatingMiddle

        let dhcpEnabled = makeNetworkCheckbox("DHCP", identifier: "okrun.network.dhcp.enabled")
        let cidrField = makeNetworkField(identifier: "okrun.network.dhcp.cidr")
        let rangeStartField = makeNetworkField(identifier: "okrun.network.dhcp.range-start")
        let rangeEndField = makeNetworkField(identifier: "okrun.network.dhcp.range-end")
        let leaseField = makeNetworkField(identifier: "okrun.network.dhcp.lease-seconds")

        let hostSSHEnabled = makeNetworkCheckbox("Allow VMs to SSH into this Mac", identifier: "okrun.network.host-ssh.enabled")
        let hostSSHIPAddressField = makeNetworkField(identifier: "okrun.network.host-ssh.ip-address")
        setNetworkPlaceholder("10.77.0.2", on: hostSSHIPAddressField)

        let localSwitchEnabled = makeNetworkCheckbox("Local Switch", identifier: "okrun.network.local-switch.enabled")
        let localSwitchServerField = makeNetworkField(identifier: "okrun.network.local-switch.server")
        setNetworkPlaceholder("127.0.0.1:9444", on: localSwitchServerField)
        let localSwitchStatusLabel = makeNetworkStatusLabel(identifier: "okrun.network.status.local-switch")
        let localSwitchServerStatusLabel = makeNetworkStatusLabel(identifier: "okrun.network.status.local-switch-server")
        let localSwitchMessageLabel = makeNetworkStatusLabel(identifier: "okrun.network.local-switch.status.message")
        localSwitchMessageLabel.lineBreakMode = .byWordWrapping
        localSwitchMessageLabel.maximumNumberOfLines = 3

        let switchEnabled = makeNetworkCheckbox("Web Switch", identifier: "okrun.network.switch.enabled")
        let switchServerField = makeNetworkField(identifier: "okrun.network.switch.server")
        setNetworkPlaceholder("switch.example.com:9443", on: switchServerField)

        let (bundleScroll, bundleTextView) = makeNetworkTextArea(
            identifier: "okrun.network.switch.bundle",
            height: 190
        )

        let switchStatusLabel = makeNetworkStatusLabel(identifier: "okrun.network.status.switch")
        let switchServerStatusLabel = makeNetworkStatusLabel(identifier: "okrun.network.status.switch-server")
        let switchMessageLabel = makeNetworkStatusLabel(identifier: "okrun.network.switch.status.message")
        switchMessageLabel.lineBreakMode = .byWordWrapping
        switchMessageLabel.maximumNumberOfLines = 3
        let (messageBanner, messageLabel) = makeNetworkMessageBanner(identifier: "okrun.network.status.message")

        let applyButton = NSButton(title: "Apply & Connect", target: nil, action: nil)
        applyButton.setAccessibilityIdentifier("okrun.network.apply")
        applyButton.bezelStyle = .rounded
        applyButton.controlSize = .large
        applyButton.keyEquivalent = "\r"

        let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
        refreshButton.setAccessibilityIdentifier("okrun.network.refresh")
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .large

        let closeButton = NSButton(title: "Close", target: nil, action: nil)
        closeButton.setAccessibilityIdentifier("okrun.network.close")
        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .large
        closeButton.keyEquivalent = "\u{1b}"

        let dhcpStateGrid = NSGridView(views: [
            [makeNetworkLabel("Enabled"), dhcpEnabled]
        ])
        configureNetworkGrid(dhcpStateGrid)
        let dhcpLeaseGrid = NSGridView(views: [
            [makeNetworkLabel("CIDR"), cidrField],
            [makeNetworkLabel("Range Start"), rangeStartField],
            [makeNetworkLabel("Range End"), rangeEndField],
            [makeNetworkLabel("Lease Seconds"), leaseField]
        ])
        configureNetworkGrid(dhcpLeaseGrid)
        let dhcpStack = makeNetworkSettingsStack([
            makeNetworkSettingsSection(title: "DHCP", contentView: dhcpStateGrid),
            makeNetworkSettingsSection(title: "Lease Range", contentView: dhcpLeaseGrid)
        ])

        let hostSSHGrid = NSGridView(views: [
            [makeNetworkLabel("Enabled"), hostSSHEnabled],
            [makeNetworkLabel("Host IP"), hostSSHIPAddressField]
        ])
        configureNetworkGrid(hostSSHGrid)
        let hostSSHHelp = makeNetworkHelpLabel(
            "Exposes this Mac's 127.0.0.1:22 as a private-network host. Use an address outside the DHCP range, e.g. 10.77.0.2."
        )
        let hostSSHStack = makeNetworkSettingsStack([
            makeNetworkSettingsSection(title: "Host SSH", contentView: hostSSHGrid),
            hostSSHHelp
        ])

        let localSwitchConnectionGrid = NSGridView(views: [
            [makeNetworkLabel("Enabled"), localSwitchEnabled],
            [makeNetworkLabel("Server"), localSwitchServerField]
        ])
        configureNetworkGrid(localSwitchConnectionGrid)
        let localSwitchStatusGrid = NSGridView(views: [
            [makeNetworkLabel("Status"), localSwitchStatusLabel],
            [makeNetworkLabel("Server"), localSwitchServerStatusLabel],
            [makeNetworkLabel("Message"), localSwitchMessageLabel]
        ])
        configureNetworkGrid(localSwitchStatusGrid)
        let localSwitchStack = makeNetworkSettingsStack([
            makeNetworkSettingsSection(title: "Local Switch", contentView: localSwitchConnectionGrid),
            makeNetworkSettingsSection(title: "Status", contentView: localSwitchStatusGrid)
        ])

        let switchConnectionGrid = NSGridView(views: [
            [makeNetworkLabel("Enabled"), switchEnabled],
            [makeNetworkLabel("Server URL"), switchServerField]
        ])
        configureNetworkGrid(switchConnectionGrid)
        let switchBundleGrid = NSGridView(views: [
            [makeNetworkLabel("Host Bundle JSON"), bundleScroll]
        ])
        configureNetworkGrid(switchBundleGrid)
        let switchStatusGrid = NSGridView(views: [
            [makeNetworkLabel("Status"), switchStatusLabel],
            [makeNetworkLabel("Server"), switchServerStatusLabel],
            [makeNetworkLabel("Message"), switchMessageLabel]
        ])
        configureNetworkGrid(switchStatusGrid)
        let switchStack = makeNetworkSettingsStack([
            makeNetworkSettingsSection(title: "Web Switch", contentView: switchConnectionGrid),
            makeNetworkSettingsSection(title: "Credentials", contentView: switchBundleGrid),
            makeNetworkSettingsSection(title: "Status", contentView: switchStatusGrid)
        ])

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.setAccessibilityIdentifier("okrun.network.tabs")
        tabView.tabViewType = .topTabsBezelBorder
        tabView.addTabViewItem(makeNetworkTabItem(label: "DHCP", contentView: dhcpStack))
        tabView.addTabViewItem(makeNetworkTabItem(label: "Host", contentView: hostSSHStack))
        tabView.addTabViewItem(makeNetworkTabItem(label: "Local Switch", contentView: localSwitchStack))
        tabView.addTabViewItem(makeNetworkTabItem(label: "Web Switch", contentView: switchStack))
        tabView.selectTabViewItem(at: 0)

        let buttonRow = NSStackView(views: [refreshButton, closeButton, applyButton])
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 12

        content.addSubview(title)
        content.addSubview(pathLabel)
        content.addSubview(tabView)
        content.addSubview(messageBanner)
        content.addSubview(buttonRow)
        panel.contentView = content

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            pathLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            pathLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            tabView.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            tabView.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 20),
            tabView.heightAnchor.constraint(equalToConstant: 600),
            tabView.bottomAnchor.constraint(lessThanOrEqualTo: messageBanner.topAnchor, constant: -14),
            messageBanner.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            messageBanner.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            messageBanner.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -12),
            messageBanner.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            refreshButton.widthAnchor.constraint(equalToConstant: 100),
            closeButton.widthAnchor.constraint(equalToConstant: 100),
            applyButton.widthAnchor.constraint(equalToConstant: 142)
        ])

        func setPanelMessage(_ message: String, isError: Bool = false) {
            messageLabel.stringValue = message
            messageLabel.textColor = isError
                ? NetworkConfigPalette.errorText
                : NetworkConfigPalette.secondaryText
            messageBanner.layer?.backgroundColor = (isError
                ? NetworkConfigPalette.errorBackground
                : .clear
            ).cgColor
            messageBanner.layer?.borderColor = (isError
                ? NetworkConfigPalette.errorBorder
                : .clear
            ).cgColor
        }

        func updateTransportControls() {
            let switchOn = switchEnabled.state == .on
            let localSwitchOn = localSwitchEnabled.state == .on
            let hostSSHOn = hostSSHEnabled.state == .on

            switchEnabled.isEnabled = true
            localSwitchEnabled.isEnabled = true
            hostSSHEnabled.isEnabled = true

            hostSSHIPAddressField.isEnabled = hostSSHOn
            localSwitchServerField.isEnabled = localSwitchOn
            switchServerField.isEnabled = switchOn
            bundleTextView.isEditable = true
            bundleTextView.isSelectable = true
            bundleTextView.textColor = networkTextAreaTextColor(enabled: true)
            bundleTextView.insertionPointColor = networkTextAreaInsertionPointColor()
            bundleScroll.alphaValue = 1
        }

        var loadedSwitchServer = ""
        var loadedSwitchBundleText = ""

        func loadFields() {
            do {
                _ = try store.dhcpConfigForPrivateNetwork(identifier: identifier)
                let config = try store.load()
                let privateNetwork = config.privateNetworks[identifier]
                let dhcp = privateNetwork?.dhcp ?? HostNetworkConfigStore.defaultOkrunDHCPConfig()
                dhcpEnabled.state = dhcp.enabled ? .on : .off
                cidrField.stringValue = dhcp.cidr
                rangeStartField.stringValue = dhcp.rangeStart
                rangeEndField.stringValue = dhcp.rangeEnd
                leaseField.stringValue = "\(dhcp.leaseSeconds)"

                if let hostSSHConfig = privateNetwork?.hostSSH {
                    hostSSHEnabled.state = hostSSHConfig.enabled ? .on : .off
                    hostSSHIPAddressField.stringValue = hostSSHConfig.ipAddress.isEmpty
                        ? defaultHostSSHIPAddress(cidr: dhcp.cidr)
                        : hostSSHConfig.ipAddress
                } else {
                    hostSSHEnabled.state = .off
                    hostSSHIPAddressField.stringValue = defaultHostSSHIPAddress(cidr: dhcp.cidr)
                }

                if let localSwitchConfig = privateNetwork?.localSwitch {
                    localSwitchEnabled.state = localSwitchConfig.enabled ? .on : .off
                    localSwitchServerField.stringValue = localSwitchConfig.server
                } else {
                    localSwitchEnabled.state = .off
                    localSwitchServerField.stringValue = ""
                }

                if let switchConfig = privateNetwork?.switch {
                    switchEnabled.state = switchConfig.enabled ? .on : .off
                    switchServerField.stringValue = switchConfig.server
                    loadedSwitchServer = switchConfig.server
                    bundleTextView.string = (try? readSavedSwitchBundleText()) ?? ""
                    loadedSwitchBundleText = normalizedSwitchBundleText(bundleTextView.string)
                } else {
                    switchEnabled.state = .off
                    switchServerField.stringValue = ""
                    loadedSwitchServer = ""
                    bundleTextView.string = (try? readSavedSwitchBundleText()) ?? ""
                    loadedSwitchBundleText = normalizedSwitchBundleText(bundleTextView.string)
                }
                updateTransportControls()
                setPanelMessage("Loaded network config.")
            } catch {
                setPanelMessage(error.localizedDescription, isError: true)
            }
        }

        func defaultHostSSHIPAddress(cidr: String) -> String {
            (try? PrivateNetworkHostSSHConfig.defaultIPAddress(cidr: cidr)) ?? "10.77.0.2"
        }

        func normalizedSwitchServer(_ rawValue: String, displayName: String = "Web Switch") throws -> String {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw AppError("\(displayName) server URL must not be empty.")
            }

            let server: String
            if trimmed.contains("://") {
                guard let url = URL(string: trimmed),
                      let host = url.host,
                      let port = url.port else {
                    throw AppError("\(displayName) server URL must include a host and port.")
                }
                guard url.path.isEmpty || url.path == "/",
                      url.query == nil,
                      url.fragment == nil else {
                    throw AppError("\(displayName) server URL must not include a path, query, or fragment.")
                }
                server = "\(host):\(port)"
            } else {
                server = trimmed
            }

            _ = try PrivateNetworkSwitchEndpoint.parse(server, label: displayName.lowercased())
            return server
        }

        func switchCertDirectory() -> URL {
            store.home.root
                .appendingPathComponent("switch", isDirectory: true)
                .appendingPathComponent(identifier, isDirectory: true)
        }

        func switchBundleURL() -> URL {
            switchCertDirectory().appendingPathComponent("okrun-switch-bundle.json")
        }

        func normalizedSwitchBundleText(_ text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "" : trimmed + "\n"
        }

        func switchCredentialFingerprint(bundleJSON: String) -> String {
            let hash = String(FNV1a64.hash(Array(bundleJSON.utf8)), radix: 16)
            return String(repeating: "0", count: max(0, 16 - hash.count)) + hash
        }

        func readSavedSwitchBundleText() throws -> String? {
            let url = switchBundleURL()
            guard FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }
            return try String(contentsOf: url, encoding: .utf8)
        }

        func normalizedPEM(_ text: String, marker: String, label: String) throws -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains("-----BEGIN \(marker)-----"),
                  trimmed.contains("-----END \(marker)-----") else {
                throw AppError("\(label) must include a \(marker) PEM block.")
            }
            return trimmed + "\n"
        }

        func normalizedPrivateKeyPEM(_ text: String) throws -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains("-----BEGIN "),
                  trimmed.contains("PRIVATE KEY-----"),
                  trimmed.contains("-----END ") else {
                throw AppError("Client private key must include a private key PEM block.")
            }
            return trimmed + "\n"
        }

        func writeSwitchCredentials(
            bundleJSON: String,
            ca: String,
            cert: String,
            key: String
        ) throws -> (ca: String, cert: String, key: String) {
            let directory = switchCertDirectory()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

            let caURL = directory.appendingPathComponent("ca-cert.pem")
            let certURL = directory.appendingPathComponent("client-cert.pem")
            let keyURL = directory.appendingPathComponent("client-key.pem")
            let bundleURL = switchBundleURL()

            try Data(bundleJSON.utf8).write(to: bundleURL, options: .atomic)
            try Data(ca.utf8).write(to: caURL, options: .atomic)
            try Data(cert.utf8).write(to: certURL, options: .atomic)
            try Data(key.utf8).write(to: keyURL, options: .atomic)

            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bundleURL.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: caURL.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: certURL.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)

            return (caURL.path, certURL.path, keyURL.path)
        }

        func readLocalSwitchConfig() throws -> PrivateNetworkLocalSwitchConfig? {
            guard localSwitchEnabled.state == .on else { return nil }

            let rawServer = localSwitchServerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let server = try normalizedSwitchServer(
                rawServer.isEmpty ? "127.0.0.1:9444" : rawServer,
                displayName: "Local Switch"
            )
            localSwitchServerField.stringValue = server
            return try PrivateNetworkLocalSwitchConfig(
                enabled: true,
                server: server
            ).validated()
        }

        func readHostSSHConfig(dhcp: PrivateNetworkDHCPConfig) throws -> PrivateNetworkHostSSHConfig? {
            guard hostSSHEnabled.state == .on else { return nil }
            let rawIP = hostSSHIPAddressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let ipAddress = rawIP.isEmpty ? defaultHostSSHIPAddress(cidr: dhcp.cidr) : rawIP
            hostSSHIPAddressField.stringValue = ipAddress
            return try PrivateNetworkHostSSHConfig(
                enabled: true,
                ipAddress: ipAddress
            ).validated(dhcp: dhcp)
        }

        func readSwitchConfig() throws -> PrivateNetworkSwitchConfig? {
            guard switchEnabled.state == .on else { return nil }

            let serverText = switchServerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let bundleText = normalizedSwitchBundleText(bundleTextView.string)
            if bundleText.isEmpty {
                if let saved = try store.load().privateNetworks[identifier]?.switch, saved.enabled {
                    let server = try normalizedSwitchServer(serverText.isEmpty ? saved.server : serverText)
                    switchServerField.stringValue = server
                    loadedSwitchServer = server
                    return try PrivateNetworkSwitchConfig(
                        enabled: true,
                        server: server,
                        caCert: saved.caCert,
                        clientCert: saved.clientCert,
                        clientKey: saved.clientKey,
                        credentialFingerprint: saved.credentialFingerprint
                    ).validated()
                }
                throw AppError("Paste a Web Switch host bundle JSON before applying.")
            }

            if bundleText == loadedSwitchBundleText,
               let saved = try store.load().privateNetworks[identifier]?.switch,
               saved.enabled {
                let server = try normalizedSwitchServer(serverText.isEmpty ? saved.server : serverText)
                switchServerField.stringValue = server
                loadedSwitchServer = server
                return try PrivateNetworkSwitchConfig(
                    enabled: true,
                    server: server,
                    caCert: saved.caCert,
                    clientCert: saved.clientCert,
                    clientKey: saved.clientKey,
                    credentialFingerprint: switchCredentialFingerprint(bundleJSON: bundleText)
                ).validated()
            }

            let bundle: SwitchCertificateBundle
            do {
                let data = Data(bundleText.utf8)
                bundle = try JSONDecoder().decode(SwitchCertificateBundle.self, from: data)
            } catch {
                throw AppError("Switch bundle JSON is invalid: \(error.localizedDescription)")
            }

            let bundleServer = bundle.server.trimmingCharacters(in: .whitespacesAndNewlines)
            let serverSource = serverText.isEmpty || serverText == loadedSwitchServer
                ? bundleServer
                : serverText
            let server = try normalizedSwitchServer(serverSource)
            let paths = try writeSwitchCredentials(
                bundleJSON: bundleText,
                ca: normalizedPEM(bundle.caCertPem, marker: "CERTIFICATE", label: "CA certificate"),
                cert: normalizedPEM(bundle.clientCertPem, marker: "CERTIFICATE", label: "Client certificate"),
                key: normalizedPrivateKeyPEM(bundle.clientKeyPem)
            )
            bundleTextView.string = bundleText
            loadedSwitchBundleText = bundleText
            switchServerField.stringValue = server
            loadedSwitchServer = server

            let config = PrivateNetworkSwitchConfig(
                enabled: true,
                server: server,
                caCert: paths.ca,
                clientCert: paths.cert,
                clientKey: paths.key,
                credentialFingerprint: switchCredentialFingerprint(bundleJSON: bundleText)
            )
            return try config.validated()
        }

        func readForm() throws -> HostPrivateNetworkConfig {
            let leaseSeconds = UInt32(leaseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let dhcp = try PrivateNetworkDHCPConfig(
                enabled: dhcpEnabled.state == .on,
                mode: .range,
                cidr: cidrField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                rangeStart: rangeStartField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                rangeEnd: rangeEndField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                leaseSeconds: leaseSeconds
            ).validated()

            return HostPrivateNetworkConfig(
                dhcp: dhcp,
                switch: try readSwitchConfig(),
                localSwitch: try readLocalSwitchConfig(),
                hostSSH: try readHostSSHConfig(dhcp: dhcp)
            )
        }

        func updateStatus(
            localSwitchStatus: PrivateNetworkSwitchStatus = PrivateNetworkRuntimeRegistry.shared.localSwitchStatus(identifier: identifier),
            switchStatus: PrivateNetworkSwitchStatus = PrivateNetworkRuntimeRegistry.shared.switchStatus(identifier: identifier)
        ) {
            localSwitchStatusLabel.stringValue = localSwitchStatus.state.rawValue.capitalized
            localSwitchStatusLabel.textColor = switchStatusColor(localSwitchStatus.state)
            localSwitchServerStatusLabel.stringValue = localSwitchStatus.server ?? "Not configured"
            localSwitchServerStatusLabel.textColor = localSwitchStatus.isConnected ? .systemGreen : NetworkConfigPalette.secondaryText

            let localSwitchMessage = localSwitchStatus.state == .disabled
                ? (localSwitchEnabled.state == .on ? "Apply to connect Local Switch." : "Local Switch disabled.")
                : (localSwitchStatus.errorMessage ?? localSwitchStatus.message)
            localSwitchMessageLabel.stringValue = localSwitchMessage
            localSwitchMessageLabel.textColor = localSwitchStatus.errorMessage == nil
                ? switchStatusColor(localSwitchStatus.state)
                : .systemRed

            switchStatusLabel.stringValue = switchStatus.state.rawValue.capitalized
            switchStatusLabel.textColor = switchStatusColor(switchStatus.state)
            switchServerStatusLabel.stringValue = switchStatus.server ?? "Not configured"
            switchServerStatusLabel.textColor = switchStatus.isConnected ? .systemGreen : NetworkConfigPalette.secondaryText

            let switchMessage = switchStatus.state == .disabled
                ? (switchEnabled.state == .on ? "Apply to connect Web Switch." : "Web Switch disabled.")
                : (switchStatus.errorMessage ?? switchStatus.message)
            switchMessageLabel.stringValue = switchMessage
            switchMessageLabel.textColor = switchStatus.errorMessage == nil
                ? switchStatusColor(switchStatus.state)
                : .systemRed
        }

        let actions = NetworkConfigPanelActions()
        actions.onApply = {
            do {
                var config = try store.load()
                let privateNetwork = try readForm()
                config.privateNetworks[identifier] = privateNetwork
                try store.save(config)
                let dhcpRange = try privateNetwork.dhcp.flatMap { dhcp -> PrivateNetworkDHCPLeaseRange? in
                    dhcp.enabled ? try PrivateNetworkDHCPLeaseRange(config: dhcp) : nil
                }
                try PrivateNetworkRuntimeRegistry.shared.configureHostSSH(
                    identifier: identifier,
                    hostSSHConfig: privateNetwork.hostSSH
                )
                let localSwitchStatus = PrivateNetworkRuntimeRegistry.shared.configureLocalSwitch(
                    identifier: identifier,
                    localSwitchConfig: privateNetwork.localSwitch,
                    dhcpRange: dhcpRange
                )
                let switchStatus = PrivateNetworkRuntimeRegistry.shared.configureSwitch(
                    identifier: identifier,
                    switchConfig: privateNetwork.switch,
                    dhcpRange: dhcpRange
                )
                setPanelMessage("Saved network config.")
                updateTransportControls()
                updateStatus(localSwitchStatus: localSwitchStatus, switchStatus: switchStatus)
            } catch {
                setPanelMessage(error.localizedDescription, isError: true)
            }
        }
        actions.onRefresh = {
            updateStatus()
            setPanelMessage("Refreshed status.")
        }
        actions.onSwitchToggle = {
            if switchEnabled.state == .on {
                setPanelMessage("Web Switch enabled.")
            } else {
                setPanelMessage("Web Switch disabled.")
            }
            updateTransportControls()
            updateStatus()
        }
        actions.onLocalSwitchToggle = {
            if localSwitchEnabled.state == .on {
                setPanelMessage("Local Switch enabled.")
            } else {
                setPanelMessage("Local Switch disabled.")
            }
            updateTransportControls()
            updateStatus()
        }
        actions.onHostSSHToggle = {
            if hostSSHEnabled.state == .on {
                setPanelMessage("Host SSH enabled. Apply to expose this Mac at the selected private IP.")
            } else {
                setPanelMessage("Host SSH disabled.")
            }
            updateTransportControls()
        }
        actions.onClose = { [weak panel] in
            panel?.close()
            NSApp.stopModal()
        }
        applyButton.target = actions
        applyButton.action = #selector(NetworkConfigPanelActions.apply)
        refreshButton.target = actions
        refreshButton.action = #selector(NetworkConfigPanelActions.refresh)
        closeButton.target = actions
        closeButton.action = #selector(NetworkConfigPanelActions.close)
        switchEnabled.target = actions
        switchEnabled.action = #selector(NetworkConfigPanelActions.switchToggle)
        localSwitchEnabled.target = actions
        localSwitchEnabled.action = #selector(NetworkConfigPanelActions.localSwitchToggle)
        hostSSHEnabled.target = actions
        hostSSHEnabled.action = #selector(NetworkConfigPanelActions.hostSSHToggle)

        loadFields()
        do {
            let savedPrivateNetwork = try store.load().privateNetworks[identifier]
            let dhcpRange = try savedPrivateNetwork?.dhcp.flatMap { dhcp -> PrivateNetworkDHCPLeaseRange? in
                dhcp.enabled ? try PrivateNetworkDHCPLeaseRange(config: dhcp) : nil
            }
            try PrivateNetworkRuntimeRegistry.shared.configureHostSSH(
                identifier: identifier,
                hostSSHConfig: savedPrivateNetwork?.hostSSH
            )
            let localSwitchStatus = !PrivateNetworkRuntimeRegistry.shared.hasLocalSwitch(identifier: identifier)
                && savedPrivateNetwork?.localSwitch?.enabled == true
                ? PrivateNetworkRuntimeRegistry.shared.configureLocalSwitch(
                    identifier: identifier,
                    localSwitchConfig: savedPrivateNetwork?.localSwitch,
                    dhcpRange: dhcpRange ?? nil
                )
                : PrivateNetworkRuntimeRegistry.shared.localSwitchStatus(identifier: identifier)
            let switchStatus = !PrivateNetworkRuntimeRegistry.shared.hasSwitch(identifier: identifier)
                && savedPrivateNetwork?.switch?.enabled == true
                ? PrivateNetworkRuntimeRegistry.shared.configureSwitch(
                    identifier: identifier,
                    switchConfig: savedPrivateNetwork?.switch,
                    dhcpRange: dhcpRange ?? nil
                )
                : PrivateNetworkRuntimeRegistry.shared.switchStatus(identifier: identifier)
            updateStatus(localSwitchStatus: localSwitchStatus, switchStatus: switchStatus)
        } catch {
            updateStatus()
        }

        let statusTimer = DispatchSource.makeTimerSource(queue: .main)
        statusTimer.schedule(deadline: .now() + 0.25, repeating: .milliseconds(500))
        statusTimer.setEventHandler {
            updateStatus()
        }
        statusTimer.resume()
        timer = statusTimer

        if let parent = NSApp.keyWindow {
            panel.setFrameOrigin(NSPoint(
                x: parent.frame.midX - panel.frame.width / 2,
                y: parent.frame.midY - panel.frame.height / 2
            ))
        } else {
            panel.center()
        }

        NSApp.runModal(for: panel)
        timer?.cancel()
        _ = actions
    }

    private func makeNetworkCheckbox(_ title: String, identifier: String) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.setAccessibilityIdentifier(identifier)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.font = .systemFont(ofSize: 13)
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NetworkConfigPalette.primaryText
            ]
        )
        return button
    }

    private func makeNetworkField(identifier: String) -> NSTextField {
        let field = NSTextField(string: "")
        field.setAccessibilityIdentifier(identifier)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .systemFont(ofSize: 13)
        field.controlSize = .large
        field.textColor = NetworkConfigPalette.primaryText
        field.backgroundColor = NetworkConfigPalette.fieldBackground
        field.drawsBackground = true
        return field
    }

    private func setNetworkPlaceholder(_ text: String, on field: NSTextField) {
        field.placeholderAttributedString = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NetworkConfigPalette.disabledText
            ]
        )
    }

    private func makeNetworkMessageBanner(identifier: String) -> (NSView, NSTextField) {
        let banner = NSView()
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.wantsLayer = true
        banner.layer?.cornerRadius = 8
        banner.layer?.borderWidth = 1
        banner.layer?.backgroundColor = NetworkConfigPalette.infoBackground.cgColor
        banner.layer?.borderColor = NetworkConfigPalette.infoBorder.cgColor

        let label = NSTextField(labelWithString: "")
        label.setAccessibilityIdentifier(identifier)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = NetworkConfigPalette.secondaryText
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.setContentCompressionResistancePriority(.required, for: .vertical)

        banner.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: banner.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -6)
        ])
        return (banner, label)
    }

    private func makeNetworkTextArea(identifier: String, height: CGFloat) -> (NSScrollView, NSTextView) {
        let textView = NSTextView()
        textView.setAccessibilityIdentifier(identifier)
        textView.frame = NSRect(x: 0, y: 0, width: networkControlColumnWidth(), height: height)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isEditable = false
        textView.isSelectable = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = networkTextAreaTextColor(enabled: false)
        textView.insertionPointColor = networkTextAreaInsertionPointColor()
        textView.backgroundColor = networkTextAreaBackgroundColor()
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.containerSize = NSSize(width: networkControlColumnWidth(), height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = networkTextAreaBackgroundColor()
        scrollView.documentView = textView
        scrollView.heightAnchor.constraint(equalToConstant: height).isActive = true
        return (scrollView, textView)
    }

    private func networkTextAreaBackgroundColor() -> NSColor {
        NetworkConfigPalette.fieldBackground
    }

    private func networkTextAreaTextColor(enabled: Bool) -> NSColor {
        enabled ? NetworkConfigPalette.primaryText : NetworkConfigPalette.disabledText
    }

    private func networkTextAreaInsertionPointColor() -> NSColor {
        NetworkConfigPalette.primaryText
    }

    private func makeNetworkSettingsStack(_ sections: [NSView]) -> NSStackView {
        let stack = NSStackView(views: sections)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 14
        return stack
    }

    private func makeNetworkSettingsSection(title: String, contentView: NSView) -> NSStackView {
        let titleRow = makeNetworkSectionTitleRow(title)
        let separator = makeNetworkSeparator()
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let stack = NSStackView(views: [titleRow, separator, contentView])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.setCustomSpacing(6, after: titleRow)
        stack.setCustomSpacing(12, after: separator)
        return stack
    }

    private func makeNetworkSectionTitleRow(_ text: String) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let label = makeNetworkSectionTitle(text)
        row.addSubview(label)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func makeNetworkTabItem(label: String, contentView: NSView) -> NSTabViewItem {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            contentView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            contentView.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            contentView.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -14)
        ])

        let item = NSTabViewItem(identifier: label)
        item.label = label
        item.view = container
        return item
    }

    private func makeNetworkSectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .bold)
        label.textColor = NetworkConfigPalette.primaryText
        label.alignment = .left
        label.cell?.alignment = .left
        return label
    }

    private func makeNetworkSeparator() -> NSView {
        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NetworkConfigPalette.separator.cgColor
        return separator
    }

    private func makeNetworkLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NetworkConfigPalette.secondaryText
        return label
    }

    private func makeNetworkHelpLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = NetworkConfigPalette.secondaryText
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.widthAnchor.constraint(equalToConstant: networkControlColumnWidth()).isActive = true
        return label
    }

    private func makeNetworkStatusLabel(identifier: String) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.setAccessibilityIdentifier(identifier)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = NetworkConfigPalette.secondaryText
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        return label
    }

    private func configureNetworkGrid(_ grid: NSGridView) {
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = networkLabelColumnWidth()
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 1).width = networkControlColumnWidth()
        grid.rowSpacing = 11
        grid.columnSpacing = 14
        grid.translatesAutoresizingMaskIntoConstraints = false
    }

    private func networkLabelColumnWidth() -> CGFloat {
        132
    }

    private func networkControlColumnWidth() -> CGFloat {
        520
    }

    private func switchStatusColor(_ state: PrivateNetworkSwitchConnectionState) -> NSColor {
        switch state {
        case .connected:
            return .systemGreen
        case .connecting:
            return .systemOrange
        case .failed, .rejected:
            return .systemRed
        case .disabled:
            return NetworkConfigPalette.secondaryText
        }
    }
}

private extension HostNetworkConfigStore {
    static func defaultOkrunDHCPConfig() -> PrivateNetworkDHCPConfig {
        PrivateNetworkDHCPConfig(
            enabled: true,
            mode: .range,
            cidr: "10.77.0.0/24",
            rangeStart: "10.77.0.20",
            rangeEnd: "10.77.0.200",
            leaseSeconds: 3600
        )
    }
}
