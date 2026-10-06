import SwiftUI
import AppKit
struct PlankMacDesktop: View {
    @EnvironmentObject private var client: PlankCoreClient
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var controls = false
    @State private var statistics = false
    @State private var volume = Double(PlankAudioPreferences.volume())
    @State private var muted = PlankAudioPreferences.muted()
    @State private var desktopWindow: NSWindow?
    var body: some View {
        ZStack(alignment: .topLeading) {
            PlankMacSurface(client: client, windowChanged: { if let window = $0 { desktopWindow = window } },
                            localControlsPresented: controls || client.showingTabletWaitScreen)
            if statistics { Text(client.videoDiagnosticText + "\n" + client.audioDiagnosticText).font(.system(.caption, design: .monospaced)).padding(10).background(.black.opacity(0.8)).foregroundStyle(.white).padding().allowsHitTesting(false) }
            if client.showingTabletWaitScreen {
                VStack { ProgressView("Waiting for Wacom…"); Button("Continue without tablet") { client.continueWithoutTablet() } }.padding(24).background(.regularMaterial)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(minWidth: 640, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
        .toolbar {
            ToolbarItem { Button {
                if let desktopWindow { PlankMacDesktopWindow.toggle(desktopWindow) }
                else { NSLog("PLANK Mac fullscreen: toolbar has no desktop window") }
            } label: { Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") }
                .onHover { if $0 { NSCursor.arrow.set() } }
                .background(PlankMacLocalPointerRegion())
                .help("Enter or leave full screen").keyboardShortcut("f", modifiers: [.control, .command]) }
            ToolbarItem { Button { controls.toggle() } label: { Label("Session Controls", systemImage: "slider.horizontal.3") }
                .onHover { if $0 { NSCursor.arrow.set() } }
                .background(PlankMacLocalPointerRegion())
                .popover(isPresented: $controls, arrowEdge: .bottom) { sessionControls } }
            ToolbarItem { Button("Disconnect", role: .destructive) { client.disconnectSession(); dismissWindow(id: "desktop") }
                .onHover { if $0 { NSCursor.arrow.set() } }
                .background(PlankMacLocalPointerRegion()) }
        }
        .onDisappear { client.setTabletActive(false); if client.hasActiveDesktopSession { client.disconnectSession() } }
        .onChange(of: statistics) { _, enabled in client.setVideoDiagnosticsEnabled(enabled) }
        .onChange(of: client.phase) { _, phase in if case .failed = phase { dismissWindow(id: "desktop") } }
    }
    private var sessionControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Session Controls").font(.headline)
            HStack { Button { muted.toggle(); applyAudio() } label: { Image(systemName: muted ? "speaker.slash" : "speaker.wave.2") }; PlankMacSlider(value: $volume, range: 0...1, label: "Audio volume").frame(height: 24).onChange(of: volume) { _,_ in applyAudio() } }.accessibilityLabel("Audio volume")
            if let status = client.liveBitrate {
                Text("Bitrate · \(StreamBitrate.megabitsLabel(status.currentKbps))")
                PlankMacSlider(value: Binding(get: { Double(client.liveBitrate?.currentKbps ?? status.startupKbps) }, set: { client.chooseLiveBitrate(Int($0), final: false) }), range: 10_000...150_000, step: 500, label: "Video bitrate") { editing in
                    if !editing { client.chooseLiveBitrate(client.liveBitrate?.currentKbps ?? status.startupKbps, final: true) }
                }.frame(height: 24).disabled(!status.supported)
                if !status.supported { Text("This Host does not support live bitrate changes.").font(.caption).foregroundStyle(.secondary) }
            }
            Toggle("Show statistics", isOn: $statistics)
            Divider()
            Text(client.nativeVideoQuality.title).font(.caption)
            Text("HEVC 10-bit · 4:4:4 · identity").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text(client.tabletPreflightSummary).font(.caption)
            Text("Tablet: \(PlankMacTabletSource.saved.title)").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 340)
            .background(PlankMacLocalPointerRegion())
            .onAppear { NSCursor.arrow.set() }
    }
    private func applyAudio() {
        UserDefaults.standard.set(volume, forKey: PlankAudioPreferences.volumeKey)
        UserDefaults.standard.set(muted, forKey: PlankAudioPreferences.mutedKey)
        PlankAudioOutput.shared.setVolume(Float(volume), muted: muted)
    }
}
