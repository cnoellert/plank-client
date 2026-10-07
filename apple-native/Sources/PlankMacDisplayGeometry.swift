import AppKit

/// Source pixels, local points and Host desktop origins are different spaces.
/// Use source_rect for both the video crop and absolute input into the one
/// composite stream. Local Retina scale never participates in remote mapping.
struct PlankMacDisplayGeometry: Equatable {
    let frameWidth, frameHeight: Int
    let source: PlankTopology.Rect
    init?(frameWidth: Int, frameHeight: Int, topology: PlankTopology?, outputIndex: Int) {
        guard frameWidth > 0, frameHeight > 0 else { return nil }
        self.frameWidth = frameWidth; self.frameHeight = frameHeight
        if let topology, topology.splitPresentation {
            guard topology.desktopWidth == frameWidth, topology.desktopHeight == frameHeight,
                  topology.orderedOutputs.indices.contains(outputIndex) else { return nil }
            source = topology.orderedOutputs[outputIndex].sourceRect
        } else {
            guard outputIndex == 0 else { return nil }
            source = .init(x: 0, y: 0, width: frameWidth, height: frameHeight)
        }
        guard source.fits(width: frameWidth, height: frameHeight) else { return nil }
    }
    var normalizedCrop: CGRect {
        CGRect(x: Double(source.x) / Double(frameWidth), y: Double(source.y) / Double(frameHeight),
               width: Double(source.width) / Double(frameWidth), height: Double(source.height) / Double(frameHeight))
    }
    func canvas(in bounds: CGRect) -> CGRect {
        PlankMacCoordinates.canvas(in: bounds, width: source.width, height: source.height)
    }
    func remote(_ point: CGPoint, in bounds: CGRect, dragging: Bool) -> (Int, Int)? {
        guard let (x, y) = PlankMacCoordinates.remote(point, canvas: canvas(in: bounds),
            width: source.width, height: source.height, dragging: dragging) else { return nil }
        return (x + source.x, y + source.y)
    }
    func localCursor(_ cursor: PlankRemoteCursor) -> CGPoint? {
        guard cursor.frameWidth == frameWidth, cursor.frameHeight == frameHeight,
              cursor.x >= source.x, cursor.x < source.x + source.width,
              cursor.y >= source.y, cursor.y < source.y + source.height else { return nil }
        return CGPoint(x: cursor.x - source.x, y: cursor.y - source.y)
    }
}

enum PlankMacSessionFocus {
    struct Window { let key, main: Bool }
    static func active(appActive: Bool, windows: [Window]) -> Bool {
        appActive && windows.contains { $0.key || $0.main }
    }
}
