import LoopStudioCore
import SwiftUI

/// The full MIDI range. The roll scrolls, and opens centred on the notes of the clip.
private let lowPitch = 0, highPitch = 127
private let keysWidth: CGFloat = 46

/// The grid follows the zoom, like Live's adaptive grid: the finest division whose cells are at least this wide.
private let minCellWidth: CGFloat = 30

/// The grid step at a zoom: the finest division with cells of `minCellWidth` or more, from a 1/128 up to a bar.
func adaptiveGrid(pxPerBeat: CGFloat, bar: Int64) -> Int64 {
    let q = Tick.perQuarter
    let steps: [Int64] = [q / 32, q / 16, q / 8, q / 4, q / 2, q, q * 2, max(q * 2, bar)]
    let pxPerTick = pxPerBeat / CGFloat(q)
    return steps.first { CGFloat($0) * pxPerTick >= minCellWidth } ?? steps.last!
}

/// The name of a grid step: "1/16", "1/4", "1 bar".
func gridName(_ step: Int64, bar: Int64) -> String {
    if step >= bar { return "1 bar" }
    let whole = Tick.perQuarter * 4
    return whole % step == 0 ? "1/\(whole / step)" : "\(step) ticks"
}

/// A piano roll for one MIDI clip. At zoom 1 the clip fills the width of the panel.
/// Double-click an empty cell to add a note, click a note to select it, drag it to move it, drag an edge
/// to change its length, double-click it to delete it. A drag on empty space marks the notes in a rectangle.
/// The pen (B) draws with a click or a drag. The grid follows the zoom; snap (⌘4) can be off.
struct PianoRoll: View {
    @Environment(AppModel.self) private var model
    let clip: MIDIClip
    let tint: Color
    /// 1 fits the clip into the visible width; more zooms in.
    @State private var zoom: Double = 1
    /// The height of one pitch row: the vertical zoom.
    @State private var rowHeight: CGFloat = 13
    /// The zoom values when a pinch began.
    @State private var pinchStart: (zoom: Double, row: CGFloat)?
    /// Option plus a two-finger scroll zooms the rows; Command plus a scroll zooms in time.
    @State private var wheel = WheelZoom()
    @State private var visibleWidth: CGFloat = 0
    @State private var lastLength: Int64 = Int64(Tick.perQuarter / 2)
    /// Notes the pen draws during one drag. They become one edit when the drag ends.
    @State private var drawn: [MIDINote] = []
    /// The rectangle of a marking drag on empty space, in roll points.
    @State private var band: CGRect?
    /// The marking before a Shift or Command band drag began; the band adds to it.
    @State private var bandBase: Set<MIDINote> = []
    /// The pitch a dragged note is over: its row and key light up.
    @State private var heldPitch: Int?

    /// The grid step at this zoom. Snap off still shows it, but notes land on single ticks.
    private var division: Int64 { adaptiveGrid(pxPerBeat: pxPerBeat, bar: model.barTicks) }
    private var grid: Int64 { model.snapNotes ? division : 1 }

    /// The loop bar above the notes, like Live's: its end is the clip length and can be dragged.
    private static let loopBarHeight: CGFloat = 16
    /// The velocity lane under the notes.
    private static let laneHeight: CGFloat = 56
    @State private var draftLength: Tick?
    @State private var scrollY: CGFloat = 0
    @State private var visibleHeight: CGFloat = 0
    /// A drag in the velocity lane: the notes it changes and their velocities when it began.
    @State private var velocityDrag: (targets: [MIDINote], start: [UInt8])?

    private var beats: Double { max(1, Double(clip.length.rawValue) / Double(Tick.perQuarter)) }
    /// Room past the end of the clip, so the loop can be made longer.
    private var roomBeats: Double { beats + max(4, beats * 0.5) }
    private var pxPerBeat: CGFloat { max(8, (visibleWidth - keysWidth - 2) / CGFloat(beats)) * CGFloat(zoom) }
    private var width: CGFloat { max(100, CGFloat(roomBeats) * pxPerBeat) }
    private var height: CGFloat { CGFloat(highPitch - lowPitch + 1) * rowHeight }
    /// Moves the velocity lane from its place under the rows up to the bottom of the visible area.
    private var laneOffset: CGFloat {
        guard visibleHeight > 0 else { return 0 }
        return min(0, scrollY + visibleHeight - (Self.loopBarHeight + height + Self.laneHeight))
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text("\(clip.notes.count) notes").font(.caption).foregroundStyle(Theme.dim)
                if !marked.isEmpty {
                    Text("\(marked.count) marked · vel \(velocityText)").font(.caption).foregroundStyle(Theme.dim)
                }
                Spacer()
                Button("Quantize") { quantize() }
                    .controlSize(.small).disabled(clip.notes.isEmpty)
                    .hint("Quantize: move the marked notes (or all notes) to the nearest grid step (\(gridName(division, bar: model.barTicks)))")
                toolButton("grid", on: model.snapNotes, help: "Snap to grid (⌘4). The grid follows the zoom: now \(gridName(division, bar: model.barTicks)). Off, notes land on the exact tick. Command during a drag does the opposite of this switch.") {
                    model.perform(.snapNotes)
                }
                Text(gridName(division, bar: model.barTicks)).font(.system(size: 9, design: .monospaced)).foregroundStyle(model.snapNotes ? tint : Theme.dim)
                    .frame(width: 30, alignment: .leading)
                toolButton("pencil", on: model.drawMode, help: "Draw mode (B): click or drag to draw notes, click a note to delete it") {
                    model.drawMode.toggle()
                }
                toolButton(model.previewNotes ? "speaker.wave.2.fill" : "speaker.slash", on: model.previewNotes,
                           help: "Preview: play a note when it is tapped, created, or dragged to another key; a tap on a key plays it too") {
                    model.previewNotes.toggle()
                }
                Text("X").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.dim)
                Slider(value: $zoom, in: 1...8).controlSize(.mini).frame(width: 90)
                    .hint("Horizontal zoom. All the way left, the clip fills the width. Pinch, or Command and scroll.")
                Text("Y").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.dim)
                Slider(value: $rowHeight, in: 6...28).controlSize(.mini).frame(width: 70)
                    .hint("Vertical zoom: the height of a note row. Option and scroll up or down.")
            }
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    VStack(spacing: 0) {
                    // The loop bar is pinned to the top: it moves with the vertical scroll, against it.
                    HStack(spacing: 0) {
                        Rectangle().fill(Theme.panel).frame(width: keysWidth, height: Self.loopBarHeight)
                        loopBar.frame(width: width, height: Self.loopBarHeight)
                    }
                    .offset(y: scrollY).zIndex(1)
                    HStack(alignment: .top, spacing: 0) {
                        Keys(rowHeight: rowHeight, names: model.drumNames(ofTrack: model.project.findClip(clip.id)?.0), highlight: heldPitch, tint: tint) { pitch in
                            // A tap on a key marks every note on it (Shift or Command adds) and plays it.
                            let extend = NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command)
                            let onKey = Set(clip.notes.filter { $0.pitch == pitch })
                            model.selectedNotes = extend ? model.selectedNotes.union(onKey) : onKey
                            if model.previewNotes { model.auditionNote(pitch) }
                        }
                            .frame(width: keysWidth, height: height)
                        ZStack(alignment: .topLeading) {
                            Canvas { ctx, size in drawGrid(&ctx, size) }
                                .frame(width: width, height: height)
                                .contentShape(Rectangle())
                                .gesture(penGesture, including: model.drawMode ? .all : .subviews)
                                .gesture(bandGesture, including: model.drawMode ? .subviews : .all)
                                .onTapGesture { model.selectedNotes = [] }
                                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { if !model.drawMode { add(at: $0.location) } })
                            ForEach(Array(clip.notes.enumerated()), id: \.offset) { index, note in
                                NoteView(clip: clip, index: index, note: note, tint: tint, pxPerBeat: pxPerBeat, rowHeight: rowHeight, step: division, snap: model.snapNotes,
                                         rememberLength: { lastLength = $0 }, held: { heldPitch = $0 })
                            }
                            if clip.groove != nil {
                                // Where the groove plays each note: a faint outline at the moved place.
                                Canvas { ctx, _ in
                                    for n in clip.playedNotes {
                                        let x = CGFloat(Double(n.tick.rawValue) / Double(Tick.perQuarter)) * pxPerBeat
                                        let w = max(4, CGFloat(Double(n.length.rawValue) / Double(Tick.perQuarter)) * pxPerBeat)
                                        let y = CGFloat(highPitch - Int(n.pitch)) * rowHeight
                                        ctx.stroke(Path(roundedRect: CGRect(x: x + 0.5, y: y + 0.5, width: w - 1, height: rowHeight - 2), cornerRadius: 2),
                                                   with: .color(.white.opacity(0.35 + 0.4 * Double(n.velocity) / 127)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                                    }
                                }
                                .frame(width: width, height: height)
                                .allowsHitTesting(false)
                            }
                            if let band {
                                Rectangle().fill(Color.white.opacity(0.08))
                                    .overlay(Rectangle().stroke(Color.white.opacity(0.7), lineWidth: 1))
                                    .frame(width: band.width, height: band.height)
                                    .offset(x: band.minX, y: band.minY)
                                    .allowsHitTesting(false)
                            }
                            ForEach(Array(drawn.enumerated()), id: \.offset) { _, note in
                                RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.6))
                                    .frame(width: max(4, CGFloat(Double(note.length.rawValue) / Double(Tick.perQuarter)) * pxPerBeat), height: rowHeight - 1)
                                    .offset(x: CGFloat(Double(note.tick.rawValue) / Double(Tick.perQuarter)) * pxPerBeat,
                                            y: CGFloat(highPitch - Int(note.pitch)) * rowHeight)
                                    .allowsHitTesting(false)
                            }
                            ClipPlayhead(clip: clip.id, period: clip.length) { CGFloat($0.quarters) * pxPerBeat }
                        }
                        .frame(width: width, height: height)
                    }
                    .id("roll")
                    // The velocity lane is pinned to the bottom of the view; scrolled all the way down it sits under the rows.
                    HStack(spacing: 0) {
                        Rectangle().fill(Theme.panel).frame(width: keysWidth, height: Self.laneHeight)
                            .overlay(alignment: .topLeading) { Text("Vel").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.dim).padding(4) }
                        velocityLane.frame(width: width, height: Self.laneHeight)
                    }
                    .offset(y: laneOffset).zIndex(1)
                    }
                }
                .onScrollGeometryChange(for: CGFloat.self, of: \.containerSize.height) { _, h in visibleHeight = h }
                .onScrollGeometryChange(for: CGFloat.self, of: \.containerSize.width) { _, w in visibleWidth = w }
                .onScrollGeometryChange(for: CGFloat.self, of: \.contentOffset.y) { _, y in scrollY = max(0, y) }
                // A pinch zooms in time; with Option held it zooms the row height.
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { g in
                        if pinchStart == nil { pinchStart = (zoom, rowHeight) }
                        guard let start = pinchStart else { return }
                        if NSEvent.modifierFlags.contains(.option) {
                            rowHeight = min(28, max(6, start.row * g.magnification))
                        } else {
                            zoom = min(8, max(1, start.zoom * g.magnification))
                        }
                    }
                    .onEnded { _ in pinchStart = nil })
                .onHover { wheel.inside = $0 }
                .onAppear {
                    wheel.install { dy, option in
                        if option { rowHeight = min(28, max(6, rowHeight + dy * 0.25)) }
                        else { zoom = min(8, max(1, zoom * (1 + Double(dy) * 0.01))) }
                    }
                }
                .onDisappear { wheel.remove() }
                .onChange(of: division, initial: true) { _, step in model.noteGrid = step }
                .onAppear {
                    let mid = clip.notes.isEmpty ? 60 : Int(clip.notes.map { Int($0.pitch) }.reduce(0, +)) / clip.notes.count
                    proxy.scrollTo("roll", anchor: UnitPoint(x: 0, y: 1 - Double(mid - lowPitch) / Double(highPitch - lowPitch)))
                }
            }
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: Theme.radius))
        }
    }

    /// The loop bar: a brace from the clip start to its length, with bar numbers. Drag the end to set the length.
    private var loopBar: some View {
        let shown = draftLength ?? clip.length
        return Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.panel))
            let barBeats = Double(model.barTicks) / Double(Tick.perQuarter)
            var b = 0.0, n = 1
            while b <= roomBeats {
                let x = CGFloat(b) * pxPerBeat
                ctx.fill(Path(CGRect(x: x, y: size.height - 5, width: 1, height: 5)), with: .color(Theme.dim))
                if pxPerBeat * CGFloat(barBeats) >= 24 {
                    ctx.draw(Text("\(n)").font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.dim), at: CGPoint(x: x + 3, y: 6), anchor: .leading)
                }
                b += barBeats; n += 1
            }
            let x1 = CGFloat(shown.quarters) * pxPerBeat
            let brace = CGRect(x: 0, y: 2, width: max(2, x1), height: size.height - 4)
            ctx.fill(Path(roundedRect: brace, cornerRadius: 2), with: .color(tint.opacity(draftLength == nil ? 0.45 : 0.7)))
            ctx.stroke(Path(roundedRect: brace, cornerRadius: 2), with: .color(tint), lineWidth: 1)
            ctx.fill(Path(CGRect(x: x1 - 1.5, y: 2, width: 3, height: size.height - 4)), with: .color(tint))
            ctx.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(Theme.line))
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { v in
                // The end of the brace moves; a beat is the smallest loop. Option drags free of the grid.
                let free = NSEvent.modifierFlags.contains(.option)
                var raw = Int64(Double(v.location.x / pxPerBeat) * Double(Tick.perQuarter))
                if !free { raw = (raw + Tick.perQuarter / 2) / Tick.perQuarter * Tick.perQuarter }
                draftLength = Tick(max(free ? division : Tick.perQuarter, raw))
            }
            .onEnded { _ in
                if let length = draftLength, length != clip.length {
                    model.apply(.setClipRange(clip: clip.id, start: clip.start, length: length))
                }
                draftLength = nil
            })
        .hint("Loop bar. Drag the end to set the clip's loop length; notes past the end stay but do not play. Option drags free of the grid.")
    }

    private var marked: [MIDINote] { clip.notes.filter { model.selectedNotes.contains($0) } }

    /// The velocity of the marked notes: one value, or the range.
    private var velocityText: String {
        let v = marked.map { Int($0.velocity) }
        guard let lo = v.min(), let hi = v.max() else { return "-" }
        return lo == hi ? "\(lo)" : "\(lo)–\(hi)"
    }

    /// The lane under the notes, like Live's: one marker per note, as high as its velocity. Drag a marker up or
    /// down; the marked notes move together. It stays at the bottom of the view while the roll scrolls.
    private var velocityLane: some View {
        let laneHeight = Self.laneHeight, top: CGFloat = 8
        return Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.panel))
            ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 1)), with: .color(Theme.line))
            let bar = max(Tick.perQuarter, model.barTicks)
            var tick: Int64 = 0
            while Double(tick) <= roomBeats * Double(Tick.perQuarter) {
                let x = CGFloat(Double(tick) / Double(Tick.perQuarter)) * pxPerBeat
                ctx.fill(Path(CGRect(x: x, y: 1, width: 1, height: size.height - 1)), with: .color(.white.opacity(tick % bar == 0 ? 0.2 : 0.08)))
                tick += Tick.perQuarter
            }
            for note in clip.notes {
                let x = CGFloat(Double(note.tick.rawValue) / Double(Tick.perQuarter)) * pxPerBeat
                let h = CGFloat(note.velocity) / 127 * (size.height - top)
                let on = model.selectedNotes.contains(note)
                let color: Color = on ? .white : (note.muted ? tint.opacity(0.3) : tint)
                ctx.fill(Path(CGRect(x: x - 0.5, y: size.height - h, width: 2, height: h)), with: .color(color.opacity(0.75)))
                ctx.fill(Path(ellipseIn: CGRect(x: x - 3, y: size.height - h - 3, width: 7, height: 7)), with: .color(color))
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                if velocityDrag == nil {
                    // The marker nearest to the pointer, within 6 points; a marked one wins.
                    let near = clip.notes.filter { abs(CGFloat(Double($0.tick.rawValue) / Double(Tick.perQuarter)) * pxPerBeat - g.startLocation.x) <= 6 }
                    guard let hit = near.first(where: { model.selectedNotes.contains($0) }) ?? near.first else { velocityDrag = ([], []); return }
                    if !model.selectedNotes.contains(hit) { model.selectedNotes = [hit] }
                    let group = clip.notes.filter { model.selectedNotes.contains($0) }
                    velocityDrag = (group, group.map(\.velocity))
                }
                guard let d = velocityDrag, !d.targets.isEmpty else { return }
                let delta = Int((-g.translation.height / (laneHeight - top) * 127).rounded())
                applyVelocity(model, clip, targets: d.targets, start: d.start, delta: delta)
            }
            .onEnded { _ in velocityDrag = nil })
        .hint("Velocity lane. Drag a marker up or down; marked notes change together. Control and drag on a note does the same.")
    }

    /// Moves note starts to the nearest grid step. The marked notes, or every note when none is marked.
    private func quantize() {
        let all = model.selectedNotes.isEmpty
        let step = division
        var moved: Set<MIDINote> = []
        let notes = clip.notes.map { n -> MIDINote in
            guard all || model.selectedNotes.contains(n) else { return n }
            var q = n
            q.tick = Tick(min((n.tick.rawValue + step / 2) / step * step, max(0, clip.length.rawValue - 1)))
            q.length = Tick(max(1, min(n.length.rawValue, clip.length.rawValue - q.tick.rawValue)))
            moved.insert(q)
            return q
        }
        model.setNotes(clip.id, notes)
        if !all { model.selectedNotes = moved }
    }

    private func toolButton(_ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 20)
                .foregroundStyle(on ? tint : Theme.dim)
                .background(on ? tint.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(on ? tint.opacity(0.5) : Theme.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hint(help)
    }

    private func drawGrid(_ ctx: inout GraphicsContext, _ size: CGSize) {
        for pitch in lowPitch...highPitch {
            let y = CGFloat(highPitch - pitch) * rowHeight
            let black = [1, 3, 6, 8, 10].contains(pitch % 12)
            ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: rowHeight)), with: .color(black ? .black.opacity(0.28) : .white.opacity(0.03)))
            if pitch % 12 == 0 { ctx.fill(Path(CGRect(x: 0, y: y + rowHeight - 1, width: size.width, height: 1)), with: .color(.white.opacity(0.12))) }
        }
        // The row a dragged note is over.
        if let p = heldPitch {
            ctx.fill(Path(CGRect(x: 0, y: CGFloat(highPitch - p) * rowHeight, width: size.width, height: rowHeight)), with: .color(tint.opacity(0.18)))
        }
        // Lines on the grid of this zoom; beats and bars stand out.
        let step = division, bar = max(Tick.perQuarter, model.barTicks)
        let roomTicks = Int64(roomBeats * Double(Tick.perQuarter))
        var tick: Int64 = 0
        while tick <= roomTicks {
            let x = CGFloat(Double(tick) / Double(Tick.perQuarter)) * pxPerBeat
            let strong = tick % bar == 0, beat = tick % Tick.perQuarter == 0
            ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                     with: .color(.white.opacity(strong ? 0.28 : (beat ? 0.12 : 0.05))))
            tick += step
        }
        // Past the end of the clip nothing plays.
        let end = CGFloat(Double(clip.length.rawValue) / Double(Tick.perQuarter)) * pxPerBeat
        ctx.fill(Path(CGRect(x: end, y: 0, width: max(0, size.width - end), height: size.height)), with: .color(.black.opacity(0.35)))
    }

    /// The cell at a point: its start tick on `step` and its pitch. `nil` outside the clip.
    private func cell(_ point: CGPoint, step: Int64) -> (tick: Int64, pitch: Int)? {
        let tick = Int64(Double(point.x / pxPerBeat) * Double(Tick.perQuarter)) / step * step
        let pitch = highPitch - Int(point.y / rowHeight)
        guard tick >= 0, tick < clip.length.rawValue, (lowPitch...highPitch).contains(pitch) else { return nil }
        return (tick, pitch)
    }

    /// A double-click adds a note with the last used length. With snap off it starts on the exact tick.
    private func add(at point: CGPoint) {
        guard let (tick, pitch) = cell(point, step: grid) else { return }
        let note = MIDINote(tick: Tick(tick), length: Tick(min(lastLength, clip.length.rawValue - tick)), pitch: UInt8(pitch))
        model.setNotes(clip.id, clip.notes + [note])
        model.selectedNotes = [note]
        if model.previewNotes { model.auditionNote(UInt8(pitch)) }
    }

    /// A drag on empty space marks every note the rectangle touches. Shift or Command adds to the marking.
    private var bandGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { g in
                if band == nil {
                    let extend = NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command)
                    bandBase = extend ? model.selectedNotes : []
                }
                let rect = CGRect(x: min(g.startLocation.x, g.location.x), y: min(g.startLocation.y, g.location.y),
                                  width: abs(g.translation.width), height: abs(g.translation.height))
                band = rect
                let hit = clip.notes.filter { n in
                    let x = CGFloat(Double(n.tick.rawValue) / Double(Tick.perQuarter)) * pxPerBeat
                    let w = max(4, CGFloat(Double(n.length.rawValue) / Double(Tick.perQuarter)) * pxPerBeat)
                    let y = CGFloat(highPitch - Int(n.pitch)) * rowHeight
                    return rect.intersects(CGRect(x: x, y: y, width: w, height: rowHeight))
                }
                model.selectedNotes = bandBase.union(hit)
            }
            .onEnded { _ in band = nil }
    }

    /// The pen: every grid cell the drag crosses gets a note of one grid step at the pitch under the pointer.
    private var penGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                guard let (tick, pitch) = cell(g.location, step: division) else { return }
                let taken = (clip.notes + drawn).contains { $0.pitch == UInt8(pitch) && $0.tick.rawValue <= tick && tick < $0.tick.rawValue + $0.length.rawValue }
                guard !taken else { return }
                drawn.append(MIDINote(tick: Tick(tick), length: Tick(min(division, clip.length.rawValue - tick)), pitch: UInt8(pitch)))
                if model.previewNotes { model.auditionNote(UInt8(pitch)) }
            }
            .onEnded { _ in
                guard !drawn.isEmpty else { return }
                model.setNotes(clip.id, clip.notes + drawn)
                drawn = []
            }
    }
}

/// Sets the velocity of `targets` (found by their place, since a changed note is a new value) to their value at
/// the start of the drag plus `delta`. The marking follows the notes; one drag is one undo step.
@MainActor
private func applyVelocity(_ model: AppModel, _ clip: MIDIClip, targets: [MIDINote], start: [UInt8], delta: Int) {
    var changed: Set<MIDINote> = []
    let notes = clip.notes.map { n -> MIDINote in
        guard let i = targets.firstIndex(where: { $0.tick == n.tick && $0.pitch == n.pitch && $0.length == n.length }) else { return n }
        var m = n
        m.velocity = UInt8(min(127, max(1, Int(start[i]) + delta)))
        changed.insert(m)
        return m
    }
    model.selectedNotes = changed
    model.setNotes(clip.id, notes, key: "velocity\(clip.id)")
}

/// Catches a scroll with Option or Command held over the piano roll and turns it into zoom.
/// A plain scroll still scrolls the roll.
@MainActor
final class WheelZoom {
    var inside = false
    private var token: Any?

    func install(_ zoom: @escaping (CGFloat, Bool) -> Void) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.inside else { return event }
            let option = event.modifierFlags.contains(.option), command = event.modifierFlags.contains(.command)
            guard option || command else { return event }
            let dy = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
            zoom(event.hasPreciseScrollingDeltas ? dy : dy * 8, option)
            return nil
        }
    }

    func remove() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

private struct Keys: View {
    let rowHeight: CGFloat
    /// Names for the keys of a drum kit ("Kick", "Snare"), by pitch. Empty for a keyboard.
    var names: [Int: String] = [:]
    /// The key of a dragged note lights up in the tint.
    var highlight: Int? = nil
    var tint: Color = .accentColor
    let play: (UInt8) -> Void

    var body: some View {
        Canvas { ctx, size in
            for pitch in lowPitch...highPitch {
                let y = CGFloat(highPitch - pitch) * rowHeight
                let black = [1, 3, 6, 8, 10].contains(pitch % 12)
                let color = pitch == highlight ? tint : (black ? Color(white: 0.12) : Color(white: 0.82))
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: rowHeight)), with: .color(color))
                ctx.fill(Path(CGRect(x: 0, y: y + rowHeight - 0.5, width: size.width, height: 0.5)), with: .color(.black.opacity(0.4)))
                if let name = names[pitch], rowHeight >= 9 {
                    ctx.draw(Text(name).font(.system(size: min(9, rowHeight - 2), weight: .medium)).foregroundStyle(black ? .white : .black),
                             at: CGPoint(x: 4, y: y + rowHeight / 2), anchor: .leading)
                } else if pitch % 12 == 0 {
                    ctx.draw(Text("C\(pitch / 12 - 1)").font(.system(size: 9)).foregroundStyle(.black), at: CGPoint(x: size.width - 4, y: y + rowHeight / 2), anchor: .trailing)
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { play(UInt8(min(max(highPitch - Int($0.location.y / rowHeight), lowPitch), highPitch))) })
    }
}

private struct NoteView: View {
    @Environment(AppModel.self) private var model
    let clip: MIDIClip
    let index: Int
    let note: MIDINote
    let tint: Color
    let pxPerBeat: CGFloat
    let rowHeight: CGFloat
    /// The grid step in ticks, and whether notes snap to it.
    let step: Int64
    let snap: Bool
    /// Command held when a drag began: that drag snaps when the grid is off, and runs free when it is on.
    @State private var invert = false
    @State private var edgeDragging = false
    /// The snap step of the current drag; 1 means free.
    private var grid: Int64 { snap != invert ? step : 1 }
    let rememberLength: (Int64) -> Void
    /// Reports the pitch under a drag, `nil` when it ends; the roll lights the row and the key.
    let held: (Int?) -> Void
    @State private var move: CGSize = .zero
    /// What a drag on the note does. Decided from the modifier keys when the drag begins.
    private enum DragMode { case move, copy, velocity(targets: [MIDINote], start: [UInt8]) }
    @State private var dragMode: DragMode?
    /// Where the dragged note lands: the placeholder shows it, snapped when the grid is on.
    @State private var target: (tick: Int64, pitch: Int)?
    /// A drag of the left or right edge, in points, already snapped.
    @State private var startEdge: CGFloat = 0
    @State private var endEdge: CGFloat = 0

    private var selected: Bool { model.selectedNotes.contains(note) }
    private var copying: Bool { if case .copy? = dragMode { return true } else { return false } }
    private var pxPerTick: CGFloat { pxPerBeat / CGFloat(Tick.perQuarter) }
    private func px(_ ticks: Int64) -> CGFloat { CGFloat(ticks) * pxPerTick }
    /// The shortest note: a grid step, or a 1/128 when the grid is off.
    private var minLength: Int64 { max(grid, Tick.perQuarter / 32) }
    private func snap(_ tick: Int64) -> Int64 { grid > 1 ? (tick + grid / 2) / grid * grid : tick }

    var body: some View {
        let x = px(note.tick.rawValue) + startEdge
        let w = max(4, px(note.length.rawValue) - startEdge + endEdge)
        let y = CGFloat(highPitch - Int(note.pitch)) * rowHeight
        let dragging = target != nil
        // Copying: the original stays where it is, a copy follows the pointer.
        let shift = copying ? .zero : move
        ZStack(alignment: .topLeading) {
            if copying {
                RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.5))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.white.opacity(0.7), lineWidth: 1))
                    .frame(width: max(4, px(note.length.rawValue)), height: rowHeight - 1)
                    .offset(x: px(note.tick.rawValue) + move.width, y: y + move.height)
                    .allowsHitTesting(false)
            }
            if let target {
                // The placeholder: where the note lands when the drag ends.
                RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.3))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .frame(width: max(4, px(note.length.rawValue)), height: rowHeight - 1)
                    .offset(x: px(target.tick), y: CGFloat(highPitch - target.pitch) * rowHeight)
                    .allowsHitTesting(false)
            }
            // A muted note is hollow: an outline in the tint, dim inside.
            RoundedRectangle(cornerRadius: 2)
                .fill(note.muted ? tint.opacity(0.12) : tint.opacity(0.45 + 0.55 * Double(note.velocity) / 127))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(selected ? Color.white : (note.muted ? tint.opacity(0.7) : .black.opacity(0.5)), lineWidth: selected ? 1.5 : (note.muted ? 1 : 0.5)))
                .frame(width: w, height: rowHeight - 1)
                .opacity(dragging && !copying ? 0.6 : 1)
                .overlay(alignment: .leading) { edge { startEdge = px(newStart($0) - note.tick.rawValue) } end: { resize(start: $0) } }
                .overlay(alignment: .trailing) { edge { endEdge = px(newLength($0) - note.length.rawValue) } end: { resize(end: $0) } }
                .offset(x: x + shift.width, y: y + shift.height)
                // Global coordinates: the note moves under the pointer, so its own space would shift with it.
                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { g in
                        if dragMode == nil {
                            let flags = NSEvent.modifierFlags
                            invert = flags.contains(.command)
                            if flags.contains(.control) {
                                // Control: the note stays, the drag up or down changes the velocity.
                                let group = selected && model.selectedNotes.count > 1 ? clip.notes.filter { model.selectedNotes.contains($0) } : [note]
                                dragMode = .velocity(targets: group, start: group.map(\.velocity))
                            } else {
                                // Option: the original stays, a copy moves.
                                dragMode = flags.contains(.option) ? .copy : .move
                            }
                        }
                        if case .velocity(let targets, let start)? = dragMode {
                            let delta = Int((-g.translation.height / (rowHeight * 4) * 127).rounded())
                            applyVelocity(model, clip, targets: targets, start: start, delta: delta)
                            return
                        }
                        move = g.translation
                        let t = landing(g.translation)
                        if t.pitch != target?.pitch {
                            held(t.pitch)
                            // The drag has reached another key: play it, so the ear follows the hand.
                            if model.previewNotes, target != nil || t.pitch != Int(note.pitch) { model.auditionNote(UInt8(t.pitch), velocity: note.velocity) }
                        }
                        target = t
                    }
                    .onEnded { g in
                        defer { move = .zero; target = nil; dragMode = nil; invert = false; held(nil) }
                        guard let mode = dragMode, target != nil else { return }
                        let (tick, pitch) = landing(g.translation)
                        let group = selected && model.selectedNotes.count > 1
                        if case .copy = mode {
                            copyMarked(group ? nil : note, by: tick - note.tick.rawValue, pitch: pitch - Int(note.pitch))
                        } else if group {
                            moveMarked(by: tick - note.tick.rawValue, pitch: pitch - Int(note.pitch))
                        } else {
                            replace { $0.tick = Tick(tick); $0.pitch = UInt8(pitch) }
                        }
                    })
        }
        .onTapGesture {
            if model.drawMode { delete(); return }
            let extend = NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command)
            if extend { model.selectedNotes.formSymmetricDifference([note]) } else { model.selectedNotes = [note] }
            if model.previewNotes { model.auditionNote(note.pitch, velocity: note.velocity) }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !model.drawMode { delete() } })
        .contextMenu {
            Button("Delete", role: .destructive) { delete() }
            Menu("Velocity") { ForEach([32, 64, 96, 127], id: \.self) { v in Button("\(v)") { replace { $0.velocity = UInt8(v) } } } }
            Button(note.muted ? "Activate" : "Deactivate") { replace { $0.muted.toggle() } }
            Divider()
            Text("Drag: move · Option drag: copy · Control drag up/down: velocity · Command: the other grid · 0: deactivate").font(.caption)
        }
    }

    /// Where the note lands after a drag by `translation`: the start on the grid (or the exact tick with snap
    /// off), inside the clip; the pitch on its row.
    private func landing(_ translation: CGSize) -> (tick: Int64, pitch: Int) {
        let raw = note.tick.rawValue + ticks(translation.width)
        let tick = min(max(0, snap(raw)), max(0, clip.length.rawValue - grid))
        let pitch = min(max(lowPitch, Int(note.pitch) - Int((translation.height / rowHeight).rounded())), highPitch)
        return (tick, pitch)
    }

    /// Moves every marked note by the same time and pitch, like the dragged one. Notes stay inside the clip
    /// and the key range; the marking follows them.
    private func moveMarked(by dt: Int64, pitch dp: Int) {
        var moved: Set<MIDINote> = []
        let notes = clip.notes.map { n -> MIDINote in
            guard model.selectedNotes.contains(n) else { return n }
            var m = n
            m.tick = Tick(min(max(0, n.tick.rawValue + dt), max(0, clip.length.rawValue - 1)))
            m.length = Tick(max(1, min(n.length.rawValue, clip.length.rawValue - m.tick.rawValue)))
            m.pitch = UInt8(min(max(lowPitch, Int(n.pitch) + dp), highPitch))
            moved.insert(m)
            return m
        }
        model.setNotes(clip.id, notes)
        model.selectedNotes = moved
    }

    /// Option drag: copies the marked notes (or `one` note) by the same time and pitch. The copies are marked,
    /// the originals stay. A copy that would land on an existing note is skipped.
    private func copyMarked(_ one: MIDINote?, by dt: Int64, pitch dp: Int) {
        let sources = one.map { [$0] } ?? clip.notes.filter { model.selectedNotes.contains($0) }
        var copies: [MIDINote] = []
        for n in sources {
            var m = n
            m.tick = Tick(min(max(0, n.tick.rawValue + dt), max(0, clip.length.rawValue - 1)))
            m.length = Tick(max(1, min(n.length.rawValue, clip.length.rawValue - m.tick.rawValue)))
            m.pitch = UInt8(min(max(lowPitch, Int(n.pitch) + dp), highPitch))
            if !clip.notes.contains(m) { copies.append(m) }
        }
        guard !copies.isEmpty else { return }
        model.setNotes(clip.id, clip.notes + copies)
        model.selectedNotes = Set(copies)
    }

    /// A grip at one end of the note: drag it to shorten or lengthen the note. The grip moves with the edge,
    /// so the drag is measured in global coordinates; in its own space every move would count half.
    private func edge(_ changed: @escaping (CGFloat) -> Void, end: @escaping (CGFloat) -> Void) -> some View {
        Rectangle().fill(.clear).frame(width: 6).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    if !edgeDragging { edgeDragging = true; invert = NSEvent.modifierFlags.contains(.command) }
                    changed(g.translation.width)
                }
                .onEnded { g in
                    end(g.translation.width)
                    edgeDragging = false
                    invert = false
                })
            .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }

    private func ticks(_ points: CGFloat) -> Int64 { Int64(Double(points / pxPerBeat) * Double(Tick.perQuarter)) }

    /// The length after the end edge moved by `points`: the end lands on the grid, inside the clip.
    private func newLength(_ points: CGFloat) -> Int64 {
        let end = snap(note.tick.rawValue + note.length.rawValue + ticks(points))
        return min(max(minLength, end - note.tick.rawValue), max(minLength, clip.length.rawValue - note.tick.rawValue))
    }

    /// The start after the start edge moved by `points`: on the grid, the end stays.
    private func newStart(_ points: CGFloat) -> Int64 {
        let end = note.tick.rawValue + note.length.rawValue
        return max(0, min(snap(note.tick.rawValue + ticks(points)), end - minLength))
    }

    private func resize(end points: CGFloat) {
        endEdge = 0
        let length = newLength(points)
        rememberLength(length)
        replace { $0.length = Tick(length) }
    }

    /// The end stays; the start moves on the grid.
    private func resize(start points: CGFloat) {
        startEdge = 0
        let end = note.tick.rawValue + note.length.rawValue
        let start = newStart(points)
        guard end - start >= 1 else { return }
        rememberLength(end - start)
        replace { $0.tick = Tick(start); $0.length = Tick(end - start) }
    }

    private func replace(_ change: (inout MIDINote) -> Void) {
        var notes = clip.notes
        guard notes.indices.contains(index) else { return }
        let wasSelected = model.selectedNotes.contains(notes[index])
        change(&notes[index])
        model.setNotes(clip.id, notes)
        if wasSelected { model.selectedNotes = [notes[index]] }
    }

    private func delete() {
        var notes = clip.notes
        guard notes.indices.contains(index) else { return }
        model.selectedNotes.remove(notes[index])
        notes.remove(at: index)
        model.setNotes(clip.id, notes)
    }
}
