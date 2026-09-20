# visionOS Client Port

## First usable target

The first visionOS release is a native, low-immersion PLANK Client that runs in
the visionOS Shared Space. It keeps the existing workstation browser, pairing,
authentication, transport, video, audio, and session UI, then presents one
remote desktop canvas in a resizable window.

The first release should support:

- discovery, manual bookmarks, pairing, authentication, and reconnect;
- one remote desktop stream rendered through VideoToolbox and Metal;
- host audio through SDL;
- gaze and tap as pointer input through SDL's visionOS backend;
- Bluetooth keyboard, trackpad, mouse, and controller input supported by SDL;
- both the visionOS simulator and an Apple Vision Pro device build.

The first release does not include immersive presentation, raw Wacom
forwarding, macOS global shortcuts, macOS clipboard integration, Spaces-style
fullscreen, or one native window per remote monitor. Multi-monitor hosts begin
with one selected output or one scaled canvas in the PLANK window.

## Why this shape

Qt 6.11 supports native visionOS applications and documents both simulator and
device builds. SDL 3 has a visionOS UIKit backend plus Metal, pointer, keyboard,
game controller, and audio support. PLANK already uses Qt Quick, SDL 3,
VideoToolbox, Metal, and a Rust static transport library, so the port can retain
the existing client architecture.

The desktop macOS build also contains AppKit, Carbon, ApplicationServices,
CGDisplay, and IOKit Wacom code. Those APIs are not part of the visionOS target.
The qmake scopes therefore separate reusable Apple media code from macOS desktop
integration instead of treating every `macx` build as macOS.

References:

- [Qt: Getting Started With Apple Vision Pro](https://doc.qt.io/qt-6/qt3dxr-quick-start-guide-applevisionpro.html)
- [Apple: Get started with visionOS](https://developer.apple.com/visionos/get-started/)
- [SDL platform support](https://github.com/libsdl-org/SDL/blob/main/docs/README-platforms.md)

## Build inputs

Qt does not publish a binary visionOS package. Build Qt from source for each
target and keep a matching host Qt build for its build tools.

| Input | Simulator | Device |
| --- | --- | --- |
| Apple SDK | `xrsimulator` | `xros` |
| Qt platform | `macx-visionos-clang` | `macx-visionos-clang` |
| Rust target | `aarch64-apple-visionos-sim` | `aarch64-apple-visionos` |
| PLANK dependencies | built for `xrsimulator` | built for `xros` |

Set these paths before configuring PLANK:

```bash
export PLANK_QT_HOST_PATH=/path/to/qt-host
export PLANK_QT_VISIONOS_PATH=/path/to/qt-visionos
export PLANK_VISIONOS_DEPS=/path/to/visionos-dependency-prefix
export PLANK_RUST_TARGET=aarch64-apple-visionos-sim
scripts/check-visionos-toolchain.sh
```

`PLANK_VISIONOS_DEPS` must contain target builds of SDL 3, SDL_ttf, OpenSSL,
FFmpeg, libswresample, and Opus. Existing files under `libs/mac` are macOS
artifacts and must never be linked into a visionOS app.

The current qmake files provide the first platform boundary. Qt's documented
deployment route produces an Xcode project and deploys from Xcode. Once the
target Qt and dependency builds exist, the configure attempt will determine
whether the application target should remain on qmake or move to a small CMake
wrapper while retaining the existing source lists.

## Implementation phases

### 1. Compile and launch

- Configure for `xrsimulator` without AppKit, Carbon, ApplicationServices, or
  IOKit sources.
- Launch the Qt shell in one Shared Space window.
- Browse and authenticate to a Host.

### 2. Stream and input

- Decode H.264 and HEVC with VideoToolbox.
- Render the stream with the existing SDL Metal renderer.
- Play audio and forward gaze/tap plus Bluetooth input.
- Release held input on focus loss, interruption, and disconnect.

### 3. Device qualification

- Sign and run on Apple Vision Pro.
- Exercise eye targeting, tap, pinch-drag, and a Bluetooth keyboard/trackpad on
  the available Apple Vision Pro, rather than treating simulator input as proof.
- Test local-network discovery and a Tailscale/manual bookmark.
- Verify reconnect, sleep/wake, audio route changes, window resize, sustained
  frame pacing, and thermal behavior.

### 4. Later capabilities

- Decide how remote multi-monitor sessions map to visionOS windows.
- Evaluate clipboard support using visionOS APIs.
- Evaluate immersive presentation only after the Shared Space client is stable.
- Revisit tablet input if visionOS exposes a qualified device path.

## Current gate

Portofino currently has Apple command-line tools, but no full Xcode selection,
visionOS SDK, simulator runtime, or target Qt build. Source separation and
preflight checks can be reviewed here; compilation and runtime claims remain
blocked until those tools are installed.
