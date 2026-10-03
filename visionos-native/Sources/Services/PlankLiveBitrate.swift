import Foundation

/// What the session controls show for the running encoder target. The
/// startup target comes from the bookmark and is never changed by live
/// adjustments, as on the desktop Client.
struct PlankLiveBitrateStatus: Equatable, Sendable {
    /// The Host advertised live bitrate requests and acknowledgements.
    var supported: Bool
    var startupKbps: Int
    /// The latest value chosen during this session, if any.
    var requestedKbps: Int?
    /// The latest target the Host acknowledged, after its own ceiling.
    var acceptedKbps: Int?
    /// The latest chosen value is not yet acknowledged.
    var pending: Bool

    /// The slider position: the latest choice, otherwise the startup target.
    var currentKbps: Int { requestedKbps ?? startupKbps }
}

/// Debounce, retry and acknowledgement rules for live bitrate changes,
/// following protocol/dynamic-bitrate.md: wait for 250 ms without slider
/// motion, send a released value immediately, retry an unconfirmed target at
/// most once per second, and never let an acknowledgement for an older value
/// confirm a newer one. Pure, so it is tested with an injected clock.
struct PlankLiveBitrateState: Equatable, Sendable {
    static let settleInterval: TimeInterval = 0.25
    static let retryInterval: TimeInterval = 1.0

    /// LI_FF_DYNAMIC_VIDEO_BITRATE (0x08) and LI_FF_ENCODER_TARGET_ACK
    /// (0x10) are both required: this control confirms the applied target.
    static func hostSupportsChanges(_ flags: UInt32) -> Bool {
        flags & 0x18 == 0x18
    }

    private(set) var status: PlankLiveBitrateStatus
    /// The newest target the Host has confirmed for the latest request. The
    /// startup target was validated at launch, so it starts confirmed.
    private var confirmedKbps: Int
    private var changedAt: TimeInterval = 0
    private var released = false
    private var lastSentKbps: Int?
    private var lastSentAt: TimeInterval = 0

    init(startupKbps: Int, supported: Bool = false) {
        let startup = StreamBitrate.normalized(startupKbps)
        status = PlankLiveBitrateStatus(
            supported: supported, startupKbps: startup,
            requestedKbps: nil, acceptedKbps: nil, pending: false
        )
        confirmedKbps = startup
    }

    mutating func setSupported(_ supported: Bool) {
        status.supported = supported
        refreshPending()
    }

    /// A slider position (snapped to the bookmark range and 500 kbps steps).
    /// `final` is true when the slider is released.
    mutating func choose(_ kbps: Int, final: Bool, now: TimeInterval) {
        guard status.supported else { return }
        let value = StreamBitrate.normalized(kbps)
        if value != status.currentKbps || status.requestedKbps == nil {
            changedAt = now
        }
        status.requestedKbps = value
        released = final
        refreshPending()
    }

    /// The value to send now, if any.
    func valueToSend(now: TimeInterval) -> Int? {
        guard status.supported, status.pending, let value = status.requestedKbps else { return nil }
        if value != lastSentKbps {
            return released || now - changedAt >= Self.settleInterval ? value : nil
        }
        return now - lastSentAt >= Self.retryInterval ? value : nil
    }

    mutating func didSend(_ kbps: Int, now: TimeInterval) {
        lastSentKbps = kbps
        lastSentAt = now
        refreshPending()
    }

    /// An acknowledgement from the Host. Every acknowledgement updates the
    /// target the Host reports running; only one for the latest choice ends
    /// the pending state, so a stale one never suppresses the newest value.
    mutating func acknowledge(requestedKbps: Int, appliedKbps: Int) {
        guard status.supported else { return }
        status.acceptedKbps = appliedKbps
        if requestedKbps == status.requestedKbps && requestedKbps == lastSentKbps {
            confirmedKbps = requestedKbps
        }
        refreshPending()
    }

    /// The Host applies the newest request it receives, so the choice is
    /// settled only when it is confirmed and nothing different was sent later.
    private mutating func refreshPending() {
        let current = status.currentKbps
        let sentOther = lastSentKbps.map { $0 != current } ?? false
        status.pending = status.supported && (current != confirmedKbps || sentOther)
    }
}

/// Thread-safe owner of one session's live bitrate state. The UI chooses
/// values on the main actor; the control receive thread sends them and
/// records acknowledgements, so the transport is only touched while valid.
final class PlankLiveBitrate: @unchecked Sendable {
    private let lock = NSLock()
    private var state: PlankLiveBitrateState
    private let onChange: @Sendable (PlankLiveBitrateStatus) -> Void

    init(startupKbps: Int, onChange: @escaping @Sendable (PlankLiveBitrateStatus) -> Void) {
        state = PlankLiveBitrateState(startupKbps: startupKbps)
        self.onChange = onChange
    }

    var status: PlankLiveBitrateStatus { locked { $0.status } }

    func setSupported(_ supported: Bool) { update { $0.setSupported(supported) } }

    func choose(_ kbps: Int, final: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        update { $0.choose(kbps, final: final, now: now) }
    }

    func acknowledge(requestedKbps: Int, appliedKbps: Int) {
        update { $0.acknowledge(requestedKbps: requestedKbps, appliedKbps: appliedKbps) }
    }

    /// Called from the control thread; returns false if the send failed.
    func pump(send: (UInt32) -> Bool) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard let value = locked({ $0.valueToSend(now: now) }) else { return true }
        guard send(UInt32(value)) else { return false }
        update { $0.didSend(value, now: now) }
        return true
    }

    private func locked<T>(_ body: (PlankLiveBitrateState) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(state)
    }

    private func update(_ body: (inout PlankLiveBitrateState) -> Void) {
        lock.lock()
        let before = state.status
        body(&state)
        let after = state.status
        lock.unlock()
        if after != before { onChange(after) }
    }
}
