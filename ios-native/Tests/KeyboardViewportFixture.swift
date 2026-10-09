// Isolated simulator app: compile with PlankIPadKeyboardViewport.swift.
// Exercises the production constraint with the real keyboard; no Host needed.
import UIKit
import SwiftUI

@main struct KeyboardViewportFixture: App {
    var body: some Scene { WindowGroup {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    FixtureCanvas().frame(width: geometry.size.width, height: geometry.size.height)
                }
            }.ignoresSafeArea(.keyboard, edges: .bottom)
                .navigationTitle("Keyboard viewport check").navigationBarTitleDisplayMode(.inline)
        }.ignoresSafeArea(.keyboard, edges: .bottom)
    } }
}
private struct FixtureCanvas: UIViewRepresentable {
    func makeUIView(context: Context) -> FixtureView { FixtureView() }
    func updateUIView(_ uiView: FixtureView, context: Context) {}
}
@MainActor private final class FixtureView: UIView {
    let video = UIView()
    let entry = UITextField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    var keyboardFrame = CGRect.zero
    var snapshots: [[String: Any]] = []
    var started = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        video.backgroundColor = .black
        addSubview(video); addSubview(entry)
        PlankIPadKeyboardViewport.constrain(video, inside: self)
        entry.autocorrectionType = .no
        NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)),
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !started else { return }
        started = true
        for (delay, action) in [(1.0, true), (5.0, false), (9.0, true)] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if action { self.entry.becomeFirstResponder() }
                else { self.entry.resignFirstResponder() }
            }
        }
        for (delay, name) in [(3.0, "docked"), (7.0, "hidden"), (11.0, "reopened")] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.record(name) }
        }
    }
    @objc func changed(_ notification: Notification) {
        guard let rect = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let window else { return }
        keyboardFrame = convert(window.convert(rect, from: window.screen.coordinateSpace), from: window)
    }
    func record(_ name: String) {
        layoutIfNeeded()
        snapshots.append(["name": name, "ownerHeight": bounds.height,
            "videoHeight": video.frame.height, "videoBottom": video.frame.maxY,
            "guideTop": keyboardLayoutGuide.layoutFrame.minY,
            "keyboardTop": keyboardFrame.minY, "keyboardWidth": keyboardFrame.width])
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("geometry.json")
        try? JSONSerialization.data(withJSONObject: snapshots, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
}
