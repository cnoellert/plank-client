import Foundation

/// Who holds input focus relative to the desktop session window. Session
/// controls register their window with the desktop session; using them must
/// not suspend the tablet. Anything else is a
/// genuine departure: another app, Mac Virtual Display, another PLANK window,
/// or no key window at all.
enum PlankSessionFocus: Equatable, Sendable {
    case desktop
    case sessionControls
    case away

    static func classify(desktopWindowIsKey: Bool, sceneHasKeyWindow: Bool,
                         controlsPresented: Bool = false,
                         registeredControlsAreKey: Bool = false) -> Self {
        // A registered ornament may share the desktop's UIKit window. The
        // desktop's own key status wins unless its controls are actually open.
        if desktopWindowIsKey { return controlsPresented ? .sessionControls : .desktop }
        if registeredControlsAreKey { return .sessionControls }
        return sceneHasKeyWindow ? .sessionControls : .away
    }

    /// Called only after this session's controls are explicitly closed.
    /// A background or external-window departure must never reclaim focus.
    static func shouldReclaimDesktop(controlsPresented: Bool, sceneActive: Bool,
                                     background: Bool, desktopIsKey: Bool,
                                     ownedControlsAreKey: Bool) -> Bool {
        !controlsPresented && sceneActive && !background && !desktopIsKey && ownedControlsAreKey
    }

    /// What a transition must do. Mouse buttons are released whenever the
    /// desktop loses focus, so a press cannot outlive it; only a genuine
    /// departure suspends the tablet.
    struct Effects: Equatable, Sendable {
        var tabletActive: Bool?
        var releaseMouse: Bool
        var reacquireDesktop: Bool
    }

    static func effects(from old: Self, to new: Self) -> Effects {
        guard old != new else {
            return Effects(tabletActive: nil, releaseMouse: false, reacquireDesktop: false)
        }
        switch new {
        case .desktop:
            return Effects(tabletActive: true, releaseMouse: false, reacquireDesktop: true)
        case .sessionControls:
            return Effects(tabletActive: nil, releaseMouse: old == .desktop, reacquireDesktop: false)
        case .away:
            return Effects(tabletActive: false, releaseMouse: old == .desktop, reacquireDesktop: false)
        }
    }

    /// A departure is only acted on once it is still true after this delay,
    /// so the resign/become pair of a focus handoff inside the scene never
    /// suspends the tablet. Returning focus is applied immediately.
    static let departureConfirmation: TimeInterval = 0.1

    static func needsConfirmation(from old: Self, to new: Self) -> Bool {
        new == .away && old != .away
    }
}
