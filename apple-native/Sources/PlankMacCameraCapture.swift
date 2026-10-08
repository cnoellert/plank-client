// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo

/// Standalone source adapter; not yet wired into a product session. A caller
/// must bind featureVersion/acknowledgement to its authenticated Host response.
final class PlankMacCameraCapture: NSObject, @unchecked Sendable {
    struct Choice: Sendable { let id: String; let name: String }
    enum Status: Sendable {
        case off, starting, active
        case unavailable(Reason)
    }
    enum Reason: Sendable { case permission, sourceMissing, format, captureFailed, unsupportedHost }
    private let queue = DispatchQueue(label: "la.instinctual.plank.camera.capture", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let frameQueue = DispatchQueue(label: "la.instinctual.plank.camera.encode", qos: .userInitiated)
    private var delegate: PlankMacCameraCaptureDelegate?
    private let admission = PlankMacCameraAdmission()
    private let report: @Sendable (Status) -> Void
    private var capture: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var encoder: PlankMacCameraEncoder?
    private var activation: PlankMacCameraAdmission.Activation?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var sourceObservers: [NSObjectProtocol] = []

    init(report: @escaping @Sendable (Status) -> Void) {
        self.report = report
        super.init()
        queue.setSpecific(key: queueKey, value: 1)
        lifecycleObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
            object: nil, queue: nil) { [weak self] _ in self?.stop() })
        lifecycleObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: nil) { [weak self] _ in self?.stop() })
    }
    @MainActor static func choices() -> [Choice] {
        discovery().devices.map { Choice(id: $0.uniqueID, name: $0.localizedName) }
    }
    @MainActor static func requestConsent() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }
    private static func discovery() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified)
    }
    func start(selectedID: String, generation: UInt64, acknowledgedGeneration: UInt64,
               featureVersion: UInt32, submit: @escaping @Sendable (Data) -> Bool) {
        guard !selectedID.isEmpty, let next = admission.activate(version: featureVersion, generation: generation,
                    acknowledgedGeneration: acknowledgedGeneration) else {
            stop(); report(.unavailable(.unsupportedHost)); return
        }
        queue.async { [self] in
            guard admission.isCurrent(next) else { return }
            cleanup()
            guard admission.isCurrent(next) else { return }
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                fail(next, .permission); return
            }
            guard let device = Self.discovery().devices.first(where: { $0.uniqueID == selectedID }) else {
                fail(next, .sourceMissing); return
            }
            report(.starting)
            do {
                let session = AVCaptureSession()
                let videoOutput = AVCaptureVideoDataOutput()
                let input = try AVCaptureDeviceInput(device: device)
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                guard session.canSetSessionPreset(.hd1280x720), session.canAddInput(input), session.canAddOutput(videoOutput),
                      let format = device.formats.first(where: {
                          let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                          return size.width == 1280 && size.height == 720 && $0.videoSupportedFrameRateRanges.contains {
                              $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
                          }
                      }) else { throw PlankMacCameraEncoder.Failure.format }
                session.sessionPreset = .hd1280x720
                session.addInput(input); session.addOutput(videoOutput)
                try device.lockForConfiguration()
                device.activeFormat = format
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                device.unlockForConfiguration()
                guard videoOutput.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) else {
                    throw PlankMacCameraEncoder.Failure.format
                }
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                let newEncoder = try PlankMacCameraEncoder(admission: admission, activation: next, submit: submit) { [weak self] in
                    self?.stopIfCurrent(next, reason: .captureFailed)
                }
                let newDelegate = PlankMacCameraCaptureDelegate(session: session, output: videoOutput,
                    encoder: newEncoder, activation: next, admission: admission) { [weak self] in
                        self?.stopIfCurrent(next, reason: .format)
                    }
                delegate = newDelegate
                videoOutput.setSampleBufferDelegate(newDelegate, queue: frameQueue)
                encoder = newEncoder; capture = session; output = videoOutput; activation = next
            } catch {
                fail(next, .format); return
            }
            guard admission.isCurrent(next), let capture else { cleanup(); return }
            sourceObservers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                object: capture, queue: nil) { [weak self] _ in self?.stopIfCurrent(next, reason: .captureFailed) })
            sourceObservers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil, queue: nil) { [weak self] note in
                    if (note.object as? AVCaptureDevice)?.uniqueID == selectedID {
                        self?.stopIfCurrent(next, reason: .sourceMissing)
                    }
                })
            capture.startRunning()
            guard admission.isCurrent(next), capture.isRunning else {
                if admission.isCurrent(next) { fail(next, .captureFailed) } else { cleanup() }
                return
            }
            report(.active)
        }
    }
    /// Revocation is immediate, even if startRunning/stopRunning or the hardware
    /// encoder is busy. Only camera-owned cleanup waits on the serial queue.
    func stop() {
        admission.revoke()
        queue.async { [self] in
            guard !admission.hasActivation else { return }
            cleanup(); report(.off)
        }
    }
    func requestIndependentFrame() {
        queue.async { [self] in if let activation { admission.invalidateReference(activation) } }
    }
    private func stopIfCurrent(_ expected: PlankMacCameraAdmission.Activation, reason: Reason) {
        // A retired session's notification must not revoke a newly selected source.
        guard admission.revoke(expected) else { return }
        queue.async { [self] in
            if activation == expected { cleanup(); report(.unavailable(reason)) }
        }
    }
    private func fail(_ expected: PlankMacCameraAdmission.Activation, _ reason: Reason) {
        guard admission.revoke(expected) else { return }
        cleanup(); report(.unavailable(reason))
    }
    private func cleanup() {
        sourceObservers.forEach { NotificationCenter.default.removeObserver($0) }; sourceObservers.removeAll()
        output?.setSampleBufferDelegate(nil, queue: nil); output = nil
        let previous = capture; capture = nil; activation = nil
        previous?.stopRunning()
        let previousEncoder = encoder; encoder = nil
        frameQueue.sync { previousEncoder?.finish() }
        delegate = nil
    }
    deinit {
        admission.revoke()
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil { cleanup() }
        else { queue.sync { cleanup() } }
    }
}

/// One delegate per activation. Its immutable context cannot be rebound to a new
/// camera. Capture delivery and encoding are separate from start/stopRunning so
/// shutdown never waits for its own delegate callback to return.
private final class PlankMacCameraCaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session: AVCaptureSession
    let output: AVCaptureVideoDataOutput
    let encoder: PlankMacCameraEncoder
    let activation: PlankMacCameraAdmission.Activation
    let admission: PlankMacCameraAdmission
    let fail: @Sendable () -> Void
    init(session: AVCaptureSession, output: AVCaptureVideoDataOutput, encoder: PlankMacCameraEncoder,
         activation: PlankMacCameraAdmission.Activation, admission: PlankMacCameraAdmission,
         fail: @escaping @Sendable () -> Void) {
        self.session = session; self.output = output; self.encoder = encoder
        self.activation = activation; self.admission = admission; self.fail = fail
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === self.output, admission.isCurrent(activation) else { return }
        // AVCaptureSession documents every output PTS on synchronizationClock.
        // Convert to the host monotonic clock before comparing with the age gate.
        guard let clock = session.synchronizationClock, let image = CMSampleBufferGetImageBuffer(sample),
              PlankMacCameraEncoder.validImage(image),
              let captureUS = PlankMacCameraEncoder.hostTimeUS(CMSyncConvertTime(
                  CMSampleBufferGetPresentationTimeStamp(sample), from: clock, to: CMClockGetHostTimeClock())) else {
            fail(); return
        }
        encoder.encode(image, captureTimeUS: captureUS)
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === self.output { admission.invalidateReference(activation) }
    }
}
