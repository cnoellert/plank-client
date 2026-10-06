# Mac-hosted Tablet Relay

Date: 2026-10-06. Status: proposed implementation slice; no Mac Relay built.

## Product journey

An artist plugs a supported Wacom into their Mac, enables **Share tablet with
PLANK**, registers that Relay on the AVP, and draws in the AVP's workstation
session. The Mac does not need its own workstation connection or credentials.
The Mac application shows the shared tablet, approved headset, connection state
and a clear Stop Sharing action.

First path: USB Wacom → Mac Relay → authenticated TCP over the local network →
AVP Client → existing raw-HID Host channel. Internet access is not required for
the Relay link. This does not alter the AVP's workstation connection.

Keep the AVP boundary: Setup registers a Relay; the Client selects a registered
Relay. Do not restore manual credentials or tablet-specific ExpressKey approval
in the Client. Sharing is off by default and requires explicit Mac consent.

## What can be reused

- Native Client `MacRawWacomInput` already accepts an injected frame sender,
  handles Host control replies and exclusively opens physical HID interfaces.
  Preserve its descriptors, report IDs, bounded I/O and callback lifetimes.
- Raw Relay revision `029721f` supplies PLTR/PLWH framing, Noise-authenticated
  links, approved-key identity, session ordering and enrollment semantics.
  Reuse these contracts and portable components rather than inventing another
  wire format or mouse/pressure approximation.
- Existing AVP network drawing is the receiving path. A Mac Relay is a new
  physical device owner, not a new Host input implementation.

This is not a direct build of the Linux service. At the inspected revision,
the worker bridge and dispatcher name `LinuxRawWacomInput`; capture leases use
Linux abstract sockets, TCP wakeups use `eventfd`, and enrollment relies on a
Linux local privileged endpoint. CMake places service and crypto/link targets
under its Linux guard. The Mac adapter and build boundary must be explicit.

## Bounded implementation order

1. **Separate portable link/session logic from platform service plumbing.**
   Keep Linux behavior and tests intact. Add a macOS transport adapter with
   bounded reads/writes, whole-operation deadlines, cancellation and normal
   Bonjour discovery. Bind a network listener only while sharing is enabled;
   unauthenticated peers cannot start capture or send HID controls.
2. **Adapt the existing Mac worker to the Relay bridge.** One network owner
   encrypts/decrypts; capture callbacks only enqueue bounded raw records. Host
   GET/SET/OUTPUT replies reach the actual tablet unchanged. Queue exhaustion
   must close/recover explicitly rather than silently lose tip/button events.
   Prove attachment generations remain fresh across sessions and process
   restarts; the current Mac worker's process-local generation counter is not
   sufficient evidence for persistent Relay identity.
3. **Coordinate ownership with the Mac Client.** Introduce one shared capture
   authority for direct Client use and Relay hosting. Acquire before opening
   interfaces and release only after the worker has released them. Refuse
   conflicting use with a visible busy state; never steal an active session.
   Test coexistence with the current desktop Client too, preserving exclusive
   IOHID refusal even when that older app does not participate in the new lease.
4. **Complete Mac approval and AVP Setup registration.** Authenticate discovery
   identity before pinning. Adapt Setup-mediated enrollment to a Mac consent
   authority; an untrusted Bonjour advertisement cannot approve a headset.
   Approval must prove possession of the AVP Client key and durable acceptance,
   with cancellation, expiry and replay protection. Persist identity/approvals
   in protected Mac storage using existing contract semantics.
5. **Integrate optional hosting into the native Mac app.** Hosting starts only
   with consent and an authenticated AVP session ready for tablet input. Unlike
   direct desktop capture, active hosting is not tied to Mac window focus.
   Quitting, Stop Sharing, remote disconnect and device disappearance release
   capture. Ordinary Mac input must return after release. No always-running
   privileged daemon or login item is needed for this first slice.

## First live acceptance

Use the accepted Host and AVP Client where compatible; inventory any required
Setup/Client capability change before building. Keep the existing network and
Host installation unchanged. No Host package is part of this slice.

- Register the Mac through Setup and select it in the AVP Client. Verify the
  approved identity, permission-denied flow and refusal of an unapproved peer.
- Prove hover, pressure, tip taps, held drags, side buttons and supported pad
  controls through the raw-HID path, including bidirectional feature traffic.
- Switch focus away from the Mac app while drawing on AVP; hosting continues.
  Attempt direct Mac Client capture of that same tablet; it reports busy.
- End the AVP session while the tip/button is held, then reconnect tablet-first.
  No stale held state, old generation or duplicate Host device may survive.
- Unplug/replug USB, quit/relaunch the Mac app, and sleep/wake the Mac. Retest
  approval retention, automatic recovery and return of local tablet ownership.
- Compare sustained drawing with the accepted Relay path, recording terminal
  failures and bounded queue behavior without adding per-report UI updates.

Release packaging must retain the normal Input Monitoring permission flow and
clear network/hosting consent. A successful compile is not physical acceptance.

## Later transport/device work

Wireless Wacom → Mac requires a descriptor/control/ownership probe; the current
Mac worker identifies itself as USB and must not simply relabel Bluetooth input.
Mac → AVP Bluetooth requires proof of macOS peripheral/listener APIs, negotiated
L2CAP behavior and raw-HID throughput, then the versioned handoff contract.
Linux BlueZ behavior cannot establish either Mac capability. Keep both separate
from the network-first pilot and do not advertise them before qualification.
