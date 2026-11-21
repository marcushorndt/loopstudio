import AppKit
import LoopStudioCore
import LoopStudioEngine
import SwiftUI

/// The Notes page of an audio clip, after Melodyne: every note the analysis found in the file is a blob at its
/// pitch, as long as it sounds and as thick as it is loud, also the notes of a chord. Drag a blob up or down to
/// change its pitch (in semitones; with Option free), sideways to move it in time, and its right end to make it
/// longer or shorter. A double click puts a note on the nearest semitone. Delete silences the marked note, or
/// brings it back. The page shows the file's own time line.
struct NoteEditor: View {
    @Environment(AppModel.self) private var model
    let clip: AudioClip
    let tint: Color

    /// A drag in progress: the note, what the drag does, and the change so far.
    @State private var drag: Drag?
    @FocusState private var focused: Bool

    struct Drag {
        var key: String
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
                        GeometryReader { geo in canvas(analysis, size: geo.size) }
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
        .onChange(of: clip.id) { model.selectedAudioNote = nil }
        .onDisappear { model.selectedAudioNote = nil }
    }

    private func message(_ text: String) -> some View {
        Text(text).foregroundStyle(Theme.dim).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Layout

    private struct Layout {
        let lo: Int, hi: Int
        let row: CGFloat
        let left: CGFloat
        let pps: CGFloat
        let height: CGFloat
        func y(_ pitch: Double) -> CGFloat { height - (CGFloat(pitch - Double(lo)) + 0.5) * row }
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
        let row = size.height / CGFloat(h - l + 1)
        let seconds = Double(model.project.asset(edit.source)?.frames ?? Int64(analysis.frames * analysis.hop)) / analysis.sampleRate
        return Layout(lo: l, hi: h, row: row, left: gutter, pps: (size.width - gutter - 4) / CGFloat(max(0.1, seconds)), height: size.height)
    }

    /// The note's change with the drag in progress on top.
    private func change(_ n: DetectedNote, _ edit: NoteEdit) -> NoteChange {
        var c = edit.change(n.key) ?? NoteChange(key: n.key)
        if let d = drag, d.key == n.key {
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
        let selected = model.selectedAudioNote
        let loudest = max(1e-6, analysis.notes.flatMap(\.level).max() ?? 1)
        return Canvas { ctx, size in
            // Rows: the black keys darker, a line under every C, its name in the gutter.
            for p in l.lo...l.hi {
                let y = l.y(Double(p))
                let rect = CGRect(x: l.left, y: y - l.row / 2, width: size.width - l.left, height: l.row)
                if [1, 3, 6, 8, 10].contains(((p % 12) + 12) % 12) { ctx.fill(Path(rect), with: .color(Theme.background.opacity(0.55))) }
                if p % 12 == 0 {
                    ctx.fill(Path(CGRect(x: l.left, y: y + l.row / 2 - 0.5, width: size.width - l.left, height: 0.5)), with: .color(Theme.line))
                }
                if p % 12 == 0 || l.row >= 11 {
                    ctx.draw(Text(BuiltInEffects.noteNames[safe: p] ?? "").font(.system(size: min(10, max(8, l.row - 1)))).foregroundStyle(Theme.dim),
                             at: CGPoint(x: l.left - 4, y: y), anchor: .trailing)
                }
            }
            for n in analysis.notes {
                let c = change(n, edit)
                let s = span(n, c, analysis, l)
                let isSelected = n.key == selected
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
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(analysis, edit, l))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onHover { inside in if !inside { NSCursor.arrow.set() } }
        .onContinuousHover { phase in
            guard drag == nil, case .active(let p) = phase else { return }
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

    private func dragGesture(_ analysis: NoteAnalysis, _ edit: NoteEdit, _ l: Layout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if drag == nil {
                    focused = true
                    guard let (key, stretching) = hit(v.startLocation, analysis, edit, l) else { model.selectedAudioNote = nil; return }
                    model.selectedAudioNote = key
                    drag = Drag(key: key, stretching: stretching)
                    (stretching ? NSCursor.resizeLeftRight : NSCursor.closedHand).set()
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
                defer { drag = nil; NSCursor.openHand.set() }
                guard let d = drag, let n = analysis.notes.first(where: { $0.key == d.key }) else { return }
                var c = edit.change(d.key) ?? NoteChange(key: d.key)
                if d.moved {
                    c.pitch += d.pitch
                    c.shift += d.shift
                    c.stretch *= d.stretch
                    if c.pitch == edit.change(d.key)?.pitch ?? 0, c.shift == edit.change(d.key)?.shift ?? 0,
                       c.stretch == edit.change(d.key)?.stretch ?? 1 { return }
                    model.changeNote(clip, c)
                } else if NSApp.currentEvent?.clickCount == 2 {
                    // A double click tunes the note: to the semitone nearest to where it sounds now.
                    c.pitch = (n.pitch + c.pitch).rounded() - n.pitch
                    if abs(c.pitch) < 0.005 { c.pitch = 0 }
                    model.changeNote(clip, c)
                }
            }
    }

    // MARK: Strip

    @ViewBuilder
    private func strip(_ analysis: NoteAnalysis) -> some View {
        let edit = model.noteEdit(clip)
        let note = model.selectedAudioNote.flatMap { k in analysis.notes.first { $0.key == k } }
        HStack(spacing: 10) {
            if let n = note {
                let c = edit.change(n.key) ?? NoteChange(key: n.key)
                let now = n.pitch + c.pitch
                let cents = Int(((now - now.rounded()) * 100).rounded())
                Text("\(BuiltInEffects.noteNames[safe: Int(now.rounded())] ?? "?")\(cents == 0 ? "" : String(format: " %+d ct", cents))")
                    .font(.system(size: 12, weight: .semibold)).frame(minWidth: 64, alignment: .leading)
                field("Pitch", "st", value: c.pitch) { v in var x = c; x.pitch = v; model.changeNote(clip, x) }
                field("Time", "ms", value: c.shift * 1000) { v in var x = c; x.shift = v / 1000; model.changeNote(clip, x) }
                field("Length", "%", value: c.stretch * 100) { v in var x = c; x.stretch = max(10, v) / 100; model.changeNote(clip, x) }
                field("Level", "dB", value: c.gainDb) { v in var x = c; x.gainDb = min(24, max(-60, v)); model.changeNote(clip, x) }
                Button(c.muted ? "Unmute" : "Mute") { model.toggleNoteMute(clip, key: n.key) }
                Button("Tune") {
                    var x = c
                    x.pitch = now.rounded() - n.pitch
                    if abs(x.pitch) < 0.005 { x.pitch = 0 }
                    model.changeNote(clip, x)
                }
                .help("Puts the note on the nearest semitone")
                Button("Reset") { model.changeNote(clip, NoteChange(key: n.key)) }.disabled(c.isIdentity)
            } else {
                Text("\(analysis.notes.count) notes. Click a note to edit it; drag it up, down or sideways.")
                    .foregroundStyle(Theme.dim)
            }
            Spacer(minLength: 8)
            if model.pendingNoteEdits[clip.id] != nil { ProgressView().controlSize(.mini) }
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

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
