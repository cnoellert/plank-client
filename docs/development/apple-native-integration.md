# Native Apple foundation import

Tracking: [Client issue 9](https://github.com/instinctual/plank-client/issues/9).

## Source and history

This import starts from maintained Client integration commit
`942f911fc4221d1306aca0f81c45c71190dbdd41`. It brings the Vision build-46
publication `5f2d28a10a0a1a113b7618bcf4e7b1e521f00725` and the public build-input
recipe at their existing paths. The tested runtime was
`d0056978e823a7f9a999efe9336cdb155aa61f35`; the publication adds acceptance
documentation. No Mac pilot, capture-quality side branch or camera adapter is
included in this slice.

A selective history merge retains the original Vision commits and authorship
as ancestors, while taking the maintained integration tree for existing files.
Only `visionos-native/`, its selected verification/build tools, and this guide
are imported. The shipping `app/`, existing tests, submodules and maintained
Wacom/scaling changes remain at the integration baseline. Directory moves into
`apple/shared` and platform subdirectories are a subsequent mechanical change.

## Reproducible unsigned builds

Use the [public native build recipe](../../scripts/apple-native/README.md).
Its input lock supplies public FFmpeg/Opus/libsodium archives and the original
parent transport/Kymux/Relay source commits. Full source comparisons validate
the selected FFmpeg patch independently before compilation. Cargo dependencies
are fetched with the committed lockfile, then the app builds offline. Signing
is disabled and no installed app or live session is touched.

The historical Client common-C pin was `060f6179f88343327b44d915007f1fb4cede71f1`.
This import preserves upstream's `036df96f2d1577af7a1b08c05d87a5218fff7c9b`.
Both are declared separately in the input lock and the selected gitlink is
recorded in build evidence. The raw-HID `src/plank.h` header is identical at
these revisions; the upstream implementation changes are not compiled into the
native bridge. That observation is not a Wacom device-acceptance claim.

The original parent transport remains `e532a5e1691cfa62c325169b8fc29a601f544382`
for this source build. The refreshed parent integration baseline is
`b26b84e377522fddacb21617a23c82def66040da`; moving native transport to it requires
explicit contract reconciliation and verification with upstream. The protocol
implementation is not copied into Client. Root's declared Rust 1.89 and the
tested native compiler 1.96 remain explicitly distinct in the build recipe.

## Present scope and acceptance

The imported negotiation requests Linux-oriented HEVC, ten-bit 4:4:4 identity
(`codec=1`, `ten_bit=true`, `chroma=1`, `negotiated_format=0x0800`) and stereo
Opus with five-millisecond packets. This is not the complete maintained
Host/profile matrix. Linux capture provenance, exact output precision and
supported profiles must remain explicit; macOS Host acceptance is not implied.

Vision deployment target is 26.0. Retained October 4 device evidence records an
Apple Vision Pro on visionOS 27.0.1. Historical accepted tests are recorded in
[the build-46 checkpoint](../../visionos-native/TestFlight/0.1.0-46-preflight.md).
They include Bluetooth/Network drawing and reconnect, Setup enrollment,
complete Relay migration, sleep/wake, tablet USB/Bluetooth switching, complete
tablet disappearance/return, service restart recovery and network-isolated
Bluetooth drawing with a USB tablet. The simultaneous wireless-tablet plus
network-isolated Bluetooth Relay chain remains a separate open qualification.

Do not repeat unchanged accepted tests for a source import. Changed dependency
inputs and behavior need targeted regression evidence. An unsigned compilation
and pure-policy test pass are build evidence, not full production acceptance.

## Upstream reconciliation gates

Upstream leads the following work in coordination through issue 9:

1. Persistent Host trust and changed-identity rejection before credentials.
2. Exact selected precision through decoder fallback, or explicit rejection;
   the current FFmpeg BGRA fallback does not establish ten-bit presentation.
3. Bounded smooth audio clock correction and Linux/macOS timestamp epochs.
4. Host/profile, MTU, window scaling, login/logout/takeover and input parity.
5. Public unsigned CI, followed separately by protected release signing.

Wacom raw semantics remain a gate throughout: startup, pressure, tip/buttons,
held drag, focus, reconnect and hotplug. Periodic video pauses and the reported
Host input receive queue overflow remain unresolved. The Host input-backpressure
experiment remains held; this import does not build or deploy a Host package.

The next native contribution is the separate Mac pilot after reconciliation.
Tablet sharing, multiple displays, capture quality and product camera forwarding
remain independently reviewable steps. iOS is later work after the foundation
stabilizes, not an acceptance target of this import.
