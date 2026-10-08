# Native Mac integration slices

Tracking: [upstream coordination issue 9](https://github.com/instinctual/plank-client/issues/9).

## Baseline and review order

The Vision foundation and transport correction are merged into Client
`apple-native-integration` at `1953cc11a4b281f24286c11301d10fc76601a972`.
Shipping main is a separate baseline. These Mac contributions build on that
integration merge, at the existing paths, as a separate native pilot application.
The eventual `apple/shared` directory move remains a mechanical follow-up.

| Slice | Branch | Original checkpoint retained as an ancestor | Runtime compile source |
| --- | --- | --- | --- |
| Native Mac foundation | `codex/native-mac-foundation` | `da0bb7c3575281b49cb63dfcb90f572cc5f1aeab` | `a30f08e` |
| Optional authenticated USB tablet sharing | `codex/native-mac-tablet-sharing` | `8109c8d6148132af1855a5395c1c1bd20ab29577` | `16ef937` |
| Display geometry, session controls and physical wheel | `codex/native-mac-displays` | `04675c95c9486e8f22d7587348d705bb44aeb1a4` | `fd844b5` |

Each selective history merge keeps original commits/authorship while importing
only the chosen native files and narrow shared seams. The final native tree
matches the accepted Mac build-24 publication, apart from the integration
Vision README. The shared physical Wacom worker is deliberately reconciled
with the maintained integration worker rather than replaced with its older
pilot copy. Build receipts distinguish compiled runtime from later documentation.

The foundation targets upstream `apple-native-integration`. The other two
branches form a dependent stack: sharing targets foundation; displays targets
sharing. Until their bases exist upstream, their review PRs live in the fork.
They must be retargeted for upstream integration in dependency order. A fork
review is not a merge into Alan's maintained repository. The original Mac
PRs remain historical checkpoints, not competing implementation targets.

Review entry points: [upstream foundation PR 11](https://github.com/instinctual/plank-client/pull/11),
[fork sharing PR 11](https://github.com/cnoellert/plank-client/pull/11), and
[fork display/wheel PR 12](https://github.com/cnoellert/plank-client/pull/12).
These are drafts; none of these Mac slices has merged upstream.

## Boundaries

- The existing Qt/SDL application remains the shipping application. Foundation
  changes its shared Wacom worker only to allow an injected sender and a native
  compile boundary; its maintained permission/presence APIs remain intact.
- Sharing adds a physical worker-owned capture lease, durable Relay generations,
  authenticated TCP drawing/management, explicit local approval and opt-in UI.
  Shipping capture participates in the lease; its permission request remains
  with its existing launcher. This shared-worker change needs shipping CI review.
- The native application remains `la.instinctual.PLANK.NativeMac`, Apple Silicon,
  macOS 15 minimum and SDK 27 build. It has its own bookmark namespace. Mac
  sharing supports USB Wacom and TCP to AVP; it does not advertise Mac Bluetooth
  capture, Mac-to-AVP Bluetooth, or Linux administration/decoded Setup preview.
- Display placement uses the existing Host topology/layout contract. No Host
  contract extension or package is introduced. Global session disconnect and
  fullscreen controls coordinate both windows; native green-button operation
  can remain specific to one window.
- Transport, crypto and Relay codecs remain in their owning repositories with
  the merged public recipe's explicit pins. No new protocol is copied into
  Client. Current-parent trust, precision, audio/input and CI reconciliation
  remains upstream-led through issue 9.

## Build and component evidence

All three runtime slices passed fresh public input preparation, dependency
compilation and unsigned Mac application compilation with integration common-C
`036df96f2d1577af7a1b08c05d87a5218fff7c9b`. Use the
[public recipe](../../scripts/apple-native/README.md), choosing a fresh work
directory for each platform. Signed release staging remains separate.
The final stack also passed a fresh unsigned Vision device compile at
`1bcb595a6f8a9156490186e513a5304fdb072e04` (documentation-only successor to
`fd844b5`), checking the shared session/input/topology source against SDK 27.
It was not installed or launched on a headset.

| Check | Foundation and sharing | Displays |
| --- | --- | --- |
| Input/focus policies | 552 | 568 |
| Cursor/fullscreen composition | 19 | 28 |
| Local controls/fullscreen delegate | 40 | 88 |
| Production C wrapper with Swift foreign-thread callback | 266 | 266 |
| Decoder recovery | 137 | 137 |
| Multi-display policy | Not imported | 86 |

Worker lifetime/barrier/epoch/backlog and tablet outage-policy suites also
passed. Sharing passed 55 managed Setup codec checks, 1,791 raw protocol,
enrollment/generation/lease checks, and real loopback socket tests for fragmented
discovery, ordered raw reports, bidirectional control and malformed public
metadata refusal. Hardware workers are faked in these component suites; there
is no physical tablet or OS Space-animation acceptance claim.

Run focused suites from the corresponding Client checkout:

```sh
bash scripts/test-macos-native.sh "$PLANK_NATIVE_TEST_OUT"
PLANK_RELAY_SOURCE_DIR="$PLANK_NATIVE_WORK/git/raw" \
PLANK_MANAGED_RELAY_SOURCE_DIR="$PLANK_NATIVE_WORK/git/managed" \
PLANK_RELAY_SODIUM_PREFIX="$PLANK_NATIVE_WORK/install" \
  bash scripts/test-macos-relay.sh "$PLANK_RELAY_TEST_OUT"
```

Relay tests apply to the sharing/display slices. Use a different test output
directory per slice. The app bundles are unsigned compile artifacts with local
shared FFmpeg references, not relocatable, notarized release packages.

## Acceptance carried forward and new gates

The original Mac build-24 runtime is `5db90ffeb7568105a664df0f340c5769c79b0603`;
publication is `04675c9`. Carry its targeted primary/secondary geometry,
session/window controls, mouse/pen, physical wheel and balanced middle-button
acceptance. Carry build-16 Mac sharing performance, background focus,
reconnect, USB return on the accepted Flame4 pressure policy, and Mac sleep/wake
evidence from [the tablet-sharing checkpoint](plans/macos-tablet-relay.md).
Earlier Flame3 hover-only USB return and intermittent Wacom startup are explicit
observations, not erased by later passes. Historical Linux Relay tests do not
qualify Mac hardware behavior.

New physical acceptance should target changed inputs and worker reconciliation:

1. With the accepted Host pressure policy verified, connect tablet-first; check
   hover, tip pressure, clicks, held drag and buttons before and after reconnect.
2. Verify local permission behavior and exclusive ownership between direct Mac
   capture and opt-in sharing, including another cooperating process. Stop/quit
   must return ordinary local tablet input. No unknown network peer may prompt
   for permission or acquire capture.
3. For reconciled teardown, disconnect with a held tip/button, then connect
   tablet-first. Separately exercise stream failure: do not infer Host release
   from physical closure or local transport submission alone.
4. Exercise the changed worker with hotplug/focus/fullscreen transitions using
   the same bookmark; repeat broader accepted flows only if these changes fail.
5. Establish the required macOS 15/27 same-package matrix and supported
   Host/profile scope. The development Mac's macOS 26.7 passes are not that matrix.

Compile/component success does not make the merged combination production
qualified. Periodic video pauses, the prior Host input receive-queue overflow
and upstream trust/format/audio gates remain open. Host input-backpressure
package work remains held. This preparation changes no live installation,
device or network settings.

## Next independent features

Capture quality remains [the separate original PR 6](https://github.com/cnoellert/plank-client/pull/6),
checkpoint `d264ed4904e2856cead65d7aab48f6c14d0ce063`. It is absent from
accepted Mac build 24 and this stack. Its capability selection and HTTP/session
negotiation touch the same areas as upstream exact-format reconciliation:
integrate it after that contract is settled, preserving explicit rejection
instead of claiming 10-bit presentation from an 8-bit decoder fallback.
The prior 8/10 selection pass proves switching only, not output precision.

Camera source/encoder acceptance is checkpointed separately. Product camera
negotiation, Linux receiver/application, consent and concurrent desktop/audio/
tablet qualification follow the native foundation. iOS follows shared-core
stabilization; it is not an acceptance target of this Mac import.
