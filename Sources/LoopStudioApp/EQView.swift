import LoopStudioCore
import LoopStudioEngine
import SwiftUI

/// The panel of EQ One to EQ Eight: the curve over the spectrum of its output, one handle per band, and
/// the knobs of the marked band at the right. Drag a handle: frequency and gain. Hold Option, before or
/// during the drag: the Q. Double-click: the band on or off. Right-click: the type.
struct EQView: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let device: DeviceSlot
    let spec: EffectSpec
    @State private var selected = 0
    @State private var drag: Drag?

    private struct Drag {
        var band: Int
        /// Option held: the vertical movement sets the Q instead of the gain.
        var q: Bool
        /// The translation when the mode last changed; the movement counts from here.
        var anchor: CGSize = .zero
        var startFreq: Double
        var startGain: Double
        var startQ: Double
    }

    private static let width: CGFloat = 360, pickerHeight: CGFloat = 16
    private static let height = DeviceLayout.bodyHeight - DeviceLayout.groupGap - pickerHeight
    private static let minHz = 20.0, maxHz = 20_000.0, rangeDb = 24.0
    private static let curveHz: [Double] = (0..<96).map { minHz * pow(maxHz / minHz, Double($0) / 95) }

    private var tint: Color { Theme.track(track.colorIndex) }

    private func value(_ key: String) -> Double {
        guard let p = spec.param(key) else { return 0 }
        return p.clamp(device.params[key] ?? p.def)
    }

    private func x(_ hz: Double) -> CGFloat { CGFloat(log(max(hz, Self.minHz) / Self.minHz) / log(Self.maxHz / Self.minHz)) * Self.width }
    private func hz(_ x: CGFloat) -> Double { Self.minHz * pow(Self.maxHz / Self.minHz, Double(min(max(x, 0), Self.width) / Self.width)) }
    private func y(_ db: Double) -> CGFloat { Self.height / 2 - CGFloat(db / Self.rangeDb) * Self.height / 2 }
    private func db(_ y: CGFloat) -> Double { Double((Self.height / 2 - y) / (Self.height / 2)) * Self.rangeDb }

    /// A band whose type has no gain (a cut, a notch or a band pass) sits on the zero line.
    private func hasGain(_ type: Int) -> Bool { type == 1 || type == 2 || type == 4 }

    private func handle(_ band: Int) -> CGPoint {
        let type = Int(value("b\(band + 1).type"))
        return CGPoint(x: x(value("b\(band + 1).freq")), y: y(hasGain(type) ? value("b\(band + 1).gain") : 0))
    }

    var body: some View {
        HStack(alignment: .top, spacing: DeviceLayout.groupGap) {
            VStack(spacing: DeviceLayout.groupGap) {
                ZStack {
                    SpectrumBackdrop(device: device, tint: tint, x: x)
                    curve
                }
                .frame(width: Self.width, height: Self.height)
                .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line.opacity(0.7), lineWidth: 1))
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .simultaneousGesture(TapGesture(count: 2).onEnded { toggle(selected) })
                .contextMenu { bandMenu }
                .hint("Drag a band: frequency and gain. Option, also mid-drag: Q. Double-click: band on or off. Right-click: type. Behind it: the spectrum of the output.")
                bandPicker
            }
            VStack(alignment: .leading, spacing: DeviceLayout.groupGap) {
                KnobSection(title: "Band \(selected + 1)") {
                    ForEach(["b\(selected + 1).on", "b\(selected + 1).type", "b\(selected + 1).freq", "b\(selected + 1).gain", "b\(selected + 1).q"], id: \.self) {
                        ParamKnob(track: track, device: device, spec: spec, key: $0, tint: tint)
                    }
                }
                .id(selected)
                KnobSection(title: "Out") { ParamKnob(track: track, device: device, spec: spec, key: "gain", tint: tint) }
            }
        }
    }

    /// One button per band under the curve: the marked one in the tint, an off band dim.
    private var bandPicker: some View {
        HStack(spacing: 3) {
            ForEach(0..<spec.bands, id: \.self) { i in
                let on = value("b\(i + 1).on") >= 0.5
                Button { selected = i } label: {
                    Text("\(i + 1)").font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity).frame(height: Self.pickerHeight)
                        .foregroundStyle(selected == i ? Theme.text : (on ? Theme.dim : Theme.dim.opacity(0.5)))
                        .background(selected == i ? tint.opacity(0.4) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(on ? tint.opacity(0.6) : Theme.line, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hint("Band \(i + 1): \(BuiltInEffects.eqTypes[Int(value("b\(i + 1).type"))])\(on ? "" : ", off"). Click to show its knobs.")
            }
        }
        .frame(width: Self.width)
    }

    private var curve: some View {
        Canvas { ctx, size in
            // Grid: decades and the dB lines.
            for hz in [50.0, 100, 200, 500, 1_000, 2_000, 5_000, 10_000] {
                let px = x(hz)
                ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: 0)); $0.addLine(to: CGPoint(x: px, y: size.height)) },
                           with: .color(.white.opacity(hz == 100 || hz == 1_000 || hz == 10_000 ? 0.12 : 0.05)), lineWidth: 1)
                if hz == 100 || hz == 1_000 || hz == 10_000 {
                    ctx.draw(Text(hz >= 1_000 ? "\(Int(hz / 1_000))k" : "\(Int(hz))").font(.system(size: 8)).foregroundStyle(Theme.dim),
                             at: CGPoint(x: px + 2, y: size.height - 7), anchor: .leading)
                }
            }
            for dB in [-12.0, 0, 12] {
                let py = y(dB)
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: py)); $0.addLine(to: CGPoint(x: size.width, y: py)) },
                           with: .color(.white.opacity(dB == 0 ? 0.18 : 0.06)), lineWidth: 1)
            }
            // Each band alone, faint; the marked one a little stronger.
            for band in 0..<spec.bands where value("b\(band + 1).on") >= 0.5 {
                let response = EQDSP.bandResponseDb(at: Self.curveHz, band: band, spec: spec, params: device.params, sampleRate: model.sampleRate)
                var path = Path()
                for (i, hz) in Self.curveHz.enumerated() {
                    let p = CGPoint(x: x(hz), y: y(min(max(response[i], -Self.rangeDb), Self.rangeDb)))
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                ctx.stroke(path, with: .color(tint.opacity(band == selected ? 0.45 : 0.2)), lineWidth: 1)
            }
            // The sum.
            let sum = EQDSP.responseDb(at: Self.curveHz, spec: spec, params: device.params, sampleRate: model.sampleRate)
            var path = Path()
            for (i, hz) in Self.curveHz.enumerated() {
                let p = CGPoint(x: x(hz), y: y(min(max(sum[i], -Self.rangeDb), Self.rangeDb)))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            var fill = path
            fill.addLine(to: CGPoint(x: x(Self.curveHz.last!), y: y(0)))
            fill.addLine(to: CGPoint(x: x(Self.curveHz[0]), y: y(0)))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(tint.opacity(0.12)))
            ctx.stroke(path, with: .color(tint), lineWidth: 1.5)
            // The handles.
            for band in 0..<spec.bands {
                let on = value("b\(band + 1).on") >= 0.5
                let p = handle(band)
                let r: CGFloat = band == selected ? 7 : 5.5
                let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                ctx.fill(circle, with: .color(on ? (band == selected ? tint : tint.opacity(0.55)) : Color.black.opacity(0.5)))
                ctx.stroke(circle, with: .color(on ? Theme.text.opacity(0.8) : Theme.dim), lineWidth: 1)
                ctx.draw(Text("\(band + 1)").font(.system(size: 8, weight: .bold)).foregroundStyle(on ? Color.black : Theme.dim), at: p)
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let option = NSEvent.modifierFlags.contains(.option)
                if drag == nil {
                    // The nearest handle within reach takes the drag; a click elsewhere only marks the nearest band.
                    var best = selected, bestDistance = CGFloat.infinity
                    for band in 0..<spec.bands {
                        let p = handle(band), d = hypot(p.x - g.startLocation.x, p.y - g.startLocation.y)
                        if d < bestDistance { best = band; bestDistance = d }
                    }
                    selected = best
                    guard bestDistance < 16 else { return }
                    let k = "b\(best + 1)."
                    drag = Drag(band: best, q: option, startFreq: value(k + "freq"), startGain: value(k + "gain"), startQ: value(k + "q"))
                }
                guard var d = drag else { return }
                let k = "b\(d.band + 1)."
                if option != d.q {
                    // Option went down or up mid-drag: the movement from here on counts in the new mode.
                    d.q = option
                    d.anchor = g.translation
                    d.startFreq = value(k + "freq"); d.startGain = value(k + "gain"); d.startQ = value(k + "q")
                    drag = d
                }
                let dx = g.translation.width - d.anchor.width, dy = g.translation.height - d.anchor.height
                if d.q {
                    // Up: narrower. 100 points: a factor of four.
                    let q = min(max(d.startQ * pow(4, Double(-dy) / 100), 0.1), 18)
                    model.setDeviceParam(track.id, device.id, k + "q", q)
                } else {
                    let f = hz(x(d.startFreq) + dx)
                    model.setDeviceParam(track.id, device.id, k + "freq", (f * 10).rounded() / 10)
                    if hasGain(Int(value(k + "type"))) {
                        let gain = min(max(db(y(d.startGain) + dy), -Self.rangeDb), Self.rangeDb)
                        model.setDeviceParam(track.id, device.id, k + "gain", (gain * 10).rounded() / 10)
                    }
                }
            }
            .onEnded { _ in drag = nil }
    }

    private func toggle(_ band: Int) {
        let k = "b\(band + 1).on"
        model.setDeviceParam(track.id, device.id, k, value(k) >= 0.5 ? 0 : 1)
    }

    @ViewBuilder private var bandMenu: some View {
        let k = "b\(selected + 1)."
        Text("Band \(selected + 1)")
        ForEach(Array(BuiltInEffects.eqTypes.enumerated()), id: \.offset) { i, name in
            Button(name + (Int(value(k + "type")) == i ? "  ✓" : "")) { model.setDeviceParam(track.id, device.id, k + "type", Double(i)) }
        }
        Divider()
        Button(value(k + "on") >= 0.5 ? "Turn Band Off" : "Turn Band On") { toggle(selected) }
        Button("Reset Band") {
            model.apply(.batch(commands: ["on", "type", "freq", "gain", "q"].map { .setDeviceParam(track: track.id, device: device.id, key: k + $0, value: nil) }))
        }
    }
}
