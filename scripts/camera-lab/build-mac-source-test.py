#!/usr/bin/env python3
"""Build an isolated local camera adapter test; do not launch or grant consent."""
import argparse
from pathlib import Path
import plistlib
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--transport", required=True, type=Path)
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
app = args.output.resolve() / "PLANK Camera Test.app"
contents = app / "Contents"
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
info = {"CFBundleName": "PLANK Camera Test", "CFBundleDisplayName": "PLANK Camera Test",
        "CFBundleIdentifier": "la.instinctual.PLANK.CameraSourceTest", "CFBundleExecutable": "PlankCameraTest",
        "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "0.1.0",
        "LSMinimumSystemVersion": "15.0", "NSHighResolutionCapable": True,
        "NSCameraUsageDescription": "Test the camera you choose on this Mac for five seconds."}
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
sources = root / "apple-native/Sources"
command = ["xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete", "-target", "arm64-apple-macos15.0",
           "-Onone", "-parse-as-library", "-import-objc-header", root / "apple-native/Tests/PlankMacCameraTestBridge.h",
           "-I" + str(args.transport.resolve() / "include")]
command += [sources / ("PlankMacCamera" + part + ".swift") for part in ("Admission", "Bitstream", "Encoder", "Capture")]
command += [root / "scripts/camera-lab/mac-source-test.swift", "-o", contents / "MacOS/PlankCameraTest"]
subprocess.run([str(x) for x in command], check=True, timeout=60)
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print(app)
