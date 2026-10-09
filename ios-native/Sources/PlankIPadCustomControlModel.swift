import Foundation
import CoreGraphics

/// Anchors belong to the whole available surface, independently of pen margins.
/// Each key keeps its own point size when reordered, copied or moved.
struct PlankControlPlacement: Codable, Equatable, Sendable {
    static let minimumDimension = 44.0
    static let maximumWidth = 480.0
    static let maximumHeight = 240.0
    var x: Double, y: Double, width: Double, height: Double
    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
            && (0...1).contains(x) && (0...1).contains(y)
            && (Self.minimumDimension...Self.maximumWidth).contains(width)
            && (Self.minimumDimension...Self.maximumHeight).contains(height)
    }
    func frame(in bounds: CGRect) -> CGRect {
        guard isValid, bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let w = min(CGFloat(width),max(CGFloat(Self.minimumDimension),bounds.width))
        let h = min(CGFloat(height),max(CGFloat(Self.minimumDimension),bounds.height))
        func center(_ value: CGFloat, start: CGFloat, available: CGFloat, length: CGFloat) -> CGFloat {
            guard available >= length else { return start + available / 2 }
            return min(max(start + value * available,start + length / 2),start + available - length / 2)
        }
        return CGRect(x:center(CGFloat(x),start:bounds.minX,available:bounds.width,length:w) - w / 2,
                      y:center(CGFloat(y),start:bounds.minY,available:bounds.height,length:h) - h / 2,
                      width:w,height:h)
    }
    init(frame: CGRect, in bounds: CGRect) {
        func fraction(_ value: CGFloat, start: CGFloat, length: CGFloat) -> Double {
            guard value.isFinite, start.isFinite, length.isFinite, length > 0 else { return 0.5 }
            return min(max(Double((value - start) / length),0),1)
        }
        func dimension(_ value: CGFloat, maximum: Double) -> Double {
            value.isFinite ? min(max(Double(value),Self.minimumDimension),maximum) : Self.minimumDimension
        }
        self.init(x:fraction(frame.midX,start:bounds.minX,length:bounds.width),
                  y:fraction(frame.midY,start:bounds.minY,length:bounds.height),
                  width:dimension(frame.width,maximum:Self.maximumWidth),
                  height:dimension(frame.height,maximum:Self.maximumHeight))
    }
}

struct PlankCustomControl: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var label: String
    var binding: PlankControlBinding
    var behavior: PlankControlBehavior
    var portrait: PlankControlPlacement
    var landscape: PlankControlPlacement
    init(id: UUID = UUID(), label: String, binding: PlankControlBinding,
         behavior: PlankControlBehavior = .hold, portrait: PlankControlPlacement,
         landscape: PlankControlPlacement) {
        self.id = id; self.label = label; self.binding = binding; self.behavior = behavior
        self.portrait = portrait; self.landscape = landscape
    }
    var isValid: Bool {
        !label.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && label.count <= 40
            && !label.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && binding.isValid && portrait.isValid && landscape.isValid
    }
    func placement(landscape: Bool) -> PlankControlPlacement { landscape ? self.landscape : portrait }
    mutating func setPlacement(_ value: PlankControlPlacement, landscape: Bool) {
        if landscape { self.landscape = value } else { portrait = value }
    }
}

struct PlankControlLayout: Codable, Equatable, Identifiable, Sendable {
    static let maximumControls = 32
    var id: UUID
    var name: String
    var controls: [PlankCustomControl]
    init(id: UUID = UUID(), name: String, controls: [PlankCustomControl]) {
        self.id = id; self.name = name; self.controls = controls
    }
    var isValid: Bool {
        !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && name.count <= 48
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && controls.count <= Self.maximumControls && controls.allSatisfy(\.isValid)
            && Set(controls.map(\.id)).count == controls.count
    }
    static func defaults(shortcuts: [PlankPencilModifier] = PlankPencilModifier.allCases,
                         name: String = "Artist Controls") -> Self {
        var seen = Set<PlankPencilModifier>()
        let keys = (shortcuts + PlankPencilModifier.allCases).filter { seen.insert($0).inserted }
        var modifierIndex = 0
        let controls = keys.map { key in
            let wide = key == .space
            let column = Double(modifierIndex % 2), row = Double(modifierIndex / 2)
            if !wide { modifierIndex += 1 }
            let landscape = PlankControlPlacement(x:wide ? 0.15 : 0.06 + column * 0.10,
                y:wide ? 0.66 : 0.77 + row * 0.09,width:wide ? 200 : 76,height:52)
            let portrait = PlankControlPlacement(x:wide ? 0.25 : 0.10 + column * 0.18,
                y:wide ? 0.75 : 0.85 + row * 0.06,width:wide ? 200 : 76,height:52)
            return PlankCustomControl(label:key.title,binding:.init(code:key.rawValue),
                portrait:portrait,landscape:landscape)
        }
        return Self(name:name,controls:controls)
    }
    func copied(name: String? = nil) -> Self {
        var next = self
        next.id = UUID()
        next.name = name ?? String(self.name.prefix(43)) + " Copy"
        next.controls = controls.map { control in var value = control; value.id = UUID(); return value }
        return next
    }
}

/// One validated, bounded library shared by direct Desktop and Pencil sharing.
/// Loading old five-key settings imports their sanitized order once. It never
/// rewrites pad margins, appearance, identities or consent records.
struct PlankCustomControlLibrary: Codable, Equatable, Sendable {
    static let maximumLayouts = 16
    static let storageKey = "plank.ipad.custom-controls.v1"
    var version = 1
    var layouts: [PlankControlLayout]
    var selectedID: UUID
    init(layouts: [PlankControlLayout], selectedID: UUID? = nil) {
        let values = layouts.isEmpty ? [PlankControlLayout.defaults()] : layouts
        self.layouts = values; self.selectedID = selectedID ?? values[0].id
    }
    var isValid: Bool {
        version == 1 && !layouts.isEmpty && layouts.count <= Self.maximumLayouts
            && layouts.allSatisfy(\.isValid) && Set(layouts.map(\.id)).count == layouts.count
            && layouts.contains { $0.id == selectedID }
    }
    var selectedLayout: PlankControlLayout {
        layouts.first { $0.id == selectedID } ?? layouts.first ?? .defaults()
    }
    @discardableResult mutating func select(id: UUID) -> Bool {
        guard layouts.contains(where:{ $0.id == id }) else { return false }
        selectedID = id; return true
    }
    @discardableResult mutating func upsert(layout: PlankControlLayout) -> Bool {
        guard layout.isValid else { return false }
        if let index = layouts.firstIndex(where:{ $0.id == layout.id }) { layouts[index] = layout }
        else {
            guard layouts.count < Self.maximumLayouts else { return false }
            layouts.append(layout)
        }
        selectedID = layout.id
        return true
    }
    @discardableResult mutating func remove(id: UUID) -> Bool {
        guard layouts.count > 1, let index = layouts.firstIndex(where:{ $0.id == id }) else { return false }
        layouts.remove(at:index)
        if selectedID == id { selectedID = layouts[0].id }
        return true
    }
    @discardableResult mutating func duplicate(id: UUID) -> UUID? {
        guard let original = layouts.first(where:{ $0.id == id }) else { return nil }
        let copy = original.copied()
        return upsert(layout:copy) ? copy.id : nil
    }
    static func load(from defaults: UserDefaults = .standard) -> Self {
        if let data = defaults.data(forKey:storageKey), data.count <= 512 * 1024,
           let library = try? JSONDecoder().decode(Self.self,from:data), library.isValid { return library }
        let imported = PlankControlLayout.defaults(shortcuts:PlankIPadPencilPadSettings.load(from:defaults).shortcuts)
        let library = Self(layouts:[imported])
        library.save(to:defaults)
        return library
    }
    func save(to defaults: UserDefaults = .standard) {
        guard isValid, let data = try? JSONEncoder().encode(self), data.count <= 512 * 1024 else { return }
        defaults.set(data,forKey:Self.storageKey)
    }
}
