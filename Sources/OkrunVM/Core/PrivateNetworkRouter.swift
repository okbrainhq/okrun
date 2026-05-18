import Foundation

enum PrivateNetworkTransportRoute: Equatable {
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
    }

    private struct LocalFrameSendPlan {
        var transport: PrivateNetworkRoutableTransport?
        var logsNoReachableTransport: Bool

        static let none = LocalFrameSendPlan(
            transport: nil,
            logsNoReachableTransport: false
        )
    }

    private static let queueKey = DispatchSpecificKey<UUID>()

    private let identifier: String
    private let queueID = UUID()
    private let queue: DispatchQueue
    private var runtimes: [WeakRuntime] = []
    private var webSwitch: PrivateNetworkRoutableTransport?
    private var localMACs = Set<EthernetAddress>()
    private var remoteRoutes: [EthernetAddress: PrivateNetworkTransportRoute] = [:]

    init(identifier: String) {
        self.identifier = identifier
        queue = DispatchQueue(label: "okrun.private-network-router.\(identifier).\(UUID().uuidString)")
        queue.setSpecific(key: Self.queueKey, value: queueID)
    }

    func setWebSwitch(_ webSwitch: PrivateNetworkRoutableTransport?) {
        runOnQueue {
            self.webSwitch = webSwitch
            if webSwitch == nil {
                self.remoteRoutes.removeAll()
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
            return webSwitchSendPlanOnQueue(logsNoReachableTransport: true)
        }

        localMACs.insert(header.source)
        if header.destination.isUnicast, localMACs.contains(header.destination) {
            return .none
        }

        guard header.destination.isUnicast else {
            return webSwitchSendPlanOnQueue(logsNoReachableTransport: true)
        }

        guard remoteRoutes[header.destination] != nil else {
            return webSwitchSendPlanOnQueue(logsNoReachableTransport: true)
        }

        return webSwitchSendPlanOnQueue(logsNoReachableTransport: false)
    }

    private func remoteFrameActionOnQueue(_ frame: Data, via route: PrivateNetworkTransportRoute) -> RemoteFrameAction {
        guard let header = EthernetFrameHeader.parse(frame) else {
            return .inject(localGuestRuntimesOnQueue())
        }

        if localMACs.contains(header.source) {
            return .drop
        }

        remoteRoutes[header.source] = route
        return .inject(localGuestRuntimesOnQueue())
    }

    private func webSwitchSendPlanOnQueue(logsNoReachableTransport: Bool) -> LocalFrameSendPlan {
        LocalFrameSendPlan(
            transport: webSwitch,
            logsNoReachableTransport: logsNoReachableTransport
        )
    }

    private func sendFrame(_ frame: Data, using plan: LocalFrameSendPlan) {
        guard let transport = plan.transport else {
            if plan.logsNoReachableTransport {
                logNoReachableTransport()
            }
            return
        }

        guard transport.canSendPrivateNetworkFrames else {
            if plan.logsNoReachableTransport {
                logNoReachableTransport()
            }
            return
        }

        AppLog.virtualMachine.debug(
            "Private network router sending frame privateNetwork=\(self.identifier, privacy: .public) route=web-switch bytes=\(frame.count, privacy: .public)"
        )
        transport.sendFrameToRemote(frame)
    }

    private func logNoReachableTransport() {
        AppLog.virtualMachine.debug(
            "Private network router has no reachable remote transport privateNetwork=\(self.identifier, privacy: .public)"
        )
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

    private func runOnQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) == queueID {
            return work()
        }
        return queue.sync(execute: work)
    }
}

extension PrivateNetworkSwitchTransport: PrivateNetworkRoutableTransport {
    var canSendPrivateNetworkFrames: Bool {
        canSendFrames()
    }
}
