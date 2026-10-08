import Foundation
import CoreGraphics

@main enum Checks {
    static func main() {
        let viewport = PlankIPadViewport(bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), width: 1920, height: 1080)!
        precondition(viewport.rect == CGRect(x: 0, y: 218.75, width: 1000, height: 562.5))
        precondition(viewport.map(CGPoint(x: 500, y: 100)) == nil, "Letterbox must not start a click")
        precondition(viewport.map(CGPoint(x: 0, y: 218.75))!.x == 0)
        precondition(viewport.map(CGPoint(x: 1000, y: 781.25))!.x == 1919)
        precondition(viewport.map(CGPoint(x: 1000, y: 781.25))!.y == 1079)
        let edge = viewport.map(CGPoint(x: 2000, y: -100), held: true)!
        precondition(edge.x == 1919 && edge.y == 0, "Held drags clamp at the video edge")
        precondition(viewport.map(CGPoint(x: CGFloat.nan, y: 10), held: true) == nil)
        precondition(PlankIPadViewport(bounds: .zero, width: 1920, height: 1080) == nil)
        precondition(PlankIPadViewport(bounds: CGRect(x: 0, y: 0, width: 500, height: 500), width: 100000, height: 1080) == nil)
        let portrait = PlankIPadViewport(bounds: CGRect(x: 10, y: 20, width: 500, height: 1000), width: 1000, height: 500)!
        precondition(portrait.map(CGPoint(x: 260, y: 520))!.x == 500)
        precondition(portrait.map(CGPoint(x: 260, y: 520))!.y == 250)
        var held = PlankIPadHeldInput()
        precondition(held.button(1, pressed: true))
        precondition(!held.button(1, pressed: true), "Repeated down must not create two held contacts")
        precondition(held.button(3, pressed: true))
        precondition(held.key(65, pressed: true, modifiers: 1))
        let releases = held.release()
        precondition(releases.buttons == [1, 3] && releases.keys.count == 1)
        precondition(releases.keys[0].0 == 65 && releases.keys[0].1 == 1)
        precondition(held.release().buttons.isEmpty && held.keys.isEmpty)
        precondition(!held.button(1, pressed: false), "Stale up after cancellation must not create contact")
        precondition(!held.key(65, pressed: false, modifiers: 1))
        var wheel = PlankIPadWheel()
        precondition(wheel.add(x: 0, y: 0.25).vertical == 0)
        precondition(wheel.add(x: 0, y: 0.25).vertical == 0)
        precondition(wheel.add(x: 0, y: 0.5).vertical == 1, "Small wheel samples must accumulate")
        precondition(wheel.add(x: -2.5, y: -3).vertical == -3)
        precondition(wheel.add(x: -0.5, y: 0).horizontal == -1)
        precondition(wheel.add(x: .infinity, y: .nan).vertical == 0)
        wheel.reset()
        precondition(wheel.add(x: 0, y: 0.5).vertical == 0)
        print("iPad viewport, held-input and fractional-wheel checks passed")
    }
}
