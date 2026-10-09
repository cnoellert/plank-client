import Foundation
@main struct PencilRelayChecks {
    static func main() throws {
        let hover = PlankNormalizedPen(phase:.hover,x:0.5,y:1,pressureOrDistance:0.25,tilt:45,rotation:359)
        var down = hover; down.phase = .down; down.pressureOrDistance = 0.9
        var move = down; move.phase = .move; move.x = 0.8
        var up = move; up.phase = .up; up.pressureOrDistance = 0
        for message: PlankPencilMessage in [.pen(hover),.pen(down),.pen(move),.pen(up),.configuration(width:5120,height:2880,active:true),.rightClick(x:1,y:0),.ping,.pong,.end] {
            let decoded = try PlankPencilMessage.decode(message.encoded()); assert(decoded == message)
            var wrong = try message.encoded(); wrong[4] = 2
            rejects { _ = try PlankPencilMessage.decode(wrong) }
            rejects { _ = try PlankPencilMessage.decode(message.encoded() + Data([0])) }
        }
        for invalid in [Float.nan,Float.infinity,-0.01,1.01] {
            var p = down; p.x = invalid; rejects { _ = try PlankPencilMessage.pen(p).encoded() }
        }
        var p = up; p.pressureOrDistance = 1; rejects { _ = try PlankPencilMessage.pen(p).encoded() }
        let mailbox = PlankPencilMailbox(limit:4)
        assert(mailbox.offer(.pen(hover)).wake)
        assert(!mailbox.offer(.pen(hover)).wake)
        assert(mailbox.offer(.pen(down)).accepted)
        for _ in 0..<10_000 { assert(mailbox.offer(.pen(move)).accepted) }
        assert(mailbox.offer(.pen(up)).accepted)
        var result: [PlankPencilMessage] = []
        while let next = try mailbox.take() { result.append(next) }
        assert(result == [.pen(hover),.pen(down),.pen(move),.pen(up)])
        let overflow = PlankPencilMailbox(limit:2)
        assert(overflow.offer(.pen(down)).accepted && overflow.offer(.pen(up)).accepted)
        assert(!overflow.offer(.pen(down)).accepted)
        rejects { _ = try overflow.take() } // Fail closed, never silently lose an edge.
        var state = PlankPencilStrokeState()
        rejects { try state.accept(move) }
        try state.accept(down)
        rejects { try state.accept(down) }
        try state.accept(move)
        let terminals = state.retire(); assert(terminals.map(\.phase) == [.cancel,.leave])
        assert(state.retire().isEmpty)
        rejects { try state.accept(move) } // Retired contact requires a fresh down.
        try state.accept(down); try state.accept(up)
        print("Pencil relay codec, malformed data, edge ordering, bounded coalescing and fresh-contact checks passed")
    }
    static func rejects(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Invalid input accepted") } catch {}
    }
}
