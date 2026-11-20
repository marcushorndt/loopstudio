import Foundation

/// A band-limited reader: the value of a signal between its samples, by a windowed sinc (Blackman, twelve
/// zero crossings each side). The cutoff below 1 widens the kernel, so a signal read faster than it was
/// recorded is filtered first and does not alias.
enum Sinc {
    static let half = 12
    static let oversample = 512

    /// The kernel from 0 to `half` zero crossings, `oversample` points per crossing, one guard point at the end.
    static let table: [Float] = (0...(half * oversample + 1)).map { i in
        let t = Double(i) / Double(oversample)
        guard t < Double(half) else { return 0 }
        let sinc = t == 0 ? 1 : sin(.pi * t) / (.pi * t)
        let u = t / Double(half)
        let window = 0.42 + 0.5 * cos(.pi * u) + 0.08 * cos(2 * .pi * u)
        return Float(sinc * window)
    }

    /// The value of `x` at fractional position `pos`, low-passed at `cutoff` (1 = the full band).
    @inline(__always)
    static func read(_ x: UnsafePointer<Float>, count: Int, at pos: Double, cutoff: Double, kernel: UnsafePointer<Float>) -> Float {
        let fc = min(1, max(0.02, cutoff))
        let reach = Double(half) / fc
        let start = max(0, Int((pos - reach).rounded(.up)))
        let end = min(count - 1, Int((pos + reach).rounded(.down)))
        guard start <= end else { return 0 }
        let limit = half * oversample
        let scale = fc * Double(oversample)
        var sum: Float = 0
        var i = start
        while i <= end {
            let t = abs(pos - Double(i)) * scale
            let k = Int(t)
            if k < limit {
                let f = Float(t - Double(k))
                sum += x[i] * (kernel[k] + (kernel[k + 1] - kernel[k]) * f)
            }
            i += 1
        }
        return sum * Float(fc)
    }

    /// Reads every channel of `pcm` at the positions `position(o)` for `o` in `0..<outFrames`. The cutoff
    /// follows the local speed: a stretch of two source frames per output frame filters at half the band.
    static func resample(_ pcm: PCMBuffer, outFrames: Int, position: (Double) -> Double) -> PCMBuffer {
        let out = PCMBuffer(channels: pcm.channels, frames: max(1, outFrames), sampleRate: pcm.sampleRate)
        guard outFrames > 0 else { return out }
        table.withUnsafeBufferPointer { kernel in
            let k = kernel.baseAddress!
            var previous = position(0)
            for o in 0..<outFrames {
                let pos = previous
                let next = position(Double(o + 1))
                let speed = abs(next - pos)
                let cutoff = speed > 1 ? 0.97 / speed : 1
                for c in 0..<pcm.channels {
                    out.mutableChannel(c)[o] = read(pcm.channel(c), count: pcm.frames, at: pos, cutoff: cutoff, kernel: k)
                }
                previous = next
            }
        }
        return out
    }
}
