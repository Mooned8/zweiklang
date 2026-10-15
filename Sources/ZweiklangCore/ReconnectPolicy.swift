import Foundation

/// How often Zweiklang fetches back a pair that dropped out of a running session.
/// A guest's iPhone can pull its AirPods away again and again; the budget ends that tug of war.
struct ReconnectPolicy {
    /// Pause before each attempt; the count is the number of attempts.
    var delays: [TimeInterval]
    /// The budget refills once the pair stayed this long.
    var refillAfter: TimeInterval
    private(set) var used = 0
    private var presentSince: Date?

    init(delays: [TimeInterval] = [3, 10, 30], refillAfter: TimeInterval = 300) {
        self.delays = delays
        self.refillAfter = refillAfter
    }

    var maxAttempts: Int { delays.count }
    var isExhausted: Bool { used >= delays.count }

    mutating func pairPresent(at now: Date = Date()) {
        if presentSince == nil { presentSince = now }
    }

    /// The pair dropped out. Returns whether automatic attempts are left.
    mutating func pairLost(at now: Date = Date()) -> Bool {
        if let since = presentSince, now.timeIntervalSince(since) >= refillAfter { used = 0 }
        presentSince = nil
        return !isExhausted
    }

    /// Pause before the next attempt, nil once the budget is used up.
    var nextDelay: TimeInterval? { isExhausted ? nil : delays[used] }

    /// Counts a real attempt (not a pause after which the pair had come back by itself). Returns its number from 1.
    @discardableResult
    mutating func takeAttempt() -> Int? {
        guard !isExhausted else { return nil }
        used += 1
        return used
    }
}
