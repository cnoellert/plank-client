#!/usr/bin/env python3
"""Generated media only. No physical camera, permission prompt or product session."""
import argparse
import json
import pathlib
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--transport", required=True, type=pathlib.Path)
parser.add_argument("--ffmpeg-prefix", required=True, type=pathlib.Path)
parser.add_argument("--output", required=True, type=pathlib.Path)
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
include = args.transport.resolve() / "include"
if not (include / "plank_transport_camera_encoded.h").is_file():
    parser.error("PCAM v2 transport headers required")
sources = root / "apple-native/Sources"
tests = root / "apple-native/Tests"
flags = ["xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete",
         "-target", "arm64-apple-macos15.0", "-Onone", "-parse-as-library"]
def run(command, **kwargs):
    return subprocess.run([str(x) for x in command], check=True, timeout=60, **kwargs)
common = [sources / "PlankMacCameraAdmission.swift", sources / "PlankMacCameraBitstream.swift"]
bridge = ["-import-objc-header", tests / "PlankMacCameraTestBridge.h", "-I" + str(include)]
report = {"passed": False, "physicalCameraUsed": False, "productSessionUsed": False}
try:
    run(flags + common + [tests / "PlankMacCameraAdmissionTests.swift", "-o", out / "admission"])
    run([out / "admission"])
    report["admissionAndMetadata"] = True
    run(flags + ["-typecheck"] + bridge + common + [sources / "PlankMacCameraEncoder.swift", sources / "PlankMacCameraCapture.swift"])
    report["captureAdapterMacOS15Typecheck"] = True
    run(flags + bridge + common + [sources / "PlankMacCameraEncoder.swift", tests / "PlankMacCameraEncoderTests.swift", "-o", out / "encoder"])
    result = run([out / "encoder", out / "source.h264"], capture_output=True, text=True)
    report["encoder"] = json.loads(result.stdout)
    probe = run([args.ffmpeg_prefix / "bin/ffprobe", "-v", "error", "-count_frames", "-show_entries",
                 "stream=codec_name,profile,width,height,pix_fmt,color_range,color_space,color_transfer,color_primaries,nb_read_frames",
                 "-of", "json", out / "source.h264"], capture_output=True, text=True)
    stream = json.loads(probe.stdout)["streams"][0]
    expected = {"codec_name": "h264", "profile": "Baseline", "width": 1280, "height": 720,
                "pix_fmt": "yuv420p", "color_range": "tv", "color_space": "bt709", "color_transfer": "bt709",
                "color_primaries": "bt709", "nb_read_frames": "90"}
    if stream != expected:
        raise RuntimeError("Independent decoder did not confirm the exact camera format")
    run([args.ffmpeg_prefix / "bin/ffmpeg", "-v", "error", "-xerror", "-i", out / "source.h264", "-f", "null", "-"])
    report["independentDecode"] = stream
    report["passed"] = True
finally:
    (out / "proof.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
print(json.dumps(report, sort_keys=True))
