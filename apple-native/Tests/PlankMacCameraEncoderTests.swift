// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import CoreMedia
import CoreVideo

private final class Records: @unchecked Sendable {
    let lock = NSLock()
    var values: [Data] = []
    func add(_ record: Data) -> Bool { lock.lock(); defer { lock.unlock() }; values.append(record); return true }
    var snapshot: [Data] { lock.lock(); defer { lock.unlock() }; return values }
}
@main struct PlankMacCameraEncoderTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Expected synthetic output path") }
        let gate = PlankMacCameraAdmission()
        let activation = gate.activate(version: 2, generation: 2, acknowledgedGeneration: 2)!
        let records = Records()
        let encoder = try PlankMacCameraEncoder(admission: gate, activation: activation, submit: { records.add($0) })
        var lastImage: CVPixelBuffer?
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<90 {
            let target = start + UInt64(index) * 1_000_000_000 / 30
            let now = DispatchTime.now().uptimeNanoseconds
            if now < target { Thread.sleep(forTimeInterval: Double(target - now) / 1_000_000_000) }
            var image: CVPixelBuffer?
            precondition(CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image) == kCVReturnSuccess)
            let pixels = image!; lastImage = pixels
            precondition(!PlankMacCameraEncoder.validImage(pixels), "missing color must not be guessed")
            for (key, value) in [(kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
                                 (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
                                 (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2)] {
                CVBufferSetAttachment(pixels, key, value, .shouldPropagate)
            }
            precondition(PlankMacCameraEncoder.validImage(pixels))
            CVBufferSetAttachment(pixels, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
            precondition(!PlankMacCameraEncoder.validImage(pixels), "conflicting color rejected")
            CVBufferSetAttachment(pixels, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            precondition(CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess)
            let y = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
            for row in 0..<720 {
                memset(y + row * stride, index < 45 ? 32 : 64, 640)
                memset(y + row * stride + 640, index < 45 ? 200 : 170, 640)
            }
            memset(CVPixelBufferGetBaseAddressOfPlane(pixels, 1)!, 128, CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) * 360)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            if index == 45 { gate.invalidateReference(activation) }
            encoder.encode(pixels, captureTimeUS: PlankMacCameraEncoder.nowUS)
        }
        encoder.drain()
        let emitted = records.snapshot
        precondition(emitted.count == 90 && gate.pendingCount == 0, "all generated frames received: \(emitted.count), \(encoder.diagnostics)")
        var keys: [Int] = [], stream = Data(), lastTime: UInt64 = 0
        for (index, packet) in emitted.enumerated() {
            var header = PlankEncodedCameraHeader()
            let result = packet.withUnsafeBytes { plank_encoded_camera_header_decode($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &header) }
            precondition(result == 0 && header.sequence == UInt64(index) && header.generation == 2 && header.capture_time_us > lastTime)
            lastTime = header.capture_time_us
            if header.flags & UInt8(PLANK_CAMERA_KEY_FRAME) != 0 { keys.append(index) }
            if index == 0 || index == 45 { precondition(header.flags & UInt8(PLANK_CAMERA_DISCONTINUITY) != 0) }
            let payload = packet.dropFirst(Int(PLANK_CAMERA_HEADER_BYTES))
            stream.append(payload)
        }
        precondition(keys.contains(0) && keys.contains(45))
        // Off revokes already submitted callbacks before the hardware drain.
        encoder.encode(lastImage!, captureTimeUS: PlankMacCameraEncoder.nowUS)
        gate.revoke()
        let countAtOff = records.snapshot.count
        encoder.finish()
        precondition(records.snapshot.count == countAtOff, "late callback after off")
        try stream.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        var framed = Data()
        for packet in emitted {
            let size = UInt32(packet.count)
            framed.append(contentsOf: [UInt8(size >> 24), UInt8(truncatingIfNeeded: size >> 16),
                                      UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size)])
            framed.append(packet)
        }
        try framed.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + ".pcam"))
        let result: [String: Any] = ["passed": true, "frames": emitted.count, "keyFrames": keys,
            "hardwareEncoder": true, "pcamVersion": 2, "colorSPSValidated": true,
            "physicalCameraUsed": false, "productSessionUsed": false]
        let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(json); FileHandle.standardOutput.write(Data([10]))
    }
}
