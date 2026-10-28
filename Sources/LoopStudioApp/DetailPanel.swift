import LoopStudioCore
import SwiftUI

/// The bottom panel: clip properties and follow actions on the left, the device chain on the right.
struct DetailPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                tab("Clip", .clip)
                tab("Track", .devices)
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

/// The title row of an inspector column: a small label, and an optional control on the right.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(Theme.dim)
                .lineLimit(1)
            Spacer(minLength: 4)
            trailing()
        }
        .frame(height: 22)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

/// A quiet, outlined menu button for inspector headers.
struct PillMenu<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu { content() } label: {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8).frame(height: 22)
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}

private struct ClipPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let id = model.selectedClip, let (trackID, clip) = model.project.findClip(id), let track = model.project.track(trackID) {
            let slotRow = track.slots.firstIndex { $0?.clip.id == id }
            HStack(alignment: .top, spacing: 14) {
                properties(clip, track: track)
                    .frame(width: 230)
                if case .audio(let a) = clip { soundColumn(a).frame(width: 250) }
                if let row = slotRow, let slot = track.slots[row] {
                    FollowEditor(track: track, row: row, slot: slot).frame(width: 280)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if case .midi(let m) = clip {
                        PianoRoll(clip: m, tint: Theme.track(track.colorIndex))
                    } else if case .dummy(let d) = clip {
                        DummyPanel(clip: d, tint: Theme.track(track.colorIndex))
                    } else {
                    SectionHeader(title: model.clipName(clip)) {
                        if case .audio = clip {
                            Picker("", selection: Bindable(model).showClipEnvelope) {
                                Text("Sample").tag(false)
                                Text("Gain Envelope").tag(true)
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                        }
                    }
                    if case .audio(let a) = clip, let peaks = model.waveforms[a.asset], let asset = model.project.asset(a.asset) {
                        let assetTicks = Double(asset.frames) / max(1, asset.sampleRate) * model.bpm / 60 * Double(Tick.perQuarter)
                        if model.showClipEnvelope {
                            ClipEnvelopeView(clip: a, peaks: peaks, assetTicks: assetTicks, tint: Theme.track(track.colorIndex))
                        } else if a.warpMode != .off {
                            WarpEditor(clip: a, asset: asset, peaks: peaks, tint: Theme.track(track.colorIndex))
                        } else {
                            WaveformView(peaks: peaks, color: Theme.track(track.colorIndex), fraction: Double(clip.length.rawValue) / max(1, assetTicks), loop: a.loop)
                                .background(Theme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.radius))
                        }
                    } else {
                        Spacer()
                    }
                    }
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
            SectionHeader(title: "Clip") {
                if case .dummy = clip { EmptyView() } else {
                    PillMenu(label: "Automate") { AutomationLaneToggles(track: track) }
                }
            }
            switch clip {
            case .audio(let a):
                Toggle("Loop", isOn: Binding(get: { a.loop }, set: { model.apply(.setClipLoop(clip: a.id, loop: $0)) }))
                Toggle("Clip active", isOn: Binding(get: { !a.muted }, set: { set(a, muted: !$0) }))
                warpControls(a)
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

    /// Level and fades of an audio clip, in their own column.
    private func soundColumn(_ a: AudioClip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Sound")
            slider("Gain", value: a.gainDb, range: -36...12, format: "%.1f dB") { set(a, gain: $0) }
                .contextMenu {
                    Button(model.showClipEnvelope ? "Hide Gain Envelope" : "Show Gain Envelope") { model.showClipEnvelope.toggle() }
                    Button("Clear Gain Envelope") { model.apply(.setClipEnvelope(clip: a.id, points: [])) }
                        .disabled(a.gainEnvelope?.isEmpty ?? true)
                    Divider()
                    Button("Reset Gain") { set(a, gain: 0) }
                }
            slider("Fade in", value: a.fadeInMs, range: 0...200, format: "%.1f ms") { set(a, fadeIn: $0) }
            slider("Fade out", value: a.fadeOutMs, range: 0...200, format: "%.1f ms") { set(a, fadeOut: $0) }
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
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Launch")
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
                    .frame(maxWidth: .infinity, alignment: .center)
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
    /// Lanes the user chose to show; nil means every curve of the clip, or volume if the clip has none.
    @State private var chosen: [ParameterAddress]?

    private var shown: [ParameterAddress] {
        if let chosen { return chosen }
        if !clip.lanes.isEmpty { return clip.lanes.map(\.target) }
        return model.project.automationTargets().first.map { [$0.address] } ?? []
    }

    private func set(_ address: ParameterAddress, on: Bool) {
        var list = shown
        list.removeAll { $0 == address }
        if on { list.append(address) }
        chosen = list
    }

    var body: some View {
        let targets = model.project.automationTargets()
        let lanes = shown
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Automation") {
                PillMenu(label: lanes.isEmpty ? "Add Parameter" : "Parameters") {
                    Button("Show Parameters With Curves") { chosen = clip.lanes.map(\.target) }.disabled(clip.lanes.isEmpty)
                    Divider()
                    ForEach(targets, id: \.address) { target in
                        Toggle(target.name, isOn: Binding(get: { lanes.contains(target.address) },
                                                          set: { set(target.address, on: $0) }))
                    }
                }
            }
            if lanes.isEmpty {
                VStack(spacing: 6) {
                    Text("No parameter chosen").font(.system(size: 12, weight: .medium))
                    Text("Use Add Parameter to pick what this clip moves.").font(.system(size: 11)).foregroundStyle(Theme.dim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            } else {
                GeometryReader { geo in
                    let rowH = max(64, (geo.size.height - CGFloat(lanes.count - 1) * 4) / CGFloat(lanes.count))
                    ScrollView(.vertical) {
                        VStack(spacing: 4) {
                            ForEach(lanes, id: \.self) { address in laneRow(address, height: rowH, width: geo.size.width) }
                        }
                    }
                    .scrollDisabled(rowH * CGFloat(lanes.count) <= geo.size.height)
                }
            }
        }
    }

    @ViewBuilder
    private func laneRow(_ address: ParameterAddress, height: CGFloat, width: CGFloat) -> some View {
        if let target = model.project.automationTarget(address) {
            let points = clip.lanes.first { $0.target == address }?.points ?? []
            AutomationEditor(target: target, points: points,
                             pixelsPerTick: Double(width) / Double(max(1, clip.length.rawValue)),
                             width: width, height: height - 2, tint: tint) { pts in
                model.apply(.setDummyAutomation(clip: clip.id, target: address, points: pts))
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    Text(target.name).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.text)
                    if points.isEmpty { Text("Click to add points").font(.system(size: 10)).foregroundStyle(Theme.dim) }
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Theme.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: Theme.radius))
                .padding(4)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 2) {
                    if !points.isEmpty {
                        Button { model.apply(.setDummyAutomation(clip: clip.id, target: address, points: [])) } label: {
                            Image(systemName: "trash").font(.system(size: 10)).frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain).help("Delete this curve")
                    }
                    Button { set(address, on: false) } label: {
                        Image(systemName: "xmark").font(.system(size: 10)).frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain).help("Hide this parameter")
                }
                .foregroundStyle(Theme.dim).padding(2)
            }
        }
    }
}

/// The clip gain envelope drawn over the clip's waveform. Points count from the clip start.
private struct ClipEnvelopeView: View {
    @Environment(AppModel.self) private var model
    let clip: AudioClip
    let peaks: [Float]
    let assetTicks: Double
    let tint: Color

    private static let target = AutomationTarget(
        address: ParameterAddress(node: UUID(), parameter: "clipGain"), name: "Clip Gain",
        min: -60, max: 12, def: 0, unit: "dB", logarithmic: false, choices: [])

    var body: some View {
        GeometryReader { geo in
            ZStack {
                WaveformView(peaks: peaks, color: tint.opacity(0.45),
                             fraction: Double(clip.length.rawValue) / max(1, assetTicks), loop: clip.loop)
                AutomationEditor(target: Self.target, points: clip.gainEnvelope ?? [],
                                 pixelsPerTick: Double(geo.size.width) / Double(max(1, clip.length.rawValue)),
                                 width: geo.size.width, height: geo.size.height, tint: tint) { pts in
                    model.apply(.setClipEnvelope(clip: clip.id, points: pts))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line, lineWidth: 1))
    }
}
