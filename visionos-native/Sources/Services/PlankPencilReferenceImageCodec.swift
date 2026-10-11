// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// An independently decodable, full-composite reference. This SDR JPEG is not
/// the native stream and is not suitable for judging colour-critical output.
nonisolated struct PlankPencilEncodedReferenceImage: Sendable {
    let jpegData: Data
    let sourceWidth: Int
    let sourceHeight: Int
    let encodedWidth: Int
    let encodedHeight: Int
}

/// Synchronous worker operations; the caller owns scheduling and a latest-frame
/// mailbox. Nothing here captures a UI object, persists pixels or uses CoreImage's
/// YUV conversion (the Host's xf44 samples are identity GBR, not YUV).
nonisolated enum PlankPencilReferenceImageCodec {
    enum Failure: Error {
        case invalidSourceDimensions
        case invalidSourceStorage
        case unsupportedPixelFormat
        case unavailablePixelStorage
        case imageCreationFailed
        case encodedImageTooLarge
        case invalidEncodedImage
    }

    static let maximumDimension = 1920
    static let maximumEncodedBytes = 2 * 1024 * 1024
    private static let maximumSourceDimension = 16_384
    private static let maximumSourcePixels = 33_554_432
    private static let maximumSourceStorage = 256 * 1024 * 1024

    nonisolated static func encode(_ frame: PlankRenderedFrame) throws -> PlankPencilEncodedReferenceImage {
        try validateSource(width: frame.width, height: frame.height)
        let scale = min(1.0, Double(maximumDimension) / Double(max(frame.width, frame.height)))
        let width = max(1, Int((Double(frame.width) * scale).rounded()))
        let height = max(1, Int((Double(frame.height) * scale).rounded()))
        // Allocate only the reduced output. Hardware reconstruction never makes
        // an RGBA copy of the potentially much larger original pixel buffer.
        var output = Data(count: width * height * 4)
        if let buffer = frame.pixelBuffer {
            try reconstructGBR(buffer, sourceWidth: frame.width, sourceHeight: frame.height,
                               output: &output, width: width, height: height)
        } else {
            let count = try storageSize(stride: frame.bytesPerRow, height: frame.height,
                                        minimumStride: frame.width * 4)
            guard frame.pixels.count >= count else { throw Failure.invalidSourceStorage }
            frame.pixels.withUnsafeBytes { source in
                output.withUnsafeMutableBytes { destination in
                    resample(sourceWidth: frame.width, sourceHeight: frame.height,
                             destination: destination, width: width, height: height) { x, y in
                        let offset = y * frame.bytesPerRow + x * 4
                        // This is the exact little-endian premultiplied-first
                        // BGRA interpretation used by RemoteDesktopView. Keep
                        // premultiplied RGB (black backdrop) and make JPEG opaque.
                        return SIMD3(Double(source[offset]), Double(source[offset + 1]),
                                     Double(source[offset + 2]))
                    }
                }
            }
        }
        let image = try bgraImage(output, width: width, height: height)
        // A noisy frame can exceed the wire bound. Retry at a finite number of
        // lower qualities, retaining the full composite and its geometry.
        for quality in [0.80, 0.60, 0.40] {
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                encoded, "public.jpeg" as CFString, 1, nil) else { throw Failure.imageCreationFailed }
            CGImageDestinationAddImage(destination, image, [
                kCGImageDestinationLossyCompressionQuality: quality,
                kCGImagePropertyOrientation: 1
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw Failure.imageCreationFailed }
            if encoded.length > 0 && encoded.length <= maximumEncodedBytes {
                return PlankPencilEncodedReferenceImage(
                    jpegData: encoded as Data, sourceWidth: frame.width, sourceHeight: frame.height,
                    encodedWidth: width, encodedHeight: height)
            }
        }
        throw Failure.encodedImageTooLarge
    }

    nonisolated static func decode(_ jpegData: Data, expectedWidth: Int,
                                   expectedHeight: Int) throws -> CGImage {
        guard expectedWidth > 0, expectedHeight > 0,
              expectedWidth <= maximumDimension, expectedHeight <= maximumDimension,
              jpegData.count >= 4, jpegData.count <= maximumEncodedBytes,
              jpegData.starts(with: [0xff, 0xd8]), jpegData.suffix(2).elementsEqual([0xff, 0xd9]) else {
            throw Failure.invalidEncodedImage
        }
        let lazyOptions = [kCGImageSourceShouldCache: false,
                           kCGImageSourceShouldAllowFloat: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, lazyOptions),
              CGImageSourceGetType(source) == "public.jpeg" as CFString,
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, lazyOptions) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue == expectedWidth, height.intValue == expectedHeight,
              width.doubleValue == Double(expectedWidth), height.doubleValue == Double(expectedHeight),
              (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1 else {
            throw Failure.invalidEncodedImage
        }
        // Validate compressed dimensions before ImageIO eagerly decompresses.
        guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false
        ] as CFDictionary), CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              decoded.width == expectedWidth, decoded.height == expectedHeight,
              decoded.bitsPerComponent == 8,
              let colour = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: expectedWidth, height: expectedHeight,
                                      bitsPerComponent: 8, bytesPerRow: expectedWidth * 4,
                                      space: colour, bitmapInfo: bitmapInfo.rawValue) else {
            throw Failure.invalidEncodedImage
        }
        context.setBlendMode(.copy)
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: expectedWidth, height: expectedHeight))
        guard let image = context.makeImage() else { throw Failure.imageCreationFailed }
        return image
    }

    nonisolated private static var bitmapInfo: CGBitmapInfo {
        .byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
    }

    nonisolated private static func validateSource(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= maximumSourceDimension, height <= maximumSourceDimension else {
            throw Failure.invalidSourceDimensions
        }
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow, pixels.partialValue <= maximumSourcePixels else {
            throw Failure.invalidSourceDimensions
        }
    }

    nonisolated private static func storageSize(stride: Int, height: Int, minimumStride: Int) throws -> Int {
        let count = stride.multipliedReportingOverflow(by: height)
        guard stride >= minimumStride, !count.overflow, count.partialValue > 0,
              count.partialValue <= maximumSourceStorage else { throw Failure.invalidSourceStorage }
        return count.partialValue
    }

    nonisolated private static func reconstructGBR(
        _ buffer: CVPixelBuffer, sourceWidth: Int, sourceHeight: Int,
        output: inout Data, width: Int, height: Int
    ) throws {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange else {
            throw Failure.unsupportedPixelFormat
        }
        guard CVPixelBufferGetWidth(buffer) == sourceWidth, CVPixelBufferGetHeight(buffer) == sourceHeight,
              CVPixelBufferIsPlanar(buffer), CVPixelBufferGetPlaneCount(buffer) == 2,
              (0..<2).allSatisfy({ CVPixelBufferGetWidthOfPlane(buffer, $0) == sourceWidth &&
                                  CVPixelBufferGetHeightOfPlane(buffer, $0) == sourceHeight }) else {
            throw Failure.invalidSourceStorage
        }
        let greenStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let blueRedStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let greenCount = try storageSize(stride: greenStride, height: sourceHeight, minimumStride: sourceWidth * 2)
        let blueRedCount = try storageSize(stride: blueRedStride, height: sourceHeight, minimumStride: sourceWidth * 4)
        let total = greenCount.addingReportingOverflow(blueRedCount)
        guard !total.overflow, total.partialValue <= maximumSourceStorage,
              CVPixelBufferGetDataSize(buffer) >= total.partialValue else { throw Failure.invalidSourceStorage }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw Failure.unavailablePixelStorage
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let green = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let blueRed = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
            throw Failure.unavailablePixelStorage
        }
        output.withUnsafeMutableBytes { destination in
            resample(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                     destination: destination, width: width, height: height) { x, y in
                let g = UInt16(littleEndian: green.loadUnaligned(fromByteOffset: y * greenStride + x * 2, as: UInt16.self))
                let offset = y * blueRedStride + x * 4
                let b = UInt16(littleEndian: blueRed.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                let r = UInt16(littleEndian: blueRed.loadUnaligned(fromByteOffset: offset + 2, as: UInt16.self))
                // Metal reads r16Unorm/rg16Unorm then multiplies by
                // 65535/65472. Equivalently divide the raw word by 65472.
                return SIMD3(min(255, Double(b) * 255 / 65472),
                             min(255, Double(g) * 255 / 65472),
                             min(255, Double(r) * 255 / 65472))
            }
        }
    }

    nonisolated private static func resample(
        sourceWidth: Int, sourceHeight: Int, destination: UnsafeMutableRawBufferPointer,
        width: Int, height: Int, sample: (Int, Int) -> SIMD3<Double>
    ) {
        let scaleX = Double(sourceWidth) / Double(width)
        let scaleY = Double(sourceHeight) / Double(height)
        for y in 0..<height {
            let sourceY = max(0, min(Double(sourceHeight - 1), (Double(y) + 0.5) * scaleY - 0.5))
            let top = Int(sourceY), bottom = min(sourceHeight - 1, top + 1)
            let vertical = sourceY - Double(top)
            for x in 0..<width {
                let sourceX = max(0, min(Double(sourceWidth - 1), (Double(x) + 0.5) * scaleX - 0.5))
                let left = Int(sourceX), right = min(sourceWidth - 1, left + 1)
                let horizontal = sourceX - Double(left)
                let upper = sample(left, top) * (1 - horizontal) + sample(right, top) * horizontal
                let lower = sample(left, bottom) * (1 - horizontal) + sample(right, bottom) * horizontal
                let value = upper * (1 - vertical) + lower * vertical
                let offset = (y * width + x) * 4
                destination[offset] = UInt8(value.x.rounded())
                destination[offset + 1] = UInt8(value.y.rounded())
                destination[offset + 2] = UInt8(value.z.rounded())
                destination[offset + 3] = 255
            }
        }
    }

    nonisolated private static func bgraImage(_ data: Data, width: Int, height: Int) throws -> CGImage {
        guard let colour = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: colour, bitmapInfo: bitmapInfo,
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw Failure.imageCreationFailed
        }
        return image
    }
}
