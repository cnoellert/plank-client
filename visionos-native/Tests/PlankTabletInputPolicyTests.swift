@main
struct PlankTabletInputPolicyTests {
    static func main() {
        var policy = PlankTabletInputPolicy()

        policy.begin(hasPairedTablet: false)
        assert(!policy.waitsForTablet)
        assert(!policy.forwardsTabletReports)
        assert(policy.updatePreflight(ready: true).isEmpty)
        assert(!policy.waitsForTablet)

        policy.begin(hasPairedTablet: true)
        assert(policy.waitsForTablet)
        assert(!policy.forwardsTabletReports)
        assert(!policy.allowsMouseButton(1, pressed: true))
        assert(!policy.allowsMouseButton(1, pressed: false))
        assert(!policy.allowsKey(0x41, pressed: true, modifiers: 0))
        assert(!policy.allowsKey(0x41, pressed: false, modifiers: 0))
        assert(policy.updatePreflight(ready: false).isEmpty)
        assert(policy.waitsForTablet)
        assert(policy.updatePreflight(ready: true).isEmpty)
        assert(!policy.waitsForTablet)
        assert(policy.forwardsTabletReports)
        assert(policy.allowsMouseButton(1, pressed: true))
        assert(policy.allowsKey(0x42, pressed: true, modifiers: 1))

        // Losing a live Relay must close the gate again in the same session.
        assert(policy.updatePreflight(ready: false) == [
            .mouse(1), .key(0x42, modifiers: 1),
        ])
        assert(policy.waitsForTablet)
        assert(!policy.forwardsTabletReports)
        assert(!policy.allowsMouseButton(1, pressed: false))
        assert(!policy.allowsKey(0x42, pressed: false, modifiers: 1))

        policy.continueWithoutTablet()
        assert(!policy.waitsForTablet)
        assert(!policy.forwardsTabletReports)
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
    }
}
