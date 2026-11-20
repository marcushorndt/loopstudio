import LoopStudioCore
import SwiftUI

/// The mapping between source frames and timeline beats that warp markers describe.
/// Markers are linear segments; beyond the first and last marker the nearest segment continues.
/// Without markers the mapping follows the source tempo. Source frames count at the asset's own sample rate.
struct WarpGeometry {
    var beats: [Double]
    var frames: [Double]
    var slope: Double   // frames per beat when there are fewer than two markers

    init(markers: [WarpMarker], sourceTempo: Double, assetRate: Double) {
        let sorted = markers.sorted { $0.tick < $1.tick }
        beats = sorted.map { $0.tick.quarters }
        frames = sorted.map { Double($0.sourceFrame) }
        slope = 60 / max(1, sourceTempo) * assetRate
    }

    var hasMarkers: Bool { beats.count >= 2 }

    func source(atBeat x: Double) -> Double {
        guard hasMarkers else { return x * slope }
        var i = 0
        while i < beats.count - 2 && x > beats[i + 1] { i += 1 }
        let span = beats[i + 1] - beats[i]
        guard span > 0 else { return frames[i] }
        return frames[i] + (x - beats[i]) / span * (frames[i + 1] - frames[i])
    }

    func beat(atSource s: Double) -> Double {
        guard hasMarkers else { return s / slope }
        var i = 0
        while i < frames.count - 2 && s > frames[i + 1] { i += 1 }
        let span = frames[i + 1] - frames[i]
        guard span > 0 else { return beats[i] }
        return beats[i] + (s - frames[i]) / span * (beats[i + 1] - beats[i])
    }
}

/// The warp marker editor of an audio clip: the whole sample on a beat ruler.
/// Double-click adds a marker, drag moves it, double-click on a marker deletes it.
struct WarpEditor: View {
    @Environment(AppModel.self) private var model
    let clip: AudioClip
    let asset: Asset
    let peaks: WavePeaks
    let tint: Color
    /// Points per beat from an enclosing editor that zooms; `nil` fits the whole sample.
    var ppb: CGFloat? = nil
    /// The part of the editor in view, from an enclosing editor that scrolls: only that part is drawn.
    var visible: ClosedRange<CGFloat>? = nil
    /// A playhead period that never wraps: the clip's own loop does the wrapping (`AudioClip.playTick`).
    static let noPeriod = Tick(1 << 60)
    /// A drag that does not start on a marker marks a stretch: its press and its pointer x, and the end.
    var onMark: ((CGFloat, CGFloat) -> Void)? = nil
    var onMarkEnd: (() -> Void)? = nil
    @State private var marking = false

    @State private var dragIndex: Int?
    @State private var dragTick: Tick?

    private static let grab: CGFloat = 7
    private var grid: Int64 { Int64(Tick.perQuarter) / 4 }

    private var markers: [WarpMarker] { clip.warpMarkers.sorted { $0.tick < $1.tick } }

    /// Markers as drawn: the one being dragged follows the pointer.
    private var shown: [WarpMarker] {
        var m = markers
        if let i = dragIndex, let t = dragTick, m.indices.contains(i) { m[i].tick = t }
        return m
    }

    private var geometry: WarpGeometry {
        WarpGeometry(markers: shown, sourceTempo: asset.sourceTempo ?? model.bpm, assetRate: asset.sampleRate)
    }

    /// Beats the editor shows: the whole sample, and at least the clip.
    private var totalBeats: Double {
        let end = geometry.beat(atSource: Double(asset.frames))
        let clipEnd = (clip.offset + clip.length).quarters
        return max(4, end, clipEnd)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let ppb = self.ppb ?? w / totalBeats
            let g = geometry
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    // Beat grid
                    let shown = visible ?? 0...size.width
                    var b = max(0, Int(shown.lowerBound / ppb))
                    while Double(b) <= totalBeats {
                        let x = CGFloat(Double(b)) * ppb
                        if x > shown.upperBound { break }
                        ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(Theme.text.opacity(b % 4 == 0 ? 0.14 : 0.06)))
                        b += 1
                    }
                    // The part of the sample this clip plays
                    let x0 = CGFloat(clip.offset.quarters) * ppb, x1 = CGFloat((clip.offset + clip.length).quarters) * ppb
                    ctx.fill(Path(CGRect(x: 0, y: 0, width: x0, height: size.height)), with: .color(Theme.background.opacity(0.55)))
                    ctx.fill(Path(CGRect(x: x1, y: 0, width: max(0, size.width - x1), height: size.height)), with: .color(Theme.background.opacity(0.55)))
                    // Waveform, drawn through the warp mapping
                    guard asset.frames > 0 else { return }
                    let frames = Double(asset.frames)
                    peaks.draw(in: ctx, from: max(0, shown.lowerBound), to: min(size.width, shown.upperBound), mid: size.height / 2 + 6,
                               half: size.height * 0.4, color: tint.opacity(0.9), gainDb: clip.gainDb) { g.source(atBeat: Double($0 / ppb)) / frames }
                }
                ForEach(Array(shown.enumerated()), id: \.offset) { i, m in
                    let x = CGFloat(m.tick.quarters) * ppb
                    Rectangle().fill(i == dragIndex ? Theme.text : Theme.accent).frame(width: 1.5, height: h).offset(x: x - 0.75)
                    Image(systemName: "triangle.fill").font(.system(size: 8)).rotationEffect(.degrees(180))
                        .foregroundStyle(i == dragIndex ? Theme.text : Theme.accent).offset(x: x - 4, y: 0)
                }
                ClipPlayhead(clip: clip.id, period: Self.noPeriod) {
                    CGFloat(clip.playTick(after: $0, session: model.isSessionClip(clip.id), fileTicks: model.fileTicks(clip, asset)).quarters) * ppb
                }
                if shown.isEmpty {
                    Text("Double-click to add a warp marker.").font(.caption).foregroundStyle(Theme.dim)
                        .padding(6).offset(y: h - 26)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { v in
                    if dragIndex == nil && !marking {
                        dragIndex = nearest(x: v.startLocation.x, ppb: ppb)
                        marking = dragIndex == nil && onMark != nil
                    }
                    if marking { onMark?(v.startLocation.x, v.location.x); return }
                    guard let i = dragIndex else { return }
                    dragTick = clamped(i, beat: Double(v.location.x / ppb), free: model.freeOfGrid())
                }
                .onEnded { _ in
                    defer { dragIndex = nil; dragTick = nil; marking = false }
                    if marking { onMarkEnd?(); return }
                    guard let i = dragIndex, let t = dragTick, markers.indices.contains(i), markers[i].tick != t else { return }
                    var m = markers
                    m[i].tick = t
                    commit(m)
                })
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { v in
                if let i = nearest(x: v.location.x, ppb: ppb) { remove(i) } else { add(atBeat: Double(v.location.x / ppb)) }
            })
            .contextMenu {
                Button("Clear All Markers") { commit([]) }.disabled(markers.isEmpty)
            }
        }
    }

    private func nearest(x: CGFloat, ppb: Double) -> Int? {
        let hit = shown.enumerated().map { ($0.offset, abs(CGFloat($0.element.tick.quarters) * ppb - x)) }.min { $0.1 < $1.1 }
        if let hit, hit.1 <= Self.grab { return hit.0 }
        return nil
    }

    /// A moved marker stays between its neighbours; it snaps to a sixteenth on the grid (see `freeOfGrid`).
    private func clamped(_ i: Int, beat: Double, free: Bool) -> Tick {
        var raw = Int64((beat * Double(Tick.perQuarter)).rounded())
        if !free { raw = (raw + grid / 2) / grid * grid }
        let lower = i > 0 ? markers[i - 1].tick.rawValue + 1 : 0
        let upper = i < markers.count - 1 ? markers[i + 1].tick.rawValue - 1 : Int64.max
        return Tick(min(max(raw, lower), upper))
    }

    /// A new marker keeps the current mapping where it lands, so nothing moves until you drag it.
    private func add(atBeat b: Double) {
        let raw = Int64((b * Double(Tick.perQuarter)).rounded())
        let tick = Tick((raw + grid / 2) / grid * grid)
        let source = Int64(geometry.source(atBeat: tick.quarters).rounded())
        guard tick.rawValue > 0, source > 0, source < asset.frames else { return }
        var m = markers
        if m.isEmpty { m.append(WarpMarker(sourceFrame: 0, tick: 0)) }   // the anchor at the start
        guard !m.contains(where: { $0.tick == tick }) else { return }
        m.append(WarpMarker(sourceFrame: source, tick: tick))
        commit(m.sorted { $0.tick < $1.tick })
    }

    private func remove(_ i: Int) {
        var m = markers
        guard m.indices.contains(i) else { return }
        m.remove(at: i)
        commit(m.count < 2 ? [] : m)   // one marker alone maps nothing; back to the source tempo
    }

    private func commit(_ m: [WarpMarker]) {
        model.apply(.setClipWarp(clip: clip.id, mode: clip.warpMode, markers: m))
    }
}
