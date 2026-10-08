# Native iPad pilot

Separate development application, `com.instinctual.plank.ipadpilot`, using the
existing native session/media services at their current source paths. Shipping
Mac and Vision app identities and targets are unchanged. iPadOS 26 and Apple
Silicon device/simulator are the initial compile scope, not a final OS matrix.

## First slice

One saved workstation, login, one aspect-fit desktop, video/audio, direct finger
mouse emulation, indirect pointer buttons, physical wheel and hardware keyboard.
Local controls live above the canvas; opening a control sheet retires locally
held input. The toolbar's up-chevron hides PLANK's navigation/status bars and
expands the canvas. A small down-chevron restores the toolbar. This preference
persists; the connection screen always shows its navigation bar. Hiding or
restoring controls cancels held local input without restarting the stream or
changing the remote display mode. iPadOS retains its own window management and
system gestures. The keyboard sheet sends text plus Return/Escape without stealing
remote drags. Rotation/size changes cancel the current local contact. Background
ends this pilot's stream and requires reconnect; it does not log out Linux.

Build 2 simplifies resolution selection to **Balanced (1920×1200)** and
**Sharper (2560×1600)**, both 16:10. Existing bookmarks retain their saved mode
as an additional choice until explicitly changed. The new-bookmark default is
Balanced. Rotation resizes the local aspect-fit viewport; it does not renegotiate
the Host or crop/stretch the desktop.

These are interim supported modes, not exact iPad fit. The test iPad Air's
landscape panel is 2360×1640 (59:41). The pinned virtual-startup Host mode list
has no exact match. The maintained parent already documents optional bounded
physical-startup display matching (`0x400000`), but that contract explicitly
keeps headless virtual startup preset-only. Exact-fit support must use a
capability-qualified existing matching path where available, and qualified
virtual EDID modes for headless workstations. Do not blindly send arbitrary
sizes or stretch/crop the image to claim native fit. No Host deployment is
included in this pilot change.

Build 3 adds Apple Pencil through the existing normalized pen protocol (type 7),
separate from mouse emulation and raw Wacom identity. The Host must advertise
pen support (`0x01`), and a selected raw Relay disables this pen path. Actual
coalesced contact samples carry subpixel coordinates, force divided by UIKit's
reported maximum, and altitude/azimuth converted to Host tilt direction. Hover
uses UIKit's normalized distance. Predicted samples and late estimated-property
updates are not sent. Build 3 does not map squeeze, double-tap, eraser or barrel roll.
USB-C Pencil does not provide pressure sensitivity; an unknown/zero force range
sends zero pressure rather than inventing a measurement.

Rotation, canvas dimension changes, control sheets, focus loss and local source
handoff request cancel/proximity leave. Lift and start a fresh stroke after a
geometry change. Terminal up is accepted even at the last move's timestamp;
stale moves cannot restart a cancelled contact. Finger/pointer movement cannot
interrupt an active Pencil stroke. Settings show negotiated Pencil availability.
The local probe has observed contact, hover and rotation cancellation, and the
user reports force responding. On October 8 the user accepted remote pressure, navigation and tip/cursor
alignment on Flame1 with build 3. The initial offset occurred inside Flame and
resolved when the user turned off Flame Tablet Margins. Use zero Tablet Margins
for this Pencil path; do not compensate the iPad coordinate mapping globally.
Remote tilt and rotation/interruption recovery remain unqualified; compilation
and wire tests do not qualify them.

Build 4 adds persistent **Windows / PC Keyboard** and **Apple Extended Keyboard**
choices in Session Controls. F1–F12 are literal function keys in either mode;
PC maps F13–F15 to Print Screen/Scroll Lock/Pause, and Apple keeps F13–F24
literal. Hardware key edges use GCKeyboard while connected, with UIKit as the
fallback. Space receives a priority local command while the remote canvas has
focus, preventing local control activation; its actual down/up still come from
the hardware adapter. A Pencil contact preserves held keyboard shortcuts.
Focus loss, opening controls, keyboard removal and mapping changes retire held
keys. iPadOS-reserved shortcuts and keyboard media actions are not remapped;
use the keyboard's Fn key if it emits media actions instead of F-keys.

Pencil Pro squeeze sends one right mouse click (wire button 3) on gesture end,
at the supplied hover location. Lift the tip before squeezing. It does nothing
while drawing, another mouse button is held, local controls are open, or the
Pencil is outside hover range/the video area. This avoids ending an artist's
stroke or releasing a physical mouse button. Double-tap and barrel roll remain
unmapped. Apple Pencil system shortcuts can consume squeeze before the app
receives it. On October 8 the user confirmed F-keys reach Flame with Fn held on a separate
Bluetooth Apple Magic Keyboard; ordinary top-row keys still control the iPad.
Space during a Pencil drag and squeeze acceptance remain pending. No iPadOS
setting reversing the keyboard's default top row has been verified.

Build 5 separates UIKit discrete wheel and continuous scroll recognizers. Each
nonzero physical-wheel callback sends one bounded 120-unit protocol notch;
continuous motion accumulates fractional units at a nominal 32 view points per
detent. Horizontal direction follows the existing Mac adapter. Cancelled events,
local controls, letterboxes and active Pencil strokes do not send scroll input.
Focus/geometry changes clear fractional motion. Bounded aggregate console counts
record locally submitted scroll events/units, not Host acknowledgment. Physical
wheel speed/direction and continuous-device behavior require device acceptance.

No raw Wacom driver or direct Bluetooth Wacom support is claimed. PTH-660
produced no visible probe input over USB or Bluetooth on the test iPad. The
registered Mac/Linux Relay route is the planned first Wacom path; its codecs
compile here but the enrollment/selection UI and iOS drawing qualification are
a subsequent slice. No Relay keys or approvals are imported from another app.

The shared engine retains the reviewed native recipe's exact parent/Kymux pins.
Upstream issue 9 still owns persistent trust, exact-format decoder fallback,
audio clock, input lifetime and current-parent reconciliation. This development
pilot is not a production security/precision or held-input release qualification.
Local release requests before disconnect are not proof of Host receipt: the
known shared sender shutdown ordering remains an upstream gate. No Host package
change or deployment is part of this target.

`PlankIPadVideo.swift` and `PlankIPadKeys.swift` mechanically extract the current
Vision fit/cursor container and UIKit key map; Metal presentation itself compiles
from its original shared source. These extractions are temporary pending the
agreed upstream shared-directory move, not new wire or decoder implementations.

## Unsigned build

The existing checksum/source-verified recipe accepts `ios-device` and
`ios-simulator`. Each needs its own fresh work directory and matching libraries.

```sh
rustup target add --toolchain 1.96.0 aarch64-apple-ios aarch64-apple-ios-sim
python3 scripts/apple-native/build.py prepare --platform ios-device \
  --work "$PLANK_IPAD_WORK" --cache "$PLANK_NATIVE_ARCHIVES"
python3 scripts/apple-native/build.py deps --platform ios-device --work "$PLANK_IPAD_WORK"
python3 scripts/apple-native/build.py build --platform ios-device \
  --work "$PLANK_IPAD_WORK" --client "$PLANK_CLIENT_SOURCE"
xcrun swiftc -Onone visionos-native/Sources/Models/HostBookmark.swift \
  ios-native/Sources/PlankIPadDisplayOptions.swift \
  ios-native/Sources/PlankIPadKeys.swift \
  ios-native/Sources/PlankIPadInputPolicy.swift \
  ios-native/Tests/InputPolicyChecks.swift -o "$PLANK_IPAD_CHECKS"
"$PLANK_IPAD_CHECKS"
```

Signing, profile/device membership checks, installation and runtime acceptance
are separate. Do not treat successful compilation or standalone finger/mouse
probe acceptance as a remote desktop pass.

## Pencil checks

```sh
xcrun swiftc -Onone visionos-native/Sources/Services/PlankInputQueue.swift \
  visionos-native/Sources/Models/HostBookmark.swift \
  ios-native/Sources/PlankIPadKeys.swift \
  ios-native/Sources/PlankIPadInputPolicy.swift \
  ios-native/Sources/PlankIPadPencilPolicy.swift \
  ios-native/Tests/PencilPolicyChecks.swift -o "$PLANK_PENCIL_CHECKS"
"$PLANK_PENCIL_CHECKS"
xcrun clang -O1 -DPLANK_NATIVE_TRANSPORT=1 -I "$PLANK_TRANSPORT_DIR/include" \
  visionos-native/Tests/PlankPenBridgeTests.c \
  visionos-native/Bridge/PlankRawHidFrame.c \
  -Wl,-dead_strip,-undefined,dynamic_lookup -o "$PLANK_PEN_WIRE_CHECKS"
"$PLANK_PEN_WIRE_CHECKS"
```

Orientation follows Apple's [azimuth definition](https://developer.apple.com/documentation/uikit/uitouch/azimuthangle(in:))
and the existing Host virtual-pen convention, with four cardinal-direction
fixtures. Host observation of tilt is still required.
