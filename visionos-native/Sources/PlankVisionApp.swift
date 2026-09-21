import SwiftUI

@main
struct PlankVisionApp: App {
    var body: some Scene {
        WindowGroup {
            HostBrowserView()
        }
        .defaultSize(width: 1100, height: 720)
    }
}
