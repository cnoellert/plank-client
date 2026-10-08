import Foundation

/// Decoded Host audio level, measured before any local gain: per-channel RMS,
/// the overall sample peak and the left/right correlation. A peak near 0 dBFS
/// on loud content means the decoded signal is at full scale; a correlation
/// near -1 would reveal an inverted channel that cancels when mixed to mono.
struct PlankAudioLevel: Equatable, Sendable {
    var frames = 0
    var rmsLeft: Double = 0
    var rmsRight: Double = 0
    var peak: Double = 0
    var correlation: Double?

    static func dbfs(_ value: Double) -> String {
        value > 0 ? String(format: "%.1f", 20 * log10(value)) : "-inf"
    }

    var summary: String {
        guard frames > 0 else { return "level: no audio" }
        let corr = correlation.map { String(format: "%.2f", $0) } ?? "-"
        return "level rms L \(Self.dbfs(rmsLeft)) / R \(Self.dbfs(rmsRight)) dBFS · " +
            "peak \(Self.dbfs(peak)) dBFS · L/R corr \(corr)"
    }
}

struct PlankAudioLevelMeter: Sendable {
    private var frames = 0
    private var sumLeft = 0.0
    private var sumRight = 0.0
    private var sumProduct = 0.0
    private var peak: Float = 0

    mutating func add(interleaved samples: UnsafeBufferPointer<Float>, frames count: Int) {
        let count = min(count, samples.count / 2)
        guard count > 0 else { return }
        var left = 0.0, right = 0.0, product = 0.0
        var high: Float = peak
        for index in 0..<count {
            let l = samples[index * 2], r = samples[index * 2 + 1]
            left += Double(l * l)
            right += Double(r * r)
            product += Double(l * r)
            high = max(high, abs(l), abs(r))
        }
        frames += count
        sumLeft += left
        sumRight += right
        sumProduct += product
        peak = high
    }

    var level: PlankAudioLevel {
        guard frames > 0 else { return PlankAudioLevel() }
        let n = Double(frames)
        let energy = sumLeft * sumRight
        return PlankAudioLevel(
            frames: frames,
            rmsLeft: (sumLeft / n).squareRoot(),
            rmsRight: (sumRight / n).squareRoot(),
            peak: Double(peak),
            correlation: energy > 0 ? sumProduct / energy.squareRoot() : nil
        )
    }
}
