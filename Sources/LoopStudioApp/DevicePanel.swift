import LoopStudioCore
import LoopStudioEngine
import SwiftUI

/// A rotary knob. Drag up or down to change it, double-click to reset.
/// What a knob needs to offer automation in its right-click menu.
struct KnobAutomation {
    var hasCurve: Bool
    var laneShown: Bool
    var toggleLane: () -> Void
    var clear: () -> Void
    /// The selected clip, when it can carry a lane for this parameter: its name, whether that lane holds
    /// points, and the way to open it in the clip inspector.
    var clip: ClipEntry?

    struct ClipEntry {
        var name: String
        var hasCurve: Bool
        var open: () -> Void
    }
}

/// A knob that can follow the tempo: free (ms or Hz) or a note value.
struct KnobSync {
    var synced: Bool
    /// The unit of the free value, "ms" or "Hz".
    var unit: String
    var toggle: () -> Void
}

struct Knob: View {
    let param: EffectParam
    let value: Double
    let tint: Color
    let onChange: (Double) -> Void
    let onReset: () -> Void
    /// Automation of this knob: nil hides the menu entries (a knob with no automation target).
    var automation: KnobAutomation? = nil
    /// The value a curve gives the parameter at the play position: a thin red arc on the dial, apart from
    /// the setting the knob holds. `nil` when no curve moves it now.
    var automated: Double? = nil
    var sync: KnobSync? = nil
    /// The text under the knob, in place of `param.format`: a hosted plugin gives its own strings.
    var format: ((Double) -> String)? = nil
    @State private var startPosition: Double?
    @State private var entering = false
    @State private var entry = ""

    private var rotary: Bool { param.choices.isEmpty || param.rotary }

    private func shown(_ v: Double) -> String { format?(v) ?? param.format(v) }

    /// A double-click opens the number entry; with Option held it resets the knob instead.
    private func doubleClick() {
        if NSEvent.modifierFlags.contains(.option) { onReset(); return }
        entry = param.choices.isEmpty ? KnobEntry.digits(of: shown(value)) : shown(value)
        entering = true
    }

    /// Reads the typed text: a number, with or without the unit, a comma as the decimal point, or a choice name.
    private func submitEntry() {
        let text = entry.trimmingCharacters(in: .whitespaces)
        if !param.choices.isEmpty, let i = param.choices.firstIndex(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) {
            onChange(Double(i)); return
        }
        guard let number = KnobEntry.number(from: text) else { return }
        onChange(param.clamp(number))
    }

    var body: some View {
        VStack(spacing: 3) {
            if param.isSwitch {
                OnOffSwitch(on: value >= 0.5, tint: tint) { onChange(value >= 0.5 ? 0 : 1) }
                    .frame(width: 44, height: 44)
            } else if rotary {
                KnobDial(position: param.position(value), tint: tint, automated: automated.map { param.position($0) })
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: KnobEntry.dragStart)
                    .onChanged { g in
                        if startPosition == nil { startPosition = param.position(value) }
                        onChange(param.value(atPosition: (startPosition ?? 0) - Double(g.translation.height) / 160))
                    }
                    .onEnded { _ in startPosition = nil })
                .simultaneousGesture(TapGesture(count: 2).onEnded { doubleClick() })
                // The tempo switch sits in the gap of the arc, at the bottom of the dial: every knob has that room.
                .overlay(alignment: .bottom) { if let sync { SyncToggle(sync: sync, tint: tint).offset(y: 3) } }
                .popover(isPresented: $entering, arrowEdge: .bottom) {
                    KnobEntry(title: param.name, unit: param.choices.isEmpty ? param.unit : "", text: $entry, shown: $entering, submit: submitEntry)
                }
            } else {
                Menu(shown(value)) {
                    ForEach(Array(param.choices.enumerated()), id: \.offset) { i, name in Button(name) { onChange(Double(i)) } }
                }
                .menuStyle(.borderlessButton).frame(width: 74, height: 44).font(.system(size: 11))
            }
            Text(sync == nil ? param.name : param.name.replacingOccurrences(of: " Note", with: ""))
                .font(.system(size: 10)).foregroundStyle(Theme.dim).lineLimit(1)
            if rotary {
                // The automated value stands where the setting would, in the automation colour.
                Text(shown(automated ?? value)).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                    .foregroundStyle(automated == nil ? Color.primary : Theme.automationDot)
            }
        }
        // One element per knob for VoiceOver: its name, its value, and up and down with the arrow keys.
        .accessibilityElement(children: param.isSwitch || rotary ? .ignore : .contain)
        .accessibilityLabel(param.name)
        .accessibilityValue(param.isSwitch ? (value >= 0.5 ? "On" : "Off") : shown(value))
        .accessibilityAddTraits(param.isSwitch ? .isButton : [])
        .accessibilityAction { if param.isSwitch { onChange(value >= 0.5 ? 0 : 1) } }
        .accessibilityAdjustableAction { direction in
            guard !param.isSwitch else { onChange(value >= 0.5 ? 0 : 1); return }
            // A continuous knob moves a fiftieth of its travel; a stepped one, one step.
            let step = param.choices.isEmpty ? 0.02 : 1 / Double(max(1, param.choices.count - 1))
            let position = param.position(value) + (direction == .increment ? step : -step)
            onChange(param.clamp(param.value(atPosition: min(max(position, 0), 1))))
        }
        .frame(width: 66)
        .hint(param.isSwitch ? "\(param.name): \(value >= 0.5 ? "On" : "Off"). Click to switch."
              : "\(param.name): \(shown(value)). Drag up or down; double-click to type a value; Option-double-click resets. Right-click for automation.")
        .overlay(alignment: .topTrailing) {
            if automation?.hasCurve == true {
                Circle().fill(Theme.track(0)).frame(width: 6, height: 6).padding(4).hint("Automated")
            }
        }
        .contextMenu {
            if let automation {
                Button(automation.laneShown ? "Hide Automation Curve" : "Show Automation Curve", action: automation.toggleLane)
                Button("Clear Automation", action: automation.clear).disabled(!automation.hasCurve)
                if let clip = automation.clip {
                    Button(clip.hasCurve ? "Show Clip Automation (\(clip.name))" : "Automate in Clip \(clip.name)", action: clip.open)
                }
                Divider()
            }
            if param.rotary {
                Menu("Note Value") {
                    ForEach(Array(param.choices.enumerated()), id: \.offset) { i, name in Button(name) { onChange(Double(i)) } }
                }
            }
            if let sync { Button(sync.synced ? "Free Time (\(sync.unit))" : "Follow the Tempo", action: sync.toggle) }
            Button("Reset to Default", action: onReset)
        }
    }
}

/// The number entry under a knob: a text field that Enter submits and Escape closes. The knob views share
/// its parsing, so every knob reads a typed value the same way.
struct KnobEntry: View {
    let title: String
    let unit: String
    @Binding var text: String
    @Binding var shown: Bool
    let submit: () -> Void
    @FocusState private var focused: Bool

    /// A double-click is two clicks with a little hand movement between them. A drag starts only after this
    /// much movement, so the clicks do not nudge the knob before the entry opens.
    static let dragStart: CGFloat = 2

    var body: some View {
        HStack(spacing: 4) {
            TextField(title, text: $text)
                .textFieldStyle(.roundedBorder).frame(width: 72)
                .font(.system(size: 11, design: .monospaced))
                .focused($focused)
                .onSubmit { submit(); shown = false }
                .onExitCommand { shown = false }
            if !unit.isEmpty { Text(unit).font(.system(size: 10)).foregroundStyle(Theme.dim) }
        }
        .padding(8)
        .onAppear { focused = true }
    }

    /// The number in a formatted value, without its unit: "12.5 ms" gives "12.5".
    static func digits(of formatted: String) -> String {
        String(formatted.split(separator: " ").first ?? "")
    }

    /// Reads a typed number: a comma works as the decimal point, a unit after the number is ignored.
    static func number(from text: String) -> Double? {
        var digits = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if digits.lowercased().hasPrefix("-inf") { return -.infinity }
        digits = String(digits.prefix { "0123456789.-+".contains($0) })
        return Double(digits)
    }
}

/// The drawing of a rotary knob: a 270 degree arc, filled up to `position` (0...1), and a needle.
struct KnobDial: View {
    let position: Double
    let tint: Color
    var lineWidth: CGFloat = 4
    /// The automated position (0...1): a thin red arc inside the main one, with a dot at its end. The
    /// needle keeps the setting, so the two can disagree, as they do while a curve plays.
    var automated: Double? = nil

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2 - lineWidth / 2 - 1
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let from = Angle.degrees(135), span = 270.0
            var track = Path(); track.addArc(center: c, radius: r, startAngle: from, endAngle: .degrees(135 + span), clockwise: false)
            ctx.stroke(track, with: .color(.black.opacity(0.55)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            var arc = Path(); arc.addArc(center: c, radius: r, startAngle: from, endAngle: .degrees(135 + span * position), clockwise: false)
            ctx.stroke(arc, with: .color(tint), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            let a = Angle.degrees(135 + span * position).radians
            var needle = Path(); needle.move(to: c); needle.addLine(to: CGPoint(x: c.x + cos(a) * (r - lineWidth - 2), y: c.y + sin(a) * (r - lineWidth - 2)))
            ctx.stroke(needle, with: .color(.white), style: StrokeStyle(lineWidth: max(1.5, lineWidth / 2), lineCap: .round))
            if let automated {
                let ri = r - lineWidth - 0.5
                var inner = Path(); inner.addArc(center: c, radius: ri, startAngle: from, endAngle: .degrees(135 + span * automated), clockwise: false)
                ctx.stroke(inner, with: .color(Theme.automationDot.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                let b = Angle.degrees(135 + span * automated).radians
                let p = CGPoint(x: c.x + cos(b) * ri, y: c.y + sin(b) * ri)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(Theme.automationDot))
            }
        }
    }
}

/// An On/Off setting as a switch.
struct OnOffSwitch: View {
    let on: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? tint : Color.black.opacity(0.45))
                    .overlay(Capsule().stroke(on ? tint : Theme.line, lineWidth: 1))
                Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            }
            .frame(width: 32, height: 18)
            .animation(.snappy(duration: 0.15), value: on)
        }
        .buttonStyle(.plain)
        .hint(on ? "On" : "Off")
    }
}

/// A small badge in the arc gap of a knob: the free unit, or a note when the knob follows the tempo.
/// Click to switch. The hit area is larger than the badge.
private struct SyncToggle: View {
    let sync: KnobSync
    let tint: Color

    var body: some View {
        Button(action: sync.toggle) {
            Group {
                if sync.synced { Image(systemName: "music.note") } else { Text(sync.unit) }
            }
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(sync.synced ? Color.white : Theme.dim)
            .frame(width: 24, height: 13)
            .background(sync.synced ? tint.opacity(0.85) : Theme.panelRaised, in: Capsule())
            .overlay(Capsule().stroke(sync.synced ? tint : Theme.line, lineWidth: 1))
            .padding(.horizontal, 4).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hint(sync.synced ? "Follows the tempo. Click for a free time in \(sync.unit)." : "Free time. Click to follow the tempo with a note value.")
    }
}

/// The device chain of the selected track, left to right.
struct DeviceChainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let track = model.selectedTrack.flatMap({ model.project.track($0) }) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.track(track.colorIndex)).frame(width: 8, height: 8)
                            Text(track.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 4)
                            PillMenu(label: "Automate") { AutomationLaneToggles(track: track, reveals: true) }
                        }
                        .frame(height: 22)
                        Text(kindLabel(track.kind) + " · " + (track.devices.isEmpty ? "no devices" : "\(track.devices.count) device\(track.devices.count == 1 ? "" : "s")"))
                            .font(.system(size: 10)).foregroundStyle(Theme.dim)
                    }
                    .frame(width: 230, alignment: .leading)
                    ForEach(track.devices, id: \.id) { d in
                        DeviceCard(track: track, device: d)
                        if d.isRack { ChainDevicesStrip(track: track, rack: d) }
                    }
                    emptySlot(track)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            .dropDestination(for: String.self) { items, _ in
                return model.dropDevices(items, on: track.id)
            }
            .presetNamePrompt()
        } else {
            VStack { Spacer(); Text("Select a track to see its devices.").foregroundStyle(Theme.dim); Spacer() }.frame(maxWidth: .infinity)
        }
    }

    private func kindLabel(_ kind: TrackKind) -> String {
        switch kind {
        case .audio: "Audio Track"
        case .midi: "MIDI Track"
        case .group: "Group Track"
        case .returnTrack: "Return Track"
        case .master: "Master"
        }
    }

    /// The drop target at the end of the chain. It is the only hint when the chain is empty.
    private func emptySlot(_ track: Track) -> some View {
        let instrument = track.kind == .midi && !track.devices.contains { model.isInstrument($0) }
        return VStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 14, weight: .medium))
            Text(instrument ? "Drop an instrument\nor an effect here" : "Drop an effect here")
                .font(.caption).multilineTextAlignment(.center)
            if instrument {
                ForEach(BuiltInInstruments.all, id: \.id) { spec in
                    Button(spec.name) { model.addEffect(spec.id, to: track.id) }.buttonStyle(.link).font(.caption)
                }
            }
            Button(instrument ? "Browse Instruments" : "Browse Effects") {
                model.sidebarTab = instrument ? .instruments : .effects
            }
            .buttonStyle(.link).font(.caption)
        }
        .foregroundStyle(Theme.dim)
        .frame(width: track.devices.isEmpty ? 200 : 130)
        .frame(maxHeight: .infinity)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

/// "Save Preset…" asks for the name here: an alert with a text field over the device chain.
private struct PresetNamePrompt: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var name = ""

    func body(content: Content) -> some View {
        @Bindable var model = model
        content.alert("Save Preset", isPresented: Binding(get: { model.presetPrompt != nil }, set: { if !$0 { model.presetPrompt = nil } }),
                      presenting: model.presetPrompt) { prompt in
            TextField("Name", text: $name)
            Button("Save") { model.savePreset(track: prompt.track, device: prompt.device, name: name) }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text("The settings of \(prompt.name) as a preset in the library. A preset of the same name is replaced.")
        }
        .onChange(of: model.presetPrompt) { _, prompt in if let prompt { name = prompt.name } }
    }
}

extension View {
    func presetNamePrompt() -> some View { modifier(PresetNamePrompt()) }
}

/// A drop on a device card. The card tells the delegate its width; the delegate reports which half the
/// pointer is in, so the card draws the insertion line there, and performs the drop on that side.
private struct DeviceCardDrop: DropDelegate {
    let width: CGFloat
    let side: Binding<Int>
    let perform: @MainActor @Sendable (String, Bool) -> Void

    private func update(_ info: DropInfo) {
        side.wrappedValue = info.location.x > width / 2 ? 1 : -1
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }
    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? { update(info); return DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { side.wrappedValue = 0 }

    func performDrop(info: DropInfo) -> Bool {
        side.wrappedValue = 0
        let after = info.location.x > width / 2
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        let perform = perform
        // Option at the drop: a copy of the card, like Option-drag in Live. Read now; the item loads later.
        let copy = NSEvent.modifierFlags.contains(.option)
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? NSString else { return }
            var item = String(text)
            if copy, item.hasPrefix("device:") { item = "devicecopy:" + item.dropFirst(7) }
            Task { @MainActor in perform(item, after) }
        }
        return true
    }
}

struct DeviceCard: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let device: DeviceSlot
    /// The chain this card sits in, or `nil` on the track itself.
    var chain: ChainID? = nil
    /// Where a drag over the card would land: -1 left of it, 1 right of it, 0 nothing hovers.
    @State private var dropSide = 0
    @State private var width: CGFloat = 200
    /// The page of knobs a hosted plugin with a flat parameter list shows (16 per page).
    @State private var pluginPage = 0

    /// The string the card drags: the chain and the card drop targets move the device by it.
    private var dragItem: String { "device:\(device.id.rawValue.uuidString)" }

    /// The card takes drops of effects, presets and other cards: they land left or right of it.
    private func dropTarget<V: View>(_ view: V) -> some View {
        view
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onDrop(of: [.text], delegate: DeviceCardDrop(width: width, side: $dropSide) { [track, chain, device] item, after in
                model.dropDevices([item], on: track.id, chain: chain, beside: device.id, after: after)
            })
            .overlay(alignment: dropSide < 0 ? .leading : .trailing) {
                if dropSide != 0 {
                    RoundedRectangle(cornerRadius: 1.5).fill(Theme.accent).frame(width: 3)
                        .padding(.vertical, 4).offset(x: dropSide < 0 ? -5.5 : 5.5)
                        .allowsHitTesting(false)
                }
            }
    }

    /// The body of a hosted plugin: its parameters as knobs once it is loaded.
    @ViewBuilder
    private var pluginBody: some View {
        let _ = model.pluginRevision
        if let unit = model.host.units[device.id] {
            AudioUnitKnobs(track: track, device: device, unit: unit, page: $pluginPage)
        } else if let failure = model.host.failures[device.id] {
            VStack(alignment: .leading, spacing: 6) {
                Text("Could not load").font(.caption).foregroundStyle(.red)
                Text(failure).font(.system(size: 9)).foregroundStyle(Theme.dim).lineLimit(3).frame(width: 150, alignment: .leading)
            }
            .frame(width: 170, alignment: .topLeading)
        } else {
            HStack { ProgressView().controlSize(.small); Text("Loading…").font(.caption).foregroundStyle(Theme.dim) }
                .frame(width: 170, alignment: .topLeading)
        }
    }

    /// The header items of a hosted plugin: the kind, the page switch of a flat parameter list, and the
    /// button that opens the plugin's own window.
    @ViewBuilder
    private var pluginHeader: some View {
        let _ = model.pluginRevision
        if let unit = model.host.units[device.id] {
            Text(unit.isInstrument ? "Instrument" : "AU effect").font(.system(size: 9)).foregroundStyle(Theme.dim).lineLimit(1)
            let pages = AudioUnitKnobs.pageCount(unit)
            if pages > 1 {
                HStack(spacing: 0) {
                    Button { pluginPage = (pluginPage + pages - 1) % pages } label: {
                        Image(systemName: "chevron.left").font(.system(size: 8, weight: .semibold)).frame(width: 14, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).hint("Previous page of knobs")
                    Text("\(min(pluginPage, pages - 1) + 1)/\(pages)").font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.dim)
                    Button { pluginPage = (pluginPage + 1) % pages } label: {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).frame(width: 14, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).hint("Next page of knobs")
                }
                .foregroundStyle(Theme.dim)
            }
            Button { PluginWindow.show(unit, title: device.name) } label: {
                Image(systemName: "macwindow").font(.system(size: 10)).foregroundStyle(Theme.dim)
                    .frame(width: 18, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).hint("Open the plugin's own window.")
        }
    }

    private var folded: Bool { model.foldedDevices.contains(device.id) }

    private var powerButton: some View {
        Button { model.apply(.setDeviceBypass(track: track.id, device: device.id, bypassed: !device.bypassed)) } label: {
            Image(systemName: "power").font(.system(size: 11, weight: .bold))
                .foregroundStyle(device.bypassed ? Theme.dim : Theme.accent)
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain).hint(device.bypassed ? "Turn on" : "Bypass")
        .midiLearnable(.deviceOn(track.id, device.id))
    }

    /// The card folded to a narrow strip: the power switch and the name along it. Click the name to unfold.
    private var foldedCard: some View {
        VStack(spacing: 6) {
            powerButton
            Button { model.toggleDeviceFold(device.id) } label: {
                VStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.dim)
                    Text(device.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        .fixedSize().rotationEffect(.degrees(90)).frame(width: 16, height: DeviceLayout.bodyHeight - 40)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hint("\(device.name), folded. Click to unfold.")
        }
        .padding(.vertical, 8).padding(.horizontal, 4)
        .frame(width: 28)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(selected ? Theme.text : Color.clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { click() })
        .contextMenu { DeviceMenu(track: track, device: device) }
    }

    var body: some View {
        if folded { dropTarget(foldedCard.draggable(dragItem) { dragPreview }) } else { dropTarget(openCard) }
    }

    /// What the pointer carries while a card is dragged.
    private var dragPreview: some View {
        Text(device.name).font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.accent, lineWidth: 1))
    }

    private var openCard: some View {
        let spec = device.spec
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { model.toggleDeviceFold(device.id) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.dim)
                        .frame(width: 14, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).hint("Fold \(device.name) to its title. Double-click the title does the same.")
                powerButton
                // The title is the handle: drag it to another place in the chain, or into a rack's chain.
                HStack(spacing: 0) {
                    Text(device.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture(count: 2).onEnded { model.toggleDeviceFold(device.id) })
                .draggable(dragItem) { dragPreview }
                .hint("\(device.name). Drag the title to move the device. Double-click folds it.")
                if let spec, spec.sidechain { sidechainMenu }
                if let spec, spec.isDynamics { GainReductionMeter(device: device, bands: spec.id == "multiband" ? 3 : 1) }
                if device.format == "audiounit" { pluginHeader }
                // A Patch device: the pen opens its text.
                if device.identifier == "patch", device.format == "builtin" {
                    Button { PatchEditorWindow.show(model: model, track: track.id, device: device.id) } label: {
                        Image(systemName: "pencil").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.dim)
                            .frame(width: 18, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).hint("Edit the patch: its text, with the errors. Apply is ⌘↩.")
                }
                // Presets: save the settings as a file, or bring a file in (it loads onto this device).
                Button { model.presetPrompt = PresetPrompt(track: track.id, device: device.id, name: device.name) } label: {
                    DisketteIcon().foregroundStyle(Theme.dim).frame(width: 18, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).hint("Save the settings of \(device.name) as a preset.")
                Button { model.importPresets(onto: device.id, on: track.id) } label: {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 10)).foregroundStyle(Theme.dim)
                        .frame(width: 18, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).hint("Import a preset file. One for \(device.name) loads onto it; the others go into the library.")
                Button { model.apply(.removeDevice(track: track.id, device: device.id)) } label: {
                    Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(Theme.dim)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).hint("Remove")
            }
            // Every body is `DeviceLayout.bodyHeight` tall: instruments and effects share one height, and their
            // top row of knobs sits on one line.
            Group {
                if let spec, spec.isRack {
                    RackBody(track: track, device: device, spec: spec)
                        .opacity(device.bypassed ? 0.4 : 1)
                } else if let spec, spec.isInstrument {
                    InstrumentView(track: track, device: device, spec: spec)
                        .opacity(device.bypassed ? 0.4 : 1)
                } else if let spec, spec.view == "eq" {
                    EQView(track: track, device: device, spec: spec)
                        .opacity(device.bypassed ? 0.4 : 1)
                } else if let spec, spec.id == "multiband" {
                    MultibandView(track: track, device: device, spec: spec)
                        .opacity(device.bypassed ? 0.4 : 1)
                } else if let spec, spec.view == "granulator" {
                    GranulatorView(track: track, device: device, spec: spec)
                        .opacity(device.bypassed ? 0.4 : 1)
                } else if let spec, spec.view == "patch" {
                    PatchCardView(track: track, device: device, spec: spec)
                        .opacity(device.bypassed ? 0.4 : 1)
                } else if let spec, !spec.groups.isEmpty {
                    GroupedKnobs(track: track, device: device, spec: spec)
                        .opacity(device.bypassed ? 0.4 : 1)
                } else if let spec {
                    KnobSection(title: spec.name) {
                        ForEach(spec.shownParams, id: \.key) { ParamKnob(track: track, device: device, spec: spec, key: $0.key) }
                    }
                    .opacity(device.bypassed ? 0.4 : 1)
                } else if device.format == "audiounit" {
                    pluginBody
                } else {
                    Text("Unsupported plugin format.").font(.caption).foregroundStyle(Theme.dim).frame(width: 160)
                }
            }
            .frame(height: DeviceLayout.bodyHeight, alignment: .topLeading)
        }
        .padding(8)
        // The card is as tall as the panel, like a device in Live.
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
        // A click on the card marks the device: Delete removes it, like a clip. Knobs and buttons keep their own clicks.
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(selected ? Theme.text : Color.clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { click() })
        .contextMenu { DeviceMenu(track: track, device: device) }
        .hint(selected ? "\(device.name): marked. Delete removes it, ⌘G puts the marked cards into a Rack; right-click for more."
                       : "\(device.name). Click to mark it, ⌘-click to add it to the marking, ⇧-click for a range; right-click for more.")
    }

    private var selected: Bool { model.selectedDevices.contains(device.id) }

    /// A click marks the card; ⌘ adds it to the marking, ⇧ marks the cards up to it.
    private func click() {
        let flags = NSEvent.modifierFlags
        model.selectDevice(device.id, toggle: flags.contains(.command), range: flags.contains(.shift))
    }

    /// The source a sidechain effect listens to: its own input, or another track's output.
    private var sidechainMenu: some View {
        let sources = model.project.tracks.filter { $0.id != track.id && $0.kind != .master }
        let current = device.sidechain.flatMap { model.project.track($0) }
        return Menu {
            Button("Own Input" + (device.sidechain == nil ? "  ✓" : "")) {
                model.apply(.setDeviceSidechain(track: track.id, device: device.id, source: nil))
            }
            Divider()
            ForEach(sources) { source in
                Button(source.name + (device.sidechain == source.id ? "  ✓" : "")) {
                    model.apply(.setDeviceSidechain(track: track.id, device: device.id, source: source.id))
                }
            }
            if current != nil {
                // Where the sidechain taps the source, as in Live: raw, after its devices, or after its fader.
                Divider()
                ForEach(SidechainTap.allCases, id: \.self) { tap in
                    Button(tap.name + (device.tap == tap ? "  ✓" : "")) {
                        model.apply(.setDeviceSidechainTap(track: track.id, device: device.id, tap: tap))
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                Text(current.map { "\($0.name) · \(device.tap.name)" } ?? "Own Input").font(.system(size: 10)).lineLimit(1)
            }
            .foregroundStyle(current == nil ? Theme.dim : Theme.track(current!.colorIndex))
            .padding(.horizontal, 5).frame(height: 18)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line, lineWidth: 1))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .hint("Sidechain: the signal the detector listens to. Own input, or another track: raw (Pre FX), after its devices (Post FX) or after its fader (Post Mixer). A muted or unsoloed source still feeds the sidechain.")
    }
}

/// The parameters of a hosted plugin as knobs, the same `Knob` the built-in devices use: double-click entry,
/// Option-double-click reset, automation menu, macro and MIDI map. A tree with groups shows one row per
/// group, each foldable to its title; a flat tree shows pages of 16, two rows of eight, switched from the
/// card header. A knob writes the parameter itself (`AudioUnitEffect.setParameter`); the values are read
/// again when a plugin parameter moves elsewhere and, while the transport plays, ten times a second, so
/// automation shows on the knobs.
struct AudioUnitKnobs: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let device: DeviceSlot
    let unit: AudioUnitEffect
    @Binding var page: Int

    static let perRow = 8
    static let perPage = 16

    /// Pages of a flat list; 1 for a grouped tree, which scrolls instead. A plugin that puts every parameter
    /// into one group (the Lemus machines: "GLOBAL") is a flat list too: paged, not a row of blocks.
    static func pageCount(_ unit: AudioUnitEffect) -> Int {
        let groups = unit.knobGroups()
        guard groups.count == 1 else { return 1 }
        return max(1, (groups[0].knobs.count + perPage - 1) / perPage)
    }

    var body: some View {
        let groups = unit.knobGroups()
        let flat = groups.count == 1
        let _ = model.pluginParamRevision
        TimelineView(.animation(minimumInterval: 0.1, paused: !model.transportPlaying)) { _ in
            if groups.isEmpty {
                Text("No parameters.").font(.caption).foregroundStyle(Theme.dim).frame(width: 150, alignment: .topLeading)
            } else if flat {
                flatPage(groups[0].knobs)
            } else {
                // The groups go to the right, each as blocks of two rows: the chain scrolls sideways, and the
                // body keeps its height like every other device.
                HStack(alignment: .top, spacing: DeviceLayout.groupGap) {
                    ForEach(groups, id: \.name) { group in section(group) }
                }
                .frame(height: DeviceLayout.bodyHeight, alignment: .topLeading)
            }
        }
    }

    /// One page of a flat list: two rows of eight.
    private func flatPage(_ knobs: [AUKnob]) -> some View {
        let pages = max(1, (knobs.count + Self.perPage - 1) / Self.perPage)
        let p = min(max(page, 0), pages - 1)
        let shown = Array(knobs[(p * Self.perPage)..<min(knobs.count, (p + 1) * Self.perPage)])
        let name = unit.knobGroups().first.map { $0.name.isEmpty ? device.name : $0.name } ?? device.name
        // The knobs sit inline, as in the blocks of a grouped tree: through a section's stored content
        // closure they neither took a drag nor followed the automation.
        return VStack(alignment: .leading, spacing: DeviceLayout.groupGap) {
            ForEach(Array(shown.chunked(Self.perRow).enumerated()), id: \.offset) { row in
                VStack(alignment: .leading, spacing: 0) {
                    Text((row.offset == 0 ? (pages > 1 ? "\(name) \(p + 1)/\(pages)" : name) : " ").uppercased())
                        .font(.system(size: 8.5, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.dim)
                        .lineLimit(1).padding(.leading, 6).padding(.top, 3)
                    HStack(alignment: .top, spacing: 0) { ForEach(row.element, id: \.address) { knob($0) } }
                        .padding(.horizontal, 2).padding(.bottom, 2)
                }
                .frame(height: DeviceLayout.sectionHeight, alignment: .top)
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line.opacity(0.7), lineWidth: 1))
            }
        }
    }

    /// A group of the tree: its title with a fold chevron, then its knobs in blocks of two rows of eight,
    /// side by side. A group with more than sixteen knobs gets a second block with the same title.
    private func section(_ group: AUKnobGroup) -> some View {
        let key = "\(device.id.rawValue.uuidString)|\(group.name)"
        let folded = model.foldedPluginGroups.contains(key)
        let blocks = folded ? [] : group.knobs.chunked(Self.perPage)
        return HStack(alignment: .top, spacing: DeviceLayout.groupGap) {
            if folded {
                block(group, key: key, folded: true, knobs: [], index: 0, count: 1)
            } else {
                ForEach(Array(blocks.enumerated()), id: \.offset) { b in
                    block(group, key: key, folded: false, knobs: b.element, index: b.offset, count: blocks.count)
                }
            }
        }
    }

    private func block(_ group: AUKnobGroup, key: String, folded: Bool, knobs: [AUKnob], index: Int, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if folded { model.foldedPluginGroups.remove(key) } else { model.foldedPluginGroups.insert(key) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: folded ? "chevron.right" : "chevron.down").font(.system(size: 7, weight: .semibold))
                    Text(group.name.uppercased() + (count > 1 ? " \(index + 1)/\(count)" : "")).font(.system(size: 8.5, weight: .semibold)).tracking(0.8).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.dim).padding(.leading, 6).padding(.trailing, 6).padding(.top, 3).padding(.bottom, folded ? 3 : 0)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hint(folded ? "\(group.name): folded. Click to show its knobs." : "\(group.name). Click to fold.")
            ForEach(Array(knobs.chunked(Self.perRow).enumerated()), id: \.offset) { row in
                HStack(alignment: .top, spacing: 0) { ForEach(row.element, id: \.address) { knob($0) } }
                    .padding(.horizontal, 2).padding(.bottom, 2)
            }
        }
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line.opacity(0.7), lineWidth: 1))
    }

    private func knob(_ k: AUKnob) -> some View {
        let param = EffectParam(k.key, k.name, k.min, k.max, k.def, unit: k.unit, choices: k.choices, log: k.logarithmic)
        let address = ParameterAddress(node: device.id.rawValue, parameter: k.key)
        let driven = model.macroDriving(address, on: track)
        let automated = model.automatedValue(track, address)
        // The plugin reports the automated value as its current one. While a curve plays, the knob shows
        // the setting the project holds instead, so the blue arc is the setting and the red arc the curve.
        let live = unit.parameterValue(k.address) ?? k.def
        let value = driven?.value ?? (automated != nil ? device.params[k.key] ?? live : live)
        return Knob(param: param, value: value, tint: Theme.accent,
                    onChange: { model.setDeviceParam(track.id, device.id, k.key, param.clamp($0)) },
                    onReset: { model.setDeviceParam(track.id, device.id, k.key, nil) },
                    automation: model.knobAutomation(track, address),
                    automated: automated,
                    format: k.choices.isEmpty ? { unit.displayString(k.address, $0) ?? param.format($0) } : nil)
            .allowsHitTesting(driven == nil)
            .overlay(alignment: .topTrailing) { if let driven { MacroBadge(track: track, address: address, driving: driven) } }
            .midiLearnable(.deviceParam(track.id, device.id, k.key))
            .macroMappable(address, track: track)
    }
}

private extension Array {
    /// The array in pieces of `size`; the last piece may be shorter.
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

/// A diskette, eleven points wide: the save sign. SF Symbols has none.
private struct DisketteIcon: View {
    var body: some View {
        ZStack(alignment: .top) {
            // The body, with the top right corner cut like a real one.
            Path { p in
                p.move(to: CGPoint(x: 0.5, y: 1.5))
                p.addLine(to: CGPoint(x: 8.5, y: 0.5))
                p.addLine(to: CGPoint(x: 10.5, y: 2.5))
                p.addLine(to: CGPoint(x: 10.5, y: 10.5))
                p.addLine(to: CGPoint(x: 0.5, y: 10.5))
                p.closeSubpath()
            }
            .stroke(lineWidth: 1)
            // The shutter at the top, the label at the bottom.
            Rectangle().frame(width: 4, height: 2.5).offset(x: 0.5, y: 1.5)
            Rectangle().stroke(lineWidth: 1).frame(width: 5, height: 2.5).offset(y: 6.5)
        }
        .frame(width: 11, height: 11)
    }
}

/// The gain reduction of a compressor, limiter or multiband, as bars that grow down from the top. 30 Hz.
private struct GainReductionMeter: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSlot
    let bands: Int

    var body: some View {
        // An animation schedule with the date read: a periodic one left the bars standing still between knob moves.
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let _ = context.date
            let dsp = model.engine.builtInEffect(device.id)
            HStack(spacing: 2) {
                ForEach(0..<bands, id: \.self) { i in
                    let reduction = dsp.map { Double($0.meters[i]) } ?? 0
                    ZStack(alignment: .top) {
                        RoundedRectangle(cornerRadius: 1).fill(Theme.panel)
                        RoundedRectangle(cornerRadius: 1).fill(Theme.accent.opacity(0.85))
                            .frame(height: CGFloat(min(reduction, 24) / 24) * 18)
                    }
                    .frame(width: bands > 1 ? 4 : 6, height: 18)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 1).stroke(Theme.line, lineWidth: 1))
            .hint(dsp.map { String(format: "Gain reduction: %.1f dB", $0.meters[bands > 1 ? 3 : 0]) } ?? "Gain reduction")
        }
    }
}
