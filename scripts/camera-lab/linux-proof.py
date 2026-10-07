#!/usr/bin/env python3
"""Disposable Linux proof: real V4L2 device + independent Chromium reader.

No physical camera, network media, PLANK session, or workstation install.
The workflow creates the only device this script is permitted to touch.
"""
import argparse
import functools
import http.server
import json
import os
from pathlib import Path
import signal
import subprocess
import threading
import time

from playwright.sync_api import sync_playwright

def run(*args):
    return subprocess.check_output(args, text=True, timeout=10).strip()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        raise RuntimeError("This proof only runs on disposable GitHub-hosted runners")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    probe = out / "v4l2-probe"
    device = "/dev/video42"
    report = {"kernel": run("uname", "-r"), "physicalCameraUsed": False,
              "transportIntegrated": False, "tests": {}, "passed": False}
    producer = None
    server = None
    stopped = False
    try:
        subprocess.run(["cc", "-std=c11", "-D_GNU_SOURCE", "-Wall", "-Wextra", "-Werror",
                        str(Path(__file__).with_name("v4l2-probe.c")), "-o", str(probe)], check=True)
        caps = lambda: json.loads(run(str(probe), "caps", device))
        assert caps() == {"capture": False, "output": True}, caps()
        report["tests"]["offBeforeProducer"] = True

        # Neutral-chroma dark/bright halves, independent of a codec or real scene.
        pair_dark = bytes((32, 128, 32, 128))
        pair_bright = bytes((200, 128, 200, 128))
        pattern = (pair_dark * 320 + pair_bright * 320) * 720
        (out / "pattern.yuyv").write_bytes(pattern)
        # Prevent the module from replaying the last scene indefinitely on a stall.
        run("v4l2-ctl", "-d", device, "-c", "timeout=250")
        with (out / "producer.log").open("w") as log:
            producer = subprocess.Popen([
                "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "warning", "-re",
                "-stream_loop", "-1", "-f", "rawvideo", "-pixel_format", "yuyv422",
                "-video_size", "1280x720", "-framerate", "30", "-i", str(out / "pattern.yuyv"),
                "-c:v", "rawvideo", "-pix_fmt", "yuyv422", "-f", "v4l2", device], stderr=log)
            deadline = time.monotonic() + 10
            while not caps()["capture"]:
                if producer.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Producer did not activate capture")
                time.sleep(0.1)
            report["tests"]["visibleWhileProducing"] = True
            ownership = json.loads(run(str(probe), "claim", device))
            report["ownership"] = ownership
            assert ownership["secondProducerRejected"], ownership
            report["tests"]["exclusiveProducer"] = True

            # Independent command-line application verifies exact YUYV samples.
            subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "warning",
                "-f", "v4l2", "-input_format", "yuyv422", "-video_size", "1280x720",
                "-i", device, "-frames:v", "3", "-pix_fmt", "yuyv422", "-f", "rawvideo",
                "-y", str(out / "capture.yuyv")], check=True, timeout=15)
            captured = (out / "capture.yuyv").read_bytes()
            assert captured == pattern * 3, "V4L2 sample mismatch"
            report["tests"]["independentReaderExactPixels"] = True

            # getUserMedia uses the real V4L2 device, NOT Chromium fake video capture.
            (out / "index.html").write_text('<video id="camera" autoplay muted playsinline></video>')
            handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(out))
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            origin = f"http://127.0.0.1:{server.server_port}"
            with sync_playwright() as pw:
                with pw.chromium.launch(args=["--no-sandbox"]) as browser:
                    context = browser.new_context(permissions=["camera"], base_url=origin)
                    page = context.new_page()
                    page.goto(origin)
                    selection = page.evaluate("""async () => {
                        const devices = await navigator.mediaDevices.enumerateDevices();
                        const camera = devices.find(d => d.kind === 'videoinput' && d.label.includes('PLANK Camera Lab'));
                        if (!camera) throw new Error('Lab camera not enumerated');
                        window.stream = await navigator.mediaDevices.getUserMedia({audio:false, video:{
                            deviceId:{exact:camera.deviceId}, width:{exact:1280}, height:{exact:720}}});
                        const video = document.querySelector('video'); video.srcObject = stream;
                        await video.play();
                        window.sample = () => {
                            const c = document.createElement('canvas'); c.width=1280; c.height=720;
                            const ctx=c.getContext('2d'); ctx.drawImage(video,0,0,1280,720);
                            const left=Array.from(ctx.getImageData(320,360,1,1).data).slice(0,3);
                            const right=Array.from(ctx.getImageData(960,360,1,1).data).slice(0,3);
                            return {left,right,frames:video.getVideoPlaybackQuality().totalVideoFrames};
                        };
                        return stream.getVideoTracks()[0].getSettings();
                    }""")
                    # Do not store device/group identifiers in exported evidence.
                    report["browserFormat"] = {k: selection.get(k) for k in ("width", "height", "frameRate")}
                    page.wait_for_function("sample().frames >= 15")
                    pixels = page.evaluate("sample()")
                    assert min(pixels["right"]) - max(pixels["left"]) > 100, pixels
                    report["tests"]["browserReadsRealDevice"] = True
                    report["browserVersion"] = browser.version
                    report["browserPixels"] = pixels

                    # Simulate decoder/producer starvation while device remains open.
                    os.kill(producer.pid, signal.SIGSTOP)
                    stopped = True
                    page.wait_for_function("Math.max(...sample().right.map((v,i)=>Math.abs(v-sample().left[i]))) < 10", timeout=3000)
                    report["tests"]["stallRemovesPriorImageWithin3Seconds"] = True
                    os.kill(producer.pid, signal.SIGCONT)
                    stopped = False
                    page.wait_for_function("Math.min(...sample().right)-Math.max(...sample().left) > 100", timeout=3000)
                    report["tests"]["producerResumesWithoutBrowserReopen"] = True
                    page.evaluate("stream.getTracks().forEach(t=>t.stop())")
                    context.close()

            producer.terminate()
            producer.wait(timeout=5)
            producer = None
            assert caps() == {"capture": False, "output": True}, caps()
            report["tests"]["offAfterProducerClose"] = True
            report["passed"] = True
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        if producer is not None:
            if stopped: os.kill(producer.pid, signal.SIGCONT)
            producer.kill()
            producer.wait(timeout=5)
        if server is not None: server.shutdown(); server.server_close()
        (out / "linux-proof.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(json.dumps(report, indent=2, sort_keys=True))

if __name__ == "__main__":
    main()
