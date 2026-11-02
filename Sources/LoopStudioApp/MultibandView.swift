import LoopStudioCore
import LoopStudioEngine
import SwiftUI

/// The panel of the Multiband Compressor: the three bands over the spectrum of the output, with the
/// crossovers and the thresholds as handles, and the gain reduction falling from the top of each band.
/// Drag a crossover line sideways. Drag inside a band up or down: its threshold. Hold Option, before or
/// during the drag: its ratio. The knobs sit at the right in two rows.
struct MultibandView: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let device: DeviceSlot
    let spec: EffectSpec
    @State private var drag: Drag?

    private enum Target: Equatable { case lowX, highX, band(Int) }

    private struct Drag {
        var target: Target
        var ratio: Bool
        var anchor: CGSize = .zero
        var start: Double
    }

    private static let width: CGFloat = 250
    private static let height = DeviceLayout.bodyHeight
    private static let minHz = 20.0, maxHz = 20_000.0, floorDb = -60.0
    private static let bandKeys = ["low", "mid", "high"], bandNames = ["Low", "Mid", "High"]

    private var tint: Color { Theme.track(track.colorIndex) }

    private func value(_ key: String) -> Double {
        guard let p = spec.param(key) else { return 0 }
        return p.clamp(device.params[key] ?? p.def)
    }

    private func x(_ hz: Double) -> CGFloat { CGFloat(log(max(hz, Self.minHz) / Self.minHz) / log(Self.maxHz / Self.minHz)) * Self.width }
    private func hz(_ x: CGFloat) -> Double { Self.minHz * pow(Self.maxHz / Self.minHz, Double(min(max(x, 0), Self.width) / Self.width)) }
    private func y(_ db: Double) -> CGFloat { CGFloat(db / Self.floorDb) * Self.height }
    private func db(_ y: CGFloat) -> Double { Double(min(max(y, 0), Self.height) / Self.height) * Self.floorDb }

    /// The band under a point, by the crossovers.
    private func band(at px: CGFloat) -> Int { px < x(value("lowX")) ? 0 : px < x(value("highX")) ? 1 : 2 }

    var body: some View {
        HStack(alignment: .top, spacing: DeviceLayout.groupGap) {
            ZStack {
                SpectrumBackdrop(device: device, tint: tint, x: x, floorDb: Float(Self.floorDb))
                display
            }
            .frame(width: Self.width, height: Self.height)
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line.opacity(0.7), lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .hint("Drag a crossover line sideways. Drag in a band up or down: its threshold. Option, also mid-drag: its ratio. The shade from the top: the gain reduction.")
            GroupedKnobs(track: track, device: device, spec: spec)
        }
    }

    private var display: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: model.engine.builtInEffect(device.id) == nil)) { _ in
            Canvas { ctx, size in
                let dsp = model.engine.builtInEffect(device.id)
                let edges = [x(Self.minHz), x(value("lowX")), x(value("highX")), x(Self.maxHz)]
                for (i, key) in Self.bandKeys.enumerated() {
                    let left = edges[i], right = edges[i + 1]
                    // The gain reduction, as a shade from the top, on the same dB scale as the thresholds.
                    let reduction = dsp.map { Double($0.meters[i]) } ?? 0
                    if reduction > 0.05 {
                        ctx.fill(Path(CGRect(x: left, y: 0, width: right - left, height: y(-reduction))), with: .color(tint.opacity(0.35)))
                    }
                    // The threshold line and the band's name with its numbers.
                    let threshold = value(key + ".threshold"), ty = y(threshold)
                    ctx.stroke(Path { $0.move(to: CGPoint(x: left, y: ty)); $0.addLine(to: CGPoint(x: right, y: ty)) },
                               with: .color(tint), lineWidth: 1.5)
                    let ratio = value(key + ".ratio")
                    let label = Text(String(format: "%@ %.0f dB · %.1f:1", Self.bandNames[i], threshold, ratio))
                        .font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.text.opacity(0.8))
                    ctx.draw(label, at: CGPoint(x: left + 4, y: min(ty + 3, size.height - 10)), anchor: .topLeading)
                }
                for dB in [-12.0, -24, -36, -48] {
                    let py = y(dB)
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: py)); $0.addLine(to: CGPoint(x: size.width, y: py)) },
                               with: .color(.white.opacity(0.06)), lineWidth: 1)
                }
                // The crossovers.
                for key in ["lowX", "highX"] {
                    let px = x(value(key))
                    ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: 0)); $0.addLine(to: CGPoint(x: px, y: size.height)) },
                               with: .color(Theme.text.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    let hzText = value(key) >= 1_000 ? String(format: "%.1fk", value(key) / 1_000) : "\(Int(value(key)))"
                    ctx.draw(Text(hzText).font(.system(size: 8)).foregroundStyle(Theme.dim), at: CGPoint(x: px + 2, y: size.height - 7), anchor: .leading)
                }
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let option = NSEvent.modifierFlags.contains(.option)
                if drag == nil {
                    let px = g.startLocation.x
                    let target: Target = abs(px - x(value("lowX"))) < 6 ? .lowX : abs(px - x(value("highX"))) < 6 ? .highX : .band(band(at: px))
                    drag = Drag(target: target, ratio: option, start: startValue(target, ratio: option))
                }
                guard var d = drag else { return }
                if option != d.ratio, case .band = d.target {
                    d.ratio = option
                    d.anchor = g.translation
                    d.start = startValue(d.target, ratio: option)
                    drag = d
                }
                let dx = g.translation.width - d.anchor.width, dy = g.translation.height - d.anchor.height
                switch d.target {
                case .lowX:
                    model.setDeviceParam(track.id, device.id, "lowX", (hz(x(d.start) + dx)).rounded())
                case .highX:
                    model.setDeviceParam(track.id, device.id, "highX", (hz(x(d.start) + dx)).rounded())
                case .band(let i):
                    let key = Self.bandKeys[i]
                    if d.ratio {
                        model.setDeviceParam(track.id, device.id, key + ".ratio", min(max(d.start * pow(4, Double(-dy) / 100), 1), 20))
                    } else {
                        model.setDeviceParam(track.id, device.id, key + ".threshold", (db(y(d.start) + dy) * 2).rounded() / 2)
                    }
                }
            }
            .onEnded { _ in drag = nil }
    }

    private func startValue(_ target: Target, ratio: Bool) -> Double {
        switch target {
        case .lowX: value("lowX")
        case .highX: value("highX")
        case .band(let i): value(Self.bandKeys[i] + (ratio ? ".ratio" : ".threshold"))
        }
    }
}
