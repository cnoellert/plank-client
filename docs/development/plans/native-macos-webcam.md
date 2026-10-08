# Native Mac webcam: first source/sink pair

Status: component proof plus isolated transport and Mac source candidates; not
a shipping Client feature or Host release. Accepted Mac build 24 remains the runtime checkpoint. The camera lab
does not link into either product, replace transport, capture a physical camera,
or modify an artist's workstation.

## Scope

One selected Mac camera, 1280 × 720 at nominal 30 fps, hardware H.264 encoding,
one authenticated reverse camera lane, and one Linux virtual V4L2 device.
Start off. Require an explicit camera choice and normal macOS camera consent.
Do not add microphone forwarding, Persona, automatic camera selection, multiple
cameras, 10-bit capture or 1080p in the first implementation.

The receiver is a Linux application that consumes V4L2 camera devices. Chromium
getUserMedia is the first disposable compatibility target. An artist's actual
application needs a named acceptance pass; remote desktop or Flame painting is
not evidence that a camera-consuming application accepts the stream.

## Existing boundaries

At root `66f5c2a`, the camera lane supports Ubuntu Client → macOS Host and
unchanged native-compressed capture, not a Mac software-generated bitstream.
The native pilot uses transport `e532a5e`, which has no camera ABI. Host 1.1.030
source `b8308a4` has no Linux camera receiver/device implementation. This feature
therefore needs a root protocol/capability change and Linux Host adapter as well
as a Mac Client adapter. It cannot be delivered by enabling one Client switch.

The [component lab](../../../scripts/camera-lab/README.md) proves smaller pieces
without weakening those contracts. It is deliberately outside the production
build. The existing Wacom worker, session controls, displays and transport pin
are untouched.

## Contract proposal for review

Keep PCAM v1 unchanged. Introduce a separately negotiated encoded-source
capability and versioned metadata before accepting Mac-generated H.264. Do not
send this output to a camera-v1-only peer or reuse that peer's driver-sequence
field as an invented V4L2 sequence. An old peer must keep camera unavailable
while its existing desktop/audio/input session proceeds.

The new metadata must identify the capture platform, encoder provenance,
source format and explicit color primaries/transfer/matrix/range independently
of V4L2 numeric enums. Keep activation generation, increasing frame ordinal,
actual monotonic capture time, discontinuity and independent-frame semantics.
Map declared output color only after validating sample attachments and H.264
parameter sets; reject conflicting/unknown data rather than guessing.

Wire layout and capability names are not frozen in this proposal. Review them
in the root repository together with the existing camera C/Rust fixtures and
sample validators. Reuse endpoint allocation, CAM1 framing, authenticated
controls, bounded recovery and optional-failure semantics where they remain
valid. Keep encoding/decoding in platform adapters, outside transport.

## Mac capture and encoding

The first source uses public AVFoundation NV12 capture and VideoToolbox H.264.
It requires hardware encoding; failure reports unavailable rather than silently
falling back to CPU work beside desktop decoding. Limit pending capture/encode
work to two frames and check age against the existing 150 ms camera budget.
Drop with a discontinuity and request a new independent frame after an expired
reference. Disable frame reordering. Include SPS/PPS with independent frames
and validate each length-prefixed NAL before Annex B adaptation.

Capture runs only after matching Host acknowledgement. Off, disconnect,
camera loss, application background/sleep and a retired generation stop capture
and revoke submission. A stale encoder callback cannot reactivate the source.
Changing a camera starts a new generation; do not choose another device if the
selected camera vanishes. UI names the source and shows an active indicator.
No camera enumeration permission or status is treated as proof that capture is
authorized for the signed Client.

## Linux receive/device adapter

Independently validate the H.264 dimensions, framing, generation, timestamps,
color and bounded payload before decoding. Keep at most three pending frames
with the existing 150 ms age gate. One decode job may be in flight; revocation
must clear admission even if that job is blocked. Any late completion is discarded.

Decode to a conventional YUYV V4L2 output for initial compatibility. Only one
authenticated session producer may own the selected PLANK camera. Open only
a verified PLANK-owned virtual device, never a physical camera. Device permissions
belong to the Host worker's session owner, not every local user.

No producer means no advertised capture capability. On a stall, replace the old
scene with a generated blank image rather than replaying it indefinitely; a new
independent frame is required before resuming. Off/disconnect removes/revokes the
camera and closes its device, decode state and queues. The lab's driver timeout
is a feasibility mechanism, not a production privacy/lifetime contract.

v4l2loopback requires matching kernel headers/modules and a deployment/signing
policy. Prepare a separate Host package proposal and exact rollback before a
workstation install. Ubuntu runner results do not qualify Rocky, a future kernel
upgrade or Secure Boot. Do not globally relax camera permissions, replace the
running kernel, reboot, or change Wacom configuration to make this work.

## Delivery and gates

### Component result — October 7, 2026

Gate 1 passed at source `5f6f63a` in
[disposable Linux run 37686776150](https://github.com/cnoellert/plank-client/actions/runs/37686776150).
The local Mac hardware encoder produced all 90 synthetic frames and the requested
frame-45 keyframe. An independent decoder recovered all 45 remaining frames when
starting at that keyframe. Linux decoded the same fixture, and its independent
V4L2 reader received exact reference frames. Chromium 140 received the real
virtual device at 1280 × 720 / 30 fps, with the expected dark/bright image fields.

All ten Linux checks passed: free-producer positive control, producer exclusion,
image decoding/delivery, capture unavailable before/after production, stalled
image replacement within three seconds, and recovery without reopening Chromium.
The separate module/device cleanup step also passed. This is generated media
copied between platforms, not physical capture or an authenticated PLANK stream.
The Ubuntu kernel was `6.17.0-1022-azure`; Rocky and artist application acceptance
remain open. No production Host or accepted Mac runtime was changed.

### Gate status

1. Mac hardware encoder + independent decode; Linux actual-device read from
   FFmpeg and Chromium; producer exclusion, stalls, recovery, off and cleanup.
   Complete for the synthetic component lab described above.
2. Root capability/metadata review and conformance fixtures. Isolated transport
   integration must preserve current desktop/pen tests and leave old peers usable.
3. Host receiver/package candidate and Mac explicit capture UI. Stage a rollback
   and perform one named-application acceptance on a selected test workstation.
4. Camera loss, off/on, disconnect/reconnect, sleep/background and queue pressure,
   with uninterrupted desktop audio and usable Wacom controls. Retain failure
   evidence; do not reinterpret capture success as full-path acceptance.

The existing Host input-backpressure experiment remains separate and held.
No production Host package or live install is part of the component proof.

Sources: [exact root camera contract](https://github.com/instinctual/plank/blob/66f5c2ad775b093b41c991bc120cad7913c44c8a/protocol/camera.md),
[V4L2 output](https://docs.kernel.org/userspace-api/media/v4l/dev-output.html),
[pinned loopback source](https://github.com/v4l2loopback/v4l2loopback/tree/0f9ee86760b7f2bea174b7e3e7a1d38845da0ab4).

## Encoded source candidate — October 7, 2026

[Root PR 24](https://github.com/instinctual/plank/pull/24) adds PCAM v2 alongside
unchanged v1. Its C/Rust vectors, bounded queues, eight encrypted v1/v2 ×
microphone × setup/direct combinations, and camera-only failure isolation passed.
It adds explicit API version selection, not the authenticated product negotiation
that Linux PLS1 and the native pilot still need.

The Mac candidate adds an AVFoundation source with explicit device selection and
normal consent, plus a hardware-only VideoToolbox encoder. Its capture clock is
converted from `AVCaptureSession.synchronizationClock` to the host monotonic clock.
The admission lock bounds pending work to two frames, rejects frames older than
150 ms, revokes stale callbacks by activation epoch, and requires an independent
frame after drops. Off/background/sleep/source loss revoke submission immediately;
separate capture and encode queues drain camera-owned work without blocking Wacom.
A failed submission consumes its wire ordinal so a transport queue drop cannot
cause repeated-sequence failures during recovery.

The generated source test produced 90 PCAM-v2 records and recovery keyframes at
0/30/45/75. Both Core Media metadata and baseline SPS VUI must agree on 720p,
BT.709 and limited range. Unknown/conflicting metadata is rejected. An independent
FFmpeg decoder confirmed all 90 frames with that exact format. A TLS setup test
then delivered the same 90 records byte for byte to a receiver endpoint, and the
received H.264 bytes independently decoded without errors.

`PLANK_MAC_CAMERA_SOURCE=ON` compiles these files in the Mac app; default is off.
The source-enabled app compiles with SDK27 and deployment target15.0. This is an
unsigned compile check, not an installable build or macOS15 hardware acceptance.
No session controller instantiates the adapter yet. Caller-supplied version and
Host acknowledgement must be bound to authenticated negotiation before UI or
capture can be enabled. The old default build's transport pin is unchanged.

Run the generated source checks with `scripts/test-macos-camera-source.py`, passing
the reviewed transport directory, the qualified FFmpeg prefix and an output
directory. Its `.pcam` fixture contains big-endian length-prefixed complete PCAM
records for the root test runner's optional `--encoded-records` /
`--received-payload` test. The prefix is test-file framing, not a network contract.
Neither test opens a camera, requests permission or connects to a product session.

Open gates: physical-camera format/consent and loss testing; authenticated product
capability/activation wiring; Linux Host receiver/device adapter and package policy;
actual camera-consuming application, concurrent desktop/audio/Wacom and interruptions.
The existing Host input-backpressure experiment remains held.
