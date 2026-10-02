// SPDX-License-Identifier: GPL-3.0-or-later
// Focused behavior of desktop focus ownership: PLANK's own session controls
// keep the tablet attached, while leaving the scene still releases and
// suspends exactly as before.
//
// Build/run (failures are counted explicitly, not with assert):
//   swiftc -Onone -parse-as-library Sources/Services/PlankSessionFocus.swift \
//     Tests/PlankSessionFocusTests.swift -o out && ./out
import Foundation

@main
struct PlankSessionFocusTests {
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var failures = 0

    static func check(_ condition: Bool, _ message: String, line: Int = #line) {
        checks += 1
        if !condition { failures += 1; print("FAIL line \(line): \(message)") }
    }

    typealias F = PlankSessionFocus

    static func main() {
        check(F.classify(desktopWindowIsKey: true, sceneHasKeyWindow: true) == .desktop, "desktop key")
        check(F.classify(desktopWindowIsKey: false, sceneHasKeyWindow: true) == .sessionControls,
              "another window of the desktop scene is the session controls")
        check(F.classify(desktopWindowIsKey: false, sceneHasKeyWindow: false) == .away,
              "no key window in the scene is a departure")

        check(F.classify(desktopWindowIsKey: true, sceneHasKeyWindow: true,
                         controlsPresented: true) == .sessionControls,
              "embedded controls retain desktop window ownership")
        check(F.classify(desktopWindowIsKey: false, sceneHasKeyWindow: false,
                         controlsPresented: true) == .away,
              "an open menu cannot override a real departure")

        check(F.classify(desktopWindowIsKey: false, sceneHasKeyWindow: false,
                         registeredControlsAreKey: true) == .sessionControls,
              "registered ornament window belongs to session even outside its scene")
        check(F.classify(desktopWindowIsKey: false, sceneHasKeyWindow: false,
                         controlsPresented: true, registeredControlsAreKey: false) == .away,
              "visible ornament without owned key focus cannot mask departure")

        check(F.classify(desktopWindowIsKey: true, sceneHasKeyWindow: true,
                         controlsPresented: false, registeredControlsAreKey: true) == .desktop,
              "shared ornament window cannot trap closed desktop in controls focus")
        check(F.classify(desktopWindowIsKey: true, sceneHasKeyWindow: true,
                         controlsPresented: true, registeredControlsAreKey: true) == .sessionControls,
              "shared ornament window retains controls focus only while open")

        check(F.shouldReclaimDesktop(controlsPresented: false, sceneActive: true,
                                     background: false, desktopIsKey: false, ownedControlsAreKey: true),
              "explicitly closed controls return their key window to the desktop")
        for (presented, active, background, desktopKey, ownedKey) in [
            (true, true, false, false, true), (false, false, false, false, true),
            (false, true, true, false, true), (false, true, false, true, true),
            (false, true, false, false, false)
        ] {
            check(!F.shouldReclaimDesktop(controlsPresented: presented, sceneActive: active,
                                          background: background, desktopIsKey: desktopKey,
                                          ownedControlsAreKey: ownedKey),
                  "open controls, departure, existing desktop ownership or an external window cannot be reclaimed")
        }

        // Opening and using the controls keeps the tablet; buttons release.
        let open = F.effects(from: .desktop, to: .sessionControls)
        check(open.tabletActive == nil, "opening controls must not suspend the tablet")
        check(open.releaseMouse, "a held mouse button cannot leak into the controls")
        check(!open.reacquireDesktop, "controls keep keyboard focus")

        // Dismissing the controls returns to the desktop without a resume cycle
        // being needed, but re-asserts the attachment idempotently.
        let dismiss = F.effects(from: .sessionControls, to: .desktop)
        check(dismiss.tabletActive == true && dismiss.reacquireDesktop, "dismiss returns to desktop")
        check(!dismiss.releaseMouse, "no release on return")

        // Genuine departures suspend, from the desktop or from the controls.
        let leave = F.effects(from: .desktop, to: .away)
        check(leave.tabletActive == false && leave.releaseMouse, "external focus suspends and releases")
        let leaveFromControls = F.effects(from: .sessionControls, to: .away)
        check(leaveFromControls.tabletActive == false, "leaving from the controls suspends")
        check(!leaveFromControls.releaseMouse, "buttons were already released")
        let back = F.effects(from: .away, to: .desktop)
        check(back.tabletActive == true && back.reacquireDesktop, "returning resumes")

        // Unchanged ownership does nothing.
        for state in [F.desktop, .sessionControls, .away] {
            let none = F.effects(from: state, to: state)
            check(none.tabletActive == nil && !none.releaseMouse && !none.reacquireDesktop,
                  "no effect without a change (\(state))")
        }

        // Only departures wait for confirmation; handoffs inside the scene and
        // returns apply at once.
        check(F.needsConfirmation(from: .desktop, to: .away), "departure is confirmed")
        check(F.needsConfirmation(from: .sessionControls, to: .away), "departure from controls is confirmed")
        check(!F.needsConfirmation(from: .desktop, to: .sessionControls), "controls apply at once")
        check(!F.needsConfirmation(from: .away, to: .desktop), "return applies at once")
        check(F.departureConfirmation > 0 && F.departureConfirmation <= 0.25, "short, bounded confirmation")

        print("PlankSessionFocusTests: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
