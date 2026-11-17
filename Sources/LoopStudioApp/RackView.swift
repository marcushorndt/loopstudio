import LoopStudioCore
import SwiftUI

// MARK: Environment: the racks a view sits in

private struct EnclosingRacksKey: EnvironmentKey {
    static let defaultValue: [DeviceID] = []
}

extension EnvironmentValues {
    /// The racks around the device being drawn, outermost first. A knob inside a rack can hang on its macros.
    var enclosingRacks: [DeviceID] {
        get { self[EnclosingRacksKey.self] }
        set { self[EnclosingRacksKey.self] = newValue }
    }
}

private let groupGap = DeviceLayout.groupGap

// MARK: The rack card body

/// The body of a rack card: the panel switches at the left, the eight macro knobs, and the chain list with
/// its zone editor. The devices of the shown chain follow the card in `ChainDevicesStrip`.
struct RackBody: View {
    @Environment(AppModel.self) private var model
    @Environment(\.enclosingRacks) private var racks
    let track: Track
    let device: DeviceSlot
    let spec: EffectSpec

    private var tint: Color { Theme.track(track.colorIndex) }
    private var rack: Rack { device.rack ?? Rack() }
    private var showsMacros: Bool { model.rackPanelShown(device.id, macros: true) }
    private var showsChains: Bool { model.rackPanelShown(device.id, macros: false) }
    private var mapping: Bool { model.macroMap?.rack == device.id }

    var body: some View {
        HStack(alignment: .top, spacing: groupGap) {
            sideButtons
            if showsMacros { macroPanel }
            if showsChains {
                ChainPanel(track: track, device: device)
                    // The chain mixer and the selector belong to this rack: its own macros can drive them.
                    .environment(\.enclosingRacks, racks + [device.id])
            }
            if !showsMacros && !showsChains {
                Text("\(rack.chains.count) chain\(rack.chains.count == 1 ? "" : "s") · \(rack.mappings.count) mapping\(rack.mappings.count == 1 ? "" : "s")")
                    .font(.system(size: 10)).foregroundStyle(Theme.dim).frame(height: 40)
            }
        }
    }

    /// Live's three switches at the left edge of a rack: macros, chains, and map mode.
    private var sideButtons: some View {
        VStack(spacing: 4) {
            sideButton("dial.medium", on: showsMacros, hint: showsMacros ? "Hide the macro knobs" : "Show the macro knobs") {
                model.toggleRackPanel(device.id, macros: true)
            }
            sideButton("list.bullet", on: showsChains, hint: showsChains ? "Hide the chain list" : "Show the chain list") {
                model.toggleRackPanel(device.id, macros: false)
            }
            sideButton("scope", on: mapping, tint: Theme.macroMap, hint: mapping ? "Leave map mode" : "Map mode: click a macro, then a knob inside the rack") {
                if mapping { model.endMacroMap() } else { model.toggleMacroMap(track: track.id, rack: device.id, macro: model.macroMap?.macro ?? 0) }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 22)
    }

    private func sideButton(_ icon: String, on: Bool, tint: Color = Theme.accent, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(on ? Theme.text : Theme.dim)
                .frame(width: 22, height: 22)
                .background(on ? tint.opacity(0.35) : Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(on ? tint.opacity(0.7) : Theme.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hint(hint)
    }

    private var macroPanel: some View {
        VStack(alignment: .leading, spacing: groupGap) {
            KnobSection(title: "Macros") {
                ForEach(0..<4, id: \.self) { MacroKnob(track: track, device: device, spec: spec, index: $0) }
            }
            KnobSection(title: " ") {
                ForEach(4..<Rack.macroCount, id: \.self) { MacroKnob(track: track, device: device, spec: spec, index: $0) }
            }
        }
    }
}

// MARK: Macro knobs

/// One macro knob: its own name, a badge with the count of what it drives, and the map and mapping menus.
/// In map mode a click makes it the waiting macro.
struct MacroKnob: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let device: DeviceSlot
    let spec: EffectSpec
    let index: Int
    @State private var renaming = false
    @State private var name = ""
    @State private var editing = false

    private var key: String { "macro\(index + 1)" }
    private var rack: Rack { device.rack ?? Rack() }
    /// The spec's "Macro n" with the name the user gave it.
    private func named(_ base: EffectParam) -> EffectParam { var p = base; p.name = rack.macroName(index); return p }
    private var mappings: [MacroMapping] { rack.mappings.filter { $0.macro == index } }
    private var waiting: Bool { model.macroMap == MacroMapSession(track: track.id, rack: device.id, macro: index) }
    private var inMapMode: Bool { model.macroMap?.rack == device.id }

    var body: some View {
        if let base = spec.param(key) {
            let param = named(base)
            let address = ParameterAddress(node: device.id.rawValue, parameter: key)
            let driven = model.macroDriving(address, on: track)
            Knob(param: param, value: driven?.value ?? (device.params[key] ?? param.def), tint: Theme.macroMap,
                 onChange: { model.setDeviceParam(track.id, device.id, key, param.clamp($0)) },
                 onReset: { model.setDeviceParam(track.id, device.id, key, nil) },
                 automation: automation(param), automated: model.automatedValue(track, address))
            .allowsHitTesting(driven == nil)
            .overlay(alignment: .topLeading) {
                if !mappings.isEmpty {
                    Button { editing = true } label: {
                        Text("\(mappings.count)").font(.system(size: 8, weight: .bold)).foregroundStyle(.black)
                            .padding(.horizontal, 4).frame(height: 12)
                            .background(Theme.macroMap, in: Capsule())
                            .padding(3).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hint("\(rack.macroName(index)) drives \(mappings.count) parameter\(mappings.count == 1 ? "" : "s"). Click to edit the ranges.")
                    .popover(isPresented: $editing) { MacroMappingsEditor(track: track, device: device, macro: index) }
                }
            }
            .overlay(alignment: .topTrailing) {
                if let driven { MacroBadge(track: track, address: address, driving: driven) }
            }
            .overlay {
                // Map mode: a click picks this macro as the target; the waiting one glows.
                if inMapMode {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(waiting ? Theme.macroMap : Theme.macroMap.opacity(0.35), lineWidth: waiting ? 2 : 1)
                        .background(Theme.macroMap.opacity(waiting ? 0.18 : 0.05), in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .onTapGesture { model.toggleMacroMap(track: track.id, rack: device.id, macro: index) }
                        .hint(waiting ? "\(rack.macroName(index)) waits for a knob. Click a knob inside the rack to map it." : "Click to map knobs to \(rack.macroName(index)).")
                }
            }
            .contextMenu {
                Button(waiting ? "Leave Map Mode" : "Map Knobs to \(rack.macroName(index))…") { model.toggleMacroMap(track: track.id, rack: device.id, macro: index) }
                Button("Edit Mappings… (\(mappings.count))") { editing = true }.disabled(mappings.isEmpty)
                Button("Clear Mappings") {
                    model.apply(.batch(commands: mappings.map { .removeMacroMapping(track: track.id, rack: device.id, mapping: $0.id) }))
                }
                .disabled(mappings.isEmpty)
                Divider()
                Button("Rename Macro…") { name = rack.macroName(index); renaming = true }
                let auto = automation(param)
                Button(auto.laneShown ? "Hide Automation Curve" : "Show Automation Curve", action: auto.toggleLane)
                Button("Clear Automation", action: auto.clear).disabled(!auto.hasCurve)
                Button("Reset to Default") { model.setDeviceParam(track.id, device.id, key, nil) }
            }
            .popover(isPresented: $renaming) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Macro \(index + 1) name").font(.caption).foregroundStyle(Theme.dim)
                    TextField("Macro \(index + 1)", text: $name)
                        .textFieldStyle(.roundedBorder).frame(width: 180)
                        .onSubmit { model.renameMacro(index, to: name, rack: device.id, on: track.id); renaming = false }
                }
                .padding(12)
            }
            .midiLearnable(.deviceParam(track.id, device.id, key))
            .macroMappable(address, track: track)
        }
    }

    private func automation(_ param: EffectParam) -> KnobAutomation {
        model.knobAutomation(track, ParameterAddress(node: device.id.rawValue, parameter: param.key))
    }
}

/// The badge on a knob a macro drives: which macro, and the way out.
struct MacroBadge: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let address: ParameterAddress
    let driving: (rack: DeviceSlot, mapping: MacroMapping, value: Double)
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            Text("M\(driving.mapping.macro + 1)").font(.system(size: 8, weight: .bold)).foregroundStyle(.black)
                .padding(.horizontal, 3).frame(height: 12)
                .background(Theme.macroMap, in: RoundedRectangle(cornerRadius: 3))
                .padding(3).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hint("Follows \(driving.rack.rack?.macroName(driving.mapping.macro) ?? "a macro") of \(driving.rack.name). Click for the range; right-click to unmap.")
        .contextMenu {
            Button("Edit Mapping…") { editing = true }
            Button("Unmap") { model.unmap(address, on: track) }
        }
        .popover(isPresented: $editing) { MacroMappingsEditor(track: track, device: driving.rack, macro: driving.mapping.macro) }
    }
}

// MARK: Map mode on knobs

/// In macro map mode a knob inside the waiting rack gets a green cover: a click hangs it on the macro.
private struct MacroMappable: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.enclosingRacks) private var racks
    let address: ParameterAddress
    let track: Track

    func body(content: Content) -> some View {
        let session = model.macroMap
        let reachable = session.map { racks.contains($0.rack) && $0.track == track.id } ?? false
        content.overlay {
            if reachable {
                let mapped = model.macroDriving(address, on: track)
                ZStack {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.macroMap.opacity(mapped == nil ? 0.2 : 0.4))
                    RoundedRectangle(cornerRadius: 3).stroke(Theme.macroMap, lineWidth: 1)
                    if let mapped {
                        Text("M\(mapped.mapping.macro + 1)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 3).background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 2))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { model.mapToMacro(address) }
                .contextMenu {
                    Button("Map to the Waiting Macro") { model.mapToMacro(address) }
                    Button("Unmap") { model.unmap(address, on: track) }.disabled(mapped == nil)
                }
                .hint(mapped == nil ? "Click to hang this knob on the waiting macro." : "Mapped to macro \(mapped!.mapping.macro + 1). Click to move it to the waiting macro.")
            }
        }
    }
}

extension View {
    /// A knob a rack's macro can drive. Shows the map-mode cover when its rack waits for a knob.
    func macroMappable(_ address: ParameterAddress, track: Track) -> some View { modifier(MacroMappable(address: address, track: track)) }
}

// MARK: Mapping editor

/// The mappings of one macro: what it drives, and the range and curve of each. Live's mapping browser.
struct MacroMappingsEditor: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let device: DeviceSlot
    let macro: Int

    private var current: DeviceSlot { model.project.track(track.id)?.device(device.id) ?? device }
    private var mappings: [MacroMapping] { current.rack?.mappings.filter { $0.macro == macro } ?? [] }
    private var liveTrack: Track { model.project.track(track.id) ?? track }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(current.rack?.macroName(macro) ?? "Macro \(macro + 1)") · \(current.name)").font(.system(size: 12, weight: .semibold))
            if mappings.isEmpty {
                Text("Nothing mapped. Use map mode: click the macro, then a knob inside the rack.").font(.caption).foregroundStyle(Theme.dim)
            }
            ForEach(mappings) { m in
                let target = model.project.automationTarget(m.target, on: liveTrack)
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target?.name ?? m.target.parameter).font(.system(size: 11, weight: .medium)).lineLimit(2)
                        Text(rangeText(m, target)).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.dim)
                    }
                    .frame(width: 170, alignment: .leading)
                    MiniKnob(title: "Min", position: m.min, display: format(target, m.min), unit: target?.unit ?? "%",
                             parse: target.map { t in { parse(t, $0) } }) { p in
                        var c = m; c.min = p; model.setMacroMapping(c, rack: device.id, on: track.id)
                    } onReset: { var c = m; c.min = 0; model.setMacroMapping(c, rack: device.id, on: track.id) }
                    MiniKnob(title: "Max", position: m.max, display: format(target, m.max), unit: target?.unit ?? "%",
                             parse: target.map { t in { parse(t, $0) } }) { p in
                        var c = m; c.max = p; model.setMacroMapping(c, rack: device.id, on: track.id)
                    } onReset: { var c = m; c.max = 1; model.setMacroMapping(c, rack: device.id, on: track.id) }
                    MiniKnob(title: "Curve", position: (m.curve + 1) / 2, display: String(format: "%+.2f", m.curve),
                             parse: { KnobEntry.number(from: $0).map { ($0 + 1) / 2 } }) { p in
                        var c = m; c.curve = p * 2 - 1; model.setMacroMapping(c, rack: device.id, on: track.id)
                    } onReset: { var c = m; c.curve = 0; model.setMacroMapping(c, rack: device.id, on: track.id) }
                    Button { model.apply(.removeMacroMapping(track: track.id, rack: device.id, mapping: m.id)) } label: {
                        Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(Theme.dim).frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).hint("Unmap")
                }
            }
        }
        .padding(12)
        .frame(width: 420)
    }

    private func rangeText(_ m: MacroMapping, _ target: AutomationTarget?) -> String {
        "\(format(target, m.min)) → \(format(target, m.max))" + (m.max < m.min ? " (inverted)" : "")
    }

    /// A typed value in the target's own units, or a choice name, as a position (0...1).
    private func parse(_ target: AutomationTarget, _ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if !target.choices.isEmpty, let i = target.choices.firstIndex(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
            return target.position(Double(i))
        }
        return KnobEntry.number(from: t).map { target.position(min(max($0, target.min), target.max)) }
    }

    /// A position (0...1) in the target's own units.
    private func format(_ target: AutomationTarget?, _ position: Double) -> String {
        guard let target else { return String(format: "%.0f %%", position * 100) }
        let v = target.value(atPosition: position)
        if !target.choices.isEmpty { return target.choices[min(max(0, Int(v.rounded())), target.choices.count - 1)] }
        let a = abs(v)
        let text = a >= 100 ? String(format: "%.0f", v) : (a >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v))
        return target.unit.isEmpty ? text : "\(text) \(target.unit)"
    }
}

/// A small knob over a 0...1 position with its own display text. Drag up or down; double-click opens a
/// number entry, Option-double-click resets. `parse` turns a typed text into a position; without it the
/// knob reads a percentage.
struct MiniKnob: View {
    let title: String
    let position: Double
    let display: String
    var unit = ""
    var parse: ((String) -> Double?)? = nil
    let onChange: (Double) -> Void
    let onReset: () -> Void
    @State private var start: Double?
    @State private var entering = false
    @State private var entry = ""

    var body: some View {
        VStack(spacing: 2) {
            KnobDial(position: min(max(position, 0), 1), tint: Theme.macroMap, lineWidth: 3)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: KnobEntry.dragStart)
                    .onChanged { g in
                        if start == nil { start = position }
                        onChange(min(max((start ?? 0) - Double(g.translation.height) / 160, 0), 1))
                    }
                    .onEnded { _ in start = nil })
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    if NSEvent.modifierFlags.contains(.option) { onReset(); return }
                    entry = KnobEntry.digits(of: display); entering = true
                })
                .popover(isPresented: $entering, arrowEdge: .bottom) {
                    KnobEntry(title: title, unit: parse == nil ? "%" : unit, text: $entry, shown: $entering) {
                        let p = parse?(entry) ?? KnobEntry.number(from: entry).map { $0 / 100 }
                        if let p, p.isFinite { onChange(min(max(p, 0), 1)) }
                    }
                }
            Text(title).font(.system(size: 9)).foregroundStyle(Theme.dim)
            Text(display).font(.system(size: 9, design: .monospaced)).lineLimit(1)
        }
        .frame(width: 60)
        .hint("\(title): \(display). Drag up or down; double-click to type a value; Option-double-click resets.")
    }
}

// MARK: Chain list and zones

/// The chains of a rack with their mixer, and the zone editor beside them: the selector strip, or for a MIDI
/// rack also the key and velocity zones. A drag on the ruler moves the chain selector.
struct ChainPanel: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let device: DeviceSlot
    @State private var zoneView = ZoneView.chain
    @State private var renaming: ChainID?
    @State private var name = ""

    private static let listWidth: CGFloat = 196, zoneWidth: CGFloat = 170, rowHeight: CGFloat = 22
    private var rack: Rack { device.rack ?? Rack() }
    private var shown: ChainID? { model.shownChain(of: device)?.id }
    private var selector: Double { device.params["selector"] ?? 0 }
    private var selectorAddress: ParameterAddress { ParameterAddress(node: device.id.rawValue, parameter: "selector") }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            HStack(alignment: .top, spacing: 4) {
                Color.clear.frame(width: Self.listWidth, height: 14)
                ruler
            }
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(rack.chains) { chain in
                        HStack(alignment: .center, spacing: 4) {
                            ChainRow(track: track, device: device, chain: chain, shown: chain.id == shown, onRename: { name = chain.name; renaming = chain.id })
                                .frame(width: Self.listWidth)
                            ZoneBar(track: track, device: device, chain: chain, view: zoneView, selector: selector)
                                .frame(width: Self.zoneWidth, height: Self.rowHeight - 4)
                        }
                        .frame(height: Self.rowHeight)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if zoneView == .chain, !rack.chains.isEmpty {
                        // The selector as a line through every row, so the zones under it read at a glance.
                        Rectangle().fill(Theme.midiMap).frame(width: 1)
                            .offset(x: Self.listWidth + 4 + CGFloat(selector / 127) * Self.zoneWidth)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: Self.listWidth + 4 + Self.zoneWidth, height: DeviceLayout.bodyHeight)
        .popover(item: $renaming) { id in
            VStack(alignment: .leading, spacing: 8) {
                Text("Chain name").font(.caption).foregroundStyle(Theme.dim)
                TextField("Chain", text: $name).textFieldStyle(.roundedBorder).frame(width: 180)
                    .onSubmit {
                        if var c = rack.chain(id) { c.name = name; model.setChain(c, rack: device.id, on: track.id) }
                        renaming = nil
                    }
            }
            .padding(12)
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            if device.isMIDIRack {
                ForEach(ZoneView.allCases, id: \.self) { v in
                    Button { zoneView = v } label: {
                        Text(v == .chain ? "Chain" : (v == .key ? "Key" : "Vel")).font(.system(size: 9, weight: zoneView == v ? .semibold : .regular))
                            .foregroundStyle(zoneView == v ? Theme.text : Theme.dim)
                            .padding(.horizontal, 6).frame(height: 16)
                            .background(zoneView == v ? Theme.accent.opacity(0.35) : Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
                            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hint(v == .chain ? "Zones on the chain selector strip" : (v == .key ? "Which keys each chain plays" : "Which velocities each chain plays"))
                }
            } else {
                Text("CHAINS").font(.system(size: 8.5, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.dim).padding(.leading, 4)
            }
            Spacer(minLength: 4)
            Menu {
                Button("Distribute Zones Evenly") { model.distributeZones(rack: device.id, on: track.id, fade: 0) }
                Button("Distribute Zones with Crossfades") { model.distributeZones(rack: device.id, on: track.id, fade: 8) }
                Button("Every Chain on the Whole Strip") {
                    model.apply(.batch(commands: rack.chains.map { var c = $0; c.zone = .full; return .setChain(track: track.id, rack: device.id, chain: c) }))
                }
                if device.isMIDIRack {
                    Divider()
                    Button("Clear Key and Velocity Zones") { model.clearNoteZones(rack: device.id, on: track.id) }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 10)).foregroundStyle(Theme.dim).frame(width: 18, height: 16).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .hint("Zone presets")
            Button { model.addChain(to: device.id, on: track.id) } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.dim).frame(width: 18, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain).hint("Add a chain")
        }
        .frame(height: 18)
    }

    /// The scale over the zones. On the chain view it carries the selector: drag it, map it, learn it.
    private var ruler: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let marks: [Int] = zoneView == .key ? Array(stride(from: 0, through: 120, by: 12)) : [0, 32, 64, 96, 127]
                    for m in marks {
                        let x = CGFloat(m) / 127 * size.width
                        ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: size.height - 3)); $0.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(Theme.dim), lineWidth: 1)
                        let label = zoneView == .key ? MIDIControl.noteName(UInt8(m)) : "\(m)"
                        ctx.draw(Text(label).font(.system(size: 7)).foregroundStyle(Theme.dim), at: CGPoint(x: min(max(x, 8), size.width - 8), y: 4))
                    }
                }
                if zoneView == .chain {
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: 8)).foregroundStyle(Theme.midiMap)
                        .offset(x: CGFloat(selector / 127) * w - 4, y: 5)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard zoneView == .chain else { return }
                let v = min(max(Double(g.location.x / w) * 127, 0), 127)
                model.setDeviceParam(track.id, device.id, "selector", v.rounded())
            })
            .hint(zoneView == .chain ? "Chain selector: \(Int(selector)). Drag to pick the sounding chains. A macro or a MIDI knob can drive it."
                  : (zoneView == .key ? "Keys, C-2 to G8" : "Velocity, 0 to 127"))
        }
        .frame(width: Self.zoneWidth, height: 14)
        .midiLearnable(.deviceParam(track.id, device.id, "selector"))
        .macroMappable(selectorAddress, track: track)
        .opacity(zoneView == .chain ? 1 : 0.7)
    }
}

/// One chain in the list: colour, name, mute, solo, volume and pan. A click shows its devices.
private struct ChainRow: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let device: DeviceSlot
    let chain: RackChain
    let shown: Bool
    let onRename: () -> Void

    private var tint: Color { Theme.track(chain.colorIndex) }

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 6, height: 14)
            Text(chain.name).font(.system(size: 11, weight: shown ? .semibold : .regular)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { model.showChain(chain.id, of: device.id) }
                .simultaneousGesture(TapGesture(count: 2).onEnded { onRename() })
            pill("M", on: chain.mute, tint: Theme.accent) { var c = chain; c.mute.toggle(); model.setChain(c, rack: device.id, on: track.id) }
            pill("S", on: chain.solo, tint: Theme.track(5)) { var c = chain; c.solo.toggle(); model.setChain(c, rack: device.id, on: track.id) }
            ChainLevel(track: track, device: device, chain: chain)
            ChainPan(track: track, device: device, chain: chain)
        }
        .padding(.horizontal, 4)
        .frame(height: 20)
        .background(shown ? Theme.accent.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(shown ? Theme.accent.opacity(0.6) : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .hint("\(chain.name): click to show its devices to the right of the rack. Double-click renames it.")
        .contextMenu {
            Button("Show Devices") { model.showChain(chain.id, of: device.id) }
            Button("Rename…") { onRename() }
            Menu("Colour") {
                ForEach(0..<8, id: \.self) { i in
                    Button("Colour \(i + 1)" + (chain.colorIndex == i ? "  ✓" : "")) { var c = chain; c.colorIndex = i; model.setChain(c, rack: device.id, on: track.id) }
                }
            }
            Button(chain.mute ? "Unmute" : "Mute") { var c = chain; c.mute.toggle(); model.setChain(c, rack: device.id, on: track.id) }
            Button(chain.solo ? "Unsolo" : "Solo") { var c = chain; c.solo.toggle(); model.setChain(c, rack: device.id, on: track.id) }
            Button("Reset Volume and Pan") { var c = chain; c.volumeDb = 0; c.pan = 0; model.setChain(c, rack: device.id, on: track.id) }
            Divider()
            Button("Duplicate Chain") { duplicate() }
            Button("Move Up") { move(-1) }.disabled(device.rack?.chains.first?.id == chain.id)
            Button("Move Down") { move(1) }.disabled(device.rack?.chains.last?.id == chain.id)
            Divider()
            Button("Delete Chain") { model.removeChain(chain.id, from: device.id, on: track.id) }
        }
    }

    private func pill(_ label: String, on: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 9, weight: .bold)).frame(width: 14, height: 14)
                .foregroundStyle(on ? tint : Theme.dim)
                .background(on ? tint.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 2))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(on ? tint.opacity(0.55) : Theme.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hint(label == "M" ? "Mute this chain" : "Solo this chain")
    }

    private func duplicate() {
        var map: [UUID: UUID] = [:]
        var copy = chain
        copy.id = ChainID()
        copy.name += " copy"
        copy.devices = chain.devices.map { $0.withFreshIDs(map: &map) }
        guard let i = device.rack?.chains.firstIndex(where: { $0.id == chain.id }) else { return }
        model.apply(.addChain(track: track.id, rack: device.id, chain: copy, index: i + 1))
        model.showChain(copy.id, of: device.id)
    }

    private func move(_ delta: Int) {
        guard let i = device.rack?.chains.firstIndex(where: { $0.id == chain.id }) else { return }
        model.apply(.moveChain(track: track.id, rack: device.id, chain: chain.id, to: i + delta))
    }
}

/// A chain's volume as a small bar. Drag left or right; double-click resets to 0 dB.
private struct ChainLevel: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let device: DeviceSlot
    let chain: RackChain
    @State private var start: Double?

    private var address: ParameterAddress { ParameterAddress(node: chain.id.rawValue, parameter: "volume") }

    var body: some View {
        let driven = model.macroDriving(address, on: track)
        let db = driven?.value ?? chain.volumeDb
        let position = (db - RackChain.volumeRange.lowerBound) / (RackChain.volumeRange.upperBound - RackChain.volumeRange.lowerBound)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.4))
            RoundedRectangle(cornerRadius: 2).fill(Theme.track(chain.colorIndex).opacity(0.8)).frame(width: max(2, 40 * position))
            Rectangle().fill(Theme.dim.opacity(0.6)).frame(width: 1).offset(x: 40 * (0 - RackChain.volumeRange.lowerBound) / 66)
        }
        .frame(width: 40, height: 10)
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.line, lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1).onChanged { g in
            if start == nil { start = chain.volumeDb }
            var c = chain
            c.volumeDb = min(max((start ?? 0) + Double(g.translation.width) * 0.5, RackChain.volumeRange.lowerBound), RackChain.volumeRange.upperBound)
            model.setChain(c, rack: device.id, on: track.id, key: "chainvol\(chain.id)")
        }.onEnded { _ in start = nil })
        .simultaneousGesture(TapGesture(count: 2).onEnded { var c = chain; c.volumeDb = 0; model.setChain(c, rack: device.id, on: track.id) })
        .allowsHitTesting(driven == nil)
        .hint(String(format: "Chain volume: %.1f dB. Drag left or right; double-click resets.", db))
        .macroMappable(address, track: track)
    }
}

/// A chain's pan as a dot on a short line. Drag; double-click centres.
private struct ChainPan: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let device: DeviceSlot
    let chain: RackChain
    @State private var start: Double?

    private var address: ParameterAddress { ParameterAddress(node: chain.id.rawValue, parameter: "pan") }

    var body: some View {
        let driven = model.macroDriving(address, on: track)
        let pan = driven?.value ?? chain.pan
        ZStack(alignment: .leading) {
            Rectangle().fill(Theme.line).frame(height: 1)
            Circle().fill(Theme.text).frame(width: 6, height: 6).offset(x: CGFloat((pan + 1) / 2) * 22)
        }
        .frame(width: 28, height: 10)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1).onChanged { g in
            if start == nil { start = chain.pan }
            var c = chain
            c.pan = min(max((start ?? 0) + Double(g.translation.width) / 14, -1), 1)
            model.setChain(c, rack: device.id, on: track.id, key: "chainpan\(chain.id)")
        }.onEnded { _ in start = nil })
        .simultaneousGesture(TapGesture(count: 2).onEnded { var c = chain; c.pan = 0; model.setChain(c, rack: device.id, on: track.id) })
        .allowsHitTesting(driven == nil)
        .hint(pan == 0 ? "Chain pan: centre" : String(format: "Chain pan: %.0f%% %@", abs(pan) * 100, pan < 0 ? "left" : "right"))
        .macroMappable(address, track: track)
    }
}

/// One chain's zone on the strip: the span in the chain colour, the fades as slopes. Drag the body to move
/// it, an edge to resize it; hold Option at an edge to set its fade. The Option key counts when pressed
/// mid-drag too.
private struct ZoneBar: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let device: DeviceSlot
    let chain: RackChain
    let view: ZoneView
    let selector: Double
    @State private var drag: Drag?

    private enum Grip { case low, high, body, fadeLow, fadeHigh }
    private struct Drag {
        var grip: Grip
        var start: ChainZone
        var anchor: CGFloat
        var option: Bool
    }

    private var zone: ChainZone {
        switch view {
        case .chain: chain.zone
        case .key: chain.keyZone ?? .full
        case .velocity: chain.velocityZone ?? .full
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let unit = w / 128
            let z = zone.normalized
            let x0 = CGFloat(z.low) * unit, x1 = CGFloat(z.high + 1) * unit
            let tint = Theme.track(chain.colorIndex)
            let level = view == .chain ? zone.gain(at: selector) : 1
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.25))
                Canvas { ctx, size in
                    // The span with its fades as a trapezoid, so the slopes are the picture of the crossfade.
                    var path = Path()
                    path.move(to: CGPoint(x: x0, y: size.height))
                    path.addLine(to: CGPoint(x: x0 + CGFloat(z.fadeLow) * unit, y: 1))
                    path.addLine(to: CGPoint(x: x1 - CGFloat(z.fadeHigh) * unit, y: 1))
                    path.addLine(to: CGPoint(x: x1, y: size.height))
                    path.closeSubpath()
                    ctx.fill(path, with: .color(tint.opacity(0.25 + 0.55 * level)))
                    ctx.stroke(path, with: .color(tint.opacity(0.9)), lineWidth: 1)
                    // Edge grips.
                    for x in [x0, x1] {
                        ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(tint))
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(dragGesture(width: w))
            .hint(hintText)
        }
    }

    private var hintText: String {
        let z = zone.normalized
        let what = view == .chain ? "Selector zone" : (view == .key ? "Key zone" : "Velocity zone")
        let range = view == .key ? "\(MIDIControl.noteName(UInt8(z.low)))–\(MIDIControl.noteName(UInt8(z.high)))" : "\(z.low)–\(z.high)"
        let fades = z.fadeLow > 0 || z.fadeHigh > 0 ? ", fades \(z.fadeLow)/\(z.fadeHigh)" : ""
        return "\(what) of \(chain.name): \(range)\(fades). Drag to move, drag an edge to resize, Option + edge for a fade."
    }

    private func dragGesture(width w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let option = NSEvent.modifierFlags.contains(.option)
                let unit = w / 128
                if drag == nil {
                    let z = zone.normalized
                    let x0 = CGFloat(z.low) * unit, x1 = CGFloat(z.high + 1) * unit
                    let x = g.startLocation.x
                    let grip: Grip
                    if abs(x - x0) <= 6 || (x < x0 && x >= x0 - 8) { grip = option ? .fadeLow : .low }
                    else if abs(x - x1) <= 6 || (x > x1 && x <= x1 + 8) { grip = option ? .fadeHigh : .high }
                    else if x > x0 && x < x1 { grip = .body }
                    else { grip = x < x0 ? .low : .high }
                    drag = Drag(grip: grip, start: z, anchor: 0, option: option)
                }
                guard var d = drag else { return }
                // Option pressed or released mid-drag at an edge: the same edge now moves the fade (or the span).
                if option != d.option, d.grip != .body {
                    d.option = option
                    d.start = zone.normalized
                    d.anchor = g.translation.width
                    switch d.grip {
                    case .low, .fadeLow: d.grip = option ? .fadeLow : .low
                    case .high, .fadeHigh: d.grip = option ? .fadeHigh : .high
                    case .body: break
                    }
                    drag = d
                }
                let delta = Int(((g.translation.width - d.anchor) / unit).rounded())
                var z = d.start
                switch d.grip {
                case .body:
                    let span = z.high - z.low
                    z.low = min(max(z.low + delta, 0), 127 - span)
                    z.high = z.low + span
                case .low: z.low = min(max(z.low + delta, 0), z.high)
                case .high: z.high = min(max(z.high + delta, z.low), 127)
                case .fadeLow: z.fadeLow = max(0, z.fadeLow + delta)
                case .fadeHigh: z.fadeHigh = max(0, z.fadeHigh - delta)
                }
                var c = chain
                switch view {
                case .chain: c.zone = z.normalized
                case .key: c.keyZone = z.normalized
                case .velocity: c.velocityZone = z.normalized
                }
                model.setChain(c, rack: device.id, on: track.id, key: "zone\(chain.id)\(view.rawValue)")
            }
            .onEnded { _ in drag = nil }
    }
}

// MARK: The devices of the shown chain

/// The devices of a rack's shown chain, drawn after the rack card inside a tinted frame, like Live draws a
/// rack's chain to the right of its panel. A rack inside the chain draws its own strip after itself.
struct ChainDevicesStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.enclosingRacks) private var racks
    let track: Track
    let rack: DeviceSlot

    var body: some View {
        let tint = Theme.track(track.colorIndex)
        if let chain = model.shownChain(of: rack) {
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 4) {
                    Text(chain.name).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.track(chain.colorIndex)).lineLimit(1)
                        .fixedSize().rotationEffect(.degrees(90)).frame(width: 12, height: 90)
                    Spacer(minLength: 0)
                }
                .frame(width: 12).frame(maxHeight: .infinity, alignment: .top)
                ForEach(chain.devices, id: \.id) { d in
                    DeviceCard(track: track, device: d, chain: chain.id)
                    if d.isRack { ChainDevicesStrip(track: track, rack: d) }
                }
                dropSlot(chain)
            }
            .padding(6)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(tint.opacity(0.4), lineWidth: 1))
            .environment(\.enclosingRacks, racks + [rack.id])
            .dropDestination(for: String.self) { items, _ in model.dropDevices(items, on: track.id, chain: chain.id) }
        } else {
            VStack(spacing: 6) {
                Text("No chains").font(.caption).foregroundStyle(Theme.dim)
                Button("Add Chain") { model.addChain(to: rack.id, on: track.id) }.buttonStyle(.link).font(.caption)
            }
            .frame(width: 120).frame(maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
    }

    private func dropSlot(_ chain: RackChain) -> some View {
        let wantsInstrument = rack.isMIDIRack && !chain.devices.contains { model.isInstrument($0) }
        return VStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 12, weight: .medium))
            Text(wantsInstrument ? "Drop an instrument\nor an effect into\n\(chain.name)" : "Drop an effect\ninto \(chain.name)")
                .font(.system(size: 10)).multilineTextAlignment(.center)
            if wantsInstrument {
                ForEach(BuiltInInstruments.all.filter { !$0.isRack }, id: \.id) { spec in
                    Button(spec.name) { model.addEffect(spec.id, toChain: chain.id, on: track.id) }.buttonStyle(.link).font(.system(size: 10))
                }
            }
        }
        .foregroundStyle(Theme.dim)
        .frame(width: chain.devices.isEmpty ? 150 : 110)
        .frame(maxHeight: .infinity)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}
