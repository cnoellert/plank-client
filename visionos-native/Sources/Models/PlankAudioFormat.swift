import Foundation

/// The Host's reply to the stereo audio request. Validated with the desktop
/// Client's rules before any audio is decoded; a reply that does not match is
/// a negotiation failure, never a silent fallback to another layout.
struct PlankAudioFormat: Equatable, Sendable {
    static let requestedChannels = 2
    static let sampleRate = 48_000

    let sampleRate: Int
    let channels: Int
    let streams: Int
    let coupledStreams: Int
    let packetDurationMilliseconds: Int
    let mapping: [UInt8]

    /// Returns nil unless the reply is stereo 48 kHz Opus with a stream layout
    /// and channel map that libopus accepts.
    static func negotiated(from response: [String: Any]) -> PlankAudioFormat? {
        guard let audio = response["audio"] as? [String: Any],
              let sampleRate = exactInteger(audio["sample_rate"]),
              let channels = exactInteger(audio["channels"]),
              let streams = exactInteger(audio["streams"]),
              let coupledStreams = exactInteger(audio["coupled_streams"]),
              let packetDuration = exactInteger(audio["packet_duration_ms"]),
              let rawMapping = audio["mapping"] as? [Any] else {
            return nil
        }
        guard sampleRate == Self.sampleRate,
              channels == requestedChannels,
              streams > 0, streams <= channels,
              coupledStreams >= 0, coupledStreams <= streams,
              packetDuration > 0, packetDuration <= 120,
              rawMapping.count == channels else {
            return nil
        }
        var mapping: [UInt8] = []
        for value in rawMapping {
            guard let channel = exactInteger(value),
                  channel >= 0, channel < streams + coupledStreams else {
                return nil
            }
            mapping.append(UInt8(channel))
        }
        return PlankAudioFormat(
            sampleRate: sampleRate,
            channels: channels,
            streams: streams,
            coupledStreams: coupledStreams,
            packetDurationMilliseconds: packetDuration,
            mapping: mapping
        )
    }

    /// JSONSerialization yields NSNumber; accept only whole numbers, not
    /// booleans or fractions that would truncate into a plausible value.
    private static func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let integer = number.intValue
        return number.doubleValue == Double(integer) ? integer : nil
    }
}

/// App-wide audio choices. Host speakers are a launch parameter, so a change
/// applies on the next connection; volume and mute are local and immediate.
enum PlankAudioPreferences {
    static let playOnHostKey = "plank.vision.audio.playOnHost"
    static let volumeKey = "plank.vision.audio.volume"
    static let mutedKey = "plank.vision.audio.muted"

    /// Defaults to on: the Host keeps playing through its own speakers,
    /// matching the desktop Client and the behaviour before AVP playback.
    static func playOnHost(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: playOnHostKey) as? Bool ?? true
    }

    /// The Host's `localAudioPlayMode`: 1 keeps Host speakers, 0 mutes them.
    static func localAudioPlayMode(playOnHost: Bool) -> String {
        playOnHost ? "1" : "0"
    }

    static func volume(_ defaults: UserDefaults = .standard) -> Float {
        guard let stored = defaults.object(forKey: volumeKey) as? Double,
              stored.isFinite else { return 1 }
        return Float(min(max(stored, 0), 1))
    }

    static func muted(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: mutedKey) as? Bool ?? false
    }
}
