// SPDX-License-Identifier: AGPL-3.0-or-later
// Synthetic pixels only. No AVCaptureSession, physical camera or PLANK transport.
import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

enum ProofError: Error { case status(String, OSStatus); case sample(String) }
func checked(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw ProofError.status(operation, status) }
}

final class EncoderProof {
    var session: VTCompressionSession?
    let writer: FileHandle
    let lock = NSLock()
    var errors: [String] = []
    var frames = 0
    var keys: [Int] = []
    var timings: [Double] = []
    var submitted: [Int: UInt64] = [:]

    init(path: String) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        writer = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                          kCVPixelBufferWidthKey: 1280, kCVPixelBufferHeightKey: 720,
                          kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        try checked(VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: 1280, height: 720,
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec, imageBufferAttributes: attributes,
            compressedDataAllocator: nil, outputCallback: { context, frameContext, status, flags, sample in
                guard let context else { return }
                let owner = Unmanaged<EncoderProof>.fromOpaque(context).takeUnretainedValue()
                let index = frameContext.map { Int(bitPattern: $0) - 1 } ?? -1
                owner.receive(index: index, status: status, flags: flags, sample: sample)
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &session), "create")
        guard let session else { throw ProofError.sample("missing session") }
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
        ] { try checked(VTSessionSetProperty(session, key: key, value: value), "set \(key)") }
        try checked(VTCompressionSessionPrepareToEncodeFrames(session), "prepare")
    }

    func receive(index: Int, status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?) {
        lock.lock(); defer { lock.unlock() }
        do {
            try checked(status, "callback")
            guard !flags.contains(.frameDropped), let sample, CMSampleBufferDataIsReady(sample),
                  let format = CMSampleBufferGetFormatDescription(sample),
                  let block = CMSampleBufferGetDataBuffer(sample) else { throw ProofError.sample("dropped/invalid sample") }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
            let key = !(attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false)
            var prefixSize: Int32 = 0
            var parameterCount = 0
            try checked(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterCount,
                nalUnitHeaderLengthOut: &prefixSize), "parameter info")
            guard prefixSize == 4 else { throw ProofError.sample("unexpected NAL prefix") }
            let marker = Data([0, 0, 0, 1])
            if key {
                for n in 0..<parameterCount {
                    var bytes: UnsafePointer<UInt8>?
                    var size = 0
                    try checked(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: n,
                        parameterSetPointerOut: &bytes, parameterSetSizeOut: &size,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil), "parameter set")
                    guard let bytes, size > 0 else { throw ProofError.sample("empty parameter set") }
                    try writer.write(contentsOf: marker)
                    try writer.write(contentsOf: Data(bytes: bytes, count: size))
                }
                keys.append(index)
            }
            let count = CMBlockBufferGetDataLength(block)
            guard count > 4, count <= 4 * 1024 * 1024 else { throw ProofError.sample("payload bounds") }
            var data = Data(count: count)
            try checked(data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!)
            }, "copy sample")
            var offset = 0
            while offset < count {
                guard count - offset >= 4 else { throw ProofError.sample("truncated NAL prefix") }
                let size = (0..<4).reduce(0) { ($0 << 8) | Int(data[offset + $1]) }
                offset += 4
                guard size > 0, size <= count - offset else { throw ProofError.sample("truncated NAL") }
                try writer.write(contentsOf: marker)
                try writer.write(contentsOf: data.subdata(in: offset..<(offset + size)))
                offset += size
            }
            guard let start = submitted.removeValue(forKey: index) else { throw ProofError.sample("unexpected frame") }
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            frames += 1
        } catch { errors.append(String(describing: error)) }
    }

    func run() throws -> [String: Any] {
        guard let session, let pool = VTCompressionSessionGetPixelBufferPool(session) else { throw ProofError.sample("missing pool") }
        let began = DispatchTime.now().uptimeNanoseconds
        for index in 0..<90 {
            // Pace input; measured callback age is not full network latency.
            let target = began + UInt64(index) * 1_000_000_000 / 30
            let now = DispatchTime.now().uptimeNanoseconds
            if now < target { Thread.sleep(forTimeInterval: Double(target - now) / 1_000_000_000) }
            var image: CVPixelBuffer?
            try checked(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &image), "allocate pixel buffer")
            guard let image else { throw ProofError.sample("missing image") }
            try checked(CVPixelBufferLockBaseAddress(image, []), "lock")
            let y = CVPixelBufferGetBaseAddressOfPlane(image, 0)!.assumingMemoryBound(to: UInt8.self)
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
            for row in 0..<720 {
                memset(y + row * yStride, index < 45 ? 32 : 64, 640)
                memset(y + row * yStride + 640, index < 45 ? 200 : 170, 640)
            }
            memset(CVPixelBufferGetBaseAddressOfPlane(image, 1)!, 128, CVPixelBufferGetBytesPerRowOfPlane(image, 1) * 360)
            CVPixelBufferUnlockBaseAddress(image, [])
            CVBufferSetAttachment(image, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(image, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            lock.lock(); submitted[index] = DispatchTime.now().uptimeNanoseconds; lock.unlock()
            let properties = index == 45 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            try checked(VTCompressionSessionEncodeFrame(session, imageBuffer: image,
                presentationTimeStamp: CMTime(value: Int64(index), timescale: 30),
                duration: CMTime(value: 1, timescale: 30), frameProperties: properties,
                sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: index + 1), infoFlagsOut: nil), "encode")
        }
        try checked(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid), "complete")
        var hardwarePointer: UnsafeRawPointer?
        try checked(VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                         allocator: nil, valueOut: &hardwarePointer), "hardware status")
        let hardware = hardwarePointer.map { Unmanaged<CFBoolean>.fromOpaque($0).takeRetainedValue() }
        VTCompressionSessionInvalidate(session)
        self.session = nil
        try writer.close()
        guard errors.isEmpty, frames == 90, submitted.isEmpty, keys.contains(0), keys.contains(45),
              hardware.map(CFBooleanGetValue) == true else { throw ProofError.sample("incomplete proof: \(frames), \(errors), keys \(keys)") }
        return ["passed": true, "frames": frames, "keyFrames": keys, "width": 1280, "height": 720,
                "nominalFPS": 30, "hardwareEncoder": true, "physicalCameraUsed": false,
                "transportIntegrated": false, "encodedBy": "VideoToolbox",
                "callbackAgeMaxMs": timings.max() ?? 0,
                "callbackAgeMeanMs": timings.reduce(0, +) / Double(timings.count)]
    }

    deinit { if let session { VTCompressionSessionInvalidate(session) }; try? writer.close() }
}

guard CommandLine.arguments.count == 2 else { fatalError("Usage: mac-encoder-proof <output.h264>") }
let proof = try EncoderProof(path: CommandLine.arguments[1])
let result = try proof.run()
let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(json)
FileHandle.standardOutput.write(Data([10]))
