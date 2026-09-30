import SwiftUI

struct SettingsView: View {
    @ObservedObject var client: PlankCoreClient
    @AppStorage("plank.vision.showStatistics") private var showStatistics = false
    @AppStorage("plank.vision.debugPrefer96Hz") private var debugPrefer96Hz = false
    @AppStorage("plank.vision.preferHEVC") private var preferHEVC = true
    @AppStorage("plank.vision.keyboardFunctionKeyMode") private var keyboardFunctionKeyMode = KeyboardFunctionKeyMode.pc.rawValue
#if PLANK_TABLET_RELAY
    @StateObject private var tabletRelay = PlankRelayPairing()
#endif

    private var desktopSessionActive: Bool {
        switch client.phase {
        case .startingSession, .frameReceived, .streaming: true
        default: false
        }
    }

    var body: some View {
        Form {
            Section("Streaming") {
                Toggle("Prefer HEVC", isOn: $preferHEVC)
            }

            Section("Debug Overlays") {
                Toggle("Show video decoding statistics", isOn: $showStatistics)
                Text("Shows frame counts, the active decoder, and display-link timing in the desktop window.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if showStatistics {
                    Toggle("Request 96 Hz timing for 24/48 fps (test)", isOn: $debugPrefer96Hz)
                    Text("A timing preference for the display link. visionOS may choose another rate; compare the timing readout with this switch off and on.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
                Text(tabletRelay.activeConnectionDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if tabletRelay.paired {
                    Label("Pairing saved", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    Text("PLANK connects to the selected Relay when a desktop session starts. A saved pairing can be selected again without repeating the button sequence.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Picker("Connection setup", selection: $tabletRelay.setupMethod) {
                    Text("Find Nearby").tag(PlankRelaySetupMethod.nearby)
                    Text("Bluetooth").tag(PlankRelaySetupMethod.bluetooth)
                    Text("Manual Address").tag(PlankRelaySetupMethod.manual)
                }
                .pickerStyle(.segmented)
                .onChange(of: tabletRelay.setupMethod) {
                    tabletRelay.refreshPairedState()
                }
                if tabletRelay.setupMethod == .nearby {
                    Picker("Nearby Relay", selection: $tabletRelay.selectedServiceID) {
                        Text("Choose a Relay").tag("")
                        ForEach(tabletRelay.nearbyRelays) { relay in
                            Text(relay.name).tag(relay.id)
                        }
                        if let saved = tabletRelay.savedRelayNotNearby {
                            Text("\(saved.name) (not nearby)")
                                .tag(saved.id)
                                .disabled(true)
                        }
                    }
                    .onChange(of: tabletRelay.selectedServiceID) {
                        tabletRelay.refreshPairedState()
                    }
                    Text(tabletRelay.discoveryStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if tabletRelay.savedRelayNotNearby != nil,
                       !tabletRelay.address.isEmpty {
                        Text("This saved Relay is outside local discovery. PLANK will try its saved address automatically when the desktop starts.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if !tabletRelay.selectedServiceID.isEmpty &&
                        !tabletRelay.selectedConnectionIsActive {
                        Button("Use This Relay") { tabletRelay.useSavedPairing() }
                    }
                } else if tabletRelay.setupMethod == .bluetooth {
                    Picker("Nearby Bluetooth Relay", selection: $tabletRelay.selectedBluetoothID) {
                        Text("Choose a Relay").tag("")
                        ForEach(tabletRelay.nearbyBluetoothRelays) { relay in
                            Text(relay.name).tag(relay.id.uuidString)
                        }
                        if !tabletRelay.selectedBluetoothID.isEmpty &&
                           !tabletRelay.nearbyBluetoothRelays.contains(where: {
                               $0.id.uuidString == tabletRelay.selectedBluetoothID
                           }) {
                            Text("Paired Relay (not nearby)")
                                .tag(tabletRelay.selectedBluetoothID)
                        }
                    }
                    .onChange(of: tabletRelay.selectedBluetoothID) {
                        tabletRelay.refreshPairedState()
                    }
                    Text("Pair by pressing the Wacom center button three times. The Relay must be nearby.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if tabletRelay.paired && !tabletRelay.selectedConnectionIsActive {
                        Button("Use This Relay") { tabletRelay.useSavedPairing() }
                    }
                } else {
                    TextField("Relay address", text: $tabletRelay.address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $tabletRelay.port)
                        .keyboardType(.numberPad)
                    if !tabletRelay.selectedConnectionIsActive {
                        Button("Use Manual Address") { tabletRelay.useManualPairing() }
                    } else {
                        Text("This address will be used for the next desktop session.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if tabletRelay.paired {
                    DisclosureGroup("Replace saved pairing") {
                        pairingControls
                    }
                } else {
                    pairingControls
                }
                if let code = tabletRelay.code {
                    Text("Press ExpressKeys \(code.map(String.init).joined(separator: " · ")) on the tablet, in order.")
                        .font(.title3)
                }
                Text(tabletRelay.status)
                    .foregroundStyle(.secondary)
                Text(desktopSessionActive ? client.tabletRelayStatus :
                     "Tablet link idle; start a desktop session to connect.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if desktopSessionActive {
                    Text(client.tabletPreflightSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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

#if PLANK_TABLET_RELAY
    private var pairingControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tabletRelay.setupMethod == .bluetooth ?
                 "Only replace pairing after resetting or replacing the Relay. Tap Pair, then press the Wacom center button three times." :
                 "Only replace pairing after resetting or replacing the Relay. Hold Wacom ExpressKeys 1 and 8 for five seconds, then tap Pair.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if tabletRelay.setupMethod == .nearby &&
               !tabletRelay.selectedNearbyRelayAvailable {
                Text("This Relay is not discoverable here. Choose Manual Address to replace its pairing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Pair Wacom Relay") { tabletRelay.beginPairing() }
                    .disabled(tabletRelay.isPairing ||
                              (tabletRelay.setupMethod == .nearby &&
                               !tabletRelay.selectedNearbyRelayAvailable) ||
                              (tabletRelay.setupMethod == .bluetooth &&
                               tabletRelay.selectedBluetoothID.isEmpty))
                if tabletRelay.isPairing {
                    Button("Cancel") { tabletRelay.cancelPairing() }
                }
            }
        }
    }
#endif
}
