import Foundation
import LoopStudioCore

/// Texture: Hann grains at four times overlap, each read from where the warp says plus a random spread
/// (Flux). No alignment to the waveform, so pitched material turns into a cloud; for pads, noise and
/// ambience that is the sound. The spread comes from a fixed seed: the same clip renders the same every time.
enum TextureStretch {
    static func render(_ pcm: PCMBuffer, curve: WarpCurve, grainMs: Double, flux: Double) -> PCMBuffer {
        let rate = pcm.sampleRate
        let outFrames = max(1, curve.outFrames)
        let n = max(64, Int((grainMs / 1000 * rate / 2).rounded()) * 2)
        let hop = n / 4
        let spread = Double(n) * min(1, max(0, flux / 100))
        let out = PCMBuffer(channels: pcm.channels, frames: outFrames, sampleRate: rate)
        var weight = [Float](repeating: 0, count: outFrames)
        let hann: [Float] = (0..<n).map { 0.5 - 0.5 * cosf(2 * .pi * Float($0) / Float(n)) }
        var rng = SplitMix(seed: 0x7E57_0E5E)
        let total = pcm.frames
        var o = -n / 2
        while o < outFrames {
            let center = Double(o + n / 2)
            let jitter = spread > 0 ? (rng.unit() * 2 - 1) * spread : 0
            let start = Int((curve.source(center) + jitter).rounded()) - n / 2
            for i in 0..<n {
                let to = o + i
                guard to >= 0, to < outFrames else { continue }
                let from = start + i
                let w = hann[i]
                weight[to] += w
                guard from >= 0, from < total else { continue }
                for c in 0..<pcm.channels { out.mutableChannel(c)[to] += pcm.channel(c)[from] * w }
            }
            o += hop
        }
        for c in 0..<pcm.channels {
            let y = out.mutableChannel(c)
            for i in 0..<outFrames where weight[i] > 1e-3 { y[i] /= weight[i] }
        }
        return out
    }
}

/// A small fixed-seed random source (SplitMix64).
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// 0 ..< 1.
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
