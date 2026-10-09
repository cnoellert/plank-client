import SwiftUI
import UIKit

/// One saved library is shared by the direct desktop and Pencil sharing.
/// Editing stays local until Done; the overlay receives transport closures.
@MainActor final class PlankIPadCustomControlsStore: ObservableObject {
    @Published private(set) var library: PlankCustomControlLibrary
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

    func makeUIView(context: Context) -> PlankIPadCustomControlsOverlayView {
        let view = PlankIPadCustomControlsOverlayView()
        configure(view)
        return view
    }
    func updateUIView(_ view: PlankIPadCustomControlsOverlayView, context: Context) { configure(view) }
    private func configure(_ view: PlankIPadCustomControlsOverlayView) {
        view.configure(layout:store.selectedLayout, enabled:enabled, begin:begin,
                       end:end, tap:tap, release:release, supports:supports)
    }
    static func dismantleUIView(_ view: PlankIPadCustomControlsOverlayView, coordinator: ()) { view.retire() }
}

@MainActor final class PlankIPadCustomControlsOverlayView: UIView {
    private var layout: PlankControlLayout?
    private var buttons: [UUID: PlankIPadCustomControlButton] = [:]
    private var previousBounds = CGRect.zero
    private var releaseAction: () -> Void = {}

    init() {
        super.init(frame:.zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func configure(layout next: PlankControlLayout, enabled: Bool,
                   begin: @escaping (UUID, PlankControlBinding) -> Bool,
                   end: @escaping (UUID) -> Void, tap: @escaping (PlankControlBinding) -> Bool,
                   release: @escaping () -> Void, supports: (PlankControlBinding) -> Bool) {
        if layout != next {
            retire()
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
        for control in next.controls {
            buttons[control.id]?.configure(enabled:enabled && supports(control.binding),
                                           begin:begin, end:end, tap:tap)
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds != previousBounds {
            // A touch owns the binding and geometry where it began. Resizing
            // cannot transfer that ownership to a control under its new frame.
            retire()
            previousBounds = bounds
        }
        guard let layout else { return }
        let landscape = bounds.width >= bounds.height
        for control in layout.controls {
            buttons[control.id]?.frame = control.placement(landscape:landscape).frame(in:bounds)
        }
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Hit-test only controls. The canvas below retains every other touch,
        // including a new Pencil contact directly over a shortcut control.
        if plankIsPencilHit(point:point, in:self, event:event) { return nil }
        guard let hit = super.hitTest(point, with:event), hit !== self else { return nil }
        return hit
    }
    func retire() {
        buttons.values.forEach { $0.retire() }
        releaseAction()
    }
}

@MainActor private func plankIsPencilHit(point: CGPoint, in view: UIView, event: UIEvent?) -> Bool {
    event?.allTouches?.contains(where:{ touch in
        guard touch.type == .pencil, touch.phase == .began else { return false }
        let location = touch.location(in:view)
        return abs(location.x - point.x) < 1 && abs(location.y - point.y) < 1
    }) == true
}

/// A control can have several finger owners. Every accepted contact snapshots
/// its binding, and an accessibility hold has a separate owner from fingers.
@MainActor private final class PlankIPadCustomControlButton: UIView {
    private struct Contact { let owner: UUID; let binding: PlankControlBinding; let behavior: PlankControlBehavior }
    private let control: PlankCustomControl
    private let label = UILabel()
    private var contacts: [ObjectIdentifier: Contact] = [:]
    private var accessibilityOwner: UUID?
    private var enabled = false
    private var beginAction: (UUID, PlankControlBinding) -> Bool = { _,_ in false }
    private var endAction: (UUID) -> Void = { _ in }
    private var tapAction: (PlankControlBinding) -> Bool = { _ in false }

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
                   end: @escaping (UUID) -> Void, tap: @escaping (PlankControlBinding) -> Bool) {
        if enabled && !next { retire() }
        enabled = next
        beginAction = begin; endAction = end; tapAction = tap
        refresh()
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if plankIsPencilHit(point:point, in:self, event:event) { return nil }
        return super.hitTest(point, with:event)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard enabled else { return }
        for touch in touches where touch.type != .pencil {
            let owner = UUID()
            let accepted = control.behavior == .tap || beginAction(owner,control.binding)
            if accepted {
                contacts[ObjectIdentifier(touch)] = Contact(owner:owner, binding:control.binding, behavior:control.behavior)
            }
        }
        refresh()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where !bounds.contains(touch.location(in:self)) { finish(touch, activate:false) }
        refresh()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { finish(touch, activate:bounds.contains(touch.location(in:self))) }
        refresh()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { finish(touch,activate:false) }
        refresh()
    }
    private func finish(_ touch: UITouch, activate: Bool) {
        guard let contact = contacts.removeValue(forKey:ObjectIdentifier(touch)) else { return }
        if contact.behavior == .hold { endAction(contact.owner) }
        else if activate && enabled { _ = tapAction(contact.binding) }
    }
    func retire() {
        for contact in contacts.values where contact.behavior == .hold { endAction(contact.owner) }
        contacts.removeAll()
        if let owner = accessibilityOwner { endAction(owner) }
        accessibilityOwner = nil
        refresh()
    }
    override func accessibilityActivate() -> Bool {
        guard enabled else { return false }
        if control.behavior == .tap { return tapAction(control.binding) }
        if let owner = accessibilityOwner {
            endAction(owner); accessibilityOwner = nil
        } else {
            let owner = UUID()
            guard beginAction(owner,control.binding) else { return false }
            accessibilityOwner = owner
        }
        refresh()
        UIAccessibility.post(notification:.announcement, argument:accessibilityValue)
        return true
    }
    private func refresh() {
        let held = accessibilityOwner != nil || contacts.values.contains(where:{ $0.behavior == .hold })
        let touched = held || !contacts.isEmpty
        backgroundColor = touched ? .systemBlue : UIColor(white:0.14,alpha:0.94)
        layer.borderColor = (touched ? UIColor.systemBlue : UIColor(white:0.32,alpha:0.8)).cgColor
        label.textColor = .white
        alpha = enabled ? 1 : 0.42
        accessibilityTraits = touched ? [.button,.selected] : .button
        if !enabled { accessibilityTraits.insert(.notEnabled) }
        accessibilityValue = !enabled ? "Unavailable" : (held ? "Held" : "Released")
    }
}

/// Draft-based native editor. Its control canvas sends no remote input.
struct PlankIPadCustomControlsEditor: View {
    @ObservedObject var store: PlankIPadCustomControlsStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PlankCustomControlLibrary
    @State private var history: [PlankCustomControlLibrary] = []
    @State private var selectedControlID: UUID?
    @State private var editingLandscape = true
    @State private var choseInitialOrientation = false
    @State private var inspectorVisible = true
    @State private var narrowInspector = false
    @State private var dragStart: PlankControlPlacement?
    @State private var resizeStart: PlankControlPlacement?
    @State private var canvasSize = CGSize.zero

    init(store: PlankIPadCustomControlsStore) {
        self.store = store
        _draft = State(initialValue:store.library)
        _selectedControlID = State(initialValue:store.selectedLayout.controls.first(where:{ $0.binding.code == 0x20 })?.id
                                   ?? store.selectedLayout.controls.first?.id)
    }

    private var selectedLayout: PlankControlLayout { draft.selectedLayout }
    private var selectedControl: PlankCustomControl? {
        selectedLayout.controls.first(where:{ $0.id == selectedControlID })
    }
    private var usesSheetInspector: Bool { previewFrame(in:canvasSize).width < 620 }
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
                    .onAppear {
                        canvasSize = geometry.size
                        if !choseInitialOrientation {
                            editingLandscape = geometry.size.width >= geometry.size.height
                            choseInitialOrientation = true
                        }
                    }
                    .onChange(of:geometry.size) { _,value in canvasSize = value; dragStart = nil; resizeStart = nil }
                }
                Text("Layouts are shared by iPad Desktop and Pencil Sharing.")
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
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
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
            .onChange(of:editingLandscape) { _,_ in dragStart = nil; resizeStart = nil }
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
        let canvas = previewFrame(in:available)
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
            if let selected = selectedControl, dragStart != nil {
                let placement = selected.placement(landscape:editingLandscape)
                if placement.x == 0.5 {
                    Path { path in path.move(to:CGPoint(x:bounds.midX,y:0)); path.addLine(to:CGPoint(x:bounds.midX,y:bounds.height)) }
                        .stroke(Color.blue.opacity(0.7),style:StrokeStyle(lineWidth:1,dash:[4,4]))
                        .allowsHitTesting(false)
                }
                if placement.y == 0.5 {
                    Path { path in path.move(to:CGPoint(x:0,y:bounds.midY)); path.addLine(to:CGPoint(x:bounds.width,y:bounds.midY)) }
                        .stroke(Color.blue.opacity(0.7),style:StrokeStyle(lineWidth:1,dash:[4,4]))
                        .allowsHitTesting(false)
                }
            }
            ForEach(selectedLayout.controls) { control in
                let placement = control.placement(landscape:editingLandscape)
                let frame = placement.frame(in:bounds)
                editorControl(control,frame:frame,bounds:bounds)
            }
            if let selected = selectedControl, inspectorVisible, canvas.width >= 620 {
                let frame = selected.placement(landscape:editingLandscape).frame(in:bounds)
                let inspectorSize = CGSize(width:min(304,canvas.width - 32),height:min(430,canvas.height - 24))
                inspector
                    .frame(width:inspectorSize.width,height:inspectorSize.height)
                    .background(.regularMaterial,in:RoundedRectangle(cornerRadius:16))
                    .position(inspectorCenter(beside:frame,size:inspectorSize,bounds:bounds))
            }
        }
        .frame(width:canvas.width,height:canvas.height)
        .coordinateSpace(name:"plank-custom-controls-editor-canvas")
        .position(x:canvas.midX,y:canvas.midY)
        .accessibilityElement(children:.contain)
        .accessibilityLabel(editingLandscape ? "Landscape arrangement" : "Portrait arrangement")
    }

    private func editorControl(_ control: PlankCustomControl,frame: CGRect,bounds: CGRect) -> some View {
        let selected = selectedControlID == control.id
        return ZStack {
            RoundedRectangle(cornerRadius:12)
                .fill(selected ? Color.blue.opacity(0.28) : Color(white:0.14))
                .overlay { RoundedRectangle(cornerRadius:12).stroke(selected ? Color.blue : Color.white.opacity(0.28),lineWidth:selected ? 2 : 1) }
            Text(control.label.isEmpty ? control.binding.title : control.label)
                .font(.body.weight(.medium)).lineLimit(2).minimumScaleFactor(0.8)
                .padding(.horizontal,8).foregroundStyle(.white)
            if selected {
                ForEach(0..<4,id:\.self) { corner in
                    resizeHandle(control,corner:corner,bounds:bounds)
                        .position(x:corner % 2 == 0 ? 0 : frame.width,
                                  y:corner < 2 ? 0 : frame.height)
                }
                Button {
                    inspectorVisible.toggle()
                    if usesSheetInspector { narrowInspector = true; inspectorVisible = true }
                } label: { Image(systemName:"slider.horizontal.3") }
                .font(.body).frame(width:44,height:44)
                .background(.regularMaterial,in:Circle())
                .offset(x:frame.width/2 + 26,y:0)
                .accessibilityLabel("Show control inspector")
            }
        }
        .frame(width:frame.width,height:frame.height)
        .contentShape(Rectangle())
        .position(x:frame.midX,y:frame.midY)
        .onTapGesture { select(control.id) }
        .gesture(DragGesture(minimumDistance:4,coordinateSpace:.named("plank-custom-controls-editor-canvas"))
            .onChanged { value in
                if dragStart == nil {
                    remember(); select(control.id,showInspector:false)
                    dragStart = control.placement(landscape:editingLandscape)
                }
                guard var next = dragStart, bounds.width > 0, bounds.height > 0 else { return }
                next.x += value.translation.width / bounds.width
                next.y += value.translation.height / bounds.height
                // Align to the surface center within eight points.
                if abs(next.x - 0.5) * bounds.width < 8 { next.x = 0.5 }
                if abs(next.y - 0.5) * bounds.height < 8 { next.y = 0.5 }
                setPlacement(clamped(next,in:bounds),id:control.id)
            }
            .onEnded { _ in dragStart = nil })
        .accessibilityElement(children:.ignore)
        .accessibilityLabel("\(control.label), \(control.binding.title)")
        .accessibilityHint("Select to edit binding, size and position.")
        .accessibilityAddTraits(selected ? [.isButton,.isSelected] : .isButton)
        .accessibilityAction { select(control.id) }
    }

    private func resizeHandle(_ control: PlankCustomControl,corner: Int,bounds: CGRect) -> some View {
        Circle().fill(.white).frame(width:10,height:10)
            .frame(width:44,height:44).contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance:0,coordinateSpace:.named("plank-custom-controls-editor-canvas"))
                .onChanged { value in
                    if resizeStart == nil { remember(); resizeStart = control.placement(landscape:editingLandscape) }
                    guard let original = resizeStart else { return }
                    var next = original
                    let dx = value.translation.width * (corner % 2 == 0 ? -1 : 1)
                    let dy = value.translation.height * (corner < 2 ? -1 : 1)
                    next.width = min(max(original.width + dx,PlankControlPlacement.minimumDimension),PlankControlPlacement.maximumWidth)
                    next.height = min(max(original.height + dy,PlankControlPlacement.minimumDimension),PlankControlPlacement.maximumHeight)
                    next.x = original.x + (next.width - original.width) * (corner % 2 == 0 ? -0.5 : 0.5) / max(bounds.width,1)
                    next.y = original.y + (next.height - original.height) * (corner < 2 ? -0.5 : 0.5) / max(bounds.height,1)
                    setPlacement(clamped(next,in:bounds),id:control.id)
                }
                .onEnded { _ in resizeStart = nil })
            .accessibilityHidden(true)
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
                let size = previewFrame(in:canvasSize).size
                control.setPlacement(clamped(placement,in:CGRect(origin:.zero,size:size)),landscape:editingLandscape)
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
    private func previewFrame(in available: CGSize) -> CGRect {
        let inset: CGFloat = 16
        let width = max(available.width - inset*2,44), height = max(available.height - inset*2,44)
        // Editing the current orientation uses the whole available surface.
        // The other arrangement previews the same surface with its axes
        // exchanged, retaining point-sized controls rather than scaling them.
        let currentRatio = max(width,height) / max(min(width,height),1)
        let ratio: CGFloat = editingLandscape ? currentRatio : 1/currentRatio
        let canvasWidth = min(width,height*ratio), canvasHeight = min(height,width/ratio)
        return CGRect(x:(available.width-canvasWidth)/2,y:(available.height-canvasHeight)/2,
                      width:canvasWidth,height:canvasHeight)
    }
    private func clamped(_ placement: PlankControlPlacement,in bounds: CGRect) -> PlankControlPlacement {
        var next = placement
        next.width = min(max(next.width,44),480)
        next.height = min(max(next.height,44),240)
        let halfX = min(next.width,bounds.width) / max(bounds.width*2,1)
        let halfY = min(next.height,bounds.height) / max(bounds.height*2,1)
        next.x = min(max(next.x,halfX),1-halfX)
        next.y = min(max(next.y,halfY),1-halfY)
        return next
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
