# Native visionOS client feature backlog

Recorded October 1, 2026 at the operator's request.

Status: **deferred**. These items are future work and do not expand the current
Relay Bluetooth investigation or connection-handoff acceptance gates.

## Goal

Bring the useful controls from the original PLANK desktop client into the
native Vision Pro client, with a clear native interface and saved preferences.
Include client camera/avatar and audio input/output workflows. Inventory the
remaining desktop options before deciding the complete implementation scope.

## Deferred items

### AVP-SET-01 — Bitrate and video-quality controls

- Expose video bitrate in Edit Workstation alongside resolution and stream rate.
- Preserve per-workstation and per-video-profile choices, with safe defaults,
  validation, and compatibility for existing bookmarks.
- Audit codec/profile, capture-source, chroma, and bit-depth choices against the
  desktop client and the actual Host/headset capabilities.
- Keep the accepted hardware-decoded exact-color path as the initial default.
- Show the requested and negotiated settings in optional diagnostics so the
  control's effect can be verified.

Completion: saved settings survive editing and reconnect; the selected bitrate
reaches the Host and affects the stream; unsupported combinations are explained.

Desktop references: [streaming preferences](../../../app/settings/streamingpreferences.h),
[bookmark editor](../../../app/gui/PcView.qml).

### AVP-SET-02 — Audio output, input, and controls

- Complete Host audio reception and native headset output.
- Provide playback volume and mute controls; audit desktop policies for muting
  Host speakers and muting playback while the Client is inactive.
- Evaluate stereo and surround layouts against the available audio routes.
- Track microphone forwarding, input selection, input mute, and permission UX
  alongside output settings; verify the existing Host/protocol support first.
- Qualify reconnect, focus changes, headset sleep/wake, and audio route changes.

Completion: sound and controls work in a real session; input/output states and
permissions are visible; changes and reconnects do not leave stale audio routes.

Desktop references: [audio settings](../../../app/gui/SettingsView.qml),
[audio engine](../../../app/streaming/audio/audio.cpp).
This expands the existing host-audio backlog rather than superseding it.

### AVP-SET-03 — Client camera and AVP avatar integration

- Restore the intended client-camera forwarding workflow for remote apps.
- Investigate using the Vision Pro's Persona/avatar presentation as the source.
- Establish which source APIs are available to this app, required permissions
  or entitlements, and compatibility with TestFlight/App Store distribution
  before promising a particular camera or avatar source.
- Audit the current desktop Client and Host forwarding path, supported format,
  source selection, enable/disable controls, and lifecycle behavior.

Completion: an approved source reaches a remote app with visible on/off state;
disconnect and interruption stop forwarding; unsupported sources are explained.
API/source availability remains an open feasibility question.

### AVP-SET-04 — Remaining desktop settings inventory

- Compare the current upstream desktop Client, this Client snapshot, and the
  native AVP settings and bookmark editor.
- Record each useful option as implemented, missing, or requiring a visionOS
  adaptation, with its source reference and where the setting should live.
- Include network/MTU controls, unreachable-host behavior, decoder selection,
  presentation/frame pacing, input preferences, and connection diagnostics.
- Separate workstation choices from app-wide preferences and debug overlays.
- Extend this list from that inventory; the examples above are not exhaustive.

Completion: an inspectable parity list identifies the remaining work without
implying that unimplemented controls are already supported.

## Suggested sequence when this work is activated

1. Perform the bounded desktop-settings inventory.
2. Add bitrate/video settings and audio output controls.
3. Qualify audio input and camera/avatar feasibility, then implement supported
   forwarding workflows.

This is a backlog ordering suggestion, not authorization to start implementation.
