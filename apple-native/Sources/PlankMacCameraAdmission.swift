// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Capture/encode admission is independent of the video, audio and Wacom workers.
/// All revocation and final submission are serialized by this lock. The submitter
/// must be a bounded, nonblocking camera-lane write and must not re-enter this object.
final class PlankMacCameraAdmission: @unchecked Sendable {
    struct Activation: Equatable, Sendable {
        fileprivate let epoch: UInt64
        let generation: UInt64
    }
    struct Job: Equatable, Sendable {
        fileprivate let activation: Activation
        fileprivate let ordinal: UInt64
        fileprivate let revision: UInt64
        let captureTimeUS: UInt64
        let forceIndependent: Bool
    }
    struct Frame: Sendable {
        let generation: UInt64
        let sequence: UInt64
        let captureTimeUS: UInt64
        let independent: Bool
        let discontinuity: Bool
        let payload: Data
    }
    static let maximumAgeUS: UInt64 = 150_000
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var current: Activation?
    private var jobs: [UInt64: Job] = [:]
    private var ordinal: UInt64 = 0
    private var sequence: UInt64 = 0
    private var revision: UInt64 = 0
    private var needsIndependent = true
    private var lastCapture: UInt64 = 0
    private var lastSentCapture: UInt64 = 0

    /// An authenticated feature-2 agreement and matching CAMERA_APPLIED are both
    /// required. This value is not a substitute for AVFoundation camera consent.
    func activate(version: UInt32, generation: UInt64, acknowledgedGeneration: UInt64) -> Activation? {
        lock.lock(); defer { lock.unlock() }
        retireLocked()
        guard version == 2, generation > 0, generation < UInt64.max,
              generation == acknowledgedGeneration, epoch < UInt64.max else { return nil }
        epoch += 1
        let activation = Activation(epoch: epoch, generation: generation)
        current = activation
        ordinal = 0; sequence = 0; revision = 0
        lastCapture = 0; lastSentCapture = 0; needsIndependent = true
        return activation
    }
    func revoke() {
        lock.lock(); defer { lock.unlock() }
        retireLocked()
    }
    @discardableResult
    func revoke(_ activation: Activation) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard current == activation else { return false }
        retireLocked(); return true
    }
    private func retireLocked() {
        current = nil; jobs.removeAll()
        needsIndependent = true
    }
    var hasActivation: Bool {
        lock.lock(); defer { lock.unlock() }; return current != nil
    }
    func isCurrent(_ activation: Activation) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return current == activation
    }
    func invalidateReference(_ activation: Activation) {
        lock.lock(); defer { lock.unlock() }
        if current == activation { invalidateLocked() }
    }
    private func invalidateLocked() {
        needsIndependent = true
        if revision < UInt64.max { revision += 1 } else { retireLocked() }
    }
    func reserve(_ activation: Activation, captureTimeUS: UInt64, nowUS: UInt64) -> Job? {
        lock.lock(); defer { lock.unlock() }
        guard current == activation else { return nil }
        guard captureTimeUS > lastCapture, captureTimeUS <= UInt64(Int64.max) / 1000,
              nowUS >= captureTimeUS, nowUS - captureTimeUS <= Self.maximumAgeUS,
              jobs.count < 2, ordinal < UInt64.max else {
            invalidateLocked(); return nil
        }
        lastCapture = captureTimeUS
        let job = Job(activation: activation, ordinal: ordinal, revision: revision,
                      captureTimeUS: captureTimeUS, forceIndependent: needsIndependent)
        ordinal += 1; jobs[job.ordinal] = job
        return job
    }
    func discard(_ job: Job) {
        lock.lock(); defer { lock.unlock() }
        guard current == job.activation, jobs.removeValue(forKey: job.ordinal) == job else { return }
        invalidateLocked()
    }
    @discardableResult
    func complete(_ job: Job, independent: Bool, payload: Data, nowUS: UInt64,
                  submit: (Frame) -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard current == job.activation, jobs.removeValue(forKey: job.ordinal) == job else { return false }
        guard job.revision == revision else { return false }
        guard nowUS >= job.captureTimeUS, nowUS - job.captureTimeUS <= Self.maximumAgeUS,
              job.captureTimeUS > lastSentCapture, !payload.isEmpty, payload.count <= 4 * 1024 * 1024,
              sequence < UInt64.max else { invalidateLocked(); return false }
        guard !needsIndependent || independent else { invalidateLocked(); return false }
        let frame = Frame(generation: job.activation.generation, sequence: sequence,
                          captureTimeUS: job.captureTimeUS, independent: independent,
                          discontinuity: needsIndependent, payload: payload)
        // A transport drop may consume the ordinal while clearing its queue.
        // Never reuse a submitted sequence, even when the write reports a drop.
        sequence += 1
        guard submit(frame) else { invalidateLocked(); return false }
        needsIndependent = false
        lastSentCapture = job.captureTimeUS
        return true
    }
    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return jobs.count
    }
}
