import UIKit

@MainActor enum PlankIPadKeyboardViewport {
    static func constrain(_ video: UIView, inside canvas: UIView) {
        // UIKit owns docked-keyboard geometry. Floating keyboards overlay the
        // desktop; they must not move or shrink its coordinate space.
        let guide = canvas.keyboardLayoutGuide
        guide.followsUndockedKeyboard = false
        guide.usesBottomSafeArea = false
        video.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            video.topAnchor.constraint(equalTo: canvas.topAnchor),
            video.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            video.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            video.bottomAnchor.constraint(equalTo: guide.topAnchor)
        ])
    }
}
