import AppKit

// Keep SwiftUI's window delegate in the chain. Only the desktop's full-screen
// presentation options are changed; normal window lifecycle stays with it.
@MainActor final class PlankMacWindowPresentation: NSObject, NSWindowDelegate, NSUserInterfaceValidations {
    private weak var window: NSWindow?
    private var transitioning = false
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
        PlankMacDesktopWindow.configure(window)
    }
    func remove() {
        if let window, window.delegate === self {
            window.delegate = previous
            PlankMacDesktopWindow.configure(window)
        }
    }
    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || previous?.responds(to: selector) == true
    }
    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        if previous?.responds(to: selector) == true { return previous }
        return super.forwardingTarget(for: selector)
    }
    @objc func toggleDesktopFullScreen(_ sender: Any?) {
        guard !transitioning else { return }
        window?.toggleFullScreen(sender)
    }
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleDesktopFullScreen(_:)) { return !transitioning }
        return (previous as? any NSUserInterfaceValidations)?.validateUserInterfaceItem(item) ?? true
    }
    func windowWillEnterFullScreen(_ notification: Notification) {
        transitioning = true; previous?.windowWillEnterFullScreen?(notification)
    }
    func windowWillExitFullScreen(_ notification: Notification) {
        transitioning = true; previous?.windowWillExitFullScreen?(notification)
    }
    private func repairFullScreenButton() {
        // AppKit/SwiftUI can revalidate controls after the did-change callback.
        // Rebind on the next UI turn using our reversible fullscreen action.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window, window.delegate === self else { return }
            PlankMacDesktopWindow.configure(window)
        }
    }
    func windowDidEnterFullScreen(_ notification: Notification) {
        transitioning = false
        previous?.windowDidEnterFullScreen?(notification)
        repairFullScreenButton()
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        transitioning = false
        previous?.windowDidExitFullScreen?(notification)
        repairFullScreenButton()
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        transitioning = false; previous?.windowDidFailToEnterFullScreen?(window); repairFullScreenButton()
    }
    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        transitioning = false; previous?.windowDidFailToExitFullScreen?(window); repairFullScreenButton()
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
