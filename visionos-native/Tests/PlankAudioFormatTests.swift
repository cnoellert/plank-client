import Foundation

// swiftc -Onone -parse-as-library Sources/Models/PlankAudioFormat.swift \
//     Tests/PlankAudioFormatTests.swift -o audio-format-tests && ./audio-format-tests
// Failures are counted explicitly; they do not rely on assert().

@main
struct PlankAudioFormatTests {
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var failures = 0

    static func check(_ condition: Bool, _ message: String, line: Int = #line) {
        checks += 1
        if !condition {
            failures += 1
            print("FAIL line \(line): \(message)")
        }
    }

    /// The reply exactly as JSONSerialization produces it from Host bytes.
    static func reply(_ audio: String) -> [String: Any] {
        let json = "{\"video_format\":2048,\"host_feature_flags\":36,\"audio\":\(audio)}"
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    static let linuxHostStereo =
        "{\"sample_rate\":48000,\"channels\":2,\"streams\":1,\"coupled_streams\":1," +
        "\"packet_duration_ms\":5,\"mapping\":[0,1]}"

    static func main() {
        // The Linux Host's stereo reply is accepted with every field kept.
        let format = PlankAudioFormat.negotiated(from: reply(linuxHostStereo))
        check(format == PlankAudioFormat(
            sampleRate: 48_000, channels: 2, streams: 1, coupledStreams: 1,
            packetDurationMilliseconds: 5, mapping: [0, 1]
        ), "Linux Host stereo reply")

        // Two uncoupled mono streams and a swapped map are valid stereo layouts.
        check(PlankAudioFormat.negotiated(from: reply(
            "{\"sample_rate\":48000,\"channels\":2,\"streams\":2,\"coupled_streams\":0," +
            "\"packet_duration_ms\":10,\"mapping\":[1,0]}"
        ))?.mapping == [1, 0], "two mono streams, swapped map")

        let rejected: [(String, String)] = [
            ("44.1 kHz", "{\"sample_rate\":44100,\"channels\":2,\"streams\":1,\"coupled_streams\":1,\"packet_duration_ms\":5,\"mapping\":[0,1]}"),
            ("5.1 instead of stereo", "{\"sample_rate\":48000,\"channels\":6,\"streams\":4,\"coupled_streams\":2,\"packet_duration_ms\":5,\"mapping\":[0,1,2,3,4,5]}"),
            ("mono", "{\"sample_rate\":48000,\"channels\":1,\"streams\":1,\"coupled_streams\":0,\"packet_duration_ms\":5,\"mapping\":[0]}"),
            ("no streams", "{\"sample_rate\":48000,\"channels\":2,\"streams\":0,\"coupled_streams\":0,\"packet_duration_ms\":5,\"mapping\":[0,1]}"),
            ("more coupled than streams", "{\"sample_rate\":48000,\"channels\":2,\"streams\":1,\"coupled_streams\":2,\"packet_duration_ms\":5,\"mapping\":[0,1]}"),
            ("map beyond decoded channels", "{\"sample_rate\":48000,\"channels\":2,\"streams\":1,\"coupled_streams\":1,\"packet_duration_ms\":5,\"mapping\":[0,2]}"),
            ("negative map", "{\"sample_rate\":48000,\"channels\":2,\"streams\":1,\"coupled_streams\":1,\"packet_duration_ms\":5,\"mapping\":[0,-1]}"),
            ("short map", "{\"sample_rate\":48000,\"channels\":2,\"streams\":1,\"coupled_streams\":1,\"packet_duration_ms\":5,\"mapping\":[0]}"),
            ("zero duration", "{\"sample_rate\":48000,\"channels\":2,\"streams\":1,\"coupled_streams\":1,\"packet_duration_ms\":0,\"mapping\":[0,1]}"),
            ("duration over 120 ms", "{\"sample_rate\":48000,\"channels\":2,\"streams\":1,\"coupled_streams\":1,\"packet_duration_ms\":121,\"mapping\":[0,1]}"),
            ("fractional channels", "{\"sample_rate\":48000,\"channels\":2.5,\"streams\":1,\"coupled_streams\":1,\"packet_duration_ms\":5,\"mapping\":[0,1]}"),
            ("boolean field", "{\"sample_rate\":48000,\"channels\":2,\"streams\":true,\"coupled_streams\":1,\"packet_duration_ms\":5,\"mapping\":[0,1]}"),
            ("string field", "{\"sample_rate\":\"48000\",\"channels\":2,\"streams\":1,\"coupled_streams\":1,\"packet_duration_ms\":5,\"mapping\":[0,1]}"),
            ("missing map", "{\"sample_rate\":48000,\"channels\":2,\"streams\":1,\"coupled_streams\":1,\"packet_duration_ms\":5}"),
            ("missing duration", "{\"sample_rate\":48000,\"channels\":2,\"streams\":1,\"coupled_streams\":1,\"mapping\":[0,1]}"),
        ]
        for (name, audio) in rejected {
            check(PlankAudioFormat.negotiated(from: reply(audio)) == nil, "rejects \(name)")
        }
        check(PlankAudioFormat.negotiated(from: ["video_format": 2048]) == nil,
              "rejects a reply without audio")

        // Host speakers: unset keeps today's behaviour (play on Host).
        let suite = "plank.audio-format-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        check(PlankAudioPreferences.playOnHost(defaults), "Host speakers default on")
        check(PlankAudioPreferences.localAudioPlayMode(
            playOnHost: PlankAudioPreferences.playOnHost(defaults)) == "1",
              "default launch keeps localAudioPlayMode=1")
        defaults.set(false, forKey: PlankAudioPreferences.playOnHostKey)
        check(!PlankAudioPreferences.playOnHost(defaults), "Host speakers can be turned off")
        check(PlankAudioPreferences.localAudioPlayMode(
            playOnHost: PlankAudioPreferences.playOnHost(defaults)) == "0",
              "off launches with localAudioPlayMode=0")
        defaults.set("garbage", forKey: PlankAudioPreferences.playOnHostKey)
        check(PlankAudioPreferences.playOnHost(defaults), "malformed value falls back to on")

        // Local volume and mute.
        check(PlankAudioPreferences.volume(defaults) == 1, "volume defaults to full")
        check(!PlankAudioPreferences.muted(defaults), "not muted by default")
        defaults.set(0.25, forKey: PlankAudioPreferences.volumeKey)
        check(PlankAudioPreferences.volume(defaults) == 0.25, "volume persists")
        defaults.set(4.0, forKey: PlankAudioPreferences.volumeKey)
        check(PlankAudioPreferences.volume(defaults) == 1, "volume clamps high")
        defaults.set(-1.0, forKey: PlankAudioPreferences.volumeKey)
        check(PlankAudioPreferences.volume(defaults) == 0, "volume clamps low")
        defaults.set(Double.nan, forKey: PlankAudioPreferences.volumeKey)
        check(PlankAudioPreferences.volume(defaults) == 1, "non-finite volume falls back")
        defaults.set(true, forKey: PlankAudioPreferences.mutedKey)
        check(PlankAudioPreferences.muted(defaults), "mute persists")

        print("\(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
