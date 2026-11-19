import LoopStudioCore
import LoopStudioEngine
import SwiftUI

/// The panel of the Granulator: the buffer scrolls through the display with the record head at the right
/// edge, the read position stands as a line you drag, the spray shades the reach of the grains, and each
/// grain is a dot where it reads. Click the label at the top left: freeze or record. Knobs at the right.
struct GranulatorView: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let device: DeviceSlot
    let spec: EffectSpec

    private static let width: CGFloat = 260
    private static let height = DeviceLayout.bodyHeight

    private var tint: Color { Theme.track(track.colorIndex) }

    /// The parameters as the macros set them now.
    private var params: [String: Double] { model.drivenParams(device, on: track) }

    private func value(_ key: String) -> Double {
        guard let p = spec.param(key) else { return 0 }
        return p.clamp(params[key] ?? p.def)
    }

    var body: some View {
        HStack(alignment: .top, spacing: DeviceLayout.groupGap) {
            display
                .frame(width: Self.width, height: Self.height)
                .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line.opacity(0.7), lineWidth: 1))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    // The right edge is the record head (now); the left edge is eight seconds ago.
                    let position = 1 - Double(min(max(g.location.x, 0), Self.width) / Self.width)
                    model.setDeviceParam(track.id, device.id, "position", (position * 1_000).rounded() / 1_000)
                })
                .overlay(alignment: .topLeading) { recordButton.padding(4) }
                .hint("The buffer, newest at the right. Drag: the read position. The shade: the spray. Dots: the grains. Freeze stops the recording, so the position reads through a still buffer.")
            GroupedKnobs(track: track, device: device, spec: spec)
        }
    }

    private var recordButton: some View {
        let on = value("record") >= 0.5
        return Button { model.setDeviceParam(track.id, device.id, "record", on ? 0 : 1) } label: {
            Text(on ? "REC" : "FREEZE").font(.system(size: 8, weight: .bold))
                .padding(.horizontal, 5).frame(height: 12)
                .background(on ? Color.red.opacity(0.8) : Theme.accent, in: RoundedRectangle(cornerRadius: 2))
                .foregroundStyle(on ? Color.white : Color.black)
        }
        .buttonStyle(.plain)
        .hint(on ? "Recording into the buffer. Click: freeze it" : "The buffer is frozen. Click: record again")
    }

    private var display: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: model.engine.builtInEffect(device.id) == nil)) { _ in
            Canvas { ctx, size in
                let dsp = model.engine.builtInEffect(device.id)
                let bins = DSPEffect.waveformBins
                let mid = size.height / 2
                ctx.fill(Path(CGRect(x: 0, y: mid, width: size.width, height: 1)), with: .color(.white.opacity(0.08)))
                // The peaks, scrolled so the record head sits at the right edge.
                if let dsp, let wave = dsp.waveform {
                    let head = Double(dsp.meters[0]) // 0...1 of the ring
                    let headBin = Int(head * Double(bins))
                    let binWidth = size.width / CGFloat(bins)
                    var path = Path()
                    for i in 0..<bins {
                        // Bin `b` of the ring is `d` bins behind the head.
                        let b = (headBin - bins + 1 + i + bins) % bins
                        let peak = CGFloat(min(1, wave[b]))
                        let x = CGFloat(i) * binWidth
                        let h = max(1, peak * (size.height - 8))
                        path.addRect(CGRect(x: x, y: mid - h / 2, width: max(1, binWidth - 0.5), height: h))
                    }
                    ctx.fill(path, with: .color(tint.opacity(0.45)))
                }
                // The spray: how far behind the position the grains may start.
                let position = value("position")
                let spray = value("sprayMs") / 1_000 / DSPEffect.granulatorSeconds
                let px = size.width * CGFloat(1 - position)
                if spray > 0 {
                    let sx = size.width * CGFloat(max(0, 1 - position - spray))
                    ctx.fill(Path(CGRect(x: sx, y: 0, width: px - sx, height: size.height)), with: .color(tint.opacity(0.12)))
                }
                // The grain size, as a bracket after the position.
                let grainWidth = size.width * CGFloat(value("sizeMs") / 1_000 / DSPEffect.granulatorSeconds)
                ctx.fill(Path(CGRect(x: px, y: size.height - 4, width: max(2, grainWidth), height: 2)), with: .color(tint.opacity(0.8)))
                // The read position.
                ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: 0)); $0.addLine(to: CGPoint(x: px, y: size.height)) },
                           with: .color(Theme.text.opacity(0.9)), lineWidth: 1.5)
                // The grains: a dot where each one reads now.
                if let dsp, let marks = dsp.marks {
                    let head = Double(dsp.meters[0])
                    for i in 0..<DSPEffect.markCount where marks[i] >= 0 {
                        var behind = head - Double(marks[i])
                        if behind < 0 { behind += 1 }
                        let gx = size.width * CGFloat(1 - behind)
                        ctx.fill(Path(ellipseIn: CGRect(x: gx - 2, y: mid - 2 + CGFloat(i % 7 - 3) * 6, width: 4, height: 4)), with: .color(Theme.text.opacity(0.85)))
                    }
                }
                let text = String(format: "%.2f s back · %@", position * DSPEffect.granulatorSeconds, spec.param("window")?.choices[Int(value("window"))] ?? "")
                ctx.draw(Text(text).font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.dim), at: CGPoint(x: size.width - 4, y: 9), anchor: .trailing)
            }
        }
    }
}
