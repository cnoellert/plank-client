import SwiftUI

@main
struct PlankVisionApp: App {
    @StateObject private var store = HostStore()
    @StateObject private var client = PlankCoreClient()

    init() {
        // Builds before the keyboard-type selector always applied the Apple
        // extended-keyboard convention. Migrate existing installs once so a
        // paired Windows keyboard starts with literal PC key meanings.
        let defaults = UserDefaults.standard
        let migrationKey = "plank.vision.keyboardTypeDefaultVersion"
        if defaults.integer(forKey: migrationKey) < 1 {
            defaults.set(
                KeyboardFunctionKeyMode.pc.rawValue,
                forKey: "plank.vision.keyboardFunctionKeyMode"
            )
            defaults.set(1, forKey: migrationKey)
        }
    }

    var body: some Scene {
        WindowGroup("PLANK", id: "plank-browser") {
            HostBrowserView(store: store, client: client)
        }
        .defaultSize(width: 980, height: 700)

        WindowGroup("PLANK Desktop", id: "plank-desktop") {
            if let hostID = client.activeHostID,
               let host = store.hosts.first(where: { $0.id == hostID }) {
                RemoteDesktopView(host: host, client: client)
            } else {
                RestoredDesktopWindow()
            }
        }
        .defaultSize(width: 1280, height: 720)
        .windowStyle(.plain)
        .restorationBehavior(.disabled)
    }
}

private struct RestoredDesktopWindow: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ContentUnavailableView {
            Label("Session Closed", systemImage: "display.trianglebadge.exclamationmark")
        } description: {
            Text("Return to PLANK to start a new workstation session.")
        } actions: {
            Button("Return to PLANK") { returnToBrowser() }
                .buttonStyle(.borderedProminent)
        }
        .onAppear { returnToBrowser() }
    }

    private func returnToBrowser() {
        openWindow(id: "plank-browser")
        Task { @MainActor in
            // visionOS cannot dismiss the app's last window, so give the
            // browser scene time to open before closing this restored scene.
            try? await Task.sleep(for: .milliseconds(500))
            dismissWindow(id: "plank-desktop")
        }
    }
}
