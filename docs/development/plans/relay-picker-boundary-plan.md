# Relay selection and Setup ownership

Recorded October 1, 2026. Implementation brief approved for planning by the
operator. This slice finishes the Setup/Client product boundary; it does not
expand the Bluetooth investigation or the deferred settings-parity backlog.

## Outcome

An operator configures a Relay in Relay Setup, taps **Use in PLANK**, and finds
that same Relay selected in PLANK. Later they choose an existing Relay by name
or open Setup to configure another one. Addresses and transport configuration
are not edited in PLANK.

## Ownership and scope

- Relay Setup owns discovery, management authorization, USB/Bluetooth tablet
  setup, network configuration, diagnostics and tablet preview.
- PLANK owns its drawing trust, selection of a registered Relay, drawing-link
  establishment, and desktop-session input readiness and shutdown.
- Setup and drawing approvals are distinct in the current implementation.
  Keep the existing physical drawing approval as a one-time registration
  sheet when required. It is not a permanent Client Settings control. A Setup
  approval or an app link must not silently create a drawing approval.
- Native PLANK drawing remains on the existing network transport. Registering
  a Relay discovered over Bluetooth does not enable Bluetooth drawing.
- No new Relay protocol, crypto exchange, service, daemon, entitlement,
  privileged proof harness, or contract/fixture revision is part of this slice.
- No bitrate, audio, camera, adapter-selection or Bluetooth-performance work.

## Implementation order

### 1. Small registered-Relay list

Extend the existing identity-indexed selection/store rather than adding an
independent database or credential store. Persist display name and existing
validated route hints for each drawing identity, plus one selected identity
or an explicit Off selection. Keep approval material in the existing Keychain.

- Upsert by drawing identity; repeated handoffs update one record.
- Distinct identities with identical names remain distinct and get a readable
  name disambiguation. Do not expose keys as routine product UI.
- Preserve existing approvals and migration-conflict behavior.
- Migrate the current approved selection into the list without deleting legacy
  keys or changing private keys. Do not guess identities from names/addresses.
- Explicit Off must disable Relay preflight and connection, including the
  current legacy saved-connection fallback. Choosing Off does not erase trust.
- A saved Relay can remain listed while offline; listing is not proof of a
  successful current connection.

Relevant Client surfaces: `PlankRelayPairing.swift` (keys, selection and handoff
inbox), `PlankDrawingIdentityStore.swift`, and `PlankRelayLiveLink.swift`.

### 2. Finish registration through Use in PLANK

Reuse the existing validated app-link entry point and handoff gate.

- A valid handoff with an existing drawing approval upserts and selects the
  Relay. Keep identity verification on the actual drawing connection.
- If drawing approval is required, retain the pending validated descriptor and
  present the existing physical approval flow as a registration sheet. After
  successful approval, re-evaluate the descriptor before completing registration.
  Cancel/failure must preserve the prior selection and approvals.
- An identity conflict remains an explicit refusal; never overwrite a pin.
- If a desktop session is active, defer the selection change until disconnect,
  using the existing deferral path. Do not switch a live session's Relay.
- Duplicate links must not open duplicate approval sheets or connections.

### 3. Replace Client setup controls

In `SettingsView.swift`, expose one **Tablet Relay** picker:

1. Off.
2. Registered Relays by name.
3. Set up a Relay… (opens the separate Relay Setup app).

Remove Client-facing discovery, manual address/port, pairing and reauthorization
controls, including the Advanced disclosure. Retain implementation helpers only
where migration or the one-time registration sheet still needs them.

Use concise evidence-based status: Configured while idle, Connected after link
establishment, Unavailable after a connection failure, and Approval required
for pending registration. Explain the next action beside a failure. Keep actual
network-route details in optional diagnostics, not as editable settings.

Add a minimal launch-only URL entry point in Setup if none exists. If Setup
cannot open, show a clear installation/opening message. Do not fall back to
manual configuration in PLANK. Update Setup's current handoff-failure message,
which presently tells the user to add a Relay by address in PLANK.

### 4. Make Setup connection labels truthful

- Label the management row **Setup connection**; while idle, describe its last
  verified connection rather than claiming a live connection.
- Keep **Tablet → Relay** separate from **Setup → Relay**.
- In the running preview show the actual active transport from the connection
  that supplied the samples. Keep requested transport separate when relevant.
- Label the handoff route **PLANK drawing connection** and explain that native
  PLANK uses the network drawing link for the selected Relay.
- Label a completed diagnostic as **Last connection test**; invalidate or
  qualify that result when its Relay/transport context changes.

Relevant Setup surfaces: the existing Tablet/preview views,
`SetupCoordinator.swift`, and the app entry point/build configuration.

## Verification budget

Use the existing test targets and fakes. Add a handful of focused behavioral
cases: migration/upsert without duplicates; Off suppressing legacy fallback;
pending approval completing or cancelling safely; deferred selection; and
transport/status labels derived from actual state. Assertions must be active.
Reuse existing trust and malformed-link tests; do not reproduce their fixtures
or build another harness. Run the affected suites and signed visionOS builds
for both apps, once; repeat only to fix a demonstrated failure.

One live acceptance pass:

1. Existing approved Relay: Setup → Use in PLANK selects it without an IP field.
2. Repeat handoff and relaunch: one entry remains and selection persists.
3. PLANK → Set up a Relay opens Setup. Client Settings exposes only the picker
   and status, with no address, pairing or discovery controls.
4. Connect: movement, tip drag, pressure and buttons work; disconnect/reconnect.
5. Off: start a desktop session without Relay waiting or a hidden legacy link.
6. Preview/diagnostic/handoff labels identify the three different connections.

Exercise first-time approval, two Relay identities and route updates with
existing injectable tests unless matching hardware is available. Explicitly
record any live coverage still unavailable; do not require another radio or a
network reconfiguration just to complete this UI slice.

## Delivery and stopping point

Use an isolated `codex/` worktree from the accepted integrated Client and Setup
bases. Preserve the audit branch and concurrent Bluetooth work. Commit coherent
slices and update the canonical development notes with the final boundary.

Deliver the builds, changed-file summary, test results and short live checklist.
Finish after the acceptance pass. Packaging/publication can follow the existing
release workflow; no new planning milestone, proof framework or broad refactor.
