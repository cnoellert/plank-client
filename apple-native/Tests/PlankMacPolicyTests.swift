import AppKit
import Foundation
@main @MainActor struct PlankMacPolicyTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1; precondition(condition(), message)
    }
    static func frame(_ type: UInt8, generation: UInt8 = 1, payload: [UInt8] = []) -> Data {
        var data = [UInt8](repeating: 0, count: 20); data[6] = type; data[10] = generation; data.append(contentsOf: payload); return Data(data)
    }
    static func main() {
        let canvas = PlankMacCoordinates.canvas(in: CGRect(x: 0, y: 0, width: 1000, height: 1000), width: 1920, height: 1080)
        check(abs(canvas.width - 1000) < 1e-9 && abs(canvas.height - 562.5) < 1e-9, "aspect fit")
        check(abs(canvas.minY - 218.75) < 1e-9, "letterbox is centered")
        check(PlankMacCoordinates.remote(.zero, canvas: canvas, width: 1920, height: 1080, dragging: false) == nil, "letterbox excluded")
        let drag = PlankMacCoordinates.remote(CGPoint(x: 1200, y: 1200), canvas: canvas, width: 1920, height: 1080, dragging: true)
        check(drag?.0 == 1919 && drag?.1 == 1079, "held drag clamps to last Host pixel")
        let center = PlankMacCoordinates.remote(CGPoint(x: 500,y: 500), canvas: canvas, width: 1920, height: 1080, dragging: false)
        check(center?.0 == 960 && center?.1 == 540, "retina-independent center")
        check(PlankMacCoordinates.remote(.zero, canvas: .zero, width: 0, height: 0, dragging: true) == nil, "invalid dimensions excluded")
        check(PlankMacKeys.table[0] == 0x41, "A is protocol VK, not Mac code")
        check(PlankMacKeys.table[123] == 0x25 && PlankMacKeys.table[126] == 0x26, "arrows")
        check(PlankMacKeys.table[122] == 0x70 && PlankMacKeys.table[111] == 0x7b, "F1 and F12")
        check(PlankMacKeys.modifiers([.shift,.control,.option,.command]) == 15, "modifier bits")
        check(PlankMacKeys.mouseButton(1) == 3 && PlankMacKeys.mouseButton(2) == 2, "right and middle protocol buttons")
        check(PlankMacKeys.mouseButton(3) == 4 && PlankMacKeys.mouseButton(99) == nil, "side buttons bounded")
        let input = PlankInputQueue()
        for n in 0..<256 { check(input.offerNativeRawHid(Data([UInt8(truncatingIfNeeded:n)])), "ordered report accepted") }
        check(!input.offerNativeRawHid(Data([0])), "full raw queue refuses instead of discarding a transition")
        check(input.diagnostics.depth == 256, "raw queue bounded")
        let drained = input.drain()
        check(drained.count == 256, "no raw movement coalescing")
        for (n,event) in drained.enumerated() {
            if case let .rawHid(bytes) = event { check(bytes == Data([UInt8(truncatingIfNeeded:n)]), "raw ordering preserved") }
            else { preconditionFailure("raw event changed kind") }
        }
        check(input.offerNativeRawHid(Data([1])), "drain makes space")
        input.stop(); check(!input.offerNativeRawHid(Data([2])), "late callback after stop refused")
        check(input.drain().isEmpty, "stopped generation cannot replay")
        let fresh = PlankInputQueue(); check(fresh.offerNativeRawHid(Data([3])), "new generation independent")
        let ownership = PlankInputQueue()
        check(!ownership.nativeMouseOwnsPointer, "new session starts with remote cursor ownership")
        ownership.append(.pointer(x: 5, y: 7, maximumX: 100, maximumY: 100))
        check(ownership.nativeMouseOwnsPointer, "mouse movement takes local cursor ownership")
        check(ownership.offerNativeRawHid(frame(5)), "feature report accepted unchanged")
        check(ownership.nativeMouseOwnsPointer, "tablet feature reply does not steal mouse cursor")
        check(ownership.offerNativeRawHid(frame(3)), "tablet report accepted unchanged")
        check(!ownership.nativeMouseOwnsPointer, "accepted tablet input returns remote cursor ownership")
        ownership.append(.pointer(x: 6, y: 8, maximumX: 100, maximumY: 100))
        check(ownership.nativeMouseOwnsPointer, "next mouse motion restores native cursor")
        ownership.stop()
        check(!ownership.offerNativeRawHid(frame(3)) && ownership.nativeMouseOwnsPointer, "refused report cannot change pointer owner")
        let preflight = PlankWacomPreflight(clientVersion: "pilot", hostVersion: "test", emit: { _ in })
        preflight.observeHostFeatures(rawHid: true, focusSuspend: true)
        preflight.observeLocalCapture(owned: true)
        check(!preflight.snapshot.ready, "local ownership does not imply Host attachment")
        preflight.observeSentTabletFrame(frame(1, payload:[2,0]))
        preflight.observeSentTabletFrame(frame(2)); check(!preflight.snapshot.ready, "every descriptor required")
        preflight.observeHostFrame(frame(10, payload:[0,0,0,0])); check(!preflight.snapshot.ready, "early ACK cannot skip descriptor")
        preflight.observeSentTabletFrame({ var f = frame(2); f[8] = 1; return f }())
        check(preflight.snapshot.ready, "local owner + all descriptors + Host ACK ready")
        preflight.observeLocalCapture(owned:false); check(!preflight.snapshot.ready, "focus departure revokes readiness")
        preflight.observeLocalCapture(owned:true)
        preflight.observeSentTabletFrame(frame(1, generation:2,payload:[1,0])); preflight.observeSentTabletFrame(frame(2,generation:2))
        preflight.observeHostFrame(frame(10,payload:[0,0,0,0])); check(!preflight.snapshot.ready, "stale ACK cannot approve new generation")
        preflight.observeHostFrame(frame(10,generation:2,payload:[5,0,0,0])); check(!preflight.snapshot.ready, "Host rejection preserved")
        preflight.observeHostFrame(frame(10,generation:2,payload:[0,0,0,0])); check(preflight.snapshot.ready, "new generation independently approved")
        let release = PlankMacWacomReleaseBarrier()
        check(release.wait(seconds: 0.001), "no release queued needs no wait")
        release.didQueue(); check(!release.wait(seconds: 0.001), "release must actually reach endpoint")
        release.didSend(); check(release.wait(seconds: 0.001), "sent release completes teardown")
        release.didSend(); release.didQueue(); check(release.wait(seconds: 0.001), "fast sender completion may precede producer accounting")
        release.didQueue()
        DispatchQueue.global().async { release.didSend() }
        check(release.wait(seconds: 1), "sender can finish release while capture worker is closing")
        print("Mac policies: \(checks) checks passed")
    }
}
