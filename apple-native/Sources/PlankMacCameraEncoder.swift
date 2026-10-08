// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Serial encode/configuration owner. Callback admission has its own lock;
/// nothing here runs on the desktop input/audio workers or the main thread.
final class PlankMacCameraEncoder: @unchecked Sendable {
    enum Failure: Error, Sendable { case status(OSStatus), format, sample, sps, color }
    private let diagnosticLock = NSLock()
    private var failures: UInt64 = 0
    private var lastFailure = "none"
    var diagnostics: (failures: UInt64, lastFailure: String) {
        diagnosticLock.lock(); defer { diagnosticLock.unlock() }; return (failures, lastFailure)
    }
    private func recordFailure(_ failure: Error) {
        diagnosticLock.lock(); defer { diagnosticLock.unlock() }
        failures &+= 1; lastFailure = String(describing: failure)
    }
    private var session: VTCompressionSession?
    let admission: PlankMacCameraAdmission
    let activation: PlankMacCameraAdmission.Activation
    private let submit: @Sendable (Data) -> Bool
    private let onFailure: @Sendable () -> Void

    init(admission: PlankMacCameraAdmission, activation: PlankMacCameraAdmission.Activation,
         submit: @escaping @Sendable (Data) -> Bool, onFailure: @escaping @Sendable () -> Void = {}) throws {
        self.admission = admission; self.activation = activation; self.submit = submit; self.onFailure = onFailure
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                          kCVPixelBufferWidthKey: 1280, kCVPixelBufferHeightKey: 720,
                          kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        try Self.checked(VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: 1280, height: 720,
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec, imageBufferAttributes: attributes,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session))
        guard let session else { throw Failure.format }
        do {
            for (key, value) in [
                (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue as CFTypeRef),
                (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse as CFTypeRef),
                (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel as CFTypeRef),
                (kVTCompressionPropertyKey_ExpectedFrameRate, 30 as CFNumber),
                (kVTCompressionPropertyKey_MaxKeyFrameInterval, 30 as CFNumber),
                (kVTCompressionPropertyKey_AverageBitRate, 2_000_000 as CFNumber),
                (kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2 as CFTypeRef),
                (kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2 as CFTypeRef),
                (kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as CFTypeRef)
            ] { try Self.checked(VTSessionSetProperty(session, key: key, value: value)) }
            try Self.checked(VTCompressionSessionPrepareToEncodeFrames(session))
            var hardwarePointer: UnsafeRawPointer?
            try Self.checked(VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                                   allocator: nil, valueOut: &hardwarePointer))
            guard let hardwarePointer else { throw Failure.format }
            let hardware = Unmanaged<CFBoolean>.fromOpaque(hardwarePointer).takeRetainedValue()
            guard CFBooleanGetValue(hardware) else { throw Failure.format }
        } catch { VTCompressionSessionInvalidate(session); self.session = nil; throw error }
    }
    private static func checked(_ status: OSStatus) throws { if status != noErr { throw Failure.status(status) } }
    static func hostTimeUS(_ time: CMTime) -> UInt64? {
        guard time.isNumeric else { return nil }
        let converted = CMTimeConvertScale(time, timescale: 1_000_000, method: .roundTowardZero)
        guard converted.isNumeric, converted.value > 0, converted.value <= Int64.max / 1000 else { return nil }
        return UInt64(converted.value)
    }
    static var nowUS: UInt64 { hostTimeUS(CMClockGetTime(CMClockGetHostTimeClock())) ?? 0 }
    static func validImage(_ image: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetWidth(image) == 1280, CVPixelBufferGetHeight(image) == 720,
              CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return false }
        for (key, expected) in [(kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
                                 (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
                                 (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2)] {
            guard let value = CVBufferCopyAttachment(image, key, nil), CFEqual(value, expected) else { return false }
        }
        return true
    }
    func encode(_ image: CVPixelBuffer, captureTimeUS: UInt64) {
        guard let session, Self.validImage(image) else { admission.invalidateReference(activation); return }
        guard let job = admission.reserve(activation, captureTimeUS: captureTimeUS, nowUS: Self.nowUS) else { return }
        let options = job.forceIndependent ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        var info: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: image,
            presentationTimeStamp: CMTime(value: Int64(captureTimeUS), timescale: 1_000_000),
            duration: CMTime(value: 1, timescale: 30), frameProperties: options, infoFlagsOut: &info) { [weak self] status, flags, sample in
                guard let self else { return }
                if status == noErr, flags.contains(.frameDropped) { admission.discard(job); return }
                do {
                    try Self.checked(status)
                    guard let sample else { throw Failure.sample }
                    let (payload, independent) = try Self.annexB(sample)
                    admission.complete(job, independent: independent, payload: payload, nowUS: Self.nowUS) { frame in
                        guard let packet = Self.packet(frame) else { return false }
                        return self.submit(packet)
                    }
                } catch { self.recordFailure(error); admission.discard(job); self.onFailure() }
            }
        if status != noErr || info.contains(.frameDropped) { admission.discard(job) }
    }
    /// Call on the encode owner queue. Revoke admission first for off/disconnect.
    func drain() {
        if let session { _ = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) }
    }
    func finish() {
        guard let session else { return }
        drain()
        VTCompressionSessionInvalidate(session); self.session = nil
    }
    deinit { finish() }

    static func annexB(_ sample: CMSampleBuffer) throws -> (Data, Bool) {
        guard CMSampleBufferDataIsReady(sample), CMSampleBufferGetNumSamples(sample) == 1,
              let format = CMSampleBufferGetFormatDescription(sample),
              CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264,
              let block = CMSampleBufferGetDataBuffer(sample) else { throw Failure.sample }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width == 1280, dimensions.height == 720 else { throw Failure.format }
        for (key, expected) in [(kCMFormatDescriptionExtension_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
                                 (kCMFormatDescriptionExtension_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2),
                                 (kCMFormatDescriptionExtension_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)] {
            guard let value = CMFormatDescriptionGetExtension(format, extensionKey: key), CFEqual(value, expected) else { throw Failure.color }
        }
        if let range = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo),
           !CFEqual(range, kCFBooleanFalse) { throw Failure.color }
        var prefix: Int32 = 0, parameterCount = 0
        try checked(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterCount,
            nalUnitHeaderLengthOut: &prefix))
        guard prefix == 4, parameterCount == 2 else { throw Failure.format }
        var parameters: [Data] = []
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?, size = 0
            try checked(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil))
            guard let pointer, size > 1, size <= 4096 else { throw Failure.format }
            parameters.append(Data(bytes: pointer, count: size))
        }
        guard PlankMacCameraSPS.is720pBT709Limited(parameters[0]), parameters[1][0] & 0x80 == 0, parameters[1][0] & 31 == 8 else { throw Failure.sps }
        let count = CMBlockBufferGetDataLength(block)
        guard count > 4, count <= 4 * 1024 * 1024 else { throw Failure.sample }
        var bytes = Data(count: count)
        try checked(bytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!)
        })
        var offset = 0, nals = 0, independent = false, dependent = false
        var payload = Data()
        while offset < count {
            guard count - offset >= 4, nals < 62 else { throw Failure.sample }
            let size = (0..<4).reduce(0) { ($0 << 8) | Int(bytes[offset + $1]) }; offset += 4
            guard size > 0, size <= count - offset, bytes[offset] & 0x80 == 0 else { throw Failure.sample }
            let type = bytes[offset] & 31
            guard type == 1 || type == 5 || type == 6 || type == 9 || type == 10 || type == 11 || type == 12 else { throw Failure.sample }
            if type == 1 { dependent = true }; if type == 5 { independent = true }
            payload.append(contentsOf: [0, 0, 0, 1]); payload.append(bytes.subdata(in: offset..<offset + size))
            offset += size; nals += 1
        }
        guard independent != dependent else { throw Failure.sample }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
        let declaredIndependent = !(attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false)
        guard declaredIndependent == independent else { throw Failure.sample }
        if independent {
            var prefixed = Data()
            for parameter in parameters { prefixed.append(contentsOf: [0, 0, 0, 1]); prefixed.append(parameter) }
            prefixed.append(payload); payload = prefixed
        }
        guard payload.count <= 4 * 1024 * 1024 else { throw Failure.sample }
        return (payload, independent)
    }
    private static func packet(_ frame: PlankMacCameraAdmission.Frame) -> Data? {
        var header = PlankEncodedCameraHeader()
        header.generation = frame.generation; header.sequence = frame.sequence; header.capture_time_us = frame.captureTimeUS
        header.codec = UInt32(PLANK_CAMERA_H264); header.platform = UInt32(PLANK_CAMERA_MACOS)
        header.encoder = UInt32(PLANK_CAMERA_VIDEOTOOLBOX_HARDWARE); header.source_pixel_format = UInt32(PLANK_CAMERA_NV12)
        header.width = 1280; header.height = 720; header.nominal_fps = 30
        header.primaries = UInt8(PLANK_CAMERA_BT709); header.transfer = UInt8(PLANK_CAMERA_BT709)
        header.matrix = UInt8(PLANK_CAMERA_BT709); header.range = UInt8(PLANK_CAMERA_LIMITED_RANGE)
        header.flags = (frame.independent ? UInt8(PLANK_CAMERA_KEY_FRAME) : 0) |
            (frame.discontinuity ? UInt8(PLANK_CAMERA_DISCONTINUITY) : 0)
        var packet = Data(count: Int(PLANK_CAMERA_HEADER_BYTES))
        let result = packet.withUnsafeMutableBytes {
            plank_encoded_camera_header_encode(&header, frame.payload.count, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        }
        guard result == 0 else { return nil }
        packet.append(frame.payload)
        return packet
    }
}
