# Native Apple build inputs

This recipe builds native Client dependencies from public sources and compiles
an **unsigned** application. It does not install, launch, enroll, or distribute
the application. Keep signing and device acceptance in the release workflow.
The shipping `app/` build and the parent protocol implementation are unchanged.

## Scope and checkpoints

The native code is still in its original directories. Use a clean Client
checkout containing `visionos-native/` for Vision, or `apple-native/` for the
separate Mac pilot. The tested checkpoints before this recipe are:

| Target | Runtime | Publication | Minimum OS | Retained test OS |
| --- | --- | --- | --- | --- |
| Vision build 46 | `d0056978e823a7f9a999efe9336cdb155aa61f35` | `5f2d28a10a0a1a113b7618bcf4e7b1e521f00725` | visionOS 26.0 | visionOS 27.0.1, from October 4 device evidence |
| Mac pilot build 24 | `5db90ffeb7568105a664df0f340c5769c79b0603` | `04675c95c9486e8f22d7587348d705bb44aeb1a4` | macOS 15.0 | macOS 26.7 |

The same Mac package still needs qualification on macOS 15 and macOS 27.
Deployment-target and SDK settings do not establish that acceptance. These
recipes reproduce source inputs and explicit build settings, not historical
signed binary hashes. The fresh Vision FFmpeg build uses minimum OS 26.0;
the retained library used 2.0, beneath the app's 26.0 minimum.

## Inputs

[`inputs.json`](inputs.json) is the authoritative input lock for this recipe.
It pins public repository commits, release archive SHA-256 values and the
expected contents of patched FFmpeg files. Cargo's committed lockfile resolves
the transport's Rust dependencies. The protocol and vendored Quinn code stay
in the parent repository; they are not copied into Client.

Both accepted native builds used Rust **1.96.0**, as recorded in their compiler
fingerprints. The selected parent source declares **1.89.0**. The recipe
verifies that parent declaration remains intact and explicitly selects 1.96.0
for native builds with `RUSTUP_TOOLCHAIN`; it never changes the global default.
Do not resolve this distinction by silently using a moving `stable` toolchain.

| Dependency | Version | Treatment |
| --- | --- | --- |
| FFmpeg | 9.0.1 | Shared on Mac, static on Vision; verified platform patch |
| libopus | 1.6.1 | Static, float API, optional neural extensions disabled |
| libsodium | 1.0.22 | Static; Mac assembly disabled as in the retained build |
| Parent transport | `e532a5e1691cfa62c325169b8fc29a601f544382` | Native Cargo target only |
| Kymux | `4647272e43330fad3fbe31cdb60ca6127d34764a` | Exact parent gitlink |
| Drawing Relay | `029721f9b60833d36aa31f4da558cf8325e111ca` | Shared raw protocol/crypto sources |
| Managed Relay | `73a3743e10c8031b7f5f34105d22f207e8783397` | Mac Setup codec only |
| common-C | `060f6179f88343327b44d915007f1fb4cede71f1` | Selected Client headers; no recursive dependencies |

The refreshed upstream integration branch uses common-C
`036df96f2d1577af7a1b08c05d87a5218fff7c9b`. That separate input is also declared
in the lock. The recipe verifies whichever exact gitlink the chosen Client
contains and records it in the application receipt. The import preserves the
upstream gitlink; compiling with it does not claim unchanged dependency acceptance.

Vision uses the exported VideoToolbox patch in
[`patches/0001-videotoolbox-support-visionos.patch`](patches/0001-videotoolbox-support-visionos.patch).
It omits the OpenGL ES compatibility key that the visionOS SDK makes unavailable.
Mac reuses the tracked identity-GBR HEVC patch under
`app/deploy/linux/ffmpeg-patches/`; its original attribution is preserved.
Before compilation, every source file is compared with the verified archive
plus the selected patch. Missing/extra files, other edits, executable-bit changes,
symlink substitutions and `.orig`/`.rej` residue stop the build.

## Requirements

Use an Apple Silicon Mac with full Xcode 27 or newer selected, Python 3.12 or
newer, CMake 3.30 or newer, Ninja, Git, curl, patch, make and rustup. This native build
does not require Qt, SDL, OpenSSL, a private builder, or signing credentials.

Install the explicit Rust toolchain and desired targets once:

```sh
rustup toolchain install 1.96.0 --profile minimal
rustup target add --toolchain 1.96.0 aarch64-apple-visionos
# For a simulator compile:
rustup target add --toolchain 1.96.0 aarch64-apple-visionos-sim
```

Use a clean public Client clone and initialize only the common-C headers:

```sh
git clone --no-recurse-submodules https://github.com/cnoellert/plank-client.git client
cd client
# Check out the chosen integration commit (or the checkpoint listed above).
git checkout --detach "$PLANK_CLIENT_COMMIT"
git submodule update --init moonlight-common-c/moonlight-common-c
```

Do not initialize inherited prebuilts or unrelated submodules. A Client with
uncommitted changes or an undeclared common-C pin is rejected by the app build.
The recipe itself may live in a separate clean checkout while `--client`
selects the runtime source to compile.

## Build

Choose `device`, `simulator`, or `macos`. Use a fresh work directory per platform
and attempt. Only release archives are reused through a checksum-verified cache;
old prepared source and installed dependency trees are not substituted.

```sh
export PLANK_NATIVE_WORK="$HOME/Library/Caches/plank-native/device"
export PLANK_NATIVE_ARCHIVES="$HOME/Library/Caches/plank-native/downloads"
python3 scripts/apple-native/build.py prepare --platform device \
  --work "$PLANK_NATIVE_WORK" --cache "$PLANK_NATIVE_ARCHIVES"
python3 scripts/apple-native/build.py deps --platform device --work "$PLANK_NATIVE_WORK"
python3 scripts/apple-native/build.py build --platform device --work "$PLANK_NATIVE_WORK" \
  --client "$PLANK_CLIENT_SOURCE"
```

`prepare` obtains the exact public Git commits and verifies/unpacks/patches the
archives. `deps` independently verifies the sources, fetches locked Cargo inputs,
and builds FFmpeg, Opus and sodium into the work directory. `build` verifies
the dependency inventory and selected Client source, then compiles with signing
disabled and Cargo offline in an isolated Cargo cache. Apple Silicon's linker may
emit an ad-hoc executable signature; developer/distribution signing and signed
resource envelopes are rejected. Generated libraries, receipts and the app live under
the work directory. A failed stage does not remove or overwrite an existing app.
Use a new work directory after failure; diagnosis remains available in the old one.

The Mac recipe requires a Client commit with the Mac pilot; the Vision checkpoint
alone does not contain that target. Mac FFmpeg uses shared libraries in the
private work prefix. This compile bundle is not a relocatable release package;
embedding dependencies, release signing and distribution are separate gates.

## Verification

```sh
python3 scripts/apple-native/test_build.py
bash scripts/apple-native/test.sh "$HOME/Library/Caches/plank-native/policy-tests"
python3 scripts/apple-native/build.py verify --platform device --work "$PLANK_NATIVE_WORK"
```

`prepared.json`, `dependencies.json`, and `application.json` record the input lock,
platform, exact compiler/SDK versions and output inventory/hash. They are local
build evidence; do not publish machine paths or private logs in PRs. Compilation
does not requalify Wacom initialization, trust, precision fallback, audio clocks,
session interruption or network performance. The local policy runner checks
Wacom preflight, held-input release/recovery, focus, decoder recovery, alternate
approval routes, audio formats/levels and raw frame validation with assertions
enabled. It does not establish device acceptance. Carry the accepted device tests
forward and qualify changed behavior separately before production release.
