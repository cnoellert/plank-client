# iPad live reference image and magnification

The first full-desktop image slice is implemented, freshly compiled and signed
for iPad34 / Vision50 / Mac27 from
`4a14a47e8f8fb62413f4a8c60f85fb5ecf72329a`. Independent artifact checks passed
for versions, target architectures, profiles/signatures, dependency receipts and
signed rollbacks. iPad34 and Vision50 are installed and their exact running
executables independently verified; Mac27 remains staged and unlaunched.
Physical image appearance, alignment and simultaneous input under image load
remain pending.
Magnification and pan remain the next slice.

## First reference-image slice

In the iPad's Pencil Sharing **Pad Options**, enable **Receive desktop image**.
In the connected Vision or Mac client's **Apple Pencil** settings, enable
**Share desktop image with this iPad**. Both choices default off. Adjust
**Image intensity** on the iPad; it changes the image opacity without changing
Pencil mapping, contact state, pad glow or system brightness. After desktop
disconnect, the client requires a fresh image-sharing choice.

The image is the entire already-decoded desktop composite. It occupies exactly
the existing outlined Pencil viewport: **Match desktop** preserves its aspect;
**Use full pad** stretches image and normalized input through the same rectangle.
Margins, artist controls and the normal client-screen menus remain available.
There is no additional fit, focused-display crop, zoom or pan in this slice.

Encoding and decoding run on independent utility workers. The sender registers
its own video surface in the existing workstation session and removes only that
surface when stopped. Each worker has one active frame and one replaceable
latest frame. JPEG references are SDR sRGB, at most 1920 pixels on their longer
edge, at most 2 MiB each, at most 10 offered frames per second, with a rolling
2 MiB/s sender admission budget and separately paced encrypted records. These
dimmed references are not qualified for color-critical decisions. Hardware
`xf44` is reconstructed as the existing identity GBR10 path, preserving its
channel order; software frames retain the renderer's premultiplied BGRA path.

The independent `_plank-pencil-image._tcp` lane uses NoiseIK with the exact
current approved static peer and a digest of all 64 bytes of the completed pen
handshake transcript. Both authenticated messages carry a distinct image
purpose. Image authority cannot be inferred from discovery TXT, a comparison
code fragment, an old desktop or pen/key approval alone. Existing Pencil v3
records and their strict size limits are unchanged; image chunks use their own
bounded framing and assembler. The media service follows the actual registered
Pencil service name and fails image-only on a name collision.

Image metadata requires full source dimensions, a desktop ID, monotonic frame
number and geometry generation. Dimensions must match current pen configuration
before decoding. Geometry retirement prevents an old decode from repainting a
new drawing area. A frame older than 1.5 seconds after its first local authenticated chunk
is discarded/cleared; this local age does not measure workstation-to-tablet
latency. Incomplete assembly has a separate 3-second deadline. Images stay in
memory and are not logged or saved. Image failure/turning it off restores the
charcoal pad without closing the Pencil connection. Actual background, peer
revocation and desktop end remove image authority and any retained picture.

The first physical gate is image appearance and dimming, shared margin/mapping
alignment, painting with simultaneous controls under image load, then turning
the image off while Pencil remains usable. Existing input acceptance is carried
forward; these checks qualify only the new image path. Physical latency,
interruption/final Host receipt, color-critical output, Bluetooth media and
background capture remain separate.

Focused codec, wire, sanitizer-backed crypto and real loopback checks are
reproducible on the build Mac after the public recipe's macOS prepare/deps:

```sh
apple-native/Tests/run-pencil-image-checks.sh /absolute/macos-recipe-work /absolute/fresh-check-output
```

The socket fixture uses in-memory approvals and loopback-only listeners.
It does not exercise device gestures, change Keychain approvals or establish
physical alignment/latency. Component lifecycle fixtures separately exercise
retirement during encode/decode and coalesced presentation.

## Artist experience

Pencil sharing shows the current remote desktop over the charcoal pad, with
an independent Image intensity control. Existing pad margins and artist
controls remain available. The direct iPad client should use the same image
and input geometry. Image intensity changes appearance, not pen mapping or
system brightness.

Offer **Fit / 100% / 200% / 300%** and deliberate pan. Numbered magnification
means source pixels per display pixel: 100% is one source pixel per display
pixel; 200% and 300% enlarge that pixel two and three times. These are not
multiples of Fit. A future offset near-tip magnifier can provide a visual aid
without moving the full canvas during a stroke.

## Geometry and image quality

One immutable transform must drive the image, cursor and inverse pen mapping.
It includes the selected output's source crop and offset, active pad after
margins, zoom/pan, display scale and session/geometry generation. Input adds
crop offsets back and normalizes against the full Host input extent. Define
pixel-center conventions explicitly. Pan/zoom or geometry changes retire an
active stroke before switching transforms; do not move its target underneath
the tip.

Use full pad may stretch in Fit if image and input stretch together. Numbered
pixel magnification should preserve uniform scale. Actual render backing size
must honor the display scale; a source-sized drawable alone does not prove
one-to-one pixels. A downscaled thumbnail enlarged to 200% cannot recover
native detail. Use a sufficiently detailed full frame or native source crop.

## Transport boundary

Direct iPad reuses its decoded desktop frames. For sharing, AVP/Mac forwards
frames from the existing workstation session over a separately authenticated,
bounded media channel, with explicit image-sharing authority. Current Pencil
protocol3 carries pen and keys only; its control lane must not carry image data.
No second workstation session is needed. Encoding and latest-frame dropping
must keep video from delaying tip, release or modifier edges.

Frames identify their desktop and geometry generation, source dimensions/crop
and frame number. Discard stale or mismatched frames, measure local receive and
presentation age, and retain the established input-only pad if images stop.
Remote clocks are not comparable without synchronization. Preserve the source
color/channel path; dimmed reference images are not a qualified color surface.

## Order and targeted qualification

1. Dimmable live image with measured frame age and bounded media transport.
2. Shared Fit/100%/200%/300% transform and deliberate pan.
3. Optional visual-only near-tip magnifier.

Verify transform round trips and crop/margin corners, nonzero output offsets,
native pixel patterns, contact retirement, rotation/keyboard geometry, stale
generations and input edge delivery under image load. Measure physical Pencil
response in both direct and shared contexts. Existing accepted input tests do
not need repeating. Bluetooth media, background capture and Host changes are
outside the initial slice.
