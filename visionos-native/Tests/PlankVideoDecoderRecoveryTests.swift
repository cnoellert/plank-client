// SPDX-License-Identifier: GPL-3.0-or-later
// Focused behavior of VideoToolbox bad-frame recovery: bad-data rejections keep
// hardware decoding however often they repeat, genuine decoder failures keep
// their two-rebuild budget before FFmpeg, dependent frames wait for a keyframe,
// keyframe requests stay paced, and native VideoToolbox statuses are preserved.
//
// Build/run (precondition survives -O; build -Onone to match the other suites):
//   swiftc -Onone -parse-as-library \
//     Sources/Services/PlankVideoDecoderRecovery.swift \
//     Sources/Services/PlankHardwareVideoDecoder.swift \
//     Tests/PlankVideoDecoderRecoveryTests.swift -o out && out
import Foundation
import VideoToolbox

@main
@MainActor
enum PlankVideoDecoderRecoveryTests {
    typealias Recovery = PlankVideoDecoderRecovery
    static var checks = 0
    static let second: UInt64 = 1_000_000_000

    static func check(_ condition: Bool, _ message: String, line: Int = #line) {
        checks += 1
        precondition(condition, "line \(line): \(message)")
    }

    static func main() {
        classification()
        repeatedBadDataKeepsHardware()
        consecutiveBadDataBeforeAFrame()
        genuineFailuresKeepTheirBudget()
        badDataDoesNotSpendTheBudget()
        keyFrameGate()
        requestPacing()
        print("PlankVideoDecoderRecoveryTests: \(checks) checks passed")
    }

    /// One rejection answered the way the video loop answers it: rebuild,
    /// discard dependent frames, then decode the next keyframe.
    static func rejectAndResync(
        _ recovery: inout Recovery, at now: UInt64, dependentFrames: Int = 2
    ) -> Recovery.Resumption? {
        check(recovery.badData(now: now) == .rebuildHardware, "bad data rebuilds VideoToolbox")
        for _ in 0..<dependentFrames {
            check(!recovery.admit(isKeyFrame: false), "dependent frame discarded")
        }
        check(recovery.admit(isKeyFrame: true), "keyframe admitted")
        return recovery.frameDecoded(now: now + second / 10)
    }

    static func classification() {
        let ok = OSStatus(noErr)
        let bad = OSStatus(kVTVideoDecoderBadDataErr)
        check(bad == -12909, "kVTVideoDecoderBadDataErr is the status seen on the headset")
        let rejections: [(OSStatus, OSStatus)] = [(ok, bad), (bad, ok), (bad, bad)]
        for (decodeStatus, frameStatus) in rejections {
            guard case let .badData(kept, keptFrame)? = PlankHardwareVideoDecoder
                .badDataOutcome(decodeStatus: decodeStatus, frameStatus: frameStatus) else {
                check(false, "\(decodeStatus)/\(frameStatus) is a bad-data rejection")
                continue
            }
            check(kept == decodeStatus && keptFrame == frameStatus,
                  "both native statuses are preserved")
        }
        // Success, creation/session, capability, malfunction, and any mix with
        // another failure keep the existing decoder-failure path.
        let otherwise: [(OSStatus, OSStatus)] = [
            (ok, ok),
            (OSStatus(kVTInvalidSessionErr), ok),
            (ok, OSStatus(kVTVideoDecoderUnsupportedDataFormatErr)),
            (ok, OSStatus(kVTVideoDecoderMalfunctionErr)),
            (OSStatus(kVTVideoDecoderNotAvailableNowErr), bad),
            (bad, OSStatus(kVTVideoDecoderMalfunctionErr)),
        ]
        for (decodeStatus, frameStatus) in otherwise {
            check(PlankHardwareVideoDecoder.badDataOutcome(
                decodeStatus: decodeStatus, frameStatus: frameStatus) == nil,
                  "\(decodeStatus)/\(frameStatus) is not a bad-data rejection")
        }
    }

    static func repeatedBadDataKeepsHardware() {
        var recovery = Recovery()
        for rejection in 1...10 {
            let resumption = rejectAndResync(&recovery, at: UInt64(rejection) * 2 * second)
            check(resumption == Recovery.Resumption(
                reason: .badData, hardware: true, waitedNanos: second / 10,
                discardedFrames: 2, keyFrameRequests: 0),
                  "rejection \(rejection) resumes on VideoToolbox")
        }
        check(recovery.usesHardware, "ten rejections never select FFmpeg")
        check(recovery.hardwareFailures == 0, "bad data spends no decoder-failure budget")
        check(recovery.badDataRejections == 10 && recovery.resumptions == 10, "every rejection recovered")
        check(!recovery.awaitingKeyFrame, "decoding resumed")
    }

    static func consecutiveBadDataBeforeAFrame() {
        // Each fresh keyframe is rejected again before anything decodes.
        var recovery = Recovery()
        for rejection in 0..<5 {
            check(recovery.badData(now: UInt64(rejection) * second) == .rebuildHardware,
                  "consecutive rejection \(rejection + 1) still rebuilds VideoToolbox")
            check(!recovery.admit(isKeyFrame: false), "dependent frame discarded")
            check(recovery.admit(isKeyFrame: true), "next keyframe admitted")
        }
        let resumption = recovery.frameDecoded(now: 5 * second)
        check(resumption?.hardware == true && resumption?.reason == .badData, "VideoToolbox resumes")
        check(resumption?.waitedNanos == 5 * second, "the wait spans the whole outage")
        check(resumption?.discardedFrames == 5, "discards accumulate across the outage")
        check(recovery.usesHardware && recovery.hardwareFailures == 0, "no FFmpeg, no budget spent")
    }

    static func genuineFailuresKeepTheirBudget() {
        // The original rule: hardwareFailures <= 2 rebuilds VideoToolbox,
        // otherwise FFmpeg decodes the rest of the session.
        var recovery = Recovery()
        for failure in 1...5 {
            let expected: Recovery.Action = failure <= 2 ? .rebuildHardware : .selectSoftware
            check(recovery.hardwareFailed(now: UInt64(failure) * second) == expected,
                  "genuine failure \(failure) keeps the original handling")
        }
        check(!recovery.usesHardware && recovery.hardwareFailures == 5, "FFmpeg stays selected")

        var resumed = Recovery()
        _ = resumed.hardwareFailed(now: 0)
        check(resumed.admit(isKeyFrame: true), "keyframe admitted after a failure")
        check(resumed.frameDecoded(now: second)?.hardware == true, "rebuilt VideoToolbox resumes")
        _ = resumed.hardwareFailed(now: 2 * second)
        _ = resumed.hardwareFailed(now: 3 * second)
        check(!resumed.usesHardware, "third genuine failure selects FFmpeg")
        check(!resumed.admit(isKeyFrame: false), "FFmpeg also starts at a keyframe")
        check(resumed.admit(isKeyFrame: true), "keyframe admitted for FFmpeg")
        let resumption = resumed.frameDecoded(now: 4 * second)
        check(resumption?.hardware == false && resumption?.reason == .decoderFailure,
              "the resume log names FFmpeg and the decoder failure")
    }

    static func badDataDoesNotSpendTheBudget() {
        var recovery = Recovery()
        var now: UInt64 = 0
        func tick() -> UInt64 { now += 2 * second; return now }
        _ = rejectAndResync(&recovery, at: tick())
        check(recovery.hardwareFailed(now: tick()) == .rebuildHardware, "first genuine failure")
        _ = recovery.admit(isKeyFrame: true)
        _ = recovery.frameDecoded(now: tick())
        for _ in 0..<4 { _ = rejectAndResync(&recovery, at: tick()) }
        check(recovery.hardwareFailed(now: tick()) == .rebuildHardware,
              "second genuine failure still rebuilds after five rejections")
        _ = recovery.admit(isKeyFrame: true)
        _ = recovery.frameDecoded(now: tick())
        check(recovery.usesHardware, "two genuine failures and five rejections keep VideoToolbox")
        check(recovery.badDataRejections == 5 && recovery.hardwareFailures == 2, "counted separately")
        check(recovery.hardwareFailed(now: tick()) == .selectSoftware,
              "only the third genuine failure selects FFmpeg")
    }

    static func keyFrameGate() {
        var recovery = Recovery()
        check(recovery.admit(isKeyFrame: false), "frames decode while nothing is wrong")
        _ = recovery.badData(now: 0)
        for _ in 0..<3 { check(!recovery.admit(isKeyFrame: false), "dependent frame discarded") }
        check(recovery.frameDecoded(now: second) == nil, "no resumption before a keyframe")
        check(recovery.admit(isKeyFrame: true), "keyframe ends the wait")
        check(recovery.admit(isKeyFrame: false), "frames after the keyframe decode")
        check(recovery.frameDecoded(now: second)?.discardedFrames == 3, "discards reported")
        check(recovery.frameDecoded(now: 2 * second) == nil, "a recovery is reported once")
    }

    static func requestPacing() {
        var recovery = Recovery()
        _ = recovery.badData(now: 10 * second)
        check(recovery.keyFrameRequestDue(now: 10 * second), "first request goes out at once")
        check(!recovery.keyFrameRequestDue(now: 10 * second + second / 2), "held within the interval")
        check(recovery.keyFrameRequestDue(now: 11 * second), "repeated after the interval")
        _ = recovery.admit(isKeyFrame: true)
        check(recovery.frameDecoded(now: 11 * second)?.keyFrameRequests == 2,
              "requests during the outage are reported")

        // A rejection on every frame at 60 fps for ten seconds stays bounded.
        var burst = Recovery()
        var sent = 0
        for frame in 0..<600 {
            let now = UInt64(frame) * second / 60
            _ = burst.badData(now: now)
            if burst.keyFrameRequestDue(now: now) { sent += 1 }
        }
        check(sent == 10, "at most one keyframe request per second (\(sent) in 10 s)")
        check(burst.usesHardware && burst.hardwareFailures == 0, "600 rejections keep VideoToolbox")

        // The immediate request after a genuine failure spaces the next one.
        var failed = Recovery()
        _ = failed.hardwareFailed(now: 0)
        failed.recordKeyFrameRequest(now: 0)
        check(!failed.keyFrameRequestDue(now: second / 2), "paced from the immediate request")
        check(failed.keyFrameRequestDue(now: second), "allowed after the interval")
    }
}
