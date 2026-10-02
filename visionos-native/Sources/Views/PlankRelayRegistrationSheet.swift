import SwiftUI

/// The one-time drawing approval for a Relay handed over by Relay Setup. It is
/// transient: it exists only while a validated descriptor is pending and is
/// never a permanent Settings control. Setup approval does not imply drawing
/// approval, so the physical ExpressKey confirmation is still required once.
struct PlankRelayRegistrationSheet: View {
    @ObservedObject var inbox: PlankRelayHandoffInbox
    @ObservedObject var approval: PlankRelayDrawingApproval
    let desktopSessionActive: () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Approve \(inbox.registration.pending?.displayName ?? "Relay") for Drawing")
                .font(.title2.bold())
            Text("Relay Setup handed this Relay to PLANK. Approve it once so PLANK can verify its drawing identity. Existing approvals and your current selection stay unchanged until this succeeds.")
                .foregroundStyle(.secondary)
            Text("On the tablet, hold ExpressKeys 1 and 8 for five seconds, then choose Approve and press the keys shown here, in order.")
                .font(.callout)
            if let code = approval.code {
                Text(code.map(String.init).joined(separator: " · "))
                    .font(.largeTitle.monospacedDigit().bold())
                    .accessibilityLabel("ExpressKeys \(code.map(String.init).joined(separator: ", "))")
            }
            if !approval.status.isEmpty {
                Text(approval.status).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel) { inbox.cancelRegistration(approval) }
                Spacer()
                if approval.isApproving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Approve") {
                        Task {
                            await inbox.approvePendingRegistration(
                                with: approval, desktopSessionActive: desktopSessionActive)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(28)
        .frame(width: 560)
        .interactiveDismissDisabled(approval.isApproving)
    }
}
