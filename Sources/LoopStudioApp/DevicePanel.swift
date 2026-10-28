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

struct Knob: View {
    let param: EffectParam
    let value: Double
    let tint: Color
    let onChange: (Double) -> Void
    let onReset: () -> Void
    /// Automation of this knob: nil hides the menu entries (a knob with no automation target).
    var automation: KnobAutomation? = nil
    @State private var startPosition: Double?

    var body: some View {
        VStack(spacing: 3) {
            if param.choices.isEmpty {
                ZStack {
                    Canvas { ctx, size in
                        let r = min(size.width, size.height) / 2 - 3
                        let c = CGPoint(x: size.width / 2, y: size.height / 2)
                        let from = Angle.degrees(135), span = 270.0
                        var track = Path(); track.addArc(center: c, radius: r, startAngle: from, endAngle: .degrees(135 + span), clockwise: false)
                        ctx.stroke(track, with: .color(.black.opacity(0.55)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        let p = param.position(value)
                        var arc = Path(); arc.addArc(center: c, radius: r, startAngle: from, endAngle: .degrees(135 + span * p), clockwise: false)
                        ctx.stroke(arc, with: .color(tint), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        let a = Angle.degrees(135 + span * p).radians
                        var needle = Path(); needle.move(to: c); needle.addLine(to: CGPoint(x: c.x + cos(a) * (r - 6), y: c.y + sin(a) * (r - 6)))
                        ctx.stroke(needle, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                }
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
            Text(param.name).font(.system(size: 10)).foregroundStyle(Theme.dim).lineLimit(1)
            if param.choices.isEmpty { Text(param.format(value)).font(.system(size: 10, design: .monospaced)) }
        }
        .frame(width: 66)
        .overlay(alignment: .topTrailing) {
            if automation?.hasCurve == true {
                Circle().fill(Theme.track(0)).frame(width: 6, height: 6).padding(4).help("Automated")
            }
        }
        .contextMenu {
            if let automation {
                Button(automation.laneShown ? "Hide Automation Curve" : "Show Automation Curve", action: automation.toggleLane)
                Button("Clear Automation", action: automation.clear).disabled(!automation.hasCurve)
                Divider()
            }
            Button("Reset to Default", action: onReset)
        }
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
        .frame(width: track.devices.isEmpty ? 200 : 130, height: 92)
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
                }
                .buttonStyle(.plain).help(device.bypassed ? "Turn on" : "Bypass")
                Text(device.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Button { model.apply(.removeDevice(track: track.id, device: device.id)) } label: {
                    Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(Theme.dim)
                }
                .buttonStyle(.plain).help("Remove")
            }
            if let spec {
                HStack(alignment: .top, spacing: 2) {
                    ForEach(spec.params, id: \.key) { param in
                        Knob(param: param, value: device.params[param.key] ?? param.def, tint: Theme.accent,
                             onChange: { model.setDeviceParam(track.id, device.id, param.key, param.clamp($0)) },
                             onReset: { model.setDeviceParam(track.id, device.id, param.key, nil) },
                             automation: knobAutomation(param))
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
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
        .contextMenu { DeviceMenu(track: track, device: device) }
    }
}
