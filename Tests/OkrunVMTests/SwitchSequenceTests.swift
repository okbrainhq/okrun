import Foundation
import Network
import Testing
@testable import OkrunVM

struct SwitchSequenceTests {
    @Test
    func socketsShareWireSequencesAcrossFailoverDiscoveryAndReplacement() throws {
        let server = try SequenceTestServer()
        defer { server.stop() }
        let identity = PrivateNetworkSwitchIdentity()
        let config = try PrivateNetworkSwitchConnectionConfig.localSwitch(
            PrivateNetworkLocalSwitchConfig(enabled: true, server: "127.0.0.1:\(server.port)")
        )
        func client(_ name: String) throws -> PrivateNetworkSwitchClient {
            let client = try PrivateNetworkSwitchClient(
                identifier: "sequence-test", config: config, dhcpRange: nil,
                interfaceName: name, identity: identity
            )
            let ready = DispatchSemaphore(value: 0)
            client.onStatusChange = { state, _, _, _ in
                if state == .connected { ready.signal() }
            }
            client.start()
            guard ready.wait(timeout: .now() + 5) == .success else {
                client.stop()
                throw AppError("Sequence test client failed to connect.")
            }
            return client
        }
        // Both real sockets use loopback TCP here; their interface labels and
        // shared node ID match the local/web pair used by the runtime registry.
        let local = try client("local")
        let web = try client("web")
        defer { local.stop(); web.stop() }
        try server.wait { $0.nodeIDs.count == 2 }
        let payload = Data([0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 2, 0, 0, 0, 0, 1, 8, 6])
        for _ in 0..<256 { local.send(payload) }
        try server.wait { $0.sequences.count == 256 }
        #expect(server.snapshot().sequences == Array(UInt32(1)...256))

        // Independent per-socket counters would restart at 1, so the switch
        // would discard this fallback frame as stale/duplicate.
        local.stop()
        web.send(payload)
        try server.wait { $0.sequences.count == 257 }
        #expect(server.snapshot().sequences.last == 257)

        // Recreating one transport must preserve the other transport's sequence
        // space. Discovery copies need distinct numbers even for equal payloads.
        let replacement = try client("local")
        defer { replacement.stop() }
        try server.wait { $0.nodeIDs.count == 3 }
        replacement.send(payload)
        web.send(payload)
        try server.wait { $0.sequences.count == 259 }
        let snapshot = server.snapshot()
        #expect(snapshot.nodeIDs.allSatisfy { $0 == identity.nodeID.uuidString })
        #expect(Set(snapshot.sequences) == Set(UInt32(1)...259))
        let serverDedup = SwitchDedupWindow()
        #expect(snapshot.sequences.allSatisfy { serverDedup.accept($0) })
        #expect(snapshot.errors.isEmpty)
    }

    @Test
    func concurrentSequenceAllocationIsUniqueAndIndependentPerHost() {
        let identity = PrivateNetworkSwitchIdentity()
        let results = SequenceResults()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<512 { results.append(identity.nextSequenceNumber()) }
        }
        #expect(Set(results.values) == Set(UInt32(1)...4096))
        let otherHost = PrivateNetworkSwitchIdentity()
        #expect(otherHost.nodeID != identity.nodeID)
        #expect(otherHost.nextSequenceNumber() == 1)
    }
}

private final class SequenceResults {
    private let lock = NSLock()
    private var stored: [UInt32] = []
    var values: [UInt32] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func append(_ value: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(value)
    }
}

private final class SequenceTestServer {
    struct Snapshot {
        var nodeIDs: [String] = []
        var sequences: [UInt32] = []
        var errors: [String] = []
    }

    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "okrun.test.sequence-server")
    private var connections: [NWConnection] = []
    private var state = Snapshot()

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed: ready.signal()
            default: break
            }
        }
        // Install the connection handler before start; actual clients are only
        // created after this initializer returns.
        listener.newConnectionHandler = { connection in connection.cancel() }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, let port = listener.port else {
            listener.cancel()
            throw AppError("Sequence test listener failed to start.")
        }
        self.port = port.rawValue
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, decoder: SwitchFrameDecoder())
        }
    }

    func snapshot() -> Snapshot { queue.sync { state } }

    func wait(_ condition: (Snapshot) -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let current = snapshot()
            if !current.errors.isEmpty { throw AppError(current.errors.joined(separator: "; ")) }
            if condition(current) { return }
            Thread.sleep(forTimeInterval: 0.005)
        }
        throw AppError("Timed out waiting for sequence test frames (received \(snapshot().sequences.count)).")
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, decoder: SwitchFrameDecoder) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            do {
                if let data {
                    for frame in try decoder.push(data) {
                        switch frame.type {
                        case .initFrame:
                            let initPayload = try JSONSerialization.jsonObject(with: frame.payload) as? [String: Any]
                            self.state.nodeIDs.append(initPayload?["nodeID"] as? String ?? "missing")
                            let ack = Data("{\"protocol\":\"okrun-switch/1\",\"maxFrameSize\":70000,\"networkMemberCount\":2,\"localMemberCount\":2}".utf8)
                            self.send(.initFrame, payload: ack, to: connection)
                        case .data:
                            self.state.sequences.append(frame.sequenceNumber)
                        case .ping:
                            self.send(.pong, payload: frame.payload, to: connection)
                        default: break
                        }
                    }
                }
            } catch { self.state.errors.append(error.localizedDescription) }
            if !complete && error == nil { self.receive(connection, decoder: decoder) }
        }
    }

    private func send(_ type: SwitchFrameType, payload: Data, to connection: NWConnection) {
        do {
            let frame = SwitchFrame(streamID: 0, type: type, sequenceNumber: 0, payload: payload)
            connection.send(content: try SwitchFrameProtocol.encode(frame), completion: .contentProcessed { _ in })
        } catch { state.errors.append(error.localizedDescription) }
    }
}
