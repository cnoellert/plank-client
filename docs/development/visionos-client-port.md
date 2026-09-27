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
- live HEVC 10-bit 4:4:4 video from a physical Linux Host, decoded by FFmpeg;
- direct planar 10-bit to BGRA conversion on ARM and a native UIKit layer that
  presents the latest complete frame at up to 60 fps;
- a separate, plain remote-desktop window with Standard and Wide single-display
  modes and aspect-preserving resize;
- absolute pointer movement, primary click and drag, keyboard forwarding, and
  native mouse-button forwarding for primary, secondary and middle buttons;
- a local TCP Wacom Relay link with physical ExpressKey pairing, pinned Relay
  identity, Host raw-HID forwarding, focus suspension and automatic recovery
  after the Relay disconnects;
- signed device and simulator builds from the same source.

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

## Qualification backlog

- Rebase the native Vision Pro Client branch onto the current upstream Client
  after the pen-latency comparison. Review shared transport and submodule
  changes, then rebuild and rerun the Host, streaming and Wacom preflights.
- Measure end-to-end pointer and video latency under sustained use, including
  thermal behavior and frame pacing over longer sessions.
- Isolate tablet latency by measuring capture-to-Client, Client-to-Host, and
  Host-to-visible-frame time. A short A/B comparison with the preflight Client
  and its immediate predecessor felt about the same, so the preflight change
  has no observed latency regression. Investigate the high volume of HEVC
  reference-frame errors seen with the developer console attached.
- Evaluate VideoToolbox and a native pixel-buffer or Metal path if further
  performance work is warranted; the current UIKit layer and direct color
  conversion passed the live smooth-playback check.
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
- Evaluate pairing the Wacom tablet to the headless Relay NUC over Bluetooth
  instead of USB. Confirm that Linux exposes the raw reports, pad keys, and
  pressure needed by the existing Host path before treating it as supported.
- Implement and qualify a Bluetooth LE link between the Relay NUC and Vision
  Pro, using the same authenticated session semantics as the local TCP link.
- Discover a headless Relay without knowing its IP address in advance, then
  pair it through the tablet's ExpressKeys. Keep manual address entry as a
  fallback when local discovery is unavailable.

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
  -DPLANK_RELAY_SODIUM_PREFIX=/path/to/visionos/libsodium

xcodebuild \
  -project build/visionos-native-xcode/PlankVision.xcodeproj \
  -scheme PlankVision \
  -destination 'platform=visionOS,id=<YOUR_DEVICE_ID>' \
  -configuration Debug \
  -allowProvisioningUpdates \
  build
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
