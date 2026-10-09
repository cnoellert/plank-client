import SwiftUI
import UIKit

enum PlankIPadControlSurface: Hashable { case desktop, pencilSharing }

/// One saved library is shared by the direct desktop and Pencil sharing.
/// Editing stays local until Done; the overlay receives transport closures.
@MainActor final class PlankIPadCustomControlsStore: ObservableObject {
    @Published private(set) var library: PlankCustomControlLibrary
    /// Surface geometry is transient. Reporting it must not publish a change
    /// during UIKit layout or alter the saved arrangement.
    private var surfaceSizes: [PlankIPadControlSurface: [Bool: CGSize]] = [:]
    private var latestSurfaceSizes: [PlankIPadControlSurface: CGSize] = [:]
    func latestSurfaceSize(for surface: PlankIPadControlSurface) -> CGSize? { latestSurfaceSizes[surface] }
    func reportSurface(size: CGSize, surface: PlankIPadControlSurface = .desktop) {
        guard Self.usable(size) else { return }
        surfaceSizes[surface,default:[:]][size.width >= size.height] = size
        latestSurfaceSizes[surface] = size
    }
    func referenceSize(landscape: Bool, fallback: CGSize, surface: PlankIPadControlSurface = .desktop) -> CGSize {
        if Self.usable(fallback), (fallback.width >= fallback.height) == landscape { return fallback }
        if let exact = surfaceSizes[surface]?[landscape] { return exact }
        let available = Self.usable(fallback) ? fallback : (latestSurfaceSizes[surface] ?? CGSize(width:1180,height:820))
        return (available.width >= available.height) == landscape
            ? available : CGSize(width:available.height,height:available.width)
    }
    private static func usable(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 1 && size.height > 1
    }
    init(library: PlankCustomControlLibrary = .load()) { self.library = library }
    var selectedLayout: PlankControlLayout { library.selectedLayout }
    func select(id: UUID) {
        var next = library
        guard next.select(id:id) else { return }
        replace(next)
    }
    func replace(_ value: PlankCustomControlLibrary) {
        guard value.isValid else { return }
        value.save(); library = value
    }
}

struct PlankIPadCustomControlsOverlay: UIViewRepresentable {
    @ObservedObject var store: PlankIPadCustomControlsStore
    let enabled: Bool
    let begin: (UUID, PlankControlBinding) -> Bool
    let end: (UUID) -> Void
    let tap: (PlankControlBinding) -> Bool
    let release: () -> Void
    var supports: (PlankControlBinding) -> Bool = { _ in true }
    var inputEpoch: UInt64 = 0
    var pencilSurface: () -> UIView? = { nil }
    var pencilHover: (UIHoverGestureRecognizer) -> Void = { _ in }
    var pencilSqueeze: (UIPencilInteraction.Squeeze, UIView) -> Void = { _,_ in }

    func makeUIView(context: Context) -> PlankIPadCustomControlsOverlayView {
        let view = PlankIPadCustomControlsOverlayView()
        configure(view)
        return view
    }
    func updateUIView(_ view: PlankIPadCustomControlsOverlayView, context: Context) { configure(view) }
    private func configure(_ view: PlankIPadCustomControlsOverlayView) {
        view.configure(layout:store.selectedLayout, enabled:enabled, begin:begin,
                       end:end, tap:tap, release:release, supports:supports,inputEpoch:inputEpoch,
                       pencilSurface:pencilSurface,pencilHover:pencilHover,pencilSqueeze:pencilSqueeze)
    }
    static func dismantleUIView(_ view: PlankIPadCustomControlsOverlayView, coordinator: ()) { view.retire(reason:.teardown) }
}

@MainActor final class PlankIPadCustomControlsOverlayView: UIView, UIPencilInteractionDelegate {
    enum RetirementReason: String { case explicit, layout, geometry, disabled, teardown }
    private var layout: PlankControlLayout?
    private var buttons: [UUID: PlankIPadCustomControlButton] = [:]
    private var previousBounds = CGRect.zero
    private var currentInputEpoch: UInt64?
    private var releaseAction: () -> Void = {}
    private var hoverAction: (UIHoverGestureRecognizer) -> Void = { _ in }
    private var squeezeAction: (UIPencilInteraction.Squeeze, UIView) -> Void = { _,_ in }

    init() {
        super.init(frame:.zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isAccessibilityElement = false
        let hover = UIHoverGestureRecognizer(target:self,action:#selector(hovered(_:)))
        hover.allowedTouchTypes = [NSNumber(value:UITouch.TouchType.pencil.rawValue)]
        hover.requiresExclusiveTouchType = false
        hover.cancelsTouchesInView = false
        hover.delaysTouchesBegan = false; hover.delaysTouchesEnded = false
        addGestureRecognizer(hover)
        let pencil = UIPencilInteraction(); pencil.delegate = self; addInteraction(pencil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func configure(layout next: PlankControlLayout, enabled: Bool,
                   begin: @escaping (UUID, PlankControlBinding) -> Bool,
                   end: @escaping (UUID) -> Void, tap: @escaping (PlankControlBinding) -> Bool,
                   release: @escaping () -> Void, supports: (PlankControlBinding) -> Bool,
                   inputEpoch: UInt64 = 0,
                   pencilSurface: @escaping () -> UIView? = { nil },
                   pencilHover: @escaping (UIHoverGestureRecognizer) -> Void = { _ in },
                   pencilSqueeze: @escaping (UIPencilInteraction.Squeeze, UIView) -> Void = { _,_ in }) {
        if currentInputEpoch != inputEpoch {
            let hadEpoch = currentInputEpoch != nil
            currentInputEpoch = inputEpoch
            if hadEpoch { retire(reason:.explicit) }
        }
        if layout != next {
            retire(reason:.layout)
            buttons.values.forEach { $0.removeFromSuperview() }
            buttons.removeAll()
            layout = next
            for control in next.controls {
                let button = PlankIPadCustomControlButton(control:control)
                buttons[control.id] = button
                addSubview(button)
            }
            setNeedsLayout()
        }
        releaseAction = release
        hoverAction = pencilHover; squeezeAction = pencilSqueeze
        for control in next.controls {
            buttons[control.id]?.configure(enabled:enabled && supports(control.binding),
                                           begin:begin, end:end, tap:tap,pencilSurface:pencilSurface)
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds != previousBounds {
            // A touch owns the binding and geometry where it began. Resizing
            // cannot transfer that ownership to a control under its new frame.
            retire(reason:.geometry)
            previousBounds = bounds
        }
        guard let layout else { return }
        let landscape = bounds.width >= bounds.height
        for control in layout.controls {
            buttons[control.id]?.frame = control.placement(landscape:landscape).frame(in:bounds)
        }
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Uncovered canvas points pass through. Over a key, route the actual
        // delivered UITouch by type; hit-testing can precede event.allTouches
        // and must not guess a new Pencil contact from nearby touch positions.
        guard let hit = super.hitTest(point, with:event), hit !== self else { return nil }
        return hit
    }
    @objc private func hovered(_ gesture: UIHoverGestureRecognizer) { hoverAction(gesture) }
    func pencilInteraction(_ interaction: UIPencilInteraction,didReceiveSqueeze value: UIPencilInteraction.Squeeze) {
        squeezeAction(value,self)
    }
    func retire(reason: RetirementReason = .explicit) {
        buttons.values.forEach { $0.retire(reason:reason) }
        releaseAction()
    }
}

/// A control can have several finger owners. Every accepted contact snapshots
/// its binding, and an accessibility hold has a separate owner from fingers.
@MainActor private final class PlankIPadCustomControlButton: UIView {
    private final class PencilContact {
        let touch: UITouch
        weak var target: UIView?
        init(touch: UITouch,target: UIView) { self.touch = touch; self.target = target }
    }
    private struct Diagnostics {
        var accepted = 0, rejected = 0, indirect = 0, pencil = 0, ends = 0, cancels = 0
        var disabled = 0, layout = 0, geometry = 0, teardown = 0, explicit = 0
        mutating func increment(_ key: WritableKeyPath<Self,Int>, by count: Int = 1) {
            self[keyPath:key] = min(1_000_000,self[keyPath:key] + count)
        }
    }
    private let control: PlankCustomControl
    private let label = UILabel()
    private var contacts = PlankIPadControlContactPolicy<ObjectIdentifier>()
    private var pencils: [ObjectIdentifier: PencilContact] = [:]
    private var accessibilityOwner: UUID?
    private var enabled = false
    private var beginAction: (UUID, PlankControlBinding) -> Bool = { _,_ in false }
    private var endAction: (UUID) -> Void = { _ in }
    private var tapAction: (PlankControlBinding) -> Bool = { _ in false }
    private var pencilSurface: () -> UIView? = { nil }
    private var diagnostics = Diagnostics()
    private var lastDiagnosticLog = -Double.infinity

    init(control: PlankCustomControl) {
        self.control = control
        super.init(frame:.zero)
        isMultipleTouchEnabled = true
        layer.cornerRadius = 12
        layer.borderWidth = 1
        label.text = control.label.isEmpty ? control.binding.title : control.label
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle:.body)
        label.adjustsFontForContentSizeCategory = true
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8
        label.numberOfLines = 2
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo:leadingAnchor, constant:8),
            label.trailingAnchor.constraint(equalTo:trailingAnchor, constant:-8),
            label.topAnchor.constraint(greaterThanOrEqualTo:topAnchor, constant:4),
            label.bottomAnchor.constraint(lessThanOrEqualTo:bottomAnchor, constant:-4),
            label.centerYAnchor.constraint(equalTo:centerYAnchor)
        ])
        isAccessibilityElement = true
        accessibilityLabel = label.text
        accessibilityHint = control.behavior == .hold
            ? "Double-tap to hold this shortcut. Double-tap again to release."
            : "Sends this shortcut once."
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func configure(enabled next: Bool, begin: @escaping (UUID, PlankControlBinding) -> Bool,
                   end: @escaping (UUID) -> Void, tap: @escaping (PlankControlBinding) -> Bool,
                   pencilSurface: @escaping () -> UIView?) {
        let wasEnabled = enabled
        enabled = next
        if wasEnabled && !next { retire(reason:.disabled) }
        beginAction = begin; endAction = end; tapAction = tap
        self.pencilSurface = pencilSurface
        refresh()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { retire(reason:.teardown) }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if touch.type == .pencil {
                forwardPencilBegin(touch,event:event)
                continue
            }
            guard touch.type == .direct else { diagnostics.increment(\.indirect); continue }
            guard let contact = contacts.proposal(id:ObjectIdentifier(touch),source:.direct,
                inside:bounds.contains(touch.location(in:self)),enabled:enabled,
                binding:control.binding,behavior:control.behavior) else {
                diagnostics.increment(\.rejected); continue
            }
            let accepted = contact.behavior == .tap || beginAction(contact.owner,contact.binding)
            guard accepted else { diagnostics.increment(\.rejected); continue }
            guard enabled, contacts.accept(contact) else {
                // A synchronous transport refusal can retire the view while its
                // callback is on the stack. Do not resurrect that finger epoch.
                if contact.behavior == .hold { endAction(contact.owner) }
                diagnostics.increment(\.rejected); continue
            }
            diagnostics.increment(\.accepted)
        }
        refresh(); logIfDue()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { forwardPencil(touch,phase:.moved,event:event) }
        // Real lift/cancel releases holds. Small finger drift outside a key
        // while painting is not a second synthetic key-up edge.
        refresh()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            forwardPencil(touch,phase:.ended,event:event)
            finish(touch, activate:bounds.contains(touch.location(in:self)),cancelled:false)
        }
        refresh(); logIfDue()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { forwardPencil(touch,phase:.cancelled,event:event); finish(touch,activate:false,cancelled:true) }
        refresh(); logIfDue()
    }
    private func finish(_ touch: UITouch, activate: Bool, cancelled: Bool) {
        guard let contact = contacts.finish(id:ObjectIdentifier(touch)) else { return }
        diagnostics.increment(cancelled ? \.cancels : \.ends)
        if contact.behavior == .hold { endAction(contact.owner) }
        else if activate && enabled { _ = tapAction(contact.binding) }
    }
    private func forwardPencilBegin(_ touch: UITouch,event: UIEvent?) {
        let id = ObjectIdentifier(touch)
        guard pencils[id] == nil, pencils.count < 8, let target = pencilSurface(), target !== self else { return }
        pencils[id] = PencilContact(touch:touch,target:target)
        diagnostics.increment(\.pencil)
        // Forward immediately so the target can consume the real coalesced
        // samples in this event and resolve coordinates in its own UIView.
        target.touchesBegan([touch],with:event)
    }
    private func forwardPencil(_ touch: UITouch,phase: UITouch.Phase,event: UIEvent?) {
        let id = ObjectIdentifier(touch)
        guard let contact = pencils[id] else { return }
        if phase == .ended || phase == .cancelled { pencils.removeValue(forKey:id) }
        guard let target = contact.target else { return }
        switch phase {
        case .moved: target.touchesMoved([touch],with:event)
        case .ended: target.touchesEnded([touch],with:event)
        case .cancelled: target.touchesCancelled([touch],with:event)
        default: break
        }
    }
    func retire(reason: PlankIPadCustomControlsOverlayView.RetirementReason = .explicit) {
        let retired = contacts.retire()
        let forwarded = Array(pencils.values); pencils.removeAll()
        let accessibility = accessibilityOwner; accessibilityOwner = nil
        if !retired.isEmpty || accessibility != nil {
            switch reason {
            case .disabled: diagnostics.increment(\.disabled)
            case .layout: diagnostics.increment(\.layout)
            case .geometry: diagnostics.increment(\.geometry)
            case .teardown: diagnostics.increment(\.teardown)
            case .explicit: diagnostics.increment(\.explicit)
            }
        }
        for contact in forwarded { contact.target?.touchesCancelled([contact.touch],with:nil) }
        for contact in retired where contact.behavior == .hold { endAction(contact.owner) }
        if let owner = accessibility { endAction(owner) }
        refresh(); logIfDue()
    }
    override func accessibilityActivate() -> Bool {
        guard enabled else { return false }
        if control.behavior == .tap { return tapAction(control.binding) }
        if let owner = accessibilityOwner {
            accessibilityOwner = nil; endAction(owner)
        } else {
            let owner = UUID()
            guard beginAction(owner,control.binding) else { return false }
            guard enabled else { endAction(owner); return false }
            accessibilityOwner = owner
        }
        refresh()
        UIAccessibility.post(notification:.announcement, argument:accessibilityValue)
        return true
    }
    private func refresh() {
        let held = accessibilityOwner != nil || contacts.hasHeldContact
        let touched = held || !contacts.isEmpty
        backgroundColor = touched ? .systemBlue : UIColor(white:0.14,alpha:0.94)
        layer.borderColor = (touched ? UIColor.systemBlue : UIColor(white:0.32,alpha:0.8)).cgColor
        label.textColor = .white
        alpha = enabled ? 1 : 0.42
        accessibilityTraits = touched ? [.button,.selected] : .button
        if !enabled { accessibilityTraits.insert(.notEnabled) }
        accessibilityValue = !enabled ? "Unavailable" : (held ? "Held" : "Released")
    }
    private func logIfDue() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDiagnosticLog >= 1,
              diagnostics.accepted + diagnostics.rejected + diagnostics.indirect + diagnostics.pencil > 0 else { return }
        lastDiagnosticLog = now
        // Saturating counts only: no positions, key assignments, text, device
        // identities or comparison codes. Cancellation remains a real release.
        NSLog("PLANK control contacts accepted=%d rejected=%d indirect=%d pencil=%d ended=%d cancelled=%d disabled=%d layout=%d geometry=%d teardown=%d explicit=%d active=%d",
            diagnostics.accepted,diagnostics.rejected,diagnostics.indirect,diagnostics.pencil,
            diagnostics.ends,diagnostics.cancels,diagnostics.disabled,diagnostics.layout,
            diagnostics.geometry,diagnostics.teardown,diagnostics.explicit,contacts.activeCount)
    }
}

/// Draft-based native editor. Its control canvas sends no remote input.
struct PlankIPadCustomControlsEditor: View {
    @ObservedObject var store: PlankIPadCustomControlsStore
    private let referenceSurfaceSize: CGSize
    private let surface: PlankIPadControlSurface
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PlankCustomControlLibrary
    @State private var history: [PlankCustomControlLibrary] = []
    @State private var selectedControlID: UUID?
    @State private var editingLandscape = true
    @State private var inspectorVisible = true
    @State private var narrowInspector = false
    @State private var dragStart: PlankControlPlacement?
    @State private var resizeStart: PlankControlPlacement?
    @State private var resizeMode = false
    @State private var canvasSize = CGSize.zero
    @State private var snapGuides: [PlankControlSnap.Guide] = []

    init(store: PlankIPadCustomControlsStore, referenceSurfaceSize: CGSize = .zero,
         surface: PlankIPadControlSurface = .desktop) {
        self.store = store
        self.referenceSurfaceSize = referenceSurfaceSize
        self.surface = surface
        let initialSurface = referenceSurfaceSize.width > 1 && referenceSurfaceSize.height > 1
            ? referenceSurfaceSize : (store.latestSurfaceSize(for:surface) ?? referenceSurfaceSize)
        _editingLandscape = State(initialValue:initialSurface.width >= initialSurface.height)
        _draft = State(initialValue:store.library)
        _selectedControlID = State(initialValue:store.selectedLayout.controls.first(where:{ $0.binding.code == 0x20 })?.id
                                   ?? store.selectedLayout.controls.first?.id)
    }

    private var selectedLayout: PlankControlLayout { draft.selectedLayout }
    private var selectedControl: PlankCustomControl? {
        selectedLayout.controls.first(where:{ $0.id == selectedControlID })
    }
    private var usesSheetInspector: Bool { previewGeometry(in:canvasSize).previewFrame.width < 620 }
    var body: some View {
        NavigationStack {
            VStack(spacing:0) {
                editorToolbar
                GeometryReader { geometry in
                    ZStack(alignment:.topLeading) {
                        Color(white:0.035)
                        canvas(in:geometry.size)
                    }
                    .clipped()
                    .onAppear { canvasSize = geometry.size }
                    .onChange(of:geometry.size) { _,value in
                        canvasSize = value; dragStart = nil; resizeStart = nil; snapGuides = []
                    }
                }
                Text(resizeMode ? "Drag a corner to resize. Sizes are in screen points."
                                : "Drag controls to move. Layouts are shared by iPad Desktop and Pencil Sharing.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal).padding(.vertical,10)
                    .frame(maxWidth:.infinity).background(.bar)
            }
            .navigationTitle("Edit Controls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) {
                    Button("Done") { store.replace(draft); dismiss() }.fontWeight(.semibold)
                        .disabled(!draft.isValid)
                }
            }
            .sheet(isPresented:$narrowInspector) {
                NavigationStack {
                    inspector
                    .navigationTitle("Control")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { narrowInspector = false } } }
                }
                .presentationDetents([.medium,.large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var editorToolbar: some View {
        HStack(spacing:12) {
            Menu {
                ForEach(draft.layouts) { layout in
                    Button {
                        remember(); _ = draft.select(id:layout.id)
                        selectedControlID = nil
                    } label: {
                        if layout.id == draft.selectedID { Label(layout.name,systemImage:"checkmark") }
                        else { Text(layout.name) }
                    }
                }
                Divider()
                Button("New Layout",systemImage:"plus") { addLayout() }
                    .disabled(draft.layouts.count >= PlankCustomControlLibrary.maximumLayouts)
                Button("Copy Layout",systemImage:"doc.on.doc") { copyLayout() }
                    .disabled(draft.layouts.count >= PlankCustomControlLibrary.maximumLayouts)
                Button("Reset Controls",systemImage:"arrow.counterclockwise") { resetLayout() }
                Button("Delete Layout",systemImage:"trash",role:.destructive) {
                    remember(); _ = draft.remove(id:selectedLayout.id); selectedControlID = nil
                }.disabled(draft.layouts.count <= 1)
            } label: {
                Label(selectedLayout.name,systemImage:"square.stack")
                    .lineLimit(1)
            }
            .accessibilityLabel("Layout: \(selectedLayout.name)")
            Spacer(minLength:0)
            Picker("Arrangement",selection:$editingLandscape) {
                Text("Landscape").tag(true)
                Text("Portrait").tag(false)
            }
            .pickerStyle(.segmented).frame(maxWidth:240)
            .onChange(of:editingLandscape) { _,_ in dragStart = nil; resizeStart = nil; snapGuides = [] }
            Button {
                resizeMode.toggle(); dragStart = nil; resizeStart = nil; snapGuides = []
            } label: { Image(systemName:"arrow.up.left.and.arrow.down.right") }
                .tint(resizeMode ? .blue : .primary)
                .accessibilityLabel("Resize controls")
                .accessibilityValue(resizeMode ? "On" : "Off")
                .accessibilityHint("When on, drag a selected control's corner to resize it. When off, drag controls to move them.")
            Button { addControl() } label: { Image(systemName:"plus") }
                .accessibilityLabel("Add control")
                .disabled(selectedLayout.controls.count >= PlankControlLayout.maximumControls)
            Button {
                guard let previous = history.popLast() else { return }
                draft = previous
                if selectedControl == nil { selectedControlID = nil }
            } label: { Image(systemName:"arrow.uturn.backward") }
                .accessibilityLabel("Undo edit").disabled(history.isEmpty)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal,16).padding(.vertical,10)
        .frame(minHeight:52).background(.bar)
    }

    @ViewBuilder private func canvas(in available: CGSize) -> some View {
        let geometry = previewGeometry(in:available)
        let canvas = geometry.previewFrame
        let bounds = CGRect(origin:.zero,size:canvas.size)
        ZStack(alignment:.topLeading) {
            RoundedRectangle(cornerRadius:16)
                .fill(Color(white:0.045))
                .overlay { RoundedRectangle(cornerRadius:16).stroke(Color.white.opacity(0.10),lineWidth:1) }
            if selectedLayout.controls.isEmpty {
                VStack(spacing:12) {
                    Image(systemName:"hand.tap").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Add a control, then move and resize it.").font(.body).foregroundStyle(.secondary)
                    Button("Add Control",systemImage:"plus") { addControl() }.buttonStyle(.bordered)
                }
                .frame(maxWidth:.infinity,maxHeight:.infinity)
            }
            ForEach(Array(snapGuides.enumerated()),id:\.offset) { _, guide in
                Path { path in
                    if guide.axis == .vertical {
                        path.move(to:CGPoint(x:guide.position * geometry.scale,y:guide.start * geometry.scale))
                        path.addLine(to:CGPoint(x:guide.position * geometry.scale,y:guide.end * geometry.scale))
                    } else {
                        path.move(to:CGPoint(x:guide.start * geometry.scale,y:guide.position * geometry.scale))
                        path.addLine(to:CGPoint(x:guide.end * geometry.scale,y:guide.position * geometry.scale))
                    }
                }
                .stroke(Color.blue.opacity(0.8),style:StrokeStyle(lineWidth:1,dash:[4,4]))
                .allowsHitTesting(false)
            }
            ForEach(selectedLayout.controls) { control in
                let frame = geometry.preview(frame:control.placement(landscape:editingLandscape).frame(in:geometry.referenceBounds))
                editorControl(control,frame:frame,geometry:geometry)
            }
            if let selected = selectedControl, inspectorVisible, canvas.width >= 620 {
                let frame = geometry.preview(frame:selected.placement(landscape:editingLandscape).frame(in:geometry.referenceBounds))
                let inspectorSize = CGSize(width:min(304,canvas.width - 32),height:min(430,canvas.height - 24))
                inspector
                    .frame(width:inspectorSize.width,height:inspectorSize.height)
                    .background(.regularMaterial,in:RoundedRectangle(cornerRadius:16))
                    .position(inspectorCenter(beside:frame,size:inspectorSize,bounds:bounds))
            }
            if let selected = selectedControl {
                let frame = geometry.preview(frame:selected.placement(landscape:editingLandscape).frame(in:geometry.referenceBounds))
                Button {
                    if usesSheetInspector { narrowInspector = true; inspectorVisible = true }
                    else { inspectorVisible.toggle() }
                } label: { Image(systemName:"slider.horizontal.3") }
                .font(.body).frame(width:44,height:44)
                .background(.regularMaterial,in:Circle())
                .position(inspectorToggleCenter(beside:frame,bounds:bounds))
                .accessibilityLabel("Show control inspector")
            }
        }
        .frame(width:canvas.width,height:canvas.height)
        .coordinateSpace(name:"plank-custom-controls-editor-canvas")
        .position(x:canvas.midX,y:canvas.midY)
        .accessibilityElement(children:.contain)
        .accessibilityLabel(editingLandscape ? "Landscape arrangement" : "Portrait arrangement")
    }

    private func editorControl(_ control: PlankCustomControl,frame: CGRect,
                               geometry: PlankControlPreviewGeometry) -> some View {
        let selected = selectedControlID == control.id
        return ZStack {
            RoundedRectangle(cornerRadius:12 * geometry.scale)
                .fill(selected ? Color.blue.opacity(0.28) : Color(white:0.14))
                .overlay { RoundedRectangle(cornerRadius:12 * geometry.scale).stroke(selected ? Color.blue : Color.white.opacity(0.28),lineWidth:selected ? 2 : 1) }
            Text(control.label.isEmpty ? control.binding.title : control.label)
                .font(.system(size:UIFont.preferredFont(forTextStyle:.body).pointSize * geometry.scale,weight:.medium))
                .lineLimit(2).minimumScaleFactor(0.8)
                .padding(.horizontal,8 * geometry.scale).foregroundStyle(.white)
            if selected && resizeMode {
                ForEach(0..<4,id:\.self) { corner in
                    resizeHandle(control,corner:corner,geometry:geometry)
                        .position(x:corner % 2 == 0 ? 0 : frame.width,
                                  y:corner < 2 ? 0 : frame.height)
                }
            }
        }
        .frame(width:frame.width,height:frame.height)
        .contentShape(Rectangle())
        .position(x:frame.midX,y:frame.midY)
        .onTapGesture { select(control.id) }
        .gesture(DragGesture(minimumDistance:4,coordinateSpace:.named("plank-custom-controls-editor-canvas"))
            .onChanged { value in
                guard !resizeMode else { return }
                if dragStart == nil {
                    remember(); select(control.id,showInspector:false)
                    dragStart = clampedPlacement(control.placement(landscape:editingLandscape),in:geometry.referenceBounds)
                }
                guard var next = dragStart else { return }
                let translation = geometry.referenceTranslation(value.translation)
                let bounds = geometry.referenceBounds
                next.x = min(max(next.x + translation.width / max(bounds.width,1),0),1)
                next.y = min(max(next.y + translation.height / max(bounds.height,1),0),1)
                let result = PlankControlSnap.move(placement:next,in:bounds,peers:peerFrames(excluding:control.id,in:bounds),
                                                  gutter:6,threshold:8 / max(geometry.scale,0.01))
                snapGuides = result.guides
                setPlacement(result.placement,id:control.id)
            }
            .onEnded { _ in dragStart = nil; snapGuides = [] })
        .accessibilityElement(children:.ignore)
        .accessibilityLabel("\(control.label), \(control.binding.title)")
        .accessibilityHint(resizeMode ? "Select, then drag a corner to resize. Exact size is also available in the inspector."
                           : "Drag to move. Select to edit binding, size and position.")
        .accessibilityAddTraits(selected ? [.isButton,.isSelected] : .isButton)
        .accessibilityAction { select(control.id) }
    }

    private func resizeHandle(_ control: PlankCustomControl,corner: Int,
                              geometry: PlankControlPreviewGeometry) -> some View {
        Circle().fill(.white).frame(width:max(6,10 * geometry.scale),height:max(6,10 * geometry.scale))
            .frame(width:44,height:44).contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance:0,coordinateSpace:.named("plank-custom-controls-editor-canvas"))
                .onChanged { value in
                    if resizeStart == nil { remember(); resizeStart = control.placement(landscape:editingLandscape) }
                    guard let original = resizeStart else { return }
                    let bounds = geometry.referenceBounds
                    let result = PlankControlSnap.resize(original:original,corner:corner,
                        translation:geometry.referenceTranslation(value.translation),in:bounds,
                        peers:peerFrames(excluding:control.id,in:bounds),gutter:6,threshold:8 / max(geometry.scale,0.01))
                    snapGuides = result.guides
                    setPlacement(result.placement,id:control.id)
                }
                .onEnded { _ in resizeStart = nil; snapGuides = [] })
            .accessibilityHidden(true)
    }

    private func peerFrames(excluding id: UUID,in bounds: CGRect) -> [CGRect] {
        selectedLayout.controls.filter { $0.id != id }.map { $0.placement(landscape:editingLandscape).frame(in:bounds) }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                HStack {
                    Text("Control").font(.headline)
                    Spacer()
                    if !usesSheetInspector {
                        Button { inspectorVisible = false } label: { Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary) }
                            .accessibilityLabel("Hide inspector")
                    }
                }
                TextField("Layout name",text:layoutNameBinding)
                    .font(.subheadline).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Layout name")
                if selectedControl != nil {
                    TextField("Control label",text:labelBinding)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Control label")
                    Picker("Key",selection:keyBinding) {
                        ForEach(PlankControlKeyCatalog.entries) { key in Text(key.title).tag(key.code) }
                    }
                    .pickerStyle(.menu)
                    VStack(alignment:.leading,spacing:8) {
                        Text("Modifiers").font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing:6) {
                            modifierToggle("⇧",name:"Shift",mask:1)
                            modifierToggle("⌃",name:"Control",mask:2)
                            modifierToggle("⌥",name:"Option",mask:4)
                            modifierToggle("⌘",name:"Command",mask:8)
                        }
                    }
                    Picker("Behavior",selection:controlBinding(\.behavior,fallback:.hold)) {
                        Text("Hold").tag(PlankControlBehavior.hold)
                        Text("Tap").tag(PlankControlBehavior.tap)
                    }.pickerStyle(.segmented)
                    Text(selectedControl?.behavior == .hold ? "Held until the finger lifts." : "Sends one complete shortcut.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Divider()
                    dimension("Width",key:\.width,range:44...480)
                    dimension("Height",key:\.height,range:44...240)
                    position("Horizontal",key:\.x)
                    position("Vertical",key:\.y)
                    HStack {
                        Button("Duplicate",systemImage:"plus.square.on.square") { duplicateControl() }
                            .disabled(selectedLayout.controls.count >= PlankControlLayout.maximumControls)
                        Spacer()
                        Button(role:.destructive) { deleteControl() } label: { Image(systemName:"trash") }
                            .accessibilityLabel("Delete control")
                    }
                }
                if !draft.isValid {
                    Text("Give the layout and each control a name to save your changes.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.padding(16)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func modifierToggle(_ label: String,name: String,mask: UInt8) -> some View {
        let selected = (selectedControl?.binding.modifiers ?? 0) & mask != 0
        return Button {
            mutateControl { $0.binding.modifiers ^= mask }
        } label: { Text(label).font(.title3).frame(maxWidth:.infinity,minHeight:44) }
        .buttonStyle(.bordered)
        .tint(selected ? .blue : .gray)
        .accessibilityLabel(name)
        .accessibilityValue(selected ? "Included" : "Not included")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func dimension(_ title: String,key: WritableKeyPath<PlankControlPlacement,Double>,range: ClosedRange<Double>) -> some View {
        Stepper(value:placementBinding(key),in:range,step:4) {
            HStack { Text(title); Spacer(); Text(placementValue(key),format:.number.precision(.fractionLength(0))).monospacedDigit(); Text("pt").foregroundStyle(.secondary) }
        }
        .font(.subheadline)
    }
    private func position(_ title: String,key: WritableKeyPath<PlankControlPlacement,Double>) -> some View {
        Stepper(value:placementBinding(key),in:0...1,step:0.01) {
            HStack { Text(title); Spacer(); Text(placementValue(key),format:.percent.precision(.fractionLength(0))).monospacedDigit() }
        }.font(.subheadline)
    }
    private func placementValue(_ key: KeyPath<PlankControlPlacement,Double>) -> Double {
        selectedControl?.placement(landscape:editingLandscape)[keyPath:key] ?? 0
    }
    private func placementBinding(_ key: WritableKeyPath<PlankControlPlacement,Double>) -> Binding<Double> {
        Binding(get:{ placementValue(key) },set:{ value in
            mutateControl { control in
                var placement = control.placement(landscape:editingLandscape)
                placement[keyPath:key] = value
                let bounds = previewGeometry(in:canvasSize).referenceBounds
                control.setPlacement(clampedPlacement(placement,in:bounds),landscape:editingLandscape)
            }
        })
    }
    private var layoutNameBinding: Binding<String> {
        Binding(get:{ selectedLayout.name },set:{ value in
            remember(); var layout = selectedLayout; layout.name = String(value.prefix(48)); replaceDraft(layout)
        })
    }
    private var labelBinding: Binding<String> {
        Binding(get:{ selectedControl?.label ?? "" },set:{ value in
            mutateControl { $0.label = String(value.prefix(40)) }
        })
    }
    private var keyBinding: Binding<UInt16> {
        Binding(get:{ selectedControl?.binding.code ?? 0x20 },set:{ value in mutateControl { $0.binding.code = value } })
    }
    private func controlBinding<Value>(_ key: WritableKeyPath<PlankCustomControl,Value>,fallback: Value) -> Binding<Value> {
        Binding(get:{ selectedControl?[keyPath:key] ?? fallback },set:{ value in mutateControl { $0[keyPath:key] = value } })
    }
    private func select(_ id: UUID,showInspector: Bool = true) {
        selectedControlID = id
        if showInspector {
            inspectorVisible = true
            if usesSheetInspector { narrowInspector = true }
        }
    }
    private func remember() {
        if history.last != draft { history.append(draft) }
        if history.count > 32 { history.removeFirst() }
    }
    private func mutateControl(_ action: (inout PlankCustomControl) -> Void) {
        guard let id = selectedControlID else { return }
        var layout = selectedLayout
        guard let index = layout.controls.firstIndex(where:{ $0.id == id }) else { return }
        remember(); action(&layout.controls[index]); replaceDraft(layout)
    }
    private func setPlacement(_ placement: PlankControlPlacement,id: UUID) {
        var layout = selectedLayout
        guard let index = layout.controls.firstIndex(where:{ $0.id == id }) else { return }
        layout.controls[index].setPlacement(placement,landscape:editingLandscape)
        replaceDraft(layout)
    }
    private func replaceDraft(_ layout: PlankControlLayout) {
        // Local text edits may briefly be empty. Keep that draft visible and
        // disable Done instead of silently rejecting a text-field keystroke.
        guard let index = draft.layouts.firstIndex(where:{ $0.id == layout.id }) else { return }
        draft.layouts[index] = layout
    }
    private func addControl() {
        guard selectedLayout.controls.count < PlankControlLayout.maximumControls else { return }
        remember()
        var layout = selectedLayout
        let placement = PlankControlPlacement(x:0.5,y:0.5,width:88,height:52)
        let control = PlankCustomControl(id:UUID(),label:"Space",binding:.init(code:0x20),behavior:.hold,
                                         portrait:placement,landscape:placement)
        layout.controls.append(control); replaceDraft(layout); select(control.id)
    }
    private func duplicateControl() {
        guard let original = selectedControl, selectedLayout.controls.count < PlankControlLayout.maximumControls else { return }
        remember(); var layout = selectedLayout
        var copied = original; copied.id = UUID()
        copied.portrait.x = min(copied.portrait.x + 0.04,1)
        copied.portrait.y = min(copied.portrait.y + 0.04,1)
        copied.landscape.x = min(copied.landscape.x + 0.04,1)
        copied.landscape.y = min(copied.landscape.y + 0.04,1)
        layout.controls.append(copied); replaceDraft(layout); select(copied.id)
    }
    private func deleteControl() {
        guard let id = selectedControlID else { return }
        remember(); var layout = selectedLayout; layout.controls.removeAll(where:{ $0.id == id })
        replaceDraft(layout); selectedControlID = nil; narrowInspector = false
    }
    private func addLayout() {
        guard draft.layouts.count < PlankCustomControlLibrary.maximumLayouts else { return }
        remember(); _ = draft.upsert(layout:.defaults(name:"New Layout")); selectedControlID = nil
    }
    private func copyLayout() {
        guard draft.layouts.count < PlankCustomControlLibrary.maximumLayouts else { return }
        remember(); _ = draft.duplicate(id:selectedLayout.id); selectedControlID = nil
    }
    private func resetLayout() {
        remember(); var replacement = PlankControlLayout.defaults(name:selectedLayout.name)
        replacement.id = selectedLayout.id
        replaceDraft(replacement); selectedControlID = nil
    }
    private func previewGeometry(in available: CGSize) -> PlankControlPreviewGeometry {
        PlankControlPreviewGeometry(referenceSize:store.referenceSize(landscape:editingLandscape,fallback:referenceSurfaceSize,surface:surface),
                                    availableSize:available,inset:16)
    }
    private func inspectorToggleCenter(beside frame: CGRect,bounds: CGRect) -> CGPoint {
        let radius: CGFloat = 22, gap: CGFloat = 8
        let right = frame.maxX + gap + radius
        let left = frame.minX - gap - radius
        let x = right + radius <= bounds.maxX ? right : (left - radius >= bounds.minX ? left : bounds.midX)
        return CGPoint(x:min(max(x,bounds.minX + radius),max(bounds.minX + radius,bounds.maxX - radius)),
                       y:min(max(frame.midY,bounds.minY + radius),max(bounds.minY + radius,bounds.maxY - radius)))
    }
    private func inspectorCenter(beside frame: CGRect,size: CGSize,bounds: CGRect) -> CGPoint {
        let gap: CGFloat = 16
        let minX = size.width/2 + 12, maxX = max(minX,bounds.width - size.width/2 - 12)
        let minY = size.height/2 + 12, maxY = max(minY,bounds.height - size.height/2 - 12)
        let right = frame.maxX + gap + size.width/2
        let left = frame.minX - gap - size.width/2
        let x = right <= maxX ? right : (left >= minX ? left : maxX)
        let y: CGFloat
        if right > maxX && left < minX {
            let below = frame.maxY + gap + size.height/2
            let above = frame.minY - gap - size.height/2
            y = below <= maxY ? below : (above >= minY ? above : minY)
        } else { y = frame.midY }
        return CGPoint(x:min(max(x,minX),maxX),y:min(max(y,minY),maxY))
    }
}
