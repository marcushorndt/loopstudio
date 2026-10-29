import LoopStudioCore
import SwiftUI

/// The sample page of an audio clip, like Live's: a loop bar above the waveform, a start marker, and zoom.
///
/// The loop bar shows the part of the file the clip plays as a brace. Drag in the bar to mark a new loop;
/// drag a brace edge to resize it, its middle to move it. The start marker below is the same start, as a
/// flag you can drag on its own. Everything snaps to the grid, which gets finer as you zoom in; Option
/// drags free. Zoom with a pinch, ⌘ and the scroll wheel, or the buttons.
struct SampleEditor: View {
    @Environment(AppModel.self) private var model
    let clip: AudioClip
    let asset: Asset
    let peaks: [Float]
    let tint: Color

    @State private var zoom: Double = 1
    @State private var pinchStart: Double?
    /// A loop being marked or changed, before it is committed.
    @State private var draft: (offset: Tick, length: Tick)?
    @State private var dragMode: LoopDrag?

    private enum LoopDrag { case mark(anchor: Tick), moveLoop(grab: Tick), left, right, start }
    private static let barHeight: CGFloat = 18
    private static let grab: CGFloat = 6

    private var warped: Bool { clip.warpMode != .off }

    /// Beats on the ruler for the whole file, through the warp markers or at the song tempo.
    private var geometry: WarpGeometry {
        WarpGeometry(markers: clip.warpMarkers, sourceTempo: warped ? (asset.sourceTempo ?? model.bpm) : model.bpm, assetRate: asset.sampleRate)
    }
    private var fileBeats: Double { geometry.beat(atSource: Double(asset.frames)) }
    private var totalBeats: Double { max(4, fileBeats, (clip.offset + clip.length).quarters) }

    /// The loop as drawn: the draft while a drag runs.
    private var shownOffset: Tick { draft?.offset ?? clip.offset }
    private var shownLength: Tick { draft?.length ?? clip.length }

    var body: some View {
        GeometryReader { geo in
            let viewport = geo.size.width
            let ppb = viewport * zoom / totalBeats
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
                zoomButtons
            }
            .gesture(MagnifyGesture()
                .onChanged { v in
                    if pinchStart == nil { pinchStart = zoom }
                    setZoom((pinchStart ?? 1) * v.magnification)
                }
                .onEnded { _ in pinchStart = nil })
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line, lineWidth: 1))
        .background(Theme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.radius))
        .onAppear { zoom = 1 }
    }

    // MARK: Grid and zoom

    /// The finest note value that still gets about 22 points per step at this zoom.
    private func gridStep(ppb: CGFloat) -> Int64 {
        let q = Int64(Tick.perQuarter)
        for step in [q / 16, q / 8, q / 4, q / 2, q, q * 2, q * 4] where CGFloat(step) / CGFloat(q) * ppb >= 22 { return step }
        return q * 4
    }

    private func setZoom(_ z: Double) { zoom = min(64, max(1, z)) }

    private var zoomButtons: some View {
        HStack(spacing: 2) {
            Button { setZoom(zoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }.hint("Zoom out")
            Button { setZoom(zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }.hint("Zoom in. The grid gets finer as you zoom.")
            Button { setZoom(1) } label: { Image(systemName: "arrow.left.and.right.square") }.hint("Show the whole file")
        }
        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.dim)
        .padding(4).background(Theme.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
        .padding(.top, Self.barHeight + 4).padding(.trailing, 14)
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
            ctx.fill(Path(roundedRect: brace, cornerRadius: 2), with: .color(tint.opacity(draft == nil ? 0.45 : 0.7)))
            ctx.stroke(Path(roundedRect: brace, cornerRadius: 2), with: .color(tint), lineWidth: 1)
            for x in [x0, x1] { ctx.fill(Path(CGRect(x: x - 1.5, y: 2, width: 3, height: size.height - 4)), with: .color(tint)) }
            ctx.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(Theme.line))
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { v in
                let free = NSEvent.modifierFlags.contains(.option)
                let here = Double(v.location.x / ppb)
                if dragMode == nil {
                    let x0 = CGFloat(clip.offset.quarters) * ppb, x1 = CGFloat((clip.offset + clip.length).quarters) * ppb
                    let x = v.startLocation.x
                    if abs(x - x0) <= Self.grab { dragMode = .left }
                    else if abs(x - x1) <= Self.grab { dragMode = .right }
                    else if x > x0 && x < x1 { dragMode = .moveLoop(grab: Tick(Int64(Double(x / ppb) * Double(Tick.perQuarter))) - clip.offset) }
                    else { dragMode = .mark(anchor: snapped(Double(x / ppb), step: step, free: free)) }
                }
                update(dragMode, beat: here, step: step, free: free)
            }
            .onEnded { _ in commitDraft() })
        .hint("Loop bar. Drag to mark the loop, drag an edge to resize it, drag the middle to move it. Option drags free of the grid.")
    }

    // MARK: Waveform and start marker

    @ViewBuilder
    private func waveformArea(ppb: CGFloat, step: Int64) -> some View {
        ZStack(alignment: .topLeading) {
            if warped {
                WarpEditor(clip: clip, asset: asset, peaks: peaks, tint: tint, ppb: ppb)
            } else {
                waveform(ppb: ppb, step: step)
                ClipPlayhead(clip: clip.id, period: clip.length) { CGFloat((clip.offset + $0).quarters) * ppb }
            }
            startMarker(ppb: ppb, step: step)
        }
    }

    private func waveform(ppb: CGFloat, step: Int64) -> some View {
        Canvas { ctx, size in
            // The grid at the current step; bars stronger.
            let bar = model.barTicks
            var t: Int64 = 0
            while Double(t) / Double(Tick.perQuarter) <= totalBeats {
                let x = CGFloat(Double(t) / Double(Tick.perQuarter)) * ppb
                let strong = t % bar == 0
                ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(Theme.text.opacity(strong ? 0.14 : (t % Int64(Tick.perQuarter) == 0 ? 0.08 : 0.04))))
                t += step
            }
            let x0 = CGFloat(shownOffset.quarters) * ppb, x1 = CGFloat((shownOffset + shownLength).quarters) * ppb
            ctx.fill(Path(CGRect(x: 0, y: 0, width: x0, height: size.height)), with: .color(Theme.background.opacity(0.55)))
            ctx.fill(Path(CGRect(x: x1, y: 0, width: max(0, size.width - x1), height: size.height)), with: .color(Theme.background.opacity(0.55)))
            guard !peaks.isEmpty, asset.frames > 0 else { return }
            let mid = size.height / 2
            var path = Path()
            var x: CGFloat = 0
            let g = geometry
            while x < size.width {
                let frac = g.source(atBeat: Double(x / ppb)) / Double(asset.frames)
                if frac >= 1 { break }
                if frac >= 0 {
                    let amp = CGFloat(peaks[min(peaks.count - 1, Int(frac * Double(peaks.count)))]) * (size.height * 0.45)
                    path.addRect(CGRect(x: x, y: mid - max(0.5, amp), width: 1.2, height: max(1, amp * 2)))
                }
                x += 1.5
            }
            ctx.fill(path, with: .color(tint.opacity(0.9)))
        }
    }

    /// The flag at the clip's start in the file. Drag it to move the start; the length stays.
    private func startMarker(ppb: CGFloat, step: Int64) -> some View {
        GeometryReader { geo in
            let x = CGFloat(shownOffset.quarters) * ppb
            let active = dragMode != nil && { if case .start? = dragMode { true } else { false } }()
            ZStack(alignment: .topLeading) {
                Rectangle().fill(active ? Theme.text : tint).frame(width: 1.5, height: geo.size.height).offset(x: x - 0.75)
                Image(systemName: "play.fill").font(.system(size: 9))
                    .foregroundStyle(Theme.onTint)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(active ? Theme.text : tint, in: RoundedRectangle(cornerRadius: 2))
                    .offset(x: x, y: 2)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { v in
                            dragMode = .start
                            update(.start, beat: Double((x + v.translation.width) / ppb), step: step, free: NSEvent.modifierFlags.contains(.option))
                        }
                        .onEnded { _ in commitDraft() })
                    .hint("Start marker: where the clip begins in the file. Drag it; Option drags free of the grid.")
            }
        }
    }

    // MARK: Edits

    private func update(_ mode: LoopDrag?, beat: Double, step: Int64, free: Bool) {
        guard let mode else { return }
        let end = Tick(Int64((max(totalBeats, fileBeats) * Double(Tick.perQuarter)).rounded()))
        let at = snapped(beat, step: step, free: free)
        let minLength = Tick(free ? Int64(Tick.perQuarter) / 16 : step)
        switch mode {
        case .mark(let anchor):
            let a = min(anchor, at), b = max(anchor, at)
            draft = (a, max(minLength, b - a))
        case .moveLoop(let grab):
            let raw = Tick(Int64(beat * Double(Tick.perQuarter))) - grab
            let start = free ? max(0, raw) : Tick(max(0, (raw.rawValue + step / 2) / step * step))
            draft = (min(start, max(0, end - clip.length)), clip.length)
        case .left:
            let endTick = clip.offset + clip.length
            let start = min(at, endTick - minLength)
            draft = (start, endTick - start)
        case .right:
            draft = (clip.offset, max(minLength, at - clip.offset))
        case .start:
            draft = (min(at, max(0, end - clip.length)), clip.length)
        }
    }

    private func commitDraft() {
        defer { dragMode = nil; draft = nil }
        guard let draft, draft.offset != clip.offset || draft.length != clip.length else { return }
        var c = clip
        c.offset = draft.offset
        c.length = draft.length
        model.apply(.setClip(clip: .audio(c)))
    }
}
