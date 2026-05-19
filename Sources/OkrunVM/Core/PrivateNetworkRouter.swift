import Foundation

enum PrivateNetworkTransportRoute: Equatable {
    case localSwitch
    case webSwitch

    var logName: String {
        switch self {
        case .localSwitch:
            return "local-switch"
        case .webSwitch:
            return "web-switch"
        }
    }
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

    private struct RemoteRouteEntry {
        var route: PrivateNetworkTransportRoute
        var updatedAt: Date
    }

    private struct LocalFrameSendPlan {
        var transport: PrivateNetworkRoutableTransport?
        var route: PrivateNetworkTransportRoute?
        var fallbackTransport: PrivateNetworkRoutableTransport?
        var fallbackRoute: PrivateNetworkTransportRoute?
        var logsNoReachableTransport: Bool

        static let none = LocalFrameSendPlan(
            transport: nil,
            route: nil,
            fallbackTransport: nil,
            fallbackRoute: nil,
            logsNoReachableTransport: false
        )
    }

    private static let queueKey = DispatchSpecificKey<UUID>()
    private static let defaultMacTtl: TimeInterval = 5 * 60

    private let identifier: String
    private let queueID = UUID()
    private let queue: DispatchQueue
    private let macTtl: TimeInterval
    private let now: () -> Date
    private var runtimes: [WeakRuntime] = []
    private var localSwitch: PrivateNetworkRoutableTransport?
    private var webSwitch: PrivateNetworkRoutableTransport?
    private var localMACs: [EthernetAddress: Date] = [:]
    private var remoteRoutes: [EthernetAddress: RemoteRouteEntry] = [:]

    init(
        identifier: String,
        macTtl: TimeInterval = defaultMacTtl,
        now: @escaping () -> Date = Date.init
    ) {
        self.identifier = identifier
        self.macTtl = macTtl
        self.now = now
        queue = DispatchQueue(label: "okrun.private-network-router.\(identifier).\(UUID().uuidString)")
        queue.setSpecific(key: Self.queueKey, value: queueID)
    }

    func setWebSwitch(_ webSwitch: PrivateNetworkRoutableTransport?) {
        runOnQueue {
            self.webSwitch = webSwitch
            if webSwitch == nil {
                self.removeRemoteRoutesOnQueue(.webSwitch)
            }
        }
    }

    func setLocalSwitch(_ localSwitch: PrivateNetworkRoutableTransport?) {
        runOnQueue {
            self.localSwitch = localSwitch
            if localSwitch == nil {
                self.removeRemoteRoutesOnQueue(.localSwitch)
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
        let currentDate = now()
        expireMacsOnQueue(now: currentDate)
        guard let header = EthernetFrameHeader.parse(frame) else {
            return remoteSendPlanOnQueue(logsNoReachableTransport: true)
        }

        localMACs[header.source] = currentDate
        if header.destination.isUnicast, localMACs[header.destination] != nil {
            return .none
        }

        guard header.destination.isUnicast else {
            return remoteSendPlanOnQueue(logsNoReachableTransport: true)
        }

        guard remoteRoutes[header.destination] != nil else {
            return remoteSendPlanOnQueue(logsNoReachableTransport: true)
        }

        return remoteSendPlanOnQueue(logsNoReachableTransport: false)
    }

    private func remoteFrameActionOnQueue(_ frame: Data, via route: PrivateNetworkTransportRoute) -> RemoteFrameAction {
        let currentDate = now()
        expireMacsOnQueue(now: currentDate)
        guard let header = EthernetFrameHeader.parse(frame) else {
            return .inject(localGuestRuntimesOnQueue())
        }

        if localMACs[header.source] != nil {
            return .drop
        }

        remoteRoutes[header.source] = RemoteRouteEntry(route: route, updatedAt: currentDate)
        return .inject(localGuestRuntimesOnQueue())
    }

    private func remoteSendPlanOnQueue(logsNoReachableTransport: Bool) -> LocalFrameSendPlan {
        LocalFrameSendPlan(
            transport: localSwitch,
            route: .localSwitch,
            fallbackTransport: webSwitch,
            fallbackRoute: .webSwitch,
            logsNoReachableTransport: logsNoReachableTransport
        )
    }

    private func sendFrame(_ frame: Data, using plan: LocalFrameSendPlan) {
        guard let transport = firstReachableTransport(in: plan) else {
            if plan.logsNoReachableTransport {
                logNoReachableTransport()
            }
            return
        }

        let routeName = transport.route.logName
        AppLog.virtualMachine.debug(
            "Private network router sending frame privateNetwork=\(self.identifier, privacy: .public) route=\(routeName, privacy: .public) bytes=\(frame.count, privacy: .public)"
        )
        transport.transport.sendFrameToRemote(frame)
    }

    private func removeRemoteRoutesOnQueue(_ route: PrivateNetworkTransportRoute) {
        remoteRoutes = remoteRoutes.filter { $0.value.route != route }
    }

    private func expireMacsOnQueue(now currentDate: Date) {
        localMACs = localMACs.filter { currentDate.timeIntervalSince($0.value) <= macTtl }
        remoteRoutes = remoteRoutes.filter { currentDate.timeIntervalSince($0.value.updatedAt) <= macTtl }
    }

    private func firstReachableTransport(
        in plan: LocalFrameSendPlan
    ) -> (transport: PrivateNetworkRoutableTransport, route: PrivateNetworkTransportRoute)? {
        if let transport = plan.transport,
           let route = plan.route,
           transport.canSendPrivateNetworkFrames {
            return (transport, route)
        }

        if let transport = plan.fallbackTransport,
           let route = plan.fallbackRoute,
           transport.canSendPrivateNetworkFrames {
            return (transport, route)
        }

        return nil
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
