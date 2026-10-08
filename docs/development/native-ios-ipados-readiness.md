# Native iOS and iPadOS readiness

Audit date: 2026-10-08. Status: input probe partially accepted; single-display
iPad Client has targeted playback, mouse, keyboard and resolution-switching
acceptance, not production qualification.

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
pressure-or-distance, tilt and rotation. iPad pilot build 3 adds an additive
normalized-pen event to the shared queue and C bridge, using this canonical
encoder and the existing input sender. It requires the negotiated Host feature
`0x01`; a selected raw Relay excludes Pencil. No dependency or Host change is
part of this adapter.

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

The current hardware is iPad Air 11-inch (M4), iPadOS 26.5, with Wacom Intuos
Pro PTH-660. Pencil hardware is now available. The precise Pencil model is
still unrecorded; pressure/hover support must not be inferred for other models.

## Standalone probe checkpoint

The [local iPad input probe](../../experiments/ipad-input-probe/README.md) is a
separate UIKit app with contact accounting, actual/coalesced Pencil samples,
force/orientation readings, optional hover, pointer/wheel and keyboard
diagnostics. It makes no remote input or raw-Wacom capture claim. Device and
simulator unsigned compilation and the focused terminal/order/cancellation
checks passed on October 8. Development build 1 was signed, installed and
launched after profile/device membership verification. The user reports finger
and mouse working. On October 8, device screenshots show Pencil contact and
hover. The user reports force responding. Rotation deliberately cancelled one
contact: 26 downs, 25 ups, one cancellation and zero held contacts. Fresh strokes
after rotation and background cancellation remain unqualified. These are local
probe observations, not remote drawing acceptance.

The connected test device reports iPad Air 11-inch (M4), iPadOS 26.5. This
meets the documented M-series condition for a later USBDriverKit feasibility
investigation. The user enabled Developer Mode. PTH-660 produced no dot or
other visible probe input over both USB and Bluetooth. This is a failed
system-input probe, not a test of raw report capture, which the app does not
implement. Direct Wacom support remains a separate research gate.

## Single-display Client checkpoint

The [separate iPad pilot](../../ios-native/README.md) adds an iPad-only target,
independent identity/bookmarks, manual workstation entry/login, one fit desktop,
finger/pointer, physical wheel, hardware keyboard and session controls. It
compiles the existing shared session, video, audio and authenticated Relay
codecs from their original source paths. No transport dependency pin is moved.
Shared source adaptations guard the Vision spatial-audio API to visionOS and
omit unsupported presentation-timing callbacks in the iOS simulator. Device
rendering and the session/trust/precision/audio-clock implementations remain
unchanged.

Pencil remains separate from mouse emulation. Registered Relay enrollment/selection
and iOS Wacom acceptance are next; compiled receiver code is not drawing
qualification. iPhone and multiple displays are outside this first target.
The initial pilot deployment target is iPadOS 26, separate from the input
probe's iPadOS 18 target and from any final supported OS matrix.

On October 8, the user accepted playback, mouse, hardware keyboard and several
resolution changes on installed pilot build 1. This report does not establish
Pencil, pressure, Relay drawing, audio, wheel, held-contact teardown or sustained
qualification. The next local pilot simplifies display choices and makes the
session toolbar hideable; it requires its own focused device check.

### iPad display fit

The connected iPad reports native portrait pixels 1640×2360 and landscape-right
orientation, consistent with Apple's [iPad Air 11-inch (M4) specifications](https://support.apple.com/en-us/126471).
Its landscape aspect ratio is 59:41. The currently pinned native Client requests
only the shared qualified virtual modes; none matches that panel exactly.
The interim iPad choices are 1920×1200 and 2560×1600 (both 16:10), with saved
legacy modes preserved. They must not be labeled exact-fit or native resolution.

The maintained parent's `protocol/output-topology.md` already defines bounded
physical matching (`0x400000`), so a new general display contract is not the
first step. Coordinate adoption with issue 9, verify the installed Host's
capabilities/startup kind, and use that existing path only where negotiated.
Headless virtual startup remains EDID-preset-only under that contract and needs
qualified iPad modes before exact fit can be offered. Suggested native-panel
target for this device: 2360×1640; any lower-cost same-aspect preset also needs
timing/EDID and encoder qualification. Never silently send unsupported modes.

Toolbar visibility and rotation only alter local layout; they do not change
remote session geometry. Local input is retired before layout changes and the
renderer/input adapter continue sharing the same aspect-fit rectangle. This
avoids cropping, stretching or display/session churn just to hide controls.

Focused fit/edge, held-button/key release and fractional-wheel checks pass.
Unsigned device and simulator compilation, protected signing and remote
desktop acceptance must be recorded independently. The shared issue-9 gates
remain open, including unexpected-stop release forwarding and persistent trust.

## Remote Pencil candidate — October 8

Build 3 forwards ordered actual/coalesced samples through type 7. The adapter
uses the presentation viewport without pixel quantization, rejects letterboxing
for new contacts, clamps held contacts at the desktop edge, normalizes measured
force, and converts altitude/azimuth to tilt direction. Hover distance is the
UIKit normalized value. Unknown orientation is sent as unknown; zero/unknown
force range sends zero pressure. No predicted or late estimated samples are
replayed. Barrel roll, squeeze and double-tap are not implemented.

Focused checks cover subpixel mapping, force limits, all four Host tilt axes,
same-timestamp up, duplicate/stale moves, cancel/leave idempotence, new contact
after cancellation, queue transition order, canonical big-endian type-7 bytes,
invalid payload refusal and sender failure propagation. Local admission closes
on sheets, focus, size/rotation and source changes. The shared stop path can
still discard queued releases: disconnect/background Host cleanup is an upstream
qualification gate, not a claimed release guarantee.

Next acceptance is remote hover/tap/drag, varied-pressure strokes and tilt in a
compatible drawing app, plus rotation ending the old stroke and allowing a fresh
one after lift. Finger/mouse/keyboard and playback acceptance already recorded
must not be repeated as prerequisites. This candidate is separate from the
shipping Mac/Vision targets and adds no Host package deployment.

### Remote Pencil acceptance

On October 8, the user reported pressure and navigation working on iPad build 3
connected to Flame1. A stationary tip/cursor offset was isolated to Flame. The
Host's virtual stylus had an active-area top/left inset; turning off Flame's
Tablet Margins resolved the offset according to the user. Pressure, navigation
and alignment are accepted for this tested setup, without a client coordinate
change or Host package deployment. Keep Tablet Margins at zero for the Pencil
path. Remote tilt, rotation recovery and interruption/held-state cleanup are not
inferred from this pass. Do not repeat the accepted pressure/navigation/alignment
checks as prerequisites.


## Hardware keyboard and squeeze candidate — October 8

The user reported missing function keys and Space in build 3, qualifying the
previous general keyboard pass. Build 4 adds the same Apple/PC function-key
semantics as Vision, persisted in Session Controls, and uses the connected
GCKeyboard's actual key edges. UIKit remains a fallback rather than a second
owner. Mapping aliases retain their original down identity until release; two
Shift keys cannot release each other prematurely. Space is reserved locally
while the canvas owns focus. Starting a Pencil stroke now retires pointer
buttons without releasing held keyboard shortcuts. Local controls, keyboard
removal, focus and mapping changes still release held keys. No media-key or
system-shortcut interception is claimed.

Pencil Pro squeeze sends one balanced right mouse click at its hover location
on gesture end. It is suppressed during tip contact, held pointer buttons,
closed admission or missing/outside hover position. This uses mouse button 3,
not a fabricated Pencil barrel button. Squeeze delivery requires supported
hardware and an iPadOS squeeze preference that delivers the gesture to apps.
Double-tap is unchanged. Focused keyboard mapping/alias/release and squeeze
admission checks plus device compilation pass; live keyboard/squeeze acceptance
is pending. Shared shutdown receipt/Host cleanup remains upstream-owned.

## iPad wheel correction (build 5)

The prior adapter passed UIKit view-point translation directly as high-resolution
wire units. The working Mac adapter and common-C contract use 120 units per
wheel detent. Build 5 separates discrete and continuous UIKit scroll masks: a
nonzero discrete callback emits one bounded detent per axis, while continuous
input retains fractional motion at 32 points per detent (the existing Vision
fallback's nominal scale). Horizontal sign matches the Mac adapter. Cancellation,
focus/geometry reset, controls, letterboxes and active Pencil contact remain
guarded. Aggregate console counts measure submission only. Policy checks and a
device build are required; user wheel speed/direction acceptance is pending.

Build 4 F-key forwarding was accepted with Fn held on the user's separate
Bluetooth Magic Keyboard. Space with Pencil drag and squeeze remain pending.

### Build 6 wheel event admission

The user reported build 5 not working. Its launch process exited normally and
the app was reopened as a new process; the old console contains no test data,
so absence of console counts does not prove absence of callbacks. Comparison
with the maintained Moonlight iOS UIKit adapter identified an empty allowed
touch-type list in PLANK's scroll recognizers. Build 6 explicitly allows
indirect-pointer input and sets maximumNumberOfTouches to zero, admitting wheel
events while excluding contact drags. Both discrete and continuous masks retain
the build 5 unit conversion. Received/submitted/blocked aggregate counts appear
under Session Controls when Show statistics is enabled, independently of the
launch console. Runtime acceptance is pending. Reference: [Moonlight iOS
StreamView](https://github.com/moonlight-stream/moonlight-ios/blob/master/Limelight/Input/StreamView.m).
