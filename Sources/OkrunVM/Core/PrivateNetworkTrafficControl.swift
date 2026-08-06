import Foundation

struct PrivateNetworkTokenBucket {
    let burstLimit: Double
    let refillPerSecond: Double

    private(set) var tokens: Double
    private var lastRefill: Date

    init(burstLimit: Double, refillPerSecond: Double, now: Date = Date()) {
        precondition(burstLimit >= 1)
        precondition(refillPerSecond >= 0)
        self.burstLimit = burstLimit
        self.refillPerSecond = refillPerSecond
        tokens = burstLimit
        lastRefill = now
    }

    mutating func allow(at now: Date) -> Bool {
        let elapsed = now.timeIntervalSince(lastRefill)
        if elapsed > 0 {
            tokens = min(burstLimit, tokens + elapsed * refillPerSecond)
            lastRefill = now
        }

        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

struct PrivateNetworkGuestWriteBackoff {
    let initialDelay: TimeInterval
    let maximumDelay: TimeInterval

    private(set) var consecutiveFailures = 0
    private(set) var retryAfter: Date?

    init(initialDelay: TimeInterval = 0.005, maximumDelay: TimeInterval = 0.25) {
        precondition(initialDelay > 0)
        precondition(maximumDelay >= initialDelay)
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
    }

    mutating func recordCongestion(at now: Date) -> TimeInterval {
        let exponent = min(consecutiveFailures, 20)
        let delay = min(maximumDelay, initialDelay * pow(2, Double(exponent)))
        consecutiveFailures += 1
        retryAfter = now.addingTimeInterval(delay)
        return delay
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
        retryAfter = nil
    }

    func blocksFloodTraffic(at now: Date) -> Bool {
        guard let retryAfter else { return false }
        return now < retryAfter
    }
}
