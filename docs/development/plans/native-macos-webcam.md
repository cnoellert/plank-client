# Native Mac webcam: first source/sink pair

Status: component proof and integration proposal; not a Client feature or Host
release. Accepted Mac build 24 remains the runtime checkpoint. The camera lab
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

1. Mac hardware encoder + independent decode; Linux actual-device read from
   FFmpeg and Chromium; producer exclusion, stalls, recovery, off and cleanup.
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
