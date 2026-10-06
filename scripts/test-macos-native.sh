#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 1 ]]; then echo "usage: $0 <output-dir>" >&2; exit 2; fi
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$1"
out=$(cd -- "$1" && pwd)
cd "$root"
xcrun swiftc -swift-version 6 -Onone -parse-as-library -DPLANK_NATIVE_MAC_WACOM \
    apple-native/Sources/PlankMacInputPolicy.swift visionos-native/Sources/Services/PlankInputQueue.swift \
    visionos-native/Sources/Services/PlankWacomPreflight.swift apple-native/Tests/PlankMacPolicyTests.swift -o "$out/mac-policy"
"$out/mac-policy"
xcrun clang++ -std=c++17 -O0 -DPLANK_NATIVE_MAC_WACOM -Iapple-native/Bridge -Iapp/streaming/input \
    -Imoonlight-common-c/moonlight-common-c/src apple-native/Bridge/PlankMacWacom.cpp \
    apple-native/Tests/PlankMacWacomLifetimeTests.cpp -o "$out/mac-wacom-lifetime"
"$out/mac-wacom-lifetime"
xcrun swiftc -swift-version 6 -Onone -parse-as-library \
    visionos-native/Sources/Services/PlankWacomPreflight.swift visionos-native/Tests/PlankWacomPreflightTests.swift -o "$out/relay-preflight"
"$out/relay-preflight" > "$out/relay-preflight.log" 2>&1
xcrun swiftc -swift-version 6 -Onone -parse-as-library \
    visionos-native/Sources/Services/PlankHardwareVideoDecoder.swift visionos-native/Sources/Services/PlankVideoDecoderRecovery.swift \
    visionos-native/Tests/PlankVideoDecoderRecoveryTests.swift -o "$out/decoder-recovery"
"$out/decoder-recovery"
xcrun swiftc -swift-version 6 -Onone -parse-as-library \
    visionos-native/Sources/Services/PlankTabletInputPolicy.swift visionos-native/Tests/PlankTabletInputPolicyTests.swift -o "$out/tablet-policy"
"$out/tablet-policy"
