import Foundation

enum PrivateNetworkTransportRoute: Equatable {
    case bridge
    case webSwitch
}

protocol PrivateNetworkRoutableTransport: AnyObject {
    var canSendPrivateNetworkFrames: Bool { get }

    func sendFrameToRemote(_ frame: Data)
}

final class PrivateNetworkTransportRouter {
    private struct WeakRuntime {
        weak var runtime: PrivateNetworkRuntime?
    }

    private static let queueKey = DispatchSpecificKey<UUID>()

    private let identifier: String
    private let queueID = UUID()
    private let queue: DispatchQueue
    private var runtimes: [WeakRuntime] = []
    private var bridge: PrivateNetworkRoutableTransport?
    private var webSwitch: PrivateNetworkRoutableTransport?
    private var localMACs = Set<EthernetAddress>()
    private var remoteRoutes: [EthernetAddress: PrivateNetworkTransportRoute] = [:]

    init(identifier: String) {
        self.identifier = identifier
        queue = DispatchQueue(label: "okrun.private-network-router.\(identifier).\(UUID().uuidString)")
        queue.setSpecific(key: Self.queueKey, value: queueID)
    }

    func setBridge(_ bridge: PrivateNetworkRoutableTransport?) {
        runOnQueue {
            self.bridge = bridge
            if bridge == nil {
                self.remoteRoutes = self.remoteRoutes.filter { $0.value != .bridge }
            }
        }
    }

    func setWebSwitch(_ webSwitch: PrivateNetworkRoutableTransport?) {
        runOnQueue {
            self.webSwitch = webSwitch
            if webSwitch == nil {
                self.remoteRoutes = self.remoteRoutes.filter { $0.value != .webSwitch }
            }
        }
    }

    func addRuntime(_ runtime: PrivateNetworkRuntime) {
        runtime.addFrameObserver { [weak self, weak runtime] direction, frame in
            guard direction == .fromGuest, let runtime else { return }
            self?.routeLocalFrame(frame, from: runtime)
        }

        runOnQueue {
            self.runtimes.removeAll { $0.runtime == nil || $0.runtime === runtime }
            self.runtimes.append(WeakRuntime(runtime: runtime))
        }
    }

    func removeRuntime(_ runtime: PrivateNetworkRuntime) {
        runOnQueue {
            self.runtimes.removeAll { $0.runtime == nil || $0.runtime === runtime }
        }
    }

    func hasRuntimes() -> Bool {
        runOnQueue {
            self.runtimes.removeAll { $0.runtime == nil }
            return !self.runtimes.isEmpty
        }
    }

    func routeLocalFrame(_ frame: Data) {
        runOnQueue {
            self.routeLocalFrameOnQueue(frame)
        }
    }

    func receiveRemoteFrame(_ frame: Data, via route: PrivateNetworkTransportRoute) {
        runOnQueue {
            if let header = EthernetFrameHeader.parse(frame) {
                if self.localMACs.contains(header.source) {
                    return
                }

                if route == .bridge {
                    self.remoteRoutes[header.source] = .bridge
                } else if self.remoteRoutes[header.source] == .bridge,
                          self.canSendViaBridge() {
                    return
                } else {
                    self.remoteRoutes[header.source] = .webSwitch
                }
            }

            self.injectFrameToLocalGuests(frame)
        }
    }

    private func routeLocalFrame(_ frame: Data, from runtime: PrivateNetworkRuntime) {
        runOnQueue {
            guard self.runtimes.contains(where: { $0.runtime === runtime }) else { return }
            self.routeLocalFrameOnQueue(frame)
        }
    }

    private func routeLocalFrameOnQueue(_ frame: Data) {
        guard let header = EthernetFrameHeader.parse(frame) else {
            sendDiscoveryFrame(frame)
            return
        }

        localMACs.insert(header.source)
        if header.destination.isUnicast, localMACs.contains(header.destination) {
            return
        }

        guard header.destination.isUnicast,
              let route = remoteRoutes[header.destination] else {
            sendDiscoveryFrame(frame)
            return
        }

        switch route {
        case .bridge:
            if sendFrame(frame, via: .bridge) { return }
            _ = sendFrame(frame, via: .webSwitch)
        case .webSwitch:
            if sendFrame(frame, via: .webSwitch) { return }
            _ = sendFrame(frame, via: .bridge)
        }
    }

    private func sendDiscoveryFrame(_ frame: Data) {
        let sentBridge = sendFrame(frame, via: .bridge)
        let sentSwitch = sendFrame(frame, via: .webSwitch)
        if !sentBridge && !sentSwitch {
            AppLog.virtualMachine.debug(
                "Private network router has no reachable remote transport privateNetwork=\(self.identifier, privacy: .public)"
            )
        }
    }

    @discardableResult
    private func sendFrame(_ frame: Data, via route: PrivateNetworkTransportRoute) -> Bool {
        guard let transport = transport(for: route),
              transport.canSendPrivateNetworkFrames else {
            return false
        }
        transport.sendFrameToRemote(frame)
        return true
    }

    private func transport(for route: PrivateNetworkTransportRoute) -> PrivateNetworkRoutableTransport? {
        switch route {
        case .bridge:
            return bridge
        case .webSwitch:
            return webSwitch
        }
    }

    private func canSendViaBridge() -> Bool {
        bridge?.canSendPrivateNetworkFrames == true
    }

    private func injectFrameToLocalGuests(_ frame: Data) {
        runtimes.removeAll { $0.runtime == nil }
        for weakRuntime in runtimes {
            weakRuntime.runtime?.injectFrameToGuest(frame)
        }
    }

    private func runOnQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) == queueID {
            return work()
        }
        return queue.sync(execute: work)
    }
}

extension PrivateNetworkBridge: PrivateNetworkRoutableTransport {
    var canSendPrivateNetworkFrames: Bool {
        hasActiveConnections()
    }
}

extension PrivateNetworkSwitchBridge: PrivateNetworkRoutableTransport {
    var canSendPrivateNetworkFrames: Bool {
        canSendFrames()
    }
}
