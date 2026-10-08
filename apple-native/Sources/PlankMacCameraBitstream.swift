// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// The initial encoder uses progressive baseline AVC. Validate its SPS VUI,
/// not merely the declared PCAM color. A decoder must still validate the stream.
enum PlankMacCameraSPS {
    private struct Bits {
        var bytes: [UInt8]
        var offset = 0
        mutating func read(_ count: Int) throws -> UInt32 {
            guard count >= 0, count <= 32, offset <= bytes.count * 8 - count else { throw Invalid.bits }
            var value: UInt32 = 0
            for _ in 0..<count {
                value = (value << 1) | UInt32((bytes[offset / 8] >> (7 - offset % 8)) & 1)
                offset += 1
            }
            return value
        }
        mutating func ue() throws -> UInt32 {
            var zeroes = 0
            while try read(1) == 0 { zeroes += 1; if zeroes > 20 { throw Invalid.bits } }
            return ((1 << zeroes) - 1) + (try read(zeroes))
        }
    }
    private enum Invalid: Error { case bits }
    static func is720pBT709Limited(_ nal: Data) -> Bool {
        guard nal.count > 4, nal.count <= 4096, nal[0] & 0x80 == 0, nal[0] & 31 == 7 else { return false }
        var rbsp: [UInt8] = []; var zeroes = 0; var index = 1
        while index < nal.count {
            let byte = nal[index]
            if zeroes >= 2, byte == 3 {
                guard index + 1 < nal.count, nal[index + 1] <= 3 else { return false }
                zeroes = 0; index += 1; continue
            }
            if zeroes >= 2, byte <= 2 { return false }
            rbsp.append(byte)
            zeroes = byte == 0 ? zeroes + 1 : 0
            index += 1
        }
        do {
            var bits = Bits(bytes: rbsp)
            guard try bits.read(8) == 66 else { return false } // Baseline only.
            guard try bits.read(8) & 3 == 0 else { return false } // Reserved constraints.
            _ = try bits.read(8) // Level is independently checked by the decoder.
            guard try bits.ue() <= 31, try bits.ue() <= 12 else { return false }
            let order = try bits.ue()
            if order == 0 { guard try bits.ue() <= 12 else { return false } }
            else if order != 2 { return false }
            guard try bits.ue() <= 16 else { return false }
            _ = try bits.read(1)
            let widthMB = try bits.ue() + 1, heightMB = try bits.ue() + 1
            guard widthMB <= 256, heightMB <= 256, try bits.read(1) == 1 else { return false }
            _ = try bits.read(1)
            var left: UInt32 = 0, right: UInt32 = 0, top: UInt32 = 0, bottom: UInt32 = 0
            if try bits.read(1) != 0 {
                left = try bits.ue(); right = try bits.ue(); top = try bits.ue(); bottom = try bits.ue()
            }
            guard left + right < widthMB * 8, top + bottom < heightMB * 8,
                  widthMB * 16 - 2 * (left + right) == 1280,
                  heightMB * 16 - 2 * (top + bottom) == 720,
                  try bits.read(1) == 1 else { return false } // VUI required.
            if try bits.read(1) != 0 { // Aspect ratio.
                if try bits.read(8) == 255 { _ = try bits.read(16); _ = try bits.read(16) }
            }
            if try bits.read(1) != 0 { _ = try bits.read(1) } // Overscan.
            guard try bits.read(1) == 1 else { return false } // Video signal type required.
            _ = try bits.read(3)
            return try bits.read(1) == 0 && bits.read(1) == 1 &&
                bits.read(8) == 1 && bits.read(8) == 1 && bits.read(8) == 1
        } catch { return false }
    }
}
