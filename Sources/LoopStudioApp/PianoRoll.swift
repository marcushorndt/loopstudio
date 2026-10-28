import LoopStudioCore
import SwiftUI

/// The full MIDI range. The roll scrolls, and opens centred on the notes of the clip.
private let lowPitch = 0, highPitch = 127
private let keysWidth: CGFloat = 46
private let grid = Int64(Tick.perQuarter / 4) // a sixteenth note

/// A piano roll for one MIDI clip. At zoom 1 the clip fills the width of the panel.
/// Double-click an empty cell to add a note, click a note to select it, drag it to move it, drag an edge
/// to change its length, double-click it to delete it. The pen (B) draws with a click or a drag.
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

    private var beats: Double { max(1, Double(clip.length.rawValue) / Double(Tick.perQuarter)) }
    private var pxPerBeat: CGFloat { max(8, (visibleWidth - keysWidth - 2) / CGFloat(beats)) * CGFloat(zoom) }
    private var width: CGFloat { max(100, CGFloat(beats) * pxPerBeat) }
    private var height: CGFloat { CGFloat(highPitch - lowPitch + 1) * rowHeight }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text("\(clip.notes.count) notes").font(.caption).foregroundStyle(Theme.dim)
                Spacer()
                toolButton("pencil", on: model.drawMode, help: "Draw mode (B): click or drag to draw notes, click a note to delete it") {
                    model.drawMode.toggle()
                }
                toolButton(model.previewNotes ? "speaker.wave.2.fill" : "speaker.slash", on: model.previewNotes,
                           help: "Preview: play a note when it is created or moved") {
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
                    HStack(alignment: .top, spacing: 0) {
                        Keys(rowHeight: rowHeight) { if model.previewNotes { model.auditionNote($0) } }.frame(width: keysWidth, height: height)
                        ZStack(alignment: .topLeading) {
                            Canvas { ctx, size in drawGrid(&ctx, size) }
                                .frame(width: width, height: height)
                                .contentShape(Rectangle())
                                .gesture(model.drawMode ? penGesture : nil)
                                .onTapGesture { model.selectedNotes = [] }
                                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { if !model.drawMode { add(at: $0.location) } })
                            ForEach(Array(clip.notes.enumerated()), id: \.offset) { index, note in
                                NoteView(clip: clip, index: index, note: note, tint: tint, pxPerBeat: pxPerBeat, rowHeight: rowHeight) { lastLength = $0 }
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
                }
                .onScrollGeometryChange(for: CGFloat.self, of: \.containerSize.width) { _, w in visibleWidth = w }
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
                .onAppear {
                    let mid = clip.notes.isEmpty ? 60 : Int(clip.notes.map { Int($0.pitch) }.reduce(0, +)) / clip.notes.count
                    proxy.scrollTo("roll", anchor: UnitPoint(x: 0, y: 1 - Double(mid - lowPitch) / Double(highPitch - lowPitch)))
                }
            }
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: Theme.radius))
        }
    }

    private func toolButton(_ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 20)
                .foregroundStyle(on ? tint : Theme.dim)
                .background(on ? tint.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(on ? tint.opacity(0.5) : Theme.line, lineWidth: 1))
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
        let steps = Int(beats * 4) + 1
        for i in 0...steps {
            let x = CGFloat(i) * pxPerBeat / 4
            let strong = i % 16 == 0, beat = i % 4 == 0
            ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                     with: .color(.white.opacity(strong ? 0.28 : (beat ? 0.12 : 0.04))))
        }
        // Past the end of the clip nothing plays.
        let end = CGFloat(Double(clip.length.rawValue) / Double(Tick.perQuarter)) * pxPerBeat
        ctx.fill(Path(CGRect(x: end, y: 0, width: max(0, size.width - end), height: size.height)), with: .color(.black.opacity(0.35)))
    }

    /// The grid cell at a point: its start tick and its pitch. `nil` outside the clip.
    private func cell(_ point: CGPoint) -> (tick: Int64, pitch: Int)? {
        let tick = Int64(Double(point.x / pxPerBeat) * Double(Tick.perQuarter)) / grid * grid
        let pitch = highPitch - Int(point.y / rowHeight)
        guard tick >= 0, tick < clip.length.rawValue, (lowPitch...highPitch).contains(pitch) else { return nil }
        return (tick, pitch)
    }

    private func add(at point: CGPoint) {
        guard let (tick, pitch) = cell(point) else { return }
        let note = MIDINote(tick: Tick(tick), length: Tick(min(lastLength, clip.length.rawValue - tick)), pitch: UInt8(pitch))
        model.setNotes(clip.id, clip.notes + [note])
        model.selectedNotes = [note]
        if model.previewNotes { model.auditionNote(UInt8(pitch)) }
    }

    /// The pen: every grid cell the drag crosses gets a sixteenth note at the pitch under the pointer.
    private var penGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                guard let (tick, pitch) = cell(g.location) else { return }
                let taken = (clip.notes + drawn).contains { $0.pitch == UInt8(pitch) && $0.tick.rawValue <= tick && tick < $0.tick.rawValue + $0.length.rawValue }
                guard !taken else { return }
                drawn.append(MIDINote(tick: Tick(tick), length: Tick(min(grid, clip.length.rawValue - tick)), pitch: UInt8(pitch)))
                if model.previewNotes { model.auditionNote(UInt8(pitch)) }
            }
            .onEnded { _ in
                guard !drawn.isEmpty else { return }
                model.setNotes(clip.id, clip.notes + drawn)
                drawn = []
            }
    }
}

/// Catches a scroll with Option or Command held over the piano roll and turns it into zoom.
/// A plain scroll still scrolls the roll.
@MainActor
private final class WheelZoom {
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
    let play: (UInt8) -> Void

    var body: some View {
        Canvas { ctx, size in
            for pitch in lowPitch...highPitch {
                let y = CGFloat(highPitch - pitch) * rowHeight
                let black = [1, 3, 6, 8, 10].contains(pitch % 12)
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: rowHeight)), with: .color(black ? Color(white: 0.12) : Color(white: 0.82)))
                ctx.fill(Path(CGRect(x: 0, y: y + rowHeight - 0.5, width: size.width, height: 0.5)), with: .color(.black.opacity(0.4)))
                if pitch % 12 == 0 {
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
    let rememberLength: (Int64) -> Void
    @State private var move: CGSize = .zero
    /// A drag of the left or right edge, in points.
    @State private var startEdge: CGFloat = 0
    @State private var endEdge: CGFloat = 0

    private var selected: Bool { model.selectedNotes.contains(note) }

    var body: some View {
        let x = CGFloat(Double(note.tick.rawValue) / Double(Tick.perQuarter)) * pxPerBeat + startEdge
        let w = max(4, CGFloat(Double(note.length.rawValue) / Double(Tick.perQuarter)) * pxPerBeat - startEdge + endEdge)
        let y = CGFloat(highPitch - Int(note.pitch)) * rowHeight
        RoundedRectangle(cornerRadius: 2)
            .fill(tint.opacity(0.45 + 0.55 * Double(note.velocity) / 127))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(selected ? Color.white : .black.opacity(0.5), lineWidth: selected ? 1.5 : 0.5))
            .frame(width: w, height: rowHeight - 1)
            .overlay(alignment: .leading) { edge { startEdge = $0 } end: { resize(start: $0) } }
            .overlay(alignment: .trailing) { edge { endEdge = $0 } end: { resize(end: $0) } }
            .offset(x: x + move.width, y: y + move.height)
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { move = $0.translation }
                .onEnded { g in
                    move = .zero
                    let dt = Int64(Double(g.translation.width / pxPerBeat) * Double(Tick.perQuarter))
                    let tick = min(max(0, (note.tick.rawValue + dt + grid / 2) / grid * grid), max(0, clip.length.rawValue - grid))
                    let pitch = min(max(lowPitch, Int(note.pitch) - Int((g.translation.height / rowHeight).rounded())), highPitch)
                    replace { $0.tick = Tick(tick); $0.pitch = UInt8(pitch) }
                    if model.previewNotes { model.auditionNote(UInt8(pitch)) }
                })
            .onTapGesture {
                if model.drawMode { delete(); return }
                let extend = NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command)
                if extend { model.selectedNotes.formSymmetricDifference([note]) } else { model.selectedNotes = [note] }
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded { if !model.drawMode { delete() } })
            .contextMenu {
                Button("Delete", role: .destructive) { delete() }
                Menu("Velocity") { ForEach([32, 64, 96, 127], id: \.self) { v in Button("\(v)") { replace { $0.velocity = UInt8(v) } } } }
            }
    }

    /// A grip at one end of the note: drag it to shorten or lengthen the note.
    private func edge(_ changed: @escaping (CGFloat) -> Void, end: @escaping (CGFloat) -> Void) -> some View {
        Rectangle().fill(.clear).frame(width: 6).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { changed($0.translation.width) }
                .onEnded { end($0.translation.width) })
            .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }

    private func ticks(_ points: CGFloat) -> Int64 { Int64(Double(points / pxPerBeat) * Double(Tick.perQuarter)) }

    private func resize(end points: CGFloat) {
        endEdge = 0
        let length = max(grid, (note.length.rawValue + ticks(points) + grid / 2) / grid * grid)
        rememberLength(length)
        replace { $0.length = Tick(min(length, clip.length.rawValue - $0.tick.rawValue)) }
    }

    /// The end stays; the start moves on the grid.
    private func resize(start points: CGFloat) {
        startEdge = 0
        let end = note.tick.rawValue + note.length.rawValue
        let start = max(0, min((note.tick.rawValue + ticks(points) + grid / 2) / grid * grid, end - grid))
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
