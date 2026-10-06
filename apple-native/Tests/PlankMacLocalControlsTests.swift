import AppKit
import SwiftUI

// Only transport and video are substituted. The real AppKit input view,
// cursor overlay, and window delegate run without connecting to a Host.
@MainActor final class PlankCoreClient {
    var keys: [(UInt16, Bool)] = []
    var tabletChanges = 0
    func setTabletActive(_ active: Bool) { tabletChanges += 1 }
    func registerVideoSurface(id: UUID, frame: (PlankRenderedFrame?) -> Void,
        cursor: (PlankRemoteCursor?) -> Void, cursorShape: (PlankRemoteCursorShape?) -> Void) {}
    func unregisterVideoSurface(id: UUID) {}
    func movePointer(x: Int, y: Int, width: Int, height: Int) {}
    func setMouseButton(number: UInt8, pressed: Bool) {}
    func scroll(vertical: Int16, horizontal: Int16) {}
    func sendKey(code: UInt16, pressed: Bool, modifiers: UInt8) { keys.append((code, pressed)) }
    func pressKey(code: UInt16) {}
}
final class PlankMacMetalView: NSView {
    func display(_ buffer: CVPixelBuffer) {}
}
@MainActor final class OriginalDelegate: NSObject, NSWindowDelegate {
    var closes = 0
    func windowShouldClose(_ sender: NSWindow) -> Bool { closes += 1; return false }
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposed: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        proposed.union([.disableProcessSwitching, .hideMenuBar, .hideDock])
    }
}
@main @MainActor struct PlankMacLocalControlsTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
    static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let original = OriginalDelegate()
        window.delegate = original
        let presentation = PlankMacWindowPresentation(window: window)
        check(window.delegate === presentation, "desktop delegate installed")
        let options = window.delegate!.window!(window, willUseFullScreenPresentationOptions: [])
        check(options.contains([.fullScreen, .autoHideMenuBar, .autoHideDock, .autoHideToolbar]), "fullscreen chrome auto-hides")
        check(!options.contains(.hideMenuBar) && !options.contains(.hideDock), "mutually exclusive options removed")
        check(options.contains(.disableProcessSwitching), "original delegate options preserved")
        check(window.delegate!.windowShouldClose!(window) == false && original.closes == 1, "optional lifecycle callback forwarded")
        presentation.remove()
        check(window.delegate === original, "previous window delegate restored")
        let replacement = OriginalDelegate()
        window.delegate = replacement
        presentation.install()
        check(window.delegate!.windowShouldClose!(window) == false && replacement.closes == 1, "later SwiftUI delegate preserved on reinstall")
        presentation.remove()
        check(window.delegate === replacement, "later delegate restored")

        let client = PlankCoreClient()
        let view = PlankMacInputView(client: client)
        let settings = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: 0, context: nil, characters: ",", charactersIgnoringModifiers: ",",
            isARepeat: false, keyCode: 43)!
        check(!view.performKeyEquivalent(with: settings) && client.keys.isEmpty, "Mac Settings shortcut stays local")
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: 0)!
        view.keyDown(with: key)
        check(client.keys.count == 1 && client.keys[0].1, "desktop key pressed")
        NSCursor.crosshair.set()
        view.setLocalControlsPresented(true)
        check(client.keys.count == 2 && !client.keys[1].1, "opening controls releases held remote key")
        check(client.tabletChanges == 0, "opening controls leaves tablet ownership untouched")
        check(NSCursor.current === NSCursor.arrow, "local controls restore native arrow")
        check(!view.performKeyEquivalent(with: key), "local controls leave shortcuts to AppKit")
        view.flagsChanged(with: key)
        view.keyUp(with: key)
        check(client.keys.count == 2, "no remote input leaks through controls")
        view.setLocalControlsPresented(false)
        view.keyDown(with: key)
        check(client.keys.count == 3 && client.keys[2].1, "desktop keyboard resumes after controls close")
        view.releaseInput()
        check(client.keys.count == 4 && !client.keys[3].1, "resumed key releases normally")
        check(client.tabletChanges == 0, "control dismissal does not recapture tablet")

        // Full-screen toolbars overlap content without leaving its bounds.
        // Exercise the actual input view beneath a real native control.
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        view.frame = root.bounds
        root.addSubview(view)
        window.contentView = root
        view.display(PlankRenderedFrame(pixels: Data(count: 640 * 360 * 4), pixelBuffer: nil,
            width: 640, height: 360, bytesPerRow: 640 * 4, frameNumber: 1))
        view.layoutSubtreeIfNeeded()
        let center = view.convert(NSPoint(x: 320, y: 180), to: nil)
        check(view.ownsDesktopPoint(center), "uncovered video owns pointer")
        let toolbar = NSButton(frame: root.bounds.insetBy(dx: 100, dy: 100))
        root.addSubview(toolbar, positioned: .above, relativeTo: view)
        check(!view.ownsDesktopPoint(center), "overlapping native toolbar excludes hidden cursor and remote routing")
        let ownershipChanges = client.tabletChanges
        NSCursor.crosshair.set()
        let hover = NSEvent.mouseEvent(with: .mouseMoved, location: center, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
        view.cursorUpdate(with: hover)
        check(NSCursor.current === NSCursor.arrow, "toolbar cursor update restores visible arrow")
        check(client.tabletChanges == ownershipChanges, "toolbar hover leaves tablet capture unchanged")
        toolbar.removeFromSuperview()
        check(view.ownsDesktopPoint(center), "desktop routing resumes after toolbar retracts")
        view.setLocalControlsPresented(true)
        check(!view.ownsDesktopPoint(center), "popover remains local even over video")
        view.detachWindowPresentation()

        let region = PlankMacLocalPointerView(frame: NSRect(x: 0, y: 0, width: 40, height: 24))
        check(region.hitTest(NSPoint(x: 20, y: 12)) == nil, "native pointer region never intercepts buttons")
        NSCursor.crosshair.set(); region.cursorUpdate(with: hover)
        check(NSCursor.current === NSCursor.arrow, "local control owns a visible native arrow")

        var bitrate = 50_000.0
        var finalUpdates = 0
        let control = PlankMacSlider(value: Binding(get: { bitrate }, set: { bitrate = $0 }),
            range: 10_000...150_000, step: 500, label: "Video bitrate", editingChanged: { if !$0 { finalUpdates += 1 } })
        let coordinator = PlankMacSlider.Coordinator(parent: control)
        let slider = PlankMacNativeSlider(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        slider.cell = PlankMacSliderCell(); slider.minValue = 10_000; slider.maxValue = 150_000
        slider.doubleValue = 100_260; coordinator.changed(slider)
        check(bitrate == 100_500 && slider.doubleValue == 100_500, "native slider snaps bitrate in 500 kbps steps")
        check(finalUpdates == 1, "keyboard/accessibility changes commit without a mouse release")
        slider.doubleValue = 999_999; coordinator.changed(slider)
        check(bitrate == 150_000, "native slider keeps upper bitrate bound")
        let cell = slider.cell as! PlankMacSliderCell
        for enabled in [true, false] {
            cell.isEnabled = enabled
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 24,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 96, bitsPerPixel: 32)!
            let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
            NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 24, height: 24).fill()
            cell.drawKnob(NSRect(x: 5, y: 5, width: 14, height: 14))
            NSGraphicsContext.restoreGraphicsState()
            let color = bitmap.colorAt(x: 12, y: 12)!.usingColorSpace(.deviceRGB)!
            check(color.redComponent > 0.5 && color.greenComponent > 0.5 && color.blueComponent > 0.5,
                "native slider handle visible in enabled and disabled states")
        }
        print("Mac local controls and fullscreen delegate: \(checks) checks passed")
    }
}
