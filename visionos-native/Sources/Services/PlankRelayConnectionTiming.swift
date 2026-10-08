// SPDX-License-Identifier: GPL-3.0-or-later
// One bounded discovery attempt, then authenticated attachment. A network-only
// availability grace must not cancel Bluetooth while it is still opening.
enum PlankRelayConnectionTiming {
    static let bluetoothDiscoverySeconds = 45
    static let bluetoothLinkDeadlineSeconds = 50
    static func availabilityGraceSeconds(bluetooth: Bool) -> Int {
        bluetooth ? 60 : 12
    }
}
