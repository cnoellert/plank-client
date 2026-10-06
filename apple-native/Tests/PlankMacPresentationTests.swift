import AppKit

@main @MainActor struct PlankMacPresentationTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
    static func position(width: Int = 100, height: Int = 100) -> PlankRemoteCursor {
        PlankRemoteCursor(x: 50, y: 50, frameWidth: width, frameHeight: height, sequence: 1)
    }
    static func main() {
        _ = NSApplication.shared
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        root.wantsLayer = true
        let video = NSView(frame: root.bounds); video.wantsLayer = true
        video.layer?.backgroundColor = NSColor.green.cgColor
        root.addSubview(video)
        let overlay = PlankMacCursorOverlay(frame: root.bounds)
        root.addSubview(overlay, positioned: .above, relativeTo: video)
        let window = NSWindow(contentRect: root.bounds, styleMask: [.titled,.closable], backing: .buffered, defer: false)
        window.contentView = root
        overlay.setDimensions(width: 100, height: 100)
        check(!overlay.replacesSystemCursor, "no Host position keeps native arrow")
        overlay.cursor(position())
        check(overlay.replacesSystemCursor, "position before shape has a visible fallback arrow")
        let sprite = overlay.layer!.sublayers!.first!
        check(!sprite.isHidden && sprite.contents != nil, "fallback has actual artwork")
        let shape = PlankRemoteCursorShape(pixels: Data([0,0,255,255, 0,0,255,255, 0,0,255,255, 0,0,255,255]),
            width: 2, height: 2, hotspotX: 0, hotspotY: 0, visible: true, generation: 1)
        overlay.cursorShape(shape)
        check(!sprite.isHidden && sprite.frame == CGRect(x: 50,y: 50,width: 2,height: 2), "Host cursor position and artwork")
        check(root.subviews.last === overlay && overlay.layer!.zPosition > video.layer!.zPosition, "cursor owns a view above video")
        // AppKit keeps backing layers of an unshown test window detached.
        // Compose its actual production cursor layer above the opaque video
        // layer to verify artwork and alpha, alongside the view-order check.
        root.layoutSubtreeIfNeeded()
        let composition = CALayer()
        composition.frame = root.bounds
        composition.addSublayer(video.layer!)
        composition.addSublayer(overlay.layer!)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 400, bitsPerPixel: 32)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        composition.render(in: graphics.cgContext)
        let color = bitmap.colorAt(x: 50,y: 50)!.usingColorSpace(.deviceRGB)!
        check(color.redComponent > 0.9 && color.greenComponent < 0.1, "Host cursor pixels appear above opaque video after layout")
        overlay.cursorShape(PlankRemoteCursorShape(pixels: shape.pixels,width: 2,height: 2,hotspotX: 0,hotspotY: 0,visible: false,generation: 2))
        check(sprite.isHidden && overlay.replacesSystemCursor, "explicit Host hiding respected")
        overlay.setDimensions(width: 200,height: 100)
        check(!overlay.replacesSystemCursor && sprite.isHidden, "stale position not mapped into a new resolution")
        overlay.cursorShape(nil)
        overlay.cursor(position(width: 200))
        check(overlay.replacesSystemCursor && !sprite.isHidden, "new-resolution position recovers visible fallback")
        overlay.setDimensions(width: 0,height: 0)
        check(!overlay.replacesSystemCursor && sprite.isHidden, "disconnect releases native pointer hiding")
        window.collectionBehavior = [.fullScreenAuxiliary]
        PlankMacDesktopWindow.configure(window)
        check(window.styleMask.contains(.resizable), "desktop resizable")
        check(window.collectionBehavior.contains(.fullScreenPrimary) && !window.collectionBehavior.contains(.fullScreenAuxiliary), "desktop can be primary fullscreen window")
        check(window.standardWindowButton(.zoomButton)?.isEnabled == true, "green fullscreen control enabled")
        let shortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control,.command], timestamp: 0,
            windowNumber: 0, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
        check(PlankMacKeys.staysLocal(shortcut), "fullscreen shortcut is not forwarded to Host")
        print("Mac cursor composition and fullscreen: \(checks) checks passed")
    }
}
