import SwiftUI
import UIKit

struct PlankIPadModifierPad: UIViewRepresentable {
    @ObservedObject var relay: PlankIPadPencilRelay
    let onClose: () -> Void
    let onMove: (CGPoint) -> Void
    func makeUIView(context: Context) -> PlankIPadModifierPadView {
        PlankIPadModifierPadView(relay:relay,onClose:onClose,onMove:onMove)
    }
    func updateUIView(_ view: PlankIPadModifierPadView,context: Context) { view.refresh() }
    static func dismantleUIView(_ view: PlankIPadModifierPadView,coordinator: ()) { view.release() }
}

@MainActor final class PlankIPadModifierPadView: UIView {
    private let relay: PlankIPadPencilRelay
    private var keys: [PlankModifierHoldButton] = []
    private let onMove: (CGPoint) -> Void
    init(relay: PlankIPadPencilRelay,onClose: @escaping () -> Void,onMove: @escaping (CGPoint) -> Void) {
        self.relay = relay; self.onMove = onMove; super.init(frame:.zero)
        backgroundColor = UIColor(white:0.10,alpha:0.98)
        layer.cornerRadius = 16; layer.borderWidth = 1; layer.borderColor = UIColor(white:0.3,alpha:1).cgColor
        isMultipleTouchEnabled = true
        let handle = UILabel(); handle.text = "Hold while drawing"; handle.textColor = .secondaryLabel
        handle.font = .preferredFont(forTextStyle:.footnote); handle.adjustsFontForContentSizeCategory = true
        handle.isUserInteractionEnabled = true
        let pan = UIPanGestureRecognizer(target:self,action:#selector(moved(_:)))
        pan.allowedTouchTypes = [NSNumber(value:UITouch.TouchType.direct.rawValue)]
        handle.addGestureRecognizer(pan)
        let close = UIButton(type:.system)
        close.setImage(UIImage(systemName:"xmark"),for:.normal); close.accessibilityLabel = "Hide shortcut pad"
        close.addAction(UIAction { _ in onClose() },for:.touchUpInside)
        close.widthAnchor.constraint(equalToConstant:44).isActive = true
        let header = UIStackView(arrangedSubviews:[handle,close]); header.axis = .horizontal
        header.heightAnchor.constraint(equalToConstant:36).isActive = true
        let row = UIStackView(); row.axis = .horizontal; row.distribution = .fillEqually; row.spacing = 6
        for key: PlankPencilModifier in [.shift,.control,.option,.command] {
            let button = PlankModifierHoldButton(key:key,relay:relay); keys.append(button); row.addArrangedSubview(button)
        }
        let space = PlankModifierHoldButton(key:.space,relay:relay); keys.append(space)
        let stack = UIStackView(arrangedSubviews:[header,row,space]); stack.axis = .vertical; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo:leadingAnchor,constant:10),
            stack.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-10),
            stack.topAnchor.constraint(equalTo:topAnchor,constant:4),
            stack.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-10),
            row.heightAnchor.constraint(equalTo:space.heightAnchor)
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    @objc private func moved(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed else { return }
        // Move in window coordinates so moving this palette cannot feed back
        // into the gesture's accumulated translation. Pencil never moves it.
        let delta = gesture.translation(in:window); gesture.setTranslation(.zero,in:window); onMove(delta)
    }
    func refresh() { keys.forEach { $0.refresh() } }
    func release() { relay.releaseModifiers() }
}

@MainActor private final class PlankModifierHoldButton: UIControl {
    private let key: PlankPencilModifier
    private let relay: PlankIPadPencilRelay
    private let label = UILabel()
    init(key: PlankPencilModifier,relay: PlankIPadPencilRelay) {
        self.key = key; self.relay = relay; super.init(frame:.zero)
        isExclusiveTouch = false; layer.cornerRadius = 9
        label.text = key.title; label.textAlignment = .center
        label.font = .preferredFont(forTextStyle:.body); label.adjustsFontForContentSizeCategory = true
        label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.75
        label.translatesAutoresizingMaskIntoConstraints = false; addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo:leadingAnchor,constant:3),
            label.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-3),
            label.centerYAnchor.constraint(equalTo:centerYAnchor)
        ])
        isAccessibilityElement = true; accessibilityLabel = key.accessibilityTitle
        accessibilityHint = "Double-tap to hold; double-tap again to release."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func beginTracking(_ touch: UITouch,with event: UIEvent?) -> Bool {
        guard touch.type != .pencil, relay.canDraw else { return false }
        relay.setModifier(key,pressed:true); refresh(); return true
    }
    override func continueTracking(_ touch: UITouch,with event: UIEvent?) -> Bool {
        guard bounds.contains(touch.location(in:self)) else { release(); return false }
        return true
    }
    override func endTracking(_ touch: UITouch?,with event: UIEvent?) { release() }
    override func cancelTracking(with event: UIEvent?) { release() }
    private func release() { relay.setModifier(key,pressed:false); refresh() }
    override func accessibilityActivate() -> Bool {
        guard relay.canDraw else { return false }
        relay.setModifier(key,pressed:!relay.heldModifiers.contains(key)); refresh(); return true
    }
    func refresh() {
        let held = relay.heldModifiers.contains(key)
        isEnabled = relay.canDraw
        backgroundColor = held ? .systemBlue : UIColor(white:0.19,alpha:1)
        label.textColor = held ? .white : .label
        alpha = isEnabled ? 1 : 0.45
        accessibilityTraits = held ? [.button,.selected] : .button
        if !isEnabled { accessibilityTraits.insert(.notEnabled) }
        accessibilityValue = held ? "Held" : "Released"
    }
}
