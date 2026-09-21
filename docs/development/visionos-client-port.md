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

The first release does not include immersive presentation, Wacom forwarding,
macOS global shortcuts, Spaces-style fullscreen or one native window per remote
monitor. Multi-monitor hosts begin with one selected output or one scaled canvas
inside the PLANK window.

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
- a visible connection state boundary for the upcoming core integration;
- signed device and simulator builds from the same source.

The app compiles with Xcode 27 and the visionOS 27 SDK while targeting visionOS
26. It has launched successfully in the Apple Vision Pro simulator. A signed
physical-device build has been produced; installation requires the paired
headset to remain active and unlocked.

## Build

Device:

```bash
cmake -G Xcode \
  -S visionos-native \
  -B build/visionos-native-xcode \
  -DCMAKE_SYSTEM_NAME=visionOS \
  -DCMAKE_OSX_SYSROOT=xros \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0

xcodebuild \
  -project build/visionos-native-xcode/PlankVision.xcodeproj \
  -scheme PlankVision \
  -destination 'platform=visionOS,id=00008142-001030AC01F1401C' \
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
  -DCMAKE_OSX_ARCHITECTURES=arm64
```

## Implementation sequence

1. Extract a Qt-free pairing and host-session facade from the current client.
2. Connect discovery and saved hosts to real host identity and pairing state.
3. Bridge the session lifecycle into the native app.
4. Present decoded frames through a native Metal surface.
5. Translate visionOS focus, pointer, keyboard and controller events into the
   existing remote-input path.
6. Qualify reconnect, sleep/wake, audio route changes, resize, sustained frame
   pacing and thermal behavior on the physical headset.

Streaming is not considered implemented until the native target connects to a
real Host and independently verifies video, audio and input on the headset.
