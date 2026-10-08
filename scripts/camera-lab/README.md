# Webcam component proofs

These tools are isolated from the accepted native Mac build 24. They are not
linked into the Client or Host and do not enable a camera in a PLANK session.
The existing transport pin and working Wacom paths are unchanged.

## Linux destination

The dedicated workflow builds v4l2loopback `0f9ee867` (v0.15.4) against a disposable
Ubuntu runner's own kernel. It creates one private synthetic device, feeds 720p
YUYV frames decoded from the included synthetic Mac VideoToolbox H.264 fixture,
and checks:

- capture is unavailable before and after the producer;
- a second producer cannot claim the stream;
- Linux decodes all 90 Mac-encoded frames with the expected image transition;
- an independent FFmpeg reader receives the exact generated pixels;
- Chromium enumerates and reads that actual V4L2 camera through getUserMedia;
- starving the producer replaces the previous image, then resumes without
  reopening the browser;
- the module/device can be removed after every run.

The browser receives explicit test permission; no fake-video-capture flag is
used. Evidence stores format/pixel results, not camera identifiers. The script
refuses non-GitHub-hosted execution. It must not load a module on an artist's
workstation. Ubuntu results do not establish Rocky kernel packaging, Secure
Boot support, OBS or conferencing service acceptance.

## Mac encoder

Compile `mac-encoder-proof.swift` with `xcrun swiftc`, then pass an output H.264
file path. It creates 90 generated NV12 frames at 720p/30, requires a VideoToolbox
hardware encoder, requests an extra independent frame, and writes Annex B H.264.
It checks delivery, bounded sample sizes and the requested keyframe. JSON timing
is callback age, not complete capture/network/application latency.

No physical camera is opened, and no camera permission is requested. Use an
independent decoder to verify dimensions, frame count, color and generated image
transition. This is an encoding feasibility check, not the current PCAM v1 source
contract: that contract explicitly requires unchanged native compressed capture.
The fixture manifest records its SHA-256 and local hardware/independent-decoder
results. It contains generated dark/bright fields only. Copying this fixture
between platforms does not establish authenticated network transport.

## Product boundary and next integration

The first proposed product path is Mac AVFoundation → VideoToolbox H.264 → an
authenticated camera lane → Linux decode → one virtual V4L2 camera → an explicitly
chosen application. It still needs:

1. An agreed encoded-source capability and metadata contract. Do not present
   encoded Mac output as native V4L2 capture or invent a driver sequence. Old
   peers must leave camera off. Reuse existing PCAM framing/recovery where valid.
2. A separate Linux Host adapter/package plan: selected device permissions,
   matching kernel module, ownership, explicit off/removal and recovery. This
   proof installs no production Host package.
3. Mac capture consent/source selection, default-off UI/indicator and bounded
   capture/encode work. Optional camera failures must leave desktop, audio and
   tablet operational.
4. Integration against the camera ABI in isolation from the accepted transport
   pin, then actual named-application acceptance and interruption testing.

Microphone forwarding and Vision Pro Persona are separate work. No physical
camera, PLANK transport, artist application or production release is qualified
by these component proofs.

Sources: [V4L2 output interface](https://docs.kernel.org/userspace-api/media/v4l/dev-output.html),
[v4l2loopback](https://github.com/v4l2loopback/v4l2loopback/tree/0f9ee86760b7f2bea174b7e3e7a1d38845da0ab4),
[current camera contract](https://github.com/instinctual/plank/blob/66f5c2ad775b093b41c991bc120cad7913c44c8a/protocol/camera.md).

## Local physical-source check

After the generated-source gates pass, `build-mac-source-test.py` builds a
separate PLANK Camera Test app from the same admission/capture/encoder sources.
Pass the reviewed transport directory and a staging output directory. It uses
ad-hoc signing for a local test identity, not the distributed Client identity.
The script does not launch the app, grant consent or start capture.

The operator chooses one camera and presses Start camera test. The normal
macOS permission request precedes capture. The source runs for five seconds,
then stops; Stop, window close, app background and sleep also revoke it. Only
bounded frame counts and timing are saved privately; images/encoded frames are
not written to disk or sent to a network peer. The report path is under the
operator's private PLANK notes as `camera-source-device-test/latest.json`.

This harness supplies a test acknowledgement fixture. It does not authenticate
or negotiate with a product Host, and it must never be used as evidence that
product camera authorization works. A pass establishes the selected physical
camera's format, clock mapping and the actual hardware encoder/metadata adapter.
A signed Client consent check, Linux receiver/application, desktop/audio/Wacom
concurrency and the product lifetime gates remain separate acceptance work.

The first built-in Mac camera attempt passed the permission gate but rejected
the capture format before producing any frames. This is an unresolved physical
source failure, not a qualification pass. Test build 2 reports the failing setup
step or the delivered dimensions, pixel format, color metadata or clock check.
It retains the strict format policy; diagnostic metadata never includes camera
identifiers or image contents. Retry requires the operator to press Start again.
The diagnostic retry identified 1920 × 1080 output despite selection of a 720p
input mode/preset. Test build 3 requests explicit 1280 × 720 output dimensions
through AVFoundation's uncompressed `videoSettings`, retaining strict validation
of delivered size, limited-range NV12 and BT.709. Its physical retry is pending.
