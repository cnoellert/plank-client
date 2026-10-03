import Foundation
import CoreGraphics

// swiftc -Onone -parse-as-library Sources/Services/PlankMouseCapture.swift
//   Tests/PlankMouseCaptureTests.swift -o out && ./out
@main
struct PlankMouseCaptureTests {
    @MainActor
    static func main() {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            count += 1
        }
        let lifetime = PlankMouseCaptureRequest()
        check(lifetime.requested, "new desktop enables mouse without an opt-in button")
        lifetime.endDesktop()
        check(!lifetime.requested, "departed desktop ends raw input")
        lifetime.beginDesktop()
        check(lifetime.requested, "returning desktop automatically restores raw input")
        lifetime.beginDesktop()
        check(lifetime.requested, "repeat appearance preserves raw input")
        lifetime.endDesktop()
        lifetime.endDesktop()
        lifetime.beginDesktop()
        check(lifetime.requested, "repeated departure does not latch mouse off")
        var policy = PlankMouseCapturePolicy()
        check(!policy.shouldRequest && !policy.usesRawInput, "no capture by default")
        policy.requested = true
        policy.desktopFocused = true
        check(policy.shouldRequest && !policy.usesRawInput, "no raw input without a mouse profile")
        policy.profilesAvailable = true
        check(policy.usesRawInput, "mouse profile enables raw without a pointer lock")
        policy.systemLocked = true
        check(policy.usesRawInput, "pointer lock does not change raw eligibility")
        policy.controlsPresented = true
        check(!policy.shouldRequest && !policy.usesRawInput, "controls release capture")
        policy.controlsPresented = false
        policy.background = true
        check(!policy.usesRawInput, "background cannot forward raw input")
        policy.background = false
        policy.desktopFocused = false
        check(!policy.usesRawInput, "another window cannot receive remote raw input")
        policy.desktopFocused = true
        policy.systemLocked = false
        check(policy.usesRawInput, "revoked or denied lock keeps raw input working")
        policy.profilesAvailable = false
        check(!policy.usesRawInput, "mouse removal restores UIKit fallback")
        policy.profilesAvailable = true
        policy.requested = false
        check(!policy.usesRawInput, "desktop departure disables raw independently of pointer lock")

        let bounds = CGRect(x: 10, y: 20, width: 100, height: 50)
        var position = PlankCapturedMousePosition()
        check(position.move(x: 5, y: 3, in: bounds) == CGPoint(x: 65, y: 42), "delta starts at center with inverted Y")
        check(position.move(x: 1000, y: -1000, in: bounds) == CGPoint(x: 110, y: 70), "far corner stays reachable and clamped")
        check(position.move(x: -1000, y: 1000, in: bounds) == CGPoint(x: 10, y: 20), "near corner stays reachable and clamped")
        check(position.move(x: 1, y: -1, in: bounds) == CGPoint(x: 11, y: 21), "can leave clamped corner immediately")
        position.anchor(CGPoint(x: 70, y: 30), in: bounds)
        check(position.move(x: 2, y: -2, in: bounds) == CGPoint(x: 72, y: 32), "pen handoff anchors to latest Host cursor")
        check(position.move(x: .nan, y: 0, in: bounds) == nil, "reject non-finite delta")
        check(position.point == CGPoint(x: 72, y: 32), "invalid delta preserves cursor")
        check(position.move(x: 1, y: 1, in: .zero) == nil, "ignore empty canvas")
        position.reset()
        check(position.point == nil, "release discards old accumulator")

        check(PlankMouseSensitivity.normalized(.nan) == 1, "invalid gain preserves default")
        check(PlankMouseSensitivity.normalized(.infinity) == 1, "infinite gain preserves default")
        check(PlankMouseSensitivity.normalized(0) == 0.25, "gain cannot stop movement")
        check(PlankMouseSensitivity.normalized(9) == 1.5, "gain has a bounded maximum")
        var slower = PlankCapturedMousePosition()
        check(slower.move(x: 8, y: 4, in: bounds, sensitivity: 0.5) == CGPoint(x: 64, y: 43), "half speed scales both axes")
        check(slower.move(x: 8, y: 4, in: bounds, sensitivity: 1.5) == CGPoint(x: 76, y: 37), "live speed change preserves the accumulated position")
        check(slower.move(x: 1000, y: -1000, in: bounds, sensitivity: 0.25) == CGPoint(x: 110, y: 70), "slow speed still reaches the far edges")
        check(slower.move(x: -4, y: 4, in: bounds, sensitivity: 0.25) == CGPoint(x: 109, y: 69), "slow movement can leave an edge")
        slower.anchor(CGPoint(x: 70, y: 30), in: bounds)
        check(slower.move(x: 8, y: -8, in: bounds, sensitivity: 0.5) == CGPoint(x: 74, y: 34), "pen handoff anchor is not scaled")
        var invalidGain = PlankCapturedMousePosition()
        check(invalidGain.move(x: 5, y: 3, in: bounds, sensitivity: .nan) == CGPoint(x: 65, y: 42), "invalid stored gain keeps movement working")

        var buttons = PlankMouseButtons()
        check(buttons.transition(1, pressed: true), "forward primary down")
        check(!buttons.transition(1, pressed: true), "suppress duplicate raw/UIKit down")
        check(buttons.transition(1, pressed: false), "forward matching up")
        check(!buttons.transition(1, pressed: false), "suppress duplicate or unmatched release")
        check(buttons.transition(3, pressed: true) && buttons.transition(2, pressed: true), "right and middle buttons")
        check(buttons.releaseAll() == [2, 3], "departure releases held buttons once")
        check(buttons.releaseAll().isEmpty, "repeat departure has no duplicate release")
        check(!buttons.transition(9, pressed: true), "unsupported button ignored")
        check(buttons.transition(1, pressed: true, source: 3), "an event-producing profile owns the drag")
        check(buttons.isHolding && buttons.accepts(source: 3), "originating profile can move during drag")
        check(!buttons.accepts(source: 1), "another profile cannot steer a held drag")
        check(!buttons.transition(1, pressed: false, source: 1), "another profile cannot release a held drag")
        check(!buttons.transition(3, pressed: true, source: 1), "another profile cannot add a button to the drag")
        check(buttons.transition(3, pressed: true, source: 3), "originating profile can hold two buttons")
        check(buttons.transition(1, pressed: false, source: 3), "originating profile releases its own button")
        check(!buttons.accepts(source: 1), "ownership persists while a second button is held")
        check(buttons.releaseAll() == [3], "departure releases the remaining button")
        check(!buttons.isHolding && buttons.accepts(source: 1), "release frees profile ownership")
        check(!buttons.transition(3, pressed: false, source: 3), "late release after departure is ignored")
        check(buttons.transition(1, pressed: true, source: 1), "return starts with a fresh button down")
        check(buttons.releaseAll() == [1], "second departure remains balanced")
        print("PlankMouseCaptureTests: \(count) checks passed")
    }
}
