import SwiftUI

struct PlankMacBrowser: View {
    @EnvironmentObject private var store: HostStore
    @EnvironmentObject private var client: PlankCoreClient
    @Environment(\.openWindow) private var openWindow
    @State private var selection: UUID?
    @State private var editing: HostBookmark?
    @State private var add = false
    @State private var username = ""
    @State private var password = ""
    private var selected: HostBookmark? { store.hosts.first { $0.id == selection } }
    var body: some View {
        NavigationSplitView {
            List(store.hosts, selection: $selection) { host in
                Label(host.name, systemImage: "desktopcomputer").tag(host.id)
                    .contextMenu {
                        Button("Edit Workstation") { editing = host }
                        Button("Remove Bookmark", role: .destructive) { store.remove(host); if selection == host.id { selection = nil } }
                            .disabled(client.activeHostID == host.id)
                    }
            }.navigationTitle("Workstations")
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .toolbar { ToolbarItem(placement: .primaryAction) {
                Button { add = true } label: { Label("Add Workstation", systemImage: "plus") }
                    .help("Add Workstation")
            } }
        } detail: {
            if let host = selected {
                VStack(spacing: 18) {
                    Image(systemName: "desktopcomputer").font(.system(size: 52)).foregroundStyle(.cyan)
                    Text(host.name).font(.title)
                    Text("\(host.spatialDisplaySize.title) · \(host.streamFrameRate) fps").foregroundStyle(.secondary)
                    Text(host.nativeVideoQuality.title).font(.caption).foregroundStyle(.secondary)
                    if client.activeHostID == host.id {
                        switch client.phase {
                        case .needsCredentials, .authenticating:
                            TextField("Username", text: $username)
                            SecureField("Password", text: $password).onSubmit { authenticate() }
                            Button("Sign In") { authenticate() }.disabled(client.phase.isBusy)
                        case .authenticated:
                            Button("Open Desktop") { start(host) }.buttonStyle(.borderedProminent)
                        case .streaming, .frameReceived, .startingSession:
                            Button("Show Desktop") { openWindow(id: "desktop") }
                        case let .failed(message):
                            Text(message).foregroundStyle(.orange).textSelection(.enabled)
                            Button("Reconnect") { Task { await client.reset()?.value; await client.connect(to: host) } }
                        case .probing: ProgressView("Connecting…")
                        case .idle: connect(host)
                        }
                    } else { connect(host) }
                    Button("Edit Workstation") { editing = host }
                }.frame(maxWidth: 420).padding(30)
            } else {
                VStack(spacing: 12) {
                    ContentUnavailableView("Choose a workstation", systemImage: "desktopcomputer", description: Text("Add a workstation to begin. This pilot keeps its own bookmarks."))
                    Button("Add Workstation") { add = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $add) { PlankMacBookmarkEditor(host: HostBookmark(name: "", address: ""), isNew: true) }
        .sheet(item: $editing) { host in PlankMacBookmarkEditor(host: host, isNew: false) }
        .onChange(of: store.hosts) { _, hosts in if selection == nil { selection = hosts.first?.id } }
    }
    private func connect(_ host: HostBookmark) -> some View {
        Button("Connect") { Task { await client.reset()?.value; password = ""; await client.connect(to: host) } }
            .buttonStyle(.borderedProminent).disabled(client.isClosingSession)
    }
    private func authenticate() { Task { await client.authenticate(username: username, password: password); password = "" } }
    private func start(_ host: HostBookmark) {
        client.setTabletActive(true)
        client.startMacSession(bookmark: host)
        store.markConnected(host); openWindow(id: "desktop")
    }
}
extension ConnectionPhase {
    var isBusy: Bool { switch self { case .probing, .authenticating, .startingSession: true; default: false } }
}
struct PlankMacBookmarkEditor: View {
    @EnvironmentObject private var store: HostStore
    @EnvironmentObject private var client: PlankCoreClient
    @Environment(\.dismiss) private var dismiss
    @State var host: HostBookmark
    let isNew: Bool
    @State private var warning = false
    @State private var saving = false
    var body: some View {
        VStack(spacing: 18) {
            Text(isNew ? "Add Workstation" : "Edit Workstation").font(.title2)
            Form {
                TextField("Name", text: $host.name)
                TextField("Address", text: $host.address)
                TextField("Port", value: $host.port, format: .number.grouping(.never))
                Picker("Resolution", selection: $host.spatialDisplaySize) { ForEach(SpatialDisplaySize.allCases) { Text($0.title).tag($0) } }
                Picker("Refresh rate", selection: $host.streamFrameRate) { ForEach(StreamFrameRate.presets, id: \.self) { Text("\($0) fps").tag($0) } }
                Picker("Capture quality", selection: $host.nativeVideoQuality) {
                    if !host.nativeVideoQuality.isSupported {
                        Text("Unsupported saved quality").tag(host.nativeVideoQuality).disabled(true)
                    }
                    ForEach(PlankVideoQuality.choices) { quality in
                        Text(quality.title).tag(quality).disabled(unavailableReason(quality) != nil)
                    }
                }
                Text(host.nativeVideoQuality.detail).font(.caption).foregroundStyle(.secondary)
                if let reason = unavailableReason(host.nativeVideoQuality) {
                    Text(reason).font(.caption).foregroundStyle(.orange)
                } else if client.activeHostID != host.id || client.nativeVideoCapabilities == nil {
                    Text("Host support is checked when connecting.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Capture quality, resolution and refresh rate apply after closing the session and signing in again. Bitrate is adjustable in Session Controls.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { if client.requiresSessionCloseForBookmark(host) { warning = true } else { save() } }
                    .keyboardShortcut(.defaultAction).disabled(saving || host.name.isEmpty || host.address.isEmpty || host.port == 0)
            }
        }.padding(24).frame(width: 560)
        .alert("Close the workstation session?", isPresented: $warning) {
            Button("Close and Save", role: .destructive) { save() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Changing capture quality, resolution, timing or the address requires closing this session and signing in again.") }
    }
    private func unavailableReason(_ quality: PlankVideoQuality) -> String? {
        guard quality.isSupported else { return quality.detail }
        guard client.activeHostID == host.id else { return nil }
        return client.nativeVideoCapabilities?.unavailableReason(for: quality)
    }
    private func save() { saving = true; Task {
        await client.closeSessionForBookmarkChange(host)
        if isNew { store.add(bookmark: host) } else { store.update(host) }
        dismiss()
    } }
}
