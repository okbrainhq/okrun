import Network

struct NetworkPathSnapshot: Equatable, CustomStringConvertible {
    private static let interfaceTypes: [NWInterface.InterfaceType] = [
        .wifi,
        .wiredEthernet,
        .cellular,
        .loopback,
        .other
    ]

    var status: String
    var usedInterfaces: [String]
    var availableInterfaces: [String]

    var isSatisfied: Bool {
        status == "satisfied"
    }

    var description: String {
        let used = usedInterfaces.isEmpty ? "none" : usedInterfaces.joined(separator: ",")
        let available = availableInterfaces.isEmpty ? "none" : availableInterfaces.joined(separator: ",")
        return "status=\(status) used=\(used) available=\(available)"
    }

    init(path: NWPath) {
        status = Self.describe(path.status)
        usedInterfaces = Self.interfaceTypes
            .filter { path.usesInterfaceType($0) }
            .map(Self.describe)
        availableInterfaces = path.availableInterfaces
            .map { "\($0.name):\(Self.describe($0.type))" }
            .sorted()
    }

    private static func describe(_ status: NWPath.Status) -> String {
        switch status {
        case .satisfied:
            return "satisfied"
        case .unsatisfied:
            return "unsatisfied"
        case .requiresConnection:
            return "requires-connection"
        @unknown default:
            return "unknown"
        }
    }

    private static func describe(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi:
            return "wifi"
        case .wiredEthernet:
            return "wired-ethernet"
        case .cellular:
            return "cellular"
        case .loopback:
            return "loopback"
        case .other:
            return "other"
        @unknown default:
            return "unknown"
        }
    }
}
