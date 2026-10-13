import SwiftUI

/// Local navigation only. Keeping these targets separate from the drawing
/// surface prevents a navigation gesture becoming a remote mouse press.
struct PlankIPadZoomMenu: View {
    @ObservedObject var zoom: PlankIPadZoomController
    var enabled: Bool
    var body: some View {
        Menu {
            Button { zoom.requestMode(.fit) } label: {
                HStack { Text("Fit"); if zoom.state.mode == .fit { Image(systemName:"checkmark") } }
            }
            Button { zoom.requestMode(.double) } label: {
                HStack { Text("2× View"); if zoom.state.mode == .double { Image(systemName:"checkmark") } }
            }.disabled(!enabled)
            Toggle("Hand",isOn:Binding(get:{ zoom.state.handEnabled },set:{ zoom.requestHand($0) }))
                .disabled(!enabled || zoom.state.mode == .fit)
            Button("Center View") { zoom.requestCenter(CGPoint(x:0.5,y:0.5)) }
                .disabled(!enabled || zoom.state.mode == .fit)
        } label: {
            Image(systemName:zoom.state.handEnabled ? "hand.draw" : "plus.magnifyingglass")
                .frame(width:44,height:44)
        }
        .accessibilityLabel("Desktop view")
        .accessibilityValue(zoom.state.mode == .fit ? "Fit" : (zoom.state.handEnabled ? "2× View, Hand" : "2× View"))
    }
}

struct PlankIPadPencilZoomMenu: View {
    @ObservedObject var zoom: PlankIPadZoomController
    @ObservedObject var relay: PlankIPadPencilRelay
    @ObservedObject var receiver: PlankIPadPencilImageReceiver
    var body: some View {
        PlankIPadZoomMenu(zoom:zoom,enabled:relay.canDraw && receiver.enabled)
    }
}

/// The outer footprint stays constant in Fit and 2×, preserving Artist hold
/// ownership and menu protection. The outline represents the full source;
/// the blue rectangle is the current crop, independent of window aspect.
struct PlankIPadZoomNavigator: View {
    @ObservedObject var zoom: PlankIPadZoomController
    let width: Int
    let height: Int
    var enabled: Bool
    var body: some View {
        GeometryReader { geometry in
            if let viewport = PlankIPadViewport(bounds:CGRect(origin:.zero,size:geometry.size),
                width:width,height:height) {
                let crop = zoom.state.visibleSourceCrop
                let selection = CGRect(x:viewport.rect.minX+crop.minX*viewport.rect.width,
                    y:viewport.rect.minY+crop.minY*viewport.rect.height,
                    width:crop.width*viewport.rect.width,height:crop.height*viewport.rect.height)
                ZStack(alignment:.topLeading) {
                    Rectangle().fill(.black.opacity(0.65))
                        .frame(width:viewport.rect.width,height:viewport.rect.height)
                        .position(x:viewport.rect.midX,y:viewport.rect.midY)
                    Rectangle().stroke(.secondary.opacity(0.8),lineWidth:1)
                        .frame(width:viewport.rect.width,height:viewport.rect.height)
                        .position(x:viewport.rect.midX,y:viewport.rect.midY)
                    Rectangle().fill(Color.accentColor.opacity(enabled ? 0.15 : 0.05))
                        .overlay { Rectangle().stroke(Color.accentColor.opacity(enabled ? 0.9 : 0.3),lineWidth:1.5) }
                        .frame(width:selection.width,height:selection.height)
                        .position(x:selection.midX,y:selection.midY)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:0).onChanged { value in
                    guard enabled,zoom.state.mode == .double,
                          let position = viewport.normalized(value.location,held:true) else { return }
                    zoom.requestCenter(CGPoint(x:position.x,y:position.y))
                })
            } else { Color.clear }
        }
        .padding(10)
        .frame(width:140,height:108)
        .background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:12))
        .overlay(alignment:.bottomTrailing) {
            Text(zoom.state.mode == .fit ? "Fit" : "2×").font(.caption2).foregroundStyle(.secondary)
                .padding(.trailing,8).padding(.bottom,2).allowsHitTesting(false)
        }
        .accessibilityElement(children:.ignore)
        .accessibilityLabel("Desktop navigator")
        .accessibilityValue(zoom.state.mode == .fit ? "Fit" : "2× View")
        .accessibilityHint("In 2× View, drag to choose the desktop area.")
        .accessibilityAdjustableAction { direction in
            guard enabled,zoom.state.mode == .double else { return }
            var center = zoom.state.center
            switch direction {
            case .increment: center.x += 0.125
            case .decrement: center.x -= 0.125
            @unknown default: return
            }
            zoom.requestCenter(center)
        }
    }
}

struct PlankIPadPencilZoomNavigator: View {
    @ObservedObject var zoom: PlankIPadZoomController
    @ObservedObject var relay: PlankIPadPencilRelay
    @ObservedObject var receiver: PlankIPadPencilImageReceiver
    var body: some View {
        PlankIPadZoomNavigator(zoom:zoom,width:relay.width,height:relay.height,
            enabled:relay.canDraw && receiver.enabled)
    }
}
