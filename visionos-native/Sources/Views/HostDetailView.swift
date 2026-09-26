import SwiftUI

struct HostDetailView: View {
    let host: HostBookmark
    @ObservedObject var store: HostStore
    @ObservedObject var client: PlankCoreClient
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var username = ""
    @State private var password = ""

    private var displaySize: Binding<SpatialDisplaySize> {
        Binding(
            get: { host.spatialDisplaySize },
            set: { newValue in
                var updated = host
                updated.spatialDisplaySize = newValue
                store.update(updated)
            }
        )
    }

    var body: some View {
        connectionPanel
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(host.name)
    }

    private var connectionPanel: some View {
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

            if canChooseDisplaySize {
                displaySizeControl
            }

            if case .authenticated = client.phase {
                Button {
                    openWindow(id: "plank-desktop")
                    client.startSession(displaySize: host.spatialDisplaySize)
                } label: {
                    Label("Start Session", systemImage: "play.rectangle.fill")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
            }

            if isSessionActive {
                HStack(spacing: 16) {
                    Button {
                        openWindow(id: "plank-desktop")
                    } label: {
                        Label("Open Session", systemImage: "macwindow.on.rectangle")
                    }
                    .buttonStyle(.borderedProminent)

                    Button(role: .destructive) {
                        client.disconnectSession()
                        dismissWindow(id: "plank-desktop")
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle.fill")
                    }
                }
            }

            if case .needsCredentials = client.phase {
                VStack(spacing: 14) {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)

                    Button {
                        let suppliedPassword = password
                        password = ""
                        Task {
                            await client.authenticate(
                                username: username,
                                password: suppliedPassword
                            )
                            if case .authenticated = client.phase {
                                store.markConnected(host)
                            }
                        }
                    } label: {
                        Label("Sign In", systemImage: "person.badge.key.fill")
                            .frame(minWidth: 140)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(username.isEmpty || password.isEmpty)
                }
                .frame(maxWidth: 420)
            } else {
                HStack(spacing: 16) {
                    Button(role: .destructive) {
                        store.remove(host)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }

                    switch client.phase {
                    case .idle:
                        connectButton("Connect", systemImage: "play.fill")
                    case .failed:
                        connectButton("Try Again", systemImage: "arrow.clockwise")
                    default:
                        EmptyView()
                    }
                }
            }
        }
    }

    private var isSessionActive: Bool {
        switch client.phase {
        case .startingSession, .frameReceived, .streaming:
            return true
        default:
            return false
        }
    }

    private var canChooseDisplaySize: Bool {
        switch client.phase {
        case .idle, .needsCredentials, .authenticated, .failed:
            return true
        default:
            return false
        }
    }

    private var displaySizeControl: some View {
        VStack(spacing: 10) {
            Picker("Display", selection: displaySize) {
                ForEach(SpatialDisplaySize.allCases) { size in
                    Text(size.title)
                        .tag(size)
                        .disabled(!size.isAvailable)
                }
            }
            .pickerStyle(.segmented)

            Text(displaySize.wrappedValue == .ultrawide ?
                 "Ultrawide requires the upcoming 5120×1440 Host mode." :
                 "One virtual display · \(displaySize.wrappedValue.virtualMode.replacingOccurrences(of: "x", with: " × "))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 520)
    }

    @ViewBuilder
    private var status: some View {
        switch client.phase {
        case .idle:
            Text("Ready")
                .foregroundStyle(.secondary)
        case .probing:
            ProgressView("Contacting workstation…")
        case let .needsCredentials(identity):
            Label("Connected securely to \(identity.name)", systemImage: "lock.shield.fill")
                .foregroundStyle(.green)
        case let .authenticating(identity):
            ProgressView("Signing in to \(identity.name)…")
        case let .authenticated(identity, authentication):
            VStack(spacing: 8) {
                Label("Signed in to \(identity.name)", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text(authentication.desktopStage == "greeter" ?
                     "The Linux desktop is unlocking. Streaming session startup is next." :
                     "The Host accepted this client. Streaming session startup is next.")
                    .foregroundStyle(.secondary)
            }
        case let .startingSession(identity, _):
            ProgressView("Starting secure stream from \(identity.name)…")
        case let .frameReceived(identity, _, probe):
            VStack(spacing: 8) {
                Label("Live video reached Vision Pro", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(identity.name) sent frame \(probe.frameNumber), \(probe.byteCount.formatted()) bytes")
                Text(probe.negotiationSummary)
                    .foregroundStyle(.secondary)
            }
        case let .streaming(identity, _, frameNumber):
            Label("Live video from \(identity.name) · frame \(frameNumber)", systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func connectButton(_ title: String, systemImage: String) -> some View {
        Button {
            Task { await client.connect(to: host) }
        } label: {
            Label(title, systemImage: systemImage)
                .frame(minWidth: 120)
        }
        .buttonStyle(.borderedProminent)
    }

}
