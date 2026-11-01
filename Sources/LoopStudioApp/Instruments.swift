import LoopStudioCore
import LoopStudioEngine
import SwiftUI

/// One knob of a built-in device, wired to the project: its value, undo, the automation menu, MIDI Learn,
/// and the tempo switch of a synced knob.
struct ParamKnob: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let device: DeviceSlot
    let spec: EffectSpec
    let key: String
    var tint: Color = Theme.accent

    var body: some View {
        if let free = spec.param(key) {
            // A synced knob shows its note value instead of the free value.
            let synced = free.syncable && (device.params[free.syncKey] ?? 0) >= 0.5
            let param = synced ? spec.param(free.divisionKey) ?? free : free
            Knob(param: param, value: device.params[param.key] ?? param.def, tint: tint,
                 onChange: { model.setDeviceParam(track.id, device.id, param.key, param.clamp($0)) },
                 onReset: { model.setDeviceParam(track.id, device.id, param.key, nil) },
                 automation: automation(param),
                 sync: free.syncable ? KnobSync(synced: synced, unit: free.unit) {
                     model.setDeviceParam(track.id, device.id, free.syncKey, synced ? 0 : 1)
                 } : nil)
            .midiLearnable(.deviceParam(track.id, device.id, param.key))
        }
    }

    private func automation(_ param: EffectParam) -> KnobAutomation {
        let address = ParameterAddress(node: device.id.rawValue, parameter: param.key)
        return KnobAutomation(
            hasCurve: track.automation.contains { $0.target == address && !$0.points.isEmpty },
            laneShown: model.isLaneShown(track, address),
            toggleLane: { model.toggleLaneAndReveal(track, address) },
            clear: { model.apply(.setAutomation(track: track.id, target: address, points: [])) })
    }
}

/// A named group of knobs on an instrument, like the sections printed on a hardware panel.
struct KnobSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased()).font(.system(size: 8.5, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.dim)
                .padding(.leading, 4).padding(.bottom, 2)
            HStack(alignment: .top, spacing: 0) { content() }
        }
    }
}

private struct SectionDivider: View {
    var body: some View { Rectangle().fill(Theme.line).frame(width: 1).padding(.vertical, 8).padding(.horizontal, 4) }
}

/// The panel of a built-in instrument: a view of its own per instrument, a plain knob row for any other.
struct InstrumentView: View {
    let track: Track
    let device: DeviceSlot
    let spec: EffectSpec

    var body: some View {
        switch device.identifier {
        case "acid": AcidBassView(track: track, device: device, spec: spec)
        case "drum808": Drum808View(track: track, device: device, spec: spec)
        default:
            HStack(alignment: .top, spacing: 2) {
                ForEach(spec.shownParams, id: \.key) { ParamKnob(track: track, device: device, spec: spec, key: $0.key) }
            }
        }
    }
}

// MARK: Acid Bass

private let acidTint = Color(red: 0.98, green: 0.62, blue: 0.22)

struct AcidBassView: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let device: DeviceSlot
    let spec: EffectSpec

    private func knob(_ key: String) -> some View { ParamKnob(track: track, device: device, spec: spec, key: key, tint: acidTint) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            AcidScope(device: device)
                .frame(width: 150, height: 92)
                .padding(.top, 2)
                .hint("The filter as it sounds: the curve follows the envelope and the accent. Orange: the cutoff knob.")
            SectionDivider()
            KnobSection(title: "Oscillator") { knob("wave"); knob("tune"); knob("sub") }
            SectionDivider()
            KnobSection(title: "Filter") { knob("cutoff"); knob("resonance"); knob("envMod"); knob("keyTrack"); knob("decay") }
            SectionDivider()
            KnobSection(title: "Accent · Slide") { knob("accent"); knob("slide") }
                .hint("Accent: a note at velocity \(BuiltInInstruments.accentVelocity) or more is louder, with a filter kick. Slide: a note that overlaps the one before glides to it.")
            SectionDivider()
            KnobSection(title: "Out") { knob("drive"); knob("volume") }
        }
    }
}

/// The filter response of the Acid Bass, drawn live: the knob curve dimmed, the sounding curve on top.
private struct AcidScope: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSlot

    var body: some View {
        let synth = model.engine.builtInInstrument(device.id)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: synth == nil)) { _ in
            Canvas { ctx, size in
                let knobCutoff = device.params["cutoff"] ?? 700
                let resonance = device.params["resonance"] ?? 0.65
                let live = synth.map { Double($0.telemetryValue(0)) } ?? knobCutoff
                let level = synth.map { Double($0.telemetryValue(1)) } ?? 0
                let gate = (synth?.telemetryValue(2) ?? 0) > 0.5
                let accent = (synth?.telemetryValue(3) ?? 0) > 0.5
                let plot = CGRect(x: 0, y: 0, width: size.width, height: size.height - 14)
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: Theme.radius + 1), with: .color(.black.opacity(0.35)))
                // Octave lines from 20 Hz to 20 kHz.
                for k in 1..<10 {
                    let x = plot.width * CGFloat(k) / 10
                    ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: plot.height)) }, with: .color(.white.opacity(0.06)), lineWidth: 1)
                }
                func curve(_ cutoff: Double) -> Path {
                    var p = Path()
                    for i in 0...Int(plot.width) {
                        let x = CGFloat(i)
                        let f = 20 * pow(2, Double(x / plot.width) * 10)
                        let ratio = f / max(20, cutoff)
                        var mag = 1 / (1 + pow(ratio, 8)).squareRoot()
                        let bump = log2(ratio)
                        mag *= 1 + resonance * resonance * 9 * exp(-bump * bump * 10)
                        let db = max(-42, min(18, 20 * log10(max(mag, 1e-6))))
                        let y = plot.height * CGFloat((18 - db) / 60)
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    return p
                }
                ctx.stroke(curve(knobCutoff), with: .color(acidTint.opacity(0.35)), lineWidth: 1)
                var fill = curve(live)
                fill.addLine(to: CGPoint(x: plot.width, y: plot.height)); fill.addLine(to: CGPoint(x: 0, y: plot.height)); fill.closeSubpath()
                ctx.fill(fill, with: .color(acidTint.opacity(0.08 + 0.25 * min(1, level * 2))))
                ctx.stroke(curve(live), with: .color(acidTint.opacity(0.55 + 0.45 * min(1, level * 2))), lineWidth: 1.5)
                // The level bar and the two lights.
                let barY = size.height - 9
                ctx.fill(Path(roundedRect: CGRect(x: 4, y: barY, width: plot.width - 48, height: 4), cornerRadius: 2), with: .color(.white.opacity(0.08)))
                ctx.fill(Path(roundedRect: CGRect(x: 4, y: barY, width: (plot.width - 48) * CGFloat(min(1, level)), height: 4), cornerRadius: 2), with: .color(acidTint))
                func light(_ x: CGFloat, _ on: Bool, _ text: String) {
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: barY - 1, width: 6, height: 6)), with: .color(on ? Theme.automationDot : .white.opacity(0.12)))
                    ctx.draw(Text(text).font(.system(size: 7, weight: .semibold)).foregroundStyle(Theme.dim), at: CGPoint(x: x + 9, y: barY + 2), anchor: .leading)
                }
                light(plot.width - 40, gate, "GATE")
                light(plot.width - 14, accent, "ACC")
            }
        }
    }
}

// MARK: 808 Drums

private let drumTint = Color(red: 0.93, green: 0.33, blue: 0.30)

struct Drum808View: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let device: DeviceSlot
    let spec: EffectSpec
    @State private var selected = 0

    private var pad: BuiltInInstruments.DrumPad { BuiltInInstruments.drumPads[min(selected, BuiltInInstruments.drumPads.count - 1)] }

    private func knob(_ key: String) -> some View { ParamKnob(track: track, device: device, spec: spec, key: key, tint: drumTint) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            DrumPadGrid(device: device, selected: $selected) { note in model.auditionNote(note, on: track.id) }
                .padding(.top, 2)
            SectionDivider()
            KnobSection(title: "\(pad.name) · \(MIDIControl.noteName(pad.notes[0]))") {
                ForEach(pad.params, id: \.self) { knob($0) }
            }
            .id(pad.key)
            SectionDivider()
            KnobSection(title: "Kit") { ForEach(BuiltInInstruments.drumKitParams, id: \.self) { knob($0) } }
        }
    }
}

/// The twelve pads, four per row. A pad lights when it plays. Click one to hear it and to see its knobs.
private struct DrumPadGrid: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSlot
    @Binding var selected: Int
    let play: (UInt8) -> Void

    var body: some View {
        let synth = model.engine.builtInInstrument(device.id)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: synth == nil)) { _ in
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(0..<4, id: \.self) { column in
                            let i = row * 4 + column
                            let pad = BuiltInInstruments.drumPads[i]
                            let level = Double(synth?.telemetryValue(i) ?? 0)
                            padButton(pad, index: i, level: level)
                        }
                    }
                }
            }
        }
    }

    private func padButton(_ pad: BuiltInInstruments.DrumPad, index i: Int, level: Double) -> some View {
        Button {
            selected = i
            play(pad.notes[0])
        } label: {
            VStack(spacing: 1) {
                Text(pad.name).font(.system(size: 9, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Text(MIDIControl.noteName(pad.notes[0])).font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.dim)
            }
            .frame(width: 50, height: 28)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius + 1)
                    .fill(drumTint.opacity(0.12 + 0.75 * min(1, level)))
            )
            .overlay(RoundedRectangle(cornerRadius: Theme.radius + 1).stroke(selected == i ? Theme.text : Theme.line, lineWidth: selected == i ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hint("\(pad.name): plays on \(pad.notes.map { MIDIControl.noteName($0) }.joined(separator: ", ")). Click to hear it and to show its knobs.")
    }
}

extension AppModel {
    /// A short note on one track, for the pads of an instrument. It plays whatever the track is armed for.
    func auditionNote(_ pitch: UInt8, on track: TrackID, velocity: UInt8 = 110) {
        engine.sendLiveMIDI(track: track, 0x90, pitch, velocity)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            engine.sendLiveMIDI(track: track, 0x80, pitch, 0)
        }
    }

    /// The name a pitch has on a track, when the track's instrument is a drum kit: "Kick", "Snare"...
    func drumNames(ofTrack track: TrackID?) -> [Int: String] {
        guard let track, let t = project.track(track) else { return [:] }
        let kit = t.devices.first { !$0.bypassed && $0.format == "builtin" && BuiltInEffects.spec($0.identifier)?.isInstrument == true }
        guard kit?.identifier == "drum808" else { return [:] }
        var names: [Int: String] = [:]
        for pad in BuiltInInstruments.drumPads { for note in pad.notes { names[Int(note)] = pad.name } }
        return names
    }
}
