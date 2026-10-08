import Foundation

/// One startup attempt may wait longer for a display transition, but repeated
/// progress replies cannot turn it into an unlimited retry loop.
struct PlankSessionStartupDeadline {
    private let maximumDeadline: ContinuousClock.Instant
    private(set) var deadline: ContinuousClock.Instant

    init(now: ContinuousClock.Instant, waitingForRelease: Bool) {
        maximumDeadline = now.advanced(by: .seconds(45))
        deadline = waitingForRelease ? now.advanced(by: .seconds(12)) : maximumDeadline
    }

    mutating func displayTransition() {
        deadline = maximumDeadline
    }

    func canRetry(at now: ContinuousClock.Instant) -> Bool {
        now < deadline
    }
}
