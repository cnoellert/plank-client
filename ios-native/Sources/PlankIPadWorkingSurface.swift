import SwiftUI
import UIKit

private struct PlankIPadControlChromeKey: EnvironmentKey {
    static let defaultValue: PlankControlChromeGeometry? = nil
}
extension EnvironmentValues {
    var plankControlChrome: PlankControlChromeGeometry? {
        get { self[PlankIPadControlChromeKey.self] }
        set { self[PlankIPadControlChromeKey.self] = newValue }
    }
}

/// Desktop and Pencil sharing use the same window-sized artist-control canvas.
/// Local chrome is a foreground layer; only the video/pad reserves its space.
/// This does not change either UIKit surface's remote-coordinate transform.
struct PlankIPadWorkingSurface<Content: View, Controls: View, Toolbar: View, Floating: View, Consent: View>: View {
    let barsVisible: Bool
    let consentVisible: Bool
    let measured: (CGSize) -> Void
    let chromeChanged: (PlankControlChromeGeometry) -> Void
    let content: Content
    let controls: Controls
    let toolbar: Toolbar
    let floating: Floating
    let consent: Consent
    @State private var insets = UIEdgeInsets.zero
    @State private var floatingFrame = CGRect.zero
    @State private var consentFrame = CGRect.zero
    init(barsVisible: Bool, consentVisible: Bool = false, measured: @escaping (CGSize) -> Void,
         chromeChanged: @escaping (PlankControlChromeGeometry) -> Void = { _ in },
         @ViewBuilder content: () -> Content, @ViewBuilder controls: () -> Controls,
         @ViewBuilder toolbar: () -> Toolbar, @ViewBuilder floating: () -> Floating,
         @ViewBuilder consent: () -> Consent) {
        self.barsVisible = barsVisible; self.consentVisible = consentVisible
        self.measured = measured; self.chromeChanged = chromeChanged
        self.content = content(); self.controls = controls(); self.toolbar = toolbar()
        self.floating = floating(); self.consent = consent()
    }
    var body: some View {
        GeometryReader { geometry in
            let chrome = chromeGeometry(size:geometry.size)
            ZStack {
                content
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
                    .padding(.top,barsVisible ? insets.top + 44 : 0)
                    .padding(.bottom,barsVisible ? insets.bottom : 0)
                controls.frame(width:geometry.size.width,height:geometry.size.height)
                    .environment(\.plankControlChrome,chrome)
                VStack(spacing:0) {
                    if barsVisible {
                        Color.clear.frame(height:insets.top).allowsHitTesting(false)
                        toolbar.frame(height:44).frame(maxWidth:.infinity)
                            .background(.regularMaterial)
                    }
                    Spacer(minLength:0).allowsHitTesting(false)
                }
                if !barsVisible {
                    floating
                        .onGeometryChange(for:CGRect.self) { $0.frame(in:.named("plank-control-window")) } action: { floatingFrame = $0 }
                        .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topTrailing)
                        .padding(.top,max(12,insets.top)).padding(.trailing,12)
                }
                consent
                    .onGeometryChange(for:CGRect.self) { $0.frame(in:.named("plank-control-window")) } action: { consentFrame = $0 }
                    .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
                    .padding(.top,barsVisible ? insets.top + 52 : max(12,insets.top))
            }
            .frame(width:geometry.size.width,height:geometry.size.height)
            .coordinateSpace(name:"plank-control-window")
            .background {
                PlankIPadWindowMetrics { _,value in if insets != value { insets = value } }
            }
            .onAppear { measured(geometry.size) }
            .onChange(of:geometry.size) { _,size in measured(size) }
            .onAppear { chromeChanged(chrome) }
            .onChange(of:chrome) { _,value in chromeChanged(value) }
            .onChange(of:consentVisible) { _,visible in if !visible { consentFrame = .zero } }
        }
        .ignoresSafeArea(.container)
        .ignoresSafeArea(.keyboard,edges:.bottom)
        .background(Color.black.ignoresSafeArea())
    }
    private func chromeGeometry(size: CGSize) -> PlankControlChromeGeometry {
        let bounds = CGRect(origin:.zero,size:size)
        let top = barsVisible ? insets.top + 44 : insets.top
        let usable = CGRect(x:insets.left,y:top,width:max(0,size.width - insets.left - insets.right),
                            height:max(0,size.height - top - insets.bottom))
        // Wait for the actual hidden-toolbar footprint, rather than guessing
        // its width or placing keys under local navigation for one frame.
        let ready = barsVisible || PlankControlChromeGeometry.valid(floatingFrame)
        return PlankControlChromeGeometry(bounds:bounds,usableBounds:ready ? usable : .zero,
            reservedRects:(barsVisible ? [] : [floatingFrame]) + (consentVisible ? [consentFrame] : []))
    }
}

/// A public UIKit window measure also gives the idle editor the same reference
/// as a working surface. It never derives dimensions from a toolbar or sheet.
struct PlankIPadWindowMetrics: UIViewRepresentable {
    let changed: (CGSize,UIEdgeInsets) -> Void
    func makeUIView(context: Context) -> PlankIPadWindowMetricsView {
        let view = PlankIPadWindowMetricsView(); view.changed = changed; return view
    }
    func updateUIView(_ view: PlankIPadWindowMetricsView,context: Context) { view.changed = changed; view.report() }
}
final class PlankIPadWindowMetricsView: UIView {
    var changed: (CGSize,UIEdgeInsets) -> Void = { _,_ in }
    private var previousSize = CGSize.zero
    private var previousInsets = UIEdgeInsets.zero
    override func didMoveToWindow() { super.didMoveToWindow(); report() }
    override func layoutSubviews() { super.layoutSubviews(); report() }
    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); report() }
    func report() {
        guard let window else { return }
        let size = window.bounds.size, insets = window.safeAreaInsets
        guard size != previousSize || insets != previousInsets else { return }
        previousSize = size; previousInsets = insets
        // Defer the observable SwiftUI update out of UIKit's layout pass.
        DispatchQueue.main.async { [weak self] in
            guard let self,self.window != nil else { return }
            self.changed(size,insets)
        }
    }
}
