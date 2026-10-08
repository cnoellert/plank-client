// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

@main struct PlankMacCameraAdmissionTests {
    static func main() {
        let gate = PlankMacCameraAdmission()
        precondition(gate.activate(version: 1, generation: 1, acknowledgedGeneration: 1) == nil)
        precondition(gate.activate(version: 2, generation: 1, acknowledgedGeneration: 2) == nil)
        precondition(gate.activate(version: 2, generation: 0, acknowledgedGeneration: 0) == nil)
        precondition(gate.activate(version: 2, generation: .max, acknowledgedGeneration: .max) == nil)
        let activation = gate.activate(version: 2, generation: 1, acknowledgedGeneration: 1)!
        let first = gate.reserve(activation, captureTimeUS: 1, nowUS: 1)!
        let second = gate.reserve(activation, captureTimeUS: 2, nowUS: 2)!
        precondition(first.forceIndependent && second.forceIndependent)
        precondition(gate.pendingCount == 2)
        precondition(gate.reserve(activation, captureTimeUS: 3, nowUS: 3) == nil)
        let bytes = Data([1])
        precondition(!gate.complete(first, independent: true, payload: bytes, nowUS: 3) { _ in fatalError("retired reference submitted") })
        precondition(!gate.complete(second, independent: true, payload: bytes, nowUS: 3) { _ in fatalError("retired reference submitted") })
        precondition(gate.pendingCount == 0)
        let key = gate.reserve(activation, captureTimeUS: 4, nowUS: 4)!
        precondition(key.forceIndependent)
        precondition(gate.complete(key, independent: true, payload: bytes, nowUS: 4) {
            precondition($0.sequence == 0 && $0.discontinuity && $0.generation == 1); return true
        })
        precondition(!gate.complete(key, independent: true, payload: bytes, nowUS: 4) { _ in fatalError("duplicate callback") })
        let expired = gate.reserve(activation, captureTimeUS: 5, nowUS: 5)!
        precondition(!gate.complete(expired, independent: false, payload: bytes, nowUS: 150_006) { _ in fatalError("expired frame submitted") })
        let dependent = gate.reserve(activation, captureTimeUS: 150_007, nowUS: 150_007)!
        precondition(dependent.forceIndependent)
        precondition(!gate.complete(dependent, independent: false, payload: bytes, nowUS: 150_007) { _ in fatalError("dependent frame after expiry") })
        let recovery = gate.reserve(activation, captureTimeUS: 150_008, nowUS: 150_008)!
        precondition(gate.complete(recovery, independent: true, payload: bytes, nowUS: 150_008) {
            precondition($0.sequence == 1 && $0.discontinuity); return true
        })
        let rejected = gate.reserve(activation, captureTimeUS: 150_009, nowUS: 150_009)!
        precondition(!gate.complete(rejected, independent: false, payload: bytes, nowUS: 150_009) { _ in false })
        let afterDrop = gate.reserve(activation, captureTimeUS: 150_010, nowUS: 150_010)!
        precondition(gate.complete(afterDrop, independent: true, payload: bytes, nowUS: 150_010) {
            precondition($0.sequence == 3 && $0.discontinuity, "a rejected submission still consumes its ordinal"); return true
        })
        gate.invalidateReference(activation)
        let pending = gate.reserve(activation, captureTimeUS: 150_011, nowUS: 150_011)!
        precondition(pending.forceIndependent)
        let newer = gate.activate(version: 2, generation: 2, acknowledgedGeneration: 2)!
        precondition(!gate.complete(pending, independent: true, payload: bytes, nowUS: 150_010) { _ in fatalError("old generation callback") })
        precondition(!gate.revoke(activation) && gate.isCurrent(newer))
        precondition(gate.reserve(newer, captureTimeUS: 0, nowUS: 1) == nil)
        precondition(gate.reserve(newer, captureTimeUS: 2, nowUS: 1) == nil)
        precondition(gate.reserve(newer, captureTimeUS: 1, nowUS: 150_002) == nil)
        let current = gate.reserve(newer, captureTimeUS: 3, nowUS: 3)!
        precondition(gate.complete(current, independent: true, payload: bytes, nowUS: 3) {
            precondition($0.sequence == 0 && $0.generation == 2); return true
        })
        precondition(gate.reserve(newer, captureTimeUS: 2, nowUS: 3) == nil)
        let invalid = gate.reserve(newer, captureTimeUS: 4, nowUS: 4)!
        precondition(!gate.complete(invalid, independent: true, payload: Data(), nowUS: 4) { _ in fatalError("empty frame") })
        let unsent = gate.reserve(newer, captureTimeUS: 5, nowUS: 5)!
        gate.revoke()
        precondition(!gate.complete(unsent, independent: true, payload: bytes, nowUS: 5) { _ in fatalError("callback after off") })
        precondition(gate.pendingCount == 0 && !gate.isCurrent(newer))
        precondition(gate.reserve(newer, captureTimeUS: 6, nowUS: 6) == nil)
        // Reusing an on-wire generation still cannot reuse an in-process activation.
        let reused = gate.activate(version: 2, generation: 2, acknowledgedGeneration: 2)!
        precondition(reused != newer && !gate.revoke(newer))
        let racing = gate.reserve(reused, captureTimeUS: 7, nowUS: 7)!
        let entered = DispatchSemaphore(value: 0), leave = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0), revoked = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            precondition(gate.complete(racing, independent: true, payload: bytes, nowUS: 7) { _ in
                entered.signal(); precondition(leave.wait(timeout: .now() + 2) == .success); return true
            }); completed.signal()
        }
        precondition(entered.wait(timeout: .now() + 2) == .success)
        DispatchQueue.global().async { gate.revoke(); revoked.signal() }
        precondition(revoked.wait(timeout: .now() + 0.02) == .timedOut)
        leave.signal()
        precondition(completed.wait(timeout: .now() + 2) == .success && revoked.wait(timeout: .now() + 2) == .success)
        precondition(!gate.isCurrent(reused))
        precondition(PlankMacCameraSPS.is720pBT709Limited(Data([0x27,0x42,0,0x1f,0xab,0x40,0x28,0x02,0xdd,0x35,1,1,1,2])))
        var wrongColor = Data([0x27,0x42,0,0x1f,0xab,0x40,0x28,0x02,0xdd,0x35,1,1,1,2])
        wrongColor[10] = 6
        precondition(!PlankMacCameraSPS.is720pBT709Limited(wrongColor))
        var wrongProfile = wrongColor; wrongProfile[1] = 100
        precondition(!PlankMacCameraSPS.is720pBT709Limited(wrongProfile))
        for length in 0..<14 {
            precondition(!PlankMacCameraSPS.is720pBT709Limited(Data(wrongColor.prefix(length))))
        }
        precondition(!PlankMacCameraSPS.is720pBT709Limited(Data(repeating: 0, count: 4097)))
        print("Camera admission: acknowledgement, queue, recovery, epoch and revocation gates passed")
    }
}
