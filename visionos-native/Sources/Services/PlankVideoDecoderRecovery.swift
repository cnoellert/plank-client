import Foundation

/// How the video loop answers VideoToolbox outcomes. Pure state with the time
/// passed in, so the policy can be checked without a decoder or a transport.
///
/// A bad-data rejection means the received bitstream is damaged, for example a
/// frame whose references were lost; VideoToolbox itself still works. It is
/// answered with a fresh hardware decoder and a fresh keyframe, and never
/// selects FFmpeg. Only genuine decoder failures (creation, capability and any
/// other status) draw on the budget that selects FFmpeg for the session.
struct PlankVideoDecoderRecovery {
    enum Reason: String, Sendable {
        case badData = "bad-data"
        case decoderFailure = "decoder-failure"
    }

    enum Action: Equatable, Sendable {
        /// Replace VideoToolbox with a fresh instance, then await a keyframe.
        case rebuildHardware
        /// FFmpeg decodes the rest of the session, starting at a keyframe.
        case selectSoftware
    }

    /// A finished recovery, reported once at the first decoded frame.
    struct Resumption: Equatable, Sendable {
        let reason: Reason
        let hardware: Bool
        let waitedNanos: UInt64
        let discardedFrames: Int
        let keyFrameRequests: Int
    }

    /// Genuine failures that still rebuild VideoToolbox; the next selects FFmpeg.
    static let hardwareFailureBudget = 2
    /// Keyframe requests are spaced at least this far apart.
    static let keyFrameRequestInterval: UInt64 = 1_000_000_000

    private(set) var usesHardware = true
    private(set) var hardwareFailures = 0
    private(set) var badDataRejections = 0
    private(set) var resumptions = 0
    private(set) var awaitingKeyFrame = false
    private var reason: Reason?
    private var recoveryStart: UInt64 = 0
    private var discardedFrames = 0
    private var keyFrameRequests = 0
    private var lastKeyFrameRequest: UInt64?

    mutating func badData(now: UInt64) -> Action {
        badDataRejections += 1
        begin(.badData, now: now)
        return .rebuildHardware
    }

    mutating func hardwareFailed(now: UInt64) -> Action {
        hardwareFailures += 1
        begin(.decoderFailure, now: now)
        guard hardwareFailures > Self.hardwareFailureBudget else { return .rebuildHardware }
        usesHardware = false
        return .selectSoftware
    }

    /// Whether a received frame should be decoded. While awaiting a keyframe,
    /// dependent frames are discarded; the keyframe itself ends the wait.
    mutating func admit(isKeyFrame: Bool) -> Bool {
        guard awaitingKeyFrame else { return true }
        guard isKeyFrame else {
            discardedFrames += 1
            return false
        }
        awaitingKeyFrame = false
        return true
    }

    /// Whether to request a keyframe now. The first request goes out at once
    /// unless one was sent within the interval; the rest are spaced by it.
    mutating func keyFrameRequestDue(now: UInt64) -> Bool {
        if let lastKeyFrameRequest, now &- lastKeyFrameRequest < Self.keyFrameRequestInterval {
            return false
        }
        recordKeyFrameRequest(now: now)
        return true
    }

    /// Records a request sent outside the pacing, such as the immediate request
    /// after a genuine decoder failure, so later requests are spaced from it.
    mutating func recordKeyFrameRequest(now: UInt64) {
        lastKeyFrameRequest = now
        if reason != nil { keyFrameRequests += 1 }
    }

    /// Called for every decoded frame; returns a finished recovery once.
    mutating func frameDecoded(now: UInt64) -> Resumption? {
        guard let reason, !awaitingKeyFrame else { return nil }
        let resumption = Resumption(
            reason: reason, hardware: usesHardware,
            waitedNanos: now &- recoveryStart,
            discardedFrames: discardedFrames, keyFrameRequests: keyFrameRequests
        )
        self.reason = nil
        resumptions += 1
        return resumption
    }

    /// A rejection during an unfinished recovery keeps the original start, so
    /// the reported wait covers the whole outage.
    private mutating func begin(_ next: Reason, now: UInt64) {
        if reason == nil {
            recoveryStart = now
            discardedFrames = 0
            keyFrameRequests = 0
        }
        reason = next
        awaitingKeyFrame = true
    }
}
