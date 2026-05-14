import AppKit

private final class NetworkConfigPanelActions: NSObject {
    var onApply: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onClose: (() -> Void)?
    var onAddPeer: (() -> Void)?
    var onRemovePeer: (() -> Void)?

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
        backgroundColor = isHeader ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.16, alpha: 1)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor

        let hostLabel = NSTextField(labelWithString: host)
        hostLabel.translatesAutoresizingMaskIntoConstraints = false
        hostLabel.font = isHeader ? .systemFont(ofSize: 12, weight: .semibold) : .monospacedSystemFont(ofSize: 12, weight: .regular)
        hostLabel.textColor = .labelColor
        hostLabel.lineBreakMode = .byTruncatingMiddle

        let portLabel = NSTextField(labelWithString: port)
        portLabel.translatesAutoresizingMaskIntoConstraints = false
        portLabel.font = hostLabel.font
        portLabel.textColor = .labelColor
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
        layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1).cgColor
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
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 780),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Private Network"
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel
        panel.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor

        let title = NSTextField(labelWithString: "Private Network")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        let pathLabel = NSTextField(labelWithString: store.home.privateNetworksURL.path)
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
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
        peerHostField.placeholderString = "172.16.0.10"
        let peerPortField = makeNetworkField(identifier: "okrun.network.bridge.peer-port")
        peerPortField.placeholderString = "7777"
        peerPortField.stringValue = "7777"
        let addPeerButton = NSButton(title: "Add Peer", target: nil, action: nil)
        addPeerButton.setAccessibilityIdentifier("okrun.network.bridge.peer-add")
        addPeerButton.bezelStyle = .rounded
        let removePeerButton = NSButton(title: "Remove Peer", target: nil, action: nil)
        removePeerButton.setAccessibilityIdentifier("okrun.network.bridge.peer-remove")
        removePeerButton.bezelStyle = .rounded

        let peerControls = NSStackView(views: [peerHostField, peerPortField, addPeerButton, removePeerButton])
        peerControls.translatesAutoresizingMaskIntoConstraints = false
        peerControls.orientation = .horizontal
        peerControls.alignment = .centerY
        peerControls.spacing = 8
        peerPortField.widthAnchor.constraint(equalToConstant: 88).isActive = true
        addPeerButton.widthAnchor.constraint(equalToConstant: 96).isActive = true
        removePeerButton.widthAnchor.constraint(equalToConstant: 116).isActive = true

        let peersTable = NetworkPeerListView()
        peersTable.heightAnchor.constraint(equalToConstant: 112).isActive = true

        let bindStatusLabel = makeNetworkStatusLabel(identifier: "okrun.network.status.bind")
        let peerStatusLabel = makeNetworkStatusLabel(identifier: "okrun.network.status.peers")
        let messageLabel = makeNetworkStatusLabel(identifier: "okrun.network.status.message")
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2

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

        let dhcpSectionTitle = makeNetworkSectionTitle("DHCP Settings")
        let bridgeSectionTitle = makeNetworkSectionTitle("Bridge Settings")
        let statusSectionTitle = makeNetworkSectionTitle("Bridge Status")
        let dhcpSeparator = makeNetworkSeparator()
        let bridgeSeparator = makeNetworkSeparator()

        let statusGrid = NSGridView(views: [
            [makeNetworkLabel("Bind Status"), bindStatusLabel],
            [makeNetworkLabel("Peer Status"), peerStatusLabel],
            [makeNetworkLabel("Message"), messageLabel]
        ])
        configureNetworkGrid(statusGrid)

        let dhcpGrid = NSGridView(views: [
            [makeNetworkLabel("DHCP"), dhcpEnabled],
            [makeNetworkLabel("CIDR"), cidrField],
            [makeNetworkLabel("Range Start"), rangeStartField],
            [makeNetworkLabel("Range End"), rangeEndField],
            [makeNetworkLabel("Lease Seconds"), leaseField]
        ])
        configureNetworkGrid(dhcpGrid)

        let bridgeGrid = NSGridView(views: [
            [makeNetworkLabel("Bridge"), bridgeEnabled],
            [makeNetworkLabel("Bind"), bindEnabled],
            [makeNetworkLabel("Bind Host"), bindHostField],
            [makeNetworkLabel("Bind Port"), bindPortField],
            [makeNetworkLabel("Add Peer"), peerControls],
            [makeNetworkLabel("Peers"), peersTable]
        ])
        configureNetworkGrid(bridgeGrid)

        let buttonRow = NSStackView(views: [refreshButton, closeButton, applyButton])
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 12

        content.addSubview(title)
        content.addSubview(pathLabel)
        content.addSubview(dhcpSectionTitle)
        content.addSubview(dhcpGrid)
        content.addSubview(dhcpSeparator)
        content.addSubview(bridgeSectionTitle)
        content.addSubview(bridgeGrid)
        content.addSubview(bridgeSeparator)
        content.addSubview(statusSectionTitle)
        content.addSubview(statusGrid)
        content.addSubview(buttonRow)
        panel.contentView = content

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            pathLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            pathLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            dhcpSectionTitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            dhcpSectionTitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            dhcpSectionTitle.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 20),
            dhcpGrid.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            dhcpGrid.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            dhcpGrid.topAnchor.constraint(equalTo: dhcpSectionTitle.bottomAnchor, constant: 8),
            dhcpSeparator.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            dhcpSeparator.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            dhcpSeparator.topAnchor.constraint(equalTo: dhcpGrid.bottomAnchor, constant: 16),
            dhcpSeparator.heightAnchor.constraint(equalToConstant: 1),
            bridgeSectionTitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            bridgeSectionTitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            bridgeSectionTitle.topAnchor.constraint(equalTo: dhcpSeparator.bottomAnchor, constant: 14),
            bridgeGrid.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            bridgeGrid.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            bridgeGrid.topAnchor.constraint(equalTo: bridgeSectionTitle.bottomAnchor, constant: 8),
            bridgeSeparator.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            bridgeSeparator.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            bridgeSeparator.topAnchor.constraint(equalTo: bridgeGrid.bottomAnchor, constant: 16),
            bridgeSeparator.heightAnchor.constraint(equalToConstant: 1),
            statusSectionTitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            statusSectionTitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            statusSectionTitle.topAnchor.constraint(equalTo: bridgeSeparator.bottomAnchor, constant: 14),
            statusGrid.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            statusGrid.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            statusGrid.topAnchor.constraint(equalTo: statusSectionTitle.bottomAnchor, constant: 8),
            statusGrid.bottomAnchor.constraint(lessThanOrEqualTo: buttonRow.topAnchor, constant: -24),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            refreshButton.widthAnchor.constraint(equalToConstant: 100),
            closeButton.widthAnchor.constraint(equalToConstant: 100),
            applyButton.widthAnchor.constraint(equalToConstant: 142)
        ])

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
                messageLabel.stringValue = "Loaded network config."
                messageLabel.textColor = .secondaryLabelColor
            } catch {
                messageLabel.stringValue = error.localizedDescription
                messageLabel.textColor = .systemRed
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

            return HostPrivateNetworkConfig(dhcp: dhcp, bridge: bridge)
        }

        func updateStatus(_ status: PrivateNetworkBridgeStatus = PrivateNetworkRuntimeRegistry.shared.bridgeStatus(identifier: identifier)) {
            bindStatusLabel.stringValue = status.bindMessage
            bindStatusLabel.textColor = status.isListening ? .systemGreen : .secondaryLabelColor

            if let error = status.errorMessage {
                peerStatusLabel.stringValue = "Error"
                peerStatusLabel.textColor = .systemRed
                messageLabel.stringValue = error
                messageLabel.textColor = .systemRed
                return
            }

            if status.peers.isEmpty {
                peerStatusLabel.stringValue = "No peers"
                peerStatusLabel.textColor = .secondaryLabelColor
                return
            }

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
                peerStatusLabel.textColor = connected == status.peers.count ? .systemGreen : .secondaryLabelColor
            }

            messageLabel.stringValue = status.peers.map { peer in
                "\(peer.endpoint.description) [\(peer.state.rawValue)]: \(peer.message)"
            }.joined(separator: "\n")
            messageLabel.textColor = failed > 0
                ? .systemRed
                : (status.peers.allSatisfy(\.isConnected) ? .systemGreen : .systemOrange)
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
                let status = PrivateNetworkRuntimeRegistry.shared.configureBridge(
                    identifier: identifier,
                    bridgeConfig: privateNetwork.bridge,
                    dhcpRange: dhcpRange
                )
                messageLabel.stringValue = "Saved network config."
                messageLabel.textColor = .secondaryLabelColor
                updateStatus(status)
            } catch {
                messageLabel.stringValue = error.localizedDescription
                messageLabel.textColor = .systemRed
            }
        }
        actions.onRefresh = {
            updateStatus()
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
                messageLabel.stringValue = "Added peer \(peer.description)."
                messageLabel.textColor = .secondaryLabelColor
            } catch {
                messageLabel.stringValue = error.localizedDescription
                messageLabel.textColor = .systemRed
            }
        }
        actions.onRemovePeer = {
            guard !peersTable.peers.isEmpty else {
                messageLabel.stringValue = "No peer selected."
                messageLabel.textColor = .secondaryLabelColor
                return
            }
            let selectedRow = peersTable.selectedRow
            var peers = peersTable.peers
            let index = selectedRow >= 0 ? selectedRow : peers.count - 1
            guard index < peers.count else { return }
            let removedPeer = peers.remove(at: index)
            peersTable.peers = peers
            messageLabel.stringValue = "Removed peer \(removedPeer.description)."
            messageLabel.textColor = .secondaryLabelColor
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

        loadFields()
        if !PrivateNetworkRuntimeRegistry.shared.hasBridge(identifier: identifier),
           let bridge = (try? store.load().privateNetworks[identifier]?.bridge),
           let privateNetwork = try? readForm() {
            let dhcpRange = try? privateNetwork.dhcp.flatMap { dhcp -> PrivateNetworkDHCPLeaseRange? in
                dhcp.enabled ? try PrivateNetworkDHCPLeaseRange(config: dhcp) : nil
            }
            updateStatus(PrivateNetworkRuntimeRegistry.shared.configureBridge(
                identifier: identifier,
                bridgeConfig: bridge,
                dhcpRange: dhcpRange ?? nil
            ))
        } else {
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
        return button
    }

    private func makeNetworkField(identifier: String) -> NSTextField {
        let field = NSTextField(string: "")
        field.setAccessibilityIdentifier(identifier)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .systemFont(ofSize: 13)
        field.controlSize = .large
        return field
    }

    private func makeNetworkSectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        return label
    }

    private func makeNetworkSeparator() -> NSView {
        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        return separator
    }

    private func makeNetworkLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeNetworkStatusLabel(identifier: String) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.setAccessibilityIdentifier(identifier)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        return label
    }

    private func configureNetworkGrid(_ grid: NSGridView) {
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 116
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 1).width = 500
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
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
