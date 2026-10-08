import Foundation

// Only the feature mask is needed by the production session in this focused
// link. The test does not replace its sender, queue or preflight implementation.
enum PlankHostFeature { static let tabletRelayRequired: UInt32 = 0x24 }

@main @MainActor struct PlankMacWacomWorkerTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        checks += 1
        precondition(value, message)
    }
    static func frame(_ type: UInt8) -> Data {
        var data = Data(repeating: 0, count: 20)
        data[6] = type
        return data
    }
    static func send(_ data: Data) -> Bool {
        data.withUnsafeBytes {
            plank_mac_test_worker_send($0.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
    }
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var kinds: [UInt8] = []
        func append(_ kind: UInt8) { lock.lock(); kinds.append(kind); lock.unlock() }
        var value: [UInt8] { lock.lock(); defer { lock.unlock() }; return kinds }
    }
    static func optOut(initialTimeout: Bool) async {
        var policy = PlankTabletInputPolicy()
        policy.begin(hasPairedTablet: true)
        let input = PlankInputQueue()
        let preflight = PlankWacomPreflight(clientVersion: "pilot", hostVersion: "test", emit: { _ in })
        var selected: PlankMacWacomSession? = PlankMacWacomSession(input: input, preflight: preflight)
        let old = selected!
        let records = Recorder()
        let sender = Task.detached {
            for await _ in input.signals {
                for event in input.drain() {
                    if case let .rawHid(bytes) = event {
                        records.append(bytes[6]); old.observeSent(bytes)
                    }
                }
            }
        }
        old.hostFeatures(PlankHostFeature.tabletRelayRequired, active: true)
        if initialTimeout {
            check(policy.expireAvailabilityGrace() == .continueWithoutTablet, "initial availability expiry opts out")
        } else {
            policy.continueWithoutTablet()
            check(!policy.waitsForTablet, "manual opt-out leaves waiting state")
        }
        // The production CoreClient finish path uses this same retirement call.
        PlankMacWacomSession.retireForSession(&selected)
        check(selected == nil, "opt-out removes selected USB capture")
        check(!send(frame(1)), "late USB hotplug cannot attach after opt-out")
        check(!send(frame(3)), "retired capture cannot forward pen reports")
        old.setActive(false); old.setActive(true)
        old.hostFeatures(PlankHostFeature.tabletRelayRequired, active: true)
        await old.close()
        check(plank_mac_test_worker_activations() == 1, "focus/Host callbacks cannot reactivate retired capture")
        check(records.value == [13], "release drains once through live sender before teardown")
        check(!send(frame(1)), "late callback after opt-out destruction refused")
        input.stop(); await sender.value
    }
    static func main() async {
        let input = PlankInputQueue()
        let preflight = PlankWacomPreflight(clientVersion: "pilot", hostVersion: "test", emit: { _ in })
        // Keep the real MainActor constructor: moving test construction to a
        // worker would hide the isolation inheritance that caused the crash.
        let session = PlankMacWacomSession(input: input, preflight: preflight)
        check(send(frame(1)), "foreign-thread ATTACH accepted")
        check(preflight.snapshot.gates[.deviceOwnership] == .passed, "worker records actual ownership")
        check(input.drain().count == 1, "ATTACH reaches production queue")
        input.append(.pointer(x: 5, y: 7, maximumX: 100, maximumY: 100))
        _ = input.drain()
        let status = frame(3) + Data([0x80, 0x01])
        check(send(status), "battery/status raw input is still forwarded")
        check(input.nativeMouseOwnsPointer, "background raw input cannot reclaim cursor")
        let forwarded = input.drain()
        if case let .rawHid(bytes)? = forwarded.first { check(bytes == status, "status bytes remain unchanged") }
        else { preconditionFailure("status forwarding missing") }
        check(send(frame(3)), "genuine pen raw bytes accepted")
        plank_mac_test_worker_activity()
        check(!input.nativeMouseOwnsPointer, "filtered physical activity reaches Swift from worker thread")
        _ = input.drain()
        input.append(.pointer(x: 6, y: 8, maximumX: 100, maximumY: 100))
        check(input.nativeMouseOwnsPointer, "next mouse movement restores local ownership")
        _ = input.drain()
        let release = frame(13)
        check(send(release), "foreign-thread release accepted")
        check(preflight.snapshot.gates[.deviceOwnership] == .pending, "release clears ownership")
        let events = input.drain()
        check(events.count == 1, "release kept in order")
        session.observeSent(release)
        for _ in 0..<256 { check(send(frame(3)), "foreign-thread raw report accepted") }
        check(!send(frame(3)), "foreign-thread congestion refused at bound")
        check(input.diagnostics.depth == 256, "worker cannot exceed queue bound")
        input.stop()
        check(!send(frame(1)), "stopped generation rejects callback")
        await session.close()
        check(!send(frame(1)), "late driver callback cannot access revoked Swift context")
        input.append(.pointer(x: 8, y: 9, maximumX: 100, maximumY: 100))
        plank_mac_test_worker_activity()
        check(input.nativeMouseOwnsPointer, "late filtered callback is revoked along with sender")
        await optOut(initialTimeout: false)
        await optOut(initialTimeout: true)
        let freshInput = PlankInputQueue()
        let fresh = PlankMacWacomSession(input: freshInput, preflight: preflight)
        check(send(frame(1)), "a new session may explicitly enable USB again")
        freshInput.stop(); await fresh.close()
        print("Mac Wacom foreign-thread callback: \(checks) checks passed")
    }
}
