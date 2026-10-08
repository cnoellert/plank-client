# Native iPad pilot

Separate development application, `com.instinctual.plank.ipadpilot`, using the
existing native session/media services at their current source paths. Shipping
Mac and Vision app identities and targets are unchanged. iPadOS 26 and Apple
Silicon device/simulator are the initial compile scope, not a final OS matrix.

## First slice

One saved workstation, login, one aspect-fit desktop, video/audio, direct finger
mouse emulation, indirect pointer buttons, physical wheel and hardware keyboard.
Local controls live above the canvas; opening a control sheet retires locally
held input. The keyboard sheet sends text plus Return/Escape without stealing
remote drags. Rotation/size changes cancel the current local contact. Background
ends this pilot's stream and requires reconnect; it does not log out Linux.

Pencil samples are deliberately excluded from mouse emulation. The separate
input probe remains the pressure/tilt/contact test until Pencil hardware arrives.
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
xcrun swiftc -Onone ios-native/Sources/PlankIPadInputPolicy.swift \
  ios-native/Tests/InputPolicyChecks.swift -o "$PLANK_IPAD_CHECKS"
"$PLANK_IPAD_CHECKS"
```

Signing, profile/device membership checks, installation and runtime acceptance
are separate. Do not treat successful compilation or standalone finger/mouse
probe acceptance as a remote desktop pass.
