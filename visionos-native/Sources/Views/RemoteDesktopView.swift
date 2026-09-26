import CoreGraphics
import Foundation
import GameController
import QuartzCore
import SwiftUI
import UIKit

struct RemoteDesktopView: View {
    let host: HostBookmark
    @ObservedObject var client: PlankCoreClient
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("plank.vision.keyboardFunctionKeyMode") private var keyboardFunctionKeyMode = KeyboardFunctionKeyMode.pc.rawValue
    @State private var keyboardFocusGeneration = 0
    @State private var mouseReleaseGeneration = 0
    var body: some View {
        ZStack {
            Color.black

            GeometryReader { proxy in
                ZStack {
                    VideoSurface(client: client)
                    if let frame = client.frameDimensions {
                        RemoteInputSurface(
                            releaseGeneration: mouseReleaseGeneration,
                            onPointer: { location in
                                sendPointer(location, in: proxy.size, frame: frame)
                            },
                            onButton: { number, pressed in
                                requestKeyboardFocus()
                                client.setMouseButton(number: number, pressed: pressed)
                            },
                            onScroll: { vertical, horizontal in
                                requestKeyboardFocus()
                                client.scroll(vertical: vertical, horizontal: horizontal)
                            }
                        )
                    } else {
                        VStack(spacing: 18) {
                            ProgressView()
                            Text("Starting secure stream from \(host.name)…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            KeyboardCapture(
                focusGeneration: keyboardFocusGeneration,
                functionKeyMode: KeyboardFunctionKeyMode(rawValue: keyboardFunctionKeyMode) ?? .pc,
                onCharacters: handleKeyboardCharacters,
                onKeyEvent: { code, pressed, modifiers in
                    client.sendKey(code: code, pressed: pressed, modifiers: modifiers)
                }
            )
            .allowsHitTesting(false)

            WindowGeometryConfigurator(
                pixelWidth: host.spatialDisplaySize.pixelSize.width,
                pixelHeight: host.spatialDisplaySize.pixelSize.height
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .onAppear {
            client.setTabletActive(scenePhase == .active)
            requestKeyboardFocus()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                client.setTabletActive(true)
                requestKeyboardFocus()
            } else {
                client.setTabletActive(false)
                mouseReleaseGeneration &+= 1
            }
        }
        .onChange(of: client.phase) { _, phase in
            if !isSessionActive(phase) {
                dismissWindow(id: "plank-desktop")
            }
        }
    }

    private func isSessionActive(_ phase: ConnectionPhase) -> Bool {
        switch phase {
        case .startingSession, .frameReceived, .streaming:
            return true
        default:
            return false
        }
    }

    private func requestKeyboardFocus() {
        keyboardFocusGeneration &+= 1
    }

    private func sendPointer(
        _ location: CGPoint,
        in availableSize: CGSize,
        frame: PlankFrameDimensions
    ) {
        let scale = min(
            availableSize.width / CGFloat(frame.width),
            availableSize.height / CGFloat(frame.height)
        )
        guard scale > 0 else { return }
        let imageSize = CGSize(
            width: CGFloat(frame.width) * scale,
            height: CGFloat(frame.height) * scale
        )
        let origin = CGPoint(
            x: (availableSize.width - imageSize.width) / 2,
            y: (availableSize.height - imageSize.height) / 2
        )
        let x = Int(((location.x - origin.x) / scale).rounded())
        let y = Int(((location.y - origin.y) / scale).rounded())
        guard x >= 0, y >= 0, x < frame.width, y < frame.height else { return }
        client.movePointer(x: x, y: y, width: frame.width, height: frame.height)
    }

    private func handleKeyboardCharacters(_ characters: String) {
        for character in characters {
            switch character {
            case "\r", "\n":
                client.pressKey(code: 0x0D)
            case "\t":
                client.pressKey(code: 0x09)
            case "\u{8}", "\u{7f}":
                client.pressKey(code: 0x08)
            case "\u{1b}":
                client.pressKey(code: 0x1B)
            default:
                if let key = physicalKey(for: character) {
                    client.pressKey(code: key.code, modifiers: key.shifted ? 0x01 : 0)
                } else {
                    client.sendText(String(character))
                }
            }
        }
    }

    private func physicalKey(for character: Character) -> (code: UInt16, shifted: Bool)? {
        if let ascii = character.asciiValue {
            if ascii >= Character("a").asciiValue!, ascii <= Character("z").asciiValue! {
                return (UInt16(ascii - Character("a").asciiValue! + 0x41), false)
            }
            if ascii >= Character("A").asciiValue!, ascii <= Character("Z").asciiValue! {
                return (UInt16(ascii - Character("A").asciiValue! + 0x41), true)
            }
            if ascii >= Character("0").asciiValue!, ascii <= Character("9").asciiValue! {
                return (UInt16(ascii), false)
            }
        }
        switch character {
        case " ": return (0x20, false)
        case "!": return (0x31, true)
        case "@": return (0x32, true)
        case "#": return (0x33, true)
        case "$": return (0x34, true)
        case "%": return (0x35, true)
        case "^": return (0x36, true)
        case "&": return (0x37, true)
        case "*": return (0x38, true)
        case "(": return (0x39, true)
        case ")": return (0x30, true)
        case ";": return (0xBA, false)
        case ":": return (0xBA, true)
        case "=": return (0xBB, false)
        case "+": return (0xBB, true)
        case ",": return (0xBC, false)
        case "<": return (0xBC, true)
        case "-": return (0xBD, false)
        case "_": return (0xBD, true)
        case ".": return (0xBE, false)
        case ">": return (0xBE, true)
        case "/": return (0xBF, false)
        case "?": return (0xBF, true)
        case "`": return (0xC0, false)
        case "~": return (0xC0, true)
        case "[": return (0xDB, false)
        case "{": return (0xDB, true)
        case "\\": return (0xDC, false)
        case "|": return (0xDC, true)
        case "]": return (0xDD, false)
        case "}": return (0xDD, true)
        case "'": return (0xDE, false)
        case "\"": return (0xDE, true)
        default: return nil
        }
    }

}

private struct VideoSurface: UIViewRepresentable {
    let client: PlankCoreClient

    func makeCoordinator() -> Coordinator { Coordinator(client: client) }

    func makeUIView(context: Context) -> VideoSurfaceView {
        let view = VideoSurfaceView(frame: .zero)
        client.registerVideoSurface(
            id: context.coordinator.id,
            frame: { [weak view] in view?.display($0) },
            cursor: { [weak view] in view?.displayCursor($0) },
            cursorShape: { [weak view] in view?.displayCursorShape($0) }
        )
        return view
    }

    func updateUIView(_ view: VideoSurfaceView, context: Context) {}

    static func dismantleUIView(_ view: VideoSurfaceView, coordinator: Coordinator) {
        coordinator.client.unregisterVideoSurface(id: coordinator.id)
    }

    @MainActor
    final class Coordinator {
        let id = UUID()
        let client: PlankCoreClient

        init(client: PlankCoreClient) { self.client = client }
    }
}

private final class VideoSurfaceView: UIView {
    private var dimensions: PlankFrameDimensions?
    private var cursor: PlankRemoteCursor?
    private var cursorShape: PlankRemoteCursorShape?
    private let cursorLayer = CALayer()
    private let cursorFallback = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        isUserInteractionEnabled = false
        layer.contentsGravity = .resizeAspect
        cursorLayer.contentsGravity = .resize
        cursorLayer.isHidden = true
        layer.addSublayer(cursorLayer)
        cursorFallback.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
        cursorFallback.cornerRadius = 9
        cursorFallback.borderWidth = 2
        cursorFallback.borderColor = UIColor.cyan.cgColor
        cursorFallback.isHidden = true
        layer.addSublayer(cursorFallback)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func display(_ frame: PlankRenderedFrame?) {
        guard let frame,
              let provider = CGDataProvider(data: frame.pixels as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            layer.contents = nil
            dimensions = nil
            cursorLayer.isHidden = true
            cursorFallback.isHidden = true
            return
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        guard let image = CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return }
        dimensions = PlankFrameDimensions(width: frame.width, height: frame.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        layoutCursor()
        CATransaction.commit()
    }

    func displayCursor(_ cursor: PlankRemoteCursor?) {
        self.cursor = cursor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutCursor()
        CATransaction.commit()
    }

    func displayCursorShape(_ shape: PlankRemoteCursorShape?) {
        cursorShape = shape
        cursorLayer.contents = nil
        if let shape,
           let provider = CGDataProvider(data: shape.pixels as CFData),
           let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) {
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            )
            cursorLayer.contents = CGImage(
                width: shape.width,
                height: shape.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: shape.width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutCursor()
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutCursor()
    }

    private func layoutCursor() {
        guard let dimensions, let cursor,
              dimensions.width == cursor.frameWidth,
              dimensions.height == cursor.frameHeight,
              bounds.width > 0, bounds.height > 0 else {
            cursorLayer.isHidden = true
            cursorFallback.isHidden = true
            return
        }
        let scale = min(
            bounds.width / CGFloat(dimensions.width),
            bounds.height / CGFloat(dimensions.height)
        )
        let imageWidth = CGFloat(dimensions.width) * scale
        let imageHeight = CGFloat(dimensions.height) * scale
        let pointer = CGPoint(
            x: (bounds.width - imageWidth) / 2 + CGFloat(cursor.x) * scale,
            y: (bounds.height - imageHeight) / 2 + CGFloat(cursor.y) * scale
        )
        guard let cursorShape else {
            cursorLayer.isHidden = true
            cursorFallback.position = pointer
            cursorFallback.isHidden = false
            return
        }
        cursorFallback.isHidden = true
        guard cursorShape.visible, cursorLayer.contents != nil else {
            cursorLayer.isHidden = true
            return
        }
        cursorLayer.frame = CGRect(
            x: pointer.x - CGFloat(cursorShape.hotspotX) * scale,
            y: pointer.y - CGFloat(cursorShape.hotspotY) * scale,
            width: CGFloat(cursorShape.width) * scale,
            height: CGFloat(cursorShape.height) * scale
        )
        cursorLayer.isHidden = false
    }
}

private struct RemoteInputSurface: UIViewRepresentable {
    let releaseGeneration: Int
    let onPointer: @MainActor (CGPoint) -> Void
    let onButton: @MainActor (UInt8, Bool) -> Void
    let onScroll: @MainActor (Int16, Int16) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onPointer: onPointer,
            onButton: onButton,
            onScroll: onScroll
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isOpaque = false

        let hover = UIHoverGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleHover(_:))
        )
        hover.delegate = context.coordinator
        view.addGestureRecognizer(hover)

        let mousePress = PhysicalMousePressRecognizer()
        mousePress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        mousePress.cancelsTouchesInView = false
        mousePress.delegate = context.coordinator
        mousePress.onPointer = { [weak coordinator = context.coordinator] location in
            coordinator?.onPointer(location)
        }
        mousePress.onButton = { [weak coordinator = context.coordinator] button, pressed in
            coordinator?.onButton(button, pressed)
        }
        view.addGestureRecognizer(mousePress)
        context.coordinator.beginMouseMotionTracking()

        let wheel = WheelCaptureScrollView(frame: .zero)
        wheel.backgroundColor = .clear
        wheel.isOpaque = false
        wheel.showsVerticalScrollIndicator = false
        wheel.showsHorizontalScrollIndicator = false
        wheel.contentInsetAdjustmentBehavior = .never
        wheel.bounces = false
        wheel.panGestureRecognizer.allowedTouchTypes = []
        wheel.panGestureRecognizer.allowedScrollTypesMask = .discrete
        wheel.delegate = context.coordinator
        wheel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wheel)
        NSLayoutConstraint.activate([
            wheel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            wheel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            wheel.topAnchor.constraint(equalTo: view.topAnchor),
            wheel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onPointer = onPointer
        context.coordinator.onButton = onButton
        context.coordinator.onScroll = onScroll
        if context.coordinator.releaseGeneration != releaseGeneration {
            context.coordinator.releaseGeneration = releaseGeneration
            for recognizer in view.gestureRecognizers ?? [] {
                (recognizer as? PhysicalMousePressRecognizer)?.releaseIfNeeded()
            }
        }
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.stopMouseMotionTracking()
        for recognizer in view.gestureRecognizers ?? [] {
            (recognizer as? PhysicalMousePressRecognizer)?.releaseIfNeeded()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate, UIScrollViewDelegate {
        var onPointer: @MainActor (CGPoint) -> Void
        var onButton: @MainActor (UInt8, Bool) -> Void
        var onScroll: @MainActor (Int16, Int16) -> Void
        var releaseGeneration = 0
        private var mouseObservers: [NSObjectProtocol] = []
        private weak var trackedMouse: GCMouse?
        private var sawPhysicalMouseMotion = false
        private var lastPhysicalMouseMotion = 0.0

        init(
            onPointer: @escaping @MainActor (CGPoint) -> Void,
            onButton: @escaping @MainActor (UInt8, Bool) -> Void,
            onScroll: @escaping @MainActor (Int16, Int16) -> Void
        ) {
            self.onPointer = onPointer
            self.onButton = onButton
            self.onScroll = onScroll
        }

        func beginMouseMotionTracking() {
            trackMouse(GCMouse.current)
            let center = NotificationCenter.default
            mouseObservers.append(center.addObserver(
                forName: NSNotification.Name.GCMouseDidBecomeCurrent,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.trackMouse(GCMouse.current)
                }
            })
            mouseObservers.append(center.addObserver(
                forName: NSNotification.Name.GCMouseDidStopBeingCurrent,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.trackMouse(GCMouse.current)
                }
            })
        }

        func stopMouseMotionTracking() {
            if let trackedMouse {
                trackedMouse.mouseInput?.mouseMovedHandler = nil
            }
            trackedMouse = nil
            for observer in mouseObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            mouseObservers.removeAll()
        }

        private func trackMouse(_ mouse: GCMouse?) {
            trackedMouse?.mouseInput?.mouseMovedHandler = nil
            trackedMouse = mouse
            mouse?.mouseInput?.mouseMovedHandler = { [weak self] _, _, _ in
                DispatchQueue.main.async { [weak self] in
                    self?.sawPhysicalMouseMotion = true
                    self?.lastPhysicalMouseMotion = CACurrentMediaTime()
                }
            }
        }

        private static func wheelStepAmount(_ value: CGFloat) -> Int16 {
            guard value.isFinite else { return 0 }
            guard value != 0 else { return 0 }
            let ticks = Int16(min(12, max(1, (abs(value) / 32).rounded())))
            return value > 0 ? ticks * 120 : -ticks * 120
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let wheel = scrollView as? WheelCaptureScrollView,
                  !wheel.isRecentering,
                  wheel.hasWheelGeometry else { return }
            let delta = CGPoint(
                x: scrollView.contentOffset.x - wheel.centerOffset.x,
                y: scrollView.contentOffset.y - wheel.centerOffset.y
            )
            guard delta.x != 0 || delta.y != 0 else { return }
            wheel.recenter()
            let vertical = Self.wheelStepAmount(-delta.y)
            let horizontal = Self.wheelStepAmount(-delta.x)
            if vertical != 0 || horizontal != 0 {
                onScroll(vertical, horizontal)
            }
        }

        @objc func handleHover(_ recognizer: UIHoverGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began, .changed:
                // On visionOS gaze also drives hover. Once a physical mouse has
                // been observed, only hover paired with recent mouse motion may
                // move the remote pointer; merely looking at the window cannot.
                if sawPhysicalMouseMotion &&
                    CACurrentMediaTime() - lastPhysicalMouseMotion > 0.25 {
                    return
                }
                let location = recognizer.location(in: view)
                onPointer(location)
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer is UIHoverGestureRecognizer ||
                otherGestureRecognizer is UIHoverGestureRecognizer
        }
    }
}

// An indirect-pointer touch spans the physical button's down-to-up interval.
// Tap recognizers only fire on release, and pan recognizers wait for movement,
// so neither can faithfully represent a stationary click and hold.
private final class PhysicalMousePressRecognizer: UIGestureRecognizer {
    var onPointer: ((CGPoint) -> Void)?
    var onButton: ((UInt8, Bool) -> Void)?
    private weak var activeTouch: UITouch?
    private var activeButton: UInt8?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard activeTouch == nil,
              let touch = touches.first(where: { $0.type == .indirectPointer }),
              let view else { return }
        let mask = event.buttonMask
        let button: UInt8
        if mask.contains(.button(3)) {
            button = 2 // Moonlight middle
        } else if mask.contains(.secondary) {
            button = 3 // Moonlight right
        } else {
            button = 1
        }
        activeTouch = touch
        activeButton = button
        onPointer?(touch.location(in: view))
        onButton?(button, true)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let activeTouch, touches.contains(activeTouch), let view else { return }
        onPointer?(activeTouch.location(in: view))
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let activeTouch, touches.contains(activeTouch) else { return }
        if let view { onPointer?(activeTouch.location(in: view)) }
        releaseIfNeeded()
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        guard let activeTouch, touches.contains(activeTouch) else { return }
        releaseIfNeeded()
        state = .cancelled
    }

    func releaseIfNeeded() {
        if let activeButton { onButton?(activeButton, false) }
        activeTouch = nil
        activeButton = nil
    }

    override func reset() {
        releaseIfNeeded()
        super.reset()
    }
}

private final class WheelCaptureScrollView: UIScrollView {
    private(set) var isRecentering = false
    private(set) var hasWheelGeometry = false

    var centerOffset: CGPoint {
        CGPoint(x: bounds.width, y: bounds.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let size = CGSize(width: bounds.width * 3, height: bounds.height * 3)
        guard contentSize != size else { return }
        isRecentering = true
        hasWheelGeometry = false
        contentSize = size
        contentOffset = centerOffset
        hasWheelGeometry = true
        isRecentering = false
    }

    func recenter() {
        isRecentering = true
        contentOffset = centerOffset
        isRecentering = false
    }
}

private struct WindowGeometryConfigurator: UIViewRepresentable {
    let pixelWidth: Int
    let pixelHeight: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        applyGeometry(to: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        applyGeometry(to: view, coordinator: context.coordinator)
    }

    private func applyGeometry(to view: UIView, coordinator: Coordinator) {
        guard pixelWidth > 0, pixelHeight > 0 else { return }
        let aspectRatio = CGFloat(pixelWidth) / CGFloat(pixelHeight)
        guard coordinator.appliedAspectRatio != aspectRatio else { return }

        DispatchQueue.main.async {
            guard let scene = view.window?.windowScene else {
                DispatchQueue.main.async {
                    applyGeometry(to: view, coordinator: coordinator)
                }
                return
            }
            let idealWidth: CGFloat = 1280
            let minimumWidth: CGFloat = 640
            let maximumWidth: CGFloat = 2560
            let preferences = UIWindowScene.GeometryPreferences.Vision(
                size: CGSize(width: idealWidth, height: idealWidth / aspectRatio),
                minimumSize: CGSize(width: minimumWidth, height: minimumWidth / aspectRatio),
                maximumSize: CGSize(width: maximumWidth, height: maximumWidth / aspectRatio),
                resizingRestrictions: .uniform
            )
            scene.requestGeometryUpdate(preferences) { error in
                print("PLANK window geometry update failed: \(error.localizedDescription)")
            }
            coordinator.appliedAspectRatio = aspectRatio
        }
    }

    final class Coordinator {
        var appliedAspectRatio: CGFloat?
    }
}

private struct KeyboardCapture: UIViewRepresentable {
    let focusGeneration: Int
    let functionKeyMode: KeyboardFunctionKeyMode
    let onCharacters: @MainActor (String) -> Void
    let onKeyEvent: @MainActor (UInt16, Bool, UInt8) -> Void

    func makeUIView(context: Context) -> KeyboardCaptureView {
        let view = KeyboardCaptureView()
        view.onCharacters = onCharacters
        view.onKeyEvent = onKeyEvent
        view.functionKeyMode = functionKeyMode
        view.focusGeneration = focusGeneration
        return view
    }

    func updateUIView(_ view: KeyboardCaptureView, context: Context) {
        view.onCharacters = onCharacters
        view.onKeyEvent = onKeyEvent
        view.functionKeyMode = functionKeyMode
        guard view.focusGeneration != focusGeneration else { return }
        view.focusGeneration = focusGeneration
        view.requestKeyboardFocus(force: true)
    }
}

@MainActor
private final class KeyboardCaptureView: UIView {
    var onCharacters: (@MainActor (String) -> Void)?
    var onKeyEvent: (@MainActor (UInt16, Bool, UInt8) -> Void)?
    var focusGeneration = 0
    var functionKeyMode: KeyboardFunctionKeyMode = .pc
    private var pressedKeys: [UInt16: UInt8] = [:]

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            releaseAllKeys()
        } else {
            requestKeyboardFocus(force: true)
        }
    }

    func requestKeyboardFocus(force: Bool) {
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if force && self.isFirstResponder {
                _ = self.resignFirstResponder()
            }
            _ = self.becomeFirstResponder()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            if let code = windowsVirtualKey(for: key.keyCode, functionKeyMode: functionKeyMode) {
                let modifiers = plankModifiers(for: key.modifierFlags)
                pressedKeys[code] = modifiers
                onKeyEvent?(code, true, modifiers)
                handled = true
            } else if !key.characters.isEmpty {
                onCharacters?(key.characters)
                handled = true
            }
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key,
                  let code = windowsVirtualKey(
                    for: key.keyCode,
                    functionKeyMode: functionKeyMode
                  ) else { continue }
            let modifiers = plankModifiers(for: key.modifierFlags)
            onKeyEvent?(code, false, modifiers)
            pressedKeys.removeValue(forKey: code)
            handled = true
        }
        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        releaseAllKeys()
        super.pressesCancelled(presses, with: event)
    }

    private func releaseAllKeys() {
        for (code, modifiers) in pressedKeys {
            onKeyEvent?(code, false, modifiers)
        }
        pressedKeys.removeAll(keepingCapacity: true)
    }
}

private func plankModifiers(for flags: UIKeyModifierFlags) -> UInt8 {
    var modifiers: UInt8 = 0
    if flags.contains(.shift) { modifiers |= 0x01 }
    if flags.contains(.control) { modifiers |= 0x02 }
    if flags.contains(.alternate) { modifiers |= 0x04 }
    if flags.contains(.command) { modifiers |= 0x08 }
    return modifiers
}

private func windowsVirtualKey(
    for usage: UIKeyboardHIDUsage,
    functionKeyMode: KeyboardFunctionKeyMode
) -> UInt16? {
    let key = Int(usage.rawValue)
    if functionKeyMode == .pc {
        switch key {
        // visionOS reports these three top-right keys from a Windows keyboard
        // as F13-F15. Restore the meanings printed on the physical keycaps.
        case 0x68: return 0x2C // Print Screen
        case 0x69: return 0x91 // Scroll Lock
        case 0x6A: return 0x13 // Pause
        default: break
        }
    }
    if (0x04...0x1D).contains(key) {
        return UInt16(0x41 + key - 0x04)
    }
    if (0x1E...0x26).contains(key) {
        return UInt16(0x31 + key - 0x1E)
    }
    if key == 0x27 { return 0x30 }
    if (0x3A...0x45).contains(key) {
        return UInt16(0x70 + key - 0x3A)
    }
    if (0x59...0x61).contains(key) {
        return UInt16(0x61 + key - 0x59)
    }
    if key == 0x62 { return 0x60 }
    if (0x68...0x73).contains(key) {
        return UInt16(0x7C + key - 0x68)
    }

    switch key {
    case 0x28, 0x58: return 0x0D // Return and keypad Enter
    case 0x29: return 0x1B
    case 0x2A: return 0x08
    case 0x2B: return 0x09
    case 0x2C: return 0x20
    case 0x2D: return 0xBD
    case 0x2E: return 0xBB
    case 0x2F: return 0xDB
    case 0x30: return 0xDD
    case 0x31, 0x32, 0x64: return 0xDC
    case 0x33: return 0xBA
    case 0x34: return 0xDE
    case 0x35: return 0xC0
    case 0x36: return 0xBC
    case 0x37: return 0xBE
    case 0x38: return 0xBF
    case 0x39: return 0x14
    case 0x46: return 0x2C
    case 0x47: return 0x91
    case 0x48: return 0x13
    case 0x49: return 0x2D
    case 0x4A: return 0x24
    case 0x4B: return 0x21
    case 0x4C: return 0x2E
    case 0x4D: return 0x23
    case 0x4E: return 0x22
    case 0x4F: return 0x27
    case 0x50: return 0x25
    case 0x51: return 0x28
    case 0x52: return 0x26
    case 0x53: return 0x90
    case 0x54: return 0x6F
    case 0x55: return 0x6A
    case 0x56: return 0x6D
    case 0x57: return 0x6B
    case 0x63: return 0x6E
    case 0x65: return 0x5D
    case 0xE0, 0xE4: return 0x11
    case 0xE1, 0xE5: return 0x10
    case 0xE2, 0xE6: return 0x12
    case 0xE3: return 0x5B
    case 0xE7: return 0x5C
    default: return nil
    }
}
