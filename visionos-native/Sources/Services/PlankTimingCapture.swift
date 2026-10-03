import Foundation

/// A bounded, opt-in per-second timing capture of every video stage, so a
/// slow or hitching stream can be attributed to Host content cadence,
/// arrival, decode, the hand-off to the main thread, or presentation. It is
/// independent of the statistics overlay and costs one uncontended lock per
/// recorded event while enabled, nothing measurable while disabled.
final class PlankTimingCapture: @unchecked Sendable {
    static let shared = PlankTimingCapture()

    /// A size hint only; compressed size does not establish content cadence.
    static let smallFrameBytes = 2_048
    /// Fifteen minutes of one-second lines per session at most.
    static let maximumLines = 900

    private struct Window {
        var arrivals = 0
        var smallFrames = 0
        var sizes: [Int] = []
        var lastArrival: UInt64 = 0
        var maxArrivalGap: UInt64 = 0
        var decoded = 0
        var decodeTotal: UInt64 = 0
        var decodeMax: UInt64 = 0
        var offered = 0
        var replaced = 0
        var delivered = 0
        var deliveryMax: UInt64 = 0
        var acquired = 0
        var submitted = 0
        var gpuCompleted = 0
        var gpuFailed = 0
        var presented = 0
        var repeated = 0
        var skipped = 0
        var lastPresentedFrame: UInt64 = 0
        var lastPresent: Double = 0
        var maxPresentGap: Double = 0
        var drawableWaitMax: UInt64 = 0
        var drawableMisses = 0
        var gpuMax: Double = 0
        var background = false
    }

    private let lock = NSLock()
    private var enabled = false
    private var window = Window()
    private var session = "-"
    private var sessionStart: UInt64 = 0
    private var lastRoll: UInt64 = 0
    private var lines = 0

    private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func setEnabled(_ value: Bool) {
        lock.lock()
        if value != enabled { window = Window() }
        enabled = value
        lock.unlock()
    }

    func beginSession(_ label: String) {
        lock.lock()
        session = label
        sessionStart = now()
        lastRoll = sessionStart
        lines = 0
        window = Window()
        lock.unlock()
    }

    private func record(_ body: (inout Window, UInt64) -> Void) {
        lock.lock()
        if enabled { body(&window, now()) }
        lock.unlock()
    }

    func arrival(size: Int) {
        record { w, t in
            w.arrivals += 1
            if size < Self.smallFrameBytes { w.smallFrames += 1 }
            if w.sizes.count < 512 { w.sizes.append(size) }
            if w.lastArrival != 0 { w.maxArrivalGap = max(w.maxArrivalGap, t - w.lastArrival) }
            w.lastArrival = t
        }
    }

    func decoded(nanos: UInt64) {
        record { w, _ in
            w.decoded += 1
            w.decodeTotal &+= nanos
            w.decodeMax = max(w.decodeMax, nanos)
        }
    }

    /// `replacedPending` is true when a frame still waiting for the main
    /// thread is discarded in favour of this newer one.
    func offered(replacedPending: Bool) {
        record { w, _ in
            w.offered += 1
            if replacedPending { w.replaced += 1 }
        }
    }

    func delivered(latencyNanos: UInt64) {
        record { w, _ in
            w.delivered += 1
            w.deliveryMax = max(w.deliveryMax, latencyNanos)
        }
    }

    func drawableAcquired(drawableWaitNanos: UInt64, gotDrawable: Bool, background: Bool) {
        record { w, _ in
            w.drawableWaitMax = max(w.drawableWaitMax, drawableWaitNanos)
            if background { w.background = true }
            guard gotDrawable else { w.drawableMisses += 1; return }
            w.acquired += 1
        }
    }

    func submitted() {
        record { w, _ in w.submitted += 1 }
    }

    func gpuCompleted(seconds: Double, succeeded: Bool) {
        record { w, _ in
            if succeeded { w.gpuCompleted += 1 }
            else { w.gpuFailed += 1 }
            if seconds.isFinite && seconds >= 0 { w.gpuMax = max(w.gpuMax, seconds) }
        }
    }

    /// Metal's completion handler supplies actual presentation host time.
    /// Layout redraws reuse the frame ID and do not count as new video frames.
    func presented(frameID: UInt64, time: Double) {
        record { w, _ in
            guard time.isFinite && time > 0 else { w.skipped += 1; return }
            if w.lastPresentedFrame == frameID { w.repeated += 1; return }
            w.presented += 1
            if w.lastPresent > 0 { w.maxPresentGap = max(w.maxPresentGap, time - w.lastPresent) }
            w.lastPresent = time
            w.lastPresentedFrame = frameID
        }
    }

    /// Called about once per second from the video receive thread.
    func roll() {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        let t = now()
        guard t - lastRoll >= 1_000_000_000 else { lock.unlock(); return }
        lastRoll = t
        let w = window
        // Keep inter-event gaps continuous across windows.
        window = Window(lastArrival: w.lastArrival, lastPresentedFrame: w.lastPresentedFrame, lastPresent: w.lastPresent)
        let line = lines < Self.maximumLines ? lines : nil
        lines += 1
        let label = session
        let elapsed = Double(t - sessionStart) / 1e9
        lock.unlock()
        guard line != nil else { return }

        func ms(_ n: UInt64) -> String { String(format: "%.1f", Double(n) / 1e6) }
        let sorted = w.sizes.sorted()
        let p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let maxSize = sorted.last ?? 0
        NSLog("PLANK timing session=%@ t=%.0fs arrive=%d small=%d sizeKB=[p50 %.1f max %.1f] arriveGapMax=%@ms decode=%d decodeMs=[avg %.1f max %@] offer=%d replaced=%d deliver=%d deliverMaxMs=%@ acquire=%d submit=%d gpuDone=%d gpuFail=%d present=%d redraw=%d skipped=%d presentGapMaxMs=%.1f drawableWaitMaxMs=%@ drawableMiss=%d gpuMaxMs=%.1f background=%d",
              label, elapsed, w.arrivals, w.smallFrames,
              Double(p50) / 1024, Double(maxSize) / 1024, ms(w.maxArrivalGap),
              w.decoded, w.decoded == 0 ? 0 : Double(w.decodeTotal) / Double(w.decoded) / 1e6,
              ms(w.decodeMax), w.offered, w.replaced, w.delivered, ms(w.deliveryMax),
              w.acquired, w.submitted, w.gpuCompleted, w.gpuFailed, w.presented, w.repeated, w.skipped,
              w.maxPresentGap * 1000, ms(w.drawableWaitMax), w.drawableMisses,
              w.gpuMax * 1000, w.background ? 1 : 0)
    }
}
