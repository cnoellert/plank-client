import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// The Host's exact-colour HEVC stream stores G in Y and B/R in Cb/Cr.
// VideoToolbox must return xf44; ordinary RGB output applies an unwanted YUV matrix.
final class PlankHardwareVideoDecoder {
    enum Outcome {
        case frame(CVPixelBuffer)
        case waiting
        /// VideoToolbox rejected the bitstream as damaged
        /// (kVTVideoDecoderBadDataErr). The decoder still works; both native
        /// statuses are kept as returned.
        case badData(decodeStatus: OSStatus, frameStatus: OSStatus)
        /// Creation, capability or any other decoder failure; see lastError.
        case unavailable
    }

    /// The bad-data outcome when every failing status is
    /// kVTVideoDecoderBadDataErr; nil for success or any other failure.
    static func badDataOutcome(decodeStatus: OSStatus, frameStatus: OSStatus) -> Outcome? {
        let failures = [decodeStatus, frameStatus].filter { $0 != noErr }
        guard !failures.isEmpty,
              failures.allSatisfy({ $0 == kVTVideoDecoderBadDataErr }) else { return nil }
        return .badData(decodeStatus: decodeStatus, frameStatus: frameStatus)
    }

    private final class Output: @unchecked Sendable {
        var status: OSStatus = noErr
        var image: CVPixelBuffer?
    }

    private var vps: [UInt8]?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private(set) var failed = false
    private(set) var lastError: String?

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    func decode(_ bytes: UnsafeBufferPointer<UInt8>) -> Outcome {
        if failed { return .unavailable }
        let nals = Self.splitNALs(bytes)
        guard !nals.isEmpty else { return .waiting }

        var changed = false
        for nal in nals {
            switch Self.nalType(nal) {
            case 32 where nal != vps: vps = nal; changed = true
            case 33 where nal != sps: sps = nal; changed = true
            case 34 where nal != pps: pps = nal; changed = true
            default: break
            }
        }
        if changed, let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
            format = nil
        }
        if session == nil && !configure() { return failed ? .unavailable : .waiting }

        var accessUnit = [UInt8]()
        for nal in nals {
            let kind = Self.nalType(nal)
            guard kind < 32 || kind == 39 || kind == 40 else { continue }
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { accessUnit.append(contentsOf: $0) }
            accessUnit.append(contentsOf: nal)
        }
        guard !accessUnit.isEmpty, let format, let session else { return .waiting }

        var block: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: accessUnit.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: accessUnit.count,
            flags: 0, blockBufferOut: &block
        )
        guard blockStatus == noErr, let block else { return fail("Block buffer: \(blockStatus)") }
        let copyStatus = accessUnit.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: accessUnit.count
            )
        }
        guard copyStatus == noErr else { return fail("Block copy: \(copyStatus)") }
        var sample: CMSampleBuffer?
        var sampleSize = [accessUnit.count]
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        guard sampleStatus == noErr, let sample else { return fail("Sample buffer: \(sampleStatus)") }

        let output = Output()
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
        ) { callbackStatus, _, image, _, _ in
            output.status = callbackStatus
            output.image = image
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard status == noErr, output.status == noErr else {
            if let rejected = Self.badDataOutcome(decodeStatus: status, frameStatus: output.status) {
                return reject(rejected, "VideoToolbox bad data: \(status)/\(output.status)")
            }
            return fail("VideoToolbox decode: \(status)/\(output.status)")
        }
        guard let image = output.image else { return .waiting }
        guard CVPixelBufferGetPixelFormatType(image) ==
                kCVPixelFormatType_444YpCbCr10BiPlanarFullRange else {
            return fail("Unexpected VideoToolbox pixel format")
        }
        return .frame(image)
    }

    private func configure() -> Bool {
        guard let vps, let sps, let pps else { return false }
        var newFormat: CMVideoFormatDescription?
        let status = vps.withUnsafeBufferPointer { v in
            sps.withUnsafeBufferPointer { s in
                pps.withUnsafeBufferPointer { p in
                    let pointers = [v.baseAddress!, s.baseAddress!, p.baseAddress!]
                    let sizes = [vps.count, sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: 3,
                        parameterSetPointers: pointers, parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4, extensions: nil,
                        formatDescriptionOut: &newFormat
                    )
                }
            }
        }
        guard status == noErr, let newFormat else {
            _ = fail("Format description: \(status)")
            return false
        }
        let requirements: [String: Any] = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true
        ]
        let output: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        var newSession: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: newFormat,
            decoderSpecification: requirements as CFDictionary,
            imageBufferAttributes: output as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &newSession
        )
        guard createStatus == noErr, let newSession else {
            _ = fail("Hardware decoder creation: \(createStatus)")
            return false
        }
        format = newFormat
        session = newSession
        return true
    }

    private func fail(_ reason: String) -> Outcome {
        failed = true
        lastError = reason
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        return .unavailable
    }

    /// Damaged input, not a decoder fault: drop the session without marking the
    /// decoder failed. The caller rebuilds and waits for a keyframe.
    private func reject(_ outcome: Outcome, _ reason: String) -> Outcome {
        lastError = reason
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        return outcome
    }

    private static func nalType(_ nal: [UInt8]) -> Int { Int((nal[0] >> 1) & 63) }

    private static func splitNALs(_ bytes: UnsafeBufferPointer<UInt8>) -> [[UInt8]] {
        var starts: [(prefix: Int, payload: Int)] = []
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0 && bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    starts.append((index, index + 3))
                    index += 3
                    continue
                }
                if bytes[index + 2] == 0 && bytes[index + 3] == 1 {
                    starts.append((index, index + 4))
                    index += 4
                    continue
                }
            }
            index += 1
        }
        return starts.enumerated().compactMap { number, start in
            let end = number + 1 < starts.count ? starts[number + 1].prefix : bytes.count
            return end > start.payload ? Array(bytes[start.payload..<end]) : nil
        }
    }
}
