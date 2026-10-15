# iPad live reference image and magnification

Current image senders are installed Vision52 from
`e8b928ffd8b253edc959c7669b2cc23b50aa99f2` and native Mac30 from
`dd07decfa5f1a26a664cc699d3cfce2ba725b5ae`. Mac30 adds bounded shared diagnostics
without changing Mac29's image behavior. Its targeted Pencil/Artist smoke check
is user-accepted; the later October15 trial also reports hover, click/drag and
basic Sharing zoom working after a one-to-two-second startup delay. Image quality
and timing remain unqualified. The Mac is open alongside the retained Qt client.
Current installed iPad45 runtime `9dcde0af10dd11f6259d0d1bee088dff4f345466`
retains build43's local Fit/2×, Hand and area navigation, build35's optimized
image receiver, build36's finger option and build44's bounded diagnostics.
The user accepts map hide/button access, restore and header movement in both
Desktop and Pencil Sharing. The targeted editor outline/editing check from42
remains accepted. Direct tip alignment and basic Mac Sharing zoom are now
user-reported working; held-input view changes and Sharing Hand isolation remain
separate physical gates.

The October 11 artist trial confirms the picture appears and latency is better,
but below the hoped responsiveness; image promotion remains held. Older
iPad34 / Vision50 from `4a14a47e8f8fb62413f4a8c60f85fb5ecf72329a` failed the
picture latency/stretching trial. Old Air34 remains unchanged; Vision50 is
superseded. Mac27/28/29 remain staged and unlaunched. Sharper source-region media
and a separate loupe remain later work.

## October 10 physical usability result

The user reported that picture latency and stretching make this version not
worth using, and clarified that the delay is mainly the picture. The image
slice is not accepted for promotion. Earlier Pencil and controls acceptance
remains intact; a new Pencil slowdown was not reported as reproduced. Dimming,
mapping corners and input under media load were not separately qualified.

The baseline source caps image sampling at 10 fps, performs CPU resampling/JPEG
encoding, and paces media bytes at 2 MiB/s. The installed development apps were
compiled with unoptimized Swift. These are plausible picture-delay costs;
no correlated physical encode, transfer and presentation timings were recorded,
so the dominant cause has not been measured.

A bounded in-memory comparison of the exact codec on M4 Max/macOS26.7 found a
large optimization difference for synthetic 3840×2160 frames reduced to
1920×1080. Three encodes per format gave median BGRA times of 1105.84 ms
unoptimized and 15.27 ms optimized, and actual xf44 GBR10 times of 1300.15 ms
and 21.50 ms. JPEG sizes were identical between optimization modes for each
format (129,947 and 130,332 bytes). No screen images were captured or saved.
These are Mac encode measurements, not AVP performance or end-to-end latency.
They justify investigating an optimized image conversion candidate before
discarding the JPEG approach or raising its frame rate/bandwidth limits.

In that baseline, Use full pad deliberately stretches the complete image and
normalized Pencil mapping together. Match desktop uses one aspect-preserving
rectangle for both.
The physical mode used in the reported trial is unrecorded, so that stretching
path is not a conclusive diagnosis. Applying an image-only aspect fill/crop
would break Pencil alignment. A uniform cropped drawing view requires a shared
source crop/scale and matching inverse input transform. A separate visual-only
magnifier can instead retain the established full-pad input mapping.

That assessment preceded the October 11 candidate below. The optional image
choices remain default off, and the working input-only pad remains available.

## October 11 optimized candidate — iPad35 / Vision51 / Mac28

Only the bounded pixel converter is compiled with `-O2`, without fast math or
floating-point contraction. The applications retain normal Debug settings,
including Swift `-Onone`, and the public recipe/dependency pins are unchanged.
Conversion uses the existing premultiplied BGRA and actual identity `xf44`
GBR10 channel/normalization conventions. Storage and dimension validation,
JPEG admission/quality, decode checks, consent and transport limits remain
unchanged.

Sanitizer-backed converter and unchanged codec checks passed. Ten resampler
comparisons and both synthetic JPEG outputs match the prior conversion byte
for byte. On the build Mac, the same in-memory 3840×2160 to 1920×1080 workload
gave median encode times of 11.986 ms for BGRA and 22.130 ms for GBR10 with
Swift still unoptimized. These are Mac encode measurements, not AVP or
end-to-end latency, and do not establish a physical usability repair.

While **Receive desktop image** is enabled, picture and Pencil use one
effective **Match desktop** rectangle inside the configured margins. The saved
input-only mapping preference is preserved; disabling the image restores it.
Waiting or failed image delivery does not independently change pen mapping.
Consent transitions retire contact and held controls before changing geometry,
then synchronously update the shared image/input rectangle before fresh input.
Native policy/transition fixtures passed, including saved FullPad restoration
and retention of the approved pen peer. Actual device alignment remains a gate.

Sparse content-free samples record sender encode time/size, receiver pre-decode
local age and decode time, and local age at accepted MainActor delivery. The
last value precedes layer assignment and does not measure compositor completion
or scanout. Local receive age includes assembly and worker waiting; it does not
isolate network delay or compare unsynchronized device clocks. No images or
typed text are logged or saved.

All three signed artifacts passed independent version, architecture, profile,
signature, source and exact dependency checks; signed34/50/27 rollbacks are
retained. At that checkpoint no candidate was installed or launched; iPad35 was
subsequently installed and independently verified on the new M5. A new device trial is
required for picture latency, proportional alignment, simultaneous Pencil and
controls under media load, and image-off continuation. Existing input-only
acceptance is carried forward. Zoom, pan and magnification are not implemented.

## Image startup recovery — Vision52 / Mac29

The new M5 trial reports no image when reception is enabled. Logs establish
receive consent and an active Pencil connection, with no accepted decoded image.
They do not identify sender consent, transport or dimension/freshness admission
as the actual cause. Current image status on both devices is requested. Input
and image wire/crypto bytes match the prior compatible versions.

A separate confirmed startup defect is reproduced locally: the sender's
one-attempt latch survives an image connection failure. If the client enables
sharing before iPad reception, later receiver availability cannot restart media
without toggling the client choice off/on. Vision52 / Mac29 retire that latch
and schedule one weak retry task, at 1/2/4/8-second capped delays. Each attempt
revalidates explicit share consent, the current approved pen binding and the
streaming desktop. Turning sharing off, replacing the binding or ending the pen
or desktop invalidates pending tasks and stale callbacks. Pencil and Artist
Control ownership and the encoder worker are unchanged; both image consent
choices and all existing authentication/dimension/age checks remain required.

Nine exact-production-body cases pass with real MainActor tasks and cancellation,
using stand-in peers, listener, client and encoder. They cover sender-first
failure then availability, stale callbacks, consent off, binding/desktop changes,
synchronous start failure, non-streaming state, capped delay and weak owner
release. Native Vision and Mac builds/signing/dependency/library-closure checks
also pass. iPad36 and Vision52 were then installed under the artist's readiness
confirmation; exact app versions and running paths are independently verified.
The requested image trial now reports a visible picture and better latency,
below the artist's hoped responsiveness. This resolves the appearance/delay
question without establishing the original missing-picture cause or complete
image usability. Actual alignment, dimming and simultaneous input under image
load remain separate gates. No new Pencil slowdown was reported.

Sparse first/every30 successful-frame samples from this trial give a median
sender encode time of 38.12 ms and receiver decode time of 11.63 ms. Receiver-local
age at delivery entry has a median 137.60 ms, including assembly/worker wait after
the first authenticated chunk. These samples are not synchronized across
devices and exclude source capture, transfer before the first chunk, compositor
and scanout; adding the medians does not establish end-to-end latency.

## First reference-image slice

In the iPad's Pencil Sharing **Pad Options**, enable **Receive desktop image**.
In the connected Vision or Mac client's **Apple Pencil** settings, enable
**Share desktop image with this iPad**. Both choices default off. Adjust
**Image intensity** on the iPad; it changes the image opacity without changing
Pencil mapping, contact state, pad glow or system brightness. After desktop
disconnect, the client requires a fresh image-sharing choice.

The image is the entire already-decoded desktop composite. In candidate35 it
occupies exactly the aspect-preserving outlined Pencil viewport, with the same
inverse input mapping. Image consent temporarily selects **Match desktop**;
the saved **Use full pad** preference is available again when images are off.
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

### October 11 zoom proposal — discussion before implementation

The artist requests a doubled view for viewing and operation in both direct
iPad Desktop and Pencil Sharing. Recommend **Fit / 2× View** first, with a
deliberate **Hand** navigation control and a small full-desktop navigator.
Here 2× means twice Fit, rather than a native-pixel percentage. Existing
100%/200%/300% ideas mean source-pixel magnification and should be named
separately if added later. The artist agreed to try this proposal; the connected
layout-naming correction comes first. Naming39 and authored editor42 are now
physically accepted for their targeted checks. At the proposal checkpoint zoom
was not implemented; the candidate43 section below records the subsequent slice.
Center the initial doubled view on the last valid Pencil hover position, or
the desktop center when hover is unavailable. The navigator can select another
area deliberately. This proposal avoids moving the view continuously under
the Pencil while drawing.

The primary zoom is an operating workspace: picture, cursor, Pencil, mouse and
squeeze positions use the same crop/scale and inverse mapping. Artist Controls
stay at their saved physical size and location. Hold zoom/pan requests until
the active Pencil stroke or pointer drag ends; the target must not move under
a held contact. Keep intentionally held modifiers owned until their real
release, rather than releasing them solely for a local view change. Rotation
or session/geometry replacement still retires contact before forced changes.

Hand-mode contacts are local navigation, available even with Ignore finger
input enabled, and exclude Artist-control hit regions. Do not infer a pan from
an ordinary first finger that has already sent a remote click. Avoid automatic
follow-pan during drawing. A later view-only loupe beside the tip could enlarge
detail without changing the established drawing coordinates.

Direct Desktop retains the decoded original frame and can crop locally without
another stream. Sharing currently receives a full-frame JPEG with a 1920-pixel
long edge; enlarging it cannot recover missing detail or reduce picture delay.
For sharp shared magnification, a later negotiated media extension would request
a bounded source region from AVP/Mac and carry crop/generation metadata. Current
image messages require full-frame identity crop, so that would be a separate
protocol slice. It does not require a new Host contract or workstation session.

## Geometry and image quality

One immutable transform must drive the image, cursor and inverse pen mapping.
It includes the selected output's source crop and offset, active pad after
margins, zoom/pan, display scale and session/geometry generation. Input adds
crop offsets back and normalizes against the full Host input extent. Define
pixel-center conventions explicitly. Voluntary pan/zoom waits for contact
release before switching transforms; forced geometry changes retire the contact
first. Do not move a stroke's target underneath the tip. Missing or stale pictures
clear the image without silently changing the current crop or input mapping.

The current image candidate preserves aspect in Fit. A future stretch option
would have to change image and input together; numbered pixel magnification
should preserve uniform scale. Actual render backing size
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
2. Implement the artist-approved shared Fit / 2× View transform and deliberate
   local Hand navigation after fullscreen naming and windowed controls are
   qualified. No zoom runtime is included in iPad39.
3. Assess sharper source-region media as a separate negotiated slice.
4. Optional visual-only near-tip magnifier.

Verify transform round trips and crop/margin corners, nonzero output offsets,
native pixel patterns, contact retirement, rotation/keyboard geometry, stale
generations and input edge delivery under image load. Measure physical Pencil
response in both direct and shared contexts. Existing accepted input tests do
not need repeating. Bluetooth media, background capture and Host changes are
outside the initial slice.

## Local Fit/2× operating view — iPad43 candidate

Runtime `5a2ea686a3bab92df91af69c17a4ca4de1e31dca` adds the approved local view
in both direct Desktop and Pencil Sharing. The magnifying-glass toolbar button
offers **Fit**, **2× View**, **Hand** and **Center View**, and stays available
with the session toolbar hidden. Compact windows keep Artist visibility,
Layouts and View as dedicated buttons; keyboard, settings, toolbar hiding and
disconnect/stop move into **More session controls**. Sharing's 2× option requires
active Pencil sharing and Receive desktop image. Fit restores ordinary drawing
and turns Hand off.

2× means twice the current Fit scale. It starts around the last valid Pencil
hover or desktop center, bounded to keep the crop inside the picture. The small
navigator outlines the complete desktop and current crop; it is an area selector,
not another live stream. Drag there to choose a region, or enable Hand to move
the picture with a local finger/Pencil drag. Additional and margin Hand contacts
remain local and cannot fall through into remote clicks. Artist controls retain
priority; Pencil forwarded from their overlay keeps its remote drawing route.
Ignore finger input still filters ordinary remote finger clicks while deliberate
Hand and navigator interactions remain available.

One immutable viewport drives the fitted operating rectangle, entire-image frame,
visible source crop, forward cursor and inverse Pencil/pointer/squeeze coordinates.
Local crop offsets are added back before normalized complete-desktop delivery.
The existing inverse endpoint convention is explicit: outer viewport edges map
to inclusive pixel indices `0...width-1` and `0...height-1`, and forward cursor
mapping uses that same convention. Fresh input rejects letterbox areas; existing
drags retain edge clamping. Source image layers and the actual Metal child use
the same clipped operating rectangle. Artist button geometry is separate from zoom.

Voluntary mode, center, pan and Hand requests coalesce while a remote Pencil,
finger or mouse-button contact is held. After its real release edges and cleared
contact fields, native presentation and input apply the emitted crop together,
retiring only old hover. Artist and physical keyboard modifiers keep their real
release ownership; view changes do not advance their input epoch or restart the
session. Forced bounds/keyboard, source, admission and session changes retain
existing retirement and discard pending old-view requests. The navigator's
protected 140×108-point footprint is constant in Fit and2×, so ordinary mode/pan
changes do not change Artist chrome reservations.

The receiver, authenticated pen/media protocols, Host and native recipe pins
are unchanged. Sharing still receives the same dimmed complete-frame JPEG;
enlargement cannot recover detail or remove picture delay. Sharper source-region
delivery is a separate negotiated media slice. Media geometry generation is
not repurposed for local zoom. Missing or stale images keep their existing
image-only clearing behavior.

Swift6 policy and exact-contact fixtures pass crop landmarks and roundtrips,
nonzero bounds/crop offsets, Fit compatibility, invalid geometry, deferred
requests, multi-button release ordering and preserved held Shift/Space. Native
Simulator27 checks render the production video/input/pad-image and WorkingSurface,
Artist and navigator components with stand-in transport. Eight rendering phases
and22 cases pass actual software/Metal-child layout, clipping, cursor/hotspot
alignment, retained frames, synchronous crop, held-stroke visual deferral,
local Hand and Artist/navigator priority in both contexts. Exact toolbar bodies
pass reachable, disjoint 44-point targets at375 points and normal width. Saved
screenshots contain synthetic fixture landmarks, never workstation images or text.

Controlled windows and manually delivered touch subclasses do not qualify
physical iPadOS26.6 arbitration, palm rejection, compositor/scanout timing,
hardware xf44 GPU quality or final Host receipt. New physical zoom/alignment,
Hand/navigation and simultaneous controls remain pending. Accepted editor42,
naming, keyboard, wheel and earlier input results are carried forward.

The final43 device app was freshly built, signed and independently verified for
the new M5, including exact compiled runtime/resources, profile/certificate,
entitlements, declared pins and all258 dependency entries. Signed42/41/40/39,
Vision52 and Mac29 remain intact. A precompact43 package was never installed
and is quarantined; the final build uses a fresh dependency-only clone after
the public recipe refused reuse of an app build directory. After the user
authorized the disconnected update,43 was installed and launched on the new M5.
Separate app/process inventories verify43/0.1.0 and its matching executable.
Vision52, the old Air, Mac29 and Host/network/dependency pins remain unchanged.
Physical zoom/alignment, Hand/navigation and simultaneous-control checks remain
pending; installation does not establish those results.

Reproduce the focused fixtures on the build Mac:

```sh
python3 ios-native/Tests/run-zoom-policy-checks.py --output /absolute/fresh-output
python3 ios-native/Tests/run-zoom-input-integration-checks.py --output /absolute/another-fresh-output
```


## Optional movable zoom map — iPad45

The zoom toolbar menu adds **Show Zoom Map** and **Reset Map Position** in
both direct Desktop and Pencil Sharing. The map's **×** button hides it; drag
its **Map** header to move the panel. Dragging inside the map continues to select
the source region. Panel movement and visibility do not request a change to Fit/2×, Hand or the
source crop, and do not reset drawing coordinates, input epoch or the approved peer.

Visibility and normalized panel position are remembered separately from Artist
layouts and shared between both iPad modes. The original 140×108 map is inside
a fixed 140×152 panel with separate 44-point move/hide targets. Window resizing
and rotation clamp placement within current safe bounds and avoid actual local
menu/consent rectangles without scaling the map or rewriting saved placements.
If the panel cannot fit, it is omitted until space is available. A hidden panel
is removed from the hierarchy and chrome reservations; it leaves no invisible
hit target or dead area over Artist buttons. Reset remains reachable in the
menu even while drawing or the map is unavailable.

Existing Artist chrome retirement remains unchanged: changing reserved map
geometry balances held Artist keys and cancels Pencil contacts forwarded through
those keys. Ordinary canvas strokes are not retired by panel placement changes.
This is a local UI change; the image lane, zoom transforms, receiver, protocol,
Host, dependency pins and latency-diagnostic behavior remain unchanged.


Build45 was installed as an update on the M5 after the user explicitly disconnected
and stopped sharing. Exact45/0.1.0 and the running executable were inventoried.
The user answered **Works in both modes** to hide/button access, menu restoration
and header movement in Desktop and Pencil Sharing. This is targeted map acceptance;
it does not establish the latency cause, all window/OS cases or final Host receipt.
Vision52 and the existing native/dependency/Host/network pins remain unchanged.


## October 14 direct zoom feedback

On installed iPad45, the user answered “Yes. Stays under pencil” to the requested
direct Desktop 2× edge-drawing, Hand pan/off and return-Fit check. Record this
as user-reported direct trial acceptance, with tip alignment explicitly
confirmed; individual Hand details were not separately described. No timing,
OS input-arbitration or final Host receipt was measured. Sharing image/view/input
alignment and held-contact/modifier view changes remain separate physical gates.


## October 15 Mac Sharing zoom feedback

The user reports hover, click/drag and zoom working through native Mac30, with
iPad45 unchanged, after a one-to-two-second startup delay. USB is attached and
only the guest network is available; Flame-01 is reached through Tailscale.
No network setting or runtime changed to obtain this result. This records basic
Sharing zoom operation, not independently measured picture latency, an identified
transport repair or a separately described Hand-isolation result. Held-modifier
ownership and a requested view change during an active stroke remain pending.


### Sharing zoom availability follow-up

The next held-input trial could not start because the user could not select
2×. In this runtime, Sharing view controls require both active Pencil admission
and Receive desktop image enabled. A Mac focus pause can therefore disable local
zoom. The current iPad image state was not yet confirmed, so the exact cause
remains open. The earlier user-reported basic zoom result is retained; stable
availability and held-modifier/view-change behavior are not qualified.

### Local Sharing navigation correction — candidate46

The user confirmed that the live workstation picture was visible while 2×
could not be selected. The existing Sharing menu gated local navigation on
remote input admission. A Mac focus pause could disable 2× even though image
reception continued; repeated input configurations also reset the local view.
This source defect is established independently of the unmeasured physical
state at the exact failed tap.

Candidate46 allows 2×, Center and deliberate Hand navigation when the current
approved Pencil peer has supplied desktop dimensions, image reception is on,
and the iPad is not adjusting local settings. Remote pen, squeeze and Artist
keys still require active client input admission. A focus-only configuration
retires contact and keys, discards pending old-contact view changes and preserves
the applied crop. New peer, changed dimensions, image mapping changes and local
geometry/settings transitions retain their existing reset behavior. Returning
focus admits only fresh contacts; it does not replay the retired stroke.

Focused production-body checks cover paused navigation without remote output,
held-input retirement, stale move/up rejection, focus resume and source/geometry
reset. Two native Simulator menu checks pass selection of 2×/Hand while remote
input is paused, plus image-consent/configuration/settings gates. The fresh
device build, exact M5 profile and signature, unchanged entitlements/dependencies
and protected source boundaries pass separate package verification. Runtime
`4c7731272c68f53b4272f959ca695d1803b7080d` is signed and staged as iPad46;
the user subsequently authorized its disconnected update. Independent device
inventories verify installed46/0.1.0 and the exact running executable. Mac30 and
Vision52 are unchanged. The targeted Sharing 2×/Hand availability, focus-return
crop continuity and fresh-contact check is pending; held-modifier qualification
follows separately. This is not a latency or transport repair.
