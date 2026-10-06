import AppKit
import SwiftUI

struct PlankMacSurface: NSViewRepresentable {
    let client: PlankCoreClient
    func makeNSView(context: Context) -> PlankMacInputView {
        let view = PlankMacInputView(client: client)
        client.registerVideoSurface(id: view.surfaceID, frame: { [weak view] in view?.display($0) },
            cursor: { [weak view] in view?.cursor($0) }, cursorShape: { [weak view] in view?.shape($0) })
        return view
    }
    func updateNSView(_ view: PlankMacInputView, context: Context) {}
    static func dismantleNSView(_ view: PlankMacInputView, coordinator: ()) {
        view.releaseInput(); view.client.setTabletActive(false); view.client.unregisterVideoSurface(id: view.surfaceID)
    }
}
final class PlankMacInputView: NSView {
    let client: PlankCoreClient
    let surfaceID = UUID()
    private let video = PlankMacMetalView(frame: .zero)
    private let software = CALayer()
    private let remoteCursor = CALayer()
    private var cursorState: PlankRemoteCursor?
    private var cursorShape: PlankRemoteCursorShape?
    private var width = 0, height = 0
    private var heldButtons = Set<UInt8>()
    private var heldKeys = Set<UInt16>()
    private var modifierKeys = Set<UInt16>()
    private var observations = [NSObjectProtocol]()
    private var tracking: NSTrackingArea?
    private var canvas: CGRect { PlankMacCoordinates.canvas(in: bounds, width: width, height: height) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(client: PlankCoreClient) {
        self.client = client; super.init(frame: .zero); wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor; addSubview(video)
        layer?.addSublayer(software); software.contentsGravity = .resizeAspect
        layer?.addSublayer(remoteCursor); remoteCursor.isHidden = true
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observations.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateFocus() }
            })
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    isolated deinit { observations.forEach(NotificationCenter.default.removeObserver) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.acceptsMouseMovedEvents = true; window?.makeFirstResponder(self); updateFocus() }
    private func updateFocus() {
        let owned = NSApp.isActive && (window?.isKeyWindow == true || window?.isMainWindow == true)
        if !owned { releaseInput() }; client.setTabletActive(owned)
    }
    override func layout() { super.layout(); video.frame = canvas; software.frame = canvas; placeCursor(); window?.invalidateCursorRects(for: self) }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.inVisibleRect,.activeInKeyWindow,.mouseMoved,.cursorUpdate,.mouseEnteredAndExited], owner: self)
        addTrackingArea(next); tracking = next; super.updateTrackingAreas()
    }
    func display(_ frame: PlankRenderedFrame?) {
        guard let frame else { width = 0; height = 0; video.isHidden = true; software.contents = nil; remoteCursor.isHidden = true; return }
        width = frame.width; height = frame.height; needsLayout = true
        if let pixels = frame.pixelBuffer { video.isHidden = false; software.contents = nil; video.display(pixels) }
        else if let provider = CGDataProvider(data: frame.pixels as CFData) {
            video.isHidden = true
            software.contents = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: frame.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: .byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
    }
    func cursor(_ position: PlankRemoteCursor?) { cursorState = position; placeCursor() }
    func shape(_ shape: PlankRemoteCursorShape?) {
        cursorShape = shape
        if let shape, shape.pixels.count == shape.width * shape.height * 4,
           let provider = CGDataProvider(data: shape.pixels as CFData) {
            remoteCursor.contents = CGImage(width: shape.width, height: shape.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: shape.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: .byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        } else { remoteCursor.contents = nil }
        placeCursor()
    }
    private func placeCursor() {
        guard let position = cursorState, let shape = cursorShape, shape.visible, width > 1, height > 1 else { remoteCursor.isHidden = true; return }
        let scale = canvas.width / Double(width)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        remoteCursor.frame = CGRect(x: canvas.minX + Double(position.x - shape.hotspotX) * scale,
            y: canvas.minY + Double(position.y - shape.hotspotY) * scale,
            width: Double(shape.width) * scale, height: Double(shape.height) * scale)
        remoteCursor.isHidden = remoteCursor.contents == nil; CATransaction.commit()
    }
    private func pointer(_ event: NSEvent) -> Bool {
        guard NSApp.isActive, window?.isKeyWindow == true,
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
        guard canvas.contains(convert(event.locationInWindow, from: nil)) else { return }
        let factor = event.hasPreciseScrollingDeltas ? 1.0 : 120.0
        client.scroll(vertical: Int16(clamping: Int(event.scrollingDeltaY * factor)), horizontal: Int16(clamping: Int(event.scrollingDeltaX * factor)))
    }
    override func keyDown(with event: NSEvent) {
        guard !PlankMacKeys.staysLocal(event), let key = PlankMacKeys.table[event.keyCode] else { super.keyDown(with: event); return }
        heldKeys.insert(key); client.sendKey(code: key, pressed: true, modifiers: PlankMacKeys.modifiers(event.modifierFlags))
    }
    override func keyUp(with event: NSEvent) {
        guard let key = PlankMacKeys.table[event.keyCode], heldKeys.remove(key) != nil else { return }
        client.sendKey(code: key, pressed: false, modifiers: PlankMacKeys.modifiers(event.modifierFlags))
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if PlankMacKeys.staysLocal(event) { return false }; keyDown(with: event); return true
    }
    override func flagsChanged(with event: NSEvent) {
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
    override func resignFirstResponder() -> Bool { releaseInput(); return true }
    func releaseInput() {
        heldButtons.forEach { client.setMouseButton(number: $0, pressed: false) }
        heldKeys.union(modifierKeys).forEach { client.sendKey(code: $0, pressed: false, modifiers: 0) }
        heldButtons.removeAll(); heldKeys.removeAll(); modifierKeys.removeAll()
    }
    override func resetCursorRects() {
        if !canvas.isEmpty { addCursorRect(canvas, cursor: NSCursor(image: NSImage(size: NSSize(width: 1,height: 1)), hotSpot: .zero)) }
    }
    override func cursorUpdate(with event: NSEvent) {
        if canvas.contains(convert(event.locationInWindow, from: nil)), width > 0 {
            NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero).set()
        } else { NSCursor.arrow.set() }
    }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
}
