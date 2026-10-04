# Native visionOS Client

## Product direction

The visionOS client uses a native SwiftUI interface in the visionOS Shared
Space. PLANK's existing protocol, transport, decoder and input implementations
remain the intended engine underneath it, but the desktop Qt interface is not
part of the visionOS product.

The earlier Qt prototype proved that the existing client could build, sign,
launch, discover hosts and continuously render on a physical Apple Vision Pro.
It also exposed the wrong product boundary: desktop Qt controls did not behave
reliably under gaze, pinch, Bluetooth mouse or keyboard input, and navigation
could change internally without presenting the requested page. Those UI shims
have been removed from the PLANK worktree.

## First usable target

The first native release should support:

- Bonjour discovery and manual workstation bookmarks;
- pairing, authentication and reconnect through the PLANK core;
- one remote desktop stream decoded by VideoToolbox and rendered with Metal;
- host audio;
- gaze, pinch, Bluetooth keyboard, trackpad, mouse and controller input;
- held-input release on focus loss, interruption and disconnect;
- both the visionOS simulator and a physical Apple Vision Pro build.

The baseline first release does not require immersive presentation, macOS
global shortcuts, Spaces-style fullscreen or one native window per remote
monitor. Wacom forwarding is now an experimental, separately paired Relay
capability. Multi-monitor hosts begin with one selected output or one scaled
canvas inside the PLANK window.

## Architecture

`visionos-native/` owns the visionOS application and interface:

- SwiftUI host browser, bookmark editor and settings;
- native window, focus and lifecycle handling;
- a narrow `PlankCoreClient` boundary for pairing and sessions;
- platform presentation of errors, authentication and connection state.

The reusable core will own:

- the GameStream/Moonlight protocol path;
- pairing and host authentication;
- the transport and session lifecycle;
- video and audio packet handling;
- normalized remote input events.

Platform rendering and input remain native to visionOS. The bridge must not
pull Qt object ownership or QML navigation into the native application.

## Current implementation

The native target currently provides:

- a working `NavigationSplitView` workstation browser;
- persistent manual bookmarks;
- `_nvstream._tcp` Bonjour discovery;
- native add, remove and settings surfaces;
- TLS 1.3 Host identity validation with certificate continuity pinning;
- native Linux username/password authentication and session-token handling;
- authenticated topology, application-list and Desktop launch requests;
- a native Rust transport bridge with bounded negotiation, frame receive and
  graceful disconnect handling;
- live HEVC 10-bit 4:4:4 video from a physical Linux Host, decoded by
  VideoToolbox into exact-color `xf44` planes with an FFmpeg fallback;
- native-resolution Metal presentation through an identity-GBR shader; the
  stream requests 60 fps, while sustained displayed fps remains to be measured;
- a separate, plain remote-desktop window with bookmark-owned single-display
  resolution and stream frame-rate choices and aspect-preserving resize;
- retained startup bitrate values in existing bookmarks (default 50 Mbps),
  with bitrate editing in the session controls rather than the bookmark editor;
- stereo Host audio playback (AVP-SET-02a): the negotiated 48 kHz stereo Opus
  reply is validated with the desktop Client's rules, decoded with pinned xiph
  libopus 1.6.1 on a dedicated receive thread (transport holes use Opus
  packet-loss concealment, one negotiated frame per lost frame as on desktop),
  and played as plain head-fixed stereo through AVAudioEngine from a bounded
  queue. The queue primes to 30 ms, grows 10 ms per underrun up to 100 ms,
  trims bursts above target + 60 ms, and holds its depth against clock drift
  with at most 1000 ppm correction so the delay behind presented video stays
  constant. Disconnect, interruptions, route and engine configuration changes,
  media-services resets and backgrounding discard queued audio before playback
  resumes. Volume and mute are local controls in the session controls
  menu (one compact button at the top of the desktop window), which also
  changes the running session's bitrate when the Host advertises live
  bitrate and acknowledgements (features 0x08 and 0x10) and shows the Host-acknowledged target; "Also play on workstation speakers" in Settings (default on, the
  previous behaviour) is sent as `localAudioPlayMode` on the next connection.
  The statistics overlay shows queue, output latency, holes and underruns.
  The overlay and the end-of-session log also report decoded level (RMS per
  channel, peak in dBFS, left/right correlation) and every later gain stage
  (route, output channels, system volume, PLANK mixer gain), so a quiet
  stream can be traced to the source, the decode or the output path;
- an opt-in video timing capture (Settings › Debug, independent of the
  overlay): one log line per second, at most 15 minutes per session, with
  Host frame sizes and the count under 2 KiB (a size hint, not proof of unchanged content), arrival
  gaps, decode time, frames replaced before the main thread took them,
  actual drawable presentation times and gaps, distinct acquisition/submission/
  GPU-completion counts, drawable waits and misses, GPU time and
  background state. It attributes slow or hitching video to a stage before
  any buffering, rendering or timer change;
  Live sync and listening acceptance is pending;
- absolute pointer movement, primary click and drag, keyboard forwarding, and
  native mouse-button forwarding for primary, secondary and middle buttons;
- experimental direct mouse input: all available `GCMouse` profiles are watched,
  rather than assuming the current or first profile produces events. While the
  desktop owns input, physical deltas accumulate into absolute Host coordinates;
  pointer lock is not requested or required. UIKit hover, buttons and wheel
  forwarding are suppressed while the raw path owns input. Escape is forwarded
  to the Host and never disables mouse input; desktop appearance enables raw
  input automatically. Controls, departure, backgrounding and inventory changes release held
  buttons; returning to the desktop does not restore a held press. A held drag
  remains owned by its originating profile, and stale callbacks from an old
  inventory are discarded. A persistent “Allow window resizing” toggle in
  the session controls defaults off and sets the UIKit scene's resize policy
  directly. Turning it on allows aspect-preserving resize without resetting
  the current window size. The toggle is independent of mouse focus, controls
  visibility and Wacom attachment. The standalone headset probe
  confirmed that explicitly disabling resizing resolves corner interference.
  Earlier no-resize attempts accidentally set the optional preference to nil;
  the corrected request assigns a typed enum and verifies it before submission.
  Explicitly closing owned controls returns key-window focus to the desktop.
  The operator confirmed Client build 33 resolves mouse corner access with
  resizing disabled. Reconnect/tablet-tip qualification remains separate;
- a controls button above the monitor with the menu expanding downward. Its
  window is explicitly registered with the desktop focus coordinator, keeping
  the Wacom attached while the session's own controls are used;
- a local TCP Wacom Relay link with pinned Relay identity, Host raw-HID
  forwarding, focus suspension and automatic recovery after the Relay
  disconnects;
- signed device and simulator builds from the same source.

## Tablet Relay selection boundary (October 1, 2026)

Relay Setup owns discovery, tablet setup, management authorization, network
configuration and connection testing. PLANK owns its drawing trust, the choice
of a registered Relay and the drawing link itself. Settings offers one
**Tablet Relay** picker: Off, registered Relays by name, an earlier paired
Relay where one exists, and **Set up a Relay…**, which opens Relay Setup
(`plank-relay-setup://`) or says it could not be opened. PLANK has no
discovery, address/port, pairing or reauthorize controls.

**Use in PLANK** upserts and selects the exact Relay by drawing identity;
repeats update its routes. An unknown identity gets PLANK's physical
ExpressKey approval as a one-time registration sheet; only the exact identity
is saved and the link is re-evaluated before registration. Cancel, failure or
mismatch changes nothing. Off starts no Relay preflight, connection or legacy
fallback and keeps approvals. Selection changes during a desktop session apply
at disconnect. Status reads Configured, Connected (authenticated handshake
observed), Unavailable (last attempt failed) or Approval required. Native
PLANK drawing stays on the network link; registering a Relay found over
Bluetooth does not enable Bluetooth drawing. Plan:
`docs/development/plans/relay-picker-boundary-plan.md`.

Approval attempts try the remaining advertised routes after eligible connection,
DNS or network-path failures, preserving the final native error when all routes
fail. Rejected approval, verification/storage failures and cancellation stop the
attempt. Each route is tried at most once under the existing per-attempt deadlines.

The physical ExpressKey sheet for first-time registration remains a compatibility
path. The intended replacement is authenticated Setup-mediated approval of the
Client's distinct public key by the drawing service, with proof of drawing
identity before storing the pin. This enrollment change is not implemented yet;
public handoff URLs alone do not authorize unknown identities. The requirements
and separate-service installation boundary are recorded in the managed Relay's
[handoff guide](https://github.com/instinctual/plank-avp-relay/pull/3).

The app compiles with Xcode 27 and the visionOS 27 SDK while targeting visionOS
26. It has launched on a physical Apple Vision Pro. A live comparison on
September 23, 2026 found moving video smooth with mouse and keyboard input
working after the 60 fps presentation and direct color-conversion changes.
Installation requires the paired headset to remain active and unlocked.

The 2017 Intuos Pro PTH-660 can pair to visionOS over Bluetooth, but in the
physical-device check it produced no pointer or pen input and did not appear
in the app's stylus or mouse device lists. [Wacom supports its mobile pairing
for paper sketching, not pen-tablet input](https://support.wacom.com/hc/en-us/articles/1500006264721-How-do-you-pair-the-Wacom-Intuos-Pro-2017-Paper-Edition-with-a-Mobile-device).
The separate [Linux tablet Relay](https://github.com/cnoellert/plank-tablet-relay)
now carries that same tablet over a local TCP link.
On September 25, 2026, a physical Vision Pro paired with the development NUC
using five ExpressKeys and forwarded pen movement, tip and side buttons, and
varying pressure into GNOME Settings and Flame. Focus suspension and recovery
after a real Relay service restart passed without restarting the desktop.
The NUC runs the Relay as an unprivileged systemd service. After a full NUC
reboot and reinstalling the signed Client with link-loss contact release, a
fresh physical Vision Pro session again confirmed tip clicks and varying
pressure. After removing the headset for one minute, pen movement and pressure
returned immediately on wake. In a live USB hotplug check, the Relay
reattached the tablet without restarting PLANK. Pen movement returned after a
couple of seconds; clicks and varying pressure followed a few seconds later.
Restarting the Relay service while the pen tip was held down in GNOME's tablet
test area ended the stroke cleanly; new pen input worked after reconnection.
The Host showed one Wacom device set after recovery.
The Relay now persists attachment generations; two consecutive service restarts
in one live session produced generations 2 and 3, with tip clicks and varying
pressure after each. The desktop Client's raw-Wacom worker accepts an optional
generation provider, while its existing default behavior is unchanged.

The Client now emits `PLANK Wacom preflight: {JSON}` records for each change to
the six tablet prerequisites: Host raw HID, Host focus suspend, authenticated
Relay link, exclusive raw Wacom ownership, DEVICE and all DESCRIPTOR frames
accepted by the Host transport, and a successful Host ATTACH_RESULT. The
ownership gate requires Relay software version 0.1.1 or later, which reports
attached only after Linux has grabbed every local Wacom event node. This
preflight is a protocol prerequisite; Flame pressure is still a separate live
check. Export the current Vision Pro app log and run:

```bash
python3 scripts/check_visionos_wacom_preflight.py \
  /path/to/exported-vision-pro.log --max-age-seconds 300
```

The checker prints one JSON result and exits nonzero unless the latest record
has all six gates, all three software versions, and `ready: true`. Do not use a
previous session's passing record as evidence for a new test. The 30-minute
endurance session remains pending.

## Deferred settings and feature parity

The [native client feature backlog](plans/visionos-feature-parity-backlog.md)
records the October 1, 2026 request for desktop settings parity: bitrate and
video-quality controls, audio output/input controls, client camera forwarding
with possible AVP Persona/avatar integration, and an inventory of the remaining
desktop options. These are deferred product items, separate from current Relay
connection qualification.

## Qualification backlog

The current development build has virtual-display and stream-frame-rate
choices in saved bookmarks (24, 25, 30, 48, 50, 60, 90, 120 fps presets and
custom 1–240 fps; 60 fps for existing bookmarks),
editable workstation fields, one-active-session gating in the host browser,
and live frame diagnostics confined to the desktop window. The physical
Vision Pro has passed a short live test of hardware-only HEVC 4:4:4 10-bit
decode with native-resolution Metal presentation. The initial negotiated stream
was 60 fps; neither actual display refresh nor sustained presentation rate has
been measured yet.

The first frame-rate bookmark build sent the selected rate in the native
stream request but still launched the Host at 60 fps. The Host requires these
rates to match, so 48 and 50 fps connections failed. Build 10 sends the saved
rate in both requests. The physical Vision Pro subsequently connected and
displayed video at both 48 and 50 fps bookmark settings in build 10. Sustained
delivered frame rate and playback pacing at those settings remain unmeasured.
Build 11 adds an opt-in display-link timing readout and a 96 Hz timing hint for
24/48 fps bookmarks. Compare the automatic and hinted readings on the physical
headset; this does not assert that an app can force the compositor's display
mode. Confirm physical refresh separately with Xcode's Display instrument when
the headset is available to Instruments.
The first visual comparison was inconclusive; no actual display-mode change has
been established.
In the follow-up headset check, switching between PLANK and Mac Virtual Display
returned cleanly in build 12. The operator perceived no benefit from alternate
stream rates and saw visible flicker/judder at 48 fps, so 60 fps remains the
working baseline. A possible pen-tip failure at non-60 fps is unconfirmed;
compare fresh 48/50 and 60 fps sessions with the six Wacom preflight gates and
Host pen-button events before attributing it to stream cadence. The display-link
readout is app callback timing, not proof of the headset's physical refresh.

The September 28 native Client input gate passed several physical-headset
connect/disconnect cycles: the paired Wacom Relay attached before desktop
input started, and the pen worked on each reconnect. This is short-session
acceptance; longer sessions and Relay-offline behavior remain to be checked.
The workstation's Remove action now lives in Edit Workstation behind a
confirmation, away from Start Session. Its placement was confirmed on the
physical headset in build 5; deletion itself was not exercised.

- Qualify the hardware decode path over a sustained session at the usual
  resolution and a shorter 5120x2160 stress run. Measure actual presented fps,
  frame intervals, receive/decode/presentation gaps, end-to-end latency,
  thermal behavior, fallback recovery, and whether the earlier frozen-picture
  failure recurs.
- Investigate intermittent Wacom first attachment when raw-device setup is
  delayed. Subsequent clean session attachments restored tip clicks and
  pressure; capture application-level XI2 events during a failing session
  before changing device mapping or attachment order.
- Rebase the native Vision Pro Client branch onto the current upstream Client
  after preserving the accepted hardware-decode build. Review shared transport
  and submodule changes, then rebuild and rerun the Host, streaming and Wacom
  preflights.
- Measure end-to-end pointer and video latency under sustained use, including
  thermal behavior and frame pacing over longer sessions.
- Isolate tablet latency by measuring capture-to-Client, Client-to-Host, and
  Host-to-visible-frame time. A short A/B comparison with the preflight Client
  and its immediate predecessor felt about the same, so the preflight change
  has no observed latency regression. Investigate the high volume of HEVC
  reference-frame errors seen with the developer console attached. In a
  5120x2160@60 Vision Pro session, thousands of frames reached the Client but
  decoding stalled and the picture froze while remote clicks still worked.
  A temporary repeated-IDR recovery build made dragging unacceptably latent;
  it was removed from the installed Client. Measure receive-queue drops,
  decode time, and frame gaps before choosing a recovery policy.
- Qualify exact-color output with reference charts and gradients on the
  headset, including whether the spatial compositor preserves 10-bit steps.
  Keep the working `xf44` shader path and compare latency and power with the
  FFmpeg fallback under equal conditions.

### September 27 exact-color decode investigation

The 5120x2160 Vision Pro freeze was recorded while the Linux Host used NvFBC,
whose source is 8-bit and expanded to the negotiated HEVC 10-bit 4:4:4 stream.
The Host sent 5,262 frames over roughly 89 seconds with zero QUIC packet loss.
A separate native depth-30 X11/XShm session sent 4,779 frames over roughly 80
seconds. These send counts show sustained Host output in those runs; they do
not measure individual capture or encode latency. Reducing native X11 capture
cost is therefore a separate optimization from the observed Vision Pro freeze.

The earlier Vision Pro path software-decoded GBRP10LE, converted it to 8-bit
BGRA, copies a complete frame into `Data`, then creates a `CGImage` for the
window. A 5120x2160 BGRA frame is 44,236,800 bytes before subsequent copies.
The macOS Client instead maps VideoToolbox 10-bit 4:4:4 pixel-buffer planes to
Metal textures and applies its identity-GBR shader. The `xf44` plane values
must reach that shader without VideoToolbox's ordinary BT.709 RGB conversion.

An isolated, signed Vision Pro test app decoded the owned HEVC 4:4:4 10-bit
chart on the physical headset with hardware-only VideoToolbox sessions. Native
output was `pf44`; requested exact output was `xf44`, with the expected
identity-GBR red-bar codes `0, 0, 1023`. The 8-bit BGRA and half-float RGBA
output requests also succeeded but would apply VideoToolbox colour conversion,
so they are unsuitable for PLANK's exact-colour transport. The user saw a
slightly smoother 10-bit gradient than the 8-bit reference on two half-float
Metal surfaces; that visual check does not prove the compositor preserves all
10 bits.

The native Client now builds with a hardware-only VideoToolbox decoder and an
`xf44`-to-Metal identity-GBR presentation path. A Mac smoke test decoded all
ten fixture frames through the new decoder, with parameter sets delivered in
a separate packet. It falls back to FFmpeg if the hardware session fails;
subsequent frames may require a new keyframe before that fallback shows video.
The first live hardware run decoded and presented continuously (2,655 received,
decoded, and shown frames in the user's capture, with 7.6 ms average decode),
but the user reported a soft image. The Metal layer initially allocated its
drawable at the 1280-point spatial-window size despite a higher-resolution
remote frame. A follow-up build allocates the drawable at the decoded frame's
native pixel size. The user then confirmed sharp Flame detail and smooth
dragging/playback on the physical headset; the photo showed 8,221 frames each
received, decoded, and shown, with 7.6 ms average decode and zero reported
drops or gaps. This is short-run acceptance of the hardware decode and native
resolution presentation path, not a sustained thermal or colour-precision
qualification. In the same run the Wacom pen moved the pointer and its side
button responded, but the tip did not draw in GNOME's tablet test area. The
Host's XInput recorder observed tip button 1 presses, releases, and pressure;
the failure is under investigation and must not be attributed to missing raw
tablet packets. A Host-side hold check showed button 1 remained down at full
pressure. The NUC Relay log also showed an 11-second raw-device attach retry
on a later connection. During that retry, Xorg briefly registered PLANK's
normalized fallback tablet, then removed it when the exact Wacom endpoints
arrived. A stale application tablet binding is a plausible cause, but has not
been established; compare application-level XI2 events before changing button
mapping or declaring a Relay packet loss problem.
In four subsequent connections, exact Wacom attachments (Relay generations
35–38) completed without retries. The user confirmed that closing and reopening
PLANK restored clicks and normal pen behavior immediately. This contrasts with
generation 34's 11-second attach retry and strengthens the device-switch
timing hypothesis without proving it. The observed recovery followed a fresh
session attachment; recovery within the failing session remains unverified.
Preserve the working build and capture application-level XI2 events if the
failure recurs before changing button mapping or the Relay protocol.
On September 28, the failure recurred when the mouse was used before the
Wacom appeared in Linux Settings. The Host's raw evdev and XInput recorders
both received tip contact, pressure, and button-1 press/release. An X11 event
window then received four complete left clicks at the spot the user targeted;
a second window visibly counted both mouse and pen clicks in the same PLANK
session. Reopening GNOME Settings after the Wacom attached restored its test
button and pen drawing. This rules out a general loss of tip packets during
that run, but does not yet identify why the earlier Settings window stopped
responding. An earlier signed Client held mouse pointer, button, and wheel
input once the Host transport was ready until Wacom preflight passed, with a
ten-second fallback if the Relay could not attach. The current Client also
holds keyboard and pen reports and removes that automatic fallback. It shows a
"Connecting Wacom tablet…" message during this wait. In live tests after the
change, the user confirmed pen tip, pen dragging, and mouse input on successive
connections; the final build showed the connection message and all three
inputs worked after it disappeared. This is short-run acceptance of startup
sequencing. The earlier Settings-window failure has not been reproduced after
the change, but its precise GNOME cause and longer-session reliability remain
open. A later September 28 connection again felt as though mouse and pen clicks
failed on the Linux wallpaper. A large X11 click-test window in that same
session visibly counted both input sources. This confirms that those presses
reached Linux; it does not establish why the wallpaper or the previous small
application target looked unresponsive.
The Host cursor shape is now capped to a minimum half-size display scale
(a 24-pixel Host arrow draws at about 12 points in the current spatial window).
The received/decoded/shown
frame counts and decoder name are now hidden by default and available through
Settings → Debug Overlays → Show video decoding statistics.
Closing the spatial desktop window previously had no onDisappear session
cleanup. The development Client now disconnects the stream when that window
closes, and its browser waits for the old transport task to finish before
offering another session. This builds and is installed on the Vision Pro, but
normal close/reconnect acceptance is pending. It is a lifecycle correction,
not yet a demonstrated cure for the intermittent tablet symptom.
The September 28 Mac Client comparison used an older PR7 Contact Test build.
Its log recorded exclusive Wacom ownership at 11:20:14, release three seconds
later, and a corresponding Host raw-HID suspend. It attached again after
focus returned. A second release followed toolbar minimize. That comparison
shows a focus/suspend path worth investigating; it does not isolate a Host
tablet decoding defect. The Host and Mac Client were then moved to Alan's
matched, signed upstream 1.1.024 packages from source commit 89afd664, with
the Host service reporting ready. The Mac Wacom check on that pair is pending.
The hardware decoder also fell back to FFmpeg mid-session while received
frames continued and the picture froze. The candidate Client now requests a
fresh IDR when the hardware decoder fails or decoding stalls, and waits for
that keyframe before decoding again. This recovery path builds and is installed
but still needs an observed natural-failure test; rising receive counts alone
do not prove that the displayed picture is current.
The Vision Pro decoder's compressed-frame input now reserves and zeroes the
FFmpeg-required padding after each packet; this change builds, but has not
received a live streaming acceptance test. Do not attribute the freeze to
missing padding without that evidence.
- Arbitrate gaze/pinch and Bluetooth mouse input so switching sources does not
  create duplicate movement or button events.
- Present local pointer shapes that match the remote cursor instead of the
  generic visionOS focus indicator.
- Verify primary, secondary and middle button press/release behavior on the
  physical headset, including held-button release during interruption.
- Complete keyboard modifier, delete/backspace and focus qualification. Keep
  physical keyboard conventions explicit: visionOS reports the top-right PC
  keys as F13-F15, so PC mode restores Print Screen, Scroll Lock and Pause;
  Apple Extended mode preserves literal F13-F24. Carry the same selectable
  distinction into the macOS desktop Client.
- Qualify discrete mouse-wheel and continuous trackpad scrolling, including
  direction, rate and horizontal scrolling.
- Add host audio output and verify sleep, wake and reconnect behavior.
- Qualify the Wacom Relay across longer Vision Pro sleeps and sessions,
  including repeated tablet hotplug cycles.
- Qualify reconnect after a normal Vision Pro disconnect. A September 27
  recording showed a generic format error followed by a Try Again path that
  discarded the saved sign-in state. Host source and the desktop Client show
  that an XML authentication failure from a replacement Host worker could
  account for the format error. The Vision Pro client now recognizes the Host's XML
  status envelope, refreshes authentication over the existing pinned TLS
  session, and offers Retry Session without prompting for credentials. The
  signed build passed compilation; live disconnect/reconnect acceptance and
  Host reservation-release timing still need verification.
- Evaluate pairing the Wacom tablet to the headless Relay NUC over Bluetooth
  instead of USB. Confirm that Linux exposes the raw reports, pad keys, and
  pressure needed by the existing Host path before treating it as supported.
- Implement and qualify a Bluetooth LE link between the Relay NUC and Vision
  Pro, using the same authenticated session semantics as the local TCP link.
  Alan's [`visionos-tablet-setup` Relay branch](https://github.com/instinctual/plank-tablet-relay/tree/visionos-tablet-setup)
  provides a separately packaged BLE readings and setup workflow, not yet
  production raw-HID forwarding. Its physical Intel 7265/BlueZ/visionOS 27
  qualification found an opt-in controller address-resolution workaround and
  a BlueZ battery-plugin conflict; port the bounded startup and recovery
  behavior before testing the production path. The running USB/TCP Relay on
  the development NUC remains the working baseline. The same branch fixes
  re-approval of an already saved headset key; assess that independently of
  the BLE transport work.
- Discover a headless Relay without knowing its IP address in advance, then
  pair it through the tablet's ExpressKeys. The signed Client now browses
  `_plank-tablet._tcp`, and the NUC advertises its identity and pairing-window
  state. The running Relay also watches for the five-second ExpressKey chord.
  Live acceptance of discovery and physical pairing remains pending. The
  current Mac and NUC are on different routed subnets, where local multicast
  does not reach Portofino; manual address remains the fallback there.

On September 27, a Vision Pro screen recording showed a saved Nearby Relay
marked “not nearby,” a disconnected live link, and a failed Re-pair attempt.
The Relay service, USB Wacom and TCP listener were healthy, but its journal
showed no new authenticated session attempt. The headset's saved settings
selected Bonjour while retaining the NUC's routable manual address. The
previous Client always chose the unresolved Bonjour endpoint for the live
link; it never tried that saved address. Re-pair also showed a raw connection
reset when the Relay's short pairing window was closed and left the Settings
status looking both paired and disconnected. The development build now tries
the pinned manual address after a bounded Bonjour attempt, keeps the same
Relay identity pin on that fallback, bounds pairing-connect waits, preserves
saved trust if re-pairing fails, and separates saved pairing from live-link
status in Settings. It is installed on the physical headset but still needs a
live reconnect and pen-pressure acceptance test.

On September 28, the standalone Tablet Setup BLE lab passed on the development
NUC's Realtek Bluetooth controller and physical Vision Pro. Its unauthenticated
transport check returned matching 64-, 512-, and 1024-byte payloads (three
round trips). Initial headset approval consistently disconnected after the
first button press. A controller trace showed BlueZ reading the headset's
Battery Level, receiving an authentication error, attempting OS-level pairing,
then terminating the BLE connection locally. A reversible runtime BlueZ
`--noplugin=battery` override removed that conflict; controller address
resolution did not need a workaround on this radio. Three short Wacom center
button presses then completed the app's authenticated pairing. Live position,
pressure, and button readings worked with the Wacom on USB and after bonding
it to the NUC over Bluetooth Classic HID. The tablet sleep/wake check resumed
all readings without re-pairing. This qualifies the separate BLE readings lab,
not PLANK's production raw-HID forwarding over BLE. The existing TCP/USB
Relay remains the desktop-session baseline.

The native Client treats a saved Wacom pairing as
part of session startup. It presents a blocking tablet-connection screen and
holds mouse, keyboard, scroll, and pen reports until the current Relay
generation passes the six Host/Relay preflight checks, including the Host's
attachment acknowledgment. Attachment and control messages continue so the
tablet can become ready. There is no silent timeout; the operator may explicitly
continue that session without Wacom. A lost Relay closes the input gate again
and releases any mouse buttons or keys already held at the Host. Disconnect and
reset also keep new connections blocked until the old transport worker and
Relay link close; the next Start issues a fresh Host launch and transport.
The Host may still be finishing its reservation after the transport exits, so
the existing bounded Host-busy retry remains necessary. The input-policy
transitions pass local
tests, and several short physical-headset reconnects passed. Sustained use,
Relay restart, and Relay-offline handling still need live qualification.

The operator reports a further input-routing correlation: repeated reconnects
worked when the physical mouse was dedicated to Vision Pro and Mac Virtual
Display stayed closed. Earlier pen or mouse failures happened with Mac Virtual
Display open and/or the mouse paired to the Mac; those two changes were not
isolated. [Apple documents](https://support.apple.com/en-gb/guide/apple-vision-pro/tan357ede966/26/visionos/26)
that Mac Virtual Display can share the Mac pointer across Mac and visionOS
windows. PLANK currently suspends the tablet Relay when its desktop scene
becomes inactive, then reattaches on return. The report suggests a focus and
reattachment interaction but does not establish it as the cause. Reproduce
with three controlled cases: PLANK alone with a Vision Pro mouse, Mac Virtual
Display open with a Vision Pro mouse, and Mac Virtual Display open with a
Mac-shared mouse. Record scene activity and the Wacom preflight gates through
each switch before changing Relay or Host input behavior.

A controlled Vision Pro-mouse run with Mac Virtual Display open narrowed the
failure: after switching back to PLANK, the Wacom tip still clicked, but the
Host cursor stopped following ordinary mouse movement. A mouse click moved the
Host cursor to the mouse position; subsequent pen movement moved it to the pen
position again. Closing Mac Virtual Display restored mouse tracking. The
Client uses a recent `GCMouse` motion callback to distinguish physical mouse
hover from gaze hover, so a missed mouse callback after window handoff can
explain this behavior. The next build refreshes that callback on scene
activation and when the PLANK window becomes key. Its first live test hit a
different focus-return failure: after the Relay suspended, PLANK remained on
“Connecting Wacom tablet…” instead of resuming, so mouse recovery could not
be judged. A follow-up build also resumes the Relay when the desktop window
becomes key. The operator's next short run found switching generally smooth when the mouse
remained paired to Vision Pro, including pen input. Keeping the mouse paired to
the Mac and using it through Mac Virtual Display remains a separate unqualified
path; the observed mouse-pointer handoff issue can still occur there.

Build 11 exposed another intermittent focus-return stall at “Connecting Wacom
tablet…”. The Relay log showed a completed Host attachment, but the Client's
preflight could still wait forever: an attached Relay status can reach the
preflight before the transport's asynchronous DEVICE-send callback, which then
reset the independent ownership gate to pending. Build 12 preserves that Relay
ownership fact across the send callback. A local regression test covers this
event order and passes; the physical-headset focus-return retest passed.

## Build

Device:

```bash
cmake -G Xcode \
  -S visionos-native \
  -B build/visionos-native-xcode \
  -DCMAKE_SYSTEM_NAME=visionOS \
  -DCMAKE_OSX_SYSROOT=xros \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DPLANK_TRANSPORT_DIR=/path/to/plank/protocol/plank-transport \
  -DPLANK_RELAY_SOURCE_DIR=/path/to/plank-tablet-relay \
  -DPLANK_RELAY_SODIUM_PREFIX=/path/to/visionos/libsodium \
  -DPLANK_OPUS_DIR=/path/to/visionos/libopus

xcodebuild \
  -project build/visionos-native-xcode/PlankVision.xcodeproj \
  -scheme PlankVision \
  -destination 'platform=visionOS,id=<YOUR_DEVICE_ID>' \
  -configuration Debug \
  -allowProvisioningUpdates \
  build
```

Build `PLANK_OPUS_DIR` with `scripts/build-visionos-opus.sh device <prefix>`
(`simulator` for the simulator). It verifies the xiph.org SHA-256 of
opus-1.6.1 before building. Without it the app builds but cannot decode Host
audio, and every session fails negotiation with a clear decoder error. The
focused audio checks run on the Mac against a `macos` build of the same
archive:

```bash
scripts/build-visionos-opus.sh macos /path/to/macos/libopus
cc -std=c11 -O0 -Wall -Wextra -Werror -DPLANK_OPUS_AUDIO=1 \
  -I/path/to/macos/libopus/include/opus -Ivisionos-native/Bridge \
  visionos-native/Tests/test_audio_pipeline.c \
  visionos-native/Bridge/PlankAudioDecoder.c visionos-native/Bridge/PlankAudioRing.c \
  /path/to/macos/libopus/lib/libopus.a -lm -o test_audio_pipeline && ./test_audio_pipeline
swiftc -Onone -parse-as-library visionos-native/Sources/Models/PlankAudioFormat.swift \
  visionos-native/Tests/PlankAudioFormatTests.swift -o audio-format-tests && ./audio-format-tests
```

Simulator:

```bash
cmake -G Xcode \
  -S visionos-native \
  -B build/visionos-native-simulator \
  -DCMAKE_SYSTEM_NAME=visionOS \
  -DCMAKE_OSX_SYSROOT=xrsimulator \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DPLANK_TRANSPORT_DIR=/path/to/plank/protocol/plank-transport
```

## Implementation sequence

1. Qualify the native launch, transport negotiation and first-frame probe on a
   physical Apple Vision Pro.
2. Decode the received 10-bit 4:4:4 HEVC frames through the existing FFmpeg
   path and present them on a native Metal surface.
3. Add audio receive and native output.
4. Translate visionOS focus, pointer, keyboard and controller events into the
   existing remote-input path.
5. Qualify reconnect, sleep/wake, audio route changes, resize, sustained frame
   pacing and thermal behavior on the physical headset.

Streaming is not considered implemented until the native target connects to a
real Host and independently verifies video, audio and input on the headset.

## Next integration target: Relay connection handoff

The standalone Setup app already learns fresh network routes through its
authenticated Relay management connection, including Bluetooth rendezvous when
multicast discovery cannot cross subnets. The native Client still maintains a
separate saved drawing endpoint and trust record. Changing the Relay from
Ethernet to Wi-Fi currently requires a manual address selection in the Client.
There is no implemented Setup-to-Client handoff; management authorization and
drawing authorization are separate today.

Proposed operator flow:

- Setup owns tablet pairing, network configuration and Relay administration.
- A **Use in PLANK** action offers the configured Relay to the Client.
- PLANK selects the Relay by its verified identity and displays its name and
  actual active network path. Address and port entry remain an advanced fallback.
- Reconnection refreshes available routes without treating an address change as
  a new Relay or requiring the operator to repeat pairing.

Implement a versioned handoff contract before adding the button. It must
distinguish management and drawing endpoints and identities, retain the current
authenticated drawing transport, and never put private keys or pairing secrets
in a launch URL. Incoming route suggestions are untrusted until the Client
verifies the saved drawing identity. A first-time authorization flow needs an
explicit design; the existing Setup approval does not automatically authorize
the independent drawing service. Do not import tablet-management UI or capture
ownership into PLANK.

Acceptance must cover changing network addresses, reachable routes across
subnets, missing or unreachable Relays, a mismatched identity, and a network
interface disappearing during an active stroke. Starting another connection
must release the old transport and input state before resuming tablet input.
This section describes planned work, not an implemented handoff or seamless
network failover.

The coordinated implementation assignments and gates are in
[Relay connection handoff execution plan](plans/relay-connection-handoff.md).
The first slice updates routes for an already approved drawing identity; new
Client enrollment remains explicit and separate.


### Independent reliable-control reception candidate

Cursor and tablet-control reception now runs on its own bounded-wait thread,
starting after stream negotiation and before decoder creation. Session
cancellation stops new reads, and teardown joins the reader before destroying
its transport. Unsupported presentation events are distinguished from a real
receive timeout. Cursor presentation retains only the newest position and
completed shape; reliable tablet control and shape chunks retain their order.

This candidate requires transport commit `ee810fe`, which waits for receive
capacity without increasing the 64-record / 8-MiB bounds or evicting reliable
records. A consumer that makes no space for two seconds still fails explicitly.
There is no wire-format, negotiation, Host-installation or Relay change.

Focused checks cover stalled-video reception, ordered bursts through encrypted
endpoints in both directions, the existing stalled-consumer failure, ignored
events, cancellation and repeated receiver teardown. Headset session stability
and tablet reattachment on reconnect remain pending live acceptance. Audio is
excluded from this comparison.


### Playback housekeeping candidate

Workstation discovery pauses while a desktop session is starting or active,
resumes when the visible browser returns to an idle state, and ignores callbacks
from a stopped discovery generation. Video progress collection and UI publication
run only while the decoding-statistics overlay is enabled. Connection phase is
published on lifecycle transitions, rather than periodically during playback.

The periodic display-timing measurement and its two-second UI summary are removed.
The explicit 96 Hz test hint remains available for 24/48 fps sessions, labelled as
a request rather than a measured refresh rate. Normal playback creates no display
probe. Decoder recovery, Metal presentation, native transport statistics and Relay
heartbeats are unchanged. These changes remove unnecessary recurring work; their
effect on the reported small playback pauses requires headset comparison.

### Bookmark mode changes and mouse speed (build 35 candidate)

Saving a resolution or frame-rate change for the currently authenticated
workstation requires **Close Session and Save**. Cancel leaves both the
bookmark and the login intact. Confirming clears retained Client authentication
and waits for the stream worker and Relay connection to finish closing before
saving; the next connection requires fresh sign-in and Wacom setup. Address
and port changes use the same rule. Ordinary reconnects with unchanged display
settings retain the existing login. This does not log out the Linux desktop.
The native disconnect still uses its existing bounded shutdown; Client closure
is not proof of an acknowledged Host release. Live mode-change acceptance is
pending.

Session controls include **Mouse speed**, from 25% to 150%, defaulting to 100%.
It applies immediately to raw mouse movement and persists across sessions.
Button, wheel, pen and UIKit hover paths retain their behavior. Movement is
accumulated in canvas points, so a smaller canvas takes less physical movement
to cross at the same speed. Resize disabling remains available independently.
Focused movement and bookmark-policy checks pass; headset acceptance is pending.

Build 36 corrects raw mouse availability: Escape is forwarded to the Host rather
than disabling the movement path. Desktop appearance automatically enables raw
input after a prior departure. Focus loss, session controls and backgrounding
still gate movement and release held buttons. Session controls no longer contain
a conditional “Use mouse in desktop” button. Mouse speed remains a persisted
setting; live Escape and reconnect acceptance is pending.

After the session controls close, the Client refreshes the canvas pointer style
after restoring desktop key-window focus, and again when raw input eligibility
changes. Native controls retain their system pointer while open. Whether this
eliminates the reported lingering circle needs the headset retest.

## Setup-mediated drawing enrollment candidate

Unknown drawing identities now use Continue in Relay Setup followed by an
explicit Allow PLANK, rather than the tablet-specific ExpressKey sequence.
The signed apps exchange only a protected public approval receipt. PLANK proves
its key and the drawing identity through the separate PLEN/1 Noise exchange
before saving a pin and registering the Relay. Existing app-private keys, pins,
picker choices and session input paths are preserved. Cancel, expiry and an
unapproved or substituted callback cannot save a new pin.

Build the matching managed Setup and raw daemon candidate described in
`docs/setup-drawing-enrollment.md` in the raw Relay repository. This slice uses
an existing TCP route for enrollment; registered-Relay Bluetooth transport
selection remains separate. Source checks and signed provisioning pass; live
cross-app registration, cancellation and reconnect acceptance are pending.
