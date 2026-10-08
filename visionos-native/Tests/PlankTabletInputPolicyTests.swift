@main
struct PlankTabletInputPolicyTests {
    static func main() {
        var policy = PlankTabletInputPolicy()

        policy.begin(hasPairedTablet: false)
        assert(!policy.waitsForTablet)
        assert(!policy.showsBlockingOverlay)
        assert(!policy.shouldContinueWhenUnavailable)
        assert(!policy.forwardsTabletReports)
        assert(policy.updatePreflight(ready: true).isEmpty)
        assert(!policy.waitsForTablet)

        policy.begin(hasPairedTablet: true)
        assert(policy.waitsForTablet)
        // A saved Keychain identity is not proof that a Relay or tablet is
        // present. Keep the mouse-first barrier but do not blank the desktop.
        assert(!policy.showsBlockingOverlay)
        assert(policy.shouldContinueWhenUnavailable)
        assert(!policy.forwardsTabletReports)
        assert(!policy.allowsMouseButton(1, pressed: true))
        assert(!policy.allowsMouseButton(1, pressed: false))
        assert(!policy.allowsKey(0x41, pressed: true, modifiers: 0))
        assert(!policy.allowsKey(0x41, pressed: false, modifiers: 0))
        assert(policy.updatePreflight(ready: false).isEmpty)
        assert(policy.waitsForTablet)
        assert(policy.updatePreflight(ready: false, relayAttached: true).isEmpty)
        assert(policy.showsBlockingOverlay)
        assert(!policy.shouldContinueWhenUnavailable)
        assert(policy.updatePreflight(ready: true, relayAttached: true).isEmpty)
        assert(!policy.waitsForTablet)
        assert(!policy.showsBlockingOverlay)
        assert(policy.forwardsTabletReports)
        assert(policy.allowsMouseButton(1, pressed: true))
        assert(policy.allowsKey(0x42, pressed: true, modifiers: 1))

        // Losing a live Relay must close the gate again in the same session.
        assert(policy.updatePreflight(ready: false) == [
            .mouse(1), .key(0x42, modifiers: 1),
        ])
        assert(policy.waitsForTablet)
        assert(!policy.forwardsTabletReports)
        assert(policy.shouldContinueWhenUnavailable)
        assert(!policy.allowsMouseButton(1, pressed: false))
        assert(!policy.allowsKey(0x42, pressed: false, modifiers: 1))

        policy.continueWithoutTablet()
        assert(!policy.waitsForTablet)
        assert(!policy.forwardsTabletReports)
        assert(!policy.showsBlockingOverlay)
        assert(policy.allowsMouseButton(1, pressed: true))
        assert(policy.allowsMouseButton(1, pressed: false))
        assert(policy.allowsKey(0x43, pressed: true, modifiers: 0))
        assert(policy.allowsKey(0x43, pressed: false, modifiers: 0))
        assert(policy.updatePreflight(ready: true).isEmpty)
        assert(!policy.forwardsTabletReports)

        // A reconnect never inherits the previous session's bypass or ACK.
        policy.begin(hasPairedTablet: true)
        assert(policy.waitsForTablet)
        assert(!policy.forwardsTabletReports)
        assert(!policy.showsBlockingOverlay)

        // An unsupported Host bypasses immediately. A late Relay callback
        // cannot start forwarding reports or restore the input barrier.
        policy.continueWithoutTablet()
        assert(!policy.waitsForTablet)
        assert(policy.allowsMouseButton(1, pressed: true))
        assert(policy.updatePreflight(ready: true, relayAttached: true).isEmpty)
        assert(!policy.forwardsTabletReports)

        // Once the availability grace expires, an absent Relay is bypassed
        // for this session. A late attachment cannot race the first mouse click.
        var absent = PlankTabletInputPolicy()
        absent.begin(hasPairedTablet: true)
        assert(!absent.allowsMouseButton(1, pressed: true))
        assert(absent.expireAvailabilityGrace() == .continueWithoutTablet)
        assert(!absent.waitsForTablet)
        assert(!absent.allowsMouseButton(1, pressed: false))
        assert(absent.allowsMouseButton(1, pressed: true))
        assert(absent.updatePreflight(ready: true, relayAttached: true).isEmpty)
        assert(!absent.forwardsTabletReports)
        assert(!absent.waitsForTablet)

        // A Relay that actually owns the tablet must retain the input guard
        // until the Host ACK or the user explicitly chooses to continue.
        var attached = PlankTabletInputPolicy()
        attached.begin(hasPairedTablet: true)
        assert(attached.updatePreflight(ready: false, relayAttached: true).isEmpty)
        assert(attached.expireAvailabilityGrace() == .none)
        assert(attached.waitsForTablet)
        assert(attached.showsBlockingOverlay)
        assert(!attached.allowsMouseButton(1, pressed: true))
        assert(attached.updatePreflight(ready: true, relayAttached: true).isEmpty)
        assert(!attached.waitsForTablet)
        assert(attached.forwardsTabletReports)

        // A tablet lost after successful attachment must keep recovering past
        // the grace period. An outage is not an explicit opt-out for the rest
        // of the session, even if Bluetooth and USB are absent together.
        var live = PlankTabletInputPolicy()
        live.begin(hasPairedTablet: true)
        _ = live.updatePreflight(ready: true, relayAttached: true)
        assert(live.allowsMouseButton(1, pressed: true))
        assert(live.allowsKey(0x41, pressed: true, modifiers: 1))
        assert(live.updatePreflight(ready: false) == [
            .mouse(1), .key(0x41, modifiers: 1),
        ])
        assert(live.expireAvailabilityGrace() == .keepRecovering)
        assert(!live.waitsForTablet)
        assert(!live.forwardsTabletReports)
        assert(!live.showsBlockingOverlay)
        assert(!live.allowsMouseButton(1, pressed: false))
        assert(!live.allowsKey(0x41, pressed: false, modifiers: 1))
        assert(live.updatePreflight(ready: false).isEmpty)
        assert(!live.waitsForTablet)
        assert(live.expireAvailabilityGrace() == .none)
        assert(live.allowsMouseButton(1, pressed: true))
        assert(live.allowsKey(0x42, pressed: true, modifiers: 0))

        // Returning ownership closes the gate until the new Host ACK and
        // descriptors pass. Held mouse/key inputs are released before that.
        assert(live.updatePreflight(ready: false, relayAttached: true) == [
            .mouse(1), .key(0x42, modifiers: 0),
        ])
        assert(live.waitsForTablet && live.showsBlockingOverlay)
        assert(live.expireAvailabilityGrace() == .none)
        assert(!live.forwardsTabletReports)
        assert(live.updatePreflight(ready: true, relayAttached: true).isEmpty)
        assert(live.forwardsTabletReports && !live.waitsForTablet)
        assert(!live.allowsMouseButton(1, pressed: false))
        assert(!live.allowsKey(0x42, pressed: false, modifiers: 0))

        // Another outage can recover too, including a ready notification
        // that arrives before the pending ownership notification.
        _ = live.updatePreflight(ready: false)
        assert(live.expireAvailabilityGrace() == .keepRecovering)
        assert(live.updatePreflight(ready: true, relayAttached: true).isEmpty)
        assert(live.forwardsTabletReports)

        // Explicit bypass remains permanent, and a new desktop transport
        // must not inherit the previous session's successful attachment.
        _ = live.updatePreflight(ready: false)
        live.continueWithoutTablet()
        _ = live.updatePreflight(ready: true, relayAttached: true)
        assert(!live.forwardsTabletReports)
        live.begin(hasPairedTablet: true)
        assert(live.expireAvailabilityGrace() == .continueWithoutTablet)
        print("Tablet input policy checks passed, including live outage recovery")
    }
}
