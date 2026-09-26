import Foundation

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
    case standard
    case wide
    case ultrawide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .wide: return "Wide"
        case .ultrawide: return "Ultrawide"
        }
    }

    var virtualMode: String {
        switch self {
        case .standard: return "2560x1440"
        case .wide: return "3440x1440"
        case .ultrawide: return "5120x1440"
        }
    }

    var pixelSize: (width: Int, height: Int) {
        let components = virtualMode.split(separator: "x").compactMap { Int($0) }
        return (components[0], components[1])
    }

    // The current Linux Host EDIDs include Standard and Wide. Keep the system
    // naming visible while the coordinated 5120x1440 Host mode is prepared.
    var isAvailable: Bool { self != .ultrawide }
}

struct HostBookmark: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var address: String
    var port: UInt16
    var lastConnectedAt: Date?
    var spatialDisplaySize: SpatialDisplaySize

    init(
        id: UUID = UUID(),
        name: String,
        address: String,
        port: UInt16 = 28989,
        lastConnectedAt: Date? = nil,
        spatialDisplaySize: SpatialDisplaySize = .standard
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.lastConnectedAt = lastConnectedAt
        self.spatialDisplaySize = spatialDisplaySize
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, address, port, lastConnectedAt, spatialDisplaySize
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
    }
}

struct PlankHostIdentity: Equatable, Sendable {
    let name: String
    let uniqueID: String
    let version: String
    let supportsAuthentication: Bool
}

struct PlankAuthentication: Equatable, Sendable {
    let sessionToken: String
    let desktopStage: String
}

struct PlankApplication: Equatable, Sendable {
    let id: Int
    let title: String
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

struct PlankRenderedFrame: Sendable {
    let pixels: Data
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
