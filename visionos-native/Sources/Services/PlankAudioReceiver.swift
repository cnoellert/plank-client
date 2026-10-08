import Foundation

struct PlankAudioProgress: Sendable {
    let packets: UInt64
    let holes: UInt64
    let concealedFrames: UInt64
    let decodeErrors: UInt64
    let transportDrops: UInt64
    let underruns: UInt64
    let trimmedMilliseconds: Double
    let backlogMilliseconds: Double
    let targetMilliseconds: Double
    let outputLatencyMilliseconds: Double
    let driftFrames: (skipped: UInt64, repeated: UInt64)
    let playing: Bool
    let outputError: String?
    let level: PlankAudioLevel
    let output: PlankAudioOutputStatus

    var summary: String {
        if let outputError { return "Audio unavailable: \(outputError)" }
        return queueSummary + "\n" + level.summary + String(
            format: " · route %@ · system %.2f · mixer %.2f",
            output.route, output.systemVolume, output.mixerVolume)
    }

    private var queueSummary: String {
        return "Audio \(playing ? "playing" : "buffering") · packets \(packets) · " +
            "holes \(holes) · concealed \(concealedFrames) · drops \(transportDrops) · " +
            "underruns \(underruns)\n" +
            String(format: "queue %.0f/%.0f ms · output %.0f ms · trimmed %.0f ms · drift -%llu/+%llu",
                   backlogMilliseconds, targetMilliseconds, outputLatencyMilliseconds,
                   trimmedMilliseconds, driftFrames.skipped, driftFrames.repeated)
    }
}

/// Receives, decodes and queues Host audio on its own thread, independent of
/// the video receiver and input sender. The transport stays valid until
/// `stop()` returns, which the session engine calls before disconnecting.
final class PlankAudioReceiver: @unchecked Sendable {
    private static let maximumPacketSize = 64 * 1024
    // Never conceal more than 100 ms for one hole; the queue is bounded anyway.
    private static let maximumConcealedSamples: UInt32 = 4_800

    private let transport: OpaquePointer
    private let decoder: OpaquePointer
    private let ring: PlankAudioRingHandle
    private let output: PlankAudioOutput
    private let sessionLabel: String
    private let onProgress: @Sendable (PlankAudioProgress) -> Void
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var stopping = false
    private var started = false

    // Receive-thread counters.
    private var packets: UInt64 = 0
    private var holes: UInt64 = 0
    private var concealedFrames: UInt64 = 0
    private var decodeErrors: UInt64 = 0
    private var windowLevel = PlankAudioLevelMeter()
    private var sessionLevel = PlankAudioLevelMeter()

    init(
        transport: OpaquePointer,
        format: PlankAudioFormat,
        sessionLabel: String,
        output: PlankAudioOutput = .shared,
        onProgress: @escaping @Sendable (PlankAudioProgress) -> Void
    ) throws {
        var error = [CChar](repeating: 0, count: 256)
        let decoder = format.mapping.withUnsafeBufferPointer { mapping in
            plank_audio_decoder_create(
                Int32(format.sampleRate), Int32(format.channels),
                Int32(format.streams), Int32(format.coupledStreams),
                mapping.baseAddress, mapping.count, &error, error.count
            )
        }
        guard let decoder else {
            throw PlankSessionError.transport(String(cString: error))
        }
        guard let ring = PlankAudioRingHandle() else {
            plank_audio_decoder_destroy(decoder)
            throw PlankSessionError.transport("Unable to allocate the audio playback queue.")
        }
        self.transport = transport
        self.decoder = decoder
        self.ring = ring
        self.output = output
        self.sessionLabel = sessionLabel
        self.onProgress = onProgress
    }

    deinit { plank_audio_decoder_destroy(decoder) }

    func start() {
        lock.lock()
        guard !started, !stopping else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        output.begin(ring)
        let thread = Thread { [self] in
            run()
            finished.signal()
        }
        thread.name = "PLANK audio receive"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Joins the receive thread, then stops and flushes playback.
    func stop() {
        lock.lock()
        let wasStarted = started
        let alreadyStopping = stopping
        stopping = true
        lock.unlock()
        guard !alreadyStopping else { return }
        if wasStarted { finished.wait() }
        output.end(ring)
        if wasStarted {
            NSLog("PLANK session %@ audio ended: %@", sessionLabel,
                  progress(level: sessionLevel.level).summary)
        }
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    private func run() {
        var payload = [UInt8](repeating: 0, count: Self.maximumPacketSize)
        var pcm = [Float](repeating: 0, count: Int(PLANK_VISION_AUDIO_MAX_FRAME_SAMPLES) * 2)
        var lastReport = DispatchTime.now().uptimeNanoseconds
        while !isStopping {
            var packet = PlankVisionAudioPacket()
            var payloadSize = 0
            let result = plank_vision_transport_receive_audio(
                transport, &packet, &payload, payload.count, &payloadSize, 20
            )
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastReport >= 1_000_000_000 {
                onProgress(progress(level: windowLevel.level))
                windowLevel = PlankAudioLevelMeter()
                lastReport = now
            }
            if result == PLANK_VISION_TRANSPORT_TIMEOUT { continue }
            guard result == PLANK_VISION_TRANSPORT_OK else {
                // The video lane owns session failure; audio just stops.
                if !isStopping {
                    NSLog("PLANK session %@ audio receive stopped (%d)", sessionLabel, result)
                }
                return
            }
            if packet.missing_samples != 0 {
                holes &+= 1
                // A hole before the Host's codec header has no frame size;
                // the desktop Client rejects it the same way.
                let frames = plank_audio_concealment_frames(
                    packet.missing_samples, UInt32(packet.frame_samples),
                    Self.maximumConcealedSamples / max(UInt32(packet.frame_samples), 1)
                )
                for _ in 0..<frames {
                    decode(nil, 0, frameSamples: UInt32(packet.frame_samples), into: &pcm)
                }
                concealedFrames &+= UInt64(frames)
                continue
            }
            guard payloadSize > 0 else {
                decodeErrors &+= 1
                continue
            }
            packets &+= 1
            payload.withUnsafeBufferPointer { bytes in
                decode(bytes.baseAddress, payloadSize,
                       frameSamples: UInt32(packet.frame_samples), into: &pcm)
            }
        }
    }

    private func decode(
        _ packet: UnsafePointer<UInt8>?,
        _ size: Int,
        frameSamples: UInt32,
        into pcm: inout [Float]
    ) {
        pcm.withUnsafeMutableBufferPointer { samples in
            let frames = plank_audio_decoder_decode(
                decoder, packet, size, frameSamples,
                samples.baseAddress, samples.count / 2
            )
            guard frames > 0 else {
                decodeErrors &+= 1
                return
            }
            let decoded = UnsafeBufferPointer(samples)
            windowLevel.add(interleaved: decoded, frames: Int(frames))
            sessionLevel.add(interleaved: decoded, frames: Int(frames))
            _ = plank_audio_ring_write(ring.pointer, samples.baseAddress, UInt32(frames))
        }
    }

    /// Counters are written by the receive thread; a slightly stale read is
    /// acceptable for diagnostics.
    private func progress(level: PlankAudioLevel) -> PlankAudioProgress {
        let ringStats = ring.stats
        var transportStats = PlankVisionAudioStats()
        _ = plank_vision_transport_audio_stats(transport, &transportStats)
        let outputStatus = output.status
        func ms(_ frames: UInt64) -> Double { Double(frames) / 48.0 }
        return PlankAudioProgress(
            packets: packets,
            holes: holes,
            concealedFrames: concealedFrames,
            decodeErrors: decodeErrors,
            transportDrops: transportStats.receive_drops,
            underruns: ringStats.underruns,
            trimmedMilliseconds: ms(ringStats.frames_trimmed),
            backlogMilliseconds: ms(UInt64(ringStats.backlog_frames)),
            targetMilliseconds: ms(UInt64(ringStats.target_frames)),
            outputLatencyMilliseconds:
                (outputStatus.outputLatencySeconds + outputStatus.ioBufferSeconds) * 1000,
            driftFrames: (ringStats.drift_frames_skipped, ringStats.drift_frames_repeated),
            playing: ringStats.playing != 0,
            outputError: outputStatus.error,
            level: level,
            output: outputStatus
        )
    }
}
