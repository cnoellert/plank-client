import AppKit
import AVFAudio
import CoreAudio
import Foundation

final class PlankAudioRingHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init?() { var config = plank_audio_ring_default_config(); guard let p = plank_audio_ring_create(&config) else { return nil }; pointer = p }
    deinit { plank_audio_ring_destroy(pointer) }
    var stats: PlankAudioRingStats { var value = PlankAudioRingStats(); plank_audio_ring_stats(pointer, &value); return value }
}
struct PlankAudioOutputStatus: Sendable {
    let running: Bool
    let outputLatencySeconds: Double
    let ioBufferSeconds: Double
    let error: String?
    let route: String
    let outputChannels: Int
    let systemVolume: Float
    let mixerVolume: Float
}
final class PlankAudioOutput: @unchecked Sendable {
    static let shared = PlankAudioOutput()
    private let queue = DispatchQueue(label: "la.instinctual.plank.mac-audio", qos: .userInitiated)
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private var ring: PlankAudioRingHandle?
    private var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    private var engineObserver: NSObjectProtocol?
    private var active = true
    private var volume = PlankAudioPreferences.volume()
    private var muted = PlankAudioPreferences.muted()
    private var lastError: String?
    private var outputLatency = 0.0
    private var bufferDuration = 0.0
    private var route = "unavailable"
    private var systemVolume = Float.nan

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        _ = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in self?.setSceneActive(false) }
        _ = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in self?.setSceneActive(true) }
    }
    func begin(_ ring: PlankAudioRingHandle) { queue.sync { teardown(); self.ring = ring; start() } }
    func end(_ ring: PlankAudioRingHandle) { queue.sync {
        guard self.ring === ring else { return }; plank_audio_ring_request_flush(ring.pointer); teardown(); self.ring = nil
    } }
    func setSceneActive(_ active: Bool) { queue.async { [self] in
        guard self.active != active else { return }; self.active = active
        if let ring = self.ring { plank_audio_ring_request_flush(ring.pointer) }
        teardown(); if active { start() }
    } }
    func setVolume(_ value: Float, muted: Bool) { queue.async { [self] in volume = min(max(value, 0), 1); self.muted = muted; engine?.mainMixerNode.outputVolume = muted ? 0 : volume } }
    var status: PlankAudioOutputStatus { queue.sync {
        PlankAudioOutputStatus(running: engine?.isRunning ?? false, outputLatencySeconds: outputLatency,
            ioBufferSeconds: bufferDuration, error: lastError, route: route,
            outputChannels: Int(engine?.outputNode.outputFormat(forBus: 0).channelCount ?? 0),
            systemVolume: systemVolume, mixerVolume: engine?.mainMixerNode.outputVolume ?? 0)
    } }
    private func start() {
        guard active, let ring else { return }
        let engine = AVAudioEngine()
        let source = AVAudioSourceNode(format: format) { silence, _, count, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self), let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return kAudioUnitErr_InvalidParameter }
            if plank_audio_ring_read(ring.pointer, left, right, count) == 0 { silence.pointee = true }; return noErr
        }
        engine.attach(source); engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = muted ? 0 : volume
        self.engine = engine; self.source = source
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }; self.queue.async { [self] in
                if let ring = self.ring { plank_audio_ring_request_flush(ring.pointer) }
                teardown(); start()
            }
        }
        do { engine.prepare(); try engine.start(); outputLatency = engine.outputNode.presentationLatency; readDevice(); lastError = nil }
        catch { lastError = error.localizedDescription; NSLog("PLANK Mac audio output: %@", error.localizedDescription) }
    }
    private func teardown() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }; engineObserver = nil
        engine?.stop(); if let engine, let source { engine.detach(source) }; engine = nil; source = nil
    }
    private func readDevice() {
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { route = "unavailable"; return }
        var name: CFString = "Output" as CFString
        address.mSelector = kAudioObjectPropertyName; size = UInt32(MemoryLayout<CFString>.size)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr { route = name as String }
        var frames: UInt32 = 0
        address.mSelector = kAudioDevicePropertyBufferFrameSize; size = 4
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &frames) == noErr {
            let rate = engine?.outputNode.outputFormat(forBus: 0).sampleRate ?? 0
            bufferDuration = rate > 0 ? Double(frames) / rate : 0
        }
        address.mSelector = kAudioDevicePropertyVolumeScalar; address.mScope = kAudioDevicePropertyScopeOutput; size = 4
        systemVolume = .nan
        _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &systemVolume)
    }
}
