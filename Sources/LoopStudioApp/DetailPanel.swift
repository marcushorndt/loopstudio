import LoopStudioCore
import SwiftUI

/// The bottom panel: clip properties and follow actions on the left, the device chain on the right.
struct DetailPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // The Clip / Track switch sits in the footer, at the bottom right (`DetailTabs`).
        Group {
            switch model.detailTab {
            case .clip: ClipPanel().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .devices: DeviceChainView().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Theme.panel)
    }
}

/// The Clip / Track switch of the bottom panel, in the footer.
struct DetailTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            tab("Clip", .clip)
            tab("Track", .devices)
        }
        .padding(2)
        .background(Theme.panelRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.radius + 1))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius + 1).strokeBorder(Theme.line, lineWidth: 1))
    }

    private func tab(_ title: String, _ value: DetailTab) -> some View {
        let on = model.detailTab == value
        return Button { model.detailTab = value } label: {
            Text(title).font(.system(size: 11, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.text : Theme.dim)
                .padding(.horizontal, 10).padding(.vertical, 2)
                .background(on ? Theme.accent.opacity(0.35) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.radius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

/// A dropdown field for inspector headers: a label and a chevron in a box with a light border.
struct PillMenu<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu { content() } label: {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 8).frame(minWidth: 96, minHeight: 22, maxHeight: 22)
            .background(Theme.panelRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.radius + 2))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius + 2).strokeBorder(Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

/// A column of the clip panel that folds to a thin strip, so the editor next to it gets the room.
/// The chevron at its top right folds it; a click on the strip opens it again.
private struct FoldableColumn<Content: View>: View {
    @Environment(AppModel.self) private var model
    let id: String
    let title: String
    let width: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if model.foldedSections.contains(id) {
            Button { model.foldedSections.remove(id) } label: {
                VStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.6)
                        .fixedSize().rotationEffect(.degrees(90)).frame(width: 14, height: 70)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.dim)
                .padding(.top, 4)
                .frame(width: 22)
                .frame(maxHeight: .infinity)
                .background(Theme.panelRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.radius))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hint("Show \(title)")
        } else {
            // The chevron sits in its own gutter on the title row, so it never crowds a dropdown.
            HStack(alignment: .top, spacing: 4) {
                Button { model.foldedSections.insert(id) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.dim)
                        .frame(width: 14, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hint("Fold \(title) to make room for the editor")
                // A short inspector scrolls the column instead of cutting it at the top and the bottom.
                ScrollView(.vertical) {
                    content().frame(width: width, alignment: .topLeading)
                }
                .frame(width: width)
                .scrollIndicators(.automatic)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct ClipPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.recording, let track = recordingTrack {
            RecordingPanel(track: track)
        } else if let id = model.selectedClip, let (trackID, clip) = model.project.findClip(id), let track = model.project.track(trackID) {
            let slotRow = track.slots.firstIndex { $0?.clip.id == id }
            HStack(alignment: .top, spacing: 14) {
                FoldableColumn(id: "clip", title: "Clip", width: 230) { properties(clip, track: track) }
                if case .audio(let a) = clip {
                    FoldableColumn(id: "sound", title: "Sound", width: 250) { soundColumn(a) }
                    FoldableColumn(id: "warp", title: "Warp", width: 250) { WarpColumn(clip: a) }
                }
                if let row = slotRow, let slot = track.slots[row] {
                    FoldableColumn(id: "launch", title: "Launch", width: 280) { FollowEditor(track: track, row: row, slot: slot) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: model.clipName(clip)) { pagePicker(clip) }
                    mainArea(clip, track: track)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack { Spacer(); Text("Select a clip to see its settings.").foregroundStyle(Theme.dim); Spacer() }
                .frame(maxWidth: .infinity)
        }
    }

    /// While a take records: the selected track if it records, else the first track of the take.
    private var recordingTrack: Track? {
        let ids = model.takeTracks
        let id = model.selectedTrack.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        return id.flatMap { model.project.track($0) }
    }

    /// The pages of the main area. A dummy clip has only automation, so it gets no picker.
    @ViewBuilder
    private func pagePicker(_ clip: Clip) -> some View {
        if case .dummy = clip { EmptyView() } else {
            Picker("", selection: Binding(get: { model.page(for: clip) }, set: { model.clipPage = $0 })) {
                if case .midi = clip { Text("Notes").tag(ClipPage.content) } else { Text("Sample").tag(ClipPage.content) }
                if case .audio = clip { Text("Gain").tag(ClipPage.gain) }
                Text("Automation").tag(ClipPage.automation)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
        }
    }

    @ViewBuilder
    private func mainArea(_ clip: Clip, track: Track) -> some View {
        let tint = Theme.track(clip.colorIndex ?? track.colorIndex)
        switch (model.page(for: clip), clip) {
        case (.automation, _):
            ClipLanesPanel(clip: clip, track: track, tint: tint)
        case (_, .midi(let m)):
            PianoRoll(clip: m, tint: tint)
        case (let page, .audio(let a)):
            if let peaks = model.waveforms[a.asset], let asset = model.project.asset(a.asset) {
                if page == .gain {
                    ClipEnvelopeView(clip: a, peaks: peaks, sourceAt: model.waveMap(a, asset, elapsed: 0, length: a.length), tint: tint)
                        .overlay { clipLengthPlayhead(clip) }
                } else {
                    SampleEditor(clip: a, asset: asset, peaks: peaks, tint: tint)
                }
            } else {
                Spacer()
            }
        default:
            Spacer()
        }
    }

    /// A play position line for an editor whose width is the clip length.
    private func clipLengthPlayhead(_ clip: Clip) -> some View {
        GeometryReader { geo in
            ClipPlayhead(clip: clip.id, period: clip.length) { t in
                geo.size.width * CGFloat(t.rawValue) / CGFloat(max(1, clip.length.rawValue))
            }
        }
    }

    @ViewBuilder
    private func properties(_ clip: Clip, track: Track) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Clip") {
                PillMenu(label: "Automate") { ClipLaneToggles(clip: clip, track: track) }
            }
            switch clip {
            case .audio(let a):
                Toggle("Loop", isOn: Binding(get: { a.loop }, set: { model.apply(.setClipLoop(clip: a.id, loop: $0)) }))
                Toggle("Clip active", isOn: Binding(get: { !a.muted }, set: { set(a, muted: !$0) }))
                Stepper("Length  \(beatsText(a.length))", onIncrement: { resize(a.id, a.start, a.length, by: 1) },
                        onDecrement: { resize(a.id, a.start, a.length, by: -1) })
                ClipFilePositions(clip: a)
            case .midi(let m):
                Toggle("Loop", isOn: Binding(get: { m.loop }, set: { model.apply(.setClipLoop(clip: m.id, loop: $0)) }))
                Stepper("Length  \(beatsText(m.length))", onIncrement: { resize(m.id, m.start, m.length, by: 4) },
                        onDecrement: { resize(m.id, m.start, m.length, by: -4) })
                GrooveControls(clip: m)
                Text("Double-click the grid to add a note. Drag to move, drag an edge to resize. B turns the pen on.")
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
            slider("Gain", value: a.gainDb, range: -36...12, format: "%.1f dB", step: 0.5, fine: 0.1, reset: 0) { set(a, gain: $0) }
                .contextMenu {
                    Button(model.clipPage == .gain ? "Hide Gain Envelope" : "Show Gain Envelope") {
                        model.clipPage = model.clipPage == .gain ? .content : .gain
                    }
                    Button("Clear Gain Envelope") { model.apply(.setClipEnvelope(clip: a.id, points: [])) }
                        .disabled(a.gainEnvelope?.isEmpty ?? true)
                    Divider()
                    Button("Reset Gain") { set(a, gain: 0) }
                }
            slider("Fade in", value: a.fadeInMs, range: 0...200, format: "%.1f ms", step: 1, fine: 0.1, reset: AudioClip.defaultFadeMs) { set(a, fadeIn: $0) }
            slider("Fade out", value: a.fadeOutMs, range: 0...200, format: "%.1f ms", step: 1, fine: 0.1, reset: AudioClip.defaultFadeMs) { set(a, fadeOut: $0) }
            Spacer()
        }
        .font(.system(size: 12))
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

    /// A slider with its value as a field: click the value, then Up and Down step it (Shift: finer), type a
    /// number, or drag up and down. A double-click on the value or the label sets the default.
    private func slider(_ label: String, value: Double, range: ClosedRange<Double>, format: String, step: Double, fine: Double,
                        reset: Double, set: @escaping (Double) -> Void) -> some View {
        let clamp = { (v: Double) in min(range.upperBound, max(range.lowerBound, v)) }
        return HStack {
            Text(label).frame(width: 52, alignment: .leading)
                .onTapGesture(count: 2) { set(reset) }
            Slider(value: Binding(get: { value }, set: set), in: range).controlSize(.small)
            StepSegment(text: String(format: format, value), width: 62,
                        step: { n, shift in set(clamp(((value + Double(n) * (shift ? fine : step)) / fine).rounded() * fine)) },
                        typed: { buffer in if let v = Double(buffer.replacingOccurrences(of: ",", with: ".")) { set(clamp(v)) } },
                        reset: { set(reset) })
                .hint("Click, then Up or Down (Shift: finer), or type a number. Drag up or down. Double-click: the default.")
        }
    }
}

/// Launch quantize and the two follow actions A and B with their chance.
private struct FollowEditor: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let row: Int
    let slot: SessionSlot
    @State private var timeText = ""

    private func timeString(_ f: FollowActions) -> String { MusicalLength.format(Tick(f.time.amount), ticksPerBar: model.barTicks) }

    /// A time in ticks is typed as bars:beats:sixteenths, like the clip lengths.
    private func commitTime(_ f: FollowActions) {
        if let ticks = MusicalLength.parse(timeText, ticksPerBar: model.barTicks), ticks.rawValue >= Tick.perQuarter / 4 {
            var s = slot; s.follow?.time.amount = ticks.rawValue; commit(s)
        } else {
            model.status = "Enter the time as bars:beats:sixteenths, for example 2:0:0"
        }
        timeText = timeString(f)
    }

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
                    if f.time.unit == .loops {
                        Stepper(value: Binding(get: { Int(f.time.amount) }, set: { var s = slot; s.follow?.time.amount = Int64($0); commit(s, key: "time") }), in: 1...64) {
                            Text("\(f.time.amount)")
                        }
                    } else {
                        TextField("bars:beats:16ths", text: $timeText)
                            .textFieldStyle(.roundedBorder).frame(width: 80)
                            .onSubmit { commitTime(f) }
                            .onAppear { timeText = timeString(f) }
                            .onChange(of: f.time.amount) { timeText = timeString(f) }
                            .hint("Time until the follow action, as bars:beats:sixteenths")
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

/// The automation lanes of a clip, one editor per lane. Points count from the start of the clip.
private struct ClipLanesPanel: View {
    @Environment(AppModel.self) private var model
    let clip: Clip
    let track: Track
    let tint: Color

    private var cycle: Tick { clip.automationCycle }
    @State private var lengthText = ""

    private func commitLength() {
        if let ticks = MusicalLength.parse(lengthText, ticksPerBar: model.barTicks), ticks.rawValue >= Tick.perQuarter / 4 {
            model.apply(.setClipAutomationLength(clip: clip.id, length: ticks))
        } else {
            model.status = "Enter a length as bars:beats:sixteenths, for example 4:2:0"
        }
        lengthText = MusicalLength.format(clip.automationCycle, ticksPerBar: model.barTicks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .dummy = clip {} else { linkRow }
            lanesBody
        }
    }

    /// Linked: the curves loop with the clip. Unlinked: they run their own length over the looping clip.
    private var linkRow: some View {
        let linked = clip.automationLength == nil
        let bars = Double(cycle.rawValue) / Double(model.barTicks)
        return HStack(spacing: 8) {
            Toggle("Link to clip length", isOn: Binding(get: { linked }, set: { on in
                model.apply(.setClipAutomationLength(clip: clip.id, length: on ? nil : clip.length))
            }))
            .toggleStyle(.checkbox)
            .hint("Linked: the automation loops with the clip. Unlinked: it has its own length, for example 16 bars over a 1-bar loop.")
            if !linked {
                TextField("bars:beats:16ths", text: $lengthText)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced)).frame(width: 78)
                    .onSubmit { commitLength() }
                    .onAppear { lengthText = MusicalLength.format(cycle, ticksPerBar: model.barTicks) }
                    .onChange(of: cycle) { lengthText = MusicalLength.format(cycle, ticksPerBar: model.barTicks) }
                    .hint("Length of the automation as bars:beats:sixteenths, for example 4:2:0 or 0:1:1. Press Return.")
                Stepper("", value: Binding(get: { bars }, set: { v in
                    let ticks = Int64((max(0.25, v) * Double(model.barTicks)).rounded())
                    model.apply(.setClipAutomationLength(clip: clip.id, length: Tick(ticks)), key: "autolen\(clip.id)")
                }), in: 0.25...512, step: bars < 1 ? 0.25 : 1)
                .labelsHidden().controlSize(.small)
                Menu("Presets") {
                    ForEach([1, 2, 4, 8, 16, 32, 64], id: \.self) { n in
                        Button("\(n) bar" + (n == 1 ? "" : "s")) {
                            model.apply(.setClipAutomationLength(clip: clip.id, length: Tick(Int64(n) * model.barTicks)))
                        }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
            }
            if case .audio = clip {
                Toggle("Waveform", isOn: Binding(get: { model.lanesWaveform }, set: { model.lanesWaveform = $0 }))
                    .toggleStyle(.checkbox)
                    .hint("Show the clip's sound under the curves")
            }
            Spacer(minLength: 0)
            // The picker lives on the page itself: the Clip column that also holds it may be folded away.
            PillMenu(label: "Automate") { ClipLaneToggles(clip: clip, track: track) }
                .hint("Pick a parameter to automate in this clip: the mixer, or any device on the track and its parameters.")
        }
        .font(.system(size: 11))
    }

    @ViewBuilder
    private var lanesBody: some View {
        let lanes = model.shownClipLanes(clip, owner: track)
        if lanes.isEmpty {
            VStack(spacing: 6) {
                Text("No clip automation shown").font(.system(size: 12, weight: .medium))
                Text(hint).font(.system(size: 11)).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
                PillMenu(label: "Automate…") { ClipLaneToggles(clip: clip, track: track) }.padding(.top, 4)
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

    /// An audio clip's sound under its curves, over the whole cycle: what plays where the curve moves.
    @ViewBuilder
    private func laneWaveform(width: CGFloat) -> some View {
        if model.lanesWaveform, case .audio(let a) = clip, let peaks = model.waveforms[a.asset], let asset = model.project.asset(a.asset) {
            WaveformView(peaks: peaks, color: tint.opacity(0.28), sourceAt: model.waveMap(a, asset, elapsed: 0, length: cycle), gainDb: a.gainDb)
        }
    }

    /// Where the clip loops inside a longer, unlinked automation cycle.
    private func loopMarks(ppt: Double) -> some View {
        Canvas { ctx, size in
            let step = clip.length.rawValue
            guard clip.automationLength != nil, step > 0, step < cycle.rawValue else { return }
            var t = step
            while t < cycle.rawValue {
                let x = CGFloat(Double(t) * ppt)
                ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(Theme.dim.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                t += step
            }
        }
    }

    private var hint: String {
        if case .dummy = clip { return "Pick what this clip moves: any track, or any device and its parameters.\nIt moves them while it plays." }
        return "Pick a parameter of this track: the mixer, or a device and its parameters.\nWhile the clip plays, its curve overrides the track automation.\nA knob's right-click menu offers this clip too."
    }

    @ViewBuilder
    private func laneRow(_ address: ParameterAddress, height: CGFloat, width: CGFloat) -> some View {
        if let target = model.project.clipAutomationTargets(clip, owner: track).first(where: { $0.address == address }) {
            let points = clip.lanes.first { $0.target == address }?.points ?? []
            let ppt = Double(width) / Double(max(1, cycle.rawValue))
            AutomationEditor(target: target, points: points, pixelsPerTick: ppt,
                             width: width, height: height - 2, tint: tint, pen: model.drawMode, penGrid: model.noteGrid) { pts in
                model.apply(.setClipAutomation(clip: clip.id, target: address, points: pts))
            }
            .overlay { laneWaveform(width: width).allowsHitTesting(false) }
            .overlay { loopMarks(ppt: ppt).allowsHitTesting(false) }
            .overlay { ClipPlayhead(clip: clip.id, period: cycle) { CGFloat(Double($0.rawValue) * ppt) } }
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
                        Button { model.apply(.setClipAutomation(clip: clip.id, target: address, points: [])) } label: {
                            Image(systemName: "trash").font(.system(size: 10)).frame(width: 20, height: 20).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).hint("Delete this curve")
                    }
                    Button { model.setClipLane(clip, owner: track, address, shown: false) } label: {
                        Image(systemName: "xmark").font(.system(size: 10)).frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).hint("Hide this lane")
                }
                .foregroundStyle(Theme.dim).padding(2)
            }
        }
    }
}

/// The checkmark items of a clip's Automate menu: which clip lanes the inspector shows.
struct ClipLaneToggles: View {
    @Environment(AppModel.self) private var model
    let clip: Clip
    let track: Track

    var body: some View {
        let used = clip.lanes.filter { !$0.points.isEmpty }.map(\.target)
        Button("Lanes With Points") { model.clipLanesShown[clip.id] = used; model.clipPage = .automation }.disabled(used.isEmpty)
        Button("Hide All") { model.clipLanesShown[clip.id] = [] }.disabled(model.shownClipLanes(clip, owner: track).isEmpty)
        if track.clips.contains(where: { $0.id == clip.id }) {
            Button("Move Clip Automation to Track") { model.moveClipAutomationToTrack(clip.id) }.disabled(used.isEmpty)
        }
        Divider()
        // One submenu per device (and the mixer), so a plugin with a hundred parameters stays a short pick.
        let automated = Set(used)
        let shown = Set(model.shownClipLanes(clip, owner: track))
        let groups = LaneGroup.groups(model.project.clipAutomationTargets(clip, owner: track), mixer: [track.id.rawValue, ParameterAddress.ownTrack])
        ForEach(groups) { group in
            let marked = group.targets.contains { automated.contains($0.address) }
            Menu(marked ? "● " + group.name : group.name) {
                ForEach(group.targets, id: \.address) { target in
                    Toggle(isOn: Binding(
                        get: { shown.contains(target.address) },
                        set: { model.setClipLane(clip, owner: track, target.address, shown: $0) })) {
                        laneLabel(target, automated: automated)
                    }
                }
            }
        }
    }
}

/// The clip gain envelope drawn over the clip's waveform. Points count from the clip start.
private struct ClipEnvelopeView: View {
    @Environment(AppModel.self) private var model
    let clip: AudioClip
    let peaks: WavePeaks
    let sourceAt: (Double) -> Double
    let tint: Color

    private static let target = AutomationTarget(
        address: ParameterAddress(node: UUID(), parameter: "clipGain"), name: "Clip Gain",
        min: -60, max: 12, def: 0, unit: "dB", logarithmic: false, choices: [])

    var body: some View {
        GeometryReader { geo in
            ZStack {
                WaveformView(peaks: peaks, color: tint.opacity(0.45), sourceAt: sourceAt, gainDb: clip.gainDb)
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

/// The play position inside a clip editor: a line that moves while the clip plays, hidden otherwise.
/// `period` folds the position: the clip loop for the sample, the automation cycle for the curves.
struct ClipPlayhead: View {
    @Environment(AppModel.self) private var model
    let clip: ClipID
    let period: Tick
    let x: (Tick) -> CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.transportPlaying)) { _ in
            if let offset = model.clipPlayOffset(clip) {
                let t = Tick(offset.rawValue % max(1, period.rawValue))
                Rectangle().fill(Theme.play).frame(width: 1.5)
                    .offset(x: x(t) - 0.75)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The start marker and the loop of an audio clip as numbers, in bars:beats:sixteenths of the file. Each
/// part steps on its own; a typed sixteenth can have decimals, so a value can sit between the grid lines.
struct ClipFilePositions: View {
    @Environment(AppModel.self) private var model
    let clip: AudioClip

    private var session: Bool { model.isSessionClip(clip.id) }
    private var fileTicks: Tick {
        guard let asset = model.project.asset(clip.asset) else { return clip.length }
        return model.fileTicks(clip, asset)
    }
    private var region: (start: Tick, length: Tick) {
        let r = clip.loopRegion(session: session)
        return (r.start, r.length ?? Tick(max(1, fileTicks.rawValue - r.start.rawValue)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("In the file").font(.caption).foregroundStyle(Theme.dim)
            TickRow(title: "Start", value: clip.offset, minimum: 0, reset: { setStart(clip.loop ? region.start : 0) }, commit: setStart)
                .hint("Start marker: where playback begins in the file. Click a part, then Up or Down. Double-click: back to the loop start, or without Loop to the file start.")
            TickRow(title: "Loop start", value: region.start, minimum: 0, reset: { setLoopStart(0) }, commit: setLoopStart)
                .opacity(clip.loop ? 1 : 0.6)
                .hint("Where the loop begins in the file. The start marker can sit before it (an intro) or inside it. Without Loop it is kept for when Loop is on.")
            TickRow(title: "Loop length", value: region.length, minimum: Tick.perQuarter / 64, isLength: true,
                    reset: { setLoopLength(Tick(max(1, fileTicks.rawValue - region.start.rawValue))) }, commit: setLoopLength)
                .opacity(clip.loop ? 1 : 0.6)
                .hint("How long the loop is. Without Loop it is kept for when Loop is on.")
        }
    }

    private func apply(_ c: AudioClip) {
        guard c != clip else { return }
        model.apply(.setClip(clip: .audio(c)), key: "positions\(clip.id)")
    }

    private func setStart(_ t: Tick) {
        var c = clip
        // A session loop without a start of its own starts at the start marker: pin it, so it stays.
        if session && c.loopStart == nil { c.loopStart = region.start }
        let end = region.start + region.length
        c.offset = clip.loop ? Tick(min(t.rawValue, end.rawValue - 1)) : t
        apply(c)
    }

    private func setLoopStart(_ t: Tick) {
        var c = clip
        let length = region.length
        c.loopStart = t
        if !session { c.loopLength = length }
        if clip.loop && c.offset >= t + length { c.offset = t }
        apply(c)
    }

    private func setLoopLength(_ t: Tick) {
        var c = clip
        c.loopStart = region.start
        if session { c.length = t } else { c.loopLength = t }
        if clip.loop && c.offset >= region.start + t { c.offset = region.start }
        apply(c)
    }
}

/// One position or length: a title and three segments, bars, beats and sixteenths. Click a segment, then
/// Up and Down step only it; type digits to set it; drag up and down; double-click for the default.
/// A position counts from 1 like the ruler (1:1:1 is the file start); a length counts from 0.
private struct TickRow: View {
    @Environment(AppModel.self) private var model
    let title: String
    let value: Tick
    let minimum: Int64
    var isLength = false
    let reset: () -> Void
    let commit: (Tick) -> Void

    private var units: [Int64] { [model.barTicks, Tick.perQuarter, Tick.perQuarter / 4] }
    private var base: Int64 { isLength ? 0 : 1 }

    /// Bars, beats and sixteenths, as shown; the sixteenths keep a part between the grid lines.
    private var parts: (bars: Int64, beats: Int64, sixteenths: Double) {
        let v = max(0, value.rawValue), u = units
        let rest = v % max(1, u[0])
        return (v / max(1, u[0]) + base, rest / u[1] + base, Double(rest % u[1]) / Double(u[2]) + Double(base))
    }

    var body: some View {
        HStack(spacing: 2) {
            Text(title).frame(width: 72, alignment: .leading)
            let p = parts
            segment(0, String(p.bars))
            Text(":").foregroundStyle(Theme.dim)
            segment(1, String(p.beats))
            Text(":").foregroundStyle(Theme.dim)
            segment(2, p.sixteenths == p.sixteenths.rounded() ? String(Int(p.sixteenths))
                    : String(format: "%.2f", p.sixteenths).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression))
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private func segment(_ i: Int, _ text: String) -> some View {
        StepSegment(text: text, width: i == 2 ? 34 : 26,
                    step: { n, _ in commit(Tick(max(minimum, value.rawValue + Int64(n) * units[i]))) },
                    typed: { buffer in set(i, buffer) },
                    reset: reset)
    }

    /// Sets one segment to a typed number and keeps the others.
    private func set(_ i: Int, _ buffer: String) {
        guard let n = Double(buffer.replacingOccurrences(of: ",", with: ".")), n >= Double(base) else { return }
        let u = units, v = max(0, value.rawValue)
        let bars = v / u[0], beats = (v % u[0]) / u[1], rest = v % u[1]
        var t: Int64
        switch i {
        case 0: t = Int64(n.rounded(.down) - Double(base)) * u[0] + beats * u[1] + rest
        case 1: t = bars * u[0] + Int64(n.rounded(.down) - Double(base)) * u[1] + rest
        default: t = bars * u[0] + beats * u[1] + Int64(((n - Double(base)) * Double(u[2])).rounded())
        }
        t = max(minimum, t)
        if t != value.rawValue { commit(Tick(t)) }
    }
}

/// A number you click and then step with Up and Down (Shift passes `true`), set by typing, or drag up and
/// down. While it has the focus the app's key shortcuts leave those keys to it.
struct StepSegment: View {
    @Environment(AppModel.self) private var model
    let text: String
    var width: CGFloat? = nil
    let step: (Int, Bool) -> Void
    let typed: (String) -> Void
    let reset: () -> Void
    @State private var id = UUID()
    @State private var buffer = ""
    @State private var dragged = 0
    @FocusState private var focused: Bool

    var body: some View {
        Text(text)
            .frame(width: width, alignment: .trailing)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(focused ? Theme.accent.opacity(0.35) : Theme.panel, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(focused ? Theme.accent : Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onTapGesture(count: 2) { reset() }
            .onTapGesture { focused = true }
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { g in
                    focused = true
                    let n = Int(-g.translation.height / 6)
                    if n != dragged { step(n - dragged, NSEvent.modifierFlags.contains(.shift)); dragged = n }
                }
                .onEnded { _ in dragged = 0 })
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                buffer = ""
                step(press.key == .upArrow ? 1 : -1, press.modifiers.contains(.shift))
                return .handled
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "0123456789.,-")) { press in
                buffer += press.characters
                typed(buffer)
                return .handled
            }
            .onKeyPress(.delete) { buffer = String(buffer.dropLast()); if !buffer.isEmpty { typed(buffer) }; return .handled }
            .onKeyPress(.return) { buffer = ""; focused = false; return .handled }
            .onKeyPress(.escape) { buffer = ""; focused = false; return .handled }
            .onChange(of: focused) { _, now in
                buffer = ""
                if now { model.focusedSegment = id } else if model.focusedSegment == id { model.focusedSegment = nil }
            }
    }
}
