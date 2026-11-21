import AppKit
import LoopStudioCore
import LoopStudioEngine
import SwiftUI

/// The Notes page of an audio clip, after Melodyne: every note the analysis found in the file is a blob at its
/// pitch, as long as it sounds and as thick as it is loud, also the notes of a chord. Drag a blob up or down to
/// change its pitch (in semitones; with Option free), sideways to move it in time, and its right end to make it
/// longer or shorter. A double click puts a note on the nearest semitone. A drag over empty space marks the notes
/// in its box (with Shift it adds them), Shift-click marks one more; a drag of a marked note moves them all.
/// Delete silences the marked notes, or brings them back. The arrow keys move the marked notes: up and down a
/// semitone (Shift: an octave), left and right a grid step (Command: the other step, Shift: shorter, longer). The page shows the file's own time line.
///
/// Zoom as in the piano roll: a pinch or Command and scroll zooms in time around the pointer, Option and scroll
/// (or a pinch with Option) zooms the rows. A plain scroll moves the view once it is zoomed. The buttons in the
/// strip zoom in, out and back to the whole file.
struct NoteEditor: View {
    @Environment(AppModel.self) private var model
    let clip: AudioClip
    let tint: Color

    /// A drag in progress: the note, what the drag does, and the change so far.
    @State private var drag: Drag?
    @FocusState private var focused: Bool
    /// The view: 1 shows the whole file and every note row; more zooms in. `startSeconds` is the time at the
    /// left edge, `pitchOffset` the rows hidden below the view.
    @State private var zoom = 1.0
    @State private var rowZoom = 1.0
    @State private var startSeconds = 0.0
    @State private var pitchOffset = 0.0
    @State private var pinchStart: (zoom: Double, rows: Double)?
    /// A box drag over empty space: its corners, and the notes marked before it (Shift adds to them).
    @State private var marquee: (from: CGPoint, to: CGPoint, base: Set<String>)?
    @State private var wheel = NoteWheel()
    /// The last layout and pointer, for the wheel and the pinch. A class: writing it does not redraw.
    @State private var geometry = NoteGeometry()

    struct Drag {
        var key: String
        /// The notes the drag moves: the marked ones when the grabbed note is among them.
        var keys: Set<String> = []
        var stretching: Bool
        /// The direction a move took after the first pixels: a move changes pitch or time, not both.
        var vertical: Bool?
        var pitch = 0.0
        var shift = 0.0
        var stretch = 1.0
        var moved: Bool { vertical != nil || stretch != 1 }
    }

    private let gutter: CGFloat = 34

    var body: some View {
        let source = model.noteSource(clip)
        Group {
            if let analysis = model.noteAnalyses[source] {
                VStack(spacing: 0) {
                    strip(analysis)
                    Rectangle().fill(Theme.line).frame(height: 1)
                    if analysis.notes.isEmpty {
                        message("No notes found. The file holds no clear pitches (drums, noise or speech).")
                    } else {
                        GeometryReader { geo in
                            ZStack(alignment: .topLeading) {
                                canvas(analysis, size: geo.size)
                                playhead(analysis, size: geo.size)
                            }
                            .clipped()
                        }
                    }
                }
            } else if model.notesInProgress.contains(source) {
                VStack(spacing: 8) { ProgressView().controlSize(.small); Text("Finding the notes…").foregroundStyle(Theme.dim) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                message("The file is not loaded yet.")
            }
        }
        .onAppear { model.analyzeNotes(clip) }
        .onChange(of: source) { model.analyzeNotes(clip) }
        .onChange(of: clip.id) {
            model.markAudioNotes([], primary: nil)
            zoom = 1; rowZoom = 1; startSeconds = 0; pitchOffset = 0
        }
        .onHover { wheel.inside = $0 }
        .onAppear { wheel.install(scrolled) }
        .onDisappear { model.markAudioNotes([], primary: nil); wheel.remove() }
    }

    private func message(_ text: String) -> some View {
        Text(text).foregroundStyle(Theme.dim).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Layout

    /// `lo...hi`: the rows in view. `base`: the pitch at the bottom edge. `left`: where second 0 lies.
    struct Layout {
        let lo: Int, hi: Int
        let base: Double
        let row: CGFloat
        let left: CGFloat
        let pps: CGFloat
        let height: CGFloat
        /// The whole file and every note row at zoom 1: for the zoom and the scroll limits.
        var seconds = 1.0, fitPPS: CGFloat = 1, fitRow: CGFloat = 1, allLo = 0, rows = 1
        func y(_ pitch: Double) -> CGFloat { height - (CGFloat(pitch - base) + 0.5) * row }
        func x(_ seconds: Double) -> CGFloat { left + CGFloat(seconds) * pps }
    }

    private func layout(_ analysis: NoteAnalysis, _ edit: NoteEdit, size: CGSize) -> Layout {
        var lo = 127.0, hi = 0.0
        for n in analysis.notes {
            let p = n.pitch + (edit.change(n.key)?.pitch ?? 0)
            lo = min(lo, p); hi = max(hi, p)
        }
        var l = Int(lo.rounded(.down)) - 2, h = Int(hi.rounded(.up)) + 2
        // At least two octaves, so a few notes do not fill the page with fat rows.
        if h - l < 24 { let pad = (24 - (h - l)) / 2; l -= pad; h = l + 24 }
        let rows = h - l + 1
        let fitRow = size.height / CGFloat(rows)
        let seconds = max(0.1, Double(model.project.asset(edit.source)?.frames ?? Int64(analysis.frames * analysis.hop)) / analysis.sampleRate)
        let fitPPS = (size.width - gutter - 4) / CGFloat(seconds)
        let pps = fitPPS * CGFloat(zoom), row = fitRow * CGFloat(rowZoom)
        let start = min(max(0, startSeconds), seconds - seconds / zoom)
        let shown = Double(rows) / rowZoom
        let base = Double(l) + min(max(0, pitchOffset), Double(rows) - shown)
        var layout = Layout(lo: max(l, Int(base.rounded(.down)) - 1), hi: min(h, Int((base + shown).rounded(.up)) + 1), base: base,
                            row: row, left: gutter - CGFloat(start) * pps, pps: pps, height: size.height)
        layout.seconds = seconds; layout.fitPPS = fitPPS; layout.fitRow = fitRow; layout.allLo = l; layout.rows = rows
        geometry.layout = layout
        geometry.width = size.width
        return layout
    }

    /// The playhead: where the clip plays in the file now, through its start marker, loop and warp.
    @ViewBuilder
    private func playhead(_ analysis: NoteAnalysis, size: CGSize) -> some View {
        if let asset = model.project.asset(clip.asset), asset.sampleRate > 0 {
            let l = layout(analysis, model.noteEdit(clip), size: size)
            let session = model.isSessionClip(clip.id)
            let fileTicks = model.fileTicks(clip, asset)
            let warp = model.waveGeometry(clip, asset)
            ClipPlayhead(clip: clip.id, period: WarpEditor.noPeriod) { elapsed in
                let beat = clip.playTick(after: elapsed, session: session, fileTicks: fileTicks).quarters
                let x = l.x(warp.source(atBeat: beat) / asset.sampleRate)
                return x < gutter ? -10 : x // not over the note names
            }
        }
    }

    // MARK: Zoom

    /// The deepest time zoom: about 50 ms across the view.
    private func maxZoom(_ l: Layout) -> Double { max(1, min(400, l.seconds / 0.05)) }

    /// Zooms in time to `target`; the time under `x` stays under it.
    private func zoomTime(to target: Double, at x: CGFloat) {
        guard let l = geometry.layout else { return }
        let z = min(maxZoom(l), max(1, target))
        let at = Double((x - l.left) / l.pps)
        zoom = z
        startSeconds = min(max(0, at - Double((x - gutter) / (l.fitPPS * CGFloat(z)))), l.seconds - l.seconds / z)
    }

    /// Zooms the rows to `target`; the pitch under `y` stays under it.
    private func zoomRows(to target: Double, at y: CGFloat) {
        guard let l = geometry.layout else { return }
        let z = min(8, max(1, target))
        let at = l.base + Double((l.height - y) / l.row) - 0.5
        rowZoom = z
        let base = at - Double((l.height - y) / (l.fitRow * CGFloat(z))) + 0.5
        pitchOffset = min(max(0, base - Double(l.allLo)), Double(l.rows) - Double(l.rows) / z)
    }

    /// A scroll over the page: Command zooms in time, Option zooms the rows, a plain scroll moves a zoomed view.
    /// Returns false when the page has nothing to do with it.
    private func scrolled(_ dx: CGFloat, _ dy: CGFloat, _ command: Bool, _ option: Bool) -> Bool {
        guard let l = geometry.layout else { return false }
        let p = geometry.pointer
        if command { zoomTime(to: zoom * pow(1.01, Double(dy != 0 ? dy : dx)), at: p.x); return true }
        if option { zoomRows(to: rowZoom * pow(1.01, Double(dy != 0 ? dy : dx)), at: p.y); return true }
        guard zoom > 1 || rowZoom > 1 else { return false }
        if zoom > 1 { startSeconds = min(max(0, startSeconds - Double(dx / l.pps)), l.seconds - l.seconds / zoom) }
        if rowZoom > 1 {
            pitchOffset = min(max(0, pitchOffset + Double(dy / l.row)), Double(l.rows) - Double(l.rows) / rowZoom)
        }
        return true
    }

    private var zoomButtons: some View {
        HStack(spacing: 2) {
            Button { zoomTime(to: zoom / 1.5, at: geometry.centre) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out. Command and scroll, or a pinch, zoom in time; Option and scroll zooms the rows.")
            Button { zoomTime(to: zoom * 1.5, at: geometry.centre) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in. Command and scroll, or a pinch, zoom in time; Option and scroll zooms the rows.")
            Button { zoom = 1; rowZoom = 1; startSeconds = 0; pitchOffset = 0 } label: { Image(systemName: "arrow.left.and.right.square") }
                .help("Show the whole file and every note")
                .disabled(zoom == 1 && rowZoom == 1)
        }
        .buttonStyle(.borderless)
    }

    /// The note's change with the drag in progress on top.
    private func change(_ n: DetectedNote, _ edit: NoteEdit) -> NoteChange {
        var c = edit.change(n.key) ?? NoteChange(key: n.key)
        if let d = drag, d.keys.contains(n.key) {
            c.pitch += d.pitch
            c.shift += d.shift
            c.stretch *= d.stretch
        }
        return c
    }

    /// Where a note's blob lies: its time span and its centre line.
    private func span(_ n: DetectedNote, _ c: NoteChange, _ analysis: NoteAnalysis, _ l: Layout) -> (x0: CGFloat, x1: CGFloat, y: CGFloat) {
        let start = analysis.seconds(frame: Double(n.startFrame)) + c.shift
        let length = Double(n.frames) * Double(analysis.hop) / analysis.sampleRate * c.stretch
        return (l.x(start), l.x(start + length), l.y(n.pitch + c.pitch))
    }

    // MARK: Drawing

    private func canvas(_ analysis: NoteAnalysis, size: CGSize) -> some View {
        let edit = model.noteEdit(clip)
        let l = layout(analysis, edit, size: size)
        let selected = model.selectedAudioNotes
        let loudest = max(1e-6, analysis.notes.flatMap(\.level).max() ?? 1)
        return Canvas { ctx, size in
            // Rows: the black keys darker, a line under every C, its name in the gutter.
            for p in l.lo...l.hi {
                let y = l.y(Double(p))
                let rect = CGRect(x: gutter, y: y - l.row / 2, width: size.width - gutter, height: l.row)
                if [1, 3, 6, 8, 10].contains(((p % 12) + 12) % 12) { ctx.fill(Path(rect), with: .color(Theme.background.opacity(0.55))) }
                if p % 12 == 0 {
                    ctx.fill(Path(CGRect(x: gutter, y: y + l.row / 2 - 0.5, width: size.width - gutter, height: 0.5)), with: .color(Theme.line))
                }
                if p % 12 == 0 || l.row >= 11 {
                    ctx.draw(Text(BuiltInEffects.noteNames[safe: p] ?? "").font(.system(size: min(10, max(8, l.row - 1)))).foregroundStyle(Theme.dim),
                             at: CGPoint(x: gutter - 4, y: y), anchor: .trailing)
                }
            }
            // The notes stay right of the gutter when the view is moved.
            var ctx = ctx
            ctx.clip(to: Path(CGRect(x: gutter, y: 0, width: size.width - gutter, height: size.height)))
            for n in analysis.notes {
                let c = change(n, edit)
                let s = span(n, c, analysis, l)
                let isSelected = selected.contains(n.key)
                // The blob: its centre follows the pitch frame by frame, its thickness the level.
                var top: [CGPoint] = [], bottom: [CGPoint] = []
                let step = max(1, Int(Double(n.frames) / Double(max(1, s.x1 - s.x0)) * 2))
                for i in stride(from: 0, to: n.frames, by: step) {
                    let x = s.x0 + (s.x1 - s.x0) * CGFloat(i) / CGFloat(max(1, n.frames - 1))
                    let midi = 69 + 12 * log2(Double(max(1, n.f0[i])) / 440) + c.pitch
                    let thick = l.row * (0.2 + 0.8 * CGFloat(sqrt(Double(n.level[i]) / Double(loudest))))
                    let y = l.y(midi)
                    top.append(CGPoint(x: x, y: y - thick / 2)); bottom.append(CGPoint(x: x, y: y + thick / 2))
                }
                var blob = Path()
                blob.addLines(top + bottom.reversed())
                blob.closeSubpath()
                if c.muted {
                    ctx.stroke(blob, with: .color(Theme.dim), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                } else {
                    let changed = !c.isIdentity
                    ctx.fill(blob, with: .color(tint.opacity(changed ? 1 : 0.75)))
                    if isSelected { ctx.stroke(blob, with: .color(Theme.text), lineWidth: 1.5) }
                }
                // Where a moved note was: a thin line at its old pitch and time.
                if c.pitch != 0 || c.shift != 0 || c.stretch != 1 {
                    let old = span(n, NoteChange(key: n.key), analysis, l)
                    ctx.stroke(Path { $0.move(to: CGPoint(x: old.x0, y: old.y)); $0.addLine(to: CGPoint(x: old.x1, y: old.y)) },
                               with: .color(Theme.dim.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
            }
            if let m = marquee {
                let box = CGRect(x: min(m.from.x, m.to.x), y: min(m.from.y, m.to.y), width: abs(m.to.x - m.from.x), height: abs(m.to.y - m.from.y))
                ctx.fill(Path(box), with: .color(Theme.text.opacity(0.08)))
                ctx.stroke(Path(box), with: .color(Theme.text.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(analysis, edit, l))
        // A pinch zooms in time around the fingers; with Option held it zooms the rows.
        .simultaneousGesture(MagnifyGesture()
            .onChanged { g in
                if pinchStart == nil { pinchStart = (zoom, rowZoom) }
                guard let start = pinchStart else { return }
                if NSEvent.modifierFlags.contains(.option) { zoomRows(to: start.rows * g.magnification, at: g.startLocation.y) }
                else { zoomTime(to: start.zoom * g.magnification, at: g.startLocation.x) }
            }
            .onEnded { _ in pinchStart = nil })
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onHover { inside in if !inside { NSCursor.arrow.set() } }
        .onContinuousHover { phase in
            guard case .active(let p) = phase else { return }
            geometry.pointer = p
            guard drag == nil else { return }
            switch hit(p, analysis, edit, l) {
            case let (_, stretch)? where stretch: NSCursor.resizeLeftRight.set()
            case _?: NSCursor.openHand.set()
            case nil: NSCursor.arrow.set()
            }
        }
    }

    /// The note under a point, and whether the point is on its right end (a stretch).
    private func hit(_ p: CGPoint, _ analysis: NoteAnalysis, _ edit: NoteEdit, _ l: Layout) -> (String, Bool)? {
        var best: (key: String, stretch: Bool, distance: CGFloat)?
        for n in analysis.notes {
            let s = span(n, change(n, edit), analysis, l)
            guard p.x >= s.x0 - 3, p.x <= s.x1 + 3 else { continue }
            let d = abs(p.y - s.y)
            guard d <= max(l.row * 0.8, 6) else { continue }
            if best == nil || d < best!.distance { best = (n.key, s.x1 - s.x0 > 14 && p.x >= s.x1 - 6, d) }
        }
        return best.map { ($0.key, $0.stretch) }
    }

    // MARK: Editing

    /// The notes whose blob touches a box.
    private func notes(in box: CGRect, _ analysis: NoteAnalysis, _ edit: NoteEdit, _ l: Layout) -> Set<String> {
        Set(analysis.notes.filter { n in
            let s = span(n, change(n, edit), analysis, l)
            return CGRect(x: s.x0, y: s.y - l.row / 2, width: max(1, s.x1 - s.x0), height: l.row).intersects(box)
        }.map(\.key))
    }

    private func dragGesture(_ analysis: NoteAnalysis, _ edit: NoteEdit, _ l: Layout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let shift = NSEvent.modifierFlags.contains(.shift)
                if drag == nil, marquee == nil {
                    focused = true
                    guard let (key, stretching) = hit(v.startLocation, analysis, edit, l) else {
                        // Empty space: a box marks the notes it touches.
                        marquee = (v.startLocation, v.location, shift ? model.selectedAudioNotes : [])
                        if !shift { model.markAudioNotes([], primary: nil) }
                        return
                    }
                    var marked = model.selectedAudioNotes
                    if shift {
                        // Shift-click adds a note to the marked ones, or takes it out.
                        if marked.contains(key) { marked.remove(key) } else { marked.insert(key) }
                        model.markAudioNotes(marked, primary: key)
                        guard marked.contains(key) else { return }
                    } else if !marked.contains(key) {
                        marked = [key]
                        model.markAudioNotes(marked, primary: key)
                    } else {
                        model.markAudioNotes(marked, primary: key)
                    }
                    drag = Drag(key: key, keys: marked, stretching: stretching)
                    (stretching ? NSCursor.resizeLeftRight : NSCursor.closedHand).set()
                }
                if let m = marquee {
                    marquee = (m.from, v.location, m.base)
                    let box = CGRect(x: min(m.from.x, v.location.x), y: min(m.from.y, v.location.y),
                                     width: abs(v.location.x - m.from.x), height: abs(v.location.y - m.from.y))
                    let inside = box.width < 2 && box.height < 2 ? [] : notes(in: box, analysis, edit, l)
                    model.markAudioNotes(m.base.union(inside), primary: nil)
                    return
                }
                guard var d = drag else { return }
                let dx = v.translation.width, dy = v.translation.height
                if d.stretching {
                    guard let n = analysis.notes.first(where: { $0.key == d.key }) else { return }
                    let base = Double(n.frames) * Double(analysis.hop) / analysis.sampleRate * (edit.change(n.key)?.stretch ?? 1)
                    d.stretch = max(0.1, base + Double(dx / l.pps)) / base
                } else {
                    if d.vertical == nil, hypot(dx, dy) > 4 { d.vertical = abs(dy) > abs(dx) }
                    if d.vertical == true {
                        let raw = Double(-dy / l.row)
                        d.pitch = NSEvent.modifierFlags.contains(.option) ? (raw * 100).rounded() / 100 : raw.rounded()
                    } else if d.vertical == false {
                        d.shift = Double(dx / l.pps)
                    }
                }
                drag = d
            }
            .onEnded { _ in
                if marquee != nil { marquee = nil; return }
                defer { drag = nil; NSCursor.openHand.set() }
                guard let d = drag else { return }
                if d.moved {
                    // Every marked note takes the same change: up or down, sideways, longer or shorter.
                    let changes: [NoteChange] = d.keys.sorted().compactMap { key in
                        var c = edit.change(key) ?? NoteChange(key: key)
                        let old = c
                        c.pitch += d.pitch
                        c.shift += d.shift
                        c.stretch *= d.stretch
                        return c == old ? nil : c
                    }
                    model.changeNotes(clip, changes)
                } else if NSApp.currentEvent?.clickCount == 2, let n = analysis.notes.first(where: { $0.key == d.key }) {
                    // A double click tunes the note: to the semitone nearest to where it sounds now.
                    var c = edit.change(d.key) ?? NoteChange(key: d.key)
                    c.pitch = (n.pitch + c.pitch).rounded() - n.pitch
                    if abs(c.pitch) < 0.005 { c.pitch = 0 }
                    model.changeNote(clip, c)
                    model.markAudioNotes([d.key], primary: d.key)
                }
            }
    }

    // MARK: Strip

    @ViewBuilder
    private func strip(_ analysis: NoteAnalysis) -> some View {
        let edit = model.noteEdit(clip)
        let note = model.selectedAudioNote.flatMap { k in analysis.notes.first { $0.key == k } }
        let marked = model.selectedAudioNotes
        HStack(spacing: 10) {
            if marked.count > 1 {
                let all = marked.sorted()
                let muted = all.allSatisfy { edit.change($0)?.muted ?? false }
                Text("\(marked.count) notes marked").font(.system(size: 12, weight: .semibold))
                Button(muted ? "Unmute" : "Mute") { model.toggleNoteMute(clip, keys: marked) }
                Button("Tune") {
                    model.changeNotes(clip, all.compactMap { key in
                        guard let n = analysis.notes.first(where: { $0.key == key }) else { return nil }
                        var c = edit.change(key) ?? NoteChange(key: key)
                        let to = (n.pitch + c.pitch).rounded() - n.pitch
                        c.pitch = abs(to) < 0.005 ? 0 : to
                        return c
                    })
                }
                .help("Puts the marked notes on the nearest semitone")
                Button("Reset") { model.changeNotes(clip, all.map { NoteChange(key: $0) }) }
                    .disabled(all.allSatisfy { edit.change($0)?.isIdentity ?? true })
            } else if let n = note {
                let c = edit.change(n.key) ?? NoteChange(key: n.key)
                let now = n.pitch + c.pitch
                let cents = Int(((now - now.rounded()) * 100).rounded())
                Text("\(BuiltInEffects.noteNames[safe: Int(now.rounded())] ?? "?")\(cents == 0 ? "" : String(format: " %+d ct", cents))")
                    .font(.system(size: 12, weight: .semibold)).frame(minWidth: 64, alignment: .leading)
                field("Pitch", "st", value: c.pitch) { v in var x = c; x.pitch = v; model.changeNote(clip, x) }
                field("Time", "ms", value: c.shift * 1000) { v in var x = c; x.shift = v / 1000; model.changeNote(clip, x) }
                field("Length", "%", value: c.stretch * 100) { v in var x = c; x.stretch = max(10, v) / 100; model.changeNote(clip, x) }
                field("Level", "dB", value: c.gainDb) { v in var x = c; x.gainDb = min(24, max(-60, v)); model.changeNote(clip, x) }
                Button(c.muted ? "Unmute" : "Mute") { model.toggleNoteMute(clip, keys: [n.key]) }
                Button("Tune") {
                    var x = c
                    x.pitch = now.rounded() - n.pitch
                    if abs(x.pitch) < 0.005 { x.pitch = 0 }
                    model.changeNote(clip, x)
                }
                .help("Puts the note on the nearest semitone")
                Button("Reset") { model.changeNote(clip, NoteChange(key: n.key)) }.disabled(c.isIdentity)
            } else {
                Text("\(analysis.notes.count) notes. Click a note to edit it; drag it up, down or sideways. Drag a box to mark several.")
                    .foregroundStyle(Theme.dim)
            }
            Spacer(minLength: 8)
            if model.pendingNoteEdits[clip.id] != nil { ProgressView().controlSize(.mini) }
            zoomButtons
            Toggle("Keep Formants", isOn: Binding(get: { edit.keepFormants }, set: { on in
                var e = edit
                e.keepFormants = on
                model.applyNoteEdit(clip.id, e)
            }))
            .toggleStyle(.checkbox)
            .help("A moved note keeps the tone colour of its old pitch, so a voice does not sound like a chipmunk")
            Button("Tune All") {
                var e = edit
                for n in analysis.notes {
                    var c = e.change(n.key) ?? NoteChange(key: n.key)
                    let to = (n.pitch + c.pitch).rounded() - n.pitch
                    c.pitch = abs(to) < 0.005 ? 0 : to
                    e = e.with(c)
                }
                model.applyNoteEdit(clip.id, e)
            }
            .help("Puts every note on the nearest semitone")
            Button("Reset All") {
                var e = edit
                e.changes = []
                model.applyNoteEdit(clip.id, e)
            }
            .disabled(edit.changes.isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 30)
    }

    /// A number field that applies its value on Return or when it loses focus.
    private func field(_ label: String, _ unit: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(Theme.dim)
            TextField("", value: Binding(get: { (value * 100).rounded() / 100 }, set: { v in if abs(v - value) > 0.0001 { set(v) } }),
                      format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder).frame(width: 52).multilineTextAlignment(.trailing)
            Text(unit).foregroundStyle(Theme.dim)
        }
    }
}

/// The last layout of the Notes page and the pointer over it.
@MainActor
final class NoteGeometry {
    var layout: NoteEditor.Layout?
    var pointer = CGPoint.zero
    /// The middle of the note area, where the buttons zoom.
    var width: CGFloat = 0
    var centre: CGFloat { 34 + (width - 34) / 2 }
}

/// Every scroll over the Notes page goes to it: a zoom with Command or Option, a move without.
@MainActor
final class NoteWheel {
    var inside = false
    private var token: Any?

    func install(_ handle: @escaping (CGFloat, CGFloat, Bool, Bool) -> Bool) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.inside else { return event }
            let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
            let used = handle(event.scrollingDeltaX * k, event.scrollingDeltaY * k,
                              event.modifierFlags.contains(.command), event.modifierFlags.contains(.option))
            return used ? nil : event
        }
    }

    func remove() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
