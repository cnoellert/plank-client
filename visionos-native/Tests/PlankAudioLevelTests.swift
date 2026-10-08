// SPDX-License-Identifier: GPL-3.0-or-later
// Focused behavior of the decoded-audio level meter used to investigate
// playback loudness: full-scale peaks, per-channel RMS, channel identity and
// inversion (cancellation) detection.
//
// Build/run (failures are counted explicitly, not with assert):
//   swiftc -Onone -parse-as-library Sources/Models/PlankAudioLevel.swift \
//     Tests/PlankAudioLevelTests.swift -o out && ./out
import Foundation

@main
struct PlankAudioLevelTests {
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var failures = 0

    static func check(_ condition: Bool, _ message: String, line: Int = #line) {
        checks += 1
        if !condition { failures += 1; print("FAIL line \(line): \(message)") }
    }

    static func level(_ left: (Int) -> Float, _ right: (Int) -> Float, frames: Int = 4800) -> PlankAudioLevel {
        var samples = [Float](repeating: 0, count: frames * 2)
        for index in 0..<frames {
            samples[index * 2] = left(index)
            samples[index * 2 + 1] = right(index)
        }
        var meter = PlankAudioLevelMeter()
        samples.withUnsafeBufferPointer { buffer in
            // Two calls, as the receiver feeds one decoded packet at a time.
            meter.add(interleaved: UnsafeBufferPointer(rebasing: buffer[0..<frames]), frames: frames / 2)
            meter.add(interleaved: UnsafeBufferPointer(rebasing: buffer[frames...]), frames: frames / 2)
        }
        return meter.level
    }

    static func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.01) -> Bool { abs(a - b) <= tolerance }

    static func main() {
        let sine = { (i: Int) -> Float in Float(sin(2 * Double.pi * 1000 * Double(i) / 48_000)) }

        // A full-scale sine: 0 dBFS peak, -3.01 dBFS RMS on both channels.
        let full = level(sine, sine)
        check(full.frames == 4800, "all frames counted")
        check(near(full.peak, 1, 0.001), "full-scale peak")
        check(near(20 * log10(full.rmsLeft), -3.01, 0.05), "sine RMS -3 dBFS")
        check(near(full.correlation ?? 0, 1), "identical channels correlate")
        check(PlankAudioLevel.dbfs(full.peak) == "0.0", "peak shown as 0.0 dBFS")

        // Half amplitude reads 6 dB lower: the meter does not normalize.
        let half = level({ sine($0) * 0.5 }, { sine($0) * 0.5 })
        check(near(20 * log10(half.peak), -6.02, 0.05), "half amplitude -6 dBFS")

        // Channel identity: left-only content stays on the left.
        let leftOnly = level(sine, { _ in 0 })
        check(leftOnly.rmsLeft > 0.7 && leftOnly.rmsRight == 0, "left-only stays left")
        check(leftOnly.correlation == nil, "no correlation with a silent channel")

        // An inverted channel is visible as correlation -1.
        let inverted = level(sine, { -sine($0) })
        check(near(inverted.correlation ?? 0, -1), "inversion detected")

        // Silence and an empty meter.
        let silent = level({ _ in 0 }, { _ in 0 })
        check(silent.peak == 0 && PlankAudioLevel.dbfs(silent.peak) == "-inf", "silence")
        check(PlankAudioLevelMeter().level.frames == 0, "empty meter")
        check(PlankAudioLevelMeter().level.summary == "level: no audio", "empty summary")

        print("PlankAudioLevelTests: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
