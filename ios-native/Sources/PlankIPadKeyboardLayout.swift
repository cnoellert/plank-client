import UIKit

/// One UIKit coordinate space owns keyboard avoidance and preview placement.
/// SwiftUI's navigation root must ignore keyboard safe-area resizing while the
/// desktop is active; applying both systems subtracts the keyboard twice.
@MainActor final class PlankIPadKeyboardLayout: NSObject {
    private weak var owner: UIView?
    private weak var video: UIView?
    private let preview = UIControl()
    private let text = UILabel()
    private var height: NSLayoutConstraint!
    private var presented = false
    private var screenKeyboardFrame: CGRect?
    private weak var keyboardScreen: UIScreen?
    private var dockedConstraints: [NSLayoutConstraint] = []
    private var dockedTop: NSLayoutConstraint!
    private var dockedWidth: NSLayoutConstraint!
    private var dockedCenter: NSLayoutConstraint!
    private var usingDockedNotification = false
    var previewFrame: CGRect { preview.frame }
    var keyboardFrame: CGRect { owner?.keyboardLayoutGuide.layoutFrame ?? .zero }
    private var previewHeight: CGFloat { max(44, UIFont.preferredFont(forTextStyle: .body).lineHeight + 16) }

    init(owner: UIView, video: UIView) {
        self.owner = owner; self.video = video
        super.init()
        let guide = owner.keyboardLayoutGuide
        guide.followsUndockedKeyboard = true
        guide.usesBottomSafeArea = false

        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.backgroundColor = .secondarySystemBackground
        preview.isHidden = true
        text.font = .preferredFont(forTextStyle: .body)
        text.adjustsFontForContentSizeCategory = true
        text.numberOfLines = 1
        text.lineBreakMode = .byTruncatingHead
        text.accessibilityLabel = "Typing preview"
        text.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(text)
        owner.addSubview(preview)
        height = preview.heightAnchor.constraint(equalToConstant: previewHeight)
        height.priority = UILayoutPriority(999)
        let width = preview.widthAnchor.constraint(equalTo: guide.widthAnchor)
        let center = preview.centerXAnchor.constraint(equalTo: guide.centerXAnchor)
        let above = preview.bottomAnchor.constraint(equalTo: guide.topAnchor)
        let below = preview.topAnchor.constraint(equalTo: guide.bottomAnchor)
        for constraint in [width, center, above, below] { constraint.priority = .defaultHigh }
        let minimumWidth = preview.widthAnchor.constraint(greaterThanOrEqualToConstant: 160)
        minimumWidth.priority = UILayoutPriority(740)
        NSLayoutConstraint.activate([
            height, width, center, minimumWidth,
            preview.leadingAnchor.constraint(greaterThanOrEqualTo: owner.safeAreaLayoutGuide.leadingAnchor),
            preview.trailingAnchor.constraint(lessThanOrEqualTo: owner.safeAreaLayoutGuide.trailingAnchor),
            preview.topAnchor.constraint(greaterThanOrEqualTo: owner.safeAreaLayoutGuide.topAnchor),
            preview.bottomAnchor.constraint(lessThanOrEqualTo: owner.bottomAnchor),
            text.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 16),
            text.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -16),
            text.topAnchor.constraint(equalTo: preview.topAnchor, constant: 8),
            text.bottomAnchor.constraint(equalTo: preview.bottomAnchor, constant: -8)
        ])
        guide.setConstraints([above], activeWhenAwayFrom: .top)
        guide.setConstraints([below], activeWhenNearEdge: .top)
        // A dock/expand transition with hardware attached can leave the guide
        // detached from the visible keyboard. The public frame notification is
        // authoritative for docked geometry; floating movement keeps the guide.
        dockedTop = preview.topAnchor.constraint(equalTo: owner.topAnchor)
        dockedWidth = preview.widthAnchor.constraint(equalToConstant: 0)
        dockedCenter = preview.centerXAnchor.constraint(equalTo: owner.leadingAnchor)
        dockedConstraints = [dockedTop, dockedWidth, dockedCenter]
        for constraint in dockedConstraints { constraint.priority = UILayoutPriority(900) }
        for name in [UIResponder.keyboardWillChangeFrameNotification,
                     UIResponder.keyboardDidChangeFrameNotification,
                     UIResponder.keyboardDidShowNotification,
                     UIResponder.keyboardDidHideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: name, object: nil)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func keyboardChanged(_ notification: Notification) {
        guard let owner, let window = owner.window else { return }
        let screen = (notification.object as? UIScreen) ?? window.screen
        guard screen === window.screen else { return }
        if notification.name == UIResponder.keyboardDidHideNotification {
            screenKeyboardFrame = nil
        } else {
            screenKeyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        }
        keyboardScreen = screen
        owner.setNeedsLayout()
    }

    private func notifiedDockedFrame(in owner: UIView) -> CGRect? {
        guard let screenKeyboardFrame, let keyboardScreen,
              owner.window?.screen === keyboardScreen else { return nil }
        let frame = owner.convert(screenKeyboardFrame, from: keyboardScreen.coordinateSpace)
        guard frame.minX <= owner.bounds.minX + 1, frame.maxX >= owner.bounds.maxX - 1,
              frame.maxY >= owner.bounds.maxY - 1, frame.minY < owner.bounds.maxY - 1 else { return nil }
        let clipped = owner.bounds.intersection(frame)
        return clipped.isNull || clipped.height <= 1 ? nil : clipped
    }

    func updateText(_ value: String) {
        text.text = value.isEmpty ? "Type into the remote desktop…" : value.replacingOccurrences(of: "\n", with: " ↵ ").replacingOccurrences(of: "\t", with: " ⇥ ")
        text.textColor = value.isEmpty ? .secondaryLabel : .label
    }

    func setPresented(_ value: Bool) {
        presented = value
        preview.isHidden = !value
        text.font = .preferredFont(forTextStyle: .body)
        height.constant = previewHeight
        owner?.setNeedsLayout()
    }

    @discardableResult func layoutViewport() -> CGRect {
        guard let owner else { return .zero }
        // Only a full-width keyboard touching the bottom occludes the viewport.
        // The same public guide follows floating keyboards for preview placement;
        // their narrow frames must not shrink the desktop.
        let notifiedDocked = presented ? notifiedDockedFrame(in: owner) : nil
        let useNotification = notifiedDocked != nil
        if let notifiedDocked {
            dockedTop.constant = max(owner.safeAreaLayoutGuide.layoutFrame.minY, notifiedDocked.minY - previewHeight)
            dockedWidth.constant = notifiedDocked.width
            dockedCenter.constant = notifiedDocked.midX
        }
        if useNotification != usingDockedNotification {
            usingDockedNotification = useNotification
            if useNotification { NSLayoutConstraint.activate(dockedConstraints) }
            else { NSLayoutConstraint.deactivate(dockedConstraints) }
            // Geometry only, never text or pen samples.
            NSLog("PLANK iPad keyboard dockedFrame=%d", useNotification)
        }
        let docked = notifiedDocked ?? owner.keyboardLayoutGuide.layoutFrame
        let hasDockedKeyboard = docked.height > 1 && docked.minY < owner.bounds.maxY - 1
            && docked.width >= owner.bounds.width - 1 && docked.maxY >= owner.bounds.maxY - 1
        let reserve = presented && hasDockedKeyboard ? previewHeight : 0
        let bottom = hasDockedKeyboard ? docked.minY - reserve : owner.bounds.maxY
        let rect = CGRect(x: owner.bounds.minX, y: owner.bounds.minY,
            width: owner.bounds.width, height: max(0, min(owner.bounds.maxY, bottom) - owner.bounds.minY))
        video?.frame = rect
        return rect
    }

    func contains(_ point: CGPoint) -> Bool { presented && preview.frame.contains(point) }
}
