// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// Calls enter from the codec's serial queue. Store their order before hopping
// to the main actor; separate Tasks alone do not guarantee FIFO submission.
final class PlankRelayWriteQueue: @unchecked Sendable {
    struct Item: Sendable {
        let data: Data
        let completion: @Sendable ((any Error)?) -> Void
    }
    enum AppendResult { case rejected, queued, startPump }
    private let lock = NSLock()
    private var items: [Item] = []
    private var bytes = 0
    private var pumping = false
    private var cancelled = false
    func append(_ data: Data, completion: @escaping @Sendable ((any Error)?) -> Void) -> AppendResult {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, items.count < 64, data.count <= 16384 - bytes else { return .rejected }
        items.append(Item(data: data, completion: completion)); bytes += data.count
        let start = !pumping; pumping = true
        return start ? .startPump : .queued
    }
    func next() -> Item? {
        lock.lock(); defer { lock.unlock() }
        guard !items.isEmpty else { pumping = false; return nil }
        let item = items.removeFirst(); bytes -= item.data.count
        return item
    }
    func cancel() -> [Item] {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        let pending = items; items.removeAll(); bytes = 0
        return pending
    }
}
