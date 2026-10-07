import AppKit

/// Session focus is the union of its windows. A secondary surface never starts,
/// stops or duplicates the session's raw Wacom worker.
@MainActor enum PlankMacSessionWindows {
    private final class WindowRef {
        weak var window: NSWindow?
        weak var view: PlankMacInputView?
        init(_ window: NSWindow, view: PlankMacInputView?) { self.window = window; self.view = view }
    }
    private final class Session {
        weak var client: PlankCoreClient?
        var windows: [UUID: WindowRef] = [:]
        var active: Bool?
        init(_ client: PlankCoreClient) { self.client = client }
    }
    private static var sessions: [ObjectIdentifier: Session] = [:]
    static func attach(client: PlankCoreClient, surface: UUID, window: NSWindow?, view: PlankMacInputView? = nil) {
        let id = ObjectIdentifier(client)
        let session = sessions[id] ?? Session(client)
        sessions[id] = session
        if let window { session.windows[surface] = WindowRef(window, view: view) }
        else { session.windows.removeValue(forKey: surface) }
        refresh(client: client)
    }
    static func owns(client: PlankCoreClient, window: NSWindow?) -> Bool {
        guard let window, let session = sessions[ObjectIdentifier(client)] else { return false }
        return session.windows.values.contains { $0.window === window }
    }
    static func remotePointer(client: PlankCoreClient, screenPoint: CGPoint) -> (Int, Int, Int, Int)? {
        guard let session = sessions[ObjectIdentifier(client)] else { return nil }
        for entry in session.windows.values {
            if let result = entry.view?.remotePointer(at: screenPoint) { return result }
        }
        return nil
    }
    static func refresh(client: PlankCoreClient) {
        // Key-window notifications for a transfer arrive in a pair. Evaluate
        // after the transfer, so Wacom never sees a false focus gap.
        DispatchQueue.main.async {
            let id = ObjectIdentifier(client)
            guard let session = sessions[id] else { return }
            let active = PlankMacSessionFocus.active(appActive: NSApp.isActive,
                windows: session.windows.values.map {
                    .init(key: $0.window?.isKeyWindow == true, main: $0.window?.isMainWindow == true)
                })
            if session.active != active { session.active = active; client.setTabletActive(active) }
            if session.windows.isEmpty { sessions.removeValue(forKey: id) }
        }
    }
}
