import Foundation

private final class Source: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    private var destroyed = false
    private var delivered: [Int] = []
    private var readAfterDestroy = false
    private var fail = false

    func receive() -> PlankControlReceiver.Result {
        lock.lock()
        let drained = next >= 512
        lock.unlock()
        // Like the native bounded wait, an idle receive waits without holding
        // any caller lock (holding it starved the observer) and then reads
        // endpoint state again, so a read after destruction is detectable.
        if drained { Thread.sleep(forTimeInterval: 0.002) }
        lock.lock()
        defer { lock.unlock() }
        if destroyed { readAfterDestroy = true; return .failed("destroyed") }
        if fail { return .failed("native=-3 state=8 test failure") }
        if next < 512 {
            let value = next
            next += 1
            delivered.append(value)
            return .packet(PlankControlReceiver.Kind(rawValue: value % 4)!)
        }
        return .idle
    }
    func setFailure() { lock.lock(); fail = true; lock.unlock() }
    func destroy() { lock.lock(); destroyed = true; lock.unlock() }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return delivered }
    var invalidRead: Bool { lock.lock(); defer { lock.unlock() }; return readAfterDestroy }
}

/// Polls a condition until it holds or the bound expires; never infers
/// success from elapsed time alone.
private func waitUntil(seconds: Double = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() >= deadline { return false }
        Thread.sleep(forTimeInterval: 0.001)
    }
    return true
}

@main struct Tests {
    static func main() {
        let source = Source()
        let receiver = PlankControlReceiver(receive: { source.receive() })
        receiver.start()
        // Simulate a video/decode stall: this caller does no work for the
        // receiver while it drains more than 64 messages on its own thread.
        precondition(waitUntil { receiver.snapshot.packets == 512 },
                     "control drain depends on video or stalled")
        let stats = receiver.snapshot
        precondition(source.values == Array(0..<512), "control drain loses ordering")
        precondition(stats.packets == 512)
        precondition(stats.recentCounts == [128, 128, 128, 128], "ignored events end drain or counts drift")
        precondition(stats.failure == nil)
        receiver.stop()
        receiver.stop() // Repeated joins remain safe.
        // stop() joins the thread, so no read may follow destruction. The
        // window only gives a broken join time to be caught reading; a
        // correct receiver passes regardless of its length.
        source.destroy()
        Thread.sleep(forTimeInterval: 0.03)
        precondition(!source.invalidRead, "receiver outlived endpoint")

        let failureSource = Source()
        failureSource.setFailure()
        let failing = PlankControlReceiver(receive: { failureSource.receive() })
        failing.start()
        precondition(waitUntil { failing.snapshot.failure != nil }, "native failure not reported")
        precondition(failing.snapshot.failure == "native=-3 state=8 test failure", "native reason lost")
        failing.stop()
        failureSource.destroy()

        let unstarted = PlankControlReceiver(receive: { .failed("must not run") })
        unstarted.stop()
        unstarted.start()
        precondition(unstarted.snapshot.failure == nil, "stop before start lost")
        // Replacement/cancellation before negotiation must not start a stale reader.
        let lifetime = PlankControlReceiverLifetime()
        lifetime.requestStop()
        let late = PlankControlReceiver(receive: { .failed("late endpoint read") })
        lifetime.install(late)
        late.start()
        late.stop()
        precondition(late.snapshot.failure == nil)

        // Repeated session replacement joins every old receiver before teardown.
        for _ in 0..<20 {
            let source = Source()
            let reader = PlankControlReceiver(receive: { source.receive() })
            let lifetime = PlankControlReceiverLifetime()
            lifetime.install(reader)
            reader.start()
            lifetime.requestStop()
            reader.stop()
            source.destroy()
            precondition(!source.invalidRead)
        }
        print("Control receiver: stalled-video burst, ordering, ignored events, error and teardown checks passed")
    }
}
