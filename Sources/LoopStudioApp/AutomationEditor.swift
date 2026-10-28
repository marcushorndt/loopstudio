import LoopStudioCore
import SwiftUI

/// An envelope editor. Click empty space to add a point, drag a point to move it,
/// double-click a point to delete it, shift-click a point to change the shape of the segment after it.
struct AutomationEditor: View {
    let target: AutomationTarget
    let points: [AutomationPoint]
    /// Horizontal scale: how many pixels one tick takes.
    let pixelsPerTick: Double
    let width: CGFloat
    let height: CGFloat
    var tint: Color = Theme.accent
    let onChange: ([AutomationPoint]) -> Void

    @State private var draft: [AutomationPoint]?
    @State private var dragging: Int?

    private var shown: [AutomationPoint] { draft ?? points }
    private let grid = Int64(Tick.perQuarter / 4)

    var body: some View {
        Canvas { ctx, size in
            // Background and a line at the default value.
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.18)))
            let defY = y(target.def)
            ctx.fill(Path(CGRect(x: 0, y: defY, width: size.width, height: 0.5)), with: .color(.white.opacity(0.18)))

            guard !shown.isEmpty else {
                ctx.draw(Text("Click to add a point").font(.system(size: 10)).foregroundStyle(Theme.dim), at: CGPoint(x: 8, y: 10), anchor: .leading)
                return
            }
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y(shown[0].value)))
            line.addLine(to: CGPoint(x: x(shown[0].tick), y: y(shown[0].value)))
            for i in 0..<(shown.count - 1) {
                let a = shown[i], b = shown[i + 1]
                let steps = a.curve == .linear || a.curve == .hold ? 1 : 24
                if a.curve == .hold {
                    line.addLine(to: CGPoint(x: x(b.tick), y: y(a.value)))
                    line.addLine(to: CGPoint(x: x(b.tick), y: y(b.value)))
                } else {
                    for s in 1...steps {
                        let t = Double(s) / Double(steps)
                        let v = a.value + (b.value - a.value) * AutomationMath.shape(a.curve, t)
                        line.addLine(to: CGPoint(x: x(a.tick) + (x(b.tick) - x(a.tick)) * t, y: y(v)))
                    }
                }
            }
            line.addLine(to: CGPoint(x: size.width, y: y(shown[shown.count - 1].value)))
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height)); fill.addLine(to: CGPoint(x: 0, y: size.height)); fill.closeSubpath()
            ctx.fill(fill, with: .color(tint.opacity(0.12)))
            ctx.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
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
                if dragging == nil { begin(at: g.startLocation) }
                guard let i = dragging, var working = draft, working.indices.contains(i) else { return }
                let tick = snap(Int64(max(0, g.location.x / pixelsPerTick)))
                working[i].tick = Tick(tick)
                working[i].value = target.value(atPosition: 1 - Double(min(max(0, g.location.y), height)) / Double(height))
                draft = working
            }
            .onEnded { _ in finish() })
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { v in
            if let i = nearest(to: v.location, in: points) {
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

    private func begin(at point: CGPoint) {
        var working = points
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

    private func finish() {
        if let draft { onChange(draft) }
        draft = nil
        dragging = nil
    }
}
