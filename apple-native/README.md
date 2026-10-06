# Native Apple client pilot

This is an isolated Apple silicon macOS 15+ pilot built from the native Vision
Client engine. It uses SwiftUI and AppKit, the existing VideoToolbox recovery,
the exact-colour Metal presentation, native transport, and stereo Opus audio.
The target links no Qt or SDL. It has a separate application identity and
bookmark domain; it does not import existing applications' private state.

The pilot is not a shipping replacement for the desktop Client. A signed build
and passing checks do not qualify streaming or physical tablet behavior.

## Wacom boundary

The initial Mac UI offers **Off** or **USB Wacom on this Mac**. Source selection
applies on the next connection. Relay services and protocols remain unchanged.
The existing Relay engine is retained, but Mac enrollment and its UI are not
part of this first slice.

Direct capture compiles the existing Mac raw-HID worker with an injected native
sender. It preserves physical descriptors, report IDs, Host GET/SET/OUTPUT
replies, exclusive ownership, generation checks, bounded asynchronous device
I/O, and release barriers. The normalized transport required by first-generation
PTH-x51 tablets is not implemented by this pilot. Those devices must not be
represented as supported exact raw-HID devices.

macOS Input Monitoring permission is granted through the normal system prompt.
No privileged helper or privacy-database modification is used. Capture begins
only after Host feature negotiation and desktop focus. Session controls belong
to the desktop window. Leaving that window releases held keyboard/mouse input
and requests physical tablet release. Disconnect waits for capture release and
bounded submission of queued release messages before stopping the transport.
Late callbacks cannot use the destroyed Swift sender context.

## Desktop presentation

The remote cursor is drawn in a separate AppKit view above the video. Positions
received before the first cursor shape use an arrow at the Host position;
the local pointer remains visible until a replacement is available. An explicit
Host request to hide its cursor is respected. Stale positions from a previous
resolution are not drawn into the new canvas.

The desktop's Full Screen toolbar button and Control-Command-F enter or leave
native macOS full screen. That shortcut stays local rather than being sent to
the workstation. The green window control is enabled too. Full screen hides
the menu bar, Dock and toolbar until the pointer reaches their screen edge.
These are per-window presentation options, not changes to system preferences.

Session controls restore the normal Mac pointer and keep their keyboard/mouse
events local. Opening them releases held desktop keyboard/mouse input without
releasing the Wacom. Closing them returns desktop input routing.
Pointer hiding follows the topmost view under the mouse, so a revealed
full-screen toolbar uses the native arrow even when it overlaps the video.

## Build

Initialize the existing common-C submodule. Supply compatible dependency inputs:

- `PLANK_TRANSPORT_DIR`: accepted `plank-transport` Cargo source;
- `PLANK_FFMPEG_DIR`: Apple silicon macOS 15 FFmpeg prefix;
- `PLANK_OPUS_DIR`: pinned libopus 1.6.1 macOS prefix;
- `PLANK_RELAY_SOURCE_DIR`: matching raw drawing Relay crypto source;
- `PLANK_RELAY_SODIUM_PREFIX`: libsodium 1.0.22 macOS 15 static prefix.

Use `scripts/build-macos-native.sh <build-dir>` with those environment variables.
The build isolates its Cargo outputs by deployment target. Bundle/sign with
`scripts/stage-macos-native.py`, supplying the FFmpeg prefix, license source
folders and a signing identity. Local staging does not notarize or publish.

Run `scripts/test-macos-native.sh <output-dir>` for focused production policy,
Wacom callback lifetime, preflight, decoder recovery and tablet-input checks.
The worker callback check constructs the production Swift session on the main
actor and invokes its sender through the production C wrapper on a foreign
thread. It also checks queue refusal and callback revocation after disconnect.

## First live acceptance

Use a test workstation with the existing accepted Host package. Close any other
Client that owns the USB Wacom. Keep the existing network unchanged.

1. Start the pilot, add the workstation, sign in, and open the desktop. Grant
   Input Monitoring when macOS asks, restarting the pilot if required.
2. Check hardware decoder selection in statistics, exact-colour video and
   audible left/right stereo. A hardware capability failure must be visible.
   Check the remote cursor is visible, then enter/leave full screen and retest
   pointer placement at the canvas edges.
3. With the Wacom attached directly by USB, verify hover, light/firm pressure,
   tip taps, held drags, side buttons and supported ExpressKeys. Check the log's
   six preflight gates rather than inferring attachment from cursor movement.
4. Change volume/bitrate in the toolbar popover while drawing; capture should
   stay owned. Switch to another app: capture must release. Return and retest.
5. Disconnect while a tip/button is held, then reconnect without using the
   mouse first. No stuck button or old generation may survive. Also test one
   resolution/timing change with the existing close-and-sign-in warning.
6. Unplug/replug USB and quit during drawing. Physical ownership must return
   to macOS and reacquire only for a fresh active session.

Do not change the Host to make this pass. Native queue-pressure and periodic
stutter issues remain separate; preserve any terminal failure evidence.

## iOS and iPadOS

Initial shared-model, recovery and Bluetooth source typechecks passed during
the feasibility audit. There is no linked or qualified iOS app yet. A mobile
pilot needs UIKit presentation/audio/lifecycle adapters, an explicit input
scope, and Relay enrollment. It must use the Relay raw-HID path for Wacom;
this Mac IOHID capture worker is not an iOS implementation. Validate the Mac
engine before extracting a broader shared Apple module.
