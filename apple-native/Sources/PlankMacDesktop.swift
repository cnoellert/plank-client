import SwiftUI
struct PlankMacDesktop: View {
    @EnvironmentObject private var client: PlankCoreClient
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var controls = false
    @State private var statistics = false
    @State private var volume = Double(PlankAudioPreferences.volume())
    @State private var muted = PlankAudioPreferences.muted()
    var body: some View {
        ZStack(alignment: .topLeading) {
            PlankMacSurface(client: client)
            if statistics { Text(client.videoDiagnosticText + "\n" + client.audioDiagnosticText).font(.system(.caption, design: .monospaced)).padding(10).background(.black.opacity(0.8)).foregroundStyle(.white).padding().allowsHitTesting(false) }
            if client.showingTabletWaitScreen {
                VStack { ProgressView("Waiting for Wacom…"); Button("Continue without tablet") { client.continueWithoutTablet() } }.padding(24).background(.regularMaterial)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(minWidth: 640, minHeight: 360)
        .toolbar {
            ToolbarItem { Button { controls.toggle() } label: { Label("Session Controls", systemImage: "slider.horizontal.3") }.popover(isPresented: $controls, arrowEdge: .bottom) { sessionControls } }
            ToolbarItem { Button("Disconnect", role: .destructive) { client.disconnectSession(); dismissWindow(id: "desktop") } }
        }
        .onDisappear { client.setTabletActive(false); if client.hasActiveDesktopSession { client.disconnectSession() } }
        .onChange(of: statistics) { _, enabled in client.setVideoDiagnosticsEnabled(enabled) }
        .onChange(of: client.phase) { _, phase in if case .failed = phase { dismissWindow(id: "desktop") } }
    }
    private var sessionControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Session Controls").font(.headline)
            HStack { Button { muted.toggle(); applyAudio() } label: { Image(systemName: muted ? "speaker.slash" : "speaker.wave.2") }; Slider(value: $volume, in: 0...1).onChange(of: volume) { _,_ in applyAudio() } }.accessibilityLabel("Audio volume")
            if let status = client.liveBitrate {
                Text("Bitrate · \(StreamBitrate.megabitsLabel(status.currentKbps))")
                Slider(value: Binding(get: { Double(client.liveBitrate?.currentKbps ?? status.startupKbps) }, set: { client.chooseLiveBitrate(Int($0), final: false) }), in: 10_000...150_000, step: 500) { editing in
                    if !editing { client.chooseLiveBitrate(client.liveBitrate?.currentKbps ?? status.startupKbps, final: true) }
                }.disabled(!status.supported)
                if !status.supported { Text("This Host does not support live bitrate changes.").font(.caption).foregroundStyle(.secondary) }
            }
            Toggle("Show statistics", isOn: $statistics)
            Divider()
            Text(client.tabletPreflightSummary).font(.caption)
            Text("Tablet: \(PlankMacTabletSource.saved.title)").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 340)
    }
    private func applyAudio() {
        UserDefaults.standard.set(volume, forKey: PlankAudioPreferences.volumeKey)
        UserDefaults.standard.set(muted, forKey: PlankAudioPreferences.mutedKey)
        PlankAudioOutput.shared.setVolume(Float(volume), muted: muted)
    }
}
