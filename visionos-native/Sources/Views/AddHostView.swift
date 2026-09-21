import SwiftUI

struct AddHostView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: HostStore

    @State private var name = ""
    @State private var address = ""
    @State private var port = "47989"

    private var parsedPort: UInt16? { UInt16(port) }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        parsedPort != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Workstation") {
                    TextField("Name", text: $name)
                    TextField("Address or hostname", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                }

                Section {
                    Text("The default PLANK host port is 47989.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Workstation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let parsedPort else { return }
                        store.add(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            address: address.trimmingCharacters(in: .whitespacesAndNewlines),
                            port: parsedPort
                        )
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .frame(minWidth: 540, minHeight: 420)
    }
}

