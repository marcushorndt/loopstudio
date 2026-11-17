import LoopStudioCore
import SwiftUI

/// An envelope editor. Click empty space to add a point, drag a point to move it,
/// double-click a point to delete it, shift-click a point to change the shape of the segment after it.
/// The diamond in the middle of a straight segment sets its slope: drag it up or down; double-click straightens.
struct AutomationEditor: View {
    let target: AutomationTarget
    let points: [AutomationPoint]
    /// Horizontal scale: how many pixels one tick takes.
    let pixelsPerTick: Double
    let width: CGFloat
    let height: CGFloat
    var tint: Color = Theme.accent
    /// The pen (draw mode): a drag draws the curve, one point per grid step, over whatever was there.
    var pen = false
    let onChange: ([AutomationPoint]) -> Void

    @State private var draft: [AutomationPoint]?
    @State private var dragging: Int?
    /// The points the pen has drawn in this drag, by tick, and the ticks the drag has covered.
    @State private var penPoints: [Int64: Double] = [:]
    @State private var penRange: ClosedRange<Int64>?
    /// The segment whose slope is being dragged: its first point, the slope at the start, and the drag direction.
    @State private var bending: (index: Int, start: Double, sign: Double)?

    private var shown: [AutomationPoint] { draft ?? points }
    private let grid = Int64(Tick.perQuarter / 4)

    var body: some View {
        Canvas { ctx, size in
            // Background and a line at the default value.
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.background.opacity(0.6)))
            let defY = y(target.def)
            ctx.stroke(Path { p in p.move(to: CGPoint(x: 0, y: defY)); p.addLine(to: CGPoint(x: size.width, y: defY)) },
                       with: .color(Theme.dim.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            guard !shown.isEmpty else { return }
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y(shown[0].value)))
            line.addLine(to: CGPoint(x: x(shown[0].tick), y: y(shown[0].value)))
            for i in 0..<(shown.count - 1) {
                let a = shown[i], b = shown[i + 1]
                let steps = (a.curve == .linear && (a.bend ?? 0) == 0) || a.curve == .hold ? 1 : 24
                if a.curve == .hold {
                    line.addLine(to: CGPoint(x: x(b.tick), y: y(a.value)))
                    line.addLine(to: CGPoint(x: x(b.tick), y: y(b.value)))
                } else {
                    for s in 1...steps {
                        let t = Double(s) / Double(steps)
                        let v = a.value + (b.value - a.value) * AutomationMath.shape(a.curve, bend: a.bend, t)
                        line.addLine(to: CGPoint(x: x(a.tick) + (x(b.tick) - x(a.tick)) * t, y: y(v)))
                    }
                }
            }
            line.addLine(to: CGPoint(x: size.width, y: y(shown[shown.count - 1].value)))
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height)); fill.addLine(to: CGPoint(x: 0, y: size.height)); fill.closeSubpath()
            ctx.fill(fill, with: .color(tint.opacity(0.12)))
            ctx.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
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
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(dragging == i ? .white : tint))
            }
            if let i = dragging, shown.indices.contains(i) {
                let p = shown[i]
                ctx.draw(Text(label(p.value)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white),
                         at: CGPoint(x: min(size.width - 40, x(p.tick) + 8), y: max(10, y(p.value) - 10)), anchor: .leading)
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                if pen { draw(at: g.location); return }
                if dragging == nil && bending == nil { begin(at: g.startLocation) }
                if let b = bending, var working = draft, working.indices.contains(b.index) {
                    let dy = Double(g.startLocation.y - g.location.y) / 60
                    working[b.index].bend = min(max(b.start + dy * b.sign, -1), 1)
                    draft = working
                    return
                }
                guard let i = dragging, var working = draft, working.indices.contains(i) else { return }
                let tick = snap(Int64(max(0, g.location.x / pixelsPerTick)))
                working[i].tick = Tick(tick)
                working[i].value = target.value(atPosition: 1 - Double(min(max(0, g.location.y), height)) / Double(height))
                draft = working
            }
            .onEnded { _ in finish() })
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { v in
            if let i = nearestHandle(to: v.location, in: points) {
                var next = points; next[i].bend = nil; onChange(next)
            } else if let i = nearest(to: v.location, in: points) {
                var next = points; next.remove(at: i); onChange(next)
            }
        })
    }

    private func x(_ t: Tick) -> CGFloat { CGFloat(Double(t.rawValue) * pixelsPerTick) }
    private func y(_ v: Double) -> CGFloat { height * (1 - CGFloat(target.position(v))) }
    private func snap(_ t: Int64) -> Int64 { (t + grid / 2) / grid * grid }

    private func label(_ v: Double) -> String {
        if !target.choices.isEmpty { return target.choices[min(max(0, Int(v.rounded())), target.choices.count - 1)] }
        return String(format: abs(v) >= 100 ? "%.0f" : "%.2f", v) + (target.unit.isEmpty ? "" : " \(target.unit)")
    }

    private func nearest(to point: CGPoint, in list: [AutomationPoint]) -> Int? {
        var best: (Int, CGFloat)?
        for (i, p) in list.enumerated() {
            let d = hypot(x(p.tick) - point.x, y(p.value) - point.y)
            if d < 10, best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
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
        } else {
            let tick = snap(Int64(max(0, point.x / pixelsPerTick)))
            let value = target.value(atPosition: 1 - Double(min(max(0, point.y), height)) / Double(height))
            working.append(AutomationPoint(tick: Tick(tick), value: value))
            working.sort { $0.tick < $1.tick }
            dragging = working.firstIndex { $0.tick == Tick(tick) }
        }
        draft = working
    }

    /// The pen: the value under the pointer lands on the nearest grid step. The points the drag has swept
    /// over are replaced; the rest of the curve stays.
    private func draw(at point: CGPoint) {
        let tick = snap(Int64(max(0, point.x / pixelsPerTick)))
        let value = target.value(atPosition: 1 - Double(min(max(0, point.y), height)) / Double(height))
        penPoints[tick] = value
        penRange = penRange.map { min($0.lowerBound, tick)...max($0.upperBound, tick) } ?? tick...tick
        var working = points.filter { !(penRange!.contains($0.tick.rawValue)) }
        working += penPoints.map { AutomationPoint(tick: Tick($0.key), value: $0.value) }
        working.sort { $0.tick < $1.tick }
        draft = working
    }

    private func finish() {
        if let draft { onChange(draft) }
        draft = nil
        dragging = nil
        bending = nil
        penPoints = [:]
        penRange = nil
    }
}
