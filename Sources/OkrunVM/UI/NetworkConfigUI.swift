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
    var onAddPeer: (() -> Void)?
    var onRemovePeer: (() -> Void)?
    var onBridgeToggle: (() -> Void)?
    var onSwitchToggle: (() -> Void)?

    @objc func apply() {
        onApply?()
    }

    @objc func refresh() {
        onRefresh?()
    }

    @objc func close() {
        onClose?()
    }

    @objc func addPeer() {
        onAddPeer?()
    }

    @objc func removePeer() {
        onRemovePeer?()
    }

    @objc func bridgeToggle() {
        onBridgeToggle?()
    }

    @objc func switchToggle() {
        onSwitchToggle?()
    }
}

private struct SwitchCertificateBundle: Decodable {
    var server: String
    var caCertPem: String
    var clientCertPem: String
    var clientKeyPem: String
}

private final class NetworkPeerRowView: NSView {
    let index: Int?
    var onSelect: ((Int) -> Void)?
    var isSelected = false {
        didSet {
            layer?.backgroundColor = isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
                : backgroundColor.cgColor
        }
    }

    private let backgroundColor: NSColor

    init(host: String, port: String, index: Int?, isHeader: Bool = false) {
        self.index = index
        backgroundColor = isHeader ? NetworkConfigPalette.sectionBackground : NetworkConfigPalette.rowBackground
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor

        let hostLabel = NSTextField(labelWithString: host)
        hostLabel.translatesAutoresizingMaskIntoConstraints = false
        hostLabel.font = isHeader ? .systemFont(ofSize: 12, weight: .semibold) : .monospacedSystemFont(ofSize: 12, weight: .regular)
        hostLabel.textColor = isHeader ? NetworkConfigPalette.secondaryText : NetworkConfigPalette.primaryText
        hostLabel.lineBreakMode = .byTruncatingMiddle

        let portLabel = NSTextField(labelWithString: port)
        portLabel.translatesAutoresizingMaskIntoConstraints = false
        portLabel.font = hostLabel.font
        portLabel.textColor = hostLabel.textColor
        portLabel.alignment = .left

        addSubview(hostLabel)
        addSubview(portLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            hostLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            hostLabel.trailingAnchor.constraint(equalTo: portLabel.leadingAnchor, constant: -12),
            hostLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            portLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            portLabel.widthAnchor.constraint(equalToConstant: 96),
            portLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        guard let index else { return }
        onSelect?(index)
    }
}

private final class NetworkPeerListView: NSView {
    private let rows = NSStackView()
    private var selectedIndex: Int?

    var peers: [PrivateNetworkBridgeEndpoint] {
        get { peerStorage }
        set {
            peerStorage = newValue
            if let selectedIndex, selectedIndex >= newValue.count {
                self.selectedIndex = nil
            }
            rebuildRows()
        }
    }
    private var peerStorage: [PrivateNetworkBridgeEndpoint] = []

    var selectedRow: Int {
        selectedIndex ?? -1
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        wantsLayer = true
        layer?.borderWidth = 1
        layer?.borderColor = NetworkConfigPalette.border.cgColor
        layer?.backgroundColor = NetworkConfigPalette.rowBackground.cgColor
        layer?.masksToBounds = true

        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.orientation = .vertical
        rows.alignment = .width
        rows.spacing = 1

        setAccessibilityIdentifier("okrun.network.bridge.peer-list")
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            rows.widthAnchor.constraint(equalTo: widthAnchor)
        ])
        rebuildRows()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection: Bool) {
        selectedIndex = indexes.first
        updateSelection()
    }

    private func rebuildRows() {
        rows.arrangedSubviews.forEach { view in
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        appendRow(NetworkPeerRowView(host: "Host", port: "Port", index: nil, isHeader: true))
        if peerStorage.isEmpty {
            let empty = NetworkPeerRowView(host: "No peers configured", port: "", index: nil)
            empty.alphaValue = 0.65
            appendRow(empty)
        } else {
            for (index, peer) in peerStorage.enumerated() {
                let row = NetworkPeerRowView(host: peer.host, port: "\(peer.port)", index: index)
                row.onSelect = { [weak self] selected in
                    self?.selectedIndex = selected
                    self?.updateSelection()
                }
                appendRow(row)
            }
        }
        updateSelection()
    }

    private func appendRow(_ row: NetworkPeerRowView) {
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }

    private func updateSelection() {
        for view in rows.arrangedSubviews {
            guard let row = view as? NetworkPeerRowView else { continue }
            row.isSelected = row.index == selectedIndex
        }
    }
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

        let bridgeEnabled = makeNetworkCheckbox("Bridge", identifier: "okrun.network.bridge.enabled")
        let bindEnabled = makeNetworkCheckbox("Bind", identifier: "okrun.network.bridge.bind-enabled")
        let bindHostField = makeNetworkField(identifier: "okrun.network.bridge.bind-host")
        let bindPortField = makeNetworkField(identifier: "okrun.network.bridge.bind-port")
        let peerHostField = makeNetworkField(identifier: "okrun.network.bridge.peer-host")
        setNetworkPlaceholder("172.16.0.10", on: peerHostField)
        let peerPortField = makeNetworkField(identifier: "okrun.network.bridge.peer-port")
        setNetworkPlaceholder("7777", on: peerPortField)
        peerPortField.stringValue = "7777"
        let addPeerButton = NSButton(title: "Add Peer", target: nil, action: nil)
        addPeerButton.setAccessibilityIdentifier("okrun.network.bridge.peer-add")
        addPeerButton.bezelStyle = .rounded
        let removePeerButton = NSButton(title: "Remove Peer", target: nil, action: nil)
        removePeerButton.setAccessibilityIdentifier("okrun.network.bridge.peer-remove")
        removePeerButton.bezelStyle = .rounded

        let peerButtonRow = NSStackView(views: [addPeerButton, removePeerButton])
        peerButtonRow.translatesAutoresizingMaskIntoConstraints = false
        peerButtonRow.orientation = .horizontal
        peerButtonRow.alignment = .centerY
        peerButtonRow.spacing = 8
        addPeerButton.widthAnchor.constraint(equalToConstant: 96).isActive = true
        removePeerButton.widthAnchor.constraint(equalToConstant: 116).isActive = true

        let peersTable = NetworkPeerListView()
        peersTable.heightAnchor.constraint(equalToConstant: 112).isActive = true

        let switchEnabled = makeNetworkCheckbox("Web Switch", identifier: "okrun.network.switch.enabled")
        let switchMultipath = makeNetworkCheckbox("Multipath", identifier: "okrun.network.switch.multipath")
        let switchServerField = makeNetworkField(identifier: "okrun.network.switch.server")
        setNetworkPlaceholder("switch.example.com:9443", on: switchServerField)

        let (bundleScroll, bundleTextView) = makeNetworkTextArea(
            identifier: "okrun.network.switch.bundle",
            height: 190
        )

        let bindStatusLabel = makeNetworkStatusLabel(identifier: "okrun.network.status.bind")
        let peerStatusLabel = makeNetworkStatusLabel(identifier: "okrun.network.status.peers")
        let bridgeMessageLabel = makeNetworkStatusLabel(identifier: "okrun.network.bridge.status.message")
        bridgeMessageLabel.lineBreakMode = .byWordWrapping
        bridgeMessageLabel.maximumNumberOfLines = 3
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

        let bridgeConnectionGrid = NSGridView(views: [
            [makeNetworkLabel("Enabled"), bridgeEnabled],
            [makeNetworkLabel("Bind"), bindEnabled],
            [makeNetworkLabel("Bind Host"), bindHostField],
            [makeNetworkLabel("Bind Port"), bindPortField]
        ])
        configureNetworkGrid(bridgeConnectionGrid)
        let bridgePeersGrid = NSGridView(views: [
            [makeNetworkLabel("Peer Host"), peerHostField],
            [makeNetworkLabel("Peer Port"), peerPortField],
            [makeNetworkLabel("Peer Actions"), peerButtonRow],
            [makeNetworkLabel("Configured Peers"), peersTable]
        ])
        configureNetworkGrid(bridgePeersGrid)
        let bridgeStatusGrid = NSGridView(views: [
            [makeNetworkLabel("Bind Status"), bindStatusLabel],
            [makeNetworkLabel("Peer Status"), peerStatusLabel],
            [makeNetworkLabel("Message"), bridgeMessageLabel]
        ])
        configureNetworkGrid(bridgeStatusGrid)
        let bridgeStack = makeNetworkSettingsStack([
            makeNetworkSettingsSection(title: "Bridge", contentView: bridgeConnectionGrid),
            makeNetworkSettingsSection(title: "Peers", contentView: bridgePeersGrid),
            makeNetworkSettingsSection(title: "Status", contentView: bridgeStatusGrid)
        ])

        let switchConnectionGrid = NSGridView(views: [
            [makeNetworkLabel("Enabled"), switchEnabled],
            [makeNetworkLabel("Multipath"), switchMultipath],
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
        tabView.addTabViewItem(makeNetworkTabItem(label: "Bridge", contentView: bridgeStack))
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
            let bridgeOn = bridgeEnabled.state == .on
            let switchOn = switchEnabled.state == .on

            switchEnabled.isEnabled = true
            bridgeEnabled.isEnabled = true

            let bridgeControlsEnabled = bridgeOn
            bindEnabled.isEnabled = bridgeControlsEnabled
            bindHostField.isEnabled = bridgeControlsEnabled
            bindPortField.isEnabled = bridgeControlsEnabled
            peerHostField.isEnabled = bridgeControlsEnabled
            peerPortField.isEnabled = bridgeControlsEnabled
            addPeerButton.isEnabled = bridgeControlsEnabled
            removePeerButton.isEnabled = bridgeControlsEnabled
            peersTable.alphaValue = bridgeControlsEnabled ? 1 : 0.55

            let switchControlsEnabled = switchOn
            switchMultipath.isEnabled = switchControlsEnabled
            switchServerField.isEnabled = switchControlsEnabled
            bundleTextView.isEditable = switchControlsEnabled
            bundleTextView.isSelectable = switchControlsEnabled
            bundleTextView.textColor = networkTextAreaTextColor(enabled: switchControlsEnabled)
            bundleTextView.insertionPointColor = networkTextAreaInsertionPointColor()
            bundleScroll.alphaValue = switchControlsEnabled ? 1 : 0.55
        }

        var loadedSwitchServer = ""

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

                if let bridge = privateNetwork?.bridge {
                    bridgeEnabled.state = .on
                    if let bind = bridge.bind {
                        bindEnabled.state = .on
                        bindHostField.stringValue = bind.host
                        bindPortField.stringValue = "\(bind.port)"
                    } else {
                        bindEnabled.state = .off
                        bindHostField.stringValue = ""
                        bindPortField.stringValue = "7777"
                    }
                    peersTable.peers = bridge.peers
                } else {
                    bridgeEnabled.state = .off
                    bindEnabled.state = .off
                    bindHostField.stringValue = ""
                    bindPortField.stringValue = "7777"
                    peersTable.peers = []
                }

                if let switchConfig = privateNetwork?.switch {
                    switchEnabled.state = switchConfig.enabled ? .on : .off
                    switchMultipath.state = switchConfig.multipath ? .on : .off
                    switchServerField.stringValue = switchConfig.server
                    loadedSwitchServer = switchConfig.server
                    bundleTextView.string = ""
                } else {
                    switchEnabled.state = .off
                    switchMultipath.state = .off
                    switchServerField.stringValue = ""
                    loadedSwitchServer = ""
                    bundleTextView.string = ""
                }
                updateTransportControls()
                setPanelMessage("Loaded network config.")
            } catch {
                setPanelMessage(error.localizedDescription, isError: true)
            }
        }

        func parseEndpoint(host: String, port: String, context: String) throws -> PrivateNetworkBridgeEndpoint {
            guard let parsedPort = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw AppError("\(context) port must be a number.")
            }
            return try PrivateNetworkBridgeEndpoint(
                host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: parsedPort
            ).validated(context: context)
        }

        func parsePeers() throws -> [PrivateNetworkBridgeEndpoint] {
            peersTable.peers
        }

        func normalizedSwitchServer(_ rawValue: String) throws -> String {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw AppError("Web Switch server URL must not be empty.")
            }

            let server: String
            if trimmed.contains("://") {
                guard let url = URL(string: trimmed),
                      let host = url.host,
                      let port = url.port else {
                    throw AppError("Web Switch server URL must include a host and port.")
                }
                guard url.path.isEmpty || url.path == "/",
                      url.query == nil,
                      url.fragment == nil else {
                    throw AppError("Web Switch server URL must not include a path, query, or fragment.")
                }
                server = "\(host):\(port)"
            } else {
                server = trimmed
            }

            _ = try PrivateNetworkSwitchConfig(server: server).endpoint()
            return server
        }

        func switchCertDirectory() -> URL {
            store.home.root
                .appendingPathComponent("switch", isDirectory: true)
                .appendingPathComponent(identifier, isDirectory: true)
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

        func writeSwitchPEMFiles(ca: String, cert: String, key: String) throws -> (ca: String, cert: String, key: String) {
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

            try Data(ca.utf8).write(to: caURL, options: .atomic)
            try Data(cert.utf8).write(to: certURL, options: .atomic)
            try Data(key.utf8).write(to: keyURL, options: .atomic)

            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: caURL.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: certURL.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)

            return (caURL.path, certURL.path, keyURL.path)
        }

        func readSwitchConfig() throws -> PrivateNetworkSwitchConfig? {
            guard switchEnabled.state == .on else { return nil }
            guard bridgeEnabled.state != .on else {
                throw AppError("Disable Bridge before enabling Web Switch.")
            }

            let serverText = switchServerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let bundleText = bundleTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
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
                        multipath: switchMultipath.state == .on
                    ).validated()
                }
                throw AppError("Paste a Web Switch host bundle JSON before applying.")
            }

            let bundle: SwitchCertificateBundle
            do {
                let data = Data(bundleTextView.string.utf8)
                bundle = try JSONDecoder().decode(SwitchCertificateBundle.self, from: data)
            } catch {
                throw AppError("Switch bundle JSON is invalid: \(error.localizedDescription)")
            }

            let bundleServer = bundle.server.trimmingCharacters(in: .whitespacesAndNewlines)
            let serverSource = serverText.isEmpty || serverText == loadedSwitchServer
                ? bundleServer
                : serverText
            let server = try normalizedSwitchServer(serverSource)
            let paths = try writeSwitchPEMFiles(
                ca: normalizedPEM(bundle.caCertPem, marker: "CERTIFICATE", label: "CA certificate"),
                cert: normalizedPEM(bundle.clientCertPem, marker: "CERTIFICATE", label: "Client certificate"),
                key: normalizedPrivateKeyPEM(bundle.clientKeyPem)
            )
            bundleTextView.string = ""
            switchServerField.stringValue = server
            loadedSwitchServer = server

            let config = PrivateNetworkSwitchConfig(
                enabled: true,
                server: server,
                caCert: paths.ca,
                clientCert: paths.cert,
                clientKey: paths.key,
                multipath: switchMultipath.state == .on
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

            let bridge: PrivateNetworkBridgeConfig?
            if bridgeEnabled.state == .on {
                let bind = bindEnabled.state == .on
                    ? try parseEndpoint(host: bindHostField.stringValue, port: bindPortField.stringValue, context: "private network bridge bind")
                    : nil
                bridge = try PrivateNetworkBridgeConfig(bind: bind, peers: parsePeers()).validated()
            } else {
                bridge = nil
            }

            return HostPrivateNetworkConfig(dhcp: dhcp, bridge: bridge, switch: try readSwitchConfig())
        }

        func updateStatus(
            bridgeStatus status: PrivateNetworkBridgeStatus = PrivateNetworkRuntimeRegistry.shared.bridgeStatus(identifier: identifier),
            switchStatus: PrivateNetworkSwitchStatus = PrivateNetworkRuntimeRegistry.shared.switchStatus(identifier: identifier)
        ) {
            bindStatusLabel.stringValue = status.bindMessage
            bindStatusLabel.textColor = status.isListening ? .systemGreen : NetworkConfigPalette.secondaryText

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

            var bridgeMessages: [String] = []
            var bridgeMessageColor = NetworkConfigPalette.secondaryText
            if let error = status.errorMessage {
                peerStatusLabel.stringValue = "Error"
                peerStatusLabel.textColor = .systemRed
                bridgeMessages.append(error)
                bridgeMessageColor = .systemRed
                bridgeMessageLabel.stringValue = bridgeMessages.joined(separator: "\n")
                bridgeMessageLabel.textColor = bridgeMessageColor
                return
            }

            if status.peers.isEmpty {
                peerStatusLabel.stringValue = "No peers"
                peerStatusLabel.textColor = NetworkConfigPalette.secondaryText
                bridgeMessages.append(bridgeEnabled.state == .on ? "No bridge peers configured." : "Bridge disabled.")
            } else {
                let connected = status.peers.filter(\.isConnected).count
                let failed = status.peers.filter { $0.state == .failed || $0.state == .rejected }.count
                let connecting = status.peers.filter { $0.state == .connecting }.count
                if failed > 0 {
                    peerStatusLabel.stringValue = "\(connected)/\(status.peers.count) connected, \(failed) error"
                    peerStatusLabel.textColor = .systemRed
                } else if connecting > 0 {
                    peerStatusLabel.stringValue = "\(connected)/\(status.peers.count) connected, \(connecting) connecting"
                    peerStatusLabel.textColor = .systemOrange
                } else {
                    peerStatusLabel.stringValue = "\(connected)/\(status.peers.count) connected"
                    peerStatusLabel.textColor = connected == status.peers.count ? .systemGreen : NetworkConfigPalette.secondaryText
                }

                bridgeMessages.append(contentsOf: status.peers.map { peer in
                    "\(peer.endpoint.description) [\(peer.state.rawValue)]: \(peer.message)"
                })

                if failed > 0 {
                    bridgeMessageColor = .systemRed
                } else if connecting > 0 {
                    bridgeMessageColor = .systemOrange
                } else if connected == status.peers.count {
                    bridgeMessageColor = .systemGreen
                }
            }

            bridgeMessageLabel.stringValue = bridgeMessages.joined(separator: "\n")
            bridgeMessageLabel.textColor = bridgeMessageColor
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
                let bridgeStatus = PrivateNetworkRuntimeRegistry.shared.configureBridge(
                    identifier: identifier,
                    bridgeConfig: privateNetwork.bridge,
                    dhcpRange: dhcpRange
                )
                let switchStatus = PrivateNetworkRuntimeRegistry.shared.configureSwitch(
                    identifier: identifier,
                    switchConfig: privateNetwork.switch,
                    dhcpRange: dhcpRange
                )
                setPanelMessage("Saved network config.")
                updateTransportControls()
                updateStatus(bridgeStatus: bridgeStatus, switchStatus: switchStatus)
            } catch {
                setPanelMessage(error.localizedDescription, isError: true)
            }
        }
        actions.onRefresh = {
            updateStatus()
            setPanelMessage("Refreshed status.")
        }
        actions.onAddPeer = {
            do {
                let peer = try parseEndpoint(
                    host: peerHostField.stringValue,
                    port: peerPortField.stringValue,
                    context: "private network bridge peer"
                )
                guard !peersTable.peers.contains(peer) else {
                    throw AppError("private network bridge peers contains duplicate endpoint \(peer.description).")
                }
                var peers = peersTable.peers
                peers.append(peer)
                peersTable.peers = peers
                peersTable.selectRowIndexes(IndexSet(integer: peers.count - 1), byExtendingSelection: false)
                peerHostField.stringValue = ""
                peerPortField.stringValue = "7777"
                setPanelMessage("Added peer \(peer.description).")
            } catch {
                setPanelMessage(error.localizedDescription, isError: true)
            }
        }
        actions.onRemovePeer = {
            guard !peersTable.peers.isEmpty else {
                setPanelMessage("No peer selected.")
                return
            }
            let selectedRow = peersTable.selectedRow
            var peers = peersTable.peers
            let index = selectedRow >= 0 ? selectedRow : peers.count - 1
            guard index < peers.count else { return }
            let removedPeer = peers.remove(at: index)
            peersTable.peers = peers
            setPanelMessage("Removed peer \(removedPeer.description).")
        }
        actions.onBridgeToggle = {
            if bridgeEnabled.state == .on {
                switchEnabled.state = .off
                setPanelMessage("Bridge enabled; Web Switch disabled.")
            } else {
                setPanelMessage("Bridge disabled.")
            }
            updateTransportControls()
            updateStatus()
        }
        actions.onSwitchToggle = {
            if switchEnabled.state == .on {
                bridgeEnabled.state = .off
                setPanelMessage("Web Switch enabled; Bridge disabled.")
            } else {
                setPanelMessage("Web Switch disabled.")
            }
            updateTransportControls()
            updateStatus()
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
        addPeerButton.target = actions
        addPeerButton.action = #selector(NetworkConfigPanelActions.addPeer)
        removePeerButton.target = actions
        removePeerButton.action = #selector(NetworkConfigPanelActions.removePeer)
        bridgeEnabled.target = actions
        bridgeEnabled.action = #selector(NetworkConfigPanelActions.bridgeToggle)
        switchEnabled.target = actions
        switchEnabled.action = #selector(NetworkConfigPanelActions.switchToggle)

        loadFields()
        do {
            let savedPrivateNetwork = try store.load().privateNetworks[identifier]
            let dhcpRange = try savedPrivateNetwork?.dhcp.flatMap { dhcp -> PrivateNetworkDHCPLeaseRange? in
                dhcp.enabled ? try PrivateNetworkDHCPLeaseRange(config: dhcp) : nil
            }
            let bridgeStatus = !PrivateNetworkRuntimeRegistry.shared.hasBridge(identifier: identifier)
                && savedPrivateNetwork?.bridge != nil
                ? PrivateNetworkRuntimeRegistry.shared.configureBridge(
                    identifier: identifier,
                    bridgeConfig: savedPrivateNetwork?.bridge,
                    dhcpRange: dhcpRange ?? nil
                )
                : PrivateNetworkRuntimeRegistry.shared.bridgeStatus(identifier: identifier)
            let switchStatus = !PrivateNetworkRuntimeRegistry.shared.hasSwitch(identifier: identifier)
                && savedPrivateNetwork?.switch?.enabled == true
                ? PrivateNetworkRuntimeRegistry.shared.configureSwitch(
                    identifier: identifier,
                    switchConfig: savedPrivateNetwork?.switch,
                    dhcpRange: dhcpRange ?? nil
                )
                : PrivateNetworkRuntimeRegistry.shared.switchStatus(identifier: identifier)
            updateStatus(bridgeStatus: bridgeStatus, switchStatus: switchStatus)
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
