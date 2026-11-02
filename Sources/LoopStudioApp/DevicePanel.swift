import LoopStudioCore
import SwiftUI

/// A rotary knob. Drag up or down to change it, double-click to reset.
/// What a knob needs to offer automation in its right-click menu.
struct KnobAutomation {
    var hasCurve: Bool
    var laneShown: Bool
    var toggleLane: () -> Void
    var clear: () -> Void
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
    var sync: KnobSync? = nil
    @State private var startPosition: Double?

    private var rotary: Bool { param.choices.isEmpty || param.rotary }

    var body: some View {
        VStack(spacing: 3) {
            if param.isSwitch {
                OnOffSwitch(on: value >= 0.5, tint: tint) { onChange(value >= 0.5 ? 0 : 1) }
                    .frame(width: 44, height: 44)
            } else if rotary {
                KnobDial(position: param.position(value), tint: tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if startPosition == nil { startPosition = param.position(value) }
                        onChange(param.value(atPosition: (startPosition ?? 0) - Double(g.translation.height) / 160))
                    }
                    .onEnded { _ in startPosition = nil })
                .simultaneousGesture(TapGesture(count: 2).onEnded { onReset() })
                // The tempo switch sits in the gap of the arc, at the bottom of the dial: every knob has that room.
                .overlay(alignment: .bottom) { if let sync { SyncToggle(sync: sync, tint: tint).offset(y: 3) } }
            } else {
                Menu(param.format(value)) {
                    ForEach(Array(param.choices.enumerated()), id: \.offset) { i, name in Button(name) { onChange(Double(i)) } }
                }
                .menuStyle(.borderlessButton).frame(width: 74, height: 44).font(.system(size: 11))
            }
            Text(sync == nil ? param.name : param.name.replacingOccurrences(of: " Note", with: ""))
                .font(.system(size: 10)).foregroundStyle(Theme.dim).lineLimit(1)
            if rotary { Text(param.format(value)).font(.system(size: 10, design: .monospaced)) }
        }
        .frame(width: 66)
        .hint(param.isSwitch ? "\(param.name): \(value >= 0.5 ? "On" : "Off"). Click to switch."
              : "\(param.name): \(param.format(value)). Drag up or down; double-click resets. Right-click for automation.")
        .overlay(alignment: .topTrailing) {
            if automation?.hasCurve == true {
                Circle().fill(Theme.track(0)).frame(width: 6, height: 6).padding(4).hint("Automated")
            }
        }
        .contextMenu {
            if let automation {
                Button(automation.laneShown ? "Hide Automation Curve" : "Show Automation Curve", action: automation.toggleLane)
                Button("Clear Automation", action: automation.clear).disabled(!automation.hasCurve)
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

/// The drawing of a rotary knob: a 270 degree arc, filled up to `position` (0...1), and a needle.
struct KnobDial: View {
    let position: Double
    let tint: Color
    var lineWidth: CGFloat = 4

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

struct DeviceCard: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let device: DeviceSlot
    /// The chain this card sits in, or `nil` on the track itself.
    var chain: ChainID? = nil

    @ViewBuilder
    private var pluginBody: some View {
        let _ = model.pluginRevision
        VStack(alignment: .leading, spacing: 6) {
            if let unit = model.host.units[device.id] {
                Text(unit.isInstrument ? "Instrument" : "Audio Unit effect").font(.caption).foregroundStyle(Theme.dim)
                Button("Open Plugin Window") { PluginWindow.show(unit, title: device.name) }.controlSize(.small)
            } else if let failure = model.host.failures[device.id] {
                Text("Could not load").font(.caption).foregroundStyle(.red)
                Text(failure).font(.system(size: 9)).foregroundStyle(Theme.dim).lineLimit(3).frame(width: 150, alignment: .leading)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Loading…").font(.caption).foregroundStyle(Theme.dim) }
            }
        }
        .frame(width: 170, alignment: .topLeading)
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
        .simultaneousGesture(TapGesture().onEnded { model.selectDevice(device.id) })
        .contextMenu { DeviceMenu(track: track, device: device) }
    }

    var body: some View {
        if folded { foldedCard } else { openCard }
    }

    private var openCard: some View {
        let spec = device.format == "builtin" ? BuiltInEffects.spec(device.identifier) : nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { model.toggleDeviceFold(device.id) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.dim)
                        .frame(width: 14, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).hint("Fold \(device.name) to its title. Double-click the title does the same.")
                powerButton
                Text(device.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture(count: 2).onEnded { model.toggleDeviceFold(device.id) })
                Spacer(minLength: 8)
                if let spec, spec.sidechain { sidechainMenu }
                if let spec, spec.isDynamics { GainReductionMeter(device: device, bands: spec.id == "multiband" ? 3 : 1) }
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
        .simultaneousGesture(TapGesture().onEnded { model.selectDevice(device.id) })
        .contextMenu { DeviceMenu(track: track, device: device) }
        .hint(selected ? "\(device.name): marked. Delete removes it; right-click for more." : "\(device.name). Click to mark it, right-click for more.")
    }

    private var selected: Bool { model.selectedDevice == device.id }

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
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                Text(current?.name ?? "Own Input").font(.system(size: 10)).lineLimit(1)
            }
            .foregroundStyle(current == nil ? Theme.dim : Theme.track(current!.colorIndex))
            .padding(.horizontal, 5).frame(height: 18)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line, lineWidth: 1))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .hint("Sidechain: the signal the detector listens to. Own input, or another track.")
    }
}

/// The gain reduction of a compressor, limiter or multiband, as bars that grow down from the top. 30 Hz.
private struct GainReductionMeter: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSlot
    let bands: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
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
