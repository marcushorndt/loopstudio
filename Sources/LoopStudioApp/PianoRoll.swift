import LoopStudioCore
import SwiftUI

private let lowPitch = 24, highPitch = 96
private let rowHeight: CGFloat = 13
private let keysWidth: CGFloat = 46
private let grid = Int64(Tick.perQuarter / 4) // a sixteenth note

/// A piano roll for one MIDI clip. Click an empty cell to add a note, drag a note to move it,
/// drag its right edge to change its length, double-click or right-click to delete.
struct PianoRoll: View {
    @Environment(AppModel.self) private var model
    let clip: MIDIClip
    let tint: Color
    @State private var pxPerBeat: CGFloat = 56
    @State private var lastLength: Int64 = Int64(Tick.perQuarter / 2)

    private var width: CGFloat { max(200, CGFloat(Double(clip.length.rawValue) / Double(Tick.perQuarter)) * pxPerBeat) }
    private var height: CGFloat { CGFloat(highPitch - lowPitch + 1) * rowHeight }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("\(clip.notes.count) notes").font(.caption).foregroundStyle(Theme.dim)
                Spacer()
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(Theme.dim)
                Slider(value: $pxPerBeat, in: 24...160).controlSize(.mini).frame(width: 110)
            }
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    HStack(alignment: .top, spacing: 0) {
                        Keys().frame(width: keysWidth, height: height)
                        ZStack(alignment: .topLeading) {
                            Canvas { ctx, size in drawGrid(&ctx, size) }
                                .frame(width: width, height: height)
                                .contentShape(Rectangle())
                                .gesture(SpatialTapGesture().onEnded { add(at: $0.location) })
                            ForEach(Array(clip.notes.enumerated()), id: \.offset) { index, note in
                                NoteView(clip: clip, index: index, note: note, tint: tint, pxPerBeat: pxPerBeat) { lastLength = $0 }
                            }
                        }
                        .frame(width: width, height: height)
                    }
                    .id("roll")
                }
                .onAppear {
                    let mid = clip.notes.isEmpty ? 60 : Int(clip.notes.map { Int($0.pitch) }.reduce(0, +)) / clip.notes.count
                    proxy.scrollTo("roll", anchor: UnitPoint(x: 0, y: 1 - Double(mid - lowPitch) / Double(highPitch - lowPitch)))
                }
            }
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private func drawGrid(_ ctx: inout GraphicsContext, _ size: CGSize) {
        for pitch in lowPitch...highPitch {
            let y = CGFloat(highPitch - pitch) * rowHeight
            let black = [1, 3, 6, 8, 10].contains(pitch % 12)
            ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: rowHeight)), with: .color(black ? .black.opacity(0.28) : .white.opacity(0.03)))
            if pitch % 12 == 0 { ctx.fill(Path(CGRect(x: 0, y: y + rowHeight - 1, width: size.width, height: 1)), with: .color(.white.opacity(0.12))) }
        }
        let beats = Int(Double(clip.length.rawValue) / Double(Tick.perQuarter) * 4) + 1
        for i in 0...beats {
            let x = CGFloat(i) * pxPerBeat / 4
            let strong = i % 16 == 0, beat = i % 4 == 0
            ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                     with: .color(.white.opacity(strong ? 0.28 : (beat ? 0.12 : 0.04))))
        }
        // Past the end of the clip nothing plays.
        let end = CGFloat(Double(clip.length.rawValue) / Double(Tick.perQuarter)) * pxPerBeat
        ctx.fill(Path(CGRect(x: end, y: 0, width: max(0, size.width - end), height: size.height)), with: .color(.black.opacity(0.35)))
    }

    private func add(at point: CGPoint) {
        let tick = Int64(Double(point.x / pxPerBeat) * Double(Tick.perQuarter)) / grid * grid
        let pitch = highPitch - Int(point.y / rowHeight)
        guard tick >= 0, tick < clip.length.rawValue, (lowPitch...highPitch).contains(pitch) else { return }
        var notes = clip.notes
        notes.append(MIDINote(tick: Tick(tick), length: Tick(min(lastLength, clip.length.rawValue - tick)), pitch: UInt8(pitch)))
        model.setNotes(clip.id, notes)
        model.auditionNote(UInt8(pitch))
    }
}

private struct Keys: View {
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
    }
}

private struct NoteView: View {
    @Environment(AppModel.self) private var model
    let clip: MIDIClip
    let index: Int
    let note: MIDINote
    let tint: Color
    let pxPerBeat: CGFloat
    let rememberLength: (Int64) -> Void
    @State private var move: CGSize = .zero
    @State private var stretch: CGFloat = 0

    var body: some View {
        let x = CGFloat(Double(note.tick.rawValue) / Double(Tick.perQuarter)) * pxPerBeat
        let w = max(4, CGFloat(Double(note.length.rawValue) / Double(Tick.perQuarter)) * pxPerBeat + stretch)
        let y = CGFloat(highPitch - Int(note.pitch)) * rowHeight
        RoundedRectangle(cornerRadius: 2)
            .fill(tint.opacity(0.45 + 0.55 * Double(note.velocity) / 127))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(.black.opacity(0.5), lineWidth: 0.5))
            .frame(width: w, height: rowHeight - 1)
            .overlay(alignment: .trailing) {
                Rectangle().fill(.clear).frame(width: 6).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { stretch = $0.translation.width }
                        .onEnded { g in
                            stretch = 0
                            let delta = Int64(Double(g.translation.width / pxPerBeat) * Double(Tick.perQuarter))
                            let length = max(grid, (note.length.rawValue + delta + grid / 2) / grid * grid)
                            rememberLength(length)
                            replace { $0.length = Tick(length) }
                        })
                    .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            }
            .offset(x: x + move.width, y: y + move.height)
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { move = $0.translation }
                .onEnded { g in
                    move = .zero
                    let dt = Int64(Double(g.translation.width / pxPerBeat) * Double(Tick.perQuarter))
                    let tick = min(max(0, (note.tick.rawValue + dt + grid / 2) / grid * grid), max(0, clip.length.rawValue - grid))
                    let pitch = min(max(lowPitch, Int(note.pitch) - Int((g.translation.height / rowHeight).rounded())), highPitch)
                    replace { $0.tick = Tick(tick); $0.pitch = UInt8(pitch) }
                    model.auditionNote(UInt8(pitch))
                })
            .onTapGesture(count: 2) { delete() }
            .contextMenu {
                Button("Delete", role: .destructive) { delete() }
                Menu("Velocity") { ForEach([32, 64, 96, 127], id: \.self) { v in Button("\(v)") { replace { $0.velocity = UInt8(v) } } } }
            }
    }

    private func replace(_ change: (inout MIDINote) -> Void) {
        var notes = clip.notes
        guard notes.indices.contains(index) else { return }
        change(&notes[index])
        model.setNotes(clip.id, notes)
    }

    private func delete() {
        var notes = clip.notes
        guard notes.indices.contains(index) else { return }
        notes.remove(at: index)
        model.setNotes(clip.id, notes)
    }
}
