# Current wireless source checkpoint

This source follows the accepted `visionos-0.1.0-12-source` tag. It contains
subsequent finite session-startup deadline handling, tablet readiness/input
policy corrections, and saved/manual Relay selection UI changes. This publishing
pass does not install a new Client or submit a new TestFlight build.

Fresh verification on September 30, 2026:

- Session startup/display-transition retry deadline tests passed.
- Tablet input readiness/focus policy tests passed.
- Six-gate Wacom preflight tests passed; two Python preflight-validator tests passed.
- Unsigned physical-device-target Xcode build passed with SDK 27, deployment
  target 26.0, hardware decoder/Metal and raw Relay integration enabled.
- New-content private-information and diff-format checks passed.

Build inputs: transport source `d9f57d8c2e1c41232f690bb1933dc1ae782b5f3c`,
common-C submodule `060f6179f88343327b44d915007f1fb4cede71f1`, and raw Relay
source `e9e0e1c` on `codex/wacom-wifi-checkpoint`. FFmpeg and visionOS libsodium
remain separately prepared dependency prefixes. The unsigned verification build
used build number 13; it is not an installed or distributed release.

Do not extend the live acceptance of build 12 to every later source change.
The handoff plan in `docs/development/plans/relay-connection-handoff.md` is a
future implementation assignment, not an implemented app link.
