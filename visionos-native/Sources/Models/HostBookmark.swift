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

struct DiscoveredHost: Identifiable, Hashable, Sendable {
    let serviceName: String
    let endpointDescription: String

    var id: String { serviceName }
}
