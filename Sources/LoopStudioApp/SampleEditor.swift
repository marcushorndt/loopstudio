import LoopStudioCore
import SwiftUI

/// The sample page of an audio clip, like Live's: a loop bar above the waveform, a start marker, and zoom.
///
/// The loop bar shows the loop as a brace; without Loop it is greyed and can still be set. Drag in the
/// bar to mark a new loop; drag a brace edge to resize it, its middle to move it. The start marker below is
/// where playback begins. With Loop on it moves on its own: before the loop it plays an intro, then the
/// loop repeats; the brace moves past it without taking it along. Everything snaps to the grid, which gets finer as you zoom in; Option
/// drags free. Zoom with a pinch, ⌘ and the scroll wheel, or the buttons.
struct SampleEditor: View {
    @Environment(AppModel.self) private var model
    let clip: AudioClip
    let asset: Asset
    let peaks: WavePeaks
    let tint: Color

    @State private var zoom: Double = 1
    /// A pinch in progress: the zoom at its start, the x under the fingers and the scroll then.
    @State private var pinchStart: (zoom: Double, x: CGFloat, scroll: CGFloat)?
    @State private var scroll = ScrollPosition(x: 0)
    @State private var scrollX: CGFloat = 0
    @State private var wheel = WheelZoom()
    /// A loop being marked or changed, before it is committed.
    @State private var draft: (offset: Tick, length: Tick)?
    /// The start marker while it is dragged on a looping clip.
    @State private var startDraft: Tick?
    /// A stretch is being marked: the click that ends the drag must not clear it.
    @State private var markingNow = false
    @State private var dragMode: LoopDrag?
    /// The width of the visible part: the waveform draws only there, so a deep zoom stays cheap.
    @State private var viewportWidth: CGFloat = 800

    private enum LoopDrag { case mark(anchor: Tick), moveLoop(grab: Tick), left, right, start }
    private static let barHeight: CGFloat = 18
    private static let grab: CGFloat = 6

    private var warped: Bool { clip.warpMode != .off }

    /// Beats on the ruler for the whole file, through the warp markers or at the song tempo.
    private var geometry: WarpGeometry {
        WarpGeometry(markers: clip.warpMarkers, sourceTempo: warped ? (asset.sourceTempo ?? model.bpm) : model.bpm, assetRate: asset.sampleRate)
    }
    private var fileBeats: Double { geometry.beat(atSource: Double(asset.frames)) }
    private var totalBeats: Double { max(4, fileBeats, (clip.offset + clip.length).quarters, (brace.offset + brace.length).quarters) }

    private var session: Bool { model.isSessionClip(clip.id) }
    private var fileTicks: Tick { Tick(Int64((fileBeats * Double(Tick.perQuarter)).rounded())) }

    /// The brace: the loop. Without Loop it stays, greyed, and can still be set, like in Live.
    private var brace: (offset: Tick, length: Tick) {
        let r = clip.loopRegion(session: session)
        return (r.start, r.length ?? Tick(max(1, fileTicks.rawValue - r.start.rawValue)))
    }

    /// The brace as drawn: the draft while a drag runs.
    private var shownOffset: Tick { draft?.offset ?? brace.offset }
    private var shownLength: Tick { draft?.length ?? brace.length }
    /// The start marker as drawn.
    private var shownStart: Tick { startDraft ?? clip.offset }

    var body: some View {
        GeometryReader { geo in
            let viewport = geo.size.width
            let ppb = viewport * zoom / totalBeats
            let _ = updateViewport(viewport)
            let step = gridStep(ppb: ppb)
            ZStack(alignment: .topTrailing) {
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        loopBar(ppb: ppb, step: step, height: Self.barHeight)
                            .frame(width: viewport * zoom, height: Self.barHeight)
                        waveformArea(ppb: ppb, step: step)
                            .frame(width: viewport * zoom)
                    }
                    .frame(height: geo.size.height)
                }
                .scrollIndicators(.automatic)
                .scrollPosition($scroll)
                .onScrollGeometryChange(for: CGFloat.self, of: \.contentOffset.x) { _, x in scrollX = max(0, x) }
                zoomButtons
            }
            // A pinch zooms around the fingers: the beat under them stays under them.
            .gesture(MagnifyGesture()
                .onChanged { v in
                    if pinchStart == nil { pinchStart = (zoom, v.startLocation.x, scrollX) }
                    guard let start = pinchStart else { return }
                    setZoom(start.zoom * v.magnification)
                    let content = (start.scroll + start.x) * CGFloat(zoom / start.zoom)
                    scroll.scrollTo(x: max(0, content - start.x))
                }
                .onEnded { _ in pinchStart = nil })
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line, lineWidth: 1))
        .background(Theme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.radius))
        .onHover { wheel.inside = $0 }
        .onAppear {
            zoom = 1
            wheel.install { dy, _ in setZoom(zoom * pow(1.01, Double(dy))) }
        }
        .onDisappear { wheel.remove() }
    }

    // MARK: Grid and zoom

    /// The finest note value that still gets about 22 points per step at this zoom.
    private func gridStep(ppb: CGFloat) -> Int64 {
        let q = Int64(Tick.perQuarter)
        for step in [q / 16, q / 8, q / 4, q / 2, q, q * 2, q * 4] where CGFloat(step) / CGFloat(q) * ppb >= 22 { return step }
        return q * 4
    }

    /// The deepest zoom: 12 points per sample, but at most 2 million points of content. The drawing loses
    /// precision beyond that, so a long file stops short of single samples.
    private var maxZoom: Double {
        let w = Double(max(1, viewportWidth))
        return max(1, min(2_000_000 / w, Double(asset.frames) * 12 / w))
    }

    private func setZoom(_ z: Double) { zoom = min(maxZoom, max(1, z)) }

    private func updateViewport(_ w: CGFloat) {
        guard abs(w - viewportWidth) > 0.5 else { return }
        DispatchQueue.main.async { viewportWidth = w }
    }

    /// The part of the content in view, with a margin, in content points.
    private var visible: ClosedRange<CGFloat> { max(0, scrollX - 40)...(scrollX + viewportWidth + 40) }

    private var zoomButtons: some View {
        HStack(spacing: 2) {
            Button { setZoom(zoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }.hint("Zoom out")
            Button { setZoom(zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }.hint("Zoom in. The grid gets finer as you zoom.")
            Button { setZoom(1) } label: { Image(systemName: "arrow.left.and.right.square") }.hint("Show the whole file")
            Button { if let s = model.sampleSelection, s.clip == clip.id { model.loopClip(to: s) } } label: {
                Image(systemName: "repeat")
            }
            .disabled(selection == nil)
            .hint("Loop the marked stretch (⌘L). Drag over the waveform to mark one.")
            Button { model.sampleGrid.toggle() } label: {
                Image(systemName: "grid").foregroundStyle(model.sampleGrid ? Theme.accent : Theme.dim)
            }
            .hint(model.sampleGrid ? "Grid on: the loop, the start and the warp markers snap to it. ⌘ or Option drags free."
                  : "Grid off: everything moves freely. ⌘ or Option snaps to the grid.")
        }
        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.dim)
        .padding(4).background(Theme.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
        .padding(.top, Self.barHeight + 4).padding(.trailing, 14)
    }

    static func stepName(_ step: Int64) -> String {
        let q = Int64(Tick.perQuarter)
        switch step {
        case q / 16: return "1/64"
        case q / 8: return "1/32"
        case q / 4: return "1/16"
        case q / 2: return "1/8"
        case q: return "1/4"
        case q * 2: return "1/2"
        default: return "1 bar"
        }
    }

    private func snapped(_ beat: Double, step: Int64, free: Bool) -> Tick {
        var raw = Int64((beat * Double(Tick.perQuarter)).rounded())
        if !free { raw = (raw + step / 2) / step * step }
        return Tick(max(0, raw))
    }

    // MARK: Loop bar

    private func loopBar(ppb: CGFloat, step: Int64, height: CGFloat) -> some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.panel))
            // Bar numbers.
            let bar = Double(model.barTicks) / Double(Tick.perQuarter)
            var b = 0.0, n = 1
            while b <= totalBeats {
                let x = CGFloat(b) * ppb
                ctx.fill(Path(CGRect(x: x, y: size.height - 5, width: 1, height: 5)), with: .color(Theme.dim))
                if ppb * CGFloat(bar) >= 24 {
                    ctx.draw(Text("\(n)").font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.dim), at: CGPoint(x: x + 3, y: 6), anchor: .leading)
                }
                b += bar; n += 1
            }
            // The brace: the part of the file the clip plays.
            let x0 = CGFloat(shownOffset.quarters) * ppb, x1 = CGFloat((shownOffset + shownLength).quarters) * ppb
            let brace = CGRect(x: x0, y: 2, width: max(2, x1 - x0), height: size.height - 4)
            let edge = clip.loop ? tint : Theme.dim
            ctx.fill(Path(roundedRect: brace, cornerRadius: 2), with: .color(edge.opacity(draft == nil ? (clip.loop ? 0.45 : 0.25) : 0.7)))
            ctx.stroke(Path(roundedRect: brace, cornerRadius: 2), with: .color(edge), lineWidth: 1)
            for x in [x0, x1] { ctx.fill(Path(CGRect(x: x - 1.5, y: 2, width: 3, height: size.height - 4)), with: .color(edge)) }
            ctx.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(Theme.line))
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { v in
                let free = model.freeOfGrid()
                let here = Double(v.location.x / ppb)
                if dragMode == nil {
                    let b = brace
                    let x0 = CGFloat(b.offset.quarters) * ppb, x1 = CGFloat((b.offset + b.length).quarters) * ppb
                    let x = v.startLocation.x
                    if abs(x - x0) <= Self.grab { dragMode = .left }
                    else if abs(x - x1) <= Self.grab { dragMode = .right }
                    else if x > x0 && x < x1 { dragMode = .moveLoop(grab: Tick(Int64(Double(x / ppb) * Double(Tick.perQuarter))) - b.offset) }
                    else { dragMode = .mark(anchor: snapped(Double(x / ppb), step: step, free: free)) }
                }
                update(dragMode, beat: here, step: step, free: free)
            }
            .onEnded { _ in commitDraft() })
        .hint("Loop bar. Drag to mark the loop, drag an edge to resize it, drag the middle to move it. The start marker stays where it is. ⌘ or Option drags free of the grid; with the grid off they snap to it.")
    }

    // MARK: Waveform and start marker

    @ViewBuilder
    private func waveformArea(ppb: CGFloat, step: Int64) -> some View {
        ZStack(alignment: .topLeading) {
            if warped {
                WarpEditor(clip: clip, asset: asset, peaks: peaks, tint: tint, ppb: ppb, visible: visible,
                           onMark: { a, b in mark(from: a, to: b, ppb: ppb, step: step) }, onMarkEnd: endMark)
            } else {
                waveform(ppb: ppb, step: step)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 3)
                        .onChanged { v in mark(from: v.startLocation.x, to: v.location.x, ppb: ppb, step: step) }
                        .onEnded { _ in endMark() })
                ClipPlayhead(clip: clip.id, period: WarpEditor.noPeriod) {
                    CGFloat(clip.playTick(after: $0, session: session, fileTicks: fileTicks).quarters) * ppb
                }
            }
            selectionOverlay(ppb: ppb)
            startMarker(ppb: ppb, step: step)
        }
        .simultaneousGesture(TapGesture().onEnded { if !markingNow { model.sampleSelection = nil } })
    }

    private func waveform(ppb: CGFloat, step: Int64) -> some View {
        Canvas { ctx, size in
            // The grid at the current step; bars stronger.
            let bar = model.barTicks
            let shown = visible
            var t: Int64 = max(0, Int64(Double(shown.lowerBound / ppb) * Double(Tick.perQuarter)) / step * step)
            while Double(t) / Double(Tick.perQuarter) <= totalBeats {
                let x = CGFloat(Double(t) / Double(Tick.perQuarter)) * ppb
                if x > shown.upperBound { break }
                let strong = t % bar == 0
                ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(Theme.text.opacity(strong ? 0.14 : (t % Int64(Tick.perQuarter) == 0 ? 0.08 : 0.04))))
                t += step
            }
            // Dimmed: what does not play. With Loop, outside the loop and the intro; without, before the start
            // and after the clip's end.
            let a = clip.loop ? min(shownOffset, shownStart) : shownStart
            let b = clip.loop ? shownOffset + shownLength : shownStart + clip.length
            let x0 = CGFloat(a.quarters) * ppb, x1 = CGFloat(b.quarters) * ppb
            ctx.fill(Path(CGRect(x: 0, y: 0, width: x0, height: size.height)), with: .color(Theme.background.opacity(0.55)))
            ctx.fill(Path(CGRect(x: x1, y: 0, width: max(0, size.width - x1), height: size.height)), with: .color(Theme.background.opacity(0.55)))
            guard asset.frames > 0 else { return }
            let g = geometry, frames = Double(asset.frames)
            peaks.draw(in: ctx, from: max(0, shown.lowerBound), to: min(size.width, shown.upperBound), mid: size.height / 2,
                       half: size.height * 0.45, color: tint.opacity(0.9), gainDb: clip.gainDb) { g.source(atBeat: Double($0 / ppb)) / frames }
        }
    }

    /// The marked stretch: a drag over the waveform away from the markers. ⌘L, or the loop button, loops the
    /// clip there. A click clears it.
    private var selection: (start: Tick, end: Tick)? {
        guard let s = model.sampleSelection, s.clip == clip.id else { return nil }
        return (s.start, s.end)
    }

    private func mark(from a: CGFloat, to b: CGFloat, ppb: CGFloat, step: Int64) {
        markingNow = true
        let free = model.freeOfGrid()
        let lo = snapped(Double(min(a, b) / ppb), step: step, free: free), hi = snapped(Double(max(a, b) / ppb), step: step, free: free)
        model.sampleSelection = (clip.id, lo, max(hi, lo + Tick(1)))
        model.status = "Marked \(MusicalLength.format(hi - lo, ticksPerBar: model.barTicks)) · ⌘L loops it · " + (free ? "free of the grid" : "on the grid (\(Self.stepName(step)))")
    }

    private func endMark() { DispatchQueue.main.async { markingNow = false } }

    private func selectionOverlay(ppb: CGFloat) -> some View {
        Canvas { ctx, size in
            guard let s = selection else { return }
            let x0 = CGFloat(s.start.quarters) * ppb, x1 = CGFloat(s.end.quarters) * ppb
            let r = CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: size.height)
            ctx.fill(Path(r), with: .color(Theme.text.opacity(0.12)))
            ctx.stroke(Path(r), with: .color(Theme.text.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }
        .allowsHitTesting(false)
    }

    /// The flag at the clip's start in the file. Drag it to move the start; the length stays.
    private func startMarker(ppb: CGFloat, step: Int64) -> some View {
        GeometryReader { geo in
            let x = CGFloat(shownStart.quarters) * ppb
            let active = dragMode != nil && { if case .start? = dragMode { true } else { false } }()
            ZStack(alignment: .topLeading) {
                Rectangle().fill(active ? Theme.text : tint).frame(width: 1.5, height: geo.size.height).offset(x: x - 0.75)
                Image(systemName: "play.fill").font(.system(size: 9))
                    .foregroundStyle(Theme.onTint)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(active ? Theme.text : tint, in: RoundedRectangle(cornerRadius: 2))
                    // The click area first, then the offset: a shape set after the offset stays at the old
                    // place, so after one drag the flag could no longer be grabbed.
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { resetStart() }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { v in
                            dragMode = .start
                            // From where the start was when the drag began: the flag moves with the drag, so its
                            // own position here would add the movement again and run ahead of the pointer.
                            update(.start, beat: clip.offset.quarters + Double(v.translation.width / ppb), step: step, free: model.freeOfGrid())
                        }
                        .onEnded { _ in commitDraft() })
                    .offset(x: x, y: 2)
                    .hint("Start marker: where playback begins. With Loop on it moves on its own, before the loop (an intro) or inside it, but not past the loop end. ⌘ or Option drags free of the grid; with the grid off they snap to it. Double-click resets it to the loop start, or without Loop to the file start.")
            }
        }
    }

    // MARK: Edits

    /// The start marker back to the loop start, or without Loop to the file start.
    private func resetStart() {
        var c = clip
        c.offset = clip.loop ? brace.offset : 0
        guard c != clip else { return }
        model.apply(.setClip(clip: .audio(c)))
    }

    private func update(_ mode: LoopDrag?, beat: Double, step: Int64, free: Bool) {
        guard let mode else { return }
        // Says what the drag does, so a held key that the app does not see shows at once.
        model.status = (free ? "Free of the grid" : "On the grid (\(Self.stepName(step)))") + " · grid \(model.sampleGrid ? "on" : "off") · keys seen: \(model.heldKeyNames())"
        let end = Tick(Int64((max(totalBeats, fileBeats) * Double(Tick.perQuarter)).rounded()))
        let at = snapped(beat, step: step, free: free)
        let minLength = Tick(free ? Int64(Tick.perQuarter) / 16 : step)
        let b = brace
        switch mode {
        case .mark(let anchor):
            let a = min(anchor, at), e = max(anchor, at)
            draft = (a, max(minLength, e - a))
        case .moveLoop(let grab):
            let raw = Tick(Int64(beat * Double(Tick.perQuarter))) - grab
            let start = free ? max(0, raw) : Tick(max(0, (raw.rawValue + step / 2) / step * step))
            draft = (min(start, max(0, end - b.length)), b.length)
        case .left:
            let endTick = b.offset + b.length
            let start = min(at, endTick - minLength)
            draft = (start, endTick - start)
        case .right:
            draft = (b.offset, max(minLength, at - b.offset))
        case .start:
            // The start moves on its own. With Loop it stops just before the loop end.
            startDraft = clip.loop ? min(at, Tick(max(0, (b.offset + b.length - minLength).rawValue))) : min(at, end)
        }
    }

    private func commitDraft() {
        defer { dragMode = nil; draft = nil; startDraft = nil }
        var c = clip
        if let start = startDraft {
            // A session loop without a start of its own starts at the start marker: pin it, so it stays.
            if session && c.loopStart == nil { c.loopStart = brace.offset }
            c.offset = start
        } else if let draft {
            c.loopStart = draft.offset
            if session { c.length = draft.length } else { c.loopLength = draft.length }
            // With Loop the start marker may sit before the loop or inside it, never past its end.
            if clip.loop && c.offset >= draft.offset + draft.length { c.offset = draft.offset }
        }
        guard c != clip else { return }
        model.apply(.setClip(clip: .audio(c)))
    }
}
