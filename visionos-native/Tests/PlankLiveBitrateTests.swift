// SPDX-License-Identifier: GPL-3.0-or-later
// Focused behavior of active-session bitrate: capability gating, 250 ms
// debounce, immediate send on release, one-second retry, stale
// acknowledgements, the Host ceiling and the unchanged startup target.
//
// Build/run (failures are counted explicitly, not with assert):
//   swiftc -Onone -parse-as-library Sources/Models/HostBookmark.swift \
//     Sources/Services/PlankLiveBitrate.swift Tests/PlankLiveBitrateTests.swift -o out && ./out
import Foundation

@main
struct PlankLiveBitrateTests {
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var failures = 0

    static func check(_ condition: Bool, _ message: String, line: Int = #line) {
        checks += 1
        if !condition { failures += 1; print("FAIL line \(line): \(message)") }
    }

    static func main() {
        check(!PlankLiveBitrateState.hostSupportsChanges(0), "no capability")
        check(!PlankLiveBitrateState.hostSupportsChanges(0x08), "requests alone are insufficient")
        check(!PlankLiveBitrateState.hostSupportsChanges(0x10), "acknowledgements alone are insufficient")
        check(PlankLiveBitrateState.hostSupportsChanges(0x18), "both capabilities enable live changes")
        // Unsupported Hosts never receive a live request.
        var off = PlankLiveBitrateState(startupKbps: 50_000)
        off.choose(80_000, final: true, now: 0)
        check(off.valueToSend(now: 10) == nil, "unsupported Host gets no request")
        check(off.status.requestedKbps == nil && !off.status.pending, "unsupported stays idle")
        check(off.status.currentKbps == 50_000, "slider shows the startup target")

        var state = PlankLiveBitrateState(startupKbps: 50_000, supported: true)
        state.choose(50_000, final: true, now: 0)
        check(!state.status.pending && state.valueToSend(now: 0) == nil,
              "the startup target is already running")

        // Slider motion waits for 250 ms of inactivity and sends the latest.
        state.choose(60_000, final: false, now: 1.00)
        state.choose(65_000, final: false, now: 1.10)
        state.choose(70_000, final: false, now: 1.20)
        check(state.valueToSend(now: 1.40) == nil, "no send while moving")
        check(state.valueToSend(now: 1.45) == 70_000, "latest value after settling")
        state.didSend(70_000, now: 1.45)
        check(state.valueToSend(now: 1.50) == nil, "no duplicate send")
        check(state.status.pending, "pending until acknowledged")

        // Unconfirmed targets are retried at most once per second.
        check(state.valueToSend(now: 2.40) == nil, "no retry within a second")
        check(state.valueToSend(now: 2.45) == 70_000, "retry after a second")
        state.didSend(70_000, now: 2.45)

        // Acknowledgement shows the Host-accepted target and ends retries.
        state.acknowledge(requestedKbps: 70_000, appliedKbps: 70_000)
        check(!state.status.pending && state.status.acceptedKbps == 70_000, "acknowledged")
        check(state.valueToSend(now: 10) == nil, "no retry after acknowledgement")
        check(state.status.startupKbps == 50_000, "live changes never alter the startup target")

        // Releasing the slider sends immediately.
        state.choose(90_000, final: true, now: 20)
        check(state.valueToSend(now: 20) == 90_000, "release sends at once")
        state.didSend(90_000, now: 20)
        state.choose(100_000, final: true, now: 20.1)
        check(state.valueToSend(now: 20.1) == 100_000, "a newer release sends at once")
        state.didSend(100_000, now: 20.1)

        // A stale acknowledgement updates the reported target but never
        // confirms the newer choice.
        state.acknowledge(requestedKbps: 90_000, appliedKbps: 90_000)
        check(state.status.acceptedKbps == 90_000, "Host reports the older target")
        check(state.status.pending, "stale acknowledgement keeps the latest pending")
        check(state.valueToSend(now: 21.2) == 100_000, "latest is retried")
        state.didSend(100_000, now: 21.2)
        state.acknowledge(requestedKbps: 100_000, appliedKbps: 100_000)
        check(!state.status.pending && state.status.acceptedKbps == 100_000, "latest confirmed")

        // Returning to the confirmed value after sending another still sends,
        // because the Host applies the newest request it received.
        state.choose(110_000, final: true, now: 30)
        state.didSend(110_000, now: 30)
        state.choose(100_000, final: true, now: 30.1)
        check(state.status.pending && state.valueToSend(now: 30.1) == 100_000,
              "return to the confirmed value is re-sent")
        state.didSend(100_000, now: 30.1)
        state.acknowledge(requestedKbps: 110_000, appliedKbps: 110_000)
        check(state.status.acceptedKbps == 110_000, "older acknowledgement reported")

        // The Host's ceiling is shown as accepted, not the request.
        var ceiling = PlankLiveBitrateState(startupKbps: 50_000, supported: true)
        ceiling.choose(150_000, final: true, now: 0)
        ceiling.didSend(150_000, now: 0)
        ceiling.acknowledge(requestedKbps: 150_000, appliedKbps: 120_000)
        check(!ceiling.status.pending && ceiling.status.acceptedKbps == 120_000, "ceiling shown")

        // Values are snapped and clamped to the bookmark range before sending,
        // so the Host never receives a value it would treat as fatal.
        var snap = PlankLiveBitrateState(startupKbps: 3_000, supported: true)
        check(snap.status.startupKbps == 10_000, "startup normalized")
        snap.choose(200_000, final: true, now: 0)
        check(snap.valueToSend(now: 0) == 150_000, "clamped high")
        snap.choose(7_000, final: true, now: 1)
        check(snap.valueToSend(now: 1) == nil, "clamped low equals the confirmed startup")
        snap.choose(60_240, final: true, now: 2)
        check(snap.valueToSend(now: 2) == 60_000, "snapped to 500 kbps")

        // Losing support stops sending.
        snap.setSupported(false)
        check(snap.valueToSend(now: 5) == nil && !snap.status.pending, "support withdrawn")

        print("PlankLiveBitrateTests: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
