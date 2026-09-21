# PLANK for Apple Vision Pro

This target is PLANK's native visionOS client shell. It owns the host browser,
bookmarks, settings, pairing and session presentation using SwiftUI. The
existing PLANK protocol, transport, decoder and input implementation will sit
behind `PlankCoreClient`; the desktop Qt interface is not part of this target.

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
  -destination 'platform=visionOS,id=00008142-001030AC01F1401C' \
  -configuration Debug build
```
