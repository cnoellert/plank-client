import Foundation

/// One blocking receiver on its own OS thread. Receive calls must have a bounded
/// timeout. The session joins this worker before destroying the native endpoint.
final class PlankControlReceiver: @unchecked Sendable {
    enum Kind: Int, CaseIterable, Sendable {
        case position, shape, tablet, ignored
    }
    enum Result: Sendable {
        case packet(Kind)
        case idle
        case failed(String)
    }
    struct Snapshot: Sendable {
        let packets: UInt64
        let lastPollAgeNanos: UInt64
        let maxPollGapNanos: UInt64
        let maxReceiveNanos: UInt64
        let recentCounts: [UInt64]
        let failure: String?

        var summary: String {
            func ms(_ value: UInt64) -> String {
                String(format: "%.1fms", Double(value) / 1_000_000)
            }
            return "packets=\(packets) lastPoll=\(ms(lastPollAgeNanos))" +
                " maxPollGap=\(ms(maxPollGapNanos)) maxReceive=\(ms(maxReceiveNanos))" +
                " recentPosition=\(recentCounts[0]) recentShape=\(recentCounts[1])" +
                " recentTablet=\(recentCounts[2]) recentIgnored=\(recentCounts[3])" +
                " failure=\(failure ?? "none")"
        }
    }
    private struct Bucket {
        var tick: UInt64 = .max
        var counts = [UInt64](repeating: 0, count: Kind.allCases.count)
    }
    private let receive: @Sendable () -> Result
    private let condition = NSCondition()
    private var started = false
    private var stopping = false
    private var finished = false
    private var failure: String?
    private var packets: UInt64 = 0
    private var lastPoll: UInt64 = 0
    private var maxPollGap: UInt64 = 0
    private var maxReceive: UInt64 = 0
    // Eleven 100-ms buckets cover the final second, with bounded storage.
    private var buckets = [Bucket](repeating: Bucket(), count: 11)

    init(receive: @escaping @Sendable () -> Result) { self.receive = receive }

    func start() {
        condition.lock()
        guard !started, !stopping else { condition.unlock(); return }
        started = true
        condition.unlock()
        let thread = Thread { [self] in run() }
        thread.name = "PLANK control receive"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Cancellation can stop new reads without blocking the calling actor.
    func requestStop() {
        condition.lock()
        stopping = true
        condition.unlock()
    }

    /// All callers wait for completion, including concurrent/repeated stops.
    func stop() {
        condition.lock()
        stopping = true
        while started && !finished { condition.wait() }
        condition.unlock()
    }

    var snapshot: Snapshot {
        condition.lock()
        defer { condition.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        let tick = now / 100_000_000
        var counts = [UInt64](repeating: 0, count: Kind.allCases.count)
        for bucket in buckets where bucket.tick <= tick && tick - bucket.tick <= 10 {
            for kind in Kind.allCases { counts[kind.rawValue] &+= bucket.counts[kind.rawValue] }
        }
        return Snapshot(packets: packets,
                        lastPollAgeNanos: lastPoll == 0 ? 0 : now - lastPoll,
                        maxPollGapNanos: maxPollGap, maxReceiveNanos: maxReceive,
                        recentCounts: counts, failure: failure)
    }

    private func run() {
        defer {
            condition.lock()
            finished = true
            condition.broadcast()
            condition.unlock()
        }
        while true {
            condition.lock()
            guard !stopping else { condition.unlock(); return }
            let start = DispatchTime.now().uptimeNanoseconds
            if lastPoll != 0 { maxPollGap = max(maxPollGap, start - lastPoll) }
            lastPoll = start
            condition.unlock()
            let result = autoreleasepool { receive() }
            let end = DispatchTime.now().uptimeNanoseconds
            condition.lock()
            maxReceive = max(maxReceive, end - start)
            switch result {
            case let .packet(kind):
                packets &+= 1
                let tick = end / 100_000_000
                let index = Int(tick % UInt64(buckets.count))
                if buckets[index].tick != tick { buckets[index] = Bucket(tick: tick) }
                buckets[index].counts[kind.rawValue] &+= 1
            case .idle: break
            case let .failed(reason):
                if !stopping { failure = reason }
                condition.unlock()
                return
            }
            condition.unlock()
        }
    }
}

/// Retains cancellation even if it arrives before negotiation creates the reader.
final class PlankControlReceiverLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var receiver: PlankControlReceiver?
    private var stopping = false

    func install(_ next: PlankControlReceiver) {
        lock.lock()
        receiver = next
        let cancelled = stopping
        lock.unlock()
        if cancelled { next.requestStop() }
    }

    func requestStop() {
        lock.lock()
        stopping = true
        let current = receiver
        lock.unlock()
        current?.requestStop()
    }
}
