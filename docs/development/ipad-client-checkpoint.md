# Native iPad and Pencil sharing checkpoint

October10, 2026: the user accepted the installed iPad31 editor refinement and
requested publication of the completed development work. This checkpoint is
for review; it does not change the shipping platform matrix or release packages.

Subsequent feedback found menu overlap and remote Pencil interruption on editor
entry. Development build33 was accepted for duplicate movement, corner resizing
and landscape main/editor toolbar clearance and published in the existing draft
PR13 at `c3dfc42bb4272ab18616e022b441fdbbe9497bc1`. Editor peer continuity remains
a separate physical gate. See
[the current controls boundary](ipad-custom-controls.md#menu-protection-and-editor-continuity--ipad32).

The authored editor aspect and editing check from42 remain accepted. Local
Fit/2× operating-view build43 is now installed and open on the new M5 after
the user's disconnected installation authorization. App inventory and its exact
running executable verify43/0.1.0; physical zoom qualification remains pending.
The subsequent user trial reports severe intermittent Pencil latency: normal
speed for a period followed by very slow response. This is not an accepted43
result. Retained logs and an unsynchronized, largely idle device profile do not
yet identify the delayed stage or establish that zoom caused it. Earlier editor
and input acceptance remains recorded; new zoom qualification is held during
the investigation.

## Review order

The accepted upstream Apple/Mac foundation is
`e8d8536486bf2eb0d7080aab8965f12d7d87b0af`. Optional Mac tablet sharing and
display/wheel changes remain separate dependent reviews:

1. [Mac sharing](https://github.com/cnoellert/plank-client/pull/11).
2. [Mac displays and wheel](https://github.com/cnoellert/plank-client/pull/12).
3. [iPad and Pencil controls](https://github.com/cnoellert/plank-client/pull/13),
   `codex/ios-ipados-readiness`, based on `codex/native-mac-displays`.

The iPad branch was rebased onto the accepted upstream foundation during
development. Publication also merges the original display review tip
`b45921542e9e7224fc6787ee0abc09e2d10e5e8a` into its ancestry. The merge tree
is exactly identical to the accepted pre-merge tree. This preserves both
histories and keeps the stacked review diff specific to the iPad/Pencil slice.
Retarget these slices upstream in dependency order after their bases are accepted.

## Runtime provenance

| Target | Compiled runtime source | State |
| --- | --- | --- |
| iPad43 | `5a2ea686a3bab92df91af69c17a4ca4de1e31dca` | Shared local Fit/2× crop, matching image/cursor/input, Hand and fixed-footprint navigator in direct Desktop and Sharing; policy/contact, native rendering and independent signed package checks pass; installed/open on M5 with exact43/0.1.0 and matching running executable observed; physical zoom check pending |
| iPad42 | `cdfbe5f004019c8e67102cc6d83a0cc6b3f76cbb` | Rebased after Alan main refresh; editor outline, keys, labels, guides and gesture inversion share the authored portrait/landscape canvas; whole rendered-editor checks, old41 tall-entry negative control and independent package review pass; installed/open on M5 with exact42/0.1.0 and running executable observed; user accepts requested physical outline/arrangement through window resize and selected control movement/resizing |
| iPad41 | `910c52fff4264c42a5fb666b1ed01aedb2f346f9` | Installed/open on M5 after authorization, exact41/0.1.0 and running executable observed; physical fixed-canvas gate failed: tall editor window keeps a tall outline around fitted landscape keys; selected-edit gate not separately answered |
| iPad40 | `44f29cebd5a97290bccffcdc331e59a3a328234f` | Drawing-only editor preview chrome correction; installed/open on M5 after disconnected authorization, exact40/0.1.0 and running executable observed; reserved-band check superseded by artist-approved whole-canvas policy41 |
| iPad39 | `549bd8e4fef1f8cfdc46fc2624eb352fdbc44957` | Installed/open on M5; user accepts fullscreen naming and general button scaling/placement; smaller-window reserved top/bottom bands remain visually odd |
| iPad38 | `000c72132e9d21c5bbff8d06443e1ad7fe0fb966` | Installed on new M5; artist reports fullscreen connected naming still fails and smaller-window controls scale incorrectly; physical naming gate failed |
| iPad37 | `535c48667d35bafcd322f692ae07703d579040cc` | Local inline layout rename and chrome-safe editor rows; installed/open on new M5 after disconnected authorization, exact version/running path verified; top-row snap accepted, connected Rename still fails/switches back |
| iPad36 | `7a5fe82d14f47c073e308af63a73ac6c6cb42014` | Built, signed and installed/open on new M5; exact version/running path independently verified; physical finger-filter acceptance pending |
| Vision52 / Mac29 | `e8b928ffd8b253edc959c7669b2cc23b50aa99f2` | Image-only recovery: Vision52 installed/running; artist reports picture visible with better latency, below expectations; image promotion held; Mac29 staged/unlaunched |
| iPad35 / Vision51 | `a102d8c8460fc851b4c55e84fc9acdafda17a3a9` | Optimized conversion and proportional shared image/Pencil mapping: iPad35 installed/open and independently verified on new M5/iPadOS26.6; Vision51 staged; physical image latency/alignment unqualified |
| Mac28 | `a102d8c8460fc851b4c55e84fc9acdafda17a3a9` | Signed and independently verified, staged and unlaunched; physical Pencil reception/image sending pending |
| iPad34 / Vision50 | `4a14a47e8f8fb62413f4a8c60f85fb5ecf72329a` | Separate dimmable reference-image slice: installed and exact running executables independently verified; user rejected picture latency/stretching as unsuitable, image promotion held |
| Mac27 | `4a14a47e8f8fb62413f4a8c60f85fb5ecf72329a` | Signed and staged; physical Pencil reception and image sending pending |
| iPad33 | `e7c8ecc354ae62890c2607e8735c92d103291fd6` | Signed, installed and independently verified; targeted move/resize and landscape toolbar clearance accepted |
| iPad32 | `387d0d73ebbbc03fe3aa6506eaa63c3cee5bb83b` | Historical installed candidate, superseded by33; signed rollback retained |
| iPad31 | `1a788801d8e48ebb3498e3c029ddee2d44afe227` | Signed, installed, exact running executable independently verified; targeted editor acceptance recorded |
| Vision49 | `0a71d0c0cef026e74844dde495e186f799b32068` | Signed and installation verified; subsequent Pencil sharing accepted by the user |
| Mac26 | `0a71d0c0cef026e74844dde495e186f799b32068` | Signed and staged; physical Pencil reception pending |

The original iPad31 publication recorded history and documentation only.
iPad32 contains the subsequent local menu/admission correction; signed iPad31
is retained for its rollback. Signed iPad30 is also retained. The public recipe and dependency pins are unchanged
from the compiled candidates; no Host, network or app identity change accompanies
publication. Private signing profiles, device receipts and logs are excluded.

## Included behavior

- Isolated single-display iPad client: playback, audio, login, saved workstation,
  aspect-fit modes, mouse/pointer input, physical wheel and hardware keyboard.
- Direct normalized Apple Pencil pressure, navigation, hover where supported,
  and lifted-tip squeeze right-click; Apple/PC mapping for received keyboard keys.
- Native live software keyboard without a local typing preview. The tested
  full-size Pencil-held setup uses **Settings → Apple Pencil → Scribble off**.
  Credential and control-label editing remain local native forms.
- Foreground authenticated local-network Pencil publisher with separate physical
  comparison/approval, normalized pen records and bounded allowlisted shortcut
  batches. Vision and Mac receivers select one tablet source; this does not
  fabricate a raw Wacom identity.
- Normal client-screen Pencil Sharing, neutral charcoal pad, independent margins
  and mapping choices. Saved artist controls serve Desktop and Sharing together.
- Full control editor: position, dimensions, edge/neighbor snapping, key/combo
  binding, generated or custom labels, layout library and undo. Quick layout
  selection, touch-and-hold editing, visibility and transparency are in the toolbar.
  Empty-space taps dismiss the inspector; tapping a control reopens it; moves
  and resizes hide it without dropping selection or gesture state.
- Candidate36 adds persistent **Ignore finger input** for remote desktop
  finger clicks/drags. Artist controls, Pencil and physical peripherals remain
  available; local controls/forms retain their touch behavior.

## Recorded evidence

Direct iPad playback, mouse, supported resolution changes, Pencil pressure and
navigation, Space during Pencil drawing, squeeze right-click and physical-wheel
scrolling are accepted. Function keys are accepted with Fn held on a separate
Bluetooth Magic Keyboard; ordinary top-row brightness/media keys remain handled
by iPadOS. The observed Flame cursor offset resolved with Flame Tablet Margins
disabled; no client coordinate compensation was added.

Pencil sharing tip/drag/pressure, desktop reconnect, fresh strokes after rotation,
pad options and simultaneous finger shortcuts/Pencil drawing are accepted.
Subsequent user checks accepted naming, credential visibility, transparency,
shared placement/menu flow, layout shortcuts and the iPad31 inspector refinement.
These are targeted development passes, not the full platform/interruption matrix.

New M5 installation of35 is independently verified; it does not transfer the
older device's complete hardware qualification. Candidate36 checks execute the
production router and contact bodies with recording Host/stand-in touch delivery,
covering persistence, finger-drag release and stale callbacks, re-enabling input
and preservation of Artist/hardware keys, Pencil and physical mouse/wheel. Its
native device app compiles; actual OS touch delivery and Host receipt are pending.

Focused layout/migration/contact/ownership, wire/atomic admission, sanitizer
crypto and consented TCP loopback checks passed during development. Fresh target
builds and signing/profile checks passed for the candidates above. The iPad31
native editor fixture passed foreground priority, dismissal/reopening,
move/resize and one-step undo restoration. Its 77 protected source boundaries
and complete non-editor controls body match accepted30. Simulator injected
gestures do not establish physical Pencil or Host receipt; narrow-sheet swipe
was source reviewed only.

The iPad32 pure geometry checks passed menu exclusion, grouped translation,
unchanged point sizes, recoverable unavailable controls and exact Undo of
explicit draft geometry edits. Four focused native simulator cases passed
production-root admission through actual editor Done/Cancel, injected inactive
and background transitions, and genuine offer refusal. An authenticated loopback
peer remains approved across editing and admits a fresh stroke after resumption.
Actual visible/compact toolbar and consent rectangles match cached/editor
geometry and live control frames; the consent reservation clears after approval.
A preinstallation check caught and corrected an older Environment snapshot
reopening input during inactive dismissal. The corrected runtime was freshly
rebuilt and signed; the earlier candidate was never installed. Injected scene
events and simulated contacts do not establish the reported physical cause or
final Host receipt. The targeted physical iPad32 check remains pending.

## Separate remaining work

- Genuine finger cancellation and held-input release; focus/lock/background and
  final Host receipt. Local retirement or sender submission is not Host proof.
- Physical custom-control OS rotation/window sizing and four-corner pad margins;
  latency, remote tilt and continuous/horizontal scrolling.
- Physical Mac26 Pencil reception and the required OS/Host/profile matrix.
- iPhone, registered external-Wacom routes and direct iPad Wacom feasibility;
  the tested PTH-660 produced no direct USB/Bluetooth input.
- Upstream [issue9](https://github.com/instinctual/plank-client/issues/9) trust,
  exact precision, audio/input lifetime and maintained-parent reconciliation.
  Periodic video pauses and the prior Host receive-queue overflow remain open;
  further Host input-backpressure package work remains held.
- [Live reference image and dimming](ipad-live-image.md) remains a separate
  development slice. Installed iPad34 / Vision50 failed the picture usability
  trial. iPad35 is installed on the new M5; its missing-picture report is not
  isolated by current sender/receiver status yet. Vision52 / Mac29 add recovery
  from the reproduced startup latch defect; source fixtures pass but candidates
  are installed on iPad/Vision, with Mac29 staged. Optimized conversion, proportional geometry and sparse phase
  timings still require a physical trial. Image promotion remains held. Magnification and Bluetooth
  Pencil transport remain planned.

Build and focused check entry points are in the [iPad README](../../ios-native/README.md),
[public native recipe](../../scripts/apple-native/README.md),
[controls record](ipad-custom-controls.md) and [Pencil record](ipad-pencil-relay.md).
