import SwiftUI

struct SettingsView: View {
    @ObservedObject var client: PlankCoreClient
    @AppStorage("plank.vision.showStatistics") private var showStatistics = false
    @AppStorage("plank.vision.preferHEVC") private var preferHEVC = true
    @AppStorage("plank.vision.keyboardFunctionKeyMode") private var keyboardFunctionKeyMode = KeyboardFunctionKeyMode.pc.rawValue
#if PLANK_TABLET_RELAY
    @StateObject private var tabletRelay = PlankRelayPairing()
#endif

    var body: some View {
        Form {
            Section("Streaming") {
                Toggle("Prefer HEVC", isOn: $preferHEVC)
                Toggle("Show session statistics", isOn: $showStatistics)
            }

            Section("Physical Keyboard") {
                Picker("Keyboard type", selection: $keyboardFunctionKeyMode) {
                    ForEach(KeyboardFunctionKeyMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }

                Text(keyboardFunctionKeyMode == KeyboardFunctionKeyMode.appleExtended.rawValue ?
                     "Apple F13 through F24 are forwarded as literal function keys." :
                     "The top-right Windows keys act as Print Screen, Scroll Lock and Pause.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

#if PLANK_TABLET_RELAY
            Section("Tablet Relay") {
                Picker("Connection", selection: $tabletRelay.connectionKind) {
                    Text("Nearby Wi-Fi").tag("wifi")
                    Text("Nearby Bluetooth").tag("bluetooth")
                    Text("Manual address").tag("manual")
                }
                .onChange(of: tabletRelay.connectionKind) {
                    tabletRelay.refreshPairedState()
                }

                if tabletRelay.connectionKind == "wifi" {
                    Picker("Nearby Relay", selection: $tabletRelay.selectedServiceID) {
                        Text("Select a Relay").tag("")
                        ForEach(tabletRelay.nearbyRelays) { relay in
                            Text(relay.name).tag(relay.id)
                        }
                    }
                    .onChange(of: tabletRelay.selectedServiceID) {
                        tabletRelay.refreshPairedState()
                    }
                    Text("Nearby relays are found automatically. Pairing is saved to the selected Relay.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if tabletRelay.connectionKind == "bluetooth" {
                    Picker("Nearby Relay", selection: $tabletRelay.selectedBluetoothID) {
                        Text("Select a Relay").tag("")
                        if !tabletRelay.selectedBluetoothID.isEmpty &&
                           !tabletRelay.nearbyBluetoothRelays.contains(where: {
                               $0.id.uuidString == tabletRelay.selectedBluetoothID
                           }) {
                            Text("Previously paired Relay (not nearby)")
                                .tag(tabletRelay.selectedBluetoothID)
                        }
                        ForEach(tabletRelay.nearbyBluetoothRelays) { relay in
                            Text(relay.name).tag(relay.id.uuidString)
                        }
                    }
                    .onChange(of: tabletRelay.selectedBluetoothID) {
                        tabletRelay.refreshPairedState()
                    }
                    Text("Bluetooth pairing uses three presses of the Wacom center button. Keep the Relay nearby.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Relay address", text: $tabletRelay.address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: tabletRelay.address) {
                            tabletRelay.refreshPairedState()
                        }
                    TextField("Port", text: $tabletRelay.port)
                        .keyboardType(.numberPad)
                        .onChange(of: tabletRelay.port) {
                            tabletRelay.refreshPairedState()
                        }
                    Text("Use this when a Relay cannot be found automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if tabletRelay.paired {
                    Button("Use Saved Pairing") {
                        if tabletRelay.connectionKind == "manual" {
                            tabletRelay.useManualPairing()
                        } else {
                            tabletRelay.useSavedPairing()
                        }
                    }
                }
                HStack {
                    Button(tabletRelay.paired ? "Re-pair Wacom Relay" : "Pair Wacom Relay") {
                        tabletRelay.beginPairing()
                    }
                        .disabled(tabletRelay.isPairing)
                    if tabletRelay.isPairing {
                        Button("Cancel") { tabletRelay.cancelPairing() }
                    }
                }
                if let code = tabletRelay.code {
                    Text("Press ExpressKeys \(code.map(String.init).joined(separator: " · ")) on the tablet, in order.")
                        .font(.title3)
                }
                Text(tabletRelay.status)
                    .foregroundStyle(tabletRelay.paired ? .green : .secondary)
                if tabletRelay.paired {
                    Text("Pairing is saved. Start a desktop session to connect automatically. Re-pair only after replacing or resetting the Relay.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(client.tabletRelayStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(client.tabletPreflightSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
#endif

            Section("About") {
                LabeledContent("Client", value: "PLANK for Apple Vision Pro")
                LabeledContent("Version", value: "0.1.0")
            }
        }
        .navigationTitle("Settings")
        .frame(minWidth: 560, minHeight: 420)
#if PLANK_TABLET_RELAY
        .onAppear { tabletRelay.startDiscovery() }
        .onDisappear { tabletRelay.stopDiscovery() }
#endif
    }
}
