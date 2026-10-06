import AppKit
import SwiftUI

struct PlankMacSurface: NSViewRepresentable {
    let client: PlankCoreClient
    var windowChanged: (NSWindow?) -> Void = { _ in }
    var localControlsPresented = false
    func makeNSView(context: Context) -> PlankMacInputView {
        let view = PlankMacInputView(client: client)
        view.windowChanged = windowChanged
        view.setLocalControlsPresented(localControlsPresented)
        client.registerVideoSurface(id: view.surfaceID, frame: { [weak view] in view?.display($0) },
            cursor: { [weak view] in view?.cursor($0) }, cursorShape: { [weak view] in view?.shape($0) })
        return view
    }
    func updateNSView(_ view: PlankMacInputView, context: Context) {
        view.windowChanged = windowChanged
        view.setLocalControlsPresented(localControlsPresented)
    }
    static func dismantleNSView(_ view: PlankMacInputView, coordinator: ()) {
        view.releaseInput(); view.restoreLocalCursor(); view.detachWindowPresentation()
        view.client.setTabletActive(false); view.client.unregisterVideoSurface(id: view.surfaceID)
    }
}
final class PlankMacInputView: NSView {
    let client: PlankCoreClient
    let surfaceID = UUID()
    private let video = PlankMacMetalView(frame: .zero)
    private let software = CALayer()
    private let cursorOverlay = PlankMacCursorOverlay(frame: .zero)
    var windowChanged: (NSWindow?) -> Void = { _ in }
    private var width = 0, height = 0
    private var heldButtons = Set<UInt8>()
    private var heldKeys = Set<UInt16>()
    private var modifierKeys = Set<UInt16>()
    private var observations = [NSObjectProtocol]()
    private var tracking: NSTrackingArea?
    private var replacingSystemCursor = false
    private var localControlsPresented = false
    private var windowPresentation: PlankMacWindowPresentation?
    private var cursorMonitor: Any?
    private let hiddenCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
    private var canvas: CGRect { PlankMacCoordinates.canvas(in: bounds, width: width, height: height) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(client: PlankCoreClient) {
        self.client = client; super.init(frame: .zero); wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor; addSubview(video)
        layer?.addSublayer(software); software.contentsGravity = .resizeAspect
        addSubview(cursorOverlay, positioned: .above, relativeTo: video)
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observations.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateFocus() }
            })
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    isolated deinit {
        observations.forEach(NotificationCenter.default.removeObserver)
        if let cursorMonitor { NSEvent.removeMonitor(cursorMonitor) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detachWindowPresentation()
        if let window {
            PlankMacDesktopWindow.configure(window)
            windowPresentation = PlankMacWindowPresentation(window: window)
            // The full-screen toolbar can cover the canvas without causing
            // mouseExited. Restore the local pointer before native controls
            // receive their events; never consume or reroute those events.
            cursorMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged,
                .rightMouseDragged, .otherMouseDragged, .cursorUpdate, .leftMouseDown,
                .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
                self?.updatePointerAppearance(for: event)
                return event
            }
            window.acceptsMouseMovedEvents = true; window.makeFirstResponder(self)
        }
        // SwiftUI's window reference is updated after the representable has
        // completed its view update; no session action is taken here.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let window { PlankMacDesktopWindow.configure(window) }
            windowPresentation?.install()
            windowChanged(window)
        }
        updateFocus()
    }
    private func updateFocus() {
        let owned = NSApp.isActive && (window?.isKeyWindow == true || window?.isMainWindow == true)
        if !NSApp.isActive || window?.isKeyWindow != true || localControlsPresented { restoreLocalCursor() }
        if !owned { releaseInput() }; client.setTabletActive(owned)
    }
    func detachWindowPresentation() {
        windowPresentation?.remove(); windowPresentation = nil
        if let cursorMonitor { NSEvent.removeMonitor(cursorMonitor); self.cursorMonitor = nil }
    }
    func setLocalControlsPresented(_ presented: Bool) {
        guard localControlsPresented != presented else { return }
        localControlsPresented = presented
        if presented { releaseInput(); restoreLocalCursor() }
        window?.invalidateCursorRects(for: self)
        // Local controls retain tablet ownership. This affects cursor and
        // keyboard/mouse routing only, never the raw Wacom capture lifetime.
    }
    func restoreLocalCursor() { PlankMacLocalPointerView.showArrow() }
    override func layout() { super.layout(); video.frame = canvas; software.frame = canvas; cursorOverlay.frame = bounds; refreshNativeCursor(); window?.invalidateCursorRects(for: self) }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.inVisibleRect,.activeInKeyWindow,.mouseMoved,.cursorUpdate,.mouseEnteredAndExited], owner: self)
        addTrackingArea(next); tracking = next; super.updateTrackingAreas()
    }
    func display(_ frame: PlankRenderedFrame?) {
        guard let frame else { width = 0; height = 0; video.isHidden = true; software.contents = nil; cursorOverlay.setDimensions(width: 0, height: 0); refreshNativeCursor(); return }
        width = frame.width; height = frame.height; needsLayout = true
        cursorOverlay.setDimensions(width: width, height: height)
        if let pixels = frame.pixelBuffer { video.isHidden = false; software.contents = nil; video.display(pixels) }
        else if let provider = CGDataProvider(data: frame.pixels as CFData) {
            video.isHidden = true
            software.contents = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: frame.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: .byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
    }
    func cursor(_ position: PlankRemoteCursor?) { cursorOverlay.cursor(position); refreshNativeCursor() }
    func shape(_ shape: PlankRemoteCursorShape?) { cursorOverlay.cursorShape(shape); refreshNativeCursor() }
    private func pointer(_ event: NSEvent) -> Bool {
        guard !localControlsPresented, NSApp.isActive, window?.isKeyWindow == true,
              (!heldButtons.isEmpty || ownsDesktopPoint(event.locationInWindow)),
              let (x,y) = PlankMacCoordinates.remote(convert(event.locationInWindow, from: nil), canvas: canvas,
                 width: width, height: height, dragging: !heldButtons.isEmpty) else { return false }
        client.movePointer(x: x, y: y, width: width, height: height); return true
    }
    override func mouseMoved(with event: NSEvent) { _ = pointer(event) }
    override func mouseDragged(with event: NSEvent) { _ = pointer(event) }
    override func rightMouseDragged(with event: NSEvent) { _ = pointer(event) }
    override func otherMouseDragged(with event: NSEvent) { _ = pointer(event) }
    private func down(_ event: NSEvent, button: UInt8) {
        guard pointer(event) else { return }; window?.makeFirstResponder(self)
        heldButtons.insert(button); client.setMouseButton(number: button, pressed: true)
    }
    private func up(_ button: UInt8) { if heldButtons.remove(button) != nil { client.setMouseButton(number: button, pressed: false) } }
    override func mouseDown(with event: NSEvent) { down(event, button: 1) }
    override func mouseUp(with event: NSEvent) { up(1) }
    override func rightMouseDown(with event: NSEvent) { down(event, button: 3) }
    override func rightMouseUp(with event: NSEvent) { up(3) }
    override func otherMouseDown(with event: NSEvent) { if let button = PlankMacKeys.mouseButton(event.buttonNumber) { down(event, button: button) } }
    override func otherMouseUp(with event: NSEvent) { if let button = PlankMacKeys.mouseButton(event.buttonNumber) { up(button) } }
    override func scrollWheel(with event: NSEvent) {
        guard !localControlsPresented, NSApp.isActive, window?.isKeyWindow == true,
              ownsDesktopPoint(event.locationInWindow) else { return }
        let factor = event.hasPreciseScrollingDeltas ? 1.0 : 120.0
        client.scroll(vertical: Int16(clamping: Int(event.scrollingDeltaY * factor)), horizontal: Int16(clamping: Int(event.scrollingDeltaX * factor)))
    }
    override func keyDown(with event: NSEvent) {
        guard !localControlsPresented else { super.keyDown(with: event); return }
        guard !PlankMacKeys.staysLocal(event), let key = PlankMacKeys.table[event.keyCode] else { super.keyDown(with: event); return }
        heldKeys.insert(key); client.sendKey(code: key, pressed: true, modifiers: PlankMacKeys.modifiers(event.modifierFlags))
    }
    override func keyUp(with event: NSEvent) {
        guard let key = PlankMacKeys.table[event.keyCode], heldKeys.remove(key) != nil else { return }
        client.sendKey(code: key, pressed: false, modifiers: PlankMacKeys.modifiers(event.modifierFlags))
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if localControlsPresented || PlankMacKeys.staysLocal(event) { return false }; keyDown(with: event); return true
    }
    override func flagsChanged(with event: NSEvent) {
        guard !localControlsPresented else { return }
        if event.keyCode == 57 { client.pressKey(code: 0x14); return }
        let next = PlankMacKeys.modifiers(event.modifierFlags)
        let keys: [(UInt8,UInt16)] = [(1,0x10),(2,0x11),(4,0x12),(8,0x5b)]
        for (bit,key) in keys {
            let pressed = next & bit != 0
            if pressed != modifierKeys.contains(key) {
                if pressed { modifierKeys.insert(key) } else { modifierKeys.remove(key) }
                client.sendKey(code: key, pressed: pressed, modifiers: next)
            }
        }
    }
    override func resignFirstResponder() -> Bool { releaseInput(); restoreLocalCursor(); return true }
    func releaseInput() {
        heldButtons.forEach { client.setMouseButton(number: $0, pressed: false) }
        heldKeys.union(modifierKeys).forEach { client.sendKey(code: $0, pressed: false, modifiers: 0) }
        heldButtons.removeAll(); heldKeys.removeAll(); modifierKeys.removeAll()
    }
    // Do not register a hidden cursor rectangle over the entire canvas:
    // AppKit's revealed full-screen toolbar overlaps that rectangle.
    override func resetCursorRects() {}
    func ownsDesktopPoint(_ windowPoint: NSPoint) -> Bool {
        guard !localControlsPresented, window != nil, width > 0,
              canvas.contains(convert(windowPoint, from: nil)) else { return false }
        var root: NSView = self
        while let parent = root.superview { root = parent }
        let point = root.superview?.convert(windowPoint, from: nil) ?? windowPoint
        guard let hit = root.hitTest(point) else { return false }
        return hit === self || hit.isDescendant(of: self)
    }
    func updatePointerAppearance(for event: NSEvent) {
        if event.window === window && ownsDesktopPoint(event.locationInWindow) { canvasCursor.set() }
        else { restoreLocalCursor() }
    }
    private var canvasCursor: NSCursor {
        !localControlsPresented && NSApp.isActive && window?.isKeyWindow == true && cursorOverlay.replacesSystemCursor ? hiddenCursor : .arrow
    }
    private func refreshNativeCursor() {
        guard replacingSystemCursor != cursorOverlay.replacesSystemCursor else { return }
        replacingSystemCursor = cursorOverlay.replacesSystemCursor
        if !replacingSystemCursor { restoreLocalCursor() }
        window?.invalidateCursorRects(for: self)
    }
    override func cursorUpdate(with event: NSEvent) {
        updatePointerAppearance(for: event)
    }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
}
