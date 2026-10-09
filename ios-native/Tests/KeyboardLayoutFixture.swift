// Isolated simulator app: compile with Sources/PlankIPadKeyboardLayout.swift.
// Uses the real system keyboard and production layout helper, without a Host.
// Geometry only is saved; no typed text or network connection is recorded.
import UIKit
import SwiftUI

@main struct FixtureApp: App {
    var body: some Scene { WindowGroup {
        NavigationStack { VStack(spacing:0) { GeometryReader { geometry in FixtureCanvas().frame(width:geometry.size.width,height:geometry.size.height) } }.ignoresSafeArea(.keyboard,edges:.bottom).navigationTitle("Keyboard geometry check").navigationBarTitleDisplayMode(.inline) }
            .ignoresSafeArea(.keyboard, edges: .bottom)
    } }
}
struct FixtureCanvas: UIViewRepresentable {
    func makeUIView(context: Context) -> FixtureView { FixtureView() }
    func updateUIView(_ uiView: FixtureView, context: Context) {}
}
@MainActor final class FixtureView: UIView {
    let video=UIView(); let entry=UITextField(frame:CGRect(x:0,y:0,width:1,height:1))
    lazy var keyboard=PlankIPadKeyboardLayout(owner:self,video:video)
    var actualKeyboard:CGRect = .zero
    var snapshots:[[String:Any]]=[]
    var started=false
    override init(frame:CGRect) {
        super.init(frame:frame)
        backgroundColor = .systemBackground
        video.backgroundColor = .black
        addSubview(video); addSubview(entry)
        entry.autocorrectionType = .no
        entry.inputAssistantItem.leadingBarButtonGroups=[]
        entry.inputAssistantItem.trailingBarButtonGroups=[]
        keyboard.updateText("Typing preview — geometry verification")
        NotificationCenter.default.addObserver(self,selector:#selector(keyboardChanged(_:)),name:UIResponder.keyboardDidChangeFrameNotification,object:nil)
        let label=UILabel(frame:CGRect(x:30,y:30,width:500,height:40)); label.text="Desktop viewport"; label.textColor = .white; video.addSubview(label)
    }
    required init?(coder:NSCoder) { fatalError() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !started else{return}; started=true
        DispatchQueue.main.asyncAfter(deadline:.now()+1){ self.keyboard.setPresented(true); self.entry.becomeFirstResponder() }
        for (time,name) in [(3.0,"docked"),(7.0,"hidden"),(11.0,"reopened"),(15.0,"stable"),(18.0,"synthetic-frame-guide-mismatch"),(23.0,"restored-system-frame")] {
            DispatchQueue.main.asyncAfter(deadline:.now()+time){ self.record(name) }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+5){ self.entry.resignFirstResponder(); self.keyboard.setPresented(false) }
        DispatchQueue.main.asyncAfter(deadline:.now()+9){ self.keyboard.setPresented(true); self.entry.becomeFirstResponder() }
        // Fault injection: the notification reports a different docked frame
        // while the real system keyboard/guide stays put. This is not gesture
        // acceptance; it verifies the authoritative-frame fallback explicitly.
        DispatchQueue.main.asyncAfter(deadline:.now()+16){
            guard let window=self.window else{return}
            let original=window.screen.coordinateSpace.convert(self.actualKeyboard,from:self)
            var changed=original; changed.origin.y += 40; changed.size.height -= 40
            NotificationCenter.default.post(name:UIResponder.keyboardDidChangeFrameNotification,object:window.screen,userInfo:[UIResponder.keyboardFrameEndUserInfoKey:changed])
            DispatchQueue.main.asyncAfter(deadline:.now()+4){
                NotificationCenter.default.post(name:UIResponder.keyboardDidChangeFrameNotification,object:window.screen,userInfo:[UIResponder.keyboardFrameEndUserInfoKey:original])
            }
        }
    }
    @objc func keyboardChanged(_ notification:Notification) {
        guard let screenRect=notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,let window else{return}
        actualKeyboard=convert(window.convert(screenRect,from:window.screen.coordinateSpace),from:window)
        setNeedsLayout()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.5){ self.record("keyboard-frame") }
    }
    override func layoutSubviews(){ super.layoutSubviews(); keyboard.layoutViewport() }
    func rect(_ v:CGRect)->[String:Double]{["x":Double(v.minX),"y":Double(v.minY),"width":Double(v.width),"height":Double(v.height)]}
    func record(_ name:String){
        layoutIfNeeded()
        snapshots.append(["name":name,"owner":rect(bounds),"ownerInWindow":rect(convert(bounds,to:window)),"video":rect(video.frame),"preview":rect(keyboard.previewFrame),"guide":rect(keyboard.keyboardFrame),"actualKeyboard":rect(actualKeyboard)])
        let url=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("geometry.json")
        try? JSONSerialization.data(withJSONObject:snapshots,options:[.prettyPrinted,.sortedKeys]).write(to:url)
    }
}
