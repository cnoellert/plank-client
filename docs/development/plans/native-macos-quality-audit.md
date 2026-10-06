# Native Mac video-quality audit and first slice

Date: 2026-10-06. Base: `da0bb7c`, accepted runtime checkpoint `60f7795`.
Candidate: native Mac build 10; physical acceptance pending.

## Source inventory

The native launch request selects `0x0800`, HEVC 10-bit 4:4:4 identity, with
NVENC direct encoding. `PlankHardwareVideoDecoder` parses HEVC parameter sets
and requires an `xf44` 10-bit full-range 4:4:4 buffer. The Metal hardware path
reconstructs identity G/B/R planes. FFmpeg creation is also fixed to HEVC; its
software path is not evidence of H.264 or other profile support.

The desktop Client and root protocols enumerate more encoding profiles than
this engine implements. Existing Qt/FFmpeg support cannot qualify the native
Swift/Metal presentation merely because the same codec libraries are linked.

| Host format/source | Native pilot status | Work needed before offering it |
| --- | --- | --- |
| NvFBC → HEVC 10-bit 4:4:4 identity | Existing default | Preserve accepted playback and input; label 8-bit source/up-conversion |
| Native X11 10-bit → same HEVC format | Build-10 capture choice, experimental | Real Host capture availability and live pen/video acceptance |
| HEVC 8-bit 4:4:4 identity | Not offered | Exact 8-bit decode output, buffer import and color qualification |
| H.264 8/10-bit 4:4:4 identity | Not offered | H.264 creation/parameter handling, exact fallback and presentation qualification |
| H.264 8/10-bit 4:2:2 YCbCr | Not offered | H.264 support plus explicit YCbCr range/matrix/chroma rendering |
| macOS Host HEVC Main10/RExt YCbCr | Not offered by this pilot | Fixed-capture launch, topology and color contract adaptation |

Hardware decoder choice stays internal. A different codec, depth, chroma or
color transform must never be substituted to make a hardware probe succeed.

## Host capability boundary

The Linux Host publishes `PlankCaptureSources`, `PlankEncoderBackends`,
`PlankEncodingModes`, `PlankTopologyVersion` and `PlankFeatureFlags` in server
information. These advertise a possible launch; they do not prove that an
experimental native-10-bit X11 source is usable in the current desktop.

Build 10 requires schema 13, capture-selection (`0x800`) and encoder-selection
(`0x1000`) bits. NvFBC HEVC 10 additionally requires `0x2000`. The exact source,
NVENC backend and HEVC-10 mode must be listed. The authenticated topology must
also carry the required feature bits. The Host launch reply must echo all three
selected values; missing or substituted values fail explicitly.

Server information is refreshed once per launch attempt, including a bounded
startup retry after worker replacement. There is no new periodic discovery or
quality lookup while receiving video, audio or tablet input.

## Implemented UI and persistence

Edit Workstation gains Capture quality:

- **8-bit capture · HEVC 10-bit:** accepted NvFBC default.
- **Native 10-bit capture (Experimental):** requests `x11-native10`, keeping the
  same stream format and decoder path.

Connected Host metadata disables choices it does not advertise. An unconnected
bookmark can save a choice, with support checked at connection/launch. An
unknown or malformed saved value remains unavailable without dropping the
bookmark or silently changing its precision. Legacy bookmarks retain NvFBC.

Quality changes close retained authentication before Save and require fresh
sign-in, like resolution/timing changes. Session Controls shows the requested
capture and exact stream format. Existing bitrate remains the live control.
An optional native-capture 503 keeps the Host status/message and stops startup
retry; it is not interpreted as proof that a prior stream is still releasing.

The new fields and quality checks are scoped to the native Mac build. Vision
defaults, raw Wacom payloads/capture ownership, decoder recovery and local
mouse/fullscreen policies are retained. No Host, Relay or protocol deployment
is part of this slice.

## Checks and live acceptance

Focused quality checks cover migration, malformed/unknown values, add/edit and
relaunch persistence, session-close policy, Host capability refusal, the actual
HTTP query builder and exact reply acceptance. Negative controls restore a
fixed NvFBC request and ignore reply validation; both must fail the checks.
Existing Mac input/presentation/Wacom/recovery checks and non-Mac bitrate and
bookmark-close checks remain gates.

With the desktop disconnected, open signed build 10 and use the unchanged Host:

1. Connect with the default quality. Verify video/audio, pen pressure, held
   drags/buttons, mouse and both fullscreen exit controls.
2. Change only capture quality. Verify the close/sign-in warning. If the Host
   accepts native 10-bit, capture the exact acceptance log and repeat pen/video
   checks. If unavailable, retain its explicit error; do not change the Host
   to force acceptance or silently retry the NvFBC source.
3. Return to the default quality and reconnect tablet-first. No stale button
   state or second-reconnect requirement may appear. Confirm live bitrate
   controls still preserve Wacom capture.

Native capture acceptance is not a native-10-bit color proof. A later precision
claim needs a verified 10-bit source ramp and encode/decode/presentation evidence.
Full codec/profile expansion remains a separate implementation slice.

## Source anchors

- [Quality policy](../../../apple-native/Sources/PlankMacVideoQuality.swift)
  and [checks](../../../apple-native/Tests/PlankMacVideoQualityTests.swift).
- [HTTP launch](../../../visionos-native/Sources/Services/PlankHTTPClient.swift),
  [stream format](../../../visionos-native/Sources/Models/PlankStreamRequest.swift)
  and [hardware decode](../../../visionos-native/Sources/Services/PlankHardwareVideoDecoder.swift).
- Existing desktop `app/backend/outputtopology.h`, `app/backend/nvhttp.cpp` and
  `app/streaming/session.cpp`; root `protocol/encoding-profiles.md` and
  `protocol/output-topology.md`. Treat installed Host metadata/reply as the
  current runtime authority rather than assuming source-tree support is deployed.
