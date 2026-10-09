# iPad Pencil sharing to PLANK Vision

Status: development implementation October 8, 2026. Publisher, receiver,
versioned records and physical comparison approval are implemented. Compilation,
local protocol checks and physical device acceptance are separate gates.
This is not yet a qualified drawing transport.

### First device result and contact correction — October 9

The user reports hover and squeeze right-click working on iPad 18 / Vision 47,
but tip clicks and dragging failing on Flame01 and Flame03, with some lag.
These are partial results, not drawing acceptance. The sharing pad omitted the
hover retirement performed by the accepted direct iPad contact path. A production
policy reproduction shows hover stamped at callback delivery can exceed a fresh
touch's acquisition timestamp: down is rejected, no touch is retained, and its
move/up events are ignored while hover continues working.

iPad 19 validates a fresh contact on a temporary policy, retires old hover, then
commits and emits leave before down. Invalid/margin starts preserve prior state;
duplicate active downs and stale motion remain rejected. Aggregate contact
counts are logged at most once per second, without coordinates or identities.
The user reports iPad 19 working well on the requested Flame03 tap/held-drag
test. The correlated Host capture contains balanced tip presses/releases and
varying pressure; publisher counters also show accepted downs, moves and ups.
This accepts the targeted contact correction, not the complete interruption
or latency qualification. A read-only Flame03 check also found the
normalized `PLANK Wacom Tablet` using Pressure Recalibration=1 despite Host
1.1.030; its packaged policy currently targets the raw mirror's udev tag.
The successful targeted test required no Host configuration/package change.
The normalized pressure-policy distinction remains recorded for investigation
if another failure needs it; this pass does not require changing it. Lag and
video decoder recovery remain separate observations. New-source reconnect,
rotation/focus and lock/background qualification remain pending.

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

## Development implementation

The iPad pilot's **Share Apple Pencil** opens a foreground pad and advertises
`_plank-pencil._tcp` with `version=1`, `capability=normalized-pen` and its public
identity. PLANK Vision Settings has a separate Apple Pencil section. The raw
Tablet Relay must be Off. The independent capability is deliberately not a
`pltr-raw-hid` descriptor; legacy raw clients do not discover or decode it.

Both apps use their own device-only, when-unlocked Keychain identity and peer
pins. Initial connection requires comparing the same twelve hexadecimal digits
on both devices and approving locally on each. The code is the first six bytes
of the authenticated IK first-message transcript hash, including the initiator
identity, ephemeral key and pinned advertised responder identity. Discovery
alone is untrusted. Existing approved identity pairs skip the comparison; a
changed public identity requires a new comparison. Pins are not shared with
Setup, Wacom Relay, Mac or another app. One pending/active headset owns the pad.

`apple-native/Shared/PlankPencilCrypto.c` calls the existing pinned relay Noise
IK implementation without changing it. It authenticates the exact
`PLANK-NORMALIZED-PEN/1` capability payload in both handshake messages. The
underlying fixed TCP Noise prologue is reused; application purpose is bound in
the encrypted handshake payload, not a newly claimed prologue. Empty raw-drawing
handshakes and mismatched purpose/version are rejected. This direct physical
comparison path does not use Setup-mediated enrollment, which remains the
existing Wacom registration path.

Records have a two-byte little-endian length, capped at 256 bytes. Handshakes
start with `PLPN` and byte version 1. Secure application plaintext also starts
with `PLPN`, version 1 and a one-byte message kind. Configuration carries two
UInt32 display dimensions and one Boolean; pen carries phase, three Float32
values, UInt8 tilt and UInt16 tilt direction; right-click carries two Float32
coordinates. All multibyte values are little-endian. Ping, pong and end have
no payload. Unknown kinds/versions, trailing bytes, nonfinite or out-of-range
values, inconsistent contact transitions, authentication failures and replay
close the peer. Transport nonce ordering comes from the existing Noise codec.

The peer serial executor owns crypto and one socket write at a time. Bounded
incoming/outgoing mailboxes admit before scheduling work, coalesce consecutive
same-phase motion only, and fail closed on edge overflow. The receiver also uses
a bounded, coalescing source-specific admission method at the workstation input
queue; refusal closes and retires the Pencil source. This does not change other
input sources or establish final Host receipt. Approval has one
absolute 60-second deadline; a connected peer has a five-second heartbeat
limit. The iPad retains actual samples only. Direct iPad desktop input and the
sharing pad are separate, mutually exclusive surfaces. The receiver requests
pad geometry from its primary desktop's actual frame dimensions and pauses
admission outside supported active sessions. Mapping/focus/background changes
retire contact; a late move cannot start a new stroke. A new tip-down releases
local mouse buttons, and pointer/buttons/wheel cannot interrupt that stroke.
Squeeze is a right-click only while the tip is lifted. Rotation ends the old
contact and requires a fresh stroke.

First acceptance must establish iPad → AVP → workstation drawing, pressure,
alignment and right-click, followed by focus, rotation, lock and reconnect.
Compilation, a working direct iPad Pencil or a working raw Wacom Relay does not
qualify this chain. Bluetooth and background capture remain outside this slice.
Host sender teardown and final receipt remain the existing upstream gate.

### Local verification

The focused Swift checks passed finite/range validation, unknown-version and
trailing-byte rejection, contact ordering, fresh-down after cancellation and
10,000 motion samples coalesced without losing stroke edges. The C adapter
passed under AddressSanitizer/UndefinedBehaviorSanitizer: matching transcript
codes, authenticated capability negotiation, empty raw handshake rejection,
same-length wrong purpose rejection, preapproval rejection and encrypted replay
failure. A real TCP loopback fixture with injected in-memory consent storage
passed two-sided comparison, no durable approval before comparison, configuration
acknowledgment and ordered down/move/up pressure delivery. These tests do not
qualify the physical iPad, AVP, Keychain entitlement or workstation drawing.
Each desktop lifetime retires its peer generation. The selected iPad can reconnect
on the next supported desktop with its existing verified identity; callbacks from
the previous peer cannot enter that desktop. An unexpected network failure
requires selecting the pad again rather than creating an unbounded retry loop.
