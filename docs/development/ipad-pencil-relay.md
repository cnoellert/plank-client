# iPad Pencil sharing to PLANK Vision

Status: requested October 8, 2026; implementation follows the keyboard docking
correction. This is a scoped design, not a working Relay or qualified transport.

## Intended use

Enable **Share Apple Pencil** on the iPad, approve the headset, then select that
iPad in PLANK Vision. The iPad becomes an absolute tablet surface while the AVP
shows the workstation. First transport is an authenticated local network link;
Bluetooth advertising/drawing is a separate platform/transport qualification.
No workstation package change is planned: use the existing type-7 normalized
pen capability only when the workstation advertises support.

## Existing paths and required extension

- `ios-native/Sources/PlankIPadPencilPolicy.swift` already converts real UIKit
  Pencil samples to `PlankNormalizedPen`: hover/contact/up/cancel/leave,
  normalized position, pressure or hover distance, tilt and tilt direction.
  Its `rotation` is tilt direction, not Pencil barrel roll.
- `visionos-native/Sources/Services/PlankCoreClient.swift` already sends those
  packets to the workstation. It currently refuses normalized pen when a raw
  Relay is selected. Add an explicit source/capability distinction; do not
  relax that guard for every Relay.
- `PlankRelayLiveLink` and the Mac Relay advertise `pltr-raw-hid`, transferring
  Wacom messages and workstation replies. Apple Pencil is not that device.
  Add a versioned normalized-pen capability and bounded authenticated record;
  unknown versions and older raw-only clients must reject it explicitly.
- Reuse reviewed identity, pairing, enrollment and authenticated framing
  boundaries. Isolate portable peer/crypto code from Mac IOKit capture before
  reuse on iPad; never import the Mac USB driver or manufacture Wacom identity.

## Implementation order

1. Define the normalized-pen capability/record and exclusive source policy,
   with schema/codec checks, finite-range validation and unsupported-version
   rejection. Preserve terminal edges; bound/coalesce replaceable hover/move
   samples without dropping contact transitions.
2. Add iPad foreground sharing with a clear pad surface, persistent app-owned
   identity and explicit physical approval. Direct desktop Pencil capture and
   sharing are mutually exclusive. Rotation/active-area changes cancel contact;
   require a fresh stroke. Lock/background/disable ends sharing and unregisters
   discovery. No claim of background Pencil capture.
3. Add AVP discovery/registration/selection for the negotiated pen capability,
   and forward accepted samples through the existing normalized pen sender.
   Raw Wacom and normalized pen own the tablet path exclusively. Gate input
   on active desktop focus and workstation pen support; retire stale peer
   generations on disconnect/reconnect. Never reuse another app's approvals.
4. Map squeeze to right-click through the existing admission/ordering policy;
   reject it during an active stroke. Do not invent unsupported eraser, barrel
   roll or ExpressKeys. Support model-dependent hover/pressure only when UIKit
   supplies them; mark unavailable features plainly.
5. Build signed iPad and AVP candidates and qualify pressure, alignment, pen
   controls, reconnect, rotation, lock/background and held-contact disconnect.
   Use the existing Host unchanged. Local cancellation is not proof of Host
   receipt: shared sender teardown remains an upstream qualification gate.

## Geometry and acceptance

Map one visible active pad area to the selected remote display using normalized
coordinates and preserve the target aspect ratio. Letterboxes do not draw.
Do not add global coordinate compensation for Flame Tablet Margins; the direct
Pencil test already established zero margins. A working standalone iPad desktop
Pencil does not qualify iPad-to-AVP forwarding, and the accepted raw Wacom Relay
checks do not qualify this new source. Initial scope is one approved headset,
one active pen owner and one selected remote display.
