// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main enum PlankRelayTransportTests {
    static func main() throws {
        let identity = "b4805f947954ddad8645c4a87d1bead9bcd2aceb3cacfa133dcdf10f1048191c"
        let management = "6f830f05473e3b6d4654cce8a68af4a0d9c1f01e4701529d5f94eb4532f86b07"
        let uuid = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
        let route = PlankDrawingRoute(address: "192.0.2.20", port: 28990, interface: nil, kind: nil)
        var body: [String: Any] = ["version": 2, "requestID": uuid.uuidString.lowercased(), "displayName": "Studio Relay",
            "managementIdentity": management, "drawingIdentity": identity,
            "drawingProtocol": ["name": "pltr-raw-hid", "version": 1, "rawHID": 1, "linkType": 2],
            "routes": [], "bluetooth": ["linkType": 1, "peripheralIdentifier": uuid.uuidString.lowercased()]]
        func parse(_ value: [String: Any], path: Int = 2) throws -> PlankDrawingHandoffParse {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return PlankDrawingHandoffValidator.validateAppLink("plank-vision://handoff/v\(path)?d=\(encoded)")
        }
        let result = try parse(body)
        guard case let .accepted(descriptor) = result else { preconditionFailure("Bluetooth-only v2: \(result)") }
        precondition(descriptor.routes.isEmpty && descriptor.bluetoothIdentifier == uuid)
        precondition((try? parse(body, path: 1)) == .rejected("version.unsupported"))
        body["bluetooth"] = ["linkType": 2, "peripheralIdentifier": uuid.uuidString.lowercased()]
        precondition((try? parse(body)) == .rejected("bluetooth.invalid"))
        body.removeValue(forKey: "bluetooth")
        precondition((try? parse(body)) == .rejected("routes.count"))
        body["bluetooth"] = ["linkType": 1, "peripheralIdentifier": "00000000-0000-0000-0000-000000000000"]
        precondition((try? parse(body)) == .rejected("bluetooth.invalid"))
        var registry = PlankRelayRegistry()
        registry.register(PlankDrawingRouteSelection(drawingIdentity: identity, displayName: "Studio Relay", routes: [route], bluetoothIdentifier: uuid))
        _ = registry.request(.relay(identity), desktopSessionActive: false)
        precondition(registry.activeRelay?.connectionRoutes == [.network(route), .bluetooth(uuid)])
        _ = registry.requestTransport(.bluetooth, identity: identity, desktopSessionActive: true)
        precondition(registry.activeRelay?.transport == .automatic)
        let pending = PlankRelayRegistryCodec.decode(PlankRelayRegistryCodec.encode(registry))!
        precondition(pending.activeRelay?.pendingTransport == .bluetooth && pending.activeRelay?.transport == .automatic)
        precondition(registry.desktopSessionEnded())
        precondition(registry.activeRelay?.connectionRoutes == [.bluetooth(uuid)])
        precondition(registry.activeRelay?.connectionRoute(attempt: 20) == .bluetooth(uuid))
        let restored = PlankRelayRegistryCodec.decode(PlankRelayRegistryCodec.encode(registry))!
        precondition(restored == registry)
        registry.register(PlankDrawingRouteSelection(drawingIdentity: identity, displayName: "Renamed", routes: [route]))
        precondition(registry.activeRelay?.bluetoothIdentifier == uuid && registry.activeRelay?.transport == .bluetooth)
        _ = registry.requestTransport(.network, identity: identity, desktopSessionActive: false)
        precondition(registry.activeRelay?.connectionRoutes == [.network(route)])
        _ = registry.request(.off, desktopSessionActive: false)
        precondition(registry.activeRelay == nil && registry.relays.count == 1)
        var tracker = PlankRelayLinkTracker()
        tracker.apply(.sessionStarted(configured: true))
        precondition(tracker.authenticatedRoute == nil)
        tracker.apply(.authenticatedRoute("Bluetooth")); tracker.apply(.ready)
        precondition(tracker.observation == .connected && tracker.authenticatedRoute == "Bluetooth")
        tracker.apply(.closed(wasReady: true))
        precondition(tracker.authenticatedRoute == nil)
        if let path = ProcessInfo.processInfo.environment["PLANK_V2_HANDOFF_OUTPUT"] {
            let link = try String(contentsOfFile: path, encoding: .utf8)
            guard case let .accepted(value) = PlankDrawingHandoffValidator.validateAppLink(link) else {
                preconditionFailure("Real Setup link accepted by Client")
            }
            precondition(value.bluetoothIdentifier == uuid && value.routes.isEmpty)
        }
        print("PlankRelayTransportTests: passed")
    }
}
