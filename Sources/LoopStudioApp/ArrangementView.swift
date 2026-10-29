import LoopStudioCore
import SwiftUI

private let laneHeight: CGFloat = 74
private let headerWidth: CGFloat = 176
private let rulerHeight: CGFloat = 28

struct ArrangementView: View {
    @Environment(AppModel.self) private var model
    @State private var marquee: CGRect?

    var body: some View {
        let tracks = model.orderedTracks
        let bars = totalBars
        let width = CGFloat(Double(bars) * model.pixelsPerBar)

        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(Theme.dim)
                        Slider(value: Bindable(model).pixelsPerBar, in: 24...420).controlSize(.mini)
                        Button { model.toggleAutomationView() } label: {
                            Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 11))
                                .foregroundStyle(model.anyLanesShown ? Theme.accent : Theme.dim)
                                .frame(width: 22, height: 18)
                                .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                                    .stroke(model.anyLanesShown ? Theme.accent.opacity(0.55) : Theme.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain).hint("Show or hide automation lanes on all tracks (A)")
                    }
                    .padding(.horizontal, 8).frame(height: rulerHeight)
                    ForEach(tracks, id: \.id) { ArrangementHeader(track: $0) }
                    // The master sits at the bottom, as in Live: it holds the master automation.
                    ArrangementHeader(track: model.project.master)
                    Button { model.addTrack() } label: { Label("Add track", systemImage: "plus").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(Theme.dim).frame(height: 36)
                }
                .frame(width: headerWidth)

                ScrollView(.horizontal) {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            Ruler(bars: bars).frame(width: width, height: rulerHeight)
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                Lane(track: track, index: index, count: tracks.count, width: width)
                            }
                            Lane(track: model.project.master, index: tracks.count, count: tracks.count, width: width)
                        }
                        SelectionOverlay(tracks: tracks)
                        if let m = marquee {
                            Rectangle().fill(Theme.accent.opacity(0.15)).overlay(Rectangle().stroke(Theme.accent, lineWidth: 1))
                                .frame(width: m.width, height: m.height).offset(x: m.minX, y: m.minY).allowsHitTesting(false)
                        }
                        LoopBrace(width: width)
                        Playhead(height: rulerHeight + model.rowsHeight)
                    }
                    .frame(width: width, alignment: .topLeading)
                    .gesture(DragGesture(minimumDistance: 5)
                        .onChanged { g in
                            guard g.startLocation.y > rulerHeight else { return }
                            marquee = CGRect(x: min(g.startLocation.x, g.location.x), y: min(g.startLocation.y, g.location.y),
                                             width: abs(g.location.x - g.startLocation.x), height: abs(g.location.y - g.startLocation.y))
                        }
                        .onEnded { g in
                            defer { marquee = nil }
                            guard let m = marquee, !tracks.isEmpty else { return }
                            let first = model.rowIndex(atY: max(0, m.minY - rulerHeight))
                            let last = model.rowIndex(atY: max(0, m.maxY - rulerHeight))
                            guard first <= last else { return }
                            let ids = Set(tracks[first...last].map(\.id))
                            let a = model.snap(xTick(m.minX, model)), b = model.snap(xTick(m.maxX, model))
                            model.selectRange(from: a, to: b > a ? b : a + Tick(Tick.perQuarter), tracks: ids)
                        })
                }
            }
        }
        .background(Theme.background)
    }

    private var totalBars: Int {
        var end: Int64 = 0
        for t in model.project.tracks { for c in t.clips { end = max(end, (c.start + c.length).rawValue) } }
        let bars = Int(end / max(1, model.barTicks)) + 16
        return max(48, bars)
    }
}

@MainActor func tickX(_ tick: Tick, _ model: AppModel) -> CGFloat {
    CGFloat(Double(tick.rawValue) / Double(model.barTicks) * model.pixelsPerBar)
}

@MainActor func xTick(_ x: CGFloat, _ model: AppModel) -> Tick {
    Tick(Int64(max(0, Double(x) / model.pixelsPerBar * Double(model.barTicks))))
}

private struct ArrangementHeader: View {
    @Environment(AppModel.self) private var model
    let track: Track

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.track(track.colorIndex)).frame(width: 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    if track.kind != .master {
                        pill("S", on: track.solo, tint: Theme.track(5)) { model.toggleSolo(track) }
                            .hint("Solo this track only. ⌘-click adds it to the soloed tracks.")
                    }
                    pill("M", on: track.mute, tint: Theme.accent) { model.apply(.setMute(id: track.id, mute: !track.mute)) }
                    pill("A", on: !model.shownLanes(track).isEmpty, tint: Theme.track(0)) { model.toggleAutomation(track) }
                        .hint("Show automation")
                    if track.kind == .audio || track.kind == .midi {
                        pill("●", on: model.armedTracks.contains(track.id), tint: .red) { model.toggleArm(track.id) }
                            .hint("Arm this track only: it records and plays the MIDI keyboard. ⌘-click adds it to the armed tracks.")
                    }
                }
            }
            Spacer()
        }
        .padding(6).frame(height: laneHeight, alignment: .top)
        .frame(height: model.rowHeight(track), alignment: .top)
        .background(model.selectedTrack == track.id ? Theme.panelRaised : Theme.panel)
        .overlay(alignment: .bottom) { AutomationLabels(track: track) }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        // The single click acts at once; a double-click also opens the inspector. A double-click handler that
        // runs first would hold every single click back until the double-click time has passed.
        .onTapGesture { model.focusTrack(track.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.openTrackInspector(track.id) })
        .contextMenu {
            if track.kind == .master { AutomationLanesMenu(track: track) } else { TrackMenuItems(track: track, showsAutomation: true) }
        }
        .dropDestination(for: String.self) { items, _ in
            return model.dropDevices(items, on: track.id)
        }
    }

    private func pill(_ label: String, on: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 10, weight: .bold)).frame(width: 24, height: 18)
                .foregroundStyle(on ? tint : Theme.dim)
                .background(on ? tint.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(on ? tint.opacity(0.55) : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct Ruler: View {
    @Environment(AppModel.self) private var model
    let bars: Int

    var body: some View {
        Canvas { ctx, size in
            let ppb = model.pixelsPerBar
            let every = ppb < 40 ? 4 : (ppb < 70 ? 2 : 1)
            for bar in 0..<bars where bar % every == 0 {
                let x = CGFloat(Double(bar) * ppb)
                ctx.fill(Path(CGRect(x: x, y: size.height - 10, width: 1, height: 10)), with: .color(Theme.dim))
                ctx.draw(Text("\(bar + 1)").font(.system(size: 10)).foregroundStyle(Theme.dim), at: CGPoint(x: x + 4, y: 8), anchor: .leading)
            }
        }
        .background(Theme.panel)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { model.seek(to: xTick($0.location.x, model)) })
        .contextMenu { RulerMenu() }
    }
}

private struct Lane: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let index: Int
    let count: Int
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                let ppb = model.pixelsPerBar
                var bar = 0
                while CGFloat(Double(bar) * ppb) < size.width {
                    let x = CGFloat(Double(bar) * ppb)
                    ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.10)))
                    if ppb > 140 {
                        for beat in 1..<4 {
                            ctx.fill(Path(CGRect(x: x + CGFloat(Double(beat) * ppb / 4), y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.04)))
                        }
                    }
                    bar += 1
                }
            }
            ForEach(track.clips, id: \.id) { clip in
                ArrangementClip(clip: clip, track: track, trackIndex: index, trackCount: count)
            }
            ForEach(Array(model.shownLanes(track).enumerated()), id: \.element) { i, address in
                if let target = model.project.automationTarget(address) {
                    AutomationEditor(target: target, points: model.automationPoints(track, address),
                                     pixelsPerTick: model.pixelsPerBar / Double(model.barTicks),
                                     width: width, height: AppModel.automationRow, tint: Theme.track(track.colorIndex)) { pts in
                        model.apply(.setAutomation(track: track.id, target: address, points: pts))
                    }
                    .overlay(alignment: .topLeading) { ClipOverrideSpans(address: address) }
                    .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                    .offset(y: laneHeight + CGFloat(i) * AppModel.automationRow)
                }
            }
        }
        .frame(width: width, height: model.rowHeight(track), alignment: .topLeading)
        .background(Theme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedTrack = track.id; model.clearSelection() }
        .contextMenu { LaneMenu(track: track) }
        .gesture(SpatialTapGesture(count: 2).onEnded { v in
            if track.kind == .midi { model.createMIDIClip(track: track.id, at: xTick(v.location.x, model)) }
        })
        .dropDestination(for: URL.self) { urls, location in
            model.dropOnTimeline(urls, track: track.id, at: xTick(location.x, model))
        }
    }
}

private struct ArrangementClip: View {
    @Environment(AppModel.self) private var model
    let clip: Clip
    let track: Track
    let trackIndex: Int
    let trackCount: Int
    @State private var drag: CGSize = .zero
    @State private var resize: CGFloat = 0
    /// A drag of the left edge, in points: it trims or extends the start, the content stays in place.
    @State private var trim: CGFloat = 0

    /// The clip being dragged follows its own gesture; the rest of a marked group follows it.
    private var shown: CGSize { drag != .zero ? drag : (model.selectedClips.contains(clip.id) ? model.groupDrag : .zero) }

    var body: some View {
        let tint = Theme.track(clip.colorIndex ?? track.colorIndex)
        let x = tickX(clip.start, model)
        let w = max(6, tickX(clip.length, model) + resize - trim)
        let selected = model.selectedClips.contains(clip.id) || model.selectedClip == clip.id
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.clipBody(clip.colorIndex ?? track.colorIndex))
            if case .audio(let a) = clip, let peaks = model.waveforms[a.asset], let asset = model.project.asset(a.asset) {
                let assetTicks = Double(asset.frames) / max(1, asset.sampleRate) * model.bpm / 60 * Double(Tick.perQuarter)
                WaveformView(peaks: peaks, color: tint.opacity(0.9), fraction: Double(clip.length.rawValue) / max(1, assetTicks), loop: a.loop,
                             start: Double(a.offset.rawValue) / max(1, assetTicks))
                    .padding(.top, 16).padding(.bottom, 3)
            }
            if case .audio(let a) = clip, let env = a.gainEnvelope, !env.isEmpty {
                EnvelopeLine(points: env, length: a.length, color: Theme.text.opacity(0.85)).padding(.top, 16).padding(.bottom, 3)
            }
            if !clip.lanes.isEmpty { MiniCurves(clip: clip, owner: track).padding(.top, 16).padding(.bottom, 3).padding(.horizontal, 2) }
            if case .midi(let m) = clip { MiniNotes(clip: m).padding(.top, 16).padding(.bottom, 3).padding(.horizontal, 2) }
            Text(model.clipName(clip)).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.onTint)
                .padding(.horizontal, 6).padding(.top, 3).lineLimit(1)
        }
        .frame(width: w, height: laneHeight - 6)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(selected ? Theme.text : tint.opacity(0.55), lineWidth: selected ? 1.5 : 1))
        .overlay(alignment: .leading) {
            Rectangle().fill(.clear).frame(width: 8).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { trim = $0.translation.width }
                    .onEnded { g in
                        let start = model.snap(xTick(tickX(clip.start, model) + g.translation.width, model))
                        trim = 0
                        if let trimmed = clip.trimmingStart(to: start) { model.apply(.setClip(clip: trimmed)) }
                        else { model.status = "The clip cannot start there: its audio begins later" }
                    })
                .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .hint("Drag to trim the start. The sound stays in place.")
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(.clear).frame(width: 8).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { resize = $0.translation.width }
                    .onEnded { g in
                        let end = model.snap(xTick(tickX(clip.start + clip.length, model) + g.translation.width, model))
                        resize = 0
                        if end > clip.start { model.apply(.setClipRange(clip: clip.id, start: clip.start, length: end - clip.start)) }
                    })
                .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
        }
        .offset(x: x + trim + shown.width, y: 3 + shown.height)
        .zIndex(shown == .zero ? 0 : 10)
        .onTapGesture {
            model.select(clip: clip.id, extend: NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command))
            model.selectedTrack = track.id
        }
        .gesture(DragGesture(minimumDistance: 4)
            .onChanged { g in
                if !model.selectedClips.contains(clip.id) { model.select(clip: clip.id, extend: false) }
                drag = g.translation
                model.groupDrag = g.translation
            }
            .onEnded { g in
                drag = .zero
                model.groupDrag = .zero
                let start = model.snap(xTick(x + g.translation.width, model))
                let shift = model.rowIndex(atY: model.rowTop(trackIndex) + laneHeight / 2 + g.translation.height) - trackIndex
                model.moveClips(Array(model.selectedClips.union([clip.id])), deltaTicks: start.rawValue - clip.start.rawValue, trackShift: shift)
            })
        .contextMenu { ArrangementClipMenu(clip: clip, track: track) }
    }
}

private struct Playhead: View {
    @Environment(AppModel.self) private var model
    let height: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.transportPlaying)) { _ in
            Rectangle().fill(.white).frame(width: 1.5, height: height)
                .offset(x: tickX(model.currentTick, model))
        }
        .allowsHitTesting(false)
    }
}

private struct LoopBrace: View {
    @Environment(AppModel.self) private var model
    let width: CGFloat
    @State private var dragStart: CGFloat = 0
    @State private var dragEnd: CGFloat = 0

    var body: some View {
        if let loop = model.project.loop, loop.enabled {
            let x0 = tickX(loop.start, model) + dragStart
            let x1 = tickX(loop.end, model) + dragEnd
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.accent.opacity(0.07)).frame(width: max(1, x1 - x0)).offset(x: x0)
                Rectangle().fill(Theme.accent).frame(width: max(1, x1 - x0), height: 5).offset(x: x0, y: rulerHeight - 5)
                handle(x: x0).gesture(DragGesture().onChanged { dragStart = $0.translation.width }.onEnded { g in
                    dragStart = 0
                    model.setLoop(start: model.snap(xTick(tickX(loop.start, model) + g.translation.width, model)), end: loop.end)
                })
                handle(x: x1 - 6).gesture(DragGesture().onChanged { dragEnd = $0.translation.width }.onEnded { g in
                    dragEnd = 0
                    model.setLoop(start: loop.start, end: model.snap(xTick(tickX(loop.end, model) + g.translation.width, model)))
                })
            }
        }
    }

    private func handle(x: CGFloat) -> some View {
        Rectangle().fill(Theme.accent).frame(width: 6, height: 14).offset(x: x, y: rulerHeight - 14).contentShape(Rectangle())
    }
}

/// The marked time range, drawn over each marked track.
private struct SelectionOverlay: View {
    @Environment(AppModel.self) private var model
    let tracks: [Track]

    var body: some View {
        if let r = model.rangeSelection {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                if r.tracks.contains(track.id) {
                    Rectangle().fill(.white.opacity(0.10))
                        .frame(width: max(1, tickX(r.end, model) - tickX(r.start, model)), height: model.rowHeight(track))
                        .offset(x: tickX(r.start, model), y: rulerHeight + model.rowTop(index))
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

/// A tiny picture of the notes of a MIDI clip.
private struct MiniNotes: View {
    let clip: MIDIClip

    var body: some View {
        Canvas { ctx, size in
            guard let lo = clip.notes.map(\.pitch).min(), let hi = clip.notes.map(\.pitch).max() else { return }
            let span = max(12, Int(hi) - Int(lo) + 1)
            let rowH = size.height / CGFloat(span)
            for n in clip.notes {
                let x = CGFloat(Double(n.tick.rawValue) / Double(max(1, clip.length.rawValue))) * size.width
                let w = max(2, CGFloat(Double(n.length.rawValue) / Double(max(1, clip.length.rawValue))) * size.width)
                let y = CGFloat(Int(hi) - Int(n.pitch)) * rowH
                ctx.fill(Path(CGRect(x: x, y: y, width: w, height: max(1.5, rowH - 0.5))), with: .color(Theme.text.opacity(0.75)))
            }
        }
    }
}

/// A clip gain envelope inside an arrangement clip, -60...+12 dB from bottom to top.
struct EnvelopeLine: View {
    let points: [AutomationPoint]
    let length: Tick
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let total = Double(max(1, length.rawValue))
            var path = Path()
            let steps = max(2, Int(size.width / 3))
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let v = AutomationMath.value(points, at: Tick(Int64(t * total))) ?? 0
                let y = size.height * (1 - CGFloat((min(max(v, -60), 12) + 60) / 72))
                let pt = CGPoint(x: CGFloat(t) * size.width, y: y)
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            ctx.stroke(path, with: .color(color), lineWidth: 1.2)
        }
    }
}

/// The automation curves of a clip, drawn small inside the clip, one dashed line per lane.
struct MiniCurves: View {
    @Environment(AppModel.self) private var model
    let clip: Clip
    let owner: Track

    var body: some View {
        Canvas { ctx, size in
            let length = Double(max(1, clip.length.rawValue))
            let cycle = clip.automationCycle.rawValue
            for lane in model.project.effectiveLanes(of: clip, owner: owner) {
                guard let target = model.project.automationTarget(lane.target) else { continue }
                var path = Path()
                let steps = max(2, Int(size.width / 3))
                for i in 0...steps {
                    let t = Double(i) / Double(steps)
                    let v = AutomationMath.value(lane.points, at: Tick(Int64(t * length) % cycle)) ?? target.def
                    let pt = CGPoint(x: CGFloat(t) * size.width, y: size.height * (1 - CGFloat(target.position(v))))
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                ctx.stroke(path, with: .color(Theme.text.opacity(0.8)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 2]))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Over a track lane: the spans where a clip's own automation overrides the lane, with the clip's curve.
/// A double-click opens that curve in the clip inspector.
private struct ClipOverrideSpans: View {
    @Environment(AppModel.self) private var model
    let address: ParameterAddress

    var body: some View {
        let target = model.project.automationTarget(address)
        ZStack(alignment: .topLeading) {
            ForEach(model.clipOverrides(address), id: \.clip.id) { item in
                let tint = Theme.track(item.tint)
                let w = max(4, tickX(item.clip.length, model))
                Canvas { ctx, size in
                    guard let target else { return }
                    let length = Double(max(1, item.clip.length.rawValue))
                    var path = Path()
                    let steps = max(2, Int(size.width / 3))
                    for i in 0...steps {
                        let t = Double(i) / Double(steps)
                        let v = AutomationMath.value(item.lane, at: Tick(Int64(t * length) % item.clip.automationCycle.rawValue)) ?? target.def
                        let pt = CGPoint(x: CGFloat(t) * size.width, y: size.height * (1 - CGFloat(target.position(v))))
                        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    ctx.stroke(path, with: .color(tint), lineWidth: 1.5)
                }
                .frame(width: w, height: AppModel.automationRow)
                .background(Theme.background.opacity(0.75))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(tint.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .overlay(alignment: .topLeading) {
                    Text("Clip: " + model.clipName(item.clip)).font(.system(size: 9, weight: .medium)).foregroundStyle(tint)
                        .lineLimit(1).padding(.horizontal, 4).padding(.top, 2)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { openInClip(item.clip) }
                .contextMenu {
                    Button("Edit in Clip") { openInClip(item.clip) }
                    Button("Move Clip Automation to Track") { model.moveClipAutomationToTrack(item.clip.id) }
                }
                .hint("The clip's own automation overrides this lane here. Double-click to edit it in the clip.")
                .offset(x: tickX(item.clip.start, model))
            }
        }
    }

    private func openInClip(_ clip: Clip) {
        guard let owner = model.project.findClip(clip.id).flatMap({ model.project.track($0.track) }) else { return }
        model.openClipAutomation(clip.id, address: model.clipAddress(address, in: clip, owner: owner))
    }
}

/// Header column of the automation lanes: one label per lane, and a menu to choose the lanes.
private struct AutomationLabels: View {
    @Environment(AppModel.self) private var model
    let track: Track

    var body: some View {
        let lanes = model.shownLanes(track)
        VStack(spacing: 0) {
            ForEach(lanes, id: \.self) { address in
                HStack(spacing: 4) {
                    Text(model.project.automationTarget(address)?.name ?? "?")
                        .font(.system(size: 10)).lineLimit(1).foregroundStyle(Theme.dim)
                    Spacer(minLength: 0)
                    Button { model.setLane(track, address, shown: false) } label: {
                        Image(systemName: "xmark").font(.system(size: 8))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.dim).hint("Hide this lane")
                }
                .padding(.horizontal, 8).padding(.top, 4)
                .frame(height: AppModel.automationRow, alignment: .top)
                .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !lanes.isEmpty {
                AutomationLanesMenu(track: track).menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(width: 24).padding(.trailing, 4).padding(.bottom, 2)
                    .hint("Choose lanes")
            }
        }
    }
}
