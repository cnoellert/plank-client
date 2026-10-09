import Foundation

// Independent, versioned normalized source. No HID descriptor or Wacom identity.
enum PlankPencilMessage: Sendable, Equatable {
    case configuration(width: UInt32, height: UInt32, active: Bool)
    case pen(PlankNormalizedPen)
    case rightClick(x: Float, y: Float)
    case modifier(PlankPencilModifier, pressed: Bool)
    case ping, pong, end

    var replaceablePhase: PlankNormalizedPen.Phase? {
        guard case let .pen(p) = self, p.phase == .hover || p.phase == .move else { return nil }
        return p.phase
    }
    func encoded() throws -> Data {
        var out = Data([0x50, 0x4c, 0x50, 0x4e, 2])
        func u32(_ value: UInt32) { for n in 0..<4 { out.append(UInt8(truncatingIfNeeded: value >> (8*n))) } }
        func scalar(_ value: Float) throws {
            guard value.isFinite, (0...1).contains(value) else { throw PlankPencilWireError.invalid }
            u32(value.bitPattern)
        }
        switch self {
        case let .configuration(w,h,active):
            guard (2...65536).contains(w), (2...65536).contains(h) else { throw PlankPencilWireError.invalid }
            out.append(1); u32(w); u32(h); out.append(active ? 1 : 0)
        case let .pen(p):
            guard p.tilt <= 90 || p.tilt == 255, p.rotation < 360 || p.rotation == 65535,
                  (p.tilt == 255) == (p.rotation == 65535),
                  [.down,.move,.hover].contains(p.phase) || p.pressureOrDistance == 0 else { throw PlankPencilWireError.invalid }
            out.append(2); out.append(p.phase.rawValue)
            try scalar(p.x); try scalar(p.y); try scalar(p.pressureOrDistance)
            out.append(p.tilt); out.append(UInt8(truncatingIfNeeded:p.rotation)); out.append(UInt8(p.rotation >> 8))
        case let .rightClick(x,y): out.append(3); try scalar(x); try scalar(y)
        case .ping: out.append(4)
        case .pong: out.append(5)
        case .end: out.append(6)
        case let .modifier(key,pressed):
            out.append(7); out.append(UInt8(truncatingIfNeeded:key.rawValue)); out.append(UInt8(key.rawValue >> 8)); out.append(pressed ? 1 : 0)
        }
        return out
    }
    static func decode(_ data: Data) throws -> Self {
        let b = Array(data)
        guard b.count >= 6, b.prefix(5) == [0x50,0x4c,0x50,0x4e,2] else { throw PlankPencilWireError.invalid }
        func u32(_ i: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[i+$1]) << (8*$1) } }
        let result: Self
        switch (b[5],b.count) {
        case (1,15):
            guard b[14] <= 1 else { throw PlankPencilWireError.invalid }
            result = .configuration(width:u32(6),height:u32(10),active:b[14] == 1)
        case (2,22):
            guard let phase = PlankNormalizedPen.Phase(rawValue:b[6]) else { throw PlankPencilWireError.invalid }
            result = .pen(.init(phase:phase,x:Float(bitPattern:u32(7)),y:Float(bitPattern:u32(11)),
                pressureOrDistance:Float(bitPattern:u32(15)),tilt:b[19],rotation:UInt16(b[20]) | UInt16(b[21]) << 8))
        case (3,14): result = .rightClick(x:Float(bitPattern:u32(6)),y:Float(bitPattern:u32(10)))
        case (4,6): result = .ping
        case (5,6): result = .pong
        case (6,6): result = .end
        case (7,9):
            guard b[8] <= 1, let key = PlankPencilModifier(rawValue:UInt16(b[6]) | UInt16(b[7]) << 8) else { throw PlankPencilWireError.invalid }
            result = .modifier(key,pressed:b[8] == 1)
        default: throw PlankPencilWireError.invalid
        }
        _ = try result.encoded() // Same finite/range rules in both directions.
        return result
    }
}
enum PlankPencilWireError: Error { case invalid, overflow, storage, crypto }

struct PlankPencilStrokeState {
    private(set) var touching = false
    private var last: PlankNormalizedPen?
    mutating func accept(_ packet: PlankNormalizedPen) throws {
        _ = try PlankPencilMessage.pen(packet).encoded()
        switch packet.phase {
        case .down: guard !touching else { throw PlankPencilWireError.invalid }; touching = true
        case .move: guard touching else { throw PlankPencilWireError.invalid }
        case .up: guard touching else { throw PlankPencilWireError.invalid }; touching = false
        case .hover: guard !touching else { throw PlankPencilWireError.invalid }
        case .cancel: touching = false
        case .leave: guard !touching else { throw PlankPencilWireError.invalid }
        }
        last = packet.phase == .leave ? nil : packet
    }
    mutating func retire() -> [PlankNormalizedPen] {
        guard var p = last else { return [] }
        var result: [PlankNormalizedPen] = []
        p.pressureOrDistance = 0
        if touching { p.phase = .cancel; result.append(p) }
        p.phase = .leave; result.append(p)
        last = nil; touching = false
        return result
    }
}

// Thread-safe admission BEFORE scheduling work: event edges cannot accumulate
// as unbounded dispatch closures. Only consecutive same-phase motion coalesces.
final class PlankPencilMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PlankPencilMessage] = []
    private var failed = false
    private var closed = false
    let limit: Int
    init(limit: Int = 128) { self.limit = limit }
    func offer(_ value: PlankPencilMessage) -> (accepted: Bool, wake: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !failed, !closed else { return (false,false) }
        let wake = values.isEmpty
        if let phase = value.replaceablePhase, values.last?.replaceablePhase == phase {
            values[values.count-1] = value
        } else {
            guard values.count < limit else { failed = true; return (false,true) }
            values.append(value)
        }
        return (true,wake)
    }
    func take() throws -> PlankPencilMessage? {
        lock.lock(); defer { lock.unlock() }
        guard !failed else { throw PlankPencilWireError.overflow }
        return values.isEmpty ? nil : values.removeFirst()
    }
    func close() { lock.lock(); closed = true; values.removeAll(); lock.unlock() }
}
