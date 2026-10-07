import AppKit
import Foundation

@main @MainActor struct PlankMacMultipleScreensTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
    static func rejects(_ object: [String: Any], _ message: String) {
        do { _ = try PlankTopologyDecoder.decode(JSONSerialization.data(withJSONObject: object)); check(false, message) }
        catch { check(true, message) }
    }
    static func main() throws {
        _ = NSApplication.shared
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let real = try PlankTopologyDecoder.decode(data)
        check(real.orderedOutputs.map(\.id) == ["x11:DP-0", "x11:DP-2"], "opaque Host identities retained")
        check(real.orderedOutputs.first?.primary == true, "primary retained")
        check(real.displayMode == "separate-displays", "dual negotiates existing composite mode")
        check(real.matches(.ultraHD, second: .portrait1280), "independent Host modes retained")
        check(real.requesting(.ultraHD, second: .portrait1280) == real, "matching request preserves snapshot")
        var rightPrimary = real
        rightPrimary.outputs = real.outputs.map { .init(id: $0.id, name: $0.name, x: $0.x,
            y: $0.y, width: $0.width, height: $0.height, primary: !$0.primary, sourceRect: $0.sourceRect) }
        check(rightPrimary.macPresentationOutputs.map(\.id) == ["x11:DP-2", "x11:DP-0"], "primary window follows Host primary even on right")
        check(rightPrimary.orderedOutputs.map(\.id) == real.orderedOutputs.map(\.id), "primary choice leaves Host spatial mode order intact")
        let primaryGeometry = PlankMacDisplayGeometry(frameWidth: 5120, frameHeight: 2160, topology: rightPrimary, outputIndex: 0)!
        let secondaryGeometry = PlankMacDisplayGeometry(frameWidth: 5120, frameHeight: 2160, topology: rightPrimary, outputIndex: 1)!
        check(primaryGeometry.source == real.orderedOutputs[1].sourceRect, "primary on right retains original stream crop")
        check(secondaryGeometry.source == real.orderedOutputs[0].sourceRect, "secondary on left retains original stream crop")
        let primaryPoint = primaryGeometry.remote(.zero, in: CGRect(x: 0, y: 0, width: 1280, height: 2160), dragging: false)!
        check(primaryPoint == (3840, 0), "primary window input includes right output offset")
        check(primaryGeometry.localCursor(.init(x: 3840, y: 200, frameWidth: 5120, frameHeight: 2160, sequence: 1)) == CGPoint(x: 0, y: 200), "primary cursor follows its output crop")
        let priority = PlankMacDisplayPriority.self
        let macLeft = priority.Display(id: 12, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        let macMain = priority.Display(id: 34, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440))
        let macRight = priority.Display(id: 56, frame: CGRect(x: 2560, y: -200, width: 1920, height: 1080))
        let displays = [macLeft, macRight, macMain]
        check(priority.orderedIDs(displays, primary: 34) == [34, 12, 56], "system primary first even when not leftmost or enumerated first")
        check(priority.targetID(outputIndex: 0, displays: displays, primary: 34) == 34, "Host primary assigned to Mac primary")
        check(priority.targetID(outputIndex: 1, displays: displays, primary: 34) == 12, "secondary uses remaining display in stable spatial order")
        check(priority.orderedIDs(Array(displays.reversed()), primary: 34) == [34, 12, 56], "enumeration changes cannot swap window roles")
        check(priority.targetID(outputIndex: 0, displays: displays, primary: 12) == 12, "changed Mac primary reassigns primary role")
        check(priority.targetID(outputIndex: 1, displays: displays, primary: 12) == 34, "changed Mac primary reassigns secondary role")
        check(priority.targetID(outputIndex: 1, displays: [macMain], primary: 34) == 34, "removed secondary falls back to remaining screen")
        check(priority.targetID(outputIndex: 1, displays: [], primary: 34) == nil, "no displays defers assignment")
        check(priority.targetID(outputIndex: 2, displays: displays, primary: 34) == nil, "unknown window role rejected")
        check(priority.id(priority.screens().first!) == CGMainDisplayID(), "production adapter uses system primary")
        let single = real.requesting(.standard)
        check(single.displayMode == "scaled-span" && single.outputs.isEmpty && single.desktopWidth == 2560,
              "layout replacement never invents source identities")
        check(!PlankTopology.validCanvas(first: .ultrawide, second: .ultrawide), "unsupported canvas rejected")
        check(PlankTopology.validCanvas(first: .dci4K, second: .dci4K), "8192 boundary accepted")
        var negative = real
        negative.desktopX = -3840; negative.desktopY = -300
        negative.outputs = real.outputs.map { .init(id: $0.id, name: $0.name, x: $0.x - 3840,
            y: $0.y - 300, width: $0.width, height: $0.height, primary: $0.primary, sourceRect: $0.sourceRect) }
        let left = PlankMacDisplayGeometry(frameWidth: 5120, frameHeight: 2160, topology: negative, outputIndex: 0)!
        let right = PlankMacDisplayGeometry(frameWidth: 5120, frameHeight: 2160, topology: negative, outputIndex: 1)!
        check(left.source.x == 0 && right.source.x == 3840, "negative desktop origins do not offset source pixels")
        check(right.normalizedCrop == CGRect(x: 0.75, y: 0, width: 0.25, height: 1), "Metal UV crop")
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 1080)
        for (geometry, rect) in [(left, left.canvas(in: bounds)), (right, right.canvas(in: bounds))] {
            let start = geometry.remote(rect.origin, in: bounds, dragging: false)!
            check(start.0 == geometry.source.x && start.1 == geometry.source.y, "top left accurate")
            let end = geometry.remote(CGPoint(x: rect.maxX, y: rect.maxY), in: bounds, dragging: true)!
            check(end.0 == geometry.source.x + geometry.source.width - 1 && end.1 == 2159, "held drag clamps to final pixel")
            check(geometry.remote(CGPoint(x: -1000, y: -1000), in: bounds, dragging: false) == nil, "letterbox rejects click")
            let outside = geometry.remote(CGPoint(x: -1000, y: -1000), in: bounds, dragging: true)!
            check(outside.0 == geometry.source.x && outside.1 == geometry.source.y, "held drag outside clamps safely")
        }
        // Same source coordinate at 1x/2x local point layouts. No backing pixel
        // factor belongs in the remote absolute-input message.
        let midpoint1 = right.remote(CGPoint(x: 320, y: 540), in: bounds, dragging: false)!
        let midpoint2 = right.remote(CGPoint(x: 640, y: 1080),
            in: CGRect(x: 0, y: 0, width: 1280, height: 2160), dragging: false)!
        check(midpoint1 == midpoint2, "mixed Retina point geometry does not double remote input")
        let seam = PlankRemoteCursor(x: 3840, y: 200, frameWidth: 5120, frameHeight: 2160, sequence: 1)
        check(left.localCursor(seam) == nil && right.localCursor(seam) == CGPoint(x: 0, y: 200), "seam belongs to exactly one output")
        check(right.localCursor(.init(x: 5119, y: 2159, frameWidth: 5120, frameHeight: 2160, sequence: 2)) == CGPoint(x: 1279, y: 2159), "last pixel preserved")
        check(PlankMacDisplayGeometry(frameWidth: 2560, frameHeight: 1440, topology: real, outputIndex: 1) == nil, "stale frame cannot be rendered or mapped with new topology")
        check(PlankMacDisplayGeometry(frameWidth: 5120, frameHeight: 2160, topology: real, outputIndex: 2) == nil, "missing output rejected")

        let overlay = PlankMacCursorOverlay(frame: bounds)
        overlay.setGeometry(right); overlay.cursor(seam)
        let sprite = overlay.layer!.sublayers!.first!
        check(!sprite.isHidden && sprite.frame.minX < 1, "production cursor sprite uses cropped local coordinate")
        overlay.setGeometry(left)
        check(sprite.isHidden, "sprite hidden on other output")
        overlay.setGeometry(right); overlay.setLocalMouse(true)
        check(sprite.isHidden, "native mouse does not double-render Host cursor")

        let focus = PlankMacSessionFocus.self
        check(focus.active(appActive: true, windows: [.init(key: true, main: true), .init(key: false, main: false)]), "first window owns Wacom")
        check(focus.active(appActive: true, windows: [.init(key: false, main: false), .init(key: true, main: true)]), "focus transfer keeps one owner")
        check(focus.active(appActive: true, windows: [.init(key: true, main: true)]), "secondary removal retains owner")
        check(!focus.active(appActive: false, windows: [.init(key: true, main: true)]), "app background releases desktop capture")
        check(!focus.active(appActive: true, windows: []), "last window removal releases capture")

        let surfaces = PlankVideoSurfaces(), id1 = UUID(), id2 = UUID()
        var firstFrames = 0, secondFrames = 0, firstCursors = 0, secondCursors = 0
        surfaces.register(id: id1, surface: .init(frame: { _ in firstFrames += 1 }, cursor: { _ in firstCursors += 1 }, shape: { _ in }))
        surfaces.register(id: id2, surface: .init(frame: { _ in secondFrames += 1 }, cursor: { _ in secondCursors += 1 }, shape: { _ in }))
        surfaces.frame(nil); surfaces.cursor(seam)
        check(firstFrames == 1 && secondFrames == 1 && firstCursors == 1 && secondCursors == 1, "one decode and cursor update reach both windows")
        surfaces.unregister(id: id2); surfaces.frame(nil); surfaces.cursor(nil)
        check(firstFrames == 2 && firstCursors == 2 && secondFrames == 1 && secondCursors == 1, "closing secondary preserves first callbacks")
        surfaces.unregister(id: id1); surfaces.frame(nil)
        check(firstFrames == 2, "disposed surface never receives another frame")
        var bookmark = HostBookmark(name: "Test", address: "test")
        let old = bookmark
        bookmark.secondDisplaySize = .portrait1280
        check(PlankBookmarkSessionPolicy.requiresClosure(edited: bookmark, connected: old, authenticated: true), "adding output requires explicit session close")
        let roundtrip = try JSONDecoder().decode(HostBookmark.self, from: JSONEncoder().encode(bookmark))
        check(roundtrip.secondDisplaySize == .portrait1280, "second mode persists")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        legacy.removeValue(forKey: "secondDisplaySize")
        check(try JSONDecoder().decode(HostBookmark.self, from: JSONSerialization.data(withJSONObject: legacy)).secondDisplaySize == nil, "old bookmark stays single")

        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var records = object["outputs"] as! [[String: Any]]
        records[1]["source_rect"] = ["x": 5000, "y": 0, "width": 1280, "height": 2160]
        object["outputs"] = records; rejects(object, "out of bounds crop rejected")
        object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        records = object["outputs"] as! [[String: Any]]
        records[1]["id"] = records[0]["id"]; object["outputs"] = records; rejects(object, "duplicate output rejected")
        object.removeValue(forKey: "outputs"); rejects(object, "advertised rectangles cannot be absent")
        object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["desktop"] = ["width": Int.max, "height": 2160]; rejects(object, "malformed allocation size bounded")
        print("Mac multiple screens: \(checks) checks passed")
    }
}
