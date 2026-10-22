import Foundation
import Testing
@testable import OkrunVM

struct SwitchFailbackTests {
    @Test(arguments: [true, false], [true, false])
    func activeUnicastReturnsToLocalWithoutNewDiscovery(onlyPeerLostLocal: Bool, localCopyFirst: Bool) {
        var now = Date(timeIntervalSince1970: 100)
        let a = FailbackHost(mac: 1, now: { now })
        let b = FailbackHost(mac: 2, now: { now })
        var pending: [(PrivateNetworkTransportRouter, Data, PrivateNetworkTransportRoute)] = []
        a.local.onSend = { if b.local.canSendPrivateNetworkFrames { pending.append((b.router, $0, .localSwitch)) } }
        b.local.onSend = { if a.local.canSendPrivateNetworkFrames { pending.append((a.router, $0, .localSwitch)) } }
        a.web.onSend = { pending.append((b.router, $0, .webSwitch)) }
        b.web.onSend = { pending.append((a.router, $0, .webSwitch)) }
        defer {
            a.local.onSend = nil; b.local.onSend = nil
            a.web.onSend = nil; b.web.onSend = nil
        }

        func deliver() {
            let preferred: PrivateNetworkTransportRoute = localCopyFirst ? .localSwitch : .webSwitch
            let ordered = pending.filter { $0.2 == preferred } + pending.filter { $0.2 != preferred }
            pending.removeAll()
            for (router, frame, route) in ordered { router.receiveRemoteFrame(frame, via: route) }
        }
        var exchanges: UInt8 = 0
        func exchange() {
            exchanges += 1
            // Ordinary, distinct unicast requests/replies only: no ARP, no
            // injected recovery observations and no route-table manipulation.
            b.router.routeLocalEndpointFrame(failbackFrame(source: 2, destination: 1, payload: exchanges))
            deliver()
            a.router.routeLocalEndpointFrame(failbackFrame(source: 1, destination: 2, payload: exchanges))
            deliver()
        }
        exchange() // initial discovery learns both peers locally
        exchange()
        #expect(a.web.frames.count == 0)
        #expect(b.web.frames.count == 1)

        for _ in 0..<2 {
            b.local.canSendPrivateNetworkFrames = false
            a.local.canSendPrivateNetworkFrames = onlyPeerLostLocal
            // Keep both web routes fresh beyond the probe interval. Recovery
            // must not depend on either route aging out after five minutes.
            for _ in 0..<10 {
                now.addTimeInterval(1)
                exchange()
            }
            let aWebCount = a.web.frames.count
            let bWebCount = b.web.frames.count
            b.local.canSendPrivateNetworkFrames = true
            a.local.canSendPrivateNetworkFrames = true
            for _ in 0..<5 {
                now.addTimeInterval(1)
                exchange()
            }
            #expect(a.local.frames.last == failbackFrame(source: 1, destination: 2, payload: exchanges))
            #expect(b.local.frames.last == failbackFrame(source: 2, destination: 1, payload: exchanges))
            #expect(a.web.frames.count - aWebCount < 5)
            #expect(b.web.frames.count - bWebCount <= 5)
            let webCounts = (a.web.frames.count, b.web.frames.count)
            exchange()
            #expect(a.web.frames.count == webCounts.0)
            #expect(b.web.frames.count == webCounts.1)
        }
        // Probe copies are deduplicated, not injected twice or bridged. An
        // asymmetric outage takes the five-second confirmation window to detect
        // (four replies before its boundary in each of the two outage cycles).
        #expect(a.endpoint.frames.count == Int(exchanges))
        #expect(b.endpoint.frames.count == Int(exchanges) - (onlyPeerLostLocal ? 8 : 0))
        #expect(pending.isEmpty)
    }

    @Test
    func webOnlyPeerKeepsWorkingAndProbesAreThrottledDespiteFreshWebTraffic() {
        var now = Date(timeIntervalSince1970: 100)
        let host = FailbackHost(mac: 1, now: { now })
        let reply = failbackFrame(source: 1, destination: 2)
        for tick in 0...100 {
            now = Date(timeIntervalSince1970: 100 + Double(tick) / 10)
            host.router.receiveRemoteFrame(failbackFrame(source: 2, destination: 1, payload: UInt8(tick)), via: .webSwitch)
            host.router.routeLocalFrame(reply)
        }
        #expect(host.web.frames.count == 101)
        #expect(host.local.frames.count == 2) // once per peer per five seconds
        // Sending a probe alone must never promote an unconfirmed local path.
        host.router.routeLocalFrame(reply)
        #expect(host.web.frames.count == 102)
        #expect(host.local.frames.count == 2)
    }

    @Test
    func unavailableLocalDoesNotConsumeProbeAndOtherPeersHaveIndependentSchedules() {
        var now = Date(timeIntervalSince1970: 100)
        let host = FailbackHost(mac: 1, now: { now })
        for peer: UInt8 in [2, 3] {
            host.router.receiveRemoteFrame(failbackFrame(source: peer, destination: 1), via: .webSwitch)
        }
        host.local.canSendPrivateNetworkFrames = false
        now.addTimeInterval(5)
        let reply = failbackFrame(source: 1, destination: 2)
        host.router.routeLocalFrame(reply)
        #expect(host.local.frames.isEmpty)
        host.local.canSendPrivateNetworkFrames = true
        host.router.routeLocalFrame(reply)
        let otherReply = failbackFrame(source: 1, destination: 3)
        host.router.routeLocalFrame(otherReply)
        #expect(host.local.frames == [reply, otherReply])
        #expect(host.web.frames == [reply, reply, otherReply])
        host.router.routeLocalFrame(reply)
        #expect(host.local.frames.count == 2)
    }

    @Test
    func recoveryProbeFloodLimitNeverDropsKnownWebTraffic() {
        var now = Date(timeIntervalSince1970: 100)
        let router = PrivateNetworkTransportRouter(
            identifier: "limited-failback", remoteFloodBurstLimit: 1,
            remoteFloodRefillPerSecond: 0, now: { now }
        )
        let local = FailbackTransport()
        let web = FailbackTransport()
        router.setLocalSwitch(local)
        router.setWebSwitch(web)
        for peer: UInt8 in [2, 3] {
            router.receiveRemoteFrame(failbackFrame(source: peer, destination: 1), via: .webSwitch)
        }
        now.addTimeInterval(5)
        let first = failbackFrame(source: 1, destination: 2)
        let second = failbackFrame(source: 1, destination: 3)
        router.routeLocalFrame(first)
        router.routeLocalFrame(second)
        #expect(local.frames == [first])
        #expect(web.frames == [first, second])
    }
}

private func failbackFrame(source: UInt8, destination: UInt8, payload: UInt8 = 0) -> Data {
    Data([0x02, 0, 0, 0, 0, destination, 0x02, 0, 0, 0, 0, source, 0x08, 0x00, payload])
}

private final class FailbackHost {
    let router: PrivateNetworkTransportRouter
    let local = FailbackTransport()
    let web = FailbackTransport()
    let endpoint: FailbackEndpoint

    init(mac: UInt8, now: @escaping () -> Date) {
        router = PrivateNetworkTransportRouter(identifier: "failback-\(mac)", now: now)
        endpoint = FailbackEndpoint(mac: mac)
        router.setLocalSwitch(local)
        router.setWebSwitch(web)
        router.addLocalEndpoint(endpoint)
    }
}

private final class FailbackTransport: PrivateNetworkRoutableTransport {
    var canSendPrivateNetworkFrames = true
    var frames: [Data] = []
    var onSend: ((Data) -> Void)?

    func sendFrameToRemote(_ frame: Data) {
        frames.append(frame)
        onSend?(frame)
    }
}

private final class FailbackEndpoint: PrivateNetworkLocalEndpoint {
    let privateNetworkMACAddress: EthernetAddress
    var frames: [Data] = []

    init(mac: UInt8) {
        privateNetworkMACAddress = EthernetFrameHeader.parse(failbackFrame(source: mac, destination: mac))!.source
    }

    func receivePrivateNetworkFrame(_ frame: Data) { frames.append(frame) }
}
