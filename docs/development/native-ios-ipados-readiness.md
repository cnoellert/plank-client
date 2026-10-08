# Native iOS and iPadOS readiness

Audit date: 2026-10-08. Status: implementation plan, not device qualification.

## Recommended order

Start with an iPad input probe for Apple Pencil, then a native single-display
Client using the shared media/session stack and registered Relay drawing.
Include external Wacom in the design from the beginning. Treat direct USB
capture as a separate feasibility gate rather than a prerequisite for the
first Client. Investigate direct Bluetooth only against an exact tablet model
and accessible protocol.

This work can proceed while the native Mac foundation is reviewed. Changes to
shared trust, input lifetime, transport precision and the maintained-parent
baseline remain coordinated through [Client issue 9](https://github.com/instinctual/plank-client/issues/9).

## Baseline and evidence limits

The inspected native Client is `b45921542e9e7224fc6787ee0abc09e2d10e5e8a`,
including Mac foundation `ac9fb757979cf6c92768448345abad592920ddc5` and tablet
sharing `73add890536d38b42b11d687cd0a68ddd48ae90e`. The public native recipe
still selects parent `6c6865562713d265a657dec613f55169ccb379b2`, Kymux
`8654cfece0fe5f3ab35177f520ca9378f6d35c24`, managed Relay `73a3743` and raw
Relay `029721f`. The independently inspected maintained parent is `0709ef0`;
its existence does not change those recipe pins.

UIKit Pencil, CoreBluetooth L2CAP, AVFAudio and Metal API references passed
standalone Swift typechecking for arm64 iOS device and simulator against SDK
27.0, using an iOS 18.0 probe deployment target. That target is not a chosen
product minimum. These checks establish API availability only: no complete
iOS app was built, installed or tested; no USB driver or entitlement was
validated. Existing AVP and Mac acceptance remains specific to those platforms.

## Input capability map

| Path | Evidence | Proposed status |
| --- | --- | --- |
| Apple Pencil → compatible iPad → workstation | Public UIKit touch, pressure, orientation and optional hover APIs; native transport already defines normalized pen input | First input probe and initial iPad drawing path |
| Wacom → Mac Relay → iPad/iPhone → workstation | Mac capture/sharing and native authenticated Relay receiver exist; iOS receiver not qualified | First external Wacom route, over TCP |
| Wacom → Linux Relay → iPad/iPhone → workstation | Existing raw drawing service and native TCP receiver; Bluetooth receiver uses CoreBluetooth GATT discovery plus L2CAP | TCP first; qualify Linux Bluetooth separately on iOS |
| Wacom USB → M-series iPad → workstation | Apple supports USBDriverKit on M-series iPads; no Wacom-specific driver proof | Feasibility investigation only |
| Wacom USB → A-series iPad or iPhone | The documented iPad DriverKit path requires M-series hardware | No direct raw USB implementation proposed through DriverKit |
| Wacom Bluetooth → iPad/iPhone → workstation | No verified public raw-report route for the target tablet | Research gate; generic pointer operation is insufficient |

Apple's [iPad driver guide](https://developer.apple.com/documentation/driverkit/creating-drivers-for-ipados)
and [USBDriverKit documentation](https://developer.apple.com/documentation/usbdriverkit)
provide the platform basis for the USB investigation. Wacom's own
[Intuos compatibility statement](https://support.wacom.com/hc/en-us/articles/1500006331582-Does-the-Wacom-Intuos-pen-tablet-work-with-an-iPhone-or-iPad)
does not promise direct iPad/iPhone support. A custom driver remains an
engineering hypothesis, not vendor-supported plug-and-play behavior. The
statement concerns Intuos; it does not resolve every Wacom product or model.

For iPhone, begin with touch, keyboard/mouse and registered Relay reception.
Pencil support targets Apple's compatible iPads. Capabilities must be checked
for each Pencil/iPad combination: for example, Pencil USB-C lacks pressure
sensitivity, and hover depends on the combination. See Apple's
[Pencil feature comparison](https://www.apple.com/apple-pencil/).

## What can be reused

Paths below refer to the inspected Client tree, before any shared/platform
directory reorganization.

| Existing component | Reuse candidate | Required platform work |
| --- | --- | --- |
| `PlankSessionEngine`, hardware decoder and media bridges | Session/media plumbing, VideoToolbox decode, native transport | Adopt the upstream-reconciled lifetime/contract; iOS foreground, lock and interruption behavior |
| `PlankAudioOutput`, receiver, ring and format policies | AVFAudio output and stale-audio retirement | Route, interruption and background validation on iOS |
| `PlankMetalVideoView` | UIKit/Metal presentation | iPad point/pixel scaling, safe areas, viewport transforms, rotation and window resizing |
| Host HTTP/discovery, trust and bookmark services | Connection and saved-host policies | Separate app identity/settings, local-network permission, UI and lifecycle |
| Relay keys, enrollment, live link and byte transports | Authentication, raw-HID framing, TCP and Bluetooth receiver logic | iOS handoff/enrollment flow and per-platform permissions/acceptance |
| Mouse/input policy helpers | Arbitration, coordinate and held-state concepts | UIKit pointer, wheel, keyboard, touch and Pencil adapters |
| Mac IOHID Wacom worker and wrapper | Raw-report, activity filtering and exclusive ownership design | Desktop IOHIDManager capture is not an iOS app capture implementation |
| Mac AppKit windows and `PlankMacInput` | Behavioral reference | New UIKit/SwiftUI iOS shell and input surfaces |

The current Vision app entry point uses visionOS scene/window policies, and
its build targets are Vision and Mac. A new iOS target needs iPhoneOS and
simulator Rust/C libraries, matching architecture and deployment settings,
assets, usage descriptions, signing and a reproducible build-input receipt.
Renaming the Vision app is insufficient. Keep the platform shell small;
directory moves should remain mechanical and distinct from behavior changes.

## Pencil: use normalized pen input

The pinned parent's
[input header](https://github.com/cnoellert/plank/blob/6c6865562713d265a657dec613f55169ccb379b2/protocol/plank-transport/include/plank_transport_input.h)
already defines `PLANK_TRANSPORT_INPUT_PEN` (type 7), a 32-byte payload and
`plank_transport_input_encode_pen`. It includes event/tool/buttons, coordinates,
pressure-or-distance, tilt and rotation. The native Swift input queue and C
bridge currently have no Pencil/normalized-pen sender.

The same parent's Host gitlink is `5829bf7c335440a8b25c3330643eacb4d914f00a`.
Its [input parser](https://github.com/instinctual/plank-host-linux/blob/5829bf7c335440a8b25c3330643eacb4d914f00a/src/input.cpp)
accepts type 7 and selects the normalized pen backend; its
[virtual pen backend](https://github.com/instinctual/plank-host-linux/blob/5829bf7c335440a8b25c3330643eacb4d914f00a/src/platform/virtualhid_input.cpp)
handles contact, pressure, distance and tilt. This source evidence supports
trying the existing contract before proposing a Host extension. It does not
verify any installed Host package or its advertised capabilities.

The first Pencil adapter should:

- Read actual UIKit Pencil samples, normalize supported force, and preserve
  sample order. Use coalesced touches without forwarding the terminal sample
  twice. Keep acquisition independent of SwiftUI redraws.
- Map positions through the visible video rectangle to the selected remote
  display; exclude letterboxing and local controls. Define behavior for zoom,
  pan, rotation and geometry changes during contact.
- Convert altitude/azimuth into the existing tilt/orientation convention with
  a fixture and Host observation. The current backend uses packet rotation to
  derive tilt direction: Pencil Pro barrel roll is not that same quantity.
  Independent barrel roll may require an explicit contract addition later.
- Emit contact up, cancel and proximity leave consistently on cancellation,
  focus/background transitions, source switches and disconnect. Establish
  cleanup ordering before stopping the sender; do not equate local submission
  with Host acknowledgement.
- Keep predicted touches local to an optional preview. Sending them as real
  remote pen events would create speculative input that cannot be retracted.
- Treat unsupported pressure, hover, squeeze, double-tap and barrel roll as
  explicit capabilities. A pressureless contact policy must be labeled; do
  not report a fabricated measurement. Gestures must not invent ExpressKeys.

Primary API references: Apple's
[force and orientation example](https://developer.apple.com/documentation/uikit/illustrating-the-force-altitude-and-azimuth-properties-of-touch-input),
[coalesced touches guide](https://developer.apple.com/documentation/uikit/getting-high-fidelity-input-with-coalesced-touches),
[predicted touches reference](https://developer.apple.com/documentation/uikit/uievent/predictedtouches(for:)),
and [Pencil hover sample](https://developer.apple.com/documentation/uikit/adopting-hover-support-for-apple-pencil).
The ordering, cancellation and remote-preview rules above are PLANK design
requirements, not claims that these APIs alone enforce them.

## External Wacom: preserve the drawing semantics

Registered Relay drawing should retain the existing authenticated,
bidirectional raw-HID path: device identity/descriptors, input reports,
workstation-to-device communication, pressure, tool/button transitions and
exclusive capture ownership. A pointer-only fallback must not be described
as qualified Wacom drawing.

Pencil uses a normalized virtual pen. External Wacom uses its existing raw
device path. Do not synthesize a Wacom USB identity for Pencil or run both
capture sources simultaneously by default. Keep source selection explicit,
retire held state before takeover, and avoid duplicate remote endpoints.

The Relay discovery UI must distinguish discovering a service from reaching
and authenticating it. The earlier Mac/AVP network experience showed why a
working Apple virtual display is not proof of a reachable Relay TCP route.
Keep source availability and actual drawing connection status separate.

### Direct USB feasibility gate

An iPad driver is a separate bundled extension with app communication and
user enablement. Apple's supported iPad families include USBDriverKit; the
iPad guide does not list HIDDriverKit as a supported family. The existing Mac
IOHIDManager worker must not simply be compiled into the iPad app.

Before committing to a direct driver, establish:

1. Exact iPad chip/OS and Wacom USB vendor/product/interface/report descriptors.
2. Whether an approved USBDriverKit match can obtain the required interfaces
   when system HID handling exists, including bidirectional feature/output
   operations. Validate exclusive ownership and app/user-client boundaries.
3. Required signing/provisioning and Apple-approved device entitlements, plus
   activation, hotplug and restart behavior on real hardware.
4. Whether the same raw wire contract can be retained without report rewriting,
   and which supported tablet models can be qualified reproducibly.

Apple documents the approval process in
[Requesting Entitlements for DriverKit Development](https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development).
No entitlement request, distribution approval or successful Wacom device claim
is established by this audit.

### Bluetooth feasibility gate

Receiving from the Linux Relay is distinct from capturing a Bluetooth Wacom
directly. The existing receiver discovers PLANK's GATT service, reads its PSM,
opens a CoreBluetooth L2CAP channel and authenticates the saved Relay identity.
Its iOS API availability passed typechecking; its iOS runtime remains untested.

[CoreBluetooth](https://developer.apple.com/documentation/corebluetooth)
supports documented Bluetooth services, but that does not establish access to
arbitrary Wacom HID channels. Direct support needs a verified model/protocol
and public access path. Likewise, [ExternalAccessory](https://developer.apple.com/documentation/externalaccessory)
requires manufacturer-supported accessory protocols and is not a generic HID
escape hatch. Do not advertise direct Bluetooth Wacom support based on pairing
or a moving system cursor.

## Delivery slices and acceptance

1. **Standalone iPad input probe:** Pencil hover where supported, contact,
   force/tilt, coalesced samples, cancel/leave and local mouse/wheel/keyboard.
   Record timing/counts and capability metadata; no full Client integration
   or Host package is needed for this source probe.
2. **Native iPad Client:** new build slice and single-display shell, using the
   agreed shared engine. Validate login, video/audio, coordinate scaling and
   input releases through the existing normalized pen contract on a compatible
   Host. Initially keep full multiwindow/multidisplay behavior out of scope.
3. **External Wacom via TCP Relay:** adapt enrollment/handoff to the iOS app
   identity. Qualify pen hover, tap, held drag, pressure, side/middle buttons,
   pad controls and return traffic for the selected supported tablet.
4. **Interruption qualification:** lock/unlock, foreground/background,
   resolution/timing changes, held contact at disconnect, tablet disappearance
   and return, Relay restart and source takeover. Inspect Host endpoints and
   releases; hover-only recovery is a failure.
5. **Linux Relay Bluetooth and direct USB research:** separate prototypes and
   receipts. Qualify the Relay path with its network disabled; require a real
   USB device claim before planning a production driver. Direct Wacom Bluetooth
   remains a separate gate.
6. **iPhone adaptation:** touch/mouse/keyboard and Relay reception after iPad
   foundation acceptance, with its own viewport and lifecycle checks.

The next hardware-dependent choice is the test iPad/Pencil combination and
external Wacom model. It selects available capabilities and the direct USB
probe; it does not block the source/API audit or shared port planning.

## Standalone probe checkpoint

The [local iPad input probe](../../experiments/ipad-input-probe/README.md) is a
separate UIKit app with contact accounting, actual/coalesced Pencil samples,
force/orientation readings, optional hover, pointer/wheel and keyboard
diagnostics. It makes no remote input or raw-Wacom capture claim. Device and
simulator unsigned compilation and the focused terminal/order/cancellation
checks passed on October 8. Physical input acceptance has not run.

The connected test device reports iPad Air 11-inch (M4), iPadOS 26.5. This
meets the documented M-series condition for a later USBDriverKit feasibility
investigation. At inspection, Developer Mode was disabled; development
installation and signing/provisioning remain separate from unsigned build
evidence. Pencil and external Wacom model selection remains pending.
