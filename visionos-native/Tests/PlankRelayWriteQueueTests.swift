import Foundation
@main enum PlankRelayWriteQueueTests {
    static func main() {
        let queue = PlankRelayWriteQueue()
        precondition(queue.append(Data([1]), completion: { _ in }) == .startPump)
        precondition(queue.append(Data([2]), completion: { _ in }) == .queued)
        precondition(queue.next()?.data == Data([1]))
        precondition(queue.append(Data([3]), completion: { _ in }) == .queued)
        precondition(queue.next()?.data == Data([2]))
        precondition(queue.next()?.data == Data([3]))
        precondition(queue.next() == nil)
        precondition(queue.append(Data(repeating: 1, count: 16384), completion: { _ in }) == .startPump)
        precondition(queue.append(Data([4]), completion: { _ in }) == .rejected)
        precondition(queue.cancel().count == 1)
        precondition(queue.next() == nil)
        precondition(queue.append(Data(), completion: { _ in }) == .rejected)
        let packets = PlankRelayWriteQueue()
        for _ in 0..<64 { precondition(packets.append(Data(), completion: { _ in }) != .rejected) }
        precondition(packets.append(Data(), completion: { _ in }) == .rejected)
        print("Bluetooth write queue: ordering, byte/packet bounds, and cancellation passed")
    }
}
