// SPDX-License-Identifier: GPL-3.0-or-later
// Focused behavior of the Tablet Relay picker boundary: registration upsert,
// Off, deferred selection, first-time approval completion and cancellation,
// migration, persistence and status labels derived from observed state.
// Trust-gate and malformed-link coverage stays in the existing suites.
//
// Build/run (assertions live; precondition survives -O):
//   swiftc -Onone -DPLANK_TABLET_RELAY -parse-as-library \
//     Sources/Models/PlankDrawingHandoff.swift \
//     Sources/Services/PlankDrawingIdentityStore.swift \
//     Sources/Models/PlankRelayRegistry.swift \
//     Tests/PlankRelayPickerTests.swift -o out && out
import Foundation

@main
enum PlankRelayPickerTests {
    static let studio = "b4805f947954ddad8645c4a87d1bead9bcd2aceb3cacfa133dcdf10f1048191c"
    static let other = "6f830f05473e3b6d4654cce8a68af4a0d9c1f01e4701529d5f94eb4532f86b07"
    static var checks = 0

    static func check(_ condition: Bool, _ message: String, line: Int = #line) {
        checks += 1
        precondition(condition, "line \(line): \(message)")
    }

    static func route(_ address: String, _ port: UInt16 = 28990) -> PlankDrawingRoute {
        PlankDrawingRoute(address: address, port: port, interface: "eth0", kind: .wired)
    }

    static func selection(_ identity: String, _ name: String,
                          _ routes: [PlankDrawingRoute]) -> PlankDrawingRouteSelection {
        PlankDrawingRouteSelection(drawingIdentity: identity, displayName: name, routes: routes)
    }

    static func descriptor(_ identity: String, request: String) -> PlankDrawingHandoffDescriptor {
        PlankDrawingHandoffDescriptor(
            version: 1, requestID: request, displayName: "Studio Relay",
            managementIdentity: "c9a2bb1573de33196112f273d0f046d78093f41103b64f17ffcc3d2c3c054f0c",
            drawingIdentity: identity, routes: [route("192.0.2.10")])
    }

    static func main() {
        registrationUpsertsWithoutDuplicates()
        offKeepsRelaysAndSelectsNothing()
        selectionIsDeferredDuringASession()
        firstTimeApprovalCompletesOrCancelsSafely()
        migrationAdoptsWithoutGuessing()
        persistenceRoundTripsAndRejectsMalformedEntries()
        statusLabelsFollowObservedState()
        linkStatusFollowsDropsAndReconnects()
        lateApprovalAfterCancelIsDiscarded()
        earlierPairingIsTransitional()
        print("PlankRelayPickerTests: \(checks) checks passed")
    }

    static func registrationUpsertsWithoutDuplicates() {
        var registry = PlankRelayRegistry()
        registry.register(selection(studio, "Studio Relay", [route("192.0.2.10")]))
        check(registry.request(.relay(studio), desktopSessionActive: false) == .applied, "select")
        // A repeated handoff with new routes updates the one entry.
        registry.register(selection(studio, "Studio Relay", [route("192.0.2.44"), route("198.51.100.7")]))
        check(registry.relays.count == 1, "repeat handoff must not duplicate")
        check(registry.activeRouteSelection?.routes.map(\.address) == ["192.0.2.44", "198.51.100.7"],
              "routes updated in place")
        check(registry.request(.relay(studio), desktopSessionActive: false) == .unchanged, "idempotent")
        // Distinct identities with the same name stay distinct and readable.
        registry.register(selection(other, "Studio Relay", [route("192.0.2.99")]))
        check(registry.relays.count == 2, "distinct identity is a second entry")
        check(registry.displayName(for: studio) == "Studio Relay", "first keeps its name")
        check(registry.displayName(for: other) == "Studio Relay (2)", "second is disambiguated")
        check(registry.displayName(for: other)?.contains(other.prefix(8)) == false, "no key in UI name")
        // Non-canonical identities and routeless entries are never registered.
        registry.register(selection("not-an-identity", "Bad", [route("192.0.2.1")]))
        registry.register(selection(String(repeating: "a", count: 64), "Empty", []))
        check(registry.relays.count == 2, "invalid registrations ignored")
        check(registry.request(.relay(String(repeating: "c", count: 64)),
                               desktopSessionActive: false) == .unknownRelay, "unknown refused")
        check(registry.selection == .relay(studio), "refusal leaves selection")
    }

    static func offKeepsRelaysAndSelectsNothing() {
        var registry = PlankRelayRegistry()
        registry.register(selection(studio, "Studio Relay", [route("192.0.2.10")]))
        _ = registry.request(.relay(studio), desktopSessionActive: false)
        check(registry.request(.off, desktopSessionActive: false) == .applied, "off applies")
        check(registry.isOff && registry.activeRouteSelection == nil, "off has no routes")
        check(registry.relays.count == 1, "off removes nothing")
        check(registry.request(.relay(studio), desktopSessionActive: false) == .applied,
              "relay selectable again without re-registration")
    }

    static func selectionIsDeferredDuringASession() {
        var registry = PlankRelayRegistry()
        registry.register(selection(studio, "Studio Relay", [route("192.0.2.10")]))
        registry.register(selection(other, "Desk Relay", [route("192.0.2.20")]))
        _ = registry.request(.relay(studio), desktopSessionActive: false)
        check(registry.request(.relay(other), desktopSessionActive: true) == .deferredUntilDisconnect,
              "live session defers")
        check(registry.selection == .relay(studio), "live session keeps its Relay")
        check(registry.request(.off, desktopSessionActive: true) == .deferredUntilDisconnect,
              "latest request replaces pending")
        check(registry.pendingSelection == .off, "pending is the latest choice")
        check(registry.desktopSessionEnded(), "disconnect applies pending")
        check(registry.isOff && registry.pendingSelection == nil, "applied once")
        check(!registry.desktopSessionEnded(), "nothing replayed")
        // Choosing the current Relay again during a session cancels a pending change.
        _ = registry.request(.relay(other), desktopSessionActive: false)
        _ = registry.request(.relay(studio), desktopSessionActive: true)
        check(registry.request(.relay(other), desktopSessionActive: true) == .unchanged, "back to current")
        check(registry.pendingSelection == nil && !registry.desktopSessionEnded(), "pending cleared")
    }

    static func firstTimeApprovalCompletesOrCancelsSafely() {
        let first = descriptor(studio, request: "11111111-1111-4111-8111-111111111111")
        var registration = PlankRelayRegistration()
        check(registration.offer(first), "first link opens the sheet")
        check(!registration.offer(first), "duplicate link opens no second sheet")
        check(registration.beginApproval() == first, "approval starts for pending")
        check(registration.beginApproval() == nil, "no second approval connection")
        check(!registration.offer(descriptor(other, request: "22222222-2222-4222-8222-222222222222")),
              "no new sheet while approving")
        // A Relay that proves a different key is refused; nothing to save.
        check(registration.finish(relayKey: other) == .identityMismatch(name: "Studio Relay"),
              "mismatch refused")
        check(registration.pending == nil, "mismatch clears pending")

        // Success, then re-evaluation through the existing gate, registers once.
        var registry = PlankRelayRegistry()
        registry.register(selection(other, "Desk Relay", [route("192.0.2.20")]))
        _ = registry.request(.relay(other), desktopSessionActive: false)
        var gate = PlankDrawingHandoffGate()
        let before = gate.evaluate(first, environment: PlankDrawingTrustEnvironment())
        check(before == .needsExplicitApproval(drawingIdentity: studio), "unknown needs approval")
        check(registration.offer(first) && registration.beginApproval() != nil, "retry sheet")
        guard case let .approved(approved) = registration.finish(relayKey: studio) else {
            preconditionFailure("exact identity must approve")
        }
        let after = gate.evaluate(approved,
            environment: PlankDrawingTrustEnvironment(approvedDrawingIdentities: [studio]))
        guard case let .verifyThenConnect(routes) = after else {
            preconditionFailure("re-evaluation must proceed once approved")
        }
        registry.register(routes)
        check(registry.request(.relay(studio), desktopSessionActive: false) == .applied, "selected")
        check(registry.relays.count == 2, "registered once")

        // Cancel and failure leave the prior selection exactly as it was.
        let prior = registry
        var canceled = PlankRelayRegistration()
        _ = canceled.offer(descriptor(String(repeating: "d", count: 64),
                                      request: "33333333-3333-4333-8333-333333333333"))
        canceled.cancel()
        check(canceled.pending == nil, "dismiss clears")
        var failed = PlankRelayRegistration()
        _ = failed.offer(first)
        _ = failed.beginApproval()
        failed.cancel()
        check(failed.approving, "dismiss cannot abandon a running approval silently")
        check(failed.finish(relayKey: nil) == .abandoned, "failure abandons")
        check(registry == prior, "cancel/failure changed nothing")
    }

    static func migrationAdoptsWithoutGuessing() {
        let adopted = PlankRelayRegistry.migrated(
            existingSelection: selection(studio, "Studio Relay", [route("192.0.2.10")]),
            hasEarlierPairing: true)
        check(adopted.selection == .relay(studio) && adopted.relays.count == 1, "adopts handoff selection")
        let earlier = PlankRelayRegistry.migrated(existingSelection: nil, hasEarlierPairing: true)
        check(earlier.selection == .earlierPairing && earlier.relays.isEmpty,
              "address/service pairing kept, no identity invented")
        let fresh = PlankRelayRegistry.migrated(existingSelection: nil, hasEarlierPairing: false)
        check(fresh.isOff && fresh.relays.isEmpty, "fresh install is Off")
    }

    static func persistenceRoundTripsAndRejectsMalformedEntries() {
        let suite = "plank.relay.picker.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlankRelayRegistryStore(defaults: defaults)
        var migrations = 0
        func existing() -> PlankDrawingRouteSelection? {
            migrations += 1
            return selection(studio, "Studio Relay", [route("192.0.2.10")])
        }
        var registry = store.load(existingSelection: existing(), hasEarlierPairing: false)
        check(migrations == 1 && registry.selection == .relay(studio), "migrates once")
        registry.register(selection(other, "Desk Relay", [route("192.0.2.20", 28991)]))
        _ = registry.request(.relay(other), desktopSessionActive: true)
        store.save(registry)
        let reloaded = store.load(existingSelection: existing(), hasEarlierPairing: true)
        check(migrations == 1, "stored registry is not re-migrated")
        check(reloaded == registry, "round trip keeps relays, selection and pending")

        var raw = PlankRelayRegistryCodec.encode(registry)
        raw["relays"] = [["identity": "zz", "name": "Bad", "routes": [["address": "192.0.2.1", "port": 1]]],
                         ["identity": studio, "name": "Studio Relay", "routes": [["address": "x", "port": 0]]]]
        raw["selection"] = studio
        let malformed = PlankRelayRegistryCodec.decode(raw)
        check(malformed?.relays.isEmpty == true, "malformed entries dropped")
        check(malformed?.selection == .off, "selection of a dropped entry falls back to Off")
        check(PlankRelayRegistryCodec.decode(["version": 2]) == nil, "unknown version ignored")
    }

    static func statusLabelsFollowObservedState() {
        func status(_ selection: PlankRelaySelection, pending: Bool = false,
                    link: PlankRelayLinkObservation = .none, deferred: String? = nil) -> PlankRelayStatus {
            PlankRelayStatus.make(selection: selection, relayName: "Studio Relay",
                                  approvalPending: pending, link: link, deferredName: deferred)
        }
        check(status(.off).title == "Off", "off")
        check(status(.relay(studio)).title == "Configured", "idle is configured, not connected")
        check(status(.relay(studio), link: .connecting).title == "Connecting", "connecting")
        check(status(.relay(studio), link: .connected).title == "Connected", "connected only when observed")
        let unavailable = status(.relay(studio), link: .unavailable)
        check(unavailable.title == "Unavailable" && unavailable.detail.contains("Relay Setup"),
              "failure explains the next action")
        check(status(.relay(studio), pending: true, link: .connected).title == "Approval required",
              "pending registration wins")
        check(status(.relay(studio), deferred: "Desk Relay").detail.contains("after you disconnect"),
              "deferred change is stated")
        check(status(.earlierPairing).title == "Configured", "earlier pairing configured")
    }

    static func linkStatusFollowsDropsAndReconnects() {
        var tracker = PlankRelayLinkTracker()
        tracker.apply(.sessionStarted(configured: false))
        check(tracker.observation == .none, "Off session reports nothing")
        tracker.apply(.sessionStarted(configured: true))
        check(tracker.observation == .connecting, "configured session starts connecting")
        tracker.apply(.ready)
        check(tracker.observation == .connected, "handshake connects")
        tracker.apply(.closed(wasReady: true))
        check(tracker.observation == .connecting, "a drop is not still Connected; retrying")
        tracker.apply(.closed(wasReady: false))
        check(tracker.observation == .unavailable, "a retry that never connected is a failure")
        tracker.apply(.ready)
        check(tracker.observation == .connected, "successful reconnection")
        tracker.apply(.failed)
        check(tracker.observation == .unavailable, "start failure")
        tracker.apply(.sessionEnded)
        check(tracker.observation == .unavailable, "failure stays reported after the session")
        tracker.apply(.sessionStarted(configured: true))
        tracker.apply(.ready)
        tracker.apply(.sessionEnded)
        check(tracker.observation == .none, "a finished link is idle, not Connected")
    }

    static func lateApprovalAfterCancelIsDiscarded() {
        var registry = PlankRelayRegistry()
        registry.register(selection(other, "Desk Relay", [route("192.0.2.20")]))
        _ = registry.request(.relay(other), desktopSessionActive: false)
        let prior = registry
        var registration = PlankRelayRegistration()
        _ = registration.offer(descriptor(studio, request: "44444444-4444-4444-8444-444444444444"))
        _ = registration.beginApproval()
        registration.cancel()
        check(registration.cancelRequested, "cancel during approval is recorded")
        // The approval then completes with the exact, matching key.
        check(registration.finish(relayKey: studio) == .abandoned,
              "a late matching result after Cancel is discarded")
        check(!registration.cancelRequested && registration.pending == nil, "reset after finish")
        check(registry == prior, "prior selection and approvals untouched")
        // The flag never leaks into the next approval.
        _ = registration.offer(descriptor(studio, request: "55555555-5555-4555-8555-555555555555"))
        _ = registration.beginApproval()
        guard case .approved = registration.finish(relayKey: studio) else {
            preconditionFailure("a later uncanceled approval still succeeds")
        }
    }

    static func earlierPairingIsTransitional() {
        var registry = PlankRelayRegistry.migrated(existingSelection: nil, hasEarlierPairing: true)
        check(registry.offersEarlierPairing, "offered while selected")
        _ = registry.request(.off, desktopSessionActive: true)
        check(registry.offersEarlierPairing, "still the live selection until disconnect")
        registry.desktopSessionEnded()
        check(!registry.offersEarlierPairing, "not offered once the user moved away")
        _ = registry.request(.earlierPairing, desktopSessionActive: true)
        check(registry.offersEarlierPairing, "offered while pending")
        _ = registry.request(.off, desktopSessionActive: true)
        check(!registry.offersEarlierPairing, "withdrawn pending is not offered")
        registry.register(selection(studio, "Studio Relay", [route("192.0.2.10")]))
        _ = registry.request(.relay(studio), desktopSessionActive: false)
        check(!registry.offersEarlierPairing, "a registered selection hides the earlier pairing")
    }
}
