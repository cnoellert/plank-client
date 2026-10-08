// SPDX-License-Identifier: GPL-3.0-or-later
// Two focused client-state checks requested at integration. Both exercise the
// trust gate against saved client state rather than fixture shape, because the
// shared fixtures deliberately describe descriptors, not PLANK's Keychain.
//
//   1. An unknown drawing identity requires explicit approval. It is never
//      auto-approved, never connected, and the requestID is not consumed, so
//      the user can approve and retry the same link.
//   2. A conflicting stored pin is refused and the stored pin is NOT
//      overwritten or removed.
//
// Build/run (assertions live; precondition survives -O):
//   swiftc -Onone -DPLANK_TABLET_RELAY -parse-as-library \
//     Sources/Models/PlankDrawingHandoff.swift \
//     Sources/Services/PlankDrawingIdentityStore.swift \
//     Tests/PlankDrawingTrustStateTests.swift -o out && out
import Foundation

@main
enum PlankDrawingTrustStateTests {
    static let known = "b4805f947954ddad8645c4a87d1bead9bcd2aceb3cacfa133dcdf10f1048191c"
    static let other = "6f830f05473e3b6d4654cce8a68af4a0d9c1f01e4701529d5f94eb4532f86b07"

    static func descriptor(identity: String, requestID: String) -> PlankDrawingHandoffDescriptor {
        PlankDrawingHandoffDescriptor(
            version: 1,
            requestID: requestID,
            displayName: "Studio Relay",
            managementIdentity: "c9a2bb1573de33196112f273d0f046d78093f41103b64f17ffcc3d2c3c054f0c",
            drawingIdentity: identity,
            routes: [PlankDrawingRoute(address: "192.0.2.10", port: 28990, interface: "eth0", kind: .wired)]
        )
    }

    static func main() {
        // ---- positive control: an approved identity really does proceed, so a
        // "refused" result below cannot pass merely because nothing works.
        var gate = PlankDrawingHandoffGate()
        let approved = PlankDrawingTrustEnvironment(approvedDrawingIdentities: [known])
        let ok = gate.evaluate(descriptor(identity: known, requestID: "11111111-1111-4111-8111-111111111111"),
                               environment: approved)
        precondition(ok.outcomeIdentifier == "handoffReady", "positive control: approved identity must proceed")
        guard case .verifyThenConnect(let selection) = ok else { preconditionFailure("expected a route selection") }
        precondition(selection.drawingIdentity == known)
        precondition(gate.hasAccepted("11111111-1111-4111-8111-111111111111"),
                     "an accepted handoff consumes its requestID")

        // ---- check 1: an unknown identity requires explicit approval.
        var unknownGate = PlankDrawingHandoffGate()
        let empty = PlankDrawingTrustEnvironment()   // no approvals of any kind
        let request = "22222222-2222-4222-8222-222222222222"
        let unknown = unknownGate.evaluate(descriptor(identity: known, requestID: request), environment: empty)
        precondition(unknown.outcomeIdentifier == "trust.unknownDrawingIdentity",
                     "an unknown identity must route to explicit approval, got \(unknown.outcomeIdentifier)")
        guard case .needsExplicitApproval(let pending) = unknown else { preconditionFailure("expected approval") }
        precondition(pending == known)
        // Never silently approved by the link.
        precondition(!empty.approvedDrawingIdentities.contains(known),
                     "an app link must not create an approval")
        precondition(empty == PlankDrawingTrustEnvironment(), "client state must be untouched")
        // The requestID stays unconsumed so approving and retrying still works.
        precondition(!unknownGate.hasAccepted(request),
                     "a declined handoff must not consume its requestID")
        precondition(unknownGate.recentRequestIDCount == 0)

        // ---- check 2: a conflicting stored pin is refused, not overwritten.
        var conflictGate = PlankDrawingHandoffGate()
        let stored = PlankDrawingTrustEnvironment(
            approvedDrawingIdentities: [other],
            routeApprovals: ["192.0.2.10:28990": other]
        )
        let before = stored
        let conflictRequest = "33333333-3333-4333-8333-333333333333"
        let conflict = conflictGate.evaluate(
            descriptor(identity: known, requestID: conflictRequest), environment: stored
        )
        precondition(conflict.outcomeIdentifier == "trust.drawingIdentityMismatch",
                     "a different identity on an approved route must be refused, got \(conflict.outcomeIdentifier)")
        guard case .drawingIdentityMismatch(let saved, let received) = conflict else {
            preconditionFailure("expected a mismatch")
        }
        precondition(saved == other && received == known, "the refusal must name both identities")
        // The stored pin survives byte-for-byte: not replaced, not removed.
        precondition(stored == before, "a refused handoff must not modify client state")
        precondition(stored.routeApprovals["192.0.2.10:28990"] == other,
                     "the stored pin must not be overwritten by the arriving identity")
        precondition(stored.approvedDrawingIdentities == [other],
                     "the arriving identity must not be added to the approved set")
        precondition(!conflictGate.hasAccepted(conflictRequest),
                     "a refused handoff must not consume its requestID")

        print("PlankDrawingTrustStateTests: unknown identity needs approval; conflicting pin refused and preserved")
    }
}
