import SwiftUI

@main struct PlankIPadApp: App {
    @StateObject private var client: PlankCoreClient
    @StateObject private var store = HostStore()
    @StateObject private var router: PlankIPadInputRouter
    init() {
        let client = PlankCoreClient()
        _client = StateObject(wrappedValue: client)
        _router = StateObject(wrappedValue: PlankIPadInputRouter(client: client))
    }
    var body: some Scene {
        WindowGroup { PlankIPadRoot(client: client, store: store, router: router) }
    }
}

struct PlankIPadRoot: View {
    @ObservedObject var client: PlankCoreClient
    @ObservedObject var store: HostStore
    @ObservedObject var router: PlankIPadInputRouter
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedID: UUID?
    @State private var add = false
    @State private var editing: HostBookmark?
    @State private var controls = false
    @State private var username = ""
    @State private var password = ""
    @AppStorage("plank.ipad.showSessionToolbar") private var showToolbar = true
    @AppStorage("plank.ipad.keyboardFunctionKeyMode") private var keyboardMode = KeyboardFunctionKeyMode.pc.rawValue
    private var host: HostBookmark? { store.hosts.first { $0.id == selectedID } }
    private var hideBars: Bool { client.hasActiveDesktopSession && !showToolbar }
    private var busy: Bool {
        switch client.phase { case .probing, .authenticating, .startingSession: true; default: client.isClosingSession }
    }
    var body: some View {
        NavigationStack {
            Group {
                if client.hasActiveDesktopSession {
                    VStack(spacing: 0) {
                        if client.frameDimensions == nil { ProgressView("Starting desktop…").padding() }
                        GeometryReader { geometry in
                            PlankIPadCanvas(client: client, router: router, functionKeyMode: KeyboardFunctionKeyMode(rawValue: keyboardMode) ?? .pc)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .overlay(alignment: .topLeading) {
                                    if client.videoDiagnosticsEnabled {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(client.videoDiagnosticText)
                                            Text(client.audioDiagnosticText)
                                        }.font(.caption2.monospacedDigit()).padding(8)
                                            .background(.black.opacity(0.8)).foregroundStyle(.white)
                                            .allowsHitTesting(false)
                                    }
                                }
                        }
                    }
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                    .ignoresSafeArea(.container, edges: hideBars ? [.top, .bottom] : [])
                    .overlay(alignment: .topTrailing) {
                        if hideBars {
                            Button { setToolbarVisible(true) } label: {
                                Image(systemName: "chevron.down")
                                    .frame(width: 44, height: 44)
                                    .background(.regularMaterial, in: Circle())
                            }
                            .accessibilityLabel("Show session toolbar")
                            .padding(12)
                        }
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            if store.hosts.isEmpty {
                                ContentUnavailableView("Add a workstation", systemImage: "desktopcomputer",
                                    description: Text("Connect to your PLANK desktop."))
                                Button("Add Workstation") { add = true }.buttonStyle(.borderedProminent)
                            } else {
                                Picker("Workstation", selection: $selectedID) {
                                    Text("Choose…").tag(Optional<UUID>.none)
                                    ForEach(store.hosts) { Text($0.name).tag(Optional($0.id)) }
                                }.pickerStyle(.menu).disabled(busy)
                                if let host {
                                    Image(systemName: "desktopcomputer").font(.system(size: 56)).foregroundStyle(.cyan)
                                    Text(host.name).font(.title)
                                    Text("\(host.spatialDisplaySize.title) · \(host.streamFrameRate) fps").foregroundStyle(.secondary)
                                    connection(host)
                                    Button("Edit Workstation") { editing = host }.disabled(busy)
                                }
                            }
                        }.frame(maxWidth: 480).padding(24).frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle(client.hasActiveDesktopSession ? (host?.name ?? "Desktop") : "PLANK iPad Pilot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if client.hasActiveDesktopSession {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { router.setSoftwareKeyboardPresented(!router.softwareKeyboardPresented) } label: {
                            Label(router.softwareKeyboardPresented ? "Hide Keyboard" : "Show Keyboard", systemImage: "keyboard")
                        }
                        Button { controls = true } label: { Label("Session Controls", systemImage: "slider.horizontal.3") }
                        Button { setToolbarVisible(false) } label: { Label("Hide Toolbar", systemImage: "chevron.up") }
                        Button("Disconnect") { disconnect() }.disabled(client.isClosingSession)
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { add = true } label: { Label("Add Workstation", systemImage: "plus") }.disabled(busy)
                    }
                }
            }
            .toolbar(hideBars ? .hidden : .visible, for: .navigationBar)
        }
        // UIKit owns keyboard space for both the viewport and typing preview.
        // Applying this at the navigation root prevents ancestor avoidance from
        // subtracting the keyboard height again (including floating transitions).
        .ignoresSafeArea(.keyboard, edges: client.hasActiveDesktopSession ? .bottom : [])
        .statusBarHidden(hideBars)
        .sheet(isPresented: $add) { PlankIPadBookmarkEditor(store: store, client: client, host: .init(name: "", address: "", spatialDisplaySize: PlankIPadDisplayOptions.defaultSize), isNew: true) }
        .sheet(item: $editing) { host in PlankIPadBookmarkEditor(store: store, client: client, host: host, isNew: false) }
        .sheet(isPresented: $controls) { PlankIPadControls(client: client, router: router) }
        .onAppear { selectedID = store.hosts.first?.id; updateAdmission() }
        .onChange(of: store.hosts) { _, hosts in if selectedID == nil { selectedID = hosts.first?.id } }
        .onChange(of: controls) { _, _ in updateAdmission() }
        .onChange(of: client.phase) { _, _ in updateAdmission() }
        .onChange(of: scenePhase) { _, phase in
            updateAdmission()
            if phase == .background { password = ""; disconnect() }
        }
    }
    @ViewBuilder private func connection(_ host: HostBookmark) -> some View {
        if client.activeHostID == host.id {
            switch client.phase {
            case .needsCredentials, .authenticating:
                TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                SecureField("Password", text: $password).textContentType(.password).onSubmit { authenticate() }
                Button("Sign In") { authenticate() }.buttonStyle(.borderedProminent).disabled(busy || username.isEmpty || password.isEmpty)
            case .authenticated:
                Button("Open Desktop") { start(host) }.buttonStyle(.borderedProminent).disabled(busy)
            case let .failed(message):
                Text(message).foregroundStyle(.orange).textSelection(.enabled)
                Button("Reconnect") { connect(host) }.buttonStyle(.borderedProminent).disabled(busy)
            case .probing: ProgressView("Connecting…")
            default: Button("Connect") { connect(host) }.buttonStyle(.borderedProminent).disabled(busy)
            }
        } else { Button("Connect") { connect(host) }.buttonStyle(.borderedProminent).disabled(busy) }
    }
    private func connect(_ host: HostBookmark) {
        password = ""
        router.enabled = false
        Task { await client.reset()?.value; await client.connect(to: host) }
    }
    private func authenticate() {
        let secret = password; password = ""
        Task { await client.authenticate(username: username, password: secret) }
    }
    private func start(_ host: HostBookmark) {
        client.setTabletActive(scenePhase == .active)
        client.startSession(displaySize: host.spatialDisplaySize, frameRate: host.streamFrameRate,
                            videoBitrateKbps: host.videoBitrateKbps)
        store.markConnected(host)
    }
    private func disconnect() {
        router.enabled = false
        client.setTabletActive(false)
        controls = false
        client.reset()
    }
    private func setToolbarVisible(_ visible: Bool) {
        // A local control changes the canvas bounds. Retire held input before
        // the layout moves, while retaining this stream and its remote mode.
        router.release()
        showToolbar = visible
        Task { @MainActor in
            await Task.yield()
            if router.enabled { router.surface?.resumeKeyboard() }
        }
    }
    private func updateAdmission() {
        let foreground = scenePhase == .active
        let streaming: Bool
        if case .streaming = client.phase { streaming = true } else { streaming = false }
        router.enabled = foreground && streaming && !controls
        client.setTabletActive(foreground && client.hasActiveDesktopSession)
        PlankAudioOutput.shared.setSceneActive(foreground)
    }
}

struct PlankIPadBookmarkEditor: View {
    @ObservedObject var store: HostStore
    @ObservedObject var client: PlankCoreClient
    @Environment(\.dismiss) private var dismiss
    @State var host: HostBookmark
    let isNew: Bool
    @State private var port = "28989"
    @State private var saving = false
    @State private var confirm = false
    private var valid: Bool {
        !host.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !host.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (UInt16(port) ?? 0) > 0
    }
    private var proposedHost: HostBookmark {
        var edited = host
        edited.name = edited.name.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.address = edited.address.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.port = UInt16(port) ?? host.port
        edited.secondDisplaySize = nil
        return edited
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Workstation") {
                    TextField("Name", text: $host.name)
                    TextField("Address or hostname", text: $host.address).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Port", text: $port).keyboardType(.numberPad)
                }
                Section("Display") {
                    Picker("Resolution", selection: $host.spatialDisplaySize) {
                        ForEach(PlankIPadDisplayOptions.choices(current: host.spatialDisplaySize)) {
                            Text(PlankIPadDisplayOptions.title($0)).tag($0)
                        }
                    }
                    Text("Two landscape sizes with the same shape. The desktop keeps its proportions when you rotate the iPad.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("Frame rate", selection: $host.streamFrameRate) {
                        ForEach(StreamFrameRate.presets, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                }
            }.navigationTitle(isNew ? "Add Workstation" : "Edit Workstation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") {
                    if client.requiresSessionCloseForBookmark(proposedHost) { confirm = true } else { save() }
                }.disabled(!valid || saving) }
            }
            .disabled(saving).interactiveDismissDisabled(saving)
            .onAppear { port = String(host.port) }
            .alert("Close the workstation session?", isPresented: $confirm) {
                Button("Cancel", role: .cancel) {}
                Button("Close Session and Save", role: .destructive) { save() }
            } message: { Text("Changing the display requires a fresh sign-in. The current connection will close before saving.") }
        }
    }
    private func save() {
        guard valid, !saving else { return }
        let edited = proposedHost
        saving = true
        Task {
            await client.closeSessionForBookmarkChange(edited)
            if isNew { store.add(name: edited.name, address: edited.address, port: edited.port,
                                displaySize: edited.spatialDisplaySize, frameRate: edited.streamFrameRate) }
            else { store.update(edited) }
            dismiss()
        }
    }
}

struct PlankIPadControls: View {
    @ObservedObject var client: PlankCoreClient
    @ObservedObject var router: PlankIPadInputRouter
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PlankAudioPreferences.volumeKey) private var volume = 1.0
    @AppStorage(PlankAudioPreferences.mutedKey) private var muted = false
    @AppStorage("plank.ipad.keyboardFunctionKeyMode") private var keyboardMode = KeyboardFunctionKeyMode.pc.rawValue
    @State private var bitrate = Double(StreamBitrate.defaultKbps)
    var body: some View {
        NavigationStack {
            Form {
                Section("Audio") {
                    Toggle("Mute", isOn: $muted)
                    Slider(value: $volume, in: 0...1) { Text("Volume") }
                }
                Section("Physical Keyboard") {
                    Picker("Keyboard type", selection: $keyboardMode) {
                        ForEach(KeyboardFunctionKeyMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    Text(keyboardMode == KeyboardFunctionKeyMode.appleExtended.rawValue ?
                         "Apple F13 through F24 are sent as function keys." :
                         "The top-right PC keys act as Print Screen, Scroll Lock and Pause.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Apple Pencil") {
                    Text(client.acceptsNormalizedPen ? "Pencil drawing available" : "Pencil drawing unavailable on this connection")
                    Text("Pressure and tilt come from your Pencil. USB-C Pencil has no pressure sensitivity. Rotate or open controls to end a stroke; lift and start again. Squeeze Pencil Pro while hovering to right-click.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Video") {
                    Text("Bitrate · \(Int(bitrate / 1000)) Mbps")
                    Slider(value: $bitrate, in: Double(StreamBitrate.minimumKbps)...Double(StreamBitrate.maximumKbps),
                           step: Double(StreamBitrate.stepKbps), onEditingChanged: { editing in
                        client.chooseLiveBitrate(Int(bitrate), final: !editing)
                    }) { Text("Bitrate") }.disabled(client.liveBitrate?.supported != true)
                    Toggle("Show statistics", isOn: Binding(get: { client.videoDiagnosticsEnabled }, set: { client.setVideoDiagnosticsEnabled($0) }))
                }
                if client.videoDiagnosticsEnabled {
                    Section("Scroll diagnostics") {
                        Text(router.wheelDiagnostics).monospacedDigit()
                        Text("Counts since this canvas opened. Sent means submitted by PLANK; it does not confirm workstation receipt.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle("Session Controls").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { bitrate = Double(client.liveBitrate?.currentKbps ?? StreamBitrate.defaultKbps) }
            .onChange(of: bitrate) { _, value in client.chooseLiveBitrate(Int(value), final: false) }
            .onChange(of: volume) { _, _ in applyAudio() }
            .onChange(of: muted) { _, _ in applyAudio() }
        }
    }
    private func applyAudio() { PlankAudioOutput.shared.setVolume(Float(volume), muted: muted) }
}
