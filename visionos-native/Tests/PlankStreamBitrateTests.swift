// SPDX-License-Identifier: GPL-3.0-or-later
// Focused behavior of the per-workstation startup bitrate: bookmark defaults,
// legacy and malformed bookmark decoding, persistence through HostStore, and
// the value that reaches video.encoder_target_kbps in the launch request.
//
// Build/run (precondition survives -O; build -Onone to match the other suites):
//   swiftc -Onone -parse-as-library \
//     Sources/Models/HostBookmark.swift \
//     Sources/Models/PlankStreamRequest.swift \
//     Sources/Services/HostDiscovery.swift \
//     Sources/Services/HostStore.swift \
//     Tests/PlankStreamBitrateTests.swift -o out && out
import Foundation

@main
@MainActor
enum PlankStreamBitrateTests {
    static var checks = 0

    static func check(_ condition: Bool, _ message: String, line: Int = #line) {
        checks += 1
        precondition(condition, "line \(line): \(message)")
    }

    static let topology = PlankTopology(
        schemaVersion: 1, featureFlags: 0, generation: "test",
        desktopWidth: 2560, desktopHeight: 1440,
        layout: .init(kind: "single", virtualModes: ["2560x1440"]))

    static func decodeList(_ json: String) -> [HostBookmark]? {
        try? JSONDecoder().decode([HostBookmark].self, from: Data(json.utf8))
    }

    /// The exact bytes that would cross the bridge for this bookmark.
    static func sentTarget(_ host: HostBookmark) -> Int? {
        let request = PlankStreamRequest.negotiation(
            topology: topology, frameRate: host.streamFrameRate,
            encoderTargetKbps: host.videoBitrateKbps)
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let video = object["video"] as? [String: Any] else { return nil }
        return video["encoder_target_kbps"] as? Int
    }

    static func main() {
        // Defaults and normalization.
        check(HostBookmark(name: "a", address: "a").videoBitrateKbps == 50_000, "new bookmark default")
        check(StreamBitrate.normalized(5_000) == 10_000, "below range clamps to 10 Mbps")
        check(StreamBitrate.normalized(200_000) == 150_000, "above range clamps to 150 Mbps")
        check(StreamBitrate.normalized(20_249) == 20_000, "rounds down to step")
        check(StreamBitrate.normalized(20_250) == 20_500, "rounds half up to step")
        check(StreamBitrate.normalized(149_900) == 150_000, "rounding never exceeds maximum")
        check(StreamBitrate.normalized(75_500) == 75_500, "desktop half-Mbps step kept")
        check(HostBookmark(name: "a", address: "a", videoBitrateKbps: 1).videoBitrateKbps == 10_000,
              "initializer normalizes")
        check(StreamBitrate.megabitsLabel(20_000) == "20 Mbps", "whole Mbps label")
        check(StreamBitrate.megabitsLabel(75_500) == "75.5 Mbps", "half Mbps label")

        // Bookmarks saved before the field existed keep the previous 50 Mbps.
        let id = UUID().uuidString
        let legacy = """
        [{"id":"\(id)","name":"Studio","address":"192.0.2.5","port":28989,
          "spatialDisplaySize":"ultraHD","streamFrameRate":30}]
        """
        let legacyHosts = decodeList(legacy)
        check(legacyHosts?.count == 1, "legacy list decodes")
        check(legacyHosts?.first?.videoBitrateKbps == 50_000, "legacy bookmark keeps 50 Mbps")
        check(legacyHosts?.first?.streamFrameRate == 30, "legacy frame rate preserved")
        check(legacyHosts?.first?.spatialDisplaySize == .ultraHD, "legacy display preserved")

        // A malformed value must not throw, or HostStore would drop every bookmark.
        let malformed = """
        [{"id":"\(UUID().uuidString)","name":"A","address":"a","port":28989,"videoBitrateKbps":"fast"},
         {"id":"\(UUID().uuidString)","name":"B","address":"b","port":28989,"videoBitrateKbps":999999}]
        """
        let malformedHosts = decodeList(malformed)
        check(malformedHosts?.count == 2, "malformed bitrate does not drop the list")
        check(malformedHosts?[0].videoBitrateKbps == 50_000, "non-integer falls back to default")
        check(malformedHosts?[1].videoBitrateKbps == 150_000, "out-of-range saved value clamps")

        // Codable round trip.
        var edited = HostBookmark(name: "R", address: "r", videoBitrateKbps: 20_000)
        let encoded = try? JSONEncoder().encode([edited])
        let roundTrip = encoded.flatMap { try? JSONDecoder().decode([HostBookmark].self, from: $0) }
        check(roundTrip?.first?.videoBitrateKbps == 20_000, "round trip keeps 20 Mbps")

        // Persistence through HostStore, including edits and relaunch.
        let suite = "plank.bitrate.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HostStore(defaults: defaults)
        store.add(name: "Twenty", address: "192.0.2.20", port: 28989, videoBitrateKbps: 20_000)
        store.add(name: "Default", address: "192.0.2.50", port: 28989)
        check(HostStore(defaults: defaults).hosts.first { $0.name == "Twenty" }?.videoBitrateKbps == 20_000,
              "added value persists across relaunch")
        check(HostStore(defaults: defaults).hosts.first { $0.name == "Default" }?.videoBitrateKbps == 50_000,
              "added default persists")
        edited = store.hosts.first { $0.name == "Twenty" }!
        edited.videoBitrateKbps = 100_000
        store.update(edited)
        let reloaded = HostStore(defaults: defaults)
        check(reloaded.hosts.first { $0.name == "Twenty" }?.videoBitrateKbps == 100_000,
              "edited value persists across relaunch")
        check(reloaded.hosts.count == 2, "editing keeps other bookmarks")

        // Legacy data already in UserDefaults loads with 50 Mbps and is kept.
        defaults.set(Data(legacy.utf8), forKey: "plank.vision.hosts.v1")
        let legacyStore = HostStore(defaults: defaults)
        check(legacyStore.hosts.count == 1, "stored legacy bookmark loads")
        check(legacyStore.hosts.first?.videoBitrateKbps == 50_000, "stored legacy bookmark gets 50 Mbps")

        // The saved value is what reaches video.encoder_target_kbps.
        let twenty = reloaded.hosts.first { $0.name == "Default" }.map {
            var host = $0; host.videoBitrateKbps = 20_000; return host
        }!
        check(sentTarget(twenty) == 20_000, "20 Mbps bookmark sends 20000")
        check(sentTarget(reloaded.hosts.first { $0.name == "Twenty" }!) == 100_000,
              "100 Mbps bookmark sends 100000")
        check(sentTarget(legacyStore.hosts.first!) == 50_000, "legacy bookmark sends 50000")
        let unsafe = PlankStreamRequest.negotiation(topology: topology, frameRate: 60,
                                                    encoderTargetKbps: 1_000_000)
        check((unsafe["video"] as? [String: Any])?["encoder_target_kbps"] as? Int == 150_000,
              "request builder never sends an out-of-range target")

        // The rest of the request is unchanged from the previous fixed literal.
        let video = PlankStreamRequest.negotiation(topology: topology, frameRate: 60,
                                                   encoderTargetKbps: 50_000)["video"] as? [String: Any]
        check(video?["width"] as? Int == 2560 && video?["height"] as? Int == 1440, "size")
        check(video?["fps"] as? Int == 60 && video?["fps_x100"] as? Int == 6000, "frame rate")
        check(video?["codec"] as? Int == 1 && video?["chroma"] as? Int == 1 &&
              video?["ten_bit"] as? Bool == true && video?["encoder_csc_mode"] as? Int == 7,
              "HEVC 10-bit 4:4:4 identity profile unchanged")
        check(video?["negotiated_format"] as? Int == 0x0800, "negotiated format unchanged")

        print("PlankStreamBitrateTests: \(checks) checks passed")
    }
}
