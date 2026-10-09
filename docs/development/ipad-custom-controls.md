# Shared iPad custom controls — design brief

## Confirmed direction — October 9

The user confirmed freely positioned keys across the drawing surface and
assignable keys/shortcut combinations. The same editor and saved layouts must
be available in the direct iPad desktop client and Share Apple Pencil. This
supersedes the proposed five-key-only, palette-confined editor scope.

Installed iPad22/Vision48 remain the current working candidates. This document
records the accepted design and candidate implementation. New editor and expanded sharing device qualification remain pending.

## Purpose and visual direction

An artist drawing on an iPad, often wearing an AVP, needs finger-accessible
shortcuts around the drawing area while the Pencil remains in use. The dark
charcoal surface remains quiet under the headset; the client variant overlays
controls on its remote canvas. Native iPad controls and semantic typography
follow PRODUCT.md. References are native iPad editing controls, the existing
PLANK pad options, and the accepted compact held-key presentation.

One **Custom Controls** entry opens the same layout library and editor from
both contexts. Showing controls is independent of opening the software keyboard.
Existing keyboard, Pencil, mouse and aspect-fit desktop input remain separate
input paths. Layout geometry must not alter remote coordinate mapping.

## Interaction contract

- Each control owns its identity, binding, label, width, height and position.
  Moving Space or changing traversal order never changes its size.
- Drag controls anywhere on the available canvas. Selection exposes resize
  handles and native width/height adjustments, with alignment guides.
- Each control binds one supported keyboard key with optional Shift, Ctrl,
  Option and Command. Initial actions are **Hold** (down while held, release
  when lifted) or **Tap** (one complete shortcut). Hold does not generate
  synthetic repeated presses. Sequential macros are outside this brief.
- Labels may name the artist's action, such as Undo; bindings remain visible
  in the editor. Defaults retain the five currently accepted controls and a
  wide Space. Adding, duplicating and removing controls is part of the editor.
- Layouts have names and portrait/landscape arrangements, with copy/reset and
  undo for edits. Saved layouts are shared between client and Pencil sharing.
- **Edit** works on a draft. Entering editing releases active controls and
  ends drawing contact. Done saves; Cancel leaves the previous layout intact.
  Working mode fixes control positions and shows held states.
- Finger and accessibility input can use controls. Pencil never activates a
  shortcut control. Provide accessible labels, held-state announcements and
  controls for position/size that do not require precise dragging.

Controls keep at least a 44-point hit area. Point sizes and normalized anchors
preserve useful sizes across contexts; clamp placement to the current surface.
Do not scale touch targets below that minimum to fit a smaller window. Validate
nonfinite/out-of-bounds geometry, bounded control counts and duplicate IDs.
Drawing margins and control placement are independent settings.

## Editor direction probes

Two generated sketches compare inspector topology, not shipped UI:

- **A — Edge controls:** modifier cluster near an edge, with a fixed side
  inspector while editing.
- **B — Split controls:** independent clusters around the canvas, with a
  compact inspector beside the selected control. Recommended to retain canvas
  space. It can use a native sheet in narrow windows.

Both permit free placement and the same bindings. The user selected **B**, the
bottom sketch, on October 9. Use the neighboring compact inspector and split
control arrangement. The probe's incidental text is illustrative: Hold sustains key state,
not automatic repeat. Image overlay is still separately planned.

## Source boundaries and implementation

Use one transport-neutral layout store, editor, overlay and action controller.
Direct desktop and Pencil sharing supply different sinks for the same key
edges; the renderer must not own transport or workstation policy.

The installed layout uses slot-dependent widths: indexes0–3 share an equal
row and index4 fills the lower row. Its position is transient SwiftUI State.
Import the existing sanitized key order when migrating, and preserve margin,
tone and consent settings. Stable per-control IDs own independent geometry.

Before connecting generic actions, introduce ownership per control/touch and
physical keyboard source. The direct router currently owns keys by code only;
the sharing receiver currently tracks only five modifier identities plus right
Command. First owner sends down, last owner sends up. Snapshot a control's
binding at contact start so changing its assignment cannot change its release.
Duplicate controls and overlapping combos must not release another owner's key.
Physical repeat retains its existing behavior.

Press a combo's modifiers before its trigger and release the trigger before
owned modifiers. Reserve capacity for an entire edge batch before updating
ownership. Hide, edit, geometry replacement, focus/background and disconnect
retire the relevant owners. Local retirement is not final Host receipt.

Sharing version2 is authenticated for the five existing key identities only.
General letters/function keys need an explicit new capability/version and
separate comparison/approval, preserving old identities and approval records.
Update the AVP and shared Mac receiver together. The expanded version3 capability requires matching new publisher/receivers and a fresh physical comparison. Version2 clients are not discovered by this capability; existing v1/v2 approval records remain intact. There is no partial or silent combo delivery. Reuse the existing Host
key transport; no Host package change is part of this feature.

Suggested coherent slices:

1. Shared layout/action model, legacy migration and bounded key ownership.
2. Native editor/library and overlay in both iPad contexts.
3. Expanded authenticated sharing capability and matching AVP/Mac receivers.
4. Signed candidates, then targeted direct-client and shared-Pencil acceptance.

## Verification and open gates

Focus tests on migration, independent geometry, invalid layouts, duplicate
bindings, hardware-plus-control holds, overlapping combos, cancellation and
batch admission. Include compatibility/replay/consent checks for the expanded
sharing capability and actual UIKit editing/hit-testing evidence.

Device checks must cover resizing and moving Space without size changes,
saved layouts in both contexts, simultaneous finger/Pencil use, tap/hold combos
with hardware keys, rotation and safe editor entry/exit. Preserve accepted
input tests; do not repeat qualification unrelated to these changed paths.

Build22 was reported generally working, and hotkeys were already accepted.
Its Space-width limitation is confirmed. The earlier margin report has local
corner evidence but no explicit four-corner physical result; do not claim that
gate complete from general feedback. Focus/lock/background and final Host
release remain separate Pencil source gates.

## Candidate implementation — October 9

The iPad editor and saved library now serve both direct desktop and Pencil
sharing. Each control retains independent size, normalized placement, label,
binding and hold/tap behavior. Space is initially selected for editing. Native
size/position controls supplement drag and corner resizing; the compact inspector
sits beside the selection, with a native sheet on narrow canvases. Editing a
draft sends no remote keys. Done stores a valid library; Cancel preserves the
saved layout. Layout copy/reset and bounded undo are local.

Protocol3 advertises `normalized-pen-keys` and authenticates
`PLANK-NORMALIZED-PEN-KEYS/3`. Its bounded key batches reserve all input edges
before changing ownership. Old identities and v1/v2 consent records are retained;
expanded key authority requires a fresh comparison approval. AVP and native Mac
receivers use the same capability. No Bluetooth sharing or image overlay is added.

The direct input controller merges hardware, software and finger ownership for
all supported keys. A rejected nonempty key batch ends the session and clears
local ownership only after session invalidation; it does not continue with an
unknown held-key state. This is local cancellation, not final Host release proof.

Focused layout/migration/ownership, codec/queue, sanitizer-backed crypto and
consented TCP loopback checks pass. Actual UIKit control hit-testing, two held
controls, cancellation on disable/rotation and layout replacement, and independent
Space width pass in an isolated simulator fixture. Physical editing gestures and
changed direct/shared shortcuts remain device gates. Historical input acceptance
is preserved but does not qualify the new editor or expanded capability.
