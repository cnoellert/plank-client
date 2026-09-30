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
        assert(absent.continueIfUnavailable())
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
        assert(!attached.continueIfUnavailable())
        assert(attached.waitsForTablet)
        assert(attached.showsBlockingOverlay)
        assert(!attached.allowsMouseButton(1, pressed: true))
        assert(attached.updatePreflight(ready: true, relayAttached: true).isEmpty)
        assert(!attached.waitsForTablet)
        assert(attached.forwardsTabletReports)
    }
}
