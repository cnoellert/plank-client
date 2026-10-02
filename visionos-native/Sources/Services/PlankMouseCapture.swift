import Foundation
import Combine
import CoreGraphics

/// Raw mouse profiles work independently of UIKit pointer lock. Forward only
/// while the desktop owns input; controls and departure release held buttons.
/// The wire remains absolute mouse, without a new Host input mode.
struct PlankMouseCapturePolicy {
    var requested = false
    var systemLocked = false
    var profilesAvailable = false
    var desktopFocused = false
    var controlsPresented = false
    var background = false

    var shouldRequest: Bool {
        requested && desktopFocused && !controlsPresented && !background
    }
    var usesRawInput: Bool { shouldRequest && profilesAvailable }
}

/// Local raw-mouse gain. It never changes pen reports, button edges, scroll,
/// UIKit hover, or the Host's input configuration.
enum PlankMouseSensitivity {
    static let storageKey = "plank.vision.mouseSensitivity"
    static let defaultValue = 1.0
    static let minimum = 0.25
    static let maximum = 1.5

    static func normalized(_ value: Double) -> Double {
        value.isFinite ? min(max(value, minimum), maximum) : defaultValue
    }
}

/// Accumulate physical mouse deltas in canvas points, not system hover space.
/// GCMouse's positive Y is upwards; UIKit canvas Y increases downwards.
struct PlankCapturedMousePosition {
    private(set) var point: CGPoint?

    mutating func reset() { point = nil }

    mutating func anchor(_ location: CGPoint, in bounds: CGRect) {
        guard !bounds.isEmpty, location.x.isFinite, location.y.isFinite else { return }
        point = CGPoint(x: min(bounds.maxX, max(bounds.minX, location.x)),
                        y: min(bounds.maxY, max(bounds.minY, location.y)))
    }

    mutating func move(x: Double, y: Double, in bounds: CGRect, sensitivity: Double = 1) -> CGPoint? {
        guard x.isFinite, y.isFinite, !bounds.isEmpty else { return nil }
        let gain = PlankMouseSensitivity.normalized(sensitivity)
        let scaledX = x * gain, scaledY = y * gain
        guard scaledX.isFinite, scaledY.isFinite else { return nil }
        let previous = point ?? CGPoint(x: bounds.midX, y: bounds.midY)
        anchor(CGPoint(x: previous.x + scaledX, y: previous.y - scaledY), in: bounds)
        return point
    }
}

/// Raw and UIKit callbacks can straddle capture acquisition/cancellation.
/// Forward each down/up at most once and release all buttons on departure.
struct PlankMouseButtons {
    private var held = Set<UInt8>()
    private var source: Int?
    var isHolding: Bool { !held.isEmpty }
    func accepts(source candidate: Int) -> Bool { source == nil || source == candidate }
    mutating func transition(_ button: UInt8, pressed: Bool, source candidate: Int = 0) -> Bool {
        guard (1...3).contains(button) else { return false }
        guard accepts(source: candidate) else { return false }
        if pressed {
            guard held.insert(button).inserted else { return false }
            source = candidate
            return true
        }
        guard held.remove(button) != nil else { return false }
        if held.isEmpty { source = nil }
        return true
    }
    mutating func releaseAll() -> [UInt8] {
        let buttons = held.sorted()
        held.removeAll()
        source = nil
        return buttons
    }
}

/// Desktop lifetime owns raw input availability. Ordinary workstation keys,
/// including Escape, must never disable it. Focus/controls remain separate
/// temporary gates in PlankMouseCapturePolicy.
@MainActor
final class PlankMouseCaptureRequest: ObservableObject {
    @Published private(set) var requested = true
    private var lastReport: String?

    func beginDesktop() {
        requested = true
        NSLog("PLANK raw mouse: desktop appeared; input enabled")
    }
    func endDesktop() {
        requested = false
        NSLog("PLANK raw mouse: desktop disappeared; input ended")
    }
    func report(stateAvailable: Bool, locked: Bool) {
        let value = "requested=\(requested) stateAvailable=\(stateAvailable) locked=\(locked)"
        guard value != lastReport else { return }
        lastReport = value
        NSLog("PLANK mouse capture state: %@", value)
    }
}
