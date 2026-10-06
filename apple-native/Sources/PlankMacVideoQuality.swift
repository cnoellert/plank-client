import Foundation

/// The first Mac quality slice changes capture precision, not the decoder's
/// exact HEVC 10-bit 4:4:4 identity contract. Unknown saved tokens survive
/// decoding so an unsupported choice cannot silently become another profile.
struct PlankVideoQuality: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let nvfbc = Self(rawValue: "nvfbc")
    static let native10 = Self(rawValue: "x11-native10")
    static let choices: [Self] = [.nvfbc, .native10]
    var id: String { rawValue }
    var isSupported: Bool { Self.choices.contains(self) }
    var title: String {
        switch self {
        case .nvfbc: "8-bit capture · HEVC 10-bit"
        case .native10: "Native 10-bit capture (Experimental)"
        default: "Unsupported saved quality"
        }
    }
    var detail: String {
        switch self {
        case .nvfbc: "NvFBC captures 8-bit pixels and expands them into the HEVC 10-bit 4:4:4 identity stream."
        case .native10: "Requires a native 10-bit X11 desktop. Host capture is experimental; the stream remains HEVC 10-bit 4:4:4 identity."
        default: "Choose a supported capture quality before opening the desktop."
        }
    }
    var captureSource: String { rawValue }
    var encoderBackend: String { "nvenc-direct" }
    var encodingMode: String { "hevc-10-444-nvenc" }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    func replyMatches(_ values: [String: String]) -> Bool {
        isSupported && values["PlankCaptureSource"] == captureSource &&
            values["PlankEncoderBackend"] == encoderBackend &&
            values["PlankEncodingMode"] == encodingMode
    }
}

struct PlankHostVideoCapabilities: Equatable, Sendable {
    let captureSources: Set<String>
    let encoderBackends: Set<String>
    let encodingModes: Set<String>
    let topologyVersion: Int
    let featureFlags: Int

    init(serverInfo: [String: String]) {
        func tokens(_ key: String) -> Set<String> {
            Set((serverInfo[key] ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
        }
        captureSources = tokens("PlankCaptureSources")
        encoderBackends = tokens("PlankEncoderBackends")
        encodingModes = tokens("PlankEncodingModes")
        topologyVersion = Int(serverInfo["PlankTopologyVersion"] ?? "") ?? 0
        featureFlags = UInt32(serverInfo["PlankFeatureFlags"] ?? "").map(Int.init) ?? 0
    }

    /// Advertisements gate an attempt, not physical capture qualification.
    /// Launch rechecks the authenticated topology bits and exact Host reply.
    func unavailableReason(for quality: PlankVideoQuality,
                           authenticatedFlags: Int? = nil) -> String? {
        guard quality.isSupported else { return "The saved capture quality is unsupported. Choose a supported quality." }
        guard topologyVersion == 13 else { return "This Host does not advertise the required video-quality contract." }
        let required = 0x800 | 0x1000 | (quality == .nvfbc ? 0x2000 : 0)
        guard featureFlags & required == required,
              authenticatedFlags.map({ $0 >= 0 && UInt64($0) <= UInt32.max && $0 & required == required }) ?? true else {
            return "This Host does not support the selected capture-quality negotiation."
        }
        guard captureSources.contains(quality.captureSource),
              encoderBackends.contains(quality.encoderBackend),
              encodingModes.contains(quality.encodingMode) else {
            return "This Host does not advertise the selected capture and HEVC 10-bit encoder."
        }
        return nil
    }
}
