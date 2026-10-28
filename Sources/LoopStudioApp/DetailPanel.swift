import LoopStudioCore
import SwiftUI

/// The bottom panel: clip properties and follow actions on the left, the device chain on the right.
struct DetailPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                tab("Clip", .clip)
                tab("Devices", .devices)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            Divider().overlay(Theme.line)
            switch model.detailTab {
            case .clip: ClipPanel().frame(maxWidth: .infinity)
            case .devices: DeviceChainView().frame(maxWidth: .infinity)
            }
        }
        .background(Theme.panel)
    }

    private func tab(_ title: String, _ value: DetailTab) -> some View {
        Button(title) { model.detailTab = value }
            .buttonStyle(.plain).font(.system(size: 12, weight: model.detailTab == value ? .bold : .regular))
            .foregroundStyle(model.detailTab == value ? Theme.accent : Theme.dim)
            .padding(.horizontal, 10).padding(.vertical, 3)
    }
}

private struct ClipPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let id = model.selectedClip, let (trackID, clip) = model.project.findClip(id), let track = model.project.track(trackID) {
            let slotRow = track.slots.firstIndex { $0?.clip.id == id }
            HStack(alignment: .top, spacing: 14) {
                properties(clip, track: track)
                    .frame(width: 270)
                VStack(alignment: .leading, spacing: 6) {
                    if case .midi(let m) = clip {
                        PianoRoll(clip: m, tint: Theme.track(track.colorIndex))
                    } else if case .dummy(let d) = clip {
                        DummyPanel(clip: d, tint: Theme.track(track.colorIndex))
                    } else {
                    Text(model.clipName(clip)).font(.headline)
                    if case .audio(let a) = clip, let peaks = model.waveforms[a.asset], let asset = model.project.asset(a.asset) {
                        let assetTicks = Double(asset.frames) / max(1, asset.sampleRate) * model.bpm / 60 * Double(Tick.perQuarter)
                        WaveformView(peaks: peaks, color: Theme.track(track.colorIndex), fraction: Double(clip.length.rawValue) / max(1, assetTicks), loop: a.loop)
                            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
                    } else {
                        Spacer()
                    }
                    }
                }
                if let row = slotRow, let slot = track.slots[row] {
                    FollowEditor(track: track, row: row, slot: slot).frame(width: 300)
                }
            }
            .padding(10)
        } else {
            VStack { Spacer(); Text("Select a clip to see its settings.").foregroundStyle(Theme.dim); Spacer() }
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func properties(_ clip: Clip, track: Track) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Clip").font(.caption.bold()).foregroundStyle(Theme.dim)
            switch clip {
            case .audio(let a):
                Toggle("Loop", isOn: Binding(get: { a.loop }, set: { model.apply(.setClipLoop(clip: a.id, loop: $0)) }))
                Toggle("Clip active", isOn: Binding(get: { !a.muted }, set: { set(a, muted: !$0) }))
                warpControls(a)
                slider("Gain", value: a.gainDb, range: -36...12, format: "%.1f dB") { set(a, gain: $0) }
                slider("Fade in", value: a.fadeInMs, range: 0...200, format: "%.1f ms") { set(a, fadeIn: $0) }
                slider("Fade out", value: a.fadeOutMs, range: 0...200, format: "%.1f ms") { set(a, fadeOut: $0) }
                Stepper("Length  \(beatsText(a.length))", onIncrement: { resize(a.id, a.start, a.length, by: 1) },
                        onDecrement: { resize(a.id, a.start, a.length, by: -1) })
            case .midi(let m):
                Toggle("Loop", isOn: Binding(get: { m.loop }, set: { model.apply(.setClipLoop(clip: m.id, loop: $0)) }))
                Stepper("Length  \(beatsText(m.length))", onIncrement: { resize(m.id, m.start, m.length, by: 4) },
                        onDecrement: { resize(m.id, m.start, m.length, by: -4) })
                Text("Click the grid to add notes. Drag to move. Drag the right edge to resize. Double-click deletes.")
                    .font(.caption).foregroundStyle(Theme.dim)
            case .dummy:
                Stepper("Length  \(beatsText(clip.length))", onIncrement: { resize(clip.id, clip.start, clip.length, by: 4) },
                        onDecrement: { resize(clip.id, clip.start, clip.length, by: -4) })
                Text("A dummy clip draws parameter curves while it plays. Its follow actions chain it to other slots.")
                    .font(.caption).foregroundStyle(Theme.dim)
            }
            Spacer()
        }
        .font(.system(size: 12))
    }

    @ViewBuilder
    private func warpControls(_ a: AudioClip) -> some View {
        let asset = model.project.asset(a.asset)
        HStack {
            Toggle("Warp", isOn: Binding(get: { a.warpMode != .off }, set: { model.apply(.setClipWarp(clip: a.id, mode: $0 ? .beats : .off, markers: a.warpMarkers)) }))
            if a.warpMode != .off {
                Picker("", selection: Binding(get: { a.warpMode }, set: { model.apply(.setClipWarp(clip: a.id, mode: $0, markers: a.warpMarkers)) })) {
                    Text("Beats").tag(WarpMode.beats)
                    Text("Tones").tag(WarpMode.tones)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 110)
            }
        }
        if a.warpMode != .off {
            HStack(spacing: 4) {
                Text("Source").frame(width: 52, alignment: .leading)
                TextField("BPM", value: Binding(get: { asset?.sourceTempo ?? 0 }, set: { v in
                    if let asset, v >= 20, v <= 400 { model.apply(.setAssetTempo(id: asset.id, bpm: v)) }
                }), format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder).frame(width: 70)
                Button("÷2") { if let t = asset?.sourceTempo, let asset { model.apply(.setAssetTempo(id: asset.id, bpm: t / 2)) } }
                Button("×2") { if let t = asset?.sourceTempo, let asset { model.apply(.setAssetTempo(id: asset.id, bpm: t * 2)) } }
                Button("Fit") { fitTempo(a) }.help("Set the source tempo so this clip's audio fills the clip length once")
            }
            .controlSize(.small)
            if asset?.sourceTempo == nil { Text("Enter the tempo of this loop.").font(.caption).foregroundStyle(.orange) }
        }
    }

    /// Makes the whole sample span the clip length: sets the source tempo that does it.
    private func fitTempo(_ a: AudioClip) {
        guard let asset = model.project.asset(a.asset), asset.sampleRate > 0 else { return }
        let seconds = Double(asset.frames) / asset.sampleRate
        let beats = Double(a.length.rawValue) / Double(Tick.perQuarter)
        guard seconds > 0, beats > 0 else { return }
        model.apply(.setAssetTempo(id: asset.id, bpm: min(400, max(20, beats * 60 / seconds))))
    }

    private func set(_ a: AudioClip, gain: Double? = nil, fadeIn: Double? = nil, fadeOut: Double? = nil, muted: Bool? = nil) {
        model.apply(.setAudioClip(clip: a.id, gainDb: gain ?? a.gainDb, fadeInMs: fadeIn ?? a.fadeInMs,
                                  fadeOutMs: fadeOut ?? a.fadeOutMs, muted: muted ?? a.muted), key: "clip\(a.id)")
    }

    private func resize(_ id: ClipID, _ start: Tick, _ length: Tick, by beats: Int64) {
        let new = length.rawValue + beats * Tick.perQuarter
        guard new >= Tick.perQuarter else { return }
        model.apply(.setClipRange(clip: id, start: start, length: Tick(new)))
    }

    private func beatsText(_ t: Tick) -> String {
        let beats = Double(t.rawValue) / Double(Tick.perQuarter)
        let bars = beats / 4
        return bars == bars.rounded() ? "\(Int(bars)) bar" + (bars == 1 ? "" : "s") : String(format: "%.2f beats", beats)
    }

    private func slider(_ label: String, value: Double, range: ClosedRange<Double>, format: String, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(label).frame(width: 52, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range).controlSize(.small)
            Text(String(format: format, value)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim).frame(width: 56, alignment: .trailing)
        }
    }
}

/// Launch quantize and the two follow actions A and B with their chance.
private struct FollowEditor: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let row: Int
    let slot: SessionSlot

    private let kinds: [(FollowActionKind, String)] = [
        (.stop, "Stop"), (.replay, "Play Again"), (.next, "Next"), (.previous, "Previous"), (.topOfBlock, "Top of Block"),
        (.endOfBlock, "End of Block"), (.any, "Any"), (.other, "Other"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Launch").font(.caption.bold()).foregroundStyle(Theme.dim)
            Picker("Quantize", selection: Binding(get: { slot.quantize }, set: { var s = slot; s.quantize = $0; commit(s) })) {
                Text("None").tag(LaunchQuantize.none)
                Text("1 Beat").tag(LaunchQuantize.beat)
                Text("1 Bar").tag(LaunchQuantize.bar)
            }
            .pickerStyle(.segmented)

            Toggle("Follow Action", isOn: Binding(get: { slot.follow != nil }, set: { on in
                var s = slot
                s.follow = on ? FollowActions(a: FollowAction(.next, weight: 1), b: FollowAction(.replay, weight: 1), time: .loops(1)) : nil
                commit(s)
            }))
            if let f = slot.follow {
                HStack {
                    actionPicker("A", f.a) { var s = slot; s.follow?.a.kind = $0; commit(s) }
                    actionPicker("B", f.b) { var s = slot; s.follow?.b.kind = $0; commit(s) }
                }
                let total = max(0.0001, f.a.weight + f.b.weight)
                let chanceA = f.a.weight / total * 100
                HStack {
                    Text("A").foregroundStyle(Theme.accent)
                    Slider(value: Binding(get: { chanceA }, set: { v in
                        var s = slot; s.follow?.a.weight = v; s.follow?.b.weight = 100 - v; commit(s, key: "chance")
                    }), in: 0...100, step: 1).controlSize(.small)
                    Text("B").foregroundStyle(Theme.accent)
                }
                Text(String(format: "Chance  A %.0f %%   B %.0f %%", chanceA, 100 - chanceA)).font(.system(size: 10)).foregroundStyle(Theme.dim)
                HStack {
                    Text("After")
                    Stepper(value: Binding(get: { Int(f.time.amount) }, set: { var s = slot; s.follow?.time.amount = Int64($0); commit(s, key: "time") }), in: 1...64) {
                        Text("\(f.time.amount)")
                    }
                    Picker("", selection: Binding(get: { f.time.unit }, set: { var s = slot; s.follow?.time = FollowTime($0, $0 == .loops ? 1 : Tick.perQuarter * 4); commit(s) })) {
                        Text("loops").tag(FollowTime.Unit.loops)
                        Text("ticks").tag(FollowTime.Unit.ticks)
                    }
                    .labelsHidden().frame(width: 80)
                }
                Picker("At block edge", selection: Binding(get: { f.edge }, set: { var s = slot; s.follow?.edge = $0; commit(s) })) {
                    Text("Wrap").tag(BlockEdge.wrap)
                    Text("Stop").tag(BlockEdge.stop)
                }
                .pickerStyle(.segmented)
            }
            Spacer()
        }
        .font(.system(size: 12))
    }

    private func actionPicker(_ label: String, _ action: FollowAction, set: @escaping (FollowActionKind) -> Void) -> some View {
        Picker(label, selection: Binding(get: { action.kind }, set: set)) {
            ForEach(kinds, id: \.0) { Text($0.1).tag($0.0) }
        }
    }

    private func commit(_ s: SessionSlot, key: String? = nil) {
        model.apply(.setSlot(track: track.id, index: row, slot: s), key: key.map { "\($0)\(s.clip.id)" })
    }
}

/// The curves of a dummy clip. Points count from the start of the clip.
private struct DummyPanel: View {
    @Environment(AppModel.self) private var model
    let clip: DummyClip
    let tint: Color
    @State private var choice: ParameterAddress?

    var body: some View {
        let targets = model.project.automationTargets()
        let address = choice ?? clip.lanes.first?.target ?? targets.first?.address
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Parameter", selection: Binding(get: { address }, set: { choice = $0 })) {
                    ForEach(targets, id: \.address) { Text($0.name).tag(Optional($0.address)) }
                }
                .controlSize(.small).frame(maxWidth: 300)
                Text("\(clip.lanes.count) curve" + (clip.lanes.count == 1 ? "" : "s")).font(.caption).foregroundStyle(Theme.dim)
                Spacer()
                if let address, clip.lanes.contains(where: { $0.target == address }) {
                    Button("Remove curve") { model.apply(.setDummyAutomation(clip: clip.id, target: address, points: [])) }.controlSize(.small)
                }
            }
            if let address, let target = model.project.automationTarget(address) {
                GeometryReader { geo in
                    AutomationEditor(target: target, points: clip.lanes.first { $0.target == address }?.points ?? [],
                                     pixelsPerTick: Double(geo.size.width) / Double(max(1, clip.length.rawValue)),
                                     width: geo.size.width, height: geo.size.height, tint: tint) { pts in
                        model.apply(.setDummyAutomation(clip: clip.id, target: address, points: pts))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Spacer()
            }
        }
    }
}
