import Foundation

struct HostBookmark: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var address: String
    var port: UInt16
    var lastConnectedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        address: String,
        port: UInt16 = 28989,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.lastConnectedAt = lastConnectedAt
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

struct PlankRenderedFrame: Equatable, Sendable {
    let pixels: Data
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let frameNumber: UInt64
}

struct PlankRemoteCursor: Equatable, Sendable {
    let x: Int
    let y: Int
    let frameWidth: Int
    let frameHeight: Int
    let sequence: UInt64
}

struct DiscoveredHost: Identifiable, Hashable, Sendable {
    let serviceName: String
    let endpointDescription: String

    var id: String { serviceName }
}
