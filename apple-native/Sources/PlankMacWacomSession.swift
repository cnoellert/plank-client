import Foundation

enum PlankMacTabletSource: String, CaseIterable, Identifiable, Sendable {
    case off, usb, relay
    var id: String { rawValue }
    var title: String {
        switch self { case .off: "Off"; case .usb: "Wacom connected to this Mac (USB)"; case .relay: "Registered Relay" }
    }
    static var saved: Self { Self(rawValue: UserDefaults.standard.string(forKey: "plank.mac.tablet-source") ?? "usb") ?? .usb }
}

// The sender's lifetime is independent of a stalled HID driver. destroy() in
// the C wrapper revokes the Swift context even when the worker exits late.
final class PlankMacWacomSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "la.instinctual.plank.mac-wacom", qos: .userInitiated)
    private var handle: OpaquePointer?
    private let releases = PlankMacWacomReleaseBarrier()
    private let inboxLock = NSLock()
    private var pendingControls: [Data] = []
    private var drainScheduled = false
    private var overflow = false
    private var closing = false
    private var desiredActive = false
    private let input: PlankInputQueue
    private let preflight: PlankWacomPreflight

    @MainActor init(input: PlankInputQueue, preflight: PlankWacomPreflight) {
        self.input = input
        self.preflight = preflight
        handle = plank_mac_wacom_create({ context, bytes, length in
            guard let context, let bytes else { return false }
            let owner = Unmanaged<PlankMacWacomSession>.fromOpaque(context).takeUnretainedValue()
            let data = Data(bytes: bytes, count: length)
            guard owner.input.offerNativeRawHid(data) else { return false }
            if length >= 20 {
                let type = UInt16(bytes[6]) | UInt16(bytes[7]) << 8
                if type == 1 { owner.preflight.observeLocalCapture(owned: true) }
                if type == 9 || type == 13 { owner.releases.didQueue(); owner.preflight.observeLocalCapture(owned: false) }
            }
            return true
        }, Unmanaged.passUnretained(self).toOpaque())
    }
    func setActive(_ active: Bool) {
        inboxLock.lock()
        guard !closing, desiredActive != active else { inboxLock.unlock(); return }
        desiredActive = active
        // Schedule while holding the inbox lock, preserving focus transitions
        // against a concurrent teardown. The worker call never runs on UI.
        queue.async { [self] in if let handle { plank_mac_wacom_active(handle, active) } }
        inboxLock.unlock()
    }
    func hostFeatures(_ flags: UInt32, active: Bool) {
        if flags & PlankHostFeature.tabletRelayRequired == PlankHostFeature.tabletRelayRequired { setActive(active) }
    }
    func control(_ data: Data) {
        inboxLock.lock()
        guard !closing else { inboxLock.unlock(); return }
        if pendingControls.count >= 128 { overflow = true; closing = true; pendingControls.removeAll() }
        else { pendingControls.append(data) }
        if !drainScheduled { drainScheduled = true; queue.async { [self] in drainControls() } }
        inboxLock.unlock()
    }
    private func drainControls() {
        while true {
            inboxLock.lock()
            let failed = overflow
            let batch = pendingControls
            pendingControls.removeAll(keepingCapacity: true)
            if batch.isEmpty || failed { drainScheduled = false }
            inboxLock.unlock()
            if failed {
                NSLog("PLANK Mac Wacom: bounded control inbox exhausted; releasing capture")
                destroyHandle(); preflight.observeLocalCapture(owned: false); return
            }
            guard !batch.isEmpty else { return }
            for data in batch {
                if let handle { data.withUnsafeBytes { plank_mac_wacom_control(handle, $0.bindMemory(to: UInt8.self).baseAddress, data.count) } }
            }
        }
    }
    func observeSent(_ data: Data) {
        guard data.count >= 20 else { return }
        let type = UInt16(data[6]) | UInt16(data[7]) << 8
        if type == 9 || type == 13 { releases.didSend() }
    }
    private func markClosing() {
        inboxLock.lock(); closing = true; desiredActive = false; pendingControls.removeAll(); inboxLock.unlock()
    }
    private func destroyHandle() {
        if let handle { plank_mac_wacom_destroy(handle); self.handle = nil
            if !releases.wait(seconds: 1) { NSLog("PLANK Mac Wacom: release submission timed out; closing transport") }
            preflight.observeLocalCapture(owned: false) }
    }
    func closeSynchronously() { markClosing(); queue.sync { destroyHandle() } }
    func close() async {
        markClosing()
        await withCheckedContinuation { continuation in queue.async { [self] in destroyHandle(); continuation.resume() } }
    }
    deinit { if let handle { plank_mac_wacom_destroy(handle) } }
}
