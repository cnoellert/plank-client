import Foundation
import CoreVideo

enum KeyboardFunctionKeyMode: String, CaseIterable, Identifiable, Sendable {
    case pc
    case appleExtended

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pc: return "Windows / PC Keyboard"
        case .appleExtended: return "Apple Extended Keyboard"
        }
    }
}

enum SpatialDisplaySize: String, Codable, CaseIterable, Identifiable, Sendable {
    case portrait1024
    case portrait1280
    case fullHD
    case wuxga
    case standard
    case tall2560
    case portrait2560
    case wide
    case wide3840
    case ultraHD
    case dci4K
    case ultrawide

    var id: String { rawValue }

    var title: String { virtualMode.replacingOccurrences(of: "x", with: " × ") }

    var virtualMode: String {
        switch self {
        case .portrait1024: return "1024x2160"
        case .portrait1280: return "1280x2160"
        case .fullHD: return "1920x1080"
        case .wuxga: return "1920x1200"
        case .standard: return "2560x1440"
        case .tall2560: return "2560x1600"
        case .portrait2560: return "2560x2160"
        case .wide: return "3440x1440"
        case .wide3840: return "3840x1600"
        case .ultraHD: return "3840x2160"
        case .dci4K: return "4096x2160"
        case .ultrawide: return "5120x2160"
        }
    }

    var pixelSize: (width: Int, height: Int) {
        let components = virtualMode.split(separator: "x").compactMap { Int($0) }
        return (components[0], components[1])
    }

}

enum StreamFrameRate {
    static let defaultValue = 60
    static let presets = [24, 25, 30, 48, 50, 60, 90, 120]

    static func normalized(_ value: Int) -> Int {
        (1...240).contains(value) ? value : defaultValue
    }
}

/// Startup encoder target sent as `video.encoder_target_kbps`. The range,
/// step and HEVC 10-bit 4:4:4 default match the desktop Client's per-profile
/// bitrate (`app/settings/streamingpreferences.h`). This is a Host encoder
/// target, not a guaranteed received rate.
enum StreamBitrate {
    static let minimumKbps = 10_000
    static let maximumKbps = 150_000
    static let stepKbps = 500
    static let defaultKbps = 50_000

    /// Clamps to the supported range and rounds to the nearest step, so a
    /// saved or edited value can never leave the qualified bounds.
    static func normalized(_ kbps: Int) -> Int {
        let clamped = min(max(kbps, minimumKbps), maximumKbps)
        let steps = (clamped - minimumKbps + stepKbps / 2) / stepKbps
        return min(minimumKbps + steps * stepKbps, maximumKbps)
    }

    static func megabitsLabel(_ kbps: Int) -> String {
        kbps % 1_000 == 0 ? "\(kbps / 1_000) Mbps" : String(format: "%.1f Mbps", Double(kbps) / 1_000)
    }
}

struct HostBookmark: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var address: String
    var port: UInt16
    var lastConnectedAt: Date?
    var spatialDisplaySize: SpatialDisplaySize
    var streamFrameRate: Int
    var videoBitrateKbps: Int
#if PLANK_NATIVE_MAC_WACOM
    var nativeVideoQuality: PlankVideoQuality = .nvfbc
#endif

    init(
        id: UUID = UUID(),
        name: String,
        address: String,
        port: UInt16 = 28989,
        lastConnectedAt: Date? = nil,
        spatialDisplaySize: SpatialDisplaySize = .standard,
        streamFrameRate: Int = StreamFrameRate.defaultValue,
        videoBitrateKbps: Int = StreamBitrate.defaultKbps
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.lastConnectedAt = lastConnectedAt
        self.spatialDisplaySize = spatialDisplaySize
        self.streamFrameRate = StreamFrameRate.normalized(streamFrameRate)
        self.videoBitrateKbps = StreamBitrate.normalized(videoBitrateKbps)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, address, port, lastConnectedAt, spatialDisplaySize, streamFrameRate
        case videoBitrateKbps
#if PLANK_NATIVE_MAC_WACOM
        case nativeVideoQuality
#endif
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        address = try values.decode(String.self, forKey: .address)
        port = try values.decode(UInt16.self, forKey: .port)
        lastConnectedAt = try values.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        spatialDisplaySize = try values.decodeIfPresent(
            SpatialDisplaySize.self,
            forKey: .spatialDisplaySize
        ) ?? .standard
        streamFrameRate = StreamFrameRate.normalized(
            (try? values.decodeIfPresent(Int.self, forKey: .streamFrameRate)) ??
            StreamFrameRate.defaultValue
        )
        // Bookmarks saved before this field existed keep the previous fixed
        // 50 Mbps target. A malformed value must not throw: HostStore decodes
        // the whole list, so one failure would drop every bookmark.
        videoBitrateKbps = StreamBitrate.normalized(
            (try? values.decodeIfPresent(Int.self, forKey: .videoBitrateKbps)) ??
            StreamBitrate.defaultKbps
        )
#if PLANK_NATIVE_MAC_WACOM
        // Missing legacy fields preserve the accepted default. Invalid/unknown
        // fields preserve an unavailable choice, not a silent precision change.
        if values.contains(.nativeVideoQuality) {
            nativeVideoQuality = (try? values.decode(PlankVideoQuality.self, forKey: .nativeVideoQuality)) ??
                .init(rawValue: "invalid-saved-quality")
        }
#endif
    }
}

struct PlankHostIdentity: Equatable, Sendable {
    let name: String
    let uniqueID: String
    let version: String
    let supportsAuthentication: Bool
#if PLANK_NATIVE_MAC_WACOM
    var videoCapabilities: PlankHostVideoCapabilities? = nil
#endif
}

struct PlankAuthentication: Equatable, Sendable {
    let sessionToken: String
    let desktopStage: String
}

struct PlankApplication: Equatable, Sendable {
    let id: Int
    let title: String
}

/// Bookmark edits compare against the settings retained by the authenticated
/// connection, not against an editor's possibly newer saved snapshot.
enum PlankBookmarkSessionPolicy {
    static func requiresClosure(edited: HostBookmark, connected: HostBookmark?,
                                authenticated: Bool) -> Bool {
        guard authenticated, let connected, edited.id == connected.id else { return false }
#if PLANK_NATIVE_MAC_WACOM
        if edited.nativeVideoQuality != connected.nativeVideoQuality { return true }
#endif
        return edited.spatialDisplaySize != connected.spatialDisplaySize ||
            StreamFrameRate.normalized(edited.streamFrameRate) !=
                StreamFrameRate.normalized(connected.streamFrameRate) ||
            edited.address != connected.address || edited.port != connected.port
    }
}

struct PlankTopology: Equatable, Sendable {
    struct Layout: Equatable, Sendable {
        let kind: String
        let virtualModes: [String]
    }

    let schemaVersion: Int
    let featureFlags: Int
    let generation: String
    let desktopWidth: Int
    let desktopHeight: Int
    let layout: Layout

    func requesting(_ displaySize: SpatialDisplaySize) -> PlankTopology {
        let pixels = displaySize.pixelSize
        return PlankTopology(
            schemaVersion: schemaVersion,
            featureFlags: featureFlags,
            generation: generation,
            desktopWidth: pixels.width,
            desktopHeight: pixels.height,
            layout: .init(kind: "single", virtualModes: [displaySize.virtualMode])
        )
    }

    func matches(_ displaySize: SpatialDisplaySize) -> Bool {
        layout.kind == "single" &&
            layout.virtualModes == [displaySize.virtualMode] &&
            desktopWidth == displaySize.pixelSize.width &&
            desktopHeight == displaySize.pixelSize.height
    }
}

struct PlankLaunchCredentials: Equatable, Sendable {
    let transportPort: UInt16
    let certificateSHA256: String
    let transportToken: String
    let udpPayloadMTU: UInt32
    let encodingMode: String
}

struct PlankFrameProbe: Equatable, Sendable {
    let byteCount: Int
    let frameNumber: UInt64
    let isKeyFrame: Bool
    let negotiationSummary: String
}

// CVPixelBuffer is immutable after VideoToolbox returns it. The Metal renderer
// retains it until its command buffer completes.
struct PlankRenderedFrame: @unchecked Sendable {
    let pixels: Data
    let pixelBuffer: CVPixelBuffer?
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let frameNumber: UInt64
}

struct PlankFrameDimensions: Equatable, Sendable {
    let width: Int
    let height: Int
}

struct PlankRemoteCursor: Equatable, Sendable {
    let x: Int
    let y: Int
    let frameWidth: Int
    let frameHeight: Int
    let sequence: UInt64
}

struct PlankRemoteCursorShape: Equatable, Sendable {
    let pixels: Data
    let width: Int
    let height: Int
    let hotspotX: Int
    let hotspotY: Int
    let visible: Bool
    let generation: UInt64
}

enum PlankCursorUpdate: Sendable {
    case position(PlankRemoteCursor)
    case shape(PlankRemoteCursorShape)
}

struct DiscoveredHost: Identifiable, Hashable, Sendable {
    let serviceName: String
    let endpointDescription: String

    var id: String { serviceName }
}
