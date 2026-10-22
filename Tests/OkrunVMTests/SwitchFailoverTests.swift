import Foundation
import Testing
@testable import OkrunVM

struct SwitchFailoverTests {
    @Test
    func freshWebTrafficNeverOverridesARecentlyConfirmedLocalPeer() {
        var now = Date(timeIntervalSince1970: 100)
        let router = PrivateNetworkTransportRouter(identifier: "sticky-local", now: { now })
        let local = FailoverTransport()
        let web = FailoverTransport()
        router.setLocalSwitch(local)
        router.setWebSwitch(web)
        let request = frame(source: 1, destination: 2)
        let reply = frame(source: 2, destination: 1)

        // Ongoing ping/SSH traffic must stay local even with distinct web
        // broadcasts and web copies arriving outside the dedup window.
        for tick: UInt8 in 0..<30 {
            router.receiveRemoteFrame(request + Data([tick]), via: .localSwitch)
            now.addTimeInterval(0.5)
            router.receiveRemoteFrame(request + Data([tick]), via: .webSwitch)
            router.receiveRemoteFrame(frame(source: 1, destination: nil) + Data([tick]), via: .webSwitch)
            router.routeLocalFrame(reply)
            now.addTimeInterval(0.5)
        }
        #expect(local.frames == Array(repeating: reply, count: 30))
        #expect(web.frames.isEmpty)
    }

    @Test
    func stalePeerFallsBackWithoutChangingOtherLocalPeers() {
        var now = Date(timeIntervalSince1970: 100)
        let router = PrivateNetworkTransportRouter(identifier: "asymmetric-failover", now: { now })
        let local = FailoverTransport()
        let web = FailoverTransport()
        router.setLocalSwitch(local)
        router.setWebSwitch(web)
        let request = frame(source: 1, destination: 2)
        let reply = frame(source: 2, destination: 1)
        let otherPeer = frame(source: 2, destination: 3)
        router.receiveRemoteFrame(request, via: .localSwitch)
        now.addTimeInterval(4.9)
        router.receiveRemoteFrame(frame(source: 3, destination: 2), via: .localSwitch)
        router.receiveRemoteFrame(frame(source: 1, destination: nil), via: .webSwitch)
        router.routeLocalFrame(reply)
        #expect(web.frames.isEmpty)

        // The peer loses its LAN path while our switch still has other members.
        // At five seconds without local confirmation, use web and a bounded
        // local probe instead of trusting a five-minute-old MAC entry.
        now = Date(timeIntervalSince1970: 105)
        router.routeLocalFrame(reply)
        router.routeLocalFrame(otherPeer)
        #expect(web.frames == [reply])
        #expect(local.frames == [reply, reply, otherPeer])
        router.routeLocalFrame(reply)
        #expect(web.frames == [reply, reply])
        #expect(local.frames.count == 3)

        router.receiveRemoteFrame(request, via: .localSwitch)
        router.routeLocalFrame(reply)
        #expect(local.frames.last == reply)
        #expect(local.frames.count == 4)
        #expect(web.frames.count == 2)
    }

    @Test
    func silentLocalPeerFallsBackWithoutReceivingAnyWebTraffic() {
        var now = Date(timeIntervalSince1970: 100)
        let router = PrivateNetworkTransportRouter(identifier: "silent-failover", now: { now })
        let local = FailoverTransport()
        let web = FailoverTransport()
        router.setLocalSwitch(local)
        router.setWebSwitch(web)
        router.receiveRemoteFrame(frame(source: 1, destination: 2), via: .localSwitch)
        let request = frame(source: 2, destination: 1)
        for _ in 0..<5 {
            router.routeLocalFrame(request)
            now.addTimeInterval(1)
        }
        #expect(web.frames.isEmpty)
        router.routeLocalFrame(request)
        #expect(local.frames.count == 6) // local recovery copy first
        #expect(web.frames == [request])
        router.routeLocalFrame(request)
        #expect(local.frames.count == 6) // probes are bounded
        #expect(web.frames == [request, request])
    }

    @Test(arguments: [true, false], [0.2, 0.5, 2.0])
    func delayedDuplicateDiscoveryKeepsLocalPreference(localFirst: Bool, delay: TimeInterval) {
        var now = Date(timeIntervalSince1970: 100)
        let router = PrivateNetworkTransportRouter(identifier: "discovery-preference", now: { now })
        let local = FailoverTransport()
        let web = FailoverTransport()
        router.setLocalSwitch(local)
        router.setWebSwitch(web)
        let request = frame(source: 1, destination: nil)
        router.receiveRemoteFrame(request, via: localFirst ? .localSwitch : .webSwitch)
        now.addTimeInterval(delay)
        router.receiveRemoteFrame(request, via: localFirst ? .webSwitch : .localSwitch)
        let reply = frame(source: 2, destination: 1)
        router.routeLocalFrame(reply)
        #expect(local.frames == [reply])
        #expect(web.frames.isEmpty)
    }

    @Test
    func unavailableLocalFallsBackImmediatelyAndUnavailableWebStillUsesLocal() {
        var now = Date(timeIntervalSince1970: 100)
        let router = PrivateNetworkTransportRouter(identifier: "unavailable-failover", now: { now })
        let local = FailoverTransport()
        let web = FailoverTransport()
        router.setLocalSwitch(local)
        router.setWebSwitch(web)
        router.receiveRemoteFrame(frame(source: 1, destination: 2), via: .localSwitch)
        let reply = frame(source: 2, destination: 1)
        local.canSendPrivateNetworkFrames = false
        router.routeLocalFrame(reply)
        #expect(web.frames == [reply])
        #expect(local.frames.isEmpty)
        now.addTimeInterval(6)
        local.canSendPrivateNetworkFrames = true
        web.canSendPrivateNetworkFrames = false
        router.routeLocalFrame(reply)
        #expect(local.frames == [reply])
        #expect(web.frames == [reply])
    }

    @Test
    func discoveryAndRecoveryCopiesAreSentLocalFirst() {
        var now = Date(timeIntervalSince1970: 100)
        let router = PrivateNetworkTransportRouter(identifier: "local-first-order", now: { now })
        let local = FailoverTransport()
        let web = FailoverTransport()
        var order: [String] = []
        local.onSend = { order.append("local") }
        web.onSend = { order.append("web") }
        router.setLocalSwitch(local)
        router.setWebSwitch(web)
        let reply = frame(source: 2, destination: 1)
        router.routeLocalFrame(reply)
        #expect(order == ["local", "web"])
        router.receiveRemoteFrame(frame(source: 1, destination: 2), via: .webSwitch)
        now.addTimeInterval(5)
        order.removeAll()
        router.routeLocalFrame(reply)
        #expect(order == ["local", "web"])
    }

    private func frame(source: UInt8, destination: UInt8?) -> Data {
        let dest: [UInt8] = destination.map { [0x02, 0, 0, 0, 0, $0] }
            ?? Array(repeating: 0xff, count: 6)
        return Data(dest + [0x02, 0, 0, 0, 0, source, 0x08, 0x06, 0x01])
    }
}

private final class FailoverTransport: PrivateNetworkRoutableTransport {
    var canSendPrivateNetworkFrames = true
    var frames: [Data] = []
    var onSend: (() -> Void)?

    func sendFrameToRemote(_ frame: Data) {
        frames.append(frame)
        onSend?()
    }
}
