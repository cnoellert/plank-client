import SwiftUI
import Network
import UIKit

@MainActor final class PlankIPadPencilRelay: ObservableObject {
    @Published private(set) var sharing = false
    @Published private(set) var status = "Sharing is off"
    @Published private(set) var verification: String?
    @Published private(set) var width = 1920, height = 1200
    @Published private(set) var active = false
    private var listener: NWListener?
    private var peer: PlankPencilRelayPeer?
    private var generation = UUID(), peerID = UUID()
    weak var pad: PlankIPadPencilPadView?
    func start() {
        guard !sharing else { return }
        do {
            let key = try PlankPencilRelayKeys.privateKey()
            let publicKey = try PlankPencilRelayKeys.publicKey(key)
            let listener = try NWListener(using:.tcp,on:.any)
            var txt = NWTXTRecord(); txt["version"] = "1"; txt["capability"] = "normalized-pen"
            txt["key"] = PlankPencilRelayKeys.hex(publicKey)
            listener.service = .init(name:UIDevice.current.name + " Pencil",type:"_plank-pencil._tcp",domain:"local.",txtRecord:txt)
            listener.newConnectionLimit = 1
            self.listener = listener; sharing = true; status = "Starting Pencil sharing…"
            generation = UUID(); let current = generation
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection,key:key,generation:current) }
            }
            listener.stateUpdateHandler = { [weak self] state in Task { @MainActor in
                guard let self, self.generation == current else { return }
                if case .ready = state { self.status = "On the headset, choose this iPad in PLANK Settings → Apple Pencil." }
                if case .failed = state { self.stop(); self.status = "Pencil sharing could not start. Check local network access." }
            } }
            listener.start(queue:.main)
        } catch { stop(); status = "Pencil sharing is unavailable. Check local network access and identity storage." }
    }
    private func accept(_ connection: NWConnection,key: Data,generation current: UUID) {
        guard sharing, generation == current, peer == nil else { connection.cancel(); return }
        do {
            peerID = UUID(); let id = peerID
            let next = try PlankPencilRelayPeer(connection:connection,privateKey:key) { [weak self] event in
                Task { @MainActor in
                    guard let self, self.generation == current, self.peerID == id else { return }
                    switch event {
                    case let .verification(code):
                        self.verification = code; self.status = "Compare this code with PLANK on your headset before approving."
                    case .ready: self.verification = nil; self.status = "Headset approved. Waiting for an active desktop."
                    case .messagesAvailable: self.drain()
                    case let .ended(reason):
                        self.pad?.retire(); self.peer = nil; self.active = false
                        self.listener?.newConnectionLimit = 1
                        self.verification = nil; self.status = reason + ". Select this iPad again on the headset."
                    }
                }
            }
            peer = next; next.start()
        } catch { connection.cancel(); listener?.newConnectionLimit = 1; status = "Could not verify headset identity." }
    }
    private func drain() {
        guard let peer else { return }
        do {
            while let message = try peer.incoming.take() {
                guard case let .configuration(w,h,next) = message else { throw PlankPencilWireError.invalid }
                // Retire the old contact before the pad mapping/admission changes.
                pad?.retire(); width = Int(w); height = Int(h); active = next
                status = next ? "Connected. Draw in the outlined area." : "Connected. Bring the PLANK desktop into focus on your headset."
                pad?.setNeedsLayout()
            }
        } catch { peer.close(); status = "Pencil connection ended." }
    }
    func approve() { guard verification != nil else { return }; verification = nil; peer?.approve(); status = "Verifying headset…" }
    func send(_ packet: PlankNormalizedPen) {
        guard let peer else { return }
        if !peer.offer(.pen(packet)) { peer.close(); active = false }
    }
    func click(x: Float,y: Float) {
        guard active, let peer else { return }
        if !peer.offer(.rightClick(x:x,y:y)) { peer.close(); active = false }
    }
    func stop() {
        pad?.retire(); generation = UUID(); peerID = UUID(); active = false; sharing = false
        peer?.close(); peer = nil; verification = nil
        listener?.newConnectionHandler = nil; listener?.stateUpdateHandler = nil; listener?.cancel(); listener = nil
        status = "Sharing is off"
    }
}

struct PlankIPadPencilRelayView: View {
    @ObservedObject var relay: PlankIPadPencilRelay
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing:16) {
                Text(relay.status).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                if let code = relay.verification {
                    Text(code).font(.title.monospaced().bold())
                    HStack {
                        Button("Reject",role:.cancel) { relay.stop() }
                        Button("Codes Match — Approve Headset") { relay.approve() }.buttonStyle(.borderedProminent)
                    }
                }
                PlankIPadPencilPad(relay:relay).background(.black).clipShape(RoundedRectangle(cornerRadius:16)).padding()
                Text("Keep this pad open while drawing. Squeeze the Pencil for a right-click after lifting the tip.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
            .navigationTitle("Share Apple Pencil")
            .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Stop Sharing") { relay.stop(); dismiss() } } }
        }
        .interactiveDismissDisabled()
        .onAppear { relay.start() }
        .onDisappear { relay.stop() }
        .onChange(of:scenePhase) { _,phase in if phase != .active { relay.stop(); dismiss() } }
    }
}
struct PlankIPadPencilPad: UIViewRepresentable {
    let relay: PlankIPadPencilRelay
    func makeUIView(context: Context) -> PlankIPadPencilPadView { PlankIPadPencilPadView(relay:relay) }
    func updateUIView(_ view: PlankIPadPencilPadView,context: Context) { view.setNeedsLayout() }
    static func dismantleUIView(_ view: PlankIPadPencilPadView,coordinator: ()) { view.retire() }
}
@MainActor final class PlankIPadPencilPadView: UIView, UIPencilInteractionDelegate {
    private let relay: PlankIPadPencilRelay
    private var policy = PlankIPadPencilPolicy(), squeeze = PlankIPadSqueezePolicy()
    private var touch: UITouch?
    private var previous = CGRect.zero
    private let outline = CAShapeLayer(), cursor = CAShapeLayer()
    private var viewport: PlankIPadViewport? { .init(bounds:bounds.insetBy(dx:16,dy:16),width:relay.width,height:relay.height) }
    init(relay: PlankIPadPencilRelay) {
        self.relay = relay; super.init(frame:.zero); relay.pad = self
        isMultipleTouchEnabled = false; backgroundColor = .black
        outline.fillColor = UIColor.secondarySystemBackground.cgColor
        outline.strokeColor = UIColor.systemCyan.cgColor; outline.lineWidth = 2; layer.addSublayer(outline)
        cursor.fillColor = UIColor.systemCyan.cgColor; layer.addSublayer(cursor)
        let hover = UIHoverGestureRecognizer(target:self,action:#selector(hovered(_:)))
        hover.allowedTouchTypes = [NSNumber(value:UITouch.TouchType.pencil.rawValue)]
        hover.cancelsTouchesInView = false; addGestureRecognizer(hover)
        let pencil = UIPencilInteraction(); pencil.delegate = self; addInteraction(pencil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let rect = viewport?.rect ?? .zero
        if rect != previous { retire(); previous = rect }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        outline.path = UIBezierPath(roundedRect:rect,cornerRadius:8).cgPath
        outline.opacity = relay.active ? 1 : 0.4; CATransaction.commit()
    }
    func retire() { for p in policy.retire() { relay.send(p) }; touch = nil; cursor.path = nil }
    private func send(_ sample: UITouch,phase: PlankNormalizedPen.Phase) -> Bool {
        guard relay.active, let viewport, let p = policy.sample(phase,point:sample.location(in:self),viewport:viewport,
            timestamp:sample.timestamp,force:Double(sample.force),maximumForce:Double(sample.maximumPossibleForce),
            altitude:Double(sample.altitudeAngle),azimuth:Double(sample.azimuthAngle(in:self))) else { return false }
        relay.send(p); mark(sample.location(in:self)); return true
    }
    private func mark(_ point: CGPoint) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cursor.path = UIBezierPath(ovalIn:CGRect(x:point.x-3,y:point.y-3,width:6,height:6)).cgPath; CATransaction.commit()
    }
    @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
        guard touch == nil, relay.active, let viewport else { return }
        guard gesture.state == .began || gesture.state == .changed,
              let p = policy.sample(.hover,point:gesture.location(in:self),viewport:viewport,
                timestamp:ProcessInfo.processInfo.systemUptime,force:0,maximumForce:0,
                altitude:Double(gesture.altitudeAngle),azimuth:Double(gesture.azimuthAngle(in:self)),distance:Double(gesture.zOffset)) else { retire(); return }
        relay.send(p); mark(gesture.location(in:self))
    }
    override func touchesBegan(_ touches: Set<UITouch>,with event: UIEvent?) {
        guard touch == nil, let next = touches.first(where: { $0.type == .pencil }), send(next,phase:.down) else { return }; touch = next
    }
    override func touchesMoved(_ touches: Set<UITouch>,with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }
        for s in (event?.coalescedTouches(for:touch) ?? [touch]).sorted(by: { $0.timestamp < $1.timestamp }) { _ = send(s,phase:.move) }
        _ = send(touch,phase:.move)
    }
    override func touchesEnded(_ touches: Set<UITouch>,with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }; _ = send(touch,phase:.up); retire()
    }
    override func touchesCancelled(_ touches: Set<UITouch>,with event: UIEvent?) { retire() }
    func pencilInteraction(_ interaction: UIPencilInteraction,didReceiveSqueeze value: UIPencilInteraction.Squeeze) {
        guard let point = value.hoverPose?.location, let position = viewport?.normalized(point),
              squeeze.click(ended:value.phase == .ended,timestamp:value.timestamp,enabled:relay.active,
                touching:policy.touching,heldButtons:false,hasPosition:true) else { return }
        relay.click(x:Float(position.x),y:Float(position.y))
    }
}
