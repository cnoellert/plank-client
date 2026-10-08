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
Its input lock supplies public FFmpeg/Opus/libsodium archives and explicit
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

The original parent transport is `e532a5e1691cfa62c325169b8fc29a601f544382`.
The current recipe selects `6c6865562713d265a657dec613f55169ccb379b2`, which changes
only its Kymux gitlink to `8654cfece0fe5f3ab35177f520ca9378f6d35c24`. This narrowly
reconciles stale-video retirement with shipping completed-packet draining,
re-resolves incoming groups after eviction, and checks retirement advances
before inserting media. The three admission regressions reproduced the original
crash, wrong-group insertion and obsolete-sequence reinsertion before the fix;
all now pass alongside the late-config audio/video draining tests. Resource
bounds, parent protocol/ABI, lockfile and native runtime are unchanged. The refreshed parent integration baseline is
`b26b84e377522fddacb21617a23c82def66040da`; moving native transport to it requires
explicit contract reconciliation and verification with upstream. The protocol
implementation is not copied into Client. Root's declared Rust 1.89 and the
tested native compiler 1.96 remain explicitly distinct in the build recipe.

## Present scope and acceptance

### Import build evidence

At source `7d90a49a5d59e61be693154ef9c49025b6dcb79c`, the complete public recipe
passed fresh source preparation, dependency compilation and unsigned Vision
device compilation with the integration common-C pin. Xcode/SDK 27.0, Rust
1.96.0, CMake 4.3.3 and Ninja 1.13.2 were used. The same recipe also compiled
the separate Mac build-24 publication `04675c95c9486e8f22d7587348d705bb44aeb1a4`
with fresh Mac dependencies; that pilot is not imported here.

Seven build-input failure tests and the existing pure Wacom/input/focus,
decoder recovery, approval-route, audio-format/level and raw-frame tests passed.
The production raw-HID session bridge passed 126 checks using deterministic
native sender stubs, and the production control bridge passed its event and
bitrate framing checks. Existing app/submodule trees matched the integration
base exactly; native runtime files matched the original Vision publication.
These are compile/component results, with no new app installation or device test.

To reproduce the bridge checks after preparing the inputs, from Client root:

```sh
for suite in PlankRawHidSessionBridgeTests PlankControlBridgeTests; do
  xcrun --sdk macosx clang -DPLANK_NATIVE_TRANSPORT=1 \
    -I "$PLANK_NATIVE_WORK/git/root/protocol/plank-transport/include" \
    "visionos-native/Tests/$suite.c" visionos-native/Bridge/PlankRawHidFrame.c \
    -Wl,-dead_strip,-undefined,dynamic_lookup -o "$PLANK_NATIVE_WORK/$suite"
  "$PLANK_NATIVE_WORK/$suite"
done
```

### Transport review correction

The dependency correction is in [Kymux PR 5](https://github.com/instinctual/plank-kymux/pull/5),
responding to [the foundation review](https://github.com/instinctual/plank-client/pull/10#issuecomment-6051542663).
Fresh public preparation, dependency compilation and unsigned app builds passed
again with the new parent/Kymux pins. Vision compiled Client source
`5df917f984430ff09fdcca67b4d7bde559514396` with integration common-C `036df96`;
Mac compiled the same separate build-24 publication `04675c9` with common-C
`060f617`. Publication after that source adds documentation only.

- All 33 audio/video component tests passed, including the three new admission
  regressions, both restored late-config draining tests and existing bounds/loss tests.
- Parent transport unit tests passed: 52, with six integration tests still ignored
  by that unit invocation. No claim is made for those integration tests.
- The seven public build-input failure tests passed again.
- Parent changes are confined to the Kymux gitlink; transport source, public ABI,
  Cargo lockfile, resource limits and native runtime files are unchanged.
- Both original stale-video retirement and shipping packet-draining commits remain
  ancestors of the selected Kymux revision.

Reproduce the component checks from the prepared native parent:

```sh
RUSTUP_TOOLCHAIN=1.96.0 cargo test --locked --offline \
  --manifest-path protocol/plank-transport/Cargo.toml \
  -p kyproto --lib protocol::driver::av
RUSTUP_TOOLCHAIN=1.96.0 cargo test --locked --offline \
  --manifest-path protocol/plank-transport/Cargo.toml \
  -p plank-transport --lib
```

Build receipts record exact inputs, toolchain and executable hashes. This is new
compile/component evidence for changed transport inputs. Existing source-policy
and raw-HID bridge evidence is retained for unchanged files; device streaming
acceptance is still separate. Neither application was installed or launched.

### Device scope

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
