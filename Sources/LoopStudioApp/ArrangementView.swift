import LoopStudioCore
import SwiftUI

private let laneHeight: CGFloat = 74
private let headerWidth: CGFloat = 176
private let rulerHeight: CGFloat = 28

/// The arrangement: the tracks scroll; the returns and the master are pinned to the bottom, as in Live,
/// and scroll sideways with the tracks.
struct ArrangementView: View {
    @Environment(AppModel.self) private var model
    @State private var marquee: CGRect?
    @State private var tracksScroll = ScrollPosition(x: 0)
    @State private var pinnedScroll = ScrollPosition(x: 0)
    @State private var tracksX: CGFloat = 0
    @State private var pinnedX: CGFloat = 0
    /// A pinch in progress: the zoom at its start, the content x under the fingers, and the scroll then.
    @State private var pinch: (pixelsPerBar: Double, x: CGFloat, scroll: CGFloat)?

    var body: some View {
        let tracks = model.arrangementTracks
        let returns = model.returnTracks
        let bars = totalBars
        let width = CGFloat(Double(bars) * model.pixelsPerBar)
        let pinnedHeight = model.pinnedRowsHeight

        VStack(spacing: 0) {
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
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).hint("Show or hide automation lanes on all tracks (A)")
                        }
                        .padding(.horizontal, 8).frame(height: rulerHeight)
                        ForEach(tracks, id: \.id) { ArrangementHeader(track: $0) }
                        Button { model.addTrack() } label: {
                            Label("Add track", systemImage: "plus").font(.caption).frame(maxWidth: .infinity).frame(height: 36).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.dim)
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
                        // A pinch zooms in time; the bar under the fingers stays under them.
                        .simultaneousGesture(MagnifyGesture()
                            .onChanged { g in
                                if pinch == nil { pinch = (model.pixelsPerBar, g.startLocation.x, tracksX) }
                                guard let p = pinch else { return }
                                let zoom = min(420, max(24, p.pixelsPerBar * g.magnification))
                                model.pixelsPerBar = zoom
                                let x = p.x * zoom / p.pixelsPerBar
                                tracksScroll.scrollTo(x: max(0, x - (p.x - p.scroll)))
                            }
                            .onEnded { _ in pinch = nil })
                    }
                    .scrollPosition($tracksScroll)
                    .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
                        tracksX = x
                        if abs(x - pinnedX) > 0.5 { pinnedScroll.scrollTo(x: x) }
                    }
                }
            }
            // When a track opens its automation lanes the rows get taller. The top edge stays where it is, so the
            // lanes open below the track; without this the scroll view keeps its bottom edge and the track jumps up.
            .defaultScrollAnchor(.top)
            .defaultScrollAnchor(.top, for: .sizeChanges)

            // The pinned rows: returns and master. They hold automation and the session's dummy clips; no
            // clips are dragged into them, so the marquee stays above. The playhead runs through them too.
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(returns, id: \.id) { ArrangementHeader(track: $0) }
                    ArrangementHeader(track: model.project.master)
                }
                .frame(width: headerWidth)
                ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            ForEach(Array(returns.enumerated()), id: \.element.id) { index, track in
                                Lane(track: track, index: tracks.count + index, count: tracks.count, width: width)
                            }
                            Lane(track: model.project.master, index: tracks.count + returns.count, count: tracks.count, width: width)
                        }
                        if let loop = model.project.loop, loop.enabled {
                            Rectangle().fill(Theme.accent.opacity(0.07))
                                .frame(width: max(1, tickX(loop.end, model) - tickX(loop.start, model)), height: pinnedHeight)
                                .offset(x: tickX(loop.start, model)).allowsHitTesting(false)
                        }
                        Playhead(height: pinnedHeight)
                    }
                    .frame(width: width, alignment: .topLeading)
                }
                .scrollPosition($pinnedScroll)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
                    pinnedX = x
                    if abs(x - tracksX) > 0.5 { tracksScroll.scrollTo(x: x) }
                }
            }
            .frame(height: pinnedHeight)
            .background(Theme.panel)
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
                    // A double-click on the name opens the inspector; on the buttons it would toggle them twice.
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture(count: 2).onEnded { model.openTrackInspector(track.id) })
                HStack(spacing: 4) {
                    if track.kind != .master {
                        pill("S", on: track.solo, tint: Theme.track(5)) { model.toggleSolo(track) }.midiLearnable(.solo(track.id))
                            .hint("Solo this track only. ⌘-click adds it to the soloed tracks.")
                    }
                    pill("M", on: track.mute, tint: Theme.accent) { model.apply(.setMute(id: track.id, mute: !track.mute)) }.midiLearnable(.mute(track.id))
                    if track.kind == .audio || track.kind == .midi {
                        pill("●", on: model.armedTracks.contains(track.id), tint: .red) { model.toggleArm(track.id) }.midiLearnable(.arm(track.id))
                            .hint("Arm this track only: it records and plays the MIDI keyboard. ⌘-click adds it to the armed tracks.")
                    }
                }
            }
            Spacer()
        }
        .padding(6).frame(height: laneHeight, alignment: .top)
        .overlay(alignment: .bottomTrailing) { automationDisclosure.padding(.trailing, 4).padding(.bottom, 3) }
        .frame(height: model.rowHeight(track), alignment: .top)
        .background(model.selectedTrack == track.id ? Theme.panelRaised : Theme.panel)
        .overlay(alignment: .bottom) { AutomationLabels(track: track) }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        // The single click acts at once; a double-click also opens the inspector. A double-click handler that
        // runs first would hold every single click back until the double-click time has passed.
        .onTapGesture { model.focusTrack(track.id) }
        .contextMenu {
            if track.kind == .master { AutomationLanesMenu(track: track) } else { TrackMenuItems(track: track, showsAutomation: true) }
        }
        // The header drags the track: dropped on another header it moves in front of that track.
        .draggable(track.kind == .master ? "" : AppModel.trackDrag(track.id))
        .dropDestination(for: String.self) { items, _ in
            if track.kind == .master { return model.dropOnNewTrack(items.map(DropItem.device)) }
            return model.dropOnTrackHeader(items, track: track.id)
        }
    }

    /// The small expander at the bottom right of the track label: a chevron that points down while the lanes
    /// are closed and up while they are open. A red dot next to it says the track holds automation points.
    private var automationDisclosure: some View {
        let open = !model.shownLanes(track).isEmpty
        return Button { model.toggleAutomation(track) } label: {
            HStack(spacing: 3) {
                if model.hasAutomation(track) {
                    Circle().fill(Theme.automationDot).frame(width: 5, height: 5)
                }
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(open ? Theme.text : Theme.dim)
            }
            .padding(.horizontal, 4).frame(height: 14)
            .background(Theme.panelRaised.opacity(open ? 1 : 0.6), in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hint(model.laneList(track).isEmpty ? "Open the automation lanes of this track. The A key opens every track's."
              : open ? "Fold the automation lanes away; they are kept." : "Open the automation lanes again.")
    }

    private func pill(_ label: String, on: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 10, weight: .bold)).frame(minWidth: 24, maxWidth: 32).frame(height: 18)
                .foregroundStyle(on ? tint : Theme.dim)
                .background(on ? tint.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(on ? tint.opacity(0.55) : Theme.line, lineWidth: 1))
                .contentShape(Rectangle())
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

/// Where a dragged file would land on a lane: the snapped start, the file's length and its name.
struct DropMark: Equatable {
    var tick: Tick
    var length: Tick
    var name: String
}

/// The lane's drop: a file makes a clip at the pointer, a device lands on the track. While the drag hovers,
/// the lane shows the mark; the drop itself loads the items and hands them to the model.
@MainActor private struct LaneDrop: DropDelegate {
    let model: AppModel
    let track: TrackID
    let mark: Binding<DropMark?>

    private func update(_ info: DropInfo) {
        if DragPasteboard.carriesDevices { mark.wrappedValue = nil; return }
        let tick = model.snap(xTick(info.location.x, model))
        guard let file = DragPasteboard.files.first else { mark.wrappedValue = DropMark(tick: tick, length: Tick(model.barTicks), name: ""); return }
        let seconds = DragPasteboard.audioSeconds(file) ?? 2
        let map = model.project.tempoMap
        let length = Tick(max(1, (map.tick(atSeconds: map.seconds(at: tick) + seconds) - tick).rawValue))
        let next = DropMark(tick: tick, length: length, name: file.deletingPathExtension().lastPathComponent)
        if mark.wrappedValue != next { mark.wrappedValue = next }
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL, .text]) }
    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? { update(info); return DropProposal(operation: .copy) }
    func dropExited(info: DropInfo) { mark.wrappedValue = nil }

    func performDrop(info: DropInfo) -> Bool {
        mark.wrappedValue = nil
        let tick = xTick(info.location.x, model)
        nonisolated(unsafe) let providers = info.itemProviders(for: [.fileURL, .text])
        guard !providers.isEmpty else { return false }
        let model = model, track = track
        Task { @MainActor in
            let items = await loadDropItems(providers)
            model.dropOnTimeline(items, track: track, at: tick)
        }
        return true
    }
}

private struct Lane: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let index: Int
    let count: Int
    let width: CGFloat
    /// A file hovers over the lane: where it would land.
    @State private var dropMark: DropMark?

    /// The placeholder under a dragged file: a dashed clip of the file's length at the snapped start, a line
    /// down the lane, and the name with the position.
    private func dropPlaceholder(_ m: DropMark) -> some View {
        let x = tickX(m.tick, model)
        let w = max(24, tickX(m.tick + m.length, model) - x)
        let bar = m.tick.rawValue / model.barTicks + 1, beat = (m.tick.rawValue % model.barTicks) / Int64(Tick.perQuarter) + 1
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.accent.opacity(0.18))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                .frame(width: w, height: laneHeight - 4).offset(x: x, y: 2)
            Rectangle().fill(Theme.accent).frame(width: 1.5, height: model.rowHeight(track)).offset(x: x)
            Text((m.name.isEmpty ? "" : m.name + "  ") + "\(bar).\(beat)")
                .font(.system(size: 10, weight: .semibold)).lineLimit(1).foregroundStyle(Theme.text)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Theme.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 3))
                .offset(x: x + 4, y: 5)
        }
        .allowsHitTesting(false)
    }

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
                                     width: width, height: AppModel.automationRow, tint: Theme.track(track.colorIndex), pen: model.drawMode, penGrid: Tick.perQuarter) { pts in
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
        // A click on empty space picks the track and puts the playhead there, snapped: play goes on from
        // there, or starts there later while stopped.
        .gesture(SpatialTapGesture().onEnded { v in
            model.selectedTrack = track.id
            model.clearSelection()
            if v.location.y < laneHeight { model.seek(to: model.snap(xTick(v.location.x, model))) }
        })
        .contextMenu { LaneMenu(track: track) }
        .gesture(SpatialTapGesture(count: 2).onEnded { v in
            if track.kind == .midi { model.createMIDIClip(track: track.id, at: xTick(v.location.x, model)) }
        })
        .onDrop(of: [.fileURL, .text], delegate: LaneDrop(model: model, track: track.id, mark: $dropMark))
        .overlay(alignment: .topLeading) { if let m = dropMark { dropPlaceholder(m) } }
    }
}

private struct ArrangementClip: View {
    @Environment(AppModel.self) private var model
    let clip: Clip
    let track: Track
    let trackIndex: Int
    let trackCount: Int
    @State private var drag: CGSize = .zero
    /// While the left edge is dragged: the new start, snapped and kept within the file. The content stays in place.
    @State private var trimStart: Tick?
    /// While the right edge is dragged: the new end, snapped.
    @State private var resizeEnd: Tick?

    /// The earliest start of the left edge: the first sample of an audio file, else the timeline start.
    /// A looping audio clip goes round its file, so it can start anywhere.
    private var earliestStart: Tick {
        if case .audio(let a) = clip, !a.loop || model.sourceTicks(of: a) == nil { return max(0, clip.start - a.offset) }
        return 0
    }

    /// The left edge position for a drag of `dx` points: snapped, and stopped at the file start and one grid step before the end.
    private func trimTarget(_ dx: CGFloat) -> Tick {
        let end = clip.start + clip.length
        let wanted = model.snap(xTick(tickX(clip.start, model) + dx, model))
        let latest = end - Tick(max(1, min(clip.length.rawValue - 1, Int64(Tick.perQuarter / 4))))
        return min(max(wanted, earliestStart), latest)
    }

    /// The clip being dragged follows its own gesture; the rest of a marked group follows it.
    private var shown: CGSize { drag != .zero ? drag : (model.selectedClips.contains(clip.id) ? model.groupDrag : .zero) }

    var body: some View {
        let tint = Theme.track(clip.colorIndex ?? track.colorIndex)
        let x = tickX(clip.start, model)
        // While an edge is dragged, the clip shows its new range: the start, the length and the file offset move together.
        let shownStart = trimStart ?? clip.start
        let shownEnd = resizeEnd ?? (clip.start + clip.length)
        let shownLength = max(Tick(1), shownEnd - shownStart)
        let trim = tickX(shownStart, model) - x
        let w = max(6, tickX(shownLength, model))
        let selected = model.selectedClips.contains(clip.id) || model.selectedClip == clip.id
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.clipBody(clip.colorIndex ?? track.colorIndex))
            if case .audio(let a) = clip, let peaks = model.waveforms[a.asset], let asset = model.project.asset(a.asset) {
                let assetTicks = Double(asset.frames) / max(1, asset.sampleRate) * model.bpm / 60 * Double(Tick.perQuarter)
                // A looping clip dragged out past the file start shows the end of the file there.
                let period = a.loop ? (model.sourceTicks(of: a)?.rawValue ?? 0) : 0
                let raw = a.offset.rawValue + (shownStart - clip.start).rawValue
                let offset = period > 0 ? (raw % period + period) % period : raw
                WaveformView(peaks: peaks, color: tint.opacity(0.9), fraction: Double(shownLength.rawValue) / max(1, assetTicks), loop: a.loop,
                             start: Double(max(0, offset)) / max(1, assetTicks))
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
        // A clip narrower than its two grips has no body to grab: the grips go, the clip can still be moved.
        .overlay(alignment: .leading) {
            if w >= 24 { Rectangle().fill(.clear).frame(width: 8).contentShape(Rectangle())
                // Measured in the window, not in the edge itself: the edge moves with the drag, which made it flicker.
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { trimStart = trimTarget($0.translation.width) }
                    .onEnded { g in
                        // A clip only shows part of its file. Dragged out past the file start, it stops there.
                        let start = trimTarget(g.translation.width)
                        trimStart = nil
                        guard start != clip.start else { return }
                        let period: Tick? = { if case .audio(let a) = clip { return model.sourceTicks(of: a) }; return nil }()
                        if let trimmed = clip.trimmingStart(to: start, period: period) { model.apply(.setClip(clip: trimmed)) }
                        else { model.status = "The clip cannot start there" }
                    })
                .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .hint("Drag to trim the start. The sound stays in place.")
            }
        }
        .overlay(alignment: .trailing) {
            if w >= 24 { Rectangle().fill(.clear).frame(width: 8).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { g in
                        let end = model.snap(xTick(tickX(clip.start + clip.length, model) + g.translation.width, model))
                        resizeEnd = max(end, clip.start + Tick(1))
                    }
                    .onEnded { g in
                        let end = model.snap(xTick(tickX(clip.start + clip.length, model) + g.translation.width, model))
                        resizeEnd = nil
                        if end > clip.start { model.apply(.setClipRange(clip: clip.id, start: clip.start, length: end - clip.start)) }
                    })
                .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            }
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

/// The loop brace in the ruler, like Live's: drag its ends to resize the loop, drag its middle to move it,
/// click it to turn the loop on or off. It stays visible, dimmed, while the loop is off.
private struct LoopBrace: View {
    @Environment(AppModel.self) private var model
    let width: CGFloat
    @State private var dragStart: CGFloat = 0
    @State private var dragEnd: CGFloat = 0

    var body: some View {
        if let loop = model.project.loop {
            let on = loop.enabled
            let tint = on ? Theme.accent : Theme.dim
            let x0 = tickX(loop.start, model) + dragStart
            let x1 = tickX(loop.end, model) + dragEnd
            let length = loop.end.rawValue - loop.start.rawValue
            ZStack(alignment: .topLeading) {
                if on {
                    Rectangle().fill(Theme.accent.opacity(0.07)).frame(width: max(1, x1 - x0)).offset(x: x0).allowsHitTesting(false)
                }
                // The brace itself. Its hit zone is the lower part of the ruler; the part above still scrubs.
                Rectangle().fill(tint.opacity(on ? 1 : 0.5)).frame(width: max(1, x1 - x0), height: 5)
                    .frame(width: max(1, x1 - x0), height: 10, alignment: .bottom)
                    .contentShape(Rectangle())
                    .offset(x: x0, y: rulerHeight - 10)
                    .gesture(DragGesture().onChanged { dragStart = $0.translation.width; dragEnd = $0.translation.width }.onEnded { g in
                        dragStart = 0; dragEnd = 0
                        let start = model.snap(xTick(tickX(loop.start, model) + g.translation.width, model))
                        model.setLoop(start: start, end: Tick(start.rawValue + length))
                    })
                    .onTapGesture { model.toggleLoop() }
                    .hint(on ? "Loop brace: drag to move the loop, drag an end to resize it, click to turn the loop off (⇧⌘L)."
                          : "Loop is off. Click the brace to turn it on (⇧⌘L); drag it or its ends to set the range first.")
                handle(x: x0, tint: tint).gesture(DragGesture().onChanged { dragStart = $0.translation.width }.onEnded { g in
                    dragStart = 0
                    model.setLoop(start: model.snap(xTick(tickX(loop.start, model) + g.translation.width, model)), end: loop.end)
                })
                .hint("Loop start")
                handle(x: x1 - 6, tint: tint).gesture(DragGesture().onChanged { dragEnd = $0.translation.width }.onEnded { g in
                    dragEnd = 0
                    model.setLoop(start: loop.start, end: model.snap(xTick(tickX(loop.end, model) + g.translation.width, model)))
                })
                .hint("Loop end")
            }
        }
    }

    private func handle(x: CGFloat, tint: Color) -> some View {
        Rectangle().fill(tint).frame(width: 6, height: 14).offset(x: x, y: rulerHeight - 14).contentShape(Rectangle())
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

/// Header column of the automation lanes. Each lane has a dropdown that picks its parameter, a dot when that
/// parameter holds points, and a close button. The last lane has a button that adds one more lane.
private struct AutomationLabels: View {
    @Environment(AppModel.self) private var model
    let track: Track

    var body: some View {
        let lanes = model.shownLanes(track)
        let automated = model.automatedTargets(track)
        VStack(spacing: 0) {
            ForEach(Array(lanes.enumerated()), id: \.element) { i, address in
                let target = model.project.automationTarget(address)
                let hasPoints = automated.contains(address)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        // The same look as the other dropdowns of the app (`PillMenu`): a bordered field with
                        // the up-down chevron, so it reads as a chooser and not as a fold button.
                        LaneParameterMenu(track: track, index: i) {
                            HStack(spacing: 5) {
                                Circle().fill(hasPoints ? Theme.automationDot : Theme.dim.opacity(0.35)).frame(width: 6, height: 6)
                                Text(target.map(LaneGroup.shortName) ?? "?")
                                    .font(.system(size: 10, weight: hasPoints ? .semibold : .regular))
                                    .foregroundStyle(hasPoints ? Theme.text : Theme.dim).lineLimit(1)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(Theme.dim)
                            }
                            .padding(.horizontal, 6).frame(minWidth: 84, maxWidth: 130).frame(height: 18)
                            .background(Theme.panelRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.radius + 2))
                            .overlay(RoundedRectangle(cornerRadius: Theme.radius + 2).strokeBorder(Theme.line, lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .fixedSize()
                        .hint(hasPoints ? "\(target?.name ?? "This lane") holds automation. Click to show another parameter in this lane."
                              : "\(target?.name ?? "This lane") has no automation yet: the dotted line is the default value. Click to show another parameter.")
                        Spacer(minLength: 0)
                        Button { model.setLane(track, address, shown: false) } label: {
                            Image(systemName: "xmark").font(.system(size: 8)).frame(width: 16, height: 16).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.dim).hint("Close this lane")
                    }
                    if let device = target.flatMap(deviceName) {
                        Text(device).font(.system(size: 9)).foregroundStyle(Theme.dim.opacity(0.8)).lineLimit(1).padding(.leading, 5).padding(.top, 2)
                    }
                }
                .padding(.horizontal, 8).padding(.top, 4)
                .frame(height: AppModel.automationRow, alignment: .top)
                .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                // The last lane has the same small button as the track label, with a plus: one more lane below.
                .overlay(alignment: .bottomTrailing) {
                    if i == lanes.count - 1 {
                        Button { model.addLane(track) } label: {
                            Image(systemName: "plus").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.dim)
                                .padding(.horizontal, 4).frame(height: 14)
                                .background(Theme.panelRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.radius))
                                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line, lineWidth: 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).hint("One more lane under this track, for another parameter")
                        .padding(.trailing, 4).padding(.bottom, 3)
                    }
                }
            }
        }
    }

    /// The device part of a target name: "Reverb" from "Drums › Reverb › Size". The track name in front is
    /// not shown, the lane sits under its track; a mixer parameter ("Drums › Volume") has no device.
    private func deviceName(_ target: AutomationTarget) -> String? {
        let parts = target.name.components(separatedBy: " › ").dropFirst().dropLast()
        return parts.isEmpty ? nil : parts.joined(separator: " › ")
    }
}
