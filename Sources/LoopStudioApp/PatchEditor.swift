import AppKit
import LoopStudioCore
import SwiftUI

// MARK: The card

/// The card of a Patch device: its panel. The knobs come in groups, one per module on the panel; the meters
/// beside them. The pen in the card's title row opens the editor.
struct PatchCardView: View {
    let track: Track
    let device: DeviceSlot
    let spec: EffectSpec

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            if let error = device.patchError {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Does not compile").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.automationDot)
                    Text(error.description).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim).lineLimit(4)
                    Text("The sound passes through unchanged. Click the pen to edit.").font(.system(size: 10)).foregroundStyle(Theme.dim)
                }
                .frame(width: 200, alignment: .leading)
            } else if spec.groups.isEmpty, spec.meterNames.isEmpty {
                Text("Nothing on the panel. Click the pen: put a knob, or a module, on the panel.")
                    .font(.system(size: 10)).foregroundStyle(Theme.dim).frame(width: 170)
            } else {
                ForEach(spec.groups, id: \.title) { group in
                    KnobSection(title: group.title) {
                        ForEach(group.keys, id: \.self) { ParamKnob(track: track, device: device, spec: spec, key: $0) }
                    }
                }
                if !spec.meterNames.isEmpty { PatchMeters(device: device, names: spec.meterNames) }
            }
        }
    }
}

/// The meters of a patch: one bar per `meter`, with its name, at 30 frames per second.
private struct PatchMeters: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSlot
    let names: [String]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
            let dsp = model.engine.builtInEffect(device.id)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(names.prefix(4).enumerated()), id: \.offset) { i, name in
                    VStack(spacing: 2) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 1).fill(Theme.panel)
                            RoundedRectangle(cornerRadius: 1).fill(Theme.accent.opacity(0.85))
                                .frame(height: CGFloat(min(1, max(0, dsp.map { Double($0.meters[i]) } ?? 0))) * 44)
                        }
                        .frame(width: 8, height: 44)
                        .overlay(RoundedRectangle(cornerRadius: 1).stroke(Theme.line, lineWidth: 1))
                        Text(name).font(.system(size: 8)).foregroundStyle(Theme.dim).lineLimit(1).frame(width: 36)
                    }
                }
            }
            .padding(.top, 8).padding(.horizontal, 4)
        }
    }
}

// MARK: The window

/// One editor window per patch device: the canvas of modules and cables, and the inspector of the selected
/// module. Every edit goes into the project at once as one undo step; the engine takes the new program at
/// the next plan. A graph that does not compile shows its error and the sound passes through.
@MainActor
enum PatchEditorWindow {
    private static var windows: [DeviceID: NSWindow] = [:]

    static func show(model: AppModel, track: TrackID, device: DeviceID) {
        if let w = windows[device] { w.makeKeyAndOrderFront(nil); return }
        let name = model.project.track(track)?.device(device)?.name ?? "Patch"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(name) – Patch"
        // The key monitor leaves "loopstudio." windows alone: typing here must not play notes or delete clips.
        window.identifier = NSUserInterfaceItemIdentifier("loopstudio.patch")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 720, height: 420)
        let view = PatchEditorView(track: track, device: device)
            .environment(model)
            .preferredColorScheme(model.isLightTheme ? .light : .dark)
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [] // the window keeps its own size; the view's minimum is not its size
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1040, height: 660))
        window.center()
        windows[device] = window
        window.makeKeyAndOrderFront(nil)
    }

    static func close(_ device: DeviceID) { windows[device]?.close(); windows[device] = nil }
}

struct PatchEditorView: View {
    @Environment(AppModel.self) private var model
    let track: TrackID
    let device: DeviceID
    @State private var doc = PatchDocument()
    @State private var loadedSource: String?
    @State private var selected: String?
    @State private var renameRequest = 0
    /// A refused edit or a warning, in the status bar until the next edit.
    @State private var notice: String?

    private var slot: DeviceSlot? { model.project.track(track)?.device(device) }
    private var compiled: Result<PatchProgram, PatchError> { PatchCompiler.cached(doc.source) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                PatchCanvas(doc: $doc, selected: $selected, commit: commit, add: { kind, point in add(kind, at: point) },
                            rename: { renameRequest += 1 })
                Divider()
                PatchInspector(doc: doc, selected: selected, renameRequest: renameRequest, commit: commit)
                    .frame(width: 300)
            }
            Divider()
            status
        }
        .frame(minWidth: 720, minHeight: 420)
        .background {
            // ⌘R: rename the selected module (the label field in the inspector takes the focus).
            Button("Rename") { if selected != nil { renameRequest += 1 } }
                .keyboardShortcut("r", modifiers: .command).hidden()
        }
        .onAppear { load() }
        .onChange(of: slot?.source) { _, _ in load() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            NameField(name: doc.name) { commit(.rename($0)) }
            Spacer()
            Menu("Add Module") {
                ForEach(PatchModules.categories, id: \.self) { category in
                    Menu(category) {
                        ForEach(PatchModules.all.filter { $0.category == category }) { spec in
                            Button(spec.name) { add(spec.id) }
                                .disabled(spec.single && doc.modules.contains { $0.kind == spec.id })
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .hint("Put a module on the canvas, or right-click the canvas. Drag from an output dot to an input dot to cable it.")
        }
        .padding(10)
    }

    private var status: some View {
        HStack(spacing: 8) {
            if let notice {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.automationDot)
                Text(notice).font(.system(size: 11)).foregroundStyle(Theme.text).lineLimit(2)
                    .onTapGesture { self.notice = nil }
            } else {
            switch compiled {
            case .success(let program):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.play)
                Text("\(program.name): \(program.spec.params.count) knob\(program.spec.params.count == 1 ? "" : "s"), \(program.ops.count) ops per sample")
                    .font(.system(size: 11)).foregroundStyle(Theme.dim)
            case .failure(let error):
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.automationDot)
                Text(error.description).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(2)
            }
            }
            Spacer()
            Text("\(doc.modules.count) modules, \(doc.cables.count) cables").font(.system(size: 10)).foregroundStyle(Theme.dim)
            Text("docs/patcher.md").font(.system(size: 10)).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    /// The device's document, when it changed under the editor (an undo, the assistant).
    private func load() {
        let source = slot?.source ?? ""
        guard source != loadedSource else { return }
        loadedSource = source
        if let parsed = PatchDocument.parse(source) { doc = parsed }
        if let selected, doc.module(selected) == nil { self.selected = nil }
    }

    /// One edit into the project. A move coalesces while it goes on; the rest are one undo step each.
    private func commit(_ edit: PatchEdit) {
        var next = doc
        do { try next.apply(edit) } catch { notice = "\(error)"; model.status = "\(error)"; return }
        notice = warning(for: edit)
        doc = next
        let source = next.source
        loadedSource = source
        let name = (try? PatchCompiler.compile(source).name).flatMap { $0 == slot?.name ? nil : $0 }
        var key: String?
        if case .move(let id, _, _) = edit { key = "patchmove.\(device).\(id)" }
        model.apply(.setDeviceSource(track: track, device: device, source: source, name: name), key: key)
        if case .failure(let e) = PatchCompiler.cached(source) { model.status = "Patch: \(e.description)" }
    }

    /// A cable between two port types that connect but differ (a control into an audio input) gets a note.
    private func warning(for edit: PatchEdit) -> String? {
        guard case .connect(let from, let fromPort, let to, let toPort) = edit,
              let a = doc.module(from), let b = doc.module(to),
              let o = PatchModules.ports(of: a).outputs.first(where: { $0.name == fromPort }),
              let i = PatchModules.ports(of: b).inputs.first(where: { $0.name == toPort }),
              o.type != i.type else { return nil }
        return "\(from).\(fromPort) → \(to).\(toPort): a \(o.type.rawValue) signal into an \(i.type.rawValue) input. It is a steady value there, not a sound."
    }

    /// A new module: where the pointer was (the canvas menu), or on a grid from the toolbar.
    private func add(_ kind: String, at point: CGPoint? = nil) {
        let n = doc.modules.count
        let x = point.map { max(0, $0.x).rounded() } ?? 60 + Double(n % 6) * 160
        let y = point.map { max(0, $0.y).rounded() } ?? 60 + Double(n / 6) * 90
        let id = doc.freeID(for: kind)
        commit(.add(kind: kind, id: id, x: x, y: y))
        selected = id
    }
}

/// The name of the patch: commits on Return or when the focus leaves.
private struct NameField: View {
    let name: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold)).frame(width: 220)
            .focused($focused)
            .onSubmit { if text != name { commit(text) } }
            .onChange(of: focused) { _, now in if !now, text != name { commit(text) } }
            .onAppear { text = name }
            .onChange(of: name) { if !focused { text = name } }
            .hint("The name of the patch; the device takes it.")
    }
}

// MARK: The canvas

/// Geometry of a module on the canvas, shared by the module views, the cables and the hit test.
enum PatchLayout {
    static let width: CGFloat = 136
    static let header: CGFloat = 22
    static let row: CGFloat = 16
    static let dot: CGFloat = 8

    static func height(_ m: PatchModule) -> CGFloat {
        let ports = PatchModules.ports(of: m)
        return header + CGFloat(max(1, max(ports.inputs.count, ports.outputs.count))) * row + 6
    }
    static func inputPoint(_ m: PatchModule, index: Int, offset: CGSize = .zero) -> CGPoint {
        CGPoint(x: m.x + offset.width, y: m.y + offset.height + header + CGFloat(index) * row + row / 2)
    }
    static func outputPoint(_ m: PatchModule, index: Int, offset: CGSize = .zero) -> CGPoint {
        CGPoint(x: m.x + offset.width + width, y: m.y + offset.height + header + CGFloat(index) * row + row / 2)
    }
    static func color(_ type: PortType) -> Color {
        switch type {
        case .audio: Theme.accent
        case .control: Theme.macroMap
        case .event: Theme.midiMap
        case .clock: Theme.automationDot
        case .data: Theme.dim
        }
    }
}

private struct CableDrag {
    var from: String
    var port: String
    var type: PortType
    var point: CGPoint
}

struct PatchCanvas: View {
    @Binding var doc: PatchDocument
    @Binding var selected: String?
    let commit: (PatchEdit) -> Void
    /// A new module of a kind at a point on the canvas (the background menu).
    let add: (String, CGPoint) -> Void
    /// Rename the selected module: the inspector's label field takes the focus.
    let rename: () -> Void
    @State private var dragOffsets: [String: CGSize] = [:]
    @State private var cableDrag: CableDrag?
    /// Where the pointer was last seen, in canvas coordinates: the place for a module added by the menu.
    @State private var pointer: CGPoint = CGPoint(x: 60, y: 60)

    private var feedback: Set<PatchCable> { PatchGraphCompiler.feedback(in: doc) }

    private var canvasSize: CGSize {
        let w = (doc.modules.map { $0.x }.max() ?? 0) + PatchLayout.width + 200
        let h = (doc.modules.map { $0.y + Double(PatchLayout.height($0)) }.max() ?? 0) + 200
        return CGSize(width: max(900, w), height: max(600, h))
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Theme.panel
                    .contentShape(Rectangle())
                    .onTapGesture { selected = nil }
                    .contextMenu { addMenu }
                cables
                cableHits
                ForEach(doc.modules) { m in
                    PatchModuleView(module: m, doc: doc, selected: selected == m.id, offset: dragOffsets[m.id] ?? .zero,
                                    cableType: cableDrag?.type,
                                    select: { selected = m.id }, commit: commit,
                                    rename: { selected = m.id; rename() },
                                    moved: { translation in dragOffsets[m.id] = translation },
                                    dropped: { translation in
                                        dragOffsets[m.id] = nil
                                        guard translation != .zero else { return }
                                        commit(.move(id: m.id, x: max(0, m.x + translation.width).rounded(), y: max(0, m.y + translation.height).rounded()))
                                    },
                                    cableStarted: { port, type, point in cableDrag = CableDrag(from: m.id, port: port, type: type, point: point) },
                                    cableMoved: { point in cableDrag?.point = point },
                                    cableEnded: { point in endCable(at: point) })
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .coordinateSpace(name: "canvas")
            .onContinuousHover(coordinateSpace: .named("canvas")) { phase in
                if case .active(let p) = phase { pointer = p }
            }
        }
        .background(Theme.panel)
        .focusable()
        .onDeleteCommand { if let selected { commit(.remove(id: selected)); self.selected = nil } }
    }

    private var cables: some View {
        Canvas { context, _ in
            let feedback = self.feedback
            for cable in doc.cables {
                guard let (from, to) = endpoints(cable), let a = doc.module(cable.from),
                      let port = PatchModules.ports(of: a).outputs.first(where: { $0.name == cable.fromPort }) else { continue }
                let color = PatchLayout.color(port.type)
                context.stroke(path(from, to), with: .color(color.opacity(0.9)), lineWidth: 1.5)
                if feedback.contains(cable) {
                    // One frame of delay on the cable that closes a loop.
                    let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
                    let r = CGRect(x: mid.x - 9, y: mid.y - 7, width: 18, height: 14)
                    context.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(Theme.panelRaised))
                    context.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(color), lineWidth: 1)
                    context.draw(Text("z⁻¹").font(.system(size: 8, weight: .semibold)).foregroundStyle(color), at: mid)
                }
            }
            if let drag = cableDrag, let a = doc.module(drag.from),
               let oi = PatchModules.ports(of: a).outputs.firstIndex(where: { $0.name == drag.port }) {
                let from = PatchLayout.outputPoint(a, index: oi)
                context.stroke(path(from, drag.point), with: .color(PatchLayout.color(drag.type).opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        }
        .allowsHitTesting(false)
    }

    /// The Add Module menu of the canvas: the module lands where the pointer was.
    @ViewBuilder private var addMenu: some View {
        let at = pointer
        ForEach(PatchModules.categories, id: \.self) { category in
            Menu(category) {
                ForEach(PatchModules.all.filter { $0.category == category }) { spec in
                    Button(spec.name) { add(spec.id, at) }
                        .disabled(spec.single && doc.modules.contains { $0.kind == spec.id })
                }
            }
        }
    }

    /// An invisible stroke over every cable, so a right-click on a cable finds it.
    private var cableHits: some View {
        ForEach(doc.cables, id: \.self) { cable in
            if let (from, to) = endpoints(cable) {
                let p = path(from, to)
                p.stroke(.clear, lineWidth: 10)
                    .contentShape(p.strokedPath(StrokeStyle(lineWidth: 10)))
                    .contextMenu {
                        Text("\(cable.from).\(cable.fromPort) → \(cable.to).\(cable.toPort)")
                        Button("Remove Cable") { commit(.disconnect(from: cable.from, fromPort: cable.fromPort, to: cable.to, toPort: cable.toPort)) }
                    }
            }
        }
    }

    private func endpoints(_ cable: PatchCable) -> (CGPoint, CGPoint)? {
        guard let a = doc.module(cable.from), let b = doc.module(cable.to) else { return nil }
        let pa = PatchModules.ports(of: a), pb = PatchModules.ports(of: b)
        guard let oi = pa.outputs.firstIndex(where: { $0.name == cable.fromPort }),
              let ii = pb.inputs.firstIndex(where: { $0.name == cable.toPort }) else { return nil }
        return (PatchLayout.outputPoint(a, index: oi, offset: dragOffsets[a.id] ?? .zero),
                PatchLayout.inputPoint(b, index: ii, offset: dragOffsets[b.id] ?? .zero))
    }

    private func path(_ a: CGPoint, _ b: CGPoint) -> Path {
        var p = Path()
        p.move(to: a)
        let dx = max(40, abs(b.x - a.x) / 2)
        p.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y), control2: CGPoint(x: b.x - dx, y: b.y))
        return p
    }

    /// The input dot under the pointer when a cable is let go: within 14 points.
    private func endCable(at point: CGPoint) {
        defer { cableDrag = nil }
        guard let drag = cableDrag else { return }
        var best: (module: String, port: String, distance: CGFloat)?
        for m in doc.modules where m.id != drag.from {
            for (i, port) in PatchModules.ports(of: m).inputs.enumerated() {
                let p = PatchLayout.inputPoint(m, index: i)
                let d = hypot(p.x - point.x, p.y - point.y)
                if d < 14, d < (best?.distance ?? .infinity) { best = (m.id, port.name, d) }
            }
        }
        guard let best else { return }
        commit(.connect(from: drag.from, fromPort: drag.port, to: best.module, toPort: best.port))
    }
}

private struct PatchModuleView: View {
    let module: PatchModule
    let doc: PatchDocument
    let selected: Bool
    let offset: CGSize
    /// The type of the cable being dragged, while one is: input dots that cannot take it dim.
    let cableType: PortType?
    let select: () -> Void
    let commit: (PatchEdit) -> Void
    let rename: () -> Void
    let moved: (CGSize) -> Void
    let dropped: (CGSize) -> Void
    let cableStarted: (String, PortType, CGPoint) -> Void
    let cableMoved: (CGPoint) -> Void
    let cableEnded: (CGPoint) -> Void

    /// The output port whose cable is being dragged out, while the drag lasts.
    @State private var cabling: String?
    @State private var hovering = false
    @State private var dragging = false

    private var ports: (inputs: [ModulePort], outputs: [ModulePort]) { PatchModules.ports(of: module) }
    private var isScript: Bool { module.kind == "script" }

    var body: some View {
        let ports = self.ports
        let rows = max(1, max(ports.inputs.count, ports.outputs.count))
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(PatchModules.label(module)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if module.isOnPanel {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 9)).foregroundStyle(Theme.accent)
                        .hint("On the panel: its knobs show on the device.")
                }
                if hovering {
                    Button { commit(.remove(id: module.id)) } label: {
                        Image(systemName: "trash").font(.system(size: 9)).foregroundStyle(Theme.dim)
                    }
                    .buttonStyle(.plain).hint("Remove the module and its cables.")
                }
            }
            .padding(.horizontal, 6).frame(height: PatchLayout.header)
            .background(headerColor)
            .contentShape(Rectangle())
            // One gesture for a click and a drag on the title: a click selects, a drag selects and moves.
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                .onChanged { v in
                    if !dragging { dragging = true; select() }
                    moved(v.translation)
                }
                .onEnded { v in
                    dragging = false
                    let far = hypot(v.translation.width, v.translation.height) >= 2
                    dropped(far ? v.translation : .zero)
                })
            ForEach(0..<rows, id: \.self) { i in
                HStack(spacing: 0) {
                    if i < ports.inputs.count { inputRow(ports.inputs[i], index: i) } else { Spacer() }
                    Spacer(minLength: 4)
                    if i < ports.outputs.count { outputRow(ports.outputs[i], index: i) }
                }
                .frame(height: PatchLayout.row)
            }
            Spacer(minLength: 0)
        }
        .frame(width: PatchLayout.width, height: PatchLayout.height(module))
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Theme.text : Theme.line, lineWidth: selected ? 1.5 : 1))
        .offset(x: module.x + offset.width, y: module.y + offset.height)
        .onTapGesture { select() }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename…") { rename() }.keyboardShortcut("r", modifiers: .command)
            Button(module.isOnPanel ? "Take off the Panel" : "Put on the Panel") { commit(.expose(id: module.id, on: !module.isOnPanel)) }
                .disabled(module.kind == "in" || module.kind == "out" || module.kind == "clock")
            let cables = doc.cables.filter { $0.from == module.id || $0.to == module.id }
            if !cables.isEmpty {
                Menu("Disconnect") {
                    ForEach(cables, id: \.self) { c in
                        Button("\(c.from).\(c.fromPort) → \(c.to).\(c.toPort)") { commit(.disconnect(from: c.from, fromPort: c.fromPort, to: c.to, toPort: c.toPort)) }
                    }
                }
            }
            Button("Remove") { commit(.remove(id: module.id)) }
        }
        .hint(PatchModules.spec(module.kind)?.help ?? module.kind)
    }

    private var headerColor: Color {
        switch module.kind {
        case "in", "out", "clock": Theme.accent.opacity(0.35)
        case "knob", "toggle", "meter": Theme.macroMap.opacity(0.3)
        case "script": Theme.midiMap.opacity(0.3)
        default: Theme.panel
        }
    }

    private func inputRow(_ port: ModulePort, index: Int) -> some View {
        let cables = doc.cables(into: module.id, port: port.name)
        let takes = cableType.map { PortType.connects($0, to: port.type) } ?? true
        return HStack(spacing: 3) {
            Circle().fill(cables.isEmpty ? Theme.panel : PatchLayout.color(port.type))
                .overlay(Circle().stroke(PatchLayout.color(port.type), lineWidth: 1))
                .frame(width: PatchLayout.dot, height: PatchLayout.dot)
                .scaleEffect(cableType != nil && takes ? 1.4 : 1)
                .opacity(takes ? 1 : 0.25)
                .offset(x: -PatchLayout.dot / 2)
                .contextMenu {
                    ForEach(cables, id: \.self) { c in
                        Button("Disconnect \(c.from).\(c.fromPort)") { commit(.disconnect(from: c.from, fromPort: c.fromPort, to: c.to, toPort: c.toPort)) }
                    }
                }
            Text(port.name).font(.system(size: 9)).foregroundStyle(Theme.text).lineLimit(1)
            if cables.isEmpty, module.kind != "script" || port.type == .control {
                Text(valueText(port)).font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.dim).lineLimit(1)
            }
        }
    }

    private func valueText(_ port: ModulePort) -> String {
        let v = module.values[port.name] ?? port.def
        if port.isNote { return NoteDivision.at(v).name }
        let text = v == v.rounded() && abs(v) < 1e6 ? String(Int(v)) : String(format: "%.3g", v)
        return port.unit.isEmpty ? text : "\(text) \(port.unit)"
    }

    private func outputRow(_ port: ModulePort, index: Int) -> some View {
        HStack(spacing: 3) {
            Text(port.name).font(.system(size: 9)).foregroundStyle(Theme.text).lineLimit(1)
            Circle().fill(PatchLayout.color(port.type))
                .frame(width: PatchLayout.dot, height: PatchLayout.dot)
                .offset(x: PatchLayout.dot / 2)
                .contentShape(Circle().scale(2.5))
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                    .onChanged { v in
                        if cabling != port.name {
                            cabling = port.name
                            cableStarted(port.name, port.type, v.location)
                        }
                        cableMoved(v.location)
                    }
                    .onEnded { v in
                        cabling = nil
                        cableEnded(v.location)
                    })
                .hint("Drag to an input dot to cable it.")
        }
    }
}

// MARK: The inspector

struct PatchInspector: View {
    @Environment(AppModel.self) private var model
    let doc: PatchDocument
    let selected: String?
    /// Counts up on ⌘R: the label field of the selected module takes the focus.
    let renameRequest: Int
    let commit: (PatchEdit) -> Void

    var body: some View {
        ScrollView {
            if let id = selected, let m = doc.module(id), let spec = PatchModules.spec(m.kind) {
                ModuleInspector(module: m, spec: spec, doc: doc, renameRequest: renameRequest, commit: commit)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select a module").font(.system(size: 12, weight: .semibold))
                    Text("Click a module to see its values. Drag a title to move it, drag an output dot to an input dot to cable it. Right-click a cable to remove it, right-click the canvas to add a module. ⌘R renames, Delete removes the selected module.")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim)
                    Text("Modules on the panel show their free inputs as knobs on the device: automation, macros and MIDI learn work on them.")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim)
                    Text("A cable that closes a loop gets one frame of delay, marked z⁻¹.")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim)
                }
                .padding(12)
            }
        }
        .background(Theme.panelRaised)
    }
}

private struct ModuleInspector: View {
    let module: PatchModule
    let spec: ModuleSpec
    let doc: PatchDocument
    let renameRequest: Int
    let commit: (PatchEdit) -> Void
    @State private var label = ""
    @State private var scriptText = ""
    @State private var loadedID = ""
    @FocusState private var labelFocused: Bool

    private var ports: (inputs: [ModulePort], outputs: [ModulePort]) { PatchModules.ports(of: module) }
    private var canExpose: Bool { !["in", "out", "clock"].contains(module.kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                TextField("Label", text: $label, prompt: Text(spec.name))
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, weight: .semibold))
                    .focused($labelFocused)
                    .onSubmit { commit(.setLabel(id: module.id, label: label)); labelFocused = false }
                    .onChange(of: labelFocused) { _, focused in
                        if !focused, label != (module.label ?? "") { commit(.setLabel(id: module.id, label: label)) }
                    }
                Text("\(spec.name) · \(module.id)").font(.system(size: 10)).foregroundStyle(Theme.dim)
                Text(spec.help).font(.system(size: 10)).foregroundStyle(Theme.dim)
            }
            if canExpose {
                Toggle("On the panel", isOn: Binding(get: { module.isOnPanel }, set: { commit(.expose(id: module.id, on: $0)) }))
                    .font(.system(size: 11))
                    .hint("The free inputs of this module show as knobs on the device card.")
            }
            if module.kind == "knob" { knobFields }
            if module.kind == "toggle" {
                Toggle("On by default", isOn: Binding(get: { (module.values["def"] ?? 0) > 0.5 }, set: { commit(.setValue(id: module.id, key: "def", value: $0 ? 1 : 0)) }))
                    .font(.system(size: 11))
            }
            if module.kind == "const" { field("Value", key: "value", def: 1) }
            if module.kind == "delay" || module.kind == "delaysync" { field("Length (s)", key: "length", def: spec.numbers["length"] ?? 2) }
            ForEach(spec.settings, id: \.key) { s in
                HStack {
                    Text(s.key.capitalized).font(.system(size: 11)).frame(width: 70, alignment: .leading)
                    Picker("", selection: Binding(get: { module.settings[s.key] ?? s.def }, set: { commit(.setSetting(id: module.id, key: s.key, value: $0)) })) {
                        ForEach(s.choices, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().controlSize(.small)
                }
            }
            let free = ports.inputs.filter { doc.cables(into: module.id, port: $0.name).isEmpty && (module.kind != "script" || $0.type == .control) }
            if !free.isEmpty {
                Text("Inputs without a cable").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.dim)
                ForEach(free, id: \.name) { port in
                    if port.isNote {
                        HStack {
                            Text(port.name).font(.system(size: 11)).frame(width: 70, alignment: .leading)
                            Picker("", selection: Binding(get: { Int((module.values[port.name] ?? port.def).rounded()) },
                                                          set: { commit(.setValue(id: module.id, key: port.name, value: Double($0))) })) {
                                ForEach(Array(NoteDivision.all.enumerated()), id: \.offset) { Text($0.element.name).tag($0.offset) }
                            }
                            .labelsHidden().controlSize(.small)
                        }
                    } else {
                        field("\(port.name)\(port.unit.isEmpty ? "" : " (\(port.unit))")", key: port.name, def: port.def)
                    }
                }
            }
            if module.kind == "script" { scriptEditor }
            let connections = doc.cables.filter { $0.from == module.id || $0.to == module.id }
            if !connections.isEmpty {
                Text("Cables").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.dim)
                ForEach(connections, id: \.self) { c in
                    HStack {
                        Text("\(c.from).\(c.fromPort) → \(c.to).\(c.toPort)").font(.system(size: 10, design: .monospaced)).lineLimit(1)
                        Spacer()
                        Button { commit(.disconnect(from: c.from, fromPort: c.fromPort, to: c.to, toPort: c.toPort)) } label: {
                            Image(systemName: "xmark").font(.system(size: 9))
                        }
                        .buttonStyle(.plain).hint("Disconnect")
                    }
                }
            }
            Button("Remove Module") { commit(.remove(id: module.id)) }.controlSize(.small)
        }
        .padding(12)
        .onAppear { sync() }
        .onChange(of: module.id) { sync() }
        .onChange(of: renameRequest) { labelFocused = true }
        .onChange(of: module.source) { if scriptText == (loadedSourceText ?? "") { scriptText = module.source ?? "" }; loadedSourceText = module.source }
    }

    @State private var loadedSourceText: String?

    private func sync() {
        label = module.label ?? ""
        scriptText = module.source ?? ""
        loadedSourceText = module.source
        loadedID = module.id
    }

    private var knobFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            field("Min", key: "min", def: 0)
            field("Max", key: "max", def: 1)
            field("Default", key: "def", def: 0.5)
            HStack {
                Text("Unit").font(.system(size: 11)).frame(width: 70, alignment: .leading)
                Picker("", selection: Binding(get: { module.settings["unit"] ?? "" }, set: { commit(.setSetting(id: module.id, key: "unit", value: $0)) })) {
                    ForEach(["", "Hz", "ms", "s", "dB", "%", "st", "note"], id: \.self) { Text($0.isEmpty ? "none" : $0).tag($0) }
                }
                .labelsHidden().controlSize(.small)
            }
            Toggle("Logarithmic", isOn: Binding(get: { (module.values["log"] ?? 0) > 0.5 }, set: { commit(.setValue(id: module.id, key: "log", value: $0 ? 1 : 0)) }))
                .font(.system(size: 11)).hint("A log knob needs a min above 0.")
        }
    }

    private func field(_ title: String, key: String, def: Double) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).frame(width: 70, alignment: .leading).lineLimit(1)
            NumberField(value: module.values[key] ?? def) { commit(.setValue(id: module.id, key: key, value: $0)) }
        }
    }

    private var scriptDirty: Bool { scriptText != (module.source ?? "") }
    /// The text compiled on its own, for the error line. In the graph its names are bound to the cables.
    private var scriptResult: Result<PatchProgram, PatchError> { PatchCompiler.cached(scriptText) }

    private var scriptEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Text").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.dim)
                Spacer()
                Menu("Examples") {
                    ForEach(PatchExamples.all, id: \.name) { example in
                        Button(example.name) {
                            scriptText = example.source
                            commit(.setSource(id: module.id, source: example.source))
                        }
                    }
                }
                .menuStyle(.borderlessButton).controlSize(.mini).fixedSize()
                .hint("Put an example text on this module. Cables to ports that stay keep.")
                Button("Revert") { scriptText = module.source ?? "" }.controlSize(.mini).disabled(!scriptDirty)
                Button("Apply") { commit(.setSource(id: module.id, source: scriptText)) }
                    .keyboardShortcut(.return, modifiers: .command).controlSize(.mini).buttonStyle(.borderedProminent)
                    .disabled(!scriptDirty || !scriptCompiles)
                    .hint("Put the text on the module (⌘↩). Its in, out and param lines are its ports.")
            }
            TextEditor(text: $scriptText)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Theme.panel)
                .autocorrectionDisabled()
                .frame(minHeight: 220)
            switch scriptResult {
            case .success: EmptyView()
            case .failure(let e): Text(e.description).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.automationDot).lineLimit(3)
            }
        }
    }

    private var scriptCompiles: Bool { if case .success = scriptResult { true } else { false } }
}

/// A small number field. It commits on Return or when the focus leaves.
private struct NumberField: View {
    let value: Double
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("0", text: $text)
            .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced)).frame(width: 90)
            .focused($focused)
            .onSubmit { apply() }
            .onChange(of: focused) { _, now in if !now { apply() } }
            .onAppear { text = Self.format(value) }
            .onChange(of: value) { if !focused { text = Self.format(value) } }
    }

    private static func format(_ v: Double) -> String { v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : String(format: "%.4g", v) }

    private func apply() {
        guard let v = Double(text.replacingOccurrences(of: ",", with: ".")), v.isFinite else { text = Self.format(value); return }
        if v != value { commit(v) }
        text = Self.format(v)
    }
}
