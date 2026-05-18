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

    private enum RemoteFrameAction {
        case drop
        case inject([PrivateNetworkRuntime])
        case checkBridgeBeforeWebSwitch(source: EthernetAddress, bridge: PrivateNetworkRoutableTransport)
    }

    private enum SendMode {
        case firstReachable
        case allReachable
    }

    private struct LocalFrameSendPlan {
        var mode: SendMode
        var transports: [PrivateNetworkRoutableTransport]
        var logsNoReachableTransport: Bool

        static let none = LocalFrameSendPlan(
            mode: .firstReachable,
            transports: [],
            logsNoReachableTransport: false
        )
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
        let plan = runOnQueue {
            self.localFrameSendPlanOnQueue(frame)
        }
        sendFrame(frame, using: plan)
    }

    func receiveRemoteFrame(_ frame: Data, via route: PrivateNetworkTransportRoute) {
        let action = runOnQueue {
            self.remoteFrameActionOnQueue(frame, via: route)
        }

        switch action {
        case .drop:
            return
        case .inject(let runtimes):
            injectFrame(frame, to: runtimes)
        case .checkBridgeBeforeWebSwitch(let source, let bridge):
            let canSendViaBridge = bridge.canSendPrivateNetworkFrames
            let runtimes = runOnQueue {
                self.remoteWebSwitchRuntimesOnQueue(source: source, canSendViaBridge: canSendViaBridge)
            }
            injectFrame(frame, to: runtimes)
        }
    }

    private func routeLocalFrame(_ frame: Data, from runtime: PrivateNetworkRuntime) {
        let plan = runOnQueue {
            guard self.runtimes.contains(where: { $0.runtime === runtime }) else {
                return LocalFrameSendPlan.none
            }
            return self.localFrameSendPlanOnQueue(frame)
        }
        sendFrame(frame, using: plan)
    }

    private func localFrameSendPlanOnQueue(_ frame: Data) -> LocalFrameSendPlan {
        guard let header = EthernetFrameHeader.parse(frame) else {
            return discoveryFrameSendPlanOnQueue()
        }

        localMACs.insert(header.source)
        if header.destination.isUnicast, localMACs.contains(header.destination) {
            return .none
        }

        guard header.destination.isUnicast,
              let route = remoteRoutes[header.destination] else {
            return discoveryFrameSendPlanOnQueue()
        }

        switch route {
        case .bridge:
            return LocalFrameSendPlan(
                mode: .firstReachable,
                transports: transports(for: [.bridge, .webSwitch]),
                logsNoReachableTransport: false
            )
        case .webSwitch:
            return LocalFrameSendPlan(
                mode: .firstReachable,
                transports: transports(for: [.webSwitch, .bridge]),
                logsNoReachableTransport: false
            )
        }
    }

    private func remoteFrameActionOnQueue(_ frame: Data, via route: PrivateNetworkTransportRoute) -> RemoteFrameAction {
        guard let header = EthernetFrameHeader.parse(frame) else {
            return .inject(localGuestRuntimesOnQueue())
        }

        if localMACs.contains(header.source) {
            return .drop
        }

        if route == .bridge {
            remoteRoutes[header.source] = .bridge
            return .inject(localGuestRuntimesOnQueue())
        }

        if remoteRoutes[header.source] == .bridge,
           let bridge {
            return .checkBridgeBeforeWebSwitch(source: header.source, bridge: bridge)
        }

        remoteRoutes[header.source] = .webSwitch
        return .inject(localGuestRuntimesOnQueue())
    }

    private func remoteWebSwitchRuntimesOnQueue(
        source: EthernetAddress,
        canSendViaBridge: Bool
    ) -> [PrivateNetworkRuntime] {
        if localMACs.contains(source) {
            return []
        }
        if canSendViaBridge, remoteRoutes[source] == .bridge {
            return []
        }

        remoteRoutes[source] = .webSwitch
        return localGuestRuntimesOnQueue()
    }

    private func discoveryFrameSendPlanOnQueue() -> LocalFrameSendPlan {
        LocalFrameSendPlan(
            mode: .allReachable,
            transports: transports(for: [.bridge, .webSwitch]),
            logsNoReachableTransport: true
        )
    }

    private func sendFrame(_ frame: Data, using plan: LocalFrameSendPlan) {
        guard !plan.transports.isEmpty else {
            if plan.logsNoReachableTransport {
                logNoReachableTransport()
            }
            return
        }

        var didSend = false
        for transport in plan.transports {
            guard transport.canSendPrivateNetworkFrames else { continue }
            transport.sendFrameToRemote(frame)
            didSend = true
            if plan.mode == .firstReachable {
                return
            }
        }

        if !didSend, plan.logsNoReachableTransport {
            logNoReachableTransport()
        }
    }

    private func logNoReachableTransport() {
        AppLog.virtualMachine.debug(
            "Private network router has no reachable remote transport privateNetwork=\(self.identifier, privacy: .public)"
        )
    }

    private func transports(for routes: [PrivateNetworkTransportRoute]) -> [PrivateNetworkRoutableTransport] {
        routes.compactMap { transport(for: $0) }
    }

    private func injectFrame(_ frame: Data, to runtimes: [PrivateNetworkRuntime]) {
        for runtime in runtimes {
            runtime.injectFrameToGuest(frame)
        }
    }

    private func localGuestRuntimesOnQueue() -> [PrivateNetworkRuntime] {
        runtimes.removeAll { $0.runtime == nil }
        return runtimes.compactMap(\.runtime)
    }

    private func transport(for route: PrivateNetworkTransportRoute) -> PrivateNetworkRoutableTransport? {
        switch route {
        case .bridge:
            return bridge
        case .webSwitch:
            return webSwitch
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
