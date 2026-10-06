import AppKit

// Keep SwiftUI's window delegate in the chain. Only the desktop's full-screen
// presentation options are changed; normal window lifecycle stays with it.
@MainActor final class PlankMacWindowPresentation: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    // Objective-C may probe optional delegate selectors outside the UI actor.
    // This weak reference is only changed by install/remove on the main actor.
    nonisolated(unsafe) private weak var previous: (any NSWindowDelegate)?

    init(window: NSWindow) {
        self.window = window
        super.init()
        install()
    }
    func install() {
        guard let window, window.delegate !== self else { return }
        previous = window.delegate
        window.delegate = self
    }
    func remove() {
        if let window, window.delegate === self { window.delegate = previous }
    }
    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || previous?.responds(to: selector) == true
    }
    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        if previous?.responds(to: selector) == true { return previous }
        return super.forwardingTarget(for: selector)
    }
    func windowDidEnterFullScreen(_ notification: Notification) {
        previous?.windowDidEnterFullScreen?(notification)
        if let window { PlankMacDesktopWindow.configure(window) }
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        previous?.windowDidExitFullScreen?(notification)
        if let window { PlankMacDesktopWindow.configure(window) }
    }
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposed: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        var options = previous?.window?(window, willUseFullScreenPresentationOptions: proposed) ?? proposed
        // AppKit requires auto-hidden menu bars to be paired with a hidden or
        // auto-hidden Dock. Auto-hide toolbar also requires fullScreen.
        options.remove([.hideMenuBar, .hideDock])
        options.formUnion([.fullScreen, .autoHideMenuBar, .autoHideDock, .autoHideToolbar])
        return options
    }
}
