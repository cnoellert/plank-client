import Foundation

@main @MainActor struct PlankMacVideoQualityTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        checks += 1
        precondition(value, message)
    }
    static let advertisement = [
        "PlankTopologyVersion": "13", "PlankFeatureFlags": String(0x3800),
        "PlankCaptureSources": "nvfbc,x11-native10",
        "PlankEncoderBackends": "software-cuda,nvenc-direct",
        "PlankEncodingModes": "h264-10-444-software,hevc-10-444-nvenc"
    ]
    static let topology = PlankTopology(schemaVersion: 13, featureFlags: 0x3800,
        generation: "fixture", desktopWidth: 3840, desktopHeight: 1600,
        layout: .init(kind: "single", virtualModes: ["3840x1600"]))
    static func query(_ quality: PlankVideoQuality? = nil) -> [String: String] {
        let fields: [URLQueryItem]
        if let quality {
            fields = PlankHTTPClient.desktopLaunchQuery(topology: topology, applicationID: 1,
                frameRate: 60, playAudioOnHost: true, captureSource: quality.captureSource)
        } else {
            fields = PlankHTTPClient.desktopLaunchQuery(topology: topology, applicationID: 1,
                frameRate: 60, playAudioOnHost: true)
        }
        return Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value ?? "") })
    }
    static func main() throws {
        let caps = PlankHostVideoCapabilities(serverInfo: advertisement)
        for quality in PlankVideoQuality.choices {
            check(caps.unavailableReason(for: quality, authenticatedFlags: 0x3800) == nil, "advertised tuple allowed")
            let request = query(quality)
            check(request["plankCaptureSource"] == quality.captureSource, "saved capture source reaches production launch query")
            check(request["plankEncoderBackend"] == "nvenc-direct", "NVENC backend stays exact")
            check(request["plankEncodingMode"] == "hevc-10-444-nvenc", "HEVC 10-bit profile stays exact")
            check(request["plankQuicUdpPayloadMtu"] == "1200", "MTU unchanged")
            let reply = ["PlankCaptureSource": quality.captureSource,
                         "PlankEncoderBackend": "nvenc-direct", "PlankEncodingMode": "hevc-10-444-nvenc"]
            check(quality.replyMatches(reply), "exact reply accepted")
            for key in reply.keys {
                var missing = reply; missing.removeValue(forKey: key)
                check(!quality.replyMatches(missing), "missing acceptance field rejected")
                var changed = reply; changed[key] = "different"
                check(!quality.replyMatches(changed), "substituted acceptance field rejected")
            }
        }
        check(query() == query(.nvfbc), "unchanged default for Vision and old Mac calls")
        var expected = query(.nvfbc); expected["plankCaptureSource"] = "x11-native10"
        check(query(.native10) == expected, "only capture selection differs between launch queries")
        check(query()["localAudioPlayMode"] == "1", "workstation speaker policy unchanged")
        for key in advertisement.keys {
            var missing = advertisement; missing.removeValue(forKey: key)
            check(PlankHostVideoCapabilities(serverInfo: missing).unavailableReason(for: .nvfbc) != nil,
                  "missing Host advertisement refuses launch")
        }
        for key in ["PlankCaptureSources", "PlankEncoderBackends", "PlankEncodingModes"] {
            var wrong = advertisement; wrong[key] = "not-supported"
            check(PlankHostVideoCapabilities(serverInfo: wrong).unavailableReason(for: .native10) != nil,
                  "unsupported advertised tuple refused")
        }
        check(caps.unavailableReason(for: .native10, authenticatedFlags: 0) != nil, "authenticated topology still required")
        check(caps.unavailableReason(for: .nvfbc, authenticatedFlags: 0x1800) != nil, "NvFBC HEVC capability bit required")
        check(caps.unavailableReason(for: .native10, authenticatedFlags: 0x1800) == nil, "NvFBC-only bit does not gate native X11")
        var malformed = advertisement; malformed["PlankFeatureFlags"] = "no"
        check(PlankHostVideoCapabilities(serverInfo: malformed).unavailableReason(for: .nvfbc) != nil, "invalid flags refused")
        malformed = advertisement; malformed["PlankTopologyVersion"] = "14"
        check(PlankHostVideoCapabilities(serverInfo: malformed).unavailableReason(for: .native10) != nil, "unknown schema refused")
        malformed = advertisement; malformed["PlankFeatureFlags"] = "-1"
        check(PlankHostVideoCapabilities(serverInfo: malformed).unavailableReason(for: .native10) != nil, "negative advertised flags refused")
        malformed["PlankFeatureFlags"] = "4294967296"
        check(PlankHostVideoCapabilities(serverInfo: malformed).unavailableReason(for: .native10) != nil, "advertised flags cannot exceed wire width")
        check(caps.unavailableReason(for: .native10, authenticatedFlags: -1) != nil, "negative authenticated flags refused")
        malformed = advertisement; malformed["PlankCaptureSources"] = " nvfbc, x11-native10 , nvfbc, "
        check(PlankHostVideoCapabilities(serverInfo: malformed).captureSources == ["nvfbc", "x11-native10"], "CSV tokens normalized")
        let unknown = PlankVideoQuality(rawValue: "future-profile")
        check(!unknown.isSupported && caps.unavailableReason(for: unknown) != nil, "unknown quality unavailable")
        check(!unknown.replyMatches(["PlankCaptureSource": "future-profile", "PlankEncoderBackend": "nvenc-direct", "PlankEncodingMode": "hevc-10-444-nvenc"]), "unknown matching reply is not support")

        let original = HostBookmark(name: "Fixture", address: "workstation.example")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        json.removeValue(forKey: "nativeVideoQuality")
        func decoded(_ object: [String: Any]) throws -> HostBookmark {
            try JSONDecoder().decode(HostBookmark.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let legacy = try decoded(json)
        check(legacy.nativeVideoQuality == .nvfbc, "legacy bookmark retains accepted default")
        check(legacy.id == original.id && legacy.spatialDisplaySize == original.spatialDisplaySize, "legacy fields preserved")
        json["nativeVideoQuality"] = "future-profile"
        let retained = try decoded(json)
        check(retained.nativeVideoQuality == unknown, "unknown token preserved rather than downgraded")
        let roundtrip = try JSONDecoder().decode(HostBookmark.self, from: JSONEncoder().encode(retained))
        check(roundtrip.nativeVideoQuality == unknown, "unsupported token survives round trip")
        for bad: Any in [42, NSNull(), ["capture": "nvfbc"]] {
            json["nativeVideoQuality"] = bad
            let invalid = try decoded(json)
            check(!invalid.nativeVideoQuality.isSupported, "malformed quality unavailable without dropping bookmark")
            check(invalid.id == original.id, "malformed value preserves bookmark identity")
        }
        var changed = original; changed.nativeVideoQuality = .native10
        check(PlankBookmarkSessionPolicy.requiresClosure(edited: changed, connected: original, authenticated: true), "quality change closes retained authentication")
        check(!PlankBookmarkSessionPolicy.requiresClosure(edited: changed, connected: original, authenticated: false), "logged-out quality edit needs no closure")
        check(!PlankBookmarkSessionPolicy.requiresClosure(edited: changed, connected: changed, authenticated: true), "same-quality reconnect preserves login")
        let connectedNative = changed
        changed.name = "Renamed"
        check(!PlankBookmarkSessionPolicy.requiresClosure(edited: changed, connected: connectedNative, authenticated: true), "name edit is not a quality change")
        let unavailable = PlankHTTPError.videoQualityUnavailable(503, "Requested capture source is unavailable")
        check(unavailable.isVideoQualityFailure, "optional capture rejection stops startup retry")
        check(unavailable.errorDescription?.contains("503") == true, "Host rejection code retained")
        check(!PlankHTTPError.rejected(503, "Busy").isVideoQualityFailure, "existing default busy handling unchanged")

        let domain = "plank.native-quality-fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = HostStore(defaults: defaults)
        store.add(bookmark: changed)
        check(store.hosts.first?.nativeVideoQuality == .native10, "new bookmark keeps selected quality")
        check(HostStore(defaults: defaults).hosts.first?.nativeVideoQuality == .native10, "quality survives app relaunch")
        var edited = changed; edited.nativeVideoQuality = .nvfbc
        store.update(edited)
        check(HostStore(defaults: defaults).hosts.first?.nativeVideoQuality == .nvfbc, "edited quality persisted")
        let nativeRequest = PlankStreamRequest.negotiation(topology: topology, frameRate: 60, encoderTargetKbps: 50_000)
        let video = nativeRequest["video"] as! [String: Any]
        check(video["negotiated_format"] as? Int == 0x0800 && video["ten_bit"] as? Bool == true,
              "native stream remains exact HEVC 10-bit format")
        check(video["encoder_csc_mode"] as? Int == 7 && video["chroma"] as? Int == 1,
              "identity and 4:4:4 remain unchanged")
        print("PlankMacVideoQualityTests: \(checks) checks passed")
    }
}
