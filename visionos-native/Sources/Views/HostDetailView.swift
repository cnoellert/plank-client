import SwiftUI

struct HostDetailView: View {
    let host: HostBookmark
    @ObservedObject var store: HostStore
    @StateObject private var client = PlankCoreClient()

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "display.2")
                .font(.system(size: 64, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.cyan)

            VStack(spacing: 8) {
                Text(host.name)
                    .font(.largeTitle.weight(.semibold))
                Text("\(host.address):\(host.port)")
                    .font(.title3.monospaced())
                    .foregroundStyle(.secondary)
            }

            status

            HStack(spacing: 16) {
                Button(role: .destructive) {
                    store.remove(host)
                } label: {
                    Label("Remove", systemImage: "trash")
                }

                Button {
                    Task {
                        await client.connect(to: host)
                        store.markConnected(host)
                    }
                } label: {
                    Label("Connect", systemImage: "play.fill")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .disabled(client.phase == .preparing)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(host.name)
    }

    @ViewBuilder
    private var status: some View {
        switch client.phase {
        case .idle:
            Text("Ready")
                .foregroundStyle(.secondary)
        case .preparing:
            ProgressView("Preparing connection…")
        case .needsCoreIntegration:
            Label("Native interface ready; streaming connection is next", systemImage: "hammer")
                .foregroundStyle(.orange)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }
}

