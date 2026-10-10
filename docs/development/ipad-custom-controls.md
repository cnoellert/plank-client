# Shared iPad custom controls — design brief

## Confirmed direction — October 9

The user confirmed freely positioned keys across the drawing surface and
assignable keys/shortcut combinations. The same editor and saved layouts must
be available in the direct iPad desktop client and Share Apple Pencil. This
supersedes the proposed five-key-only, palette-confined editor scope.

Installed iPad24/Vision49 provide the revised custom controls. On October 9 the
user tested both Pencil sharing to AVP and the direct iPad desktop, reporting
that placement and operation work considerably better. Intermittent button
releases remain unresolved; this feedback does not qualify all interruption
or final Host release gates.

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
- Drag controls anywhere on the available canvas. Edges and neighboring
  controls snap into rows/columns with a six-point gutter and alignment guides.
  Resize mode exposes corner handles; native width/height adjustments remain
  available without precise dragging.
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
  shortcut control. A finger hold survives movement outside the key until lift
  or genuine cancellation. Provide accessible labels, held-state announcements
  and controls for position/size that do not require precise dragging.

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

The earlier five-key layout used slot-dependent widths: indexes0–3 shared an equal
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

## Editor and contact revision — iPad24

The user supplied editor/live screenshots and reported that the positions did
not match, Pencil drawing sometimes illuminated controls, and finger-held
controls sometimes released while drawing. These are reported failures, not a
completed custom-controls acceptance.

The editor now fills the screen and previews the last measured live surface.
Both the canvas and the resolved button rectangles use one uniform scale;
drag/resize deltas convert back into live points. Saved button sizes and
normalized centers remain unchanged. Landscape and portrait arrangements use
their measured surface sizes when available, cached separately for Desktop and
Pencil Sharing. Six-point edge/neighbor snapping
supports aligned rows and columns, with resize snapping to neighboring sizes.
The inspector toggle stays within the preview; separate Resize mode keeps
corner hit areas from intercepting ordinary movement.

Shortcut ownership now admits actual direct finger contacts only, using a
snapshot of the binding and touch owner. Pencil contact over a control forwards
the real touch and coalesced samples to the underlying drawing surface without
highlighting or pressing the shortcut. Pencil hover and squeeze use that
surface's coordinates. A finger hold survives drift outside the control;
lift, genuine cancellation, disable, geometry/layout replacement and teardown
still release it. Direct-client Pencil cancellation retires the pen alone,
preserving independently held hardware and custom-control keys. Editing pauses
sharing input and preserves the authenticated peer; background/explicit stop
retain their existing retirement behavior.

Global input retirement advances an input epoch in both iPad paths. The overlay
retires its visible finger/accessibility owners on that same epoch even if its
bounds and layout are unchanged. Stable refreshes retain the current hold.
This prevents a blue Held control from outliving a released remote modifier
after video geometry or remote configuration changes.

The existing version3 protocol, identities, consent, Host and dependency pins
are unchanged. Vision49 and Mac26 remain matching receivers. Physical Pencil
and palm cancellation, saved placement on both live contexts, editor entry/exit,
and final Host release receipt are separate gates. Aggregate contact lifecycle
counts are bounded; typed text, bindings and positions are not logged by them.

## Follow-up — quick visibility and remaining cancellations

The user accepted the improved controls in both contexts, with intermittent
held-button releases still reported. The retained sharing log includes real
UIKit cancellation of admitted direct contacts, without layout, geometry or
explicit retirement. The later direct-client segment contains no corresponding
recorded cancellation. Palm rejection and a system/ancestor gesture remain
possible causes, not established diagnoses. A genuine cancellation continues
to release the hold; silently latching the modifier would change its contract.

Candidate iPad25 makes the grid icon a one-tap Show/Hide Controls button in both contexts.
The direct desktop retains it beside the toolbar restore button when bars are
hidden. Long-press the grid icon for Edit Controls, also exposed as an
accessibility action. Hiding controls releases their owners. No physical
keyboard shortcut is assigned by this slice.

On real admitted finger cancellation, bounded diagnostics record concurrent
Pencil contacts, public touch/ancestor recognizer categories and states, and
scene activity. These are correlations, not an OS cancellation reason. Counts
are saturated and logging is rate limited; no text, binding, touch identity or
coordinates are logged. Cancellation still releases the key normally.

## Naming revision — iPad26

The user reports iPad25's editor and onscreen controls working better, but the
keyboard made naming unusable. The embedded inspector existed only while the
uniformly scaled preview stayed wide enough. A docked keyboard could shrink
that preview past its threshold and remove the focused text field. Local
editor text is not remote input; the direct router remains disabled in editing.

Naming now uses a native Cancel/Save text popup outside preview geometry, from
the active editor or narrow inspector presentation. **Button label** is the
only naming action in the Control inspector. The layout title identifies the
saved arrangement and is renamed explicitly through **Rename Layout** in the
layout menu. Each popup changes the editor draft once; the editor's Done saves
the library and Cancel preserves the previous saved layout.

Changing a key or its modifiers updates a label that still follows the key
name. Duplicating Space and assigning Ctrl therefore names the new button Ctrl,
without changing the original button or either placement. Artist action names
such as Undo remain intact. **Use Key Name** restores automatic naming. Existing
saved labels and the legacy Command glyph are recognized without a storage or
wire migration; generated names stay within the existing 40-character limit.

The label/model checks cover copied controls, custom names, legacy glyphs,
invalid bindings, unchanged geometry and every supported key/modifier name.
The user accepted the installed iPad26 naming revision on October9: “Works
really well.” This is targeted naming acceptance; no new pen, wheel or transport
qualification is implied. Intermittent real finger cancellation remains a
separate open issue. The subsequently reported credential-screen keyboard
occlusion is a separate local login layout issue.

The next image feature is separately planned in
[live image and magnification](ipad-live-image.md): adjustable image intensity,
Fit and true pixel magnification, with a shared image/input mapping. It is not
implemented by the visibility change.

## Transparency and sharing surface revision — iPad28

The user accepted the installed iPad27 credential keyboard revision: “That
works great.” That local login gate is resolved; earlier naming, input and
transport acceptance remains unchanged.

Long-press the Show/Hide Controls grid icon for **Edit Controls…** and
**Transparency…**. The transparency popup provides one persistent global
slider shared by iPad Desktop and Pencil Sharing. It changes control color
layers only. Hit targets, saved geometry and finger ownership are unchanged;
labels remain readable and held controls retain a clear highlight at maximum
transparency. This is artist-control appearance, separate from the planned
live-image overlay.

The reported sharing overlap has a measured cause: the sharing-only pad was
shorter than the whole available client surface, and status/approval content
could shorten it further. Absolute button dimensions remained correct while
normalized centers moved closer together. The actual pad, UIKit overlay and
reported GeometryReader agreed, so this was not an incorrect UIKit scale.
The revised sharing controls and editor use the whole available content
surface, independently of the drawing pad's margins and status content. Pen
coordinate mapping remains owned by the pad. Saved labels, bindings and
placements are preserved.

Sharing instructions now say: “On the PLANK client, choose this iPad in
Settings → Apple Pencil.” Approval and focus instructions also refer to the
client, supporting the existing Vision and Mac receivers. No wire capability,
identity, approval, Host, network or dependency change is part of this slice.

Focused appearance/persistence/contact and actual portrait sharing-surface
component checks pass. Status/approval transitions preserve the control
surface and held finger ownership; resizing that surface still releases held
keys. Pencil coordinates remain relative to the actual pad, and pad resizing
retires the stroke independently. Physical transparency and the reported
sharing layout are not yet accepted; orientation and window sizing remain
device gates. Real finger cancellation remains a separate open issue; this
revision does not latch a cancelled key.
