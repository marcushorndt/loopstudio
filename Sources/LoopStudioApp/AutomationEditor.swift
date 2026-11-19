import LoopStudioCore
import SwiftUI

/// The marking of one automation editor, as the model sees it: Delete removes the marked points.
struct AutomationMarking {
    var editor: UUID
    var delete: () -> Void
}

/// An envelope editor. A click adds a point; a drag on a point moves it; a drag on a segment moves the segment
/// up or down; a drag on empty space marks a stretch of time, like a range on a clip: the points inside are
/// marked, a drag inside the stretch moves them all, Delete removes them (the curve then runs straight from the
/// point before to the point after). Double-click a point to delete it, shift-click a point to change the shape
/// of the segment after it. The diamond in the middle of a straight segment sets its slope: drag it up or down;
/// double-click straightens.
struct AutomationEditor: View {
    @Environment(AppModel.self) private var model
    let target: AutomationTarget
    let points: [AutomationPoint]
    /// Horizontal scale: how many pixels one tick takes.
    let pixelsPerTick: Double
    let width: CGFloat
    let height: CGFloat
    var tint: Color = Theme.accent
    /// The pen (draw mode): a drag draws steps, one flat bar per grid cell, over whatever was there.
    var pen = false
    /// The cell of the pen, in ticks: the grid of the view that holds the editor.
    var penGrid: Int64 = Tick.perQuarter / 4
    let onChange: ([AutomationPoint]) -> Void

    @State private var draft: [AutomationPoint]?
    @State private var dragging: Int?
    /// The points a band has marked, as indices into `points`. A marked point drags the whole group.
    @State private var marked: Set<Int> = []
    /// The band being dragged over empty space, from its press to the pointer.
    @State private var band: CGRect?
    /// The marked stretch of time, in ticks, kept after the drag: Delete and a group drag work on it.
    @State private var range: ClosedRange<Int64>?
    @State private var editorID = UUID()
    /// The segment being dragged: its first point and the values of both ends at the press.
    @State private var segment: (index: Int, values: (Double, Double))?
    /// The marked points at the press of a group drag.
    @State private var groupStart: [Int: AutomationPoint]?
    /// The pointer has moved since the press: a press without movement is a click, which adds a point.
    @State private var moved = false
    /// The values the pen has drawn in this drag, by cell, and the last cell, so a fast drag fills the cells between.
    @State private var penPoints: [Int64: Double] = [:]
    @State private var penLast: Int64?
    /// The segment whose slope is being dragged: its first point, the slope at the start, and the drag direction.
    @State private var bending: (index: Int, start: Double, sign: Double)?
    /// The last click that did not move, by the tick of the point or the handle it hit and when: a second
    /// click on the same point within a moment is a double click, which removes the point (or flattens the slope).
    @State private var lastClick: (tick: Tick, handle: Bool, at: Date)?

    private var shown: [AutomationPoint] { draft ?? points }
    private let grid = Int64(Tick.perQuarter / 4)

    var body: some View {
        Canvas { ctx, size in
            // Background and a line at the default value.
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.background.opacity(0.6)))
            let defY = y(target.def)
            ctx.stroke(Path { p in p.move(to: CGPoint(x: 0, y: defY)); p.addLine(to: CGPoint(x: size.width, y: defY)) },
                       with: .color(Theme.dim.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            if let band {
                ctx.fill(Path(band), with: .color(.white.opacity(0.06)))
                ctx.stroke(Path(band), with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            } else if let range {
                let rect = CGRect(x: x(Tick(range.lowerBound)), y: 0, width: x(Tick(range.upperBound)) - x(Tick(range.lowerBound)), height: size.height)
                ctx.fill(Path(rect), with: .color(.white.opacity(0.08)))
                ctx.stroke(Path(rect), with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            guard !shown.isEmpty else { return }
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y(shown[0].value)))
            line.addLine(to: CGPoint(x: x(shown[0].tick), y: y(shown[0].value)))
            for i in 0..<(shown.count - 1) {
                for p in samples(i, in: shown) { line.addLine(to: p) }
            }
            line.addLine(to: CGPoint(x: size.width, y: y(shown[shown.count - 1].value)))
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height)); fill.addLine(to: CGPoint(x: 0, y: size.height)); fill.closeSubpath()
            ctx.fill(fill, with: .color(tint.opacity(0.12)))
            ctx.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
            if let s = segment {
                // The segment in hand, brighter.
                var held = Path()
                held.move(to: CGPoint(x: x(shown[s.index].tick), y: y(shown[s.index].value)))
                for p in samples(s.index, in: shown) { held.addLine(to: p) }
                ctx.stroke(held, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
            for i in shown.indices.dropLast() {
                guard let c = handle(i, in: shown) else { continue }
                let r: CGFloat = bending?.index == i ? 4.5 : 3.5
                let diamond = Path { p in
                    p.move(to: CGPoint(x: c.x, y: c.y - r)); p.addLine(to: CGPoint(x: c.x + r, y: c.y))
                    p.addLine(to: CGPoint(x: c.x, y: c.y + r)); p.addLine(to: CGPoint(x: c.x - r, y: c.y)); p.closeSubpath()
                }
                ctx.fill(diamond, with: .color(Theme.background))
                ctx.stroke(diamond, with: .color(bending?.index == i ? .white : tint), lineWidth: 1.2)
            }
            for (i, p) in shown.enumerated() {
                let c = CGPoint(x: x(p.tick), y: y(p.value))
                let isMarked = marked.contains(i)
                let r: CGFloat = isMarked ? 5 : 4
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(dragging == i || isMarked ? .white : tint))
                if isMarked { ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r - 1.5, y: c.y - r - 1.5, width: 2 * r + 3, height: 2 * r + 3)), with: .color(tint), lineWidth: 1) }
            }
            if let i = dragging, shown.indices.contains(i) {
                let p = shown[i]
                ctx.draw(Text(label(p.value)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white),
                         at: CGPoint(x: min(size.width - 40, x(p.tick) + 8), y: max(10, y(p.value) - 10)), anchor: .leading)
            } else if let s = segment, shown.indices.contains(s.index) {
                let p = shown[s.index]
                ctx.draw(Text(label(p.value)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white),
                         at: CGPoint(x: min(size.width - 40, x(p.tick) + 8), y: max(10, y(p.value) - 10)), anchor: .leading)
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                if pen { draw(at: g.location); return }
                if dragging == nil && bending == nil && segment == nil && band == nil { begin(at: g.startLocation) }
                let dx = g.location.x - g.startLocation.x, dy = g.location.y - g.startLocation.y
                if abs(dx) > 2 || abs(dy) > 2 { moved = true }
                // A rise of the whole height moves a value over the whole range.
                let dPos = -Double(dy) / Double(height)
                if let b = bending, var working = draft, working.indices.contains(b.index) {
                    working[b.index].bend = min(max(b.start + Double(-dy) / 60 * b.sign, -1), 1)
                    draft = working
                    return
                }
                if let s = segment, var working = draft, working.indices.contains(s.index + 1) {
                    working[s.index].value = target.value(atPosition: target.position(s.values.0) + dPos)
                    working[s.index + 1].value = target.value(atPosition: target.position(s.values.1) + dPos)
                    draft = working
                    return
                }
                if let start = band?.origin {
                    // The band is a stretch of time over the whole height, like a marked range on a clip.
                    let rect = CGRect(x: min(start.x, g.location.x), y: 0, width: abs(g.location.x - start.x), height: height)
                    band = rect
                    let lo = Int64(max(0, rect.minX / pixelsPerTick)), hi = Int64(max(0, rect.maxX / pixelsPerTick))
                    marked = Set(points.indices.filter { (lo...hi).contains(points[$0].tick.rawValue) })
                    return
                }
                guard let i = dragging, var working = draft, working.indices.contains(i) else { return }
                if let starts = groupStart {
                    // The group keeps its shape: every point moves by the same snapped ticks and the same position,
                    // and never past the points outside the group on either side.
                    var delta = snap(Int64(dx / pixelsPerTick))
                    let lo = starts.values.map(\.tick.rawValue).min() ?? 0, hi = starts.values.map(\.tick.rawValue).max() ?? 0
                    let others = points.indices.filter { !starts.keys.contains($0) }.map { points[$0].tick.rawValue }
                    if let prev = others.filter({ $0 < lo }).max() { delta = max(delta, prev + 1 - lo) }
                    if let next = others.filter({ $0 > hi }).min() { delta = min(delta, next - 1 - hi) }
                    for (j, p0) in starts where working.indices.contains(j) {
                        working[j].tick = Tick(max(0, p0.tick.rawValue + delta))
                        working[j].value = target.value(atPosition: target.position(p0.value) + dPos)
                    }
                    draft = working
                    return
                }
                // A point stays between its neighbours: the order of the curve never changes in a drag.
                var tick = snap(Int64(max(0, g.location.x / pixelsPerTick)))
                if i > 0 { tick = max(tick, points[i - 1].tick.rawValue + 1) }
                if i + 1 < points.count { tick = min(tick, points[i + 1].tick.rawValue - 1) }
                if i > 0, i + 1 < points.count, points[i - 1].tick.rawValue + 1 > points[i + 1].tick.rawValue - 1 { tick = points[i].tick.rawValue }
                working[i].tick = Tick(tick)
                working[i].value = target.value(atPosition: 1 - Double(min(max(0, g.location.y), height)) / Double(height))
                draft = working
            }
            .onEnded { g in finish(at: g.startLocation) })
        .contextMenu {
            if !marked.isEmpty {
                Button("Delete \(marked.count) Marked Point\(marked.count == 1 ? "" : "s")", action: deleteMarked)
                Button("Clear Marking") { marked = []; range = nil }
            } else {
                Text("Drag over the lane to mark a stretch; Delete removes its points, a drag inside moves them.")
            }
        }
        // The model routes Delete to the editor that holds a marking.
        .onChange(of: marked) { _, now in
            if now.isEmpty { if model.automationMarking?.editor == editorID { model.automationMarking = nil } }
            else { model.automationMarking = AutomationMarking(editor: editorID, delete: deleteMarked) }
        }
        .onDisappear { if model.automationMarking?.editor == editorID { model.automationMarking = nil } }
    }

    /// Removes the marked points. The curve then runs from the point before the stretch to the point after it.
    private func deleteMarked() {
        let keep = points.indices.filter { !marked.contains($0) }.map { points[$0] }
        marked = []
        range = nil
        onChange(keep)
    }

    /// A press that did not move on a point or a slope handle: the second one within a moment is a double
    /// click. On a point it removes the point; on a handle it flattens the slope. True when it was one.
    private func doubleClick(tick: Tick, handle: Bool) -> Bool {
        let now = Date()
        if let last = lastClick, last.tick == tick, last.handle == handle, now.timeIntervalSince(last.at) < 0.4 {
            lastClick = nil
            return true
        }
        lastClick = (tick, handle, now)
        return false
    }

    private func x(_ t: Tick) -> CGFloat { CGFloat(Double(t.rawValue) * pixelsPerTick) }
    private func y(_ v: Double) -> CGFloat { height * (1 - CGFloat(target.position(v))) }
    private func snap(_ t: Int64) -> Int64 { (t + grid / 2) / grid * grid }

    private func label(_ v: Double) -> String {
        if !target.choices.isEmpty { return target.choices[min(max(0, Int(v.rounded())), target.choices.count - 1)] }
        return String(format: abs(v) >= 100 ? "%.0f" : "%.2f", v) + (target.unit.isEmpty ? "" : " \(target.unit)")
    }

    /// The curve of the segment that starts at point `i`, as the points of a polyline after its first point.
    private func samples(_ i: Int, in list: [AutomationPoint]) -> [CGPoint] {
        let a = list[i], b = list[i + 1]
        if a.curve == .hold { return [CGPoint(x: x(b.tick), y: y(a.value)), CGPoint(x: x(b.tick), y: y(b.value))] }
        let steps = a.curve == .linear && (a.bend ?? 0) == 0 ? 1 : 24
        return (1...steps).map { s in
            let t = Double(s) / Double(steps)
            let v = a.value + (b.value - a.value) * AutomationMath.shape(a.curve, bend: a.bend, t)
            return CGPoint(x: x(a.tick) + (x(b.tick) - x(a.tick)) * t, y: y(v))
        }
    }

    private func nearest(to point: CGPoint, in list: [AutomationPoint]) -> Int? {
        var best: (Int, CGFloat)?
        for (i, p) in list.enumerated() {
            let d = hypot(x(p.tick) - point.x, y(p.value) - point.y)
            if d < 10, best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }

    /// The segment under the pointer: the first of the two points, when the curve passes within a few pixels.
    private func nearestSegment(to point: CGPoint, in list: [AutomationPoint]) -> Int? {
        var best: (Int, CGFloat)?
        for i in list.indices.dropLast() {
            var from = CGPoint(x: x(list[i].tick), y: y(list[i].value))
            for to in samples(i, in: list) {
                let d = distance(point, from: from, to: to)
                if d < 7, best == nil || d < best!.1 { best = (i, d) }
                from = to
            }
        }
        return best?.0
    }

    private func distance(_ p: CGPoint, from a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t = len2 > 0 ? min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1) : 0
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// The slope handle of the segment that starts at point `i`: halfway in time, on the curve.
    /// Only straight (linear) segments with a rise or fall have one.
    private func handle(_ i: Int, in list: [AutomationPoint]) -> CGPoint? {
        guard i + 1 < list.count else { return nil }
        let a = list[i], b = list[i + 1]
        guard a.curve == .linear, a.value != b.value, x(b.tick) - x(a.tick) >= 16 else { return nil }
        let v = a.value + (b.value - a.value) * AutomationMath.shape(.linear, bend: a.bend, 0.5)
        return CGPoint(x: (x(a.tick) + x(b.tick)) / 2, y: y(v))
    }

    private func nearestHandle(to point: CGPoint, in list: [AutomationPoint]) -> Int? {
        list.indices.first { i in handle(i, in: list).map { hypot($0.x - point.x, $0.y - point.y) < 7 } ?? false }
    }

    private func begin(at point: CGPoint) {
        var working = points
        moved = false
        if nearest(to: point, in: working) == nil, let i = nearestHandle(to: point, in: working) {
            // Dragging up bows the curve up: for a rising segment that is a positive slope.
            bending = (i, working[i].bend ?? 0, working[i + 1].value > working[i].value ? 1 : -1)
            draft = working
            return
        }
        if let i = nearest(to: point, in: working) {
            if NSEvent.modifierFlags.contains(.shift) {
                let order: [Curve] = [.linear, .hold, .easeIn, .easeOut, .easeInOut]
                working[i].curve = order[((order.firstIndex(of: working[i].curve) ?? 0) + 1) % order.count]
                draft = working
                dragging = i
                return
            }
            dragging = i
            if marked.contains(i) {
                groupStart = Dictionary(uniqueKeysWithValues: marked.filter { working.indices.contains($0) }.map { ($0, working[$0]) })
            } else {
                marked = []
            }
            draft = working
            return
        }
        // A press inside the marked stretch drags every marked point, up, down or sideways.
        if let range, !marked.isEmpty, range.contains(Int64(max(0, point.x / pixelsPerTick))),
           let first = marked.sorted().first, working.indices.contains(first) {
            dragging = first
            groupStart = Dictionary(uniqueKeysWithValues: marked.filter { working.indices.contains($0) }.map { ($0, working[$0]) })
            draft = working
            return
        }
        marked = []
        range = nil
        if let s = nearestSegment(to: point, in: working) {
            segment = (s, (working[s].value, working[s + 1].value))
            draft = working
            return
        }
        band = CGRect(origin: point, size: .zero)
    }

    /// Adds a point under the pointer: on the grid, at the value the pointer is at.
    private func addPoint(at point: CGPoint) {
        let tick = snap(Int64(max(0, point.x / pixelsPerTick)))
        let value = target.value(atPosition: 1 - Double(min(max(0, point.y), height)) / Double(height))
        var next = points.filter { $0.tick != Tick(tick) }
        next.append(AutomationPoint(tick: Tick(tick), value: value))
        next.sort { $0.tick < $1.tick }
        onChange(next)
    }

    /// The pen: one flat step per grid cell at the value under the pointer. A fast drag fills the cells it skipped
    /// with the latest value. The cells the drag has covered are replaced; the rest of the curve stays, and after
    /// the last drawn cell it continues where it was.
    private func draw(at point: CGPoint) {
        let cell = Int64(max(0, point.x / pixelsPerTick)) / penGrid * penGrid
        let value = target.value(atPosition: 1 - Double(min(max(0, point.y), height)) / Double(height))
        if let last = penLast, abs(cell - last) > penGrid {
            for c in stride(from: min(cell, last), through: max(cell, last), by: Int(penGrid)) { penPoints[c] = value }
        }
        penPoints[cell] = value
        penLast = cell
        guard let lo = penPoints.keys.min(), let hi = penPoints.keys.max() else { return }
        let end = hi + penGrid
        var working = points.filter { $0.tick.rawValue < lo || $0.tick.rawValue >= end }
        // The painted stretch gets its own boundaries: before it and after it the curve keeps the value it
        // had there (the default when the lane was empty), so the pen never moves the open ends of the lane.
        if lo > 0, !working.contains(where: { $0.tick.rawValue < lo }) {
            working.append(AutomationPoint(tick: 0, value: AutomationMath.value(points, at: Tick(lo)) ?? target.def, curve: .hold))
        }
        working += penPoints.map { AutomationPoint(tick: Tick($0.key), value: $0.value, curve: .hold) }
        if !working.contains(where: { $0.tick.rawValue == end }) {
            working.append(AutomationPoint(tick: Tick(end), value: AutomationMath.value(points, at: Tick(end)) ?? target.def))
        }
        working.sort { $0.tick < $1.tick }
        draft = working
    }

    private func finish(at press: CGPoint) {
        defer {
            draft = nil
            dragging = nil
            bending = nil
            segment = nil
            band = nil
            groupStart = nil
            moved = false
            penPoints = [:]
            penLast = nil
        }
        if pen { if let draft { onChange(draft) }; return }
        if let band {
            // A press on empty space that did not move is a click: it adds a point. A drag keeps its stretch.
            if !moved { addPoint(at: press); marked = []; range = nil; return }
            let lo = Int64(max(0, band.minX / pixelsPerTick)), hi = Int64(max(0, band.maxX / pixelsPerTick))
            range = lo <= hi ? lo...hi : nil
            return
        }
        if segment != nil, !moved { addPoint(at: press); return }
        guard var draft else { return }
        if !moved, let b = bending, points.indices.contains(b.index) {
            if doubleClick(tick: points[b.index].tick, handle: true) { var next = points; next[b.index].bend = nil; onChange(next) }
            return
        }
        if !moved, groupStart != nil { return }
        if !moved, groupStart == nil, let i = dragging, points.indices.contains(i), draft[i].curve == points[i].curve {
            if doubleClick(tick: points[i].tick, handle: false) { var next = points; next.remove(at: i); onChange(next); marked = [] }
            return
        }
        if let starts = groupStart {
            // The group keeps its marks after the sort: the moved points are found again by their place.
            let movedPoints = starts.keys.compactMap { draft.indices.contains($0) ? draft[$0] : nil }
            draft.sort { $0.tick < $1.tick }
            marked = Set(draft.indices.filter { i in movedPoints.contains { $0.tick == draft[i].tick && $0.value == draft[i].value } })
            if let range, let lo = movedPoints.map(\.tick.rawValue).min(), let hi = movedPoints.map(\.tick.rawValue).max(),
               let oldLo = starts.values.map(\.tick.rawValue).min() {
                let shift = lo - oldLo
                self.range = (range.lowerBound + shift)...max(range.upperBound + shift, hi)
            }
        } else {
            draft.sort { $0.tick < $1.tick }
        }
        onChange(draft)
    }
}
