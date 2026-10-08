import SwiftUI

/// The one-time drawing approval for a Relay handed over by Relay Setup. It is
/// transient: it exists only while a validated descriptor is pending and is
/// never a permanent Settings control. Authenticated Setup grants a one-time
/// enrollment; PLANK verifies it before saving its own drawing pin.
struct PlankRelayRegistrationSheet: View {
    @ObservedObject var inbox: PlankRelayHandoffInbox
    @ObservedObject var approval: PlankRelayDrawingApproval
    let desktopSessionActive: () -> Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Approve \(inbox.registration.pending?.displayName ?? "Relay") for Drawing")
                .font(.title2.bold())
            Text("Relay Setup handed this Relay to PLANK. Approve it once so PLANK can verify its drawing identity. Existing approvals and your current selection stay unchanged until this succeeds.")
                .foregroundStyle(.secondary)
            Text("Continue in Relay Setup and choose Allow PLANK. PLANK will then verify the drawing connection. No tablet button sequence is needed.")
                .font(.callout)
            if !inbox.enrollmentStatus.isEmpty {
                Text(inbox.enrollmentStatus).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel) { inbox.cancelRegistration(approval) }
                Spacer()
                if inbox.registration.approving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Continue in Relay Setup") {
                        Task {
                            await inbox.requestSetupRegistration { url in
                                await withCheckedContinuation { continuation in
                                    openURL(url) { continuation.resume(returning: $0) }
                                }
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(28)
        .frame(width: 560)
        .interactiveDismissDisabled(inbox.registration.approving)
    }
}
