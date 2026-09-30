import SwiftUI

struct AddHostView: View {
    private enum Field: Hashable { case name, address, port, frameRate }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: HostStore
    @ObservedObject var client: PlankCoreClient
    let editingHost: HostBookmark?
    @FocusState private var focusedField: Field?
    @State private var showingRemoveConfirmation = false

    @State private var name = ""
    @State private var address = ""
    @State private var port = "28989"
    @State private var displaySize: SpatialDisplaySize = .standard
    @State private var frameRateSelection = StreamFrameRate.defaultValue
    @State private var customFrameRate = ""

    init(store: HostStore, client: PlankCoreClient, host: HostBookmark? = nil) {
        self.store = store
        self.client = client
        editingHost = host
        _name = State(initialValue: host?.name ?? "")
        _address = State(initialValue: host?.address ?? "")
        _port = State(initialValue: host.map { String($0.port) } ?? "28989")
        _displaySize = State(initialValue: host?.spatialDisplaySize ?? .standard)
        let savedRate = host?.streamFrameRate ?? StreamFrameRate.defaultValue
        _frameRateSelection = State(initialValue:
            StreamFrameRate.presets.contains(savedRate) ? savedRate : 0)
        _customFrameRate = State(initialValue:
            StreamFrameRate.presets.contains(savedRate) ? "" : String(savedRate))
    }

    private var parsedPort: UInt16? { UInt16(port) }
    private var parsedFrameRate: Int? {
        let value = frameRateSelection == 0 ? Int(customFrameRate) : frameRateSelection
        guard let value, (1...240).contains(value) else { return nil }
        return value
    }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        parsedPort.map { $0 > 0 } == true && parsedFrameRate != nil
    }

    private var isSessionActive: Bool {
        if client.isClosingSession { return true }
        switch client.phase {
        case .startingSession, .frameReceived, .streaming:
            return true
        default:
            return false
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Workstation") {
                    TextField("Name", text: $name)
                        .focused($focusedField, equals: .name)
                    TextField("Address or hostname", text: $address)
                        .focused($focusedField, equals: .address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .focused($focusedField, equals: .port)
                        .keyboardType(.numberPad)
                }

                Section("Virtual display") {
                    Picker("Resolution", selection: $displaySize) {
                        ForEach(SpatialDisplaySize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Stream frame rate", selection: $frameRateSelection) {
                        ForEach(StreamFrameRate.presets, id: \.self) { rate in
                            Text("\(rate) fps").tag(rate)
                        }
                        Text("Custom…").tag(0)
                    }
                    .pickerStyle(.menu)
                    if frameRateSelection == 0 {
                        TextField("Custom frame rate (1–240 fps)", text: $customFrameRate)
                            .focused($focusedField, equals: .frameRate)
                            .keyboardType(.numberPad)
                    }
                }

                Section {
                    Text("The default PLANK host port is 28989.")
                        .foregroundStyle(.secondary)
                }

                if editingHost != nil {
                    Section {
                        Button("Remove Workstation", role: .destructive) {
                            showingRemoveConfirmation = true
                        }
                        .disabled(isSessionActive)
                    } footer: {
                        Text("Remove this saved workstation from PLANK.")
                    }
                }
            }
            .navigationTitle(editingHost == nil ? "Add Workstation" : "Edit Workstation")
            .onAppear {
                if editingHost != nil { focusedField = .name }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editingHost == nil ? "Add" : "Save") {
                        guard let parsedPort, let parsedFrameRate else { return }
                        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cleanAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
                        if var edited = editingHost {
                            edited.name = cleanName
                            edited.address = cleanAddress
                            edited.port = parsedPort
                            edited.spatialDisplaySize = displaySize
                            edited.streamFrameRate = parsedFrameRate
                            store.update(edited)
                        } else {
                            store.add(name: cleanName, address: cleanAddress,
                                      port: parsedPort, displaySize: displaySize,
                                      frameRate: parsedFrameRate)
                        }
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .confirmationDialog(
                "Remove Workstation?",
                isPresented: $showingRemoveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove Workstation", role: .destructive) {
                    guard let editingHost, !isSessionActive else { return }
                    store.remove(editingHost)
                    dismiss()
                }
            } message: {
                Text("This removes the saved workstation from PLANK.")
            }
        }
        .frame(minWidth: 540, minHeight: 420)
    }
}
