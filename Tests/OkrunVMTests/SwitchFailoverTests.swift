import Foundation
import Testing
@testable import OkrunVM

struct SwitchFailoverTests {
    @Test
    func repliesFollowPeerToWebEvenWhenOurLocalSwitchIsStillConnected() {
        var now = Date(timeIntervalSince1970: 100)
        let router = PrivateNetworkTransportRouter(identifier: "asymmetric-failover", now: { now })
        let local = FailoverTransport()
        let web = FailoverTransport()
        router.setLocalSwitch(local)
        router.setWebSwitch(web)
        let request = frame(source: 1, destination: 2)
        let reply = frame(source: 2, destination: 1)
        router.receiveRemoteFrame(request, via: .localSwitch)
        router.routeLocalFrame(reply)
        #expect(local.frames == [reply])

        // Only the peer loses its LAN connection. Our local switch can still
        // have other members, so transport availability alone cannot detect it.
        now.addTimeInterval(1)
        router.receiveRemoteFrame(request, via: .webSwitch)
        router.routeLocalFrame(reply)
        #expect(web.frames == [reply])
        #expect(local.frames == [reply])

        // A fresh local observation restores the preferred low-latency route.
        now.addTimeInterval(1)
        router.receiveRemoteFrame(request, via: .localSwitch)
        router.routeLocalFrame(reply)
        #expect(local.frames == [reply, reply])
        #expect(web.frames == [reply])
    }

    @Test
    func discoveryOnWebReplacesStaleLocalPreferenceWithoutChangingOtherPeers() {
        var now = Date(timeIntervalSince1970: 100)
        let router = PrivateNetworkTransportRouter(identifier: "discovery-failover", now: { now })
        let local = FailoverTransport()
        let web = FailoverTransport()
        router.setLocalSwitch(local)
        router.setWebSwitch(web)
        router.receiveRemoteFrame(frame(source: 1, destination: 2), via: .localSwitch)
        router.receiveRemoteFrame(frame(source: 3, destination: 2), via: .localSwitch)
        now.addTimeInterval(1)

        // ARP discovery must also relearn the return path, not just IP unicast.
        router.receiveRemoteFrame(frame(source: 1, destination: nil), via: .webSwitch)
        let reply = frame(source: 2, destination: 1)
        let otherPeer = frame(source: 2, destination: 3)
        router.routeLocalFrame(reply)
        router.routeLocalFrame(otherPeer)
        #expect(web.frames == [reply])
        #expect(local.frames == [otherPeer])
    }

    @Test(arguments: [true, false])
    func delayedDuplicateDiscoveryKeepsLocalPreference(localFirst: Bool) {
        var now = Date(timeIntervalSince1970: 100)
        let router = PrivateNetworkTransportRouter(identifier: "discovery-preference", now: { now })
        let local = FailoverTransport()
        let web = FailoverTransport()
        router.setLocalSwitch(local)
        router.setWebSwitch(web)
        let request = frame(source: 1, destination: nil)
        router.receiveRemoteFrame(request, via: localFirst ? .localSwitch : .webSwitch)
        now.addTimeInterval(0.2)
        router.receiveRemoteFrame(request, via: localFirst ? .webSwitch : .localSwitch)
        let reply = frame(source: 2, destination: 1)
        router.routeLocalFrame(reply)
        #expect(local.frames == [reply])
        #expect(web.frames.isEmpty)
    }

    @Test
    func distinctWebPacketImmediatelyRelearnsAndUnavailableWebStillFallsBack() {
        let now = Date(timeIntervalSince1970: 100)
        let router = PrivateNetworkTransportRouter(identifier: "immediate-failover", now: { now })
        let local = FailoverTransport()
        let web = FailoverTransport()
        router.setLocalSwitch(local)
        router.setWebSwitch(web)
        let request = frame(source: 1, destination: 2)
        router.receiveRemoteFrame(request, via: .localSwitch)
        router.receiveRemoteFrame(request + Data([2]), via: .webSwitch)
        let reply = frame(source: 2, destination: 1)
        router.routeLocalFrame(reply)
        #expect(web.frames == [reply])
        #expect(local.frames.isEmpty)
        web.canSendPrivateNetworkFrames = false
        router.routeLocalFrame(reply)
        #expect(local.frames == [reply])
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

    func sendFrameToRemote(_ frame: Data) {
        frames.append(frame)
    }
}
