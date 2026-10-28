import LoopStudioCore
import SwiftUI

private let laneHeight: CGFloat = 74
private let headerWidth: CGFloat = 176
private let rulerHeight: CGFloat = 28

struct ArrangementView: View {
    @Environment(AppModel.self) private var model
    @State private var marquee: CGRect?

    var body: some View {
        let tracks = model.project.tracks
        let bars = totalBars
        let width = CGFloat(Double(bars) * model.pixelsPerBar)

        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(Theme.dim)
                        Slider(value: Bindable(model).pixelsPerBar, in: 24...420).controlSize(.mini)
                    }
                    .padding(.horizontal, 8).frame(height: rulerHeight)
                    ForEach(tracks, id: \.id) { ArrangementHeader(track: $0) }
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
                    pill("S", on: track.solo, tint: Color(red: 0.4, green: 0.65, blue: 1)) { model.apply(.setSolo(id: track.id, solo: !track.solo)) }
                    pill("M", on: track.mute, tint: Theme.accent) { model.apply(.setMute(id: track.id, mute: !track.mute)) }
                    pill("A", on: model.automationShown.contains(track.id), tint: Color(red: 0.95, green: 0.35, blue: 0.35)) { model.toggleAutomation(track) }
                        .help("Show automation")
                }
            }
            Spacer()
        }
        .padding(6).frame(height: laneHeight, alignment: .top)
        .frame(height: model.rowHeight(track), alignment: .top)
        .background(model.selectedTrack == track.id ? Theme.panelRaised : Theme.panel)
        .overlay(alignment: .bottom) { if model.automationShown.contains(track.id) { AutomationPicker(track: track).frame(height: AppModel.automationRow).padding(.horizontal, 6) } }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .onTapGesture { model.selectedTrack = track.id }
        .contextMenu { TrackMenuItems(track: track, showsAutomation: true) }
        .dropDestination(for: String.self) { items, _ in
            return model.dropDevices(items, on: track.id)
        }
    }

    private func pill(_ label: String, on: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 10, weight: .bold)).frame(width: 24, height: 18)
                .foregroundStyle(on ? .black : Theme.dim)
                .background(on ? tint : Theme.panelRaised, in: RoundedRectangle(cornerRadius: 3))
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
            if model.automationShown.contains(track.id), let address = model.automationChoice[track.id],
               let target = model.project.automationTarget(address) {
                AutomationEditor(target: target, points: model.automationPoints(track, address),
                                 pixelsPerTick: model.pixelsPerBar / Double(model.barTicks),
                                 width: width, height: AppModel.automationRow, tint: Theme.track(track.colorIndex)) { pts in
                    model.apply(.setAutomation(track: track.id, target: address, points: pts))
                }
                .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                .offset(y: laneHeight)
            }
        }
        .frame(width: width, height: model.rowHeight(track), alignment: .topLeading)
        .background(index % 2 == 0 ? Theme.background : Color(white: 0.145))
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

    /// The clip being dragged follows its own gesture; the rest of a marked group follows it.
    private var shown: CGSize { drag != .zero ? drag : (model.selectedClips.contains(clip.id) ? model.groupDrag : .zero) }

    var body: some View {
        let tint = Theme.track(clip.colorIndex ?? track.colorIndex)
        let x = tickX(clip.start, model)
        let w = max(6, tickX(clip.length, model) + resize)
        let selected = model.selectedClips.contains(clip.id) || model.selectedClip == clip.id
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.75))
            if case .audio(let a) = clip, let peaks = model.waveforms[a.asset], let asset = model.project.asset(a.asset) {
                let assetTicks = Double(asset.frames) / max(1, asset.sampleRate) * model.bpm / 60 * Double(Tick.perQuarter)
                WaveformView(peaks: peaks, color: .black.opacity(0.55), fraction: Double(clip.length.rawValue) / max(1, assetTicks), loop: a.loop)
                    .padding(.top, 16).padding(.bottom, 3)
            }
            if case .midi(let m) = clip { MiniNotes(clip: m).padding(.top, 16).padding(.bottom, 3).padding(.horizontal, 2) }
            Text(model.clipName(clip)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.black.opacity(0.85))
                .padding(.horizontal, 5).padding(.top, 2).lineLimit(1)
        }
        .frame(width: w, height: laneHeight - 6)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? .white : .black.opacity(0.4), lineWidth: selected ? 1.5 : 1))
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
        .offset(x: x + shown.width, y: 3 + shown.height)
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
                ctx.fill(Path(CGRect(x: x, y: y, width: w, height: max(1.5, rowH - 0.5))), with: .color(.black.opacity(0.6)))
            }
        }
    }
}

/// Chooses which parameter the automation row of a track shows.
private struct AutomationPicker: View {
    @Environment(AppModel.self) private var model
    let track: Track

    var body: some View {
        let targets = model.project.automationTargets(of: track)
        VStack(alignment: .leading, spacing: 4) {
            Picker("", selection: Binding(
                get: { model.automationChoice[track.id] ?? targets.first?.address },
                set: { model.automationChoice[track.id] = $0 })) {
                ForEach(targets, id: \.address) { Text($0.name).tag(Optional($0.address)) }
            }
            .labelsHidden().controlSize(.mini)
            Spacer()
        }
        .padding(.top, 6)
    }
}
