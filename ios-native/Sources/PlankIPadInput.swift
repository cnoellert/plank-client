import SwiftUI
import UIKit

@MainActor final class PlankIPadInputRouter: ObservableObject {
    weak var surface: PlankIPadInputView?
    let client: PlankCoreClient
    var enabled = false {
        didSet {
            if !enabled { release() }
            else if !oldValue { surface?.resumeKeyboard() }
        }
    }
    private var held = PlankIPadHeldInput()
    private var pencil = PlankIPadPencilPolicy()
    var pencilTouching: Bool { pencil.touching }
    init(client: PlankCoreClient) { self.client = client }
    func pointer(_ point: CGPoint, viewport: PlankIPadViewport, dragging: Bool) -> Bool {
        guard !pencil.touching else { return false }
        retirePencil()
        guard enabled, let pixel = viewport.map(point, held: dragging) else { return false }
        client.movePointer(x: pixel.x, y: pixel.y, width: viewport.width, height: viewport.height)
        return true
    }
    @discardableResult
    func pen(_ phase: PlankNormalizedPen.Phase, point: CGPoint, viewport: PlankIPadViewport,
             timestamp: Double, force: Double, maximumForce: Double,
             altitude: Double, azimuth: Double, distance: Double = 0) -> Bool {
        guard enabled, client.acceptsNormalizedPen,
              let packet = pencil.sample(phase, point: point, viewport: viewport, timestamp: timestamp,
                  force: force, maximumForce: maximumForce, altitude: altitude, azimuth: azimuth,
                  distance: distance) else { return false }
        client.sendPen(packet)
        return true
    }
    func retirePencil() {
        for packet in pencil.retire() { client.sendPen(packet) }
    }
    func button(_ number: UInt8, pressed: Bool) {
        guard (!pressed || enabled), held.button(number, pressed: pressed) else { return }
        client.setMouseButton(number: number, pressed: pressed)
    }
    func key(_ code: UInt16, pressed: Bool, modifiers: UInt8) {
        guard (!pressed || enabled), held.key(code, pressed: pressed, modifiers: modifiers) else { return }
        client.sendKey(code: code, pressed: pressed, modifiers: modifiers)
    }
    func release() {
        retirePencil()
        let releases = held.release()
        for number in releases.buttons { client.setMouseButton(number: number, pressed: false) }
        for (code, modifiers) in releases.keys { client.sendKey(code: code, pressed: false, modifiers: modifiers) }
        surface?.clearContact()
    }
}

struct PlankIPadCanvas: UIViewRepresentable {
    let client: PlankCoreClient
    let router: PlankIPadInputRouter
    func makeUIView(context: Context) -> PlankIPadInputView {
        PlankIPadInputView(client: client, router: router)
    }
    func updateUIView(_ view: PlankIPadInputView, context: Context) {
        view.updateDimensions(client.frameDimensions)
    }
    static func dismantleUIView(_ view: PlankIPadInputView, coordinator: ()) { view.stop() }
}

@MainActor final class PlankIPadInputView: UIView {
    private let client: PlankCoreClient
    private let router: PlankIPadInputRouter
    private let video = PlankIPadVideoView(frame: .zero)
    private let surfaceID = UUID()
    private var dimensions: PlankFrameDimensions?
    private var activeTouch: UITouch?
    private var pointerButtons = Set<UInt8>()
    private var wheel = PlankIPadWheel()
    private var previousBounds = CGRect.zero
    private var registered = false
    override var canBecomeFirstResponder: Bool { true }
    private var viewport: PlankIPadViewport? {
        guard let dimensions else { return nil }
        return PlankIPadViewport(bounds: bounds, width: dimensions.width, height: dimensions.height)
    }
    init(client: PlankCoreClient, router: PlankIPadInputRouter) {
        self.client = client; self.router = router
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        addSubview(video)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        hover.cancelsTouchesInView = false
        addGestureRecognizer(hover)
        let pencilHover = UIHoverGestureRecognizer(target: self, action: #selector(pencilHovered(_:)))
        pencilHover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        pencilHover.cancelsTouchesInView = false
        addGestureRecognizer(pencilHover)
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        scroll.cancelsTouchesInView = false
        addGestureRecognizer(scroll)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop(); return }
        guard !registered else { return }
        router.surface = self
        registered = true
        client.registerVideoSurface(id: surfaceID,
            frame: { [weak self] frame in
                self?.updateDimensions(frame.map { .init(width: $0.width, height: $0.height) })
                self?.video.display(frame)
            }, cursor: { [weak self] cursor in self?.video.displayCursor(cursor) },
            cursorShape: { [weak self] shape in self?.video.displayCursorShape(shape) })
        becomeFirstResponder()
    }
    func updateDimensions(_ next: PlankFrameDimensions?) {
        if next != dimensions { router.release() }
        dimensions = next
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if previousBounds != bounds { router.release(); previousBounds = bounds }
        video.frame = bounds
    }
    func clearContact() { activeTouch = nil; pointerButtons.removeAll(); wheel.reset() }
    func resumeKeyboard() {
        guard window != nil, !isFirstResponder else { return }
        becomeFirstResponder()
    }
    func stop() {
        router.release()
        if registered { client.unregisterVideoSurface(id: surfaceID); registered = false }
        if router.surface === self { router.surface = nil }
    }
    override func resignFirstResponder() -> Bool {
        router.release()
        return super.resignFirstResponder()
    }
    @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed, let viewport else { return }
        _ = router.pointer(gesture.location(in: self), viewport: viewport, dragging: activeTouch != nil)
    }
    @objc private func pencilHovered(_ gesture: UIHoverGestureRecognizer) {
        guard activeTouch == nil, let viewport else { return }
        if gesture.state == .began || gesture.state == .changed {
            guard viewport.normalized(gesture.location(in: self)) != nil else {
                router.retirePencil(); return
            }
            _ = router.pen(.hover, point: gesture.location(in: self), viewport: viewport,
                timestamp: ProcessInfo.processInfo.systemUptime, force: 0, maximumForce: 0,
                altitude: Double(gesture.altitudeAngle), azimuth: Double(gesture.azimuthAngle(in: self)),
                distance: Double(gesture.zOffset))
        } else { router.retirePencil() }
    }
    @objc private func scrolled(_ gesture: UIPanGestureRecognizer) {
        guard router.enabled, !router.pencilTouching, let viewport,
              viewport.map(gesture.location(in: self)) != nil else {
            gesture.setTranslation(.zero, in: self); wheel.reset(); return
        }
        let delta = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        // Keep fractional motion between callbacks rather than throwing small
        // physical-wheel deltas away. Touch drags cannot enter this recognizer.
        let value = wheel.add(x: Double(delta.x), y: Double(delta.y))
        client.scroll(vertical: value.vertical, horizontal: value.horizontal)
        if gesture.state == .cancelled || gesture.state == .failed { wheel.reset() }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first(where: { $0.type == .pencil }), let viewport {
            guard viewport.normalized(touch.location(in: self)) != nil else { return }
            // Clear pointer/key ownership before a real pen contact starts.
            router.release()
            if sendPencil(touch, phase: .down, viewport: viewport) { activeTouch = touch }
            if !isFirstResponder { becomeFirstResponder() }
            return
        }
        guard activeTouch == nil, let viewport,
              let touch = touches.first(where: { $0.type == .direct || $0.type == .indirectPointer }),
              router.pointer(touch.location(in: self), viewport: viewport, dragging: false) else { return }
        activeTouch = touch
        if touch.type == .indirectPointer {
            updatePointerButtons(event?.buttonMask.rawValue ?? 0, fallbackPrimary: true)
        } else { router.button(1, pressed: true) }
        if !isFirstResponder { becomeFirstResponder() }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch), let viewport else { return }
        if touch.type == .pencil {
            // Coalesced actual samples retain acquisition order. Timestamp policy
            // excludes duplicated final samples; predicted/late estimates stay local.
            for sample in (event?.coalescedTouches(for: touch) ?? [touch]).sorted(by: { $0.timestamp < $1.timestamp }) {
                _ = sendPencil(sample, phase: .move, viewport: viewport)
            }
            _ = sendPencil(touch, phase: .move, viewport: viewport)
            return
        }
        _ = router.pointer(touch.location(in: self), viewport: viewport, dragging: true)
        if touch.type == .indirectPointer, let event, !event.buttonMask.isEmpty {
            updatePointerButtons(event.buttonMask.rawValue, fallbackPrimary: false)
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        if touch.type == .pencil {
            if let viewport {
                for sample in (event?.coalescedTouches(for: touch) ?? []).sorted(by: { $0.timestamp < $1.timestamp }) {
                    _ = sendPencil(sample, phase: .move, viewport: viewport)
                }
                _ = sendPencil(touch, phase: .up, viewport: viewport)
            }
            router.retirePencil()
            activeTouch = nil
            return
        }
        if let viewport { _ = router.pointer(touch.location(in: self), viewport: viewport, dragging: true) }
        if touch.type == .indirectPointer { updatePointerButtons(0, fallbackPrimary: false) }
        else { router.button(1, pressed: false) }
        activeTouch = nil
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        router.release()
    }
    @discardableResult
    private func sendPencil(_ touch: UITouch, phase: PlankNormalizedPen.Phase,
                            viewport: PlankIPadViewport) -> Bool {
        router.pen(phase, point: touch.location(in: self), viewport: viewport, timestamp: touch.timestamp,
            force: Double(touch.force), maximumForce: Double(touch.maximumPossibleForce),
            altitude: Double(touch.altitudeAngle), azimuth: Double(touch.azimuthAngle(in: self)))
    }
    private func updatePointerButtons(_ mask: Int, fallbackPrimary: Bool) {
        let raw = mask == 0 && fallbackPrimary ? 1 : mask
        // UIKit primary/secondary/tertiary masks map to the existing wire's
        // left/right/middle numbering (1/3/2), as in the accepted Mac adapter.
        let mapping: [(Int, UInt8)] = [(1, 1), (2, 3), (4, 2)]
        let next = Set(mapping.compactMap { raw & $0.0 != 0 ? $0.1 : nil })
        for button in pointerButtons.subtracting(next).sorted() { router.button(button, pressed: false) }
        for button in next.subtracting(pointerButtons).sorted() { router.button(button, pressed: true) }
        pointerButtons = next
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard router.enabled else { super.pressesBegan(presses, with: event); return }
        for press in presses {
            guard let key = press.key else { continue }
            if let code = plankIPadVirtualKey(for: key.keyCode, functionKeyMode: .appleExtended) {
                router.key(code, pressed: true, modifiers: plankIPadModifiers(for: key.modifierFlags))
            } else if !key.characters.isEmpty { client.sendText(key.characters) }
        }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key,
                  let code = plankIPadVirtualKey(for: key.keyCode, functionKeyMode: .appleExtended) else { continue }
            router.key(code, pressed: false, modifiers: plankIPadModifiers(for: key.modifierFlags))
        }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) { router.release() }
}
