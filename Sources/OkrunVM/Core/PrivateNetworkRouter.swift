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

protocol PrivateNetworkLocalEndpoint: AnyObject {
    var privateNetworkMACAddress: EthernetAddress { get }

    func receivePrivateNetworkFrame(_ frame: Data)
}

final class PrivateNetworkTransportRouter {
    private struct WeakRuntime {
        weak var runtime: PrivateNetworkRuntime?
    }

    private struct WeakLocalEndpoint {
        weak var endpoint: PrivateNetworkLocalEndpoint?
    }

    private enum RemoteFrameAction {
        case drop
        case inject(runtimes: [PrivateNetworkRuntime], endpoints: [PrivateNetworkLocalEndpoint])
    }

    private struct RemoteRouteEntry {
        var localUpdatedAt: Date?
        var webUpdatedAt: Date?

        init(localUpdatedAt: Date? = nil, webUpdatedAt: Date? = nil) {
            self.localUpdatedAt = localUpdatedAt
            self.webUpdatedAt = webUpdatedAt
        }

        var hasLocalRoute: Bool {
            localUpdatedAt != nil
        }

        var hasWebRoute: Bool {
            webUpdatedAt != nil
        }

        mutating func record(_ route: PrivateNetworkTransportRoute, at date: Date) {
            switch route {
            case .localSwitch:
                localUpdatedAt = date
            case .webSwitch:
                webUpdatedAt = date
            }
        }

        mutating func remove(_ route: PrivateNetworkTransportRoute) {
            switch route {
            case .localSwitch:
                localUpdatedAt = nil
            case .webSwitch:
                webUpdatedAt = nil
            }
        }

        mutating func expire(now currentDate: Date, ttl: TimeInterval) {
            if let localUpdatedAt, currentDate.timeIntervalSince(localUpdatedAt) > ttl {
                self.localUpdatedAt = nil
            }
            if let webUpdatedAt, currentDate.timeIntervalSince(webUpdatedAt) > ttl {
                self.webUpdatedAt = nil
            }
        }

        var isEmpty: Bool {
            localUpdatedAt == nil && webUpdatedAt == nil
        }
    }

    private struct RemoteFrameFingerprint: Hashable {
        var hash: UInt64
        var byteCount: Int
    }

    private struct RemoteFrameObservation {
        var route: PrivateNetworkTransportRoute
        var updatedAt: Date
    }

    private struct TransportCandidate {
        var transport: PrivateNetworkRoutableTransport?
        var route: PrivateNetworkTransportRoute?
    }

    private struct LocalFrameSendPlan {
        var candidates: [TransportCandidate]
        var sendsToAllReachable: Bool
        var logsNoReachableTransport: Bool

        static let none = LocalFrameSendPlan(
            candidates: [],
            sendsToAllReachable: false,
            logsNoReachableTransport: false
        )
    }

    private static let queueKey = DispatchSpecificKey<UUID>()
    private static let defaultMacTtl: TimeInterval = 5 * 60
    private static let remoteFrameDedupTtl: TimeInterval = 0.25

    private let identifier: String
    private let queueID = UUID()
    private let queue: DispatchQueue
    private let macTtl: TimeInterval
    private let now: () -> Date
    private var runtimes: [WeakRuntime] = []
    private var localEndpoints: [WeakLocalEndpoint] = []
    private var localSwitch: PrivateNetworkRoutableTransport?
    private var webSwitch: PrivateNetworkRoutableTransport?
    private var localMACs: [EthernetAddress: Date] = [:]
    private var remoteRoutes: [EthernetAddress: RemoteRouteEntry] = [:]
    private var remoteFrameFingerprints: [RemoteFrameFingerprint: RemoteFrameObservation] = [:]

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

    func addLocalEndpoint(_ endpoint: PrivateNetworkLocalEndpoint) {
        runOnQueue {
            self.localEndpoints.removeAll { $0.endpoint == nil || $0.endpoint === endpoint }
            self.localEndpoints.append(WeakLocalEndpoint(endpoint: endpoint))
        }
    }

    func removeLocalEndpoint(_ endpoint: PrivateNetworkLocalEndpoint) {
        runOnQueue {
            self.localEndpoints.removeAll { $0.endpoint == nil || $0.endpoint === endpoint }
        }
    }

    func hasLocalEndpoints() -> Bool {
        runOnQueue {
            self.localEndpoints.removeAll { $0.endpoint == nil }
            return !self.localEndpoints.isEmpty
        }
    }

    func hasRuntimes() -> Bool {
        runOnQueue {
            self.runtimes.removeAll { $0.runtime == nil }
            return !self.runtimes.isEmpty
        }
    }

    func routeLocalFrame(_ frame: Data) {
        let result: (plan: LocalFrameSendPlan, endpoints: [PrivateNetworkLocalEndpoint]) = runOnQueue {
            (
                plan: self.localFrameSendPlanOnQueue(frame),
                endpoints: self.localEndpointsForFrameOnQueue(frame)
            )
        }
        deliverFrame(frame, to: result.endpoints)
        sendFrame(frame, using: result.plan)
    }

    func routeLocalEndpointFrame(_ frame: Data) {
        let result: (runtimes: [PrivateNetworkRuntime], plan: LocalFrameSendPlan) = runOnQueue {
            (
                runtimes: self.localGuestRuntimesOnQueue(),
                plan: self.localFrameSendPlanOnQueue(frame)
            )
        }
        injectFrame(frame, to: result.runtimes)
        sendFrame(frame, using: result.plan)
    }

    func receiveRemoteFrame(_ frame: Data, via route: PrivateNetworkTransportRoute) {
        let action = runOnQueue {
            self.remoteFrameActionOnQueue(frame, via: route)
        }

        switch action {
        case .drop:
            return
        case .inject(let runtimes, let endpoints):
            deliverFrame(frame, to: endpoints)
            injectFrame(frame, to: runtimes)
        }
    }

    private func routeLocalFrame(_ frame: Data, from runtime: PrivateNetworkRuntime) {
        let result: (plan: LocalFrameSendPlan, endpoints: [PrivateNetworkLocalEndpoint]) = runOnQueue {
            guard self.runtimes.contains(where: { $0.runtime === runtime }) else {
                return (plan: LocalFrameSendPlan.none, endpoints: [] as [PrivateNetworkLocalEndpoint])
            }
            return (
                plan: self.localFrameSendPlanOnQueue(frame),
                endpoints: self.localEndpointsForFrameOnQueue(frame)
            )
        }
        deliverFrame(frame, to: result.endpoints)
        sendFrame(frame, using: result.plan)
    }

    private func localFrameSendPlanOnQueue(_ frame: Data) -> LocalFrameSendPlan {
        let currentDate = now()
        expireMacsOnQueue(now: currentDate)
        expireRemoteFrameFingerprintsOnQueue(now: currentDate)
        guard let header = EthernetFrameHeader.parse(frame) else {
            return webFirstSendPlanOnQueue(logsNoReachableTransport: true)
        }

        localMACs[header.source] = currentDate
        if header.destination.isUnicast,
           localMACs[header.destination] != nil || localEndpointMACsOnQueue().contains(header.destination) {
            return .none
        }

        guard header.destination.isUnicast else {
            return discoverySendPlanOnQueue(logsNoReachableTransport: true)
        }

        guard let remoteRoute = remoteRoutes[header.destination] else {
            return discoverySendPlanOnQueue(logsNoReachableTransport: true)
        }

        return sendPlanOnQueue(for: remoteRoute, logsNoReachableTransport: false)
    }

    private func remoteFrameActionOnQueue(_ frame: Data, via route: PrivateNetworkTransportRoute) -> RemoteFrameAction {
        let currentDate = now()
        expireMacsOnQueue(now: currentDate)
        expireRemoteFrameFingerprintsOnQueue(now: currentDate)
        let shouldInject = shouldInjectRemoteFrameOnQueue(frame, via: route, now: currentDate)
        guard let header = EthernetFrameHeader.parse(frame) else {
            return shouldInject
                ? .inject(runtimes: localGuestRuntimesOnQueue(), endpoints: localEndpointObjectsOnQueue())
                : .drop
        }

        if localMACs[header.source] != nil || localEndpointMACsOnQueue().contains(header.source) {
            return .drop
        }

        var entry = remoteRoutes[header.source] ?? RemoteRouteEntry()
        entry.record(route, at: currentDate)
        remoteRoutes[header.source] = entry
        guard shouldInject else { return .drop }

        let endpoints = localEndpointsForFrameOnQueue(frame)
        let endpointMACs = localEndpointMACsOnQueue()
        let shouldInjectRuntimes = !(header.destination.isUnicast && endpointMACs.contains(header.destination))
        return .inject(
            runtimes: shouldInjectRuntimes ? localGuestRuntimesOnQueue() : [],
            endpoints: endpoints
        )
    }

    private func sendPlanOnQueue(
        for remoteRoute: RemoteRouteEntry,
        logsNoReachableTransport: Bool
    ) -> LocalFrameSendPlan {
        if remoteRoute.hasLocalRoute {
            return LocalFrameSendPlan(
                candidates: [
                    TransportCandidate(transport: localSwitch, route: .localSwitch),
                    TransportCandidate(transport: webSwitch, route: .webSwitch)
                ],
                sendsToAllReachable: false,
                logsNoReachableTransport: logsNoReachableTransport
            )
        }

        if remoteRoute.hasWebRoute {
            return LocalFrameSendPlan(
                candidates: [
                    TransportCandidate(transport: webSwitch, route: .webSwitch),
                    TransportCandidate(transport: localSwitch, route: .localSwitch)
                ],
                sendsToAllReachable: false,
                logsNoReachableTransport: logsNoReachableTransport
            )
        }

        return webFirstSendPlanOnQueue(logsNoReachableTransport: logsNoReachableTransport)
    }

    private func webFirstSendPlanOnQueue(logsNoReachableTransport: Bool) -> LocalFrameSendPlan {
        LocalFrameSendPlan(
            candidates: [
                TransportCandidate(transport: webSwitch, route: .webSwitch),
                TransportCandidate(transport: localSwitch, route: .localSwitch)
            ],
            sendsToAllReachable: false,
            logsNoReachableTransport: logsNoReachableTransport
        )
    }

    private func discoverySendPlanOnQueue(logsNoReachableTransport: Bool) -> LocalFrameSendPlan {
        LocalFrameSendPlan(
            candidates: [
                TransportCandidate(transport: webSwitch, route: .webSwitch),
                TransportCandidate(transport: localSwitch, route: .localSwitch)
            ],
            sendsToAllReachable: true,
            logsNoReachableTransport: logsNoReachableTransport
        )
    }

    private func sendFrame(_ frame: Data, using plan: LocalFrameSendPlan) {
        let transports = reachableTransports(in: plan)
        guard !transports.isEmpty else {
            if plan.logsNoReachableTransport {
                logNoReachableTransport()
            }
            return
        }

        let selectedTransports = plan.sendsToAllReachable ? transports : [transports[0]]
        for transport in selectedTransports {
            let routeName = transport.route.logName
            AppLog.virtualMachine.debug(
                "Private network router sending frame privateNetwork=\(self.identifier, privacy: .public) route=\(routeName, privacy: .public) bytes=\(frame.count, privacy: .public)"
            )
            transport.transport.sendFrameToRemote(frame)
        }
    }

    private func removeRemoteRoutesOnQueue(_ route: PrivateNetworkTransportRoute) {
        remoteRoutes = remoteRoutes.compactMapValues { entry in
            var updated = entry
            updated.remove(route)
            return updated.isEmpty ? nil : updated
        }
    }

    private func expireMacsOnQueue(now currentDate: Date) {
        localMACs = localMACs.filter { currentDate.timeIntervalSince($0.value) <= macTtl }
        remoteRoutes = remoteRoutes.compactMapValues { entry in
            var updated = entry
            updated.expire(now: currentDate, ttl: macTtl)
            return updated.isEmpty ? nil : updated
        }
    }

    private func shouldInjectRemoteFrameOnQueue(
        _ frame: Data,
        via route: PrivateNetworkTransportRoute,
        now currentDate: Date
    ) -> Bool {
        let fingerprint = RemoteFrameFingerprint(
            hash: FNV1a64.hash(Array(frame)),
            byteCount: frame.count
        )

        if let previous = remoteFrameFingerprints[fingerprint],
           currentDate.timeIntervalSince(previous.updatedAt) <= Self.remoteFrameDedupTtl,
           previous.route != route {
            remoteFrameFingerprints[fingerprint] = RemoteFrameObservation(route: route, updatedAt: currentDate)
            return false
        }

        remoteFrameFingerprints[fingerprint] = RemoteFrameObservation(route: route, updatedAt: currentDate)
        return true
    }

    private func expireRemoteFrameFingerprintsOnQueue(now currentDate: Date) {
        remoteFrameFingerprints = remoteFrameFingerprints.filter {
            currentDate.timeIntervalSince($0.value.updatedAt) <= Self.remoteFrameDedupTtl
        }
    }

    private func reachableTransports(
        in plan: LocalFrameSendPlan
    ) -> [(transport: PrivateNetworkRoutableTransport, route: PrivateNetworkTransportRoute)] {
        var result: [(transport: PrivateNetworkRoutableTransport, route: PrivateNetworkTransportRoute)] = []
        for candidate in plan.candidates {
            guard let transport = candidate.transport,
                  let route = candidate.route,
                  transport.canSendPrivateNetworkFrames else {
                continue
            }
            result.append((transport, route))
        }
        return result
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

    private func deliverFrame(_ frame: Data, to endpoints: [PrivateNetworkLocalEndpoint]) {
        for endpoint in endpoints {
            endpoint.receivePrivateNetworkFrame(frame)
        }
    }

    private func localEndpointsForFrameOnQueue(_ frame: Data) -> [PrivateNetworkLocalEndpoint] {
        let endpoints = localEndpointObjectsOnQueue()
        guard let header = EthernetFrameHeader.parse(frame), header.destination.isUnicast else {
            return endpoints
        }
        return endpoints.filter { $0.privateNetworkMACAddress == header.destination }
    }

    private func localEndpointObjectsOnQueue() -> [PrivateNetworkLocalEndpoint] {
        localEndpoints.removeAll { $0.endpoint == nil }
        return localEndpoints.compactMap(\.endpoint)
    }

    private func localEndpointMACsOnQueue() -> Set<EthernetAddress> {
        Set(localEndpointObjectsOnQueue().map(\.privateNetworkMACAddress))
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
