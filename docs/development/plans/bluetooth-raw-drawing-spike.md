# Bluetooth raw drawing development candidate

The development-only **Test Bluetooth drawing** switch in Settings uses the
selected Relay's existing drawing pin. It applies on the next workstation
connection and never falls back to TCP. Normal network drawing remains available
when the switch is off. This is not a released feature or a new approval flow.

The Client discovers Alan's Relay service, reads its dynamic LE PSM, opens L2CAP,
and sends `PLTRLEC1` channel 3. Discovery requires one nearby Relay for this first
spike; names and radio identifiers are not trusted identities. The existing raw
Noise codec authenticates the saved drawing public key with Bluetooth link type
1. Unknown or mismatched keys fail closed. The TCP codec retains type 2.

The qualified RelaySetupKit stream scheduling and partial-write logic are reused.
A bounded FIFO preserves Host reply order across the main-actor handoff. Raw
codec processing stays on its serial queue. Raw HID validation, Host features,
preflight, generation checks, capture activation and teardown remain shared.
Discovery has a finite 45-second deadline, including retrieval of an existing
system-connected Relay when its advertisements are suppressed. The overall
Bluetooth tablet-availability grace is 60 seconds, beyond the 50-second initial
link watchdog; network drawing retains its 12-second grace. Authenticated session
heartbeat remains unchanged. Existing bitrate, audio, Relay picker and mouse fixes remain.

The diagnostic candidate writes aggregate flow counts once every five seconds:
validated raw message types received from the Relay, Host control types returned,
age of the last input report, tablet messages accepted by the native Host input
sender, and input queue depth/age. It records no report payloads or coordinates.
Native acceptance is not proof that the workstation consumed a report. These
counts distinguish a stopped Relay stream from Client gating or submission;
they do not change routing, capture, retries, or raw HID semantics.

## Live acceptance

1. Install the matching development managed/raw Relay builds, retaining rollback.
   Select an already approved Relay in Client Settings and enable the test switch.
2. Stop Setup's tablet test. Keep the AVP's workstation network available. Disable
   only the Relay's network connectivity for the proof (do not strand SSH without
   an agreed recovery path).
3. Connect to a workstation. Confirm the Bluetooth raw channel and authenticated
   identity in logs, with no TCP drawing connection.
4. Verify hover, tip clicks, dragging, pressure, side buttons and ExpressKeys.
   Host control and attach replies must pass; Setup preview is not the proof.
5. Disconnect and reconnect. Exercise Setup test -> stop -> drawing capture
   transfer, then a wireless Wacom reconnect if hardware is available.
6. Re-enable the Relay network and turn the test switch off; verify TCP drawing.

A signed build and focused tests do not qualify Bluetooth performance. Record
observed transport, capture state and results. New enrollment, endpoint contract
and complete package installation remain subsequent work.
