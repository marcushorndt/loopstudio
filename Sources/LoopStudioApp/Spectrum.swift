import Accelerate
import LoopStudioCore
import LoopStudioEngine
import SwiftUI

/// Turns the last 2048 samples of a `SpectrumTap` into a smoothed dB spectrum. One per display.
final class SpectrumAnalyzer {
    static let n = 2048
    private let window: [Float]
    private let fft: vDSP.FFT<DSPSplitComplex>
    private var input = [Float](repeating: 0, count: n)
    private var real = [Float](repeating: 0, count: n / 2)
    private var imag = [Float](repeating: 0, count: n / 2)
    private var power = [Float](repeating: 0, count: n / 2)
    /// dB per bin, with a fast attack and a slow fall, so a hit shows and the picture does not flicker.
    private(set) var db = [Float](repeating: -120, count: n / 2)
    private var generation = -1
    /// A full-scale sine lands near 0 dB: the window halves it, the packed FFT doubles it, the sum spans n.
    private let referenceDb = 20 * log10(4 / Float(n))

    init() {
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.n, isHalfWindow: false)
        fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(Self.n))), radix: .radix2, ofType: DSPSplitComplex.self)!
    }

    /// Reads the tap when it has new audio. Returns false when nothing changed since the last call.
    @discardableResult func update(from tap: SpectrumTap) -> Bool {
        guard tap.generation != generation else { return false }
        generation = tap.generation
        input.withUnsafeMutableBufferPointer { tap.copyLatest(into: $0.baseAddress!, count: Self.n) }
        vDSP.multiply(input, window, result: &input)
        let half = Self.n / 2
        input.withUnsafeBufferPointer { samples in
            real.withUnsafeMutableBufferPointer { r in
                imag.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                    fft.forward(input: split, output: &split)
                    power.withUnsafeMutableBufferPointer { vDSP_zvmags(&split, 1, $0.baseAddress!, 1, vDSP_Length(half)) }
                }
            }
        }
        for i in 0..<half {
            let value = 10 * log10(max(power[i], 1e-14)) + referenceDb
            db[i] = value > db[i] ? value : max(db[i] - 1.2, -120)
        }
        return true
    }

    /// The level at a frequency, between the two bins around it.
    func level(at hz: Double, sampleRate: Double) -> Float {
        let bin = hz / sampleRate * Double(Self.n)
        let i = Int(bin)
        guard i >= 0, i + 1 < db.count else { return -120 }
        let t = Float(bin - Double(i))
        return db[i] * (1 - t) + db[i + 1] * t
    }
}

/// The spectrum of a device's output, filled from the bottom, behind its curve. 30 Hz, and only when the
/// device runs. `x` maps a frequency to the display; the level spans `floorDb` (bottom) to 0 dB (top).
struct SpectrumBackdrop: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSlot
    let tint: Color
    let x: (Double) -> CGFloat
    var floorDb: Float = -90
    @State private var analyzer = SpectrumAnalyzer()

    var body: some View {
        let tap = model.engine.builtInEffect(device.id)?.spectrum
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: tap == nil)) { _ in
            Canvas { ctx, size in
                guard let tap else { return }
                analyzer.update(from: tap)
                let rate = model.sampleRate
                let minHz = 20.0, maxHz = min(20_000, rate / 2)
                let points = 160
                var path = Path()
                path.move(to: CGPoint(x: x(minHz), y: size.height))
                for i in 0...points {
                    let hz = minHz * pow(maxHz / minHz, Double(i) / Double(points))
                    let level = max(analyzer.level(at: hz, sampleRate: rate), floorDb)
                    let y = size.height * CGFloat(1 - (level - floorDb) / -floorDb)
                    path.addLine(to: CGPoint(x: x(hz), y: max(0, y)))
                }
                path.addLine(to: CGPoint(x: x(maxHz), y: size.height))
                path.closeSubpath()
                ctx.fill(path, with: .color(tint.opacity(0.16)))
                ctx.stroke(path, with: .color(tint.opacity(0.3)), lineWidth: 0.5)
            }
        }
        .allowsHitTesting(false)
    }
}
