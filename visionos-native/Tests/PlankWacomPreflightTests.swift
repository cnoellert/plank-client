import Foundation

func frame(type: UInt16, generation: UInt16, interface: UInt16 = 0,
           payload: [UInt8] = []) -> Data {
    var bytes = [UInt8](repeating: 0, count: 20)
    bytes[6] = UInt8(truncatingIfNeeded: type)
    bytes[7] = UInt8(truncatingIfNeeded: type >> 8)
    bytes[8] = UInt8(truncatingIfNeeded: interface)
    bytes[9] = UInt8(truncatingIfNeeded: interface >> 8)
    bytes[10] = UInt8(truncatingIfNeeded: generation)
    bytes[11] = UInt8(truncatingIfNeeded: generation >> 8)
    bytes.append(contentsOf: payload)
    return Data(bytes)
}

@main
struct PlankWacomPreflightTests {
    static func main() throws {
        var records: [String] = []
        let preflight = PlankWacomPreflight(
            clientVersion: "0.1.0", hostVersion: "1.0.154",
            emit: { records.append($0) }
        )
        assert(!preflight.snapshot.ready)
        preflight.observeHostFeatures(rawHid: true, focusSuspend: true)
        preflight.beginRelayConnection()
        preflight.relayAuthenticated(version: "0.1.1")
        let attachedStatus = Data([3, 0x6a, 0x05, 0x57, 0x03, 2, 1, 0])
        preflight.observeSentTabletFrame(frame(type: 1, generation: 7,
                                               payload: [2, 0]))
        preflight.observeSentTabletFrame(frame(type: 2, generation: 7,
                                               interface: 0))
        assert(preflight.snapshot.gates[.attachSent] == .pending)
        preflight.observeSentTabletFrame(frame(type: 2, generation: 7,
                                               interface: 1))
        assert(preflight.snapshot.gates[.attachSent] == .passed)
        preflight.observeHostFrame(frame(type: 10, generation: 7,
                                         payload: [0, 0, 0, 0]))
        assert(!preflight.snapshot.ready)
        preflight.observeRelayStatus(attachedStatus)
        assert(preflight.snapshot.ready)

        let marker = "PLANK Wacom preflight: "
        let last = try XCTUnwrap(records.last)
        assert(last.hasPrefix(marker))
        let json = Data(last.dropFirst(marker.count).utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        assert(object["ready"] as? Bool == true)
        assert(object["host_version"] as? String == "1.0.154")
        assert(object["relay_version"] as? String == "0.1.1")
        assert((object["gates"] as? [String: String])?.count == 6)

        preflight.beginRelayConnection()
        assert(!preflight.snapshot.ready)
        assert(preflight.snapshot.gates[.deviceOwnership] == .pending)
        preflight.relayAuthenticated(version: "0.1.0")
        preflight.observeRelayStatus(attachedStatus)
        assert(preflight.snapshot.gates[.deviceOwnership] == .failed)
        preflight.observeHostFeatures(rawHid: true, focusSuspend: false)
        assert(preflight.snapshot.gates[.focusSuspend] == .failed)
        preflight.observeHostFrame(frame(type: 10, generation: 7,
                                         payload: [0, 0, 0, 0]))
        assert(preflight.snapshot.gates[.hostAcknowledgement] == .pending)

        // A fast Host ACK can arrive before the sender records its final
        // descriptor. The two independent facts must still converge to ready.
        let fastHost = PlankWacomPreflight(clientVersion: "0.1.0", hostVersion: "1.0.154")
        fastHost.observeHostFeatures(rawHid: true, focusSuspend: true)
        fastHost.beginRelayConnection()
        fastHost.relayAuthenticated(version: "0.1.1")
        fastHost.observeSentTabletFrame(frame(type: 1, generation: 8,
                                              payload: [2, 0]))
        fastHost.observeSentTabletFrame(frame(type: 2, generation: 8,
                                              interface: 0))
        fastHost.observeHostFrame(frame(type: 10, generation: 8,
                                        payload: [0, 0, 0, 0]))
        assert(fastHost.snapshot.gates[.hostAcknowledgement] == .passed)
        assert(!fastHost.snapshot.ready)
        fastHost.observeSentTabletFrame(frame(type: 2, generation: 8,
                                              interface: 1))
        fastHost.observeRelayStatus(attachedStatus)
        assert(fastHost.snapshot.ready)

        // The Relay can report attachment before the transport callback
        // records the attach frame. All six gates must still converge.
        let earlyRelay = PlankWacomPreflight(clientVersion: "0.1.0", hostVersion: "1.0.154")
        earlyRelay.observeHostFeatures(rawHid: true, focusSuspend: true)
        earlyRelay.beginRelayConnection()
        earlyRelay.relayAuthenticated(version: "0.1.1")
        earlyRelay.observeRelayStatus(attachedStatus)
        assert(earlyRelay.snapshot.gates[.deviceOwnership] == .passed)
        earlyRelay.observeSentTabletFrame(frame(type: 1, generation: 9,
                                                payload: [2, 0]))
        assert(earlyRelay.snapshot.gates[.deviceOwnership] == .passed)
        earlyRelay.observeSentTabletFrame(frame(type: 2, generation: 9,
                                                interface: 0))
        earlyRelay.observeSentTabletFrame(frame(type: 2, generation: 9,
                                                interface: 1))
        earlyRelay.observeHostFrame(frame(type: 10, generation: 9,
                                          payload: [0, 0, 0, 0]))
        assert(earlyRelay.snapshot.ready)
        earlyRelay.observeRelayStatus(Data([4, 0, 0, 0, 0, 0, 0, 0]))
        assert(!earlyRelay.snapshot.ready)
        earlyRelay.observeRelayStatus(attachedStatus)
        assert(earlyRelay.snapshot.ready)
    }
}

private func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "PreflightTest", code: 1) }
    return value
}
