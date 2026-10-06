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
    static func main() async {
        let input = PlankInputQueue()
        let preflight = PlankWacomPreflight(clientVersion: "pilot", hostVersion: "test", emit: { _ in })
        // Keep the real MainActor constructor: moving test construction to a
        // worker would hide the isolation inheritance that caused the crash.
        let session = PlankMacWacomSession(input: input, preflight: preflight)
        check(send(frame(1)), "foreign-thread ATTACH accepted")
        check(preflight.snapshot.gates[.deviceOwnership] == .passed, "worker records actual ownership")
        check(input.drain().count == 1, "ATTACH reaches production queue")
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
        print("Mac Wacom foreign-thread callback: \(checks) checks passed")
    }
}
