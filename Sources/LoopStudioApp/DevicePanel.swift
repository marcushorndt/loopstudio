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
            } else {
                Menu(param.format(value)) {
                    ForEach(Array(param.choices.enumerated()), id: \.offset) { i, name in Button(name) { onChange(Double(i)) } }
                }
                .menuStyle(.borderlessButton).frame(width: 74, height: 44).font(.system(size: 11))
            }
            Text(sync == nil ? param.name : param.name.replacingOccurrences(of: " Note", with: ""))
                .font(.system(size: 10)).foregroundStyle(Theme.dim).lineLimit(1)
            if rotary { Text(param.format(value)).font(.system(size: 10, design: .monospaced)) }
            if let sync { SyncToggle(sync: sync, tint: tint) }
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

/// Two small segments under a knob: the free unit, or a note value that follows the tempo.
private struct SyncToggle: View {
    let sync: KnobSync
    let tint: Color

    var body: some View {
        Button(action: sync.toggle) {
            HStack(spacing: 0) {
                segment(Text(sync.unit), on: !sync.synced)
                segment(Text(Image(systemName: "music.note")), on: sync.synced)
            }
            .font(.system(size: 9, weight: .semibold))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hint(sync.synced ? "Follows the tempo. Click for a free time in \(sync.unit)." : "Free time. Click to follow the tempo with a note value.")
    }

    private func segment(_ label: Text, on: Bool) -> some View {
        label.frame(width: 22, height: 14)
            .foregroundStyle(on ? Color.white : Theme.dim)
            .background(on ? tint.opacity(0.75) : Color.clear)
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
                            PillMenu(label: "Automate") { AutomationLaneToggles(track: track) }
                        }
                        .frame(height: 22)
                        Text(kindLabel(track.kind) + " · " + (track.devices.isEmpty ? "no devices" : "\(track.devices.count) device\(track.devices.count == 1 ? "" : "s")"))
                            .font(.system(size: 10)).foregroundStyle(Theme.dim)
                    }
                    .frame(width: 230, alignment: .leading)
                    ForEach(track.devices, id: \.id) { DeviceCard(track: track, device: $0) }
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
        let instrument = track.kind == .midi && !track.devices.contains { model.host.units[$0.id]?.isInstrument == true }
        return VStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 14, weight: .medium))
            Text(instrument ? "Drop an instrument\nor an effect here" : "Drop an effect here")
                .font(.caption).multilineTextAlignment(.center)
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

private struct DeviceCard: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let device: DeviceSlot

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
        .frame(width: 170, height: 60, alignment: .topLeading)
    }

    private func knobAutomation(_ param: EffectParam) -> KnobAutomation {
        let address = ParameterAddress(node: device.id.rawValue, parameter: param.key)
        return KnobAutomation(
            hasCurve: track.automation.contains { $0.target == address && !$0.points.isEmpty },
            laneShown: model.isLaneShown(track, address),
            toggleLane: { model.toggleLaneAndReveal(track, address) },
            clear: { model.apply(.setAutomation(track: track.id, target: address, points: [])) })
    }

    var body: some View {
        let spec = device.format == "builtin" ? BuiltInEffects.spec(device.identifier) : nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { model.apply(.setDeviceBypass(track: track.id, device: device.id, bypassed: !device.bypassed)) } label: {
                    Image(systemName: "power").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(device.bypassed ? Theme.dim : Theme.accent)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).hint(device.bypassed ? "Turn on" : "Bypass")
                Text(device.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Button { model.apply(.removeDevice(track: track.id, device: device.id)) } label: {
                    Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(Theme.dim)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).hint("Remove")
            }
            if let spec {
                HStack(alignment: .top, spacing: 2) {
                    ForEach(spec.shownParams, id: \.key) { free in
                        // A synced knob shows its note value instead of the free value.
                        let synced = free.syncable && (device.params[free.syncKey] ?? 0) >= 0.5
                        let param = synced ? spec.params.first { $0.key == free.divisionKey } ?? free : free
                        Knob(param: param, value: device.params[param.key] ?? param.def, tint: Theme.accent,
                             onChange: { model.setDeviceParam(track.id, device.id, param.key, param.clamp($0)) },
                             onReset: { model.setDeviceParam(track.id, device.id, param.key, nil) },
                             automation: knobAutomation(param),
                             sync: free.syncable ? KnobSync(synced: synced, unit: free.unit) {
                                 model.setDeviceParam(track.id, device.id, free.syncKey, synced ? 0 : 1)
                             } : nil)
                        .midiLearnable(.deviceParam(track.id, device.id, param.key))
                    }
                }
                .opacity(device.bypassed ? 0.4 : 1)
            } else if device.format == "audiounit" {
                pluginBody
            } else {
                Text("Unsupported plugin format.").font(.caption).foregroundStyle(Theme.dim).frame(width: 160, height: 60)
            }
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
}
