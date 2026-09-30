import SwiftUI

struct HostBrowserView: View {
    @ObservedObject var store: HostStore
    @ObservedObject var client: PlankCoreClient
    @StateObject private var discovery = HostDiscovery()
    @State private var selection: HostBookmark.ID?
    @State private var showingAddHost = false
    @State private var editingHost: HostBookmark?
    @State private var showingSettings = false

    private var selectedHost: HostBookmark? {
        store.hosts.first { $0.id == selection }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Saved") {
                    if store.hosts.isEmpty {
                        ContentUnavailableView(
                            "No Workstations",
                            systemImage: "desktopcomputer",
                            description: Text("Add a workstation or choose one discovered nearby.")
                        )
                    } else {
                        ForEach(store.hosts) { host in
                            Label(host.name, systemImage: "desktopcomputer")
                                .tag(host.id)
                        }
                    }
                }

                if !discovery.hosts.isEmpty {
                    Section("Nearby") {
                        ForEach(discovery.hosts) { host in
                            Button {
                                store.add(discoveredHost: host)
                                selection = store.hosts.first(where: { $0.name == host.serviceName })?.id
                            } label: {
                                Label(host.serviceName, systemImage: "bonjour")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("PLANK")
            .toolbar {
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddHost = true
                    } label: {
                        Label("Add Workstation", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let selectedHost {
                HostDetailView(host: selectedHost, store: store, client: client) {
                    editingHost = $0
                }
            } else {
                ContentUnavailableView(
                    "Choose a Workstation",
                    systemImage: "visionpro",
                    description: Text("Connect to your PLANK host from a native visionOS window.")
                )
            }
        }
        .sheet(isPresented: $showingAddHost) {
            AddHostView(store: store, client: client)
        }
        .sheet(item: $editingHost) { host in
            AddHostView(store: store, client: client, host: host)
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView(client: client)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingSettings = false }
                        }
                    }
            }
        }
        .task { discovery.start() }
        .onDisappear {
            discovery.stop()
        }
    }
}
