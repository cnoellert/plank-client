# PLANK for Apple Vision Pro

This target is PLANK's native visionOS client shell. It owns the host browser,
bookmarks, settings, pairing and session presentation using SwiftUI. The
existing PLANK protocol, transport, decoder and input implementation will sit
behind `PlankCoreClient`; the desktop Qt interface is not part of this target.

## Tablet session lifecycle

The first raw tablet attachment on a new desktop transport queues DEVICE,
DETACH, and the identical DEVICE on the ordered input lane, before forwarding
the original descriptors. The preparatory DEVICE establishes the generation
required by the Host's existing DETACH handler; it creates no tablet interfaces.
DETACH destroys any retained Host tablet endpoints so the real attachment can
create a fresh group. Identity, descriptors, reports and control replies remain
unchanged. Focus suspension and Relay reconnects inside the same desktop
transport retain their existing behavior.

This uses the existing protocol and requires no Host package change. Focused
bridge checks cover ordering, a new transport, and failures at every reset
stage. Headset reconnect and display-mode acceptance remains pending; this
does not address the separately observed native input receive queue overflow.

Generate the Xcode project:

```bash
cmake -G Xcode \
  -S visionos-native \
  -B build/visionos-native \
  -DCMAKE_SYSTEM_NAME=visionOS \
  -DCMAKE_OSX_SYSROOT=xros \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0
```

Build for a paired Apple Vision Pro:

```bash
xcodebuild \
  -project build/visionos-native/PlankVision.xcodeproj \
  -scheme PlankVision \
  -destination 'platform=visionOS,id=<YOUR_DEVICE_ID>' \
  -configuration Debug build
```
