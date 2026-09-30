# Relay connection handoff execution plan

Status: proposed implementation plan; no handoff code is included in this checkpoint.
Prepared September 30, 2026 for coordinated execution across the three repositories.

## Goal

After commissioning a Relay in the standalone Setup app, tap **Use in PLANK**
and select its verified drawing connection without entering an IP address.
PLANK reconnects by the drawing Relay identity, not by treating every new address
as a new device. Keep the accepted hardware-decoded 60 fps drawing baseline.

## Starting checkpoints

| Repository | Starting source | Purpose |
| --- | --- | --- |
| Client | `cnoellert/plank-client`, `codex/visionos-wireless-checkpoint` | Current source/build checkpoint; `visionos-0.1.0-12-source` preserves the accepted TestFlight source |
| Managed Setup/service | `instinctual/plank-avp-relay`, PR #1, `cnoellert:codex/managed-capture-lease` | Setup 0.6.4, shared capture lease, authenticated route discovery |
| Raw drawing Relay | `cnoellert/plank-tablet-relay`, `codex/wacom-wifi-checkpoint` | Existing CPace/Noise raw-HID drawing service, Bluetooth tablet capture, shared lease |

Resolve these branch names to full commits before starting and record them in
the implementation PRs. Rebase against newer upstream work as a separate review:
this plan does not qualify a rebase or change the current video transport.

Current live acceptance: USB and Bluetooth tablet readings, Setup/PLANK capture
handoff, and a fresh drawing connection over Relay Wi-Fi with Ethernet unplugged.
USB remains the best long-curve reference. The Host pressure-recalibration policy
is a separate required integration change. Sustained sessions and repeated
sleep/hotplug remain open qualification items.

## Boundary and first release

Setup owns tablet pairing, network provisioning and administration. PLANK owns
its desktop session, its drawing identity, input readiness and connection status.
The two services keep their current protocols and distinct identity stores.

Version 1 updates routes for an **already approved drawing Relay**. Setup approval
is not PLANK approval. An unknown drawing identity remains unapproved and leads
to PLANK's explicit existing drawing-approval flow. Do not silently enroll a new
Client, share Keychain private material, or change either crypto protocol here.
A later enrollment-bridge design can remove that remaining first-time step.

### Proposed contract

Define `plank-drawing-handoff-v1` as a bounded public connection descriptor:

| Field | Meaning |
| --- | --- |
| version | Exactly 1; reject unsupported versions |
| requestID | UUID for duplicate handling, not an authorization token |
| displayName | Bounded Relay name for confirmation |
| managementIdentity | Public managed-service identity, labeled separately |
| drawingIdentity | Public raw drawing-service identity; must match PLANK's saved pin |
| drawingProtocol | Explicit existing raw-HID protocol identifier and version |
| routes | At most eight TCP address/port candidates with interface metadata |

The managed service obtains this descriptor from a narrow **local public-status
interface implemented by the raw service**. It must never read or export the raw
service's private key. Constrain local status to public identity, protocol and
configured listener routes; expose no tablet samples, Client allowlist or capture
control. Handle raw-service absence without opening enrollment or taking capture.
Serve the descriptor only over the authenticated managed connection.

Setup passes the descriptor through an app link, for example a registered
`plank-vision` URL. Treat every incoming URL and route as untrusted. Enforce a
4096-byte decoded payload limit, strict field/types, bounded strings and route
validation before any network activity. The contract review must settle the
exact scheme/path, encoding, supported address classes, interface scope, and
unknown-field policy with shared positive and negative fixtures. Never include
private keys, Wi-Fi passwords, pairing codes or Host credentials in a URL.

PLANK presents the selected Relay. It matches an existing saved drawing pin and
performs the current authenticated drawing handshake before accepting a route.
A different managed identity cannot replace a drawing pin. A route cannot make
a new key trusted. Decline handoff while a desktop session is active and offer
to use it after disconnect; never interrupt a stroke because another app opened
a URL. Deduplicate repeated requests without treating requestID as proof of trust.

No background network migration or seamless mid-stroke failover in version 1.
On link loss, release input, show a recoverable connection state, and use freshly
verified routes for the next connection. Do not replay old input.

## Assignments and ownership

Each execution agent works in its own branch/worktree. Agents are not alone in
the codebase: preserve others' changes and integrate against the pinned contract.
Only the integrator deploys or closes live sessions.

| Workstream | Owned files / responsibility | Depends on |
| --- | --- | --- |
| A: contract lead | This plan; new canonical contract document and shared fixtures in raw Relay `docs/` and `tests/`; review trust/lifecycle decisions | Starting checkpoints |
| B: Relay services | Raw Relay `src/main.cpp` and new local public-status module/tests; managed `tools/avp_relay/core.py`, status plumbing and service package policy/tests | A |
| C: native PLANK | `visionos-native/Info.plist`, `Sources/PlankVisionApp.swift`, `Sources/Services/PlankRelayPairing.swift`, `PlankRelayLiveLink.swift`, new handoff/identity-route model, `Sources/Views/SettingsView.swift`, tests and CMake wiring | A; B contract fixtures |
| D: standalone Setup | `apple/RelaySetupKit/TabletManagement.swift`, `SetupCoordinator.swift`, new descriptor model, `apps/tablet-setup/Sources/TabletSetupView.swift`, model/UI tests and build wiring | A; B descriptor response |
| E: integrator | Cross-repository evidence, package/source provenance, signed builds, installation sequence and live qualification | B, C, D |

B, C and D may execute in parallel after A is reviewed and fixtures are pinned.
Do not let B and D both edit the Apple Setup library; B owns the Linux response,
D owns its Apple decoding. Protocol revisions go through A before consumer edits.

## Deliverables and acceptance by workstream

### A — freeze the descriptor and recovery behavior

- Confirm current raw and managed identity/protocol formats from executable code.
- Specify local IPC permissions/lifecycle and optional backward-compatible status
  field; an old service or app must produce a clear unsupported state.
- Publish fixtures for valid known identity, unknown/mismatched identity, malformed
  payload, oversized input, duplicate request, wrong protocol and invalid routes.
- Review that version 1 never turns app-link data into enrollment authority.

Exit: all implementers use the same contract hash and vectors. No server or UI
code is merged before these decisions are concrete.

### B — publish drawing metadata without capturing the tablet

- Raw service exposes only the public descriptor through the agreed local IPC.
- Managed authenticated status includes the optional drawing descriptor. Keep
  existing `tcpPort`/`networkAddresses` semantics for managed connections.
- Route collection respects the installed socket-family policy; errors yield an
  unavailable descriptor, not disconnection or weaker service confinement.
- Tests cover raw-service restart/absence, invalid local metadata, unauthenticated
  requests, permission denial, route bounds, and unchanged shared capture lease.

Exit: installed managed service can read the public descriptor without opening
input nodes or private keys; existing Setup and PLANK tests still pass.

### C — select by pinned identity and verify the drawing route

- Introduce identity-indexed drawing connections with a set of route candidates.
- Migrate existing address/service Keychain records without deleting approvals
  or writing a new pin from discovery. Keep the current Client private key local.
- Parse app links independently of view state; show a compact Relay selection
  and status. Put manual address/port under Advanced.
- Cancel and finish the old connection before starting a replacement. Preserve
  finite startup deadlines, focus recovery, readiness gating and input release.
- Show the actual route/interface when known. If it is unknown, say Network;
  do not infer Wi-Fi from the fact that the headset itself uses Wi-Fi.
- Tests cover migration, matching pin across changed addresses, identity mismatch,
  unknown approval, malformed URL, duplicates, active-session refusal and cancel.

Exit: build verified with Relay integration enabled; no codec, shader, frame-rate
behavior or drawing authorization changed as part of this workstream.

### D — offer Use in PLANK after Setup is ready

- Decode the optional descriptor using A's bounds and fixtures.
- Make the action available only after the authenticated Relay reports a usable
  drawing descriptor. Distinguish missing drawing service from authorization errors.
- Stop and release a running Setup tablet test before offering the handoff.
- Open PLANK with public metadata only; provide a useful fallback if it is absent.
- Keep commissioning controls in Setup. Do not relabel management transport as
  the active PLANK drawing transport.

Exit: model tests and signed Setup build pass; a failed launch does not retain
capture or reset pairing.

### E — qualify together before promotion

1. Review PRs and pin final commits/dependencies. Run focused protocol, model,
   migration, lease and service-policy tests; build clean signed app candidates
   and Linux packages on the qualified builders. Retain the accepted rollback.
2. Upgrade Relay services preserving both trust stores and tablet bonds. Verify
   binary/package provenance and passive inventory before any headset test.
3. Test known paired Relay: Setup → Use in PLANK → fresh desktop connection;
   no address typing; movement, tip, drag, side buttons and light/firm pressure.
4. Change the Relay's network address; repeat the handoff and connection while
   preserving the drawing pin. Test same-subnet discovery and Bluetooth management
   rendezvous across routed subnets separately.
5. Test unknown and mismatched drawing identities, missing raw service, unreachable
   routes, stale launch data and an already active PLANK session. No silent pairing
   reset, capture theft or competing connection is acceptable.
6. Test disconnect/reconnect, focus away/return, service restart, held-stroke link
   loss, USB/Bluetooth tablet recovery, and Ethernet loss with Wi-Fi available.
   Link loss must end the stroke and expose recovery; do not claim seamless failover.
7. Finish with a 30-minute drawing/playback run and repeated sleep/hotplug cycles.
   Record measured frame cadence and report timing alongside operator observations.

Exit: all gates have evidence; unresolved failures remain explicit. Publish a
new TestFlight build only after the integrated live tests pass.

## Execution report required from each agent

Return owned files, full commit IDs, contract/fixture revision, exact tests and
results, known limitations, and integration dependencies. Compilation is not
headset acceptance. Keep private machine addresses, passwords, identities,
pairing state and captures outside Git. Do not merge, deploy or publish a new
TestFlight build from an individual workstream.
