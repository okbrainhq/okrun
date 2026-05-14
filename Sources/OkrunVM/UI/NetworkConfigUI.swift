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

private final class NetworkPeerTableDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var peers: [PrivateNetworkBridgeEndpoint] = []

    func numberOfRows(in tableView: NSTableView) -> Int {
        peers.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < peers.count else { return nil }
        let peer = peers[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "host":
            value = peer.host
        case "port":
            value = "\(peer.port)"
        default:
            value = peer.description
        }

        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: value)
        text.translatesAutoresizingMaskIntoConstraints = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

extension AppDelegate {
    @objc func openNetworkConfig() {
        let identifier = PrivateNetworkConfig.defaultIdentifier
        let store = HostNetworkConfigStore()
        var timer: Timer?

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 740),
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

        let peerDataSource = NetworkPeerTableDataSource()
        let peersTable = NSTableView()
        peersTable.setAccessibilityIdentifier("okrun.network.bridge.peer-list")
        peersTable.delegate = peerDataSource
        peersTable.dataSource = peerDataSource
        peersTable.usesAlternatingRowBackgroundColors = true
        peersTable.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1)
        peersTable.rowHeight = 24
        let hostColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("host"))
        hostColumn.title = "Host"
        hostColumn.width = 360
        let portColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("port"))
        portColumn.title = "Port"
        portColumn.width = 112
        peersTable.addTableColumn(hostColumn)
        peersTable.addTableColumn(portColumn)

        let peersScroll = NSScrollView()
        peersScroll.translatesAutoresizingMaskIntoConstraints = false
        peersScroll.borderType = .bezelBorder
        peersScroll.hasVerticalScroller = true
        peersScroll.documentView = peersTable
        peersScroll.heightAnchor.constraint(equalToConstant: 96).isActive = true

        let bindStatusLabel = makeNetworkStatusLabel(identifier: "okrun.network.status.bind")
        let peerStatusLabel = makeNetworkStatusLabel(identifier: "okrun.network.status.peers")
        let messageLabel = makeNetworkStatusLabel(identifier: "okrun.network.status.message")
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 6

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
            [makeNetworkLabel("Peers"), peersScroll]
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
                    peerDataSource.peers = bridge.peers
                    peersTable.reloadData()
                } else {
                    bridgeEnabled.state = .off
                    bindEnabled.state = .off
                    bindHostField.stringValue = ""
                    bindPortField.stringValue = "7777"
                    peerDataSource.peers = []
                    peersTable.reloadData()
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
            peerDataSource.peers
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
                guard !peerDataSource.peers.contains(peer) else {
                    throw AppError("private network bridge peers contains duplicate endpoint \(peer.description).")
                }
                peerDataSource.peers.append(peer)
                peersTable.reloadData()
                peersTable.selectRowIndexes(IndexSet(integer: peerDataSource.peers.count - 1), byExtendingSelection: false)
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
            guard !peerDataSource.peers.isEmpty else {
                messageLabel.stringValue = "No peer selected."
                messageLabel.textColor = .secondaryLabelColor
                return
            }
            let selectedRow = peersTable.selectedRow
            let index = selectedRow >= 0 ? selectedRow : peerDataSource.peers.count - 1
            guard index < peerDataSource.peers.count else { return }
            let removedPeer = peerDataSource.peers.remove(at: index)
            peersTable.reloadData()
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
        if let bridge = (try? store.load().privateNetworks[identifier]?.bridge),
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

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            updateStatus()
        }

        if let parent = NSApp.keyWindow {
            panel.setFrameOrigin(NSPoint(
                x: parent.frame.midX - panel.frame.width / 2,
                y: parent.frame.midY - panel.frame.height / 2
            ))
        } else {
            panel.center()
        }

        NSApp.runModal(for: panel)
        timer?.invalidate()
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
