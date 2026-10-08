import Foundation

/// One fit transform owns both presentation and remote coordinates. Black
/// margins reject new contacts; an existing drag clamps to the video edge.
struct PlankIPadViewport {
    let rect: CGRect
    let width: Int
    let height: Int
    init?(bounds: CGRect, width: Int, height: Int) {
        guard bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0, width > 1, height > 1,
              width <= 65536, height <= 65536 else { return nil }
        let scale = min(bounds.width / CGFloat(width), bounds.height / CGFloat(height))
        rect = CGRect(x: bounds.midX - CGFloat(width) * scale / 2,
                      y: bounds.midY - CGFloat(height) * scale / 2,
                      width: CGFloat(width) * scale, height: CGFloat(height) * scale)
        self.width = width; self.height = height
    }
    func map(_ point: CGPoint, held: Bool = false) -> (x: Int, y: Int)? {
        guard point.x.isFinite, point.y.isFinite,
              held || (point.x >= rect.minX && point.x <= rect.maxX &&
                       point.y >= rect.minY && point.y <= rect.maxY) else { return nil }
        let x = min(max((point.x - rect.minX) / rect.width, 0), 1)
        let y = min(max((point.y - rect.minY) / rect.height, 0), 1)
        return (Int((x * CGFloat(width - 1)).rounded()),
                Int((y * CGFloat(height - 1)).rounded()))
    }
}

struct PlankIPadHeldInput {
    private(set) var buttons = Set<UInt8>()
    private(set) var keys: [UInt16: UInt8] = [:]
    mutating func button(_ number: UInt8, pressed: Bool) -> Bool {
        pressed ? buttons.insert(number).inserted : buttons.remove(number) != nil
    }
    mutating func key(_ code: UInt16, pressed: Bool, modifiers: UInt8) -> Bool {
        if pressed { keys[code] = modifiers; return true }
        return keys.removeValue(forKey: code) != nil
    }
    mutating func release() -> (buttons: [UInt8], keys: [(UInt16, UInt8)]) {
        let result = (buttons.sorted(), keys.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
        buttons.removeAll(); keys.removeAll()
        return result
    }
}

struct PlankIPadWheel {
    private var x = 0.0
    private var y = 0.0
    mutating func add(x: Double, y: Double) -> (vertical: Int16, horizontal: Int16) {
        guard x.isFinite, y.isFinite else { return (0, 0) }
        self.x += min(max(x, -32767), 32767)
        self.y += min(max(y, -32767), 32767)
        let dx = min(max(self.x.rounded(.towardZero), -32767), 32767)
        let dy = min(max(self.y.rounded(.towardZero), -32767), 32767)
        self.x -= dx; self.y -= dy
        return (Int16(dy), Int16(dx))
    }
    mutating func reset() { x = 0; y = 0 }
}
