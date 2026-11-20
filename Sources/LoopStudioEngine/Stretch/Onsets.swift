import Accelerate
import Foundation

/// Transient detection. The onset strength is the spectral flux: how much the log magnitude spectrum rises
/// from one frame to the next, summed over the bins. A peak of it that stands out from its neighbourhood is
/// an onset; a search in the waveform then finds the frame where the attack starts.
public enum Onsets {
    /// FFT length and hop at 48 kHz; other rates scale them to the nearest power of two.
    static func sizes(rate: Double) -> (fft: Int, hop: Int) {
        let fft = rate > 64_000 ? 2048 : 1024
        return (fft, fft / 4)
    }

    /// The flux below which nothing counts as an onset.
    /// Measured with the 1024-point frame: a held sine peaks at 17 (30 Hz, longer than the frame), 5 at
    /// 110 Hz, 2 at 440 Hz; an attack at -40 dB from silence at about 100, a loud click at about 500.
    static let minimumFlux: Float = 40

    /// The onset strength, one value per hop, normalized so the strongest is 1. All zero for a steady sound.
    public static func strength(_ pcm: PCMBuffer) -> (values: [Float], hop: Int) {
        var (out, hop) = rawFlux(pcm)
        let count = out.count
        // A steady sound (a held sine) changes only by leakage from frame to frame; normalized to its own
        // peak that would look like onsets. A real attack raises the sum by far more than this floor.
        let peak = out.max() ?? 0
        guard peak >= minimumFlux else { return ([Float](repeating: 0, count: count), hop) }
        var scale = 1 / peak
        out.withUnsafeMutableBufferPointer { o in vDSP_vsmul(o.baseAddress!, 1, &scale, o.baseAddress!, 1, vDSP_Length(count)) }
        return (out, hop)
    }

    /// The spectral flux per hop, not normalized.
    static func rawFlux(_ pcm: PCMBuffer) -> (values: [Float], hop: Int) {
        let (n, hop) = sizes(rate: pcm.sampleRate)
        let frames = pcm.frames
        guard frames > n else { return ([], hop) }
        let count = (frames - n) / hop + 1
        let log2n = vDSP_Length(Int(log2(Double(n))))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return ([], hop) }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        // A mono mix: onsets in any channel count.
        var mono = [Float](repeating: 0, count: frames)
        mono.withUnsafeMutableBufferPointer { m in
            for c in 0..<pcm.channels {
                vDSP_vadd(m.baseAddress!, 1, pcm.channel(c), 1, m.baseAddress!, 1, vDSP_Length(frames))
            }
        }
        var frame = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: n / 2), imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        var previous = [Float](repeating: 0, count: n / 2)
        var out = [Float](repeating: 0, count: count)
        let bins = n / 2
        let lowBin = max(1, Int((80 / (pcm.sampleRate / Double(n))).rounded(.up)))
        for f in 0..<count {
            mono.withUnsafeBufferPointer { m in
                vDSP_vmul(m.baseAddress! + f * hop, 1, window, 1, &frame, 1, vDSP_Length(n))
            }
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(bins))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(bins))
                }
            }
            var flux: Float = 0
            // From 80 Hz: below it a held deep tone beats with its mirror image from frame to frame, and an
            // attack always reaches higher. (Bin 0 also holds the Nyquist bin.)
            for b in lowBin..<bins {
                let v = log1pf(mags[b] * 10)
                let rise = v - previous[b]
                if rise > 0 { flux += rise }
                previous[b] = v
            }
            out[f] = f == 0 ? 0 : flux
        }
        return (out, hop)
    }

    /// The frames where transients start, rising. `sensitivity` 0...1: higher finds softer ones.
    public static func detect(_ pcm: PCMBuffer, sensitivity: Double = 0.5) -> [Int] {
        let (values, hop) = strength(pcm)
        guard values.count > 3 else { return [] }
        let n = sizes(rate: pcm.sampleRate).fft
        let delta = Float(0.12 - 0.1 * min(1, max(0, sensitivity)))
        let near = 3, wide = 16
        let minGap = Int(0.03 * pcm.sampleRate)
        var picked: [Int] = []
        for i in 1..<(values.count - 1) {
            let v = values[i]
            guard v > delta else { continue }
            let lo = max(0, i - near), hi = min(values.count - 1, i + near)
            var isPeak = true
            for j in lo...hi where j != i && (values[j] > v || (values[j] == v && j < i)) { isPeak = false; break }
            guard isPeak else { continue }
            let wlo = max(0, i - wide), whi = min(values.count - 1, i + near)
            var mean: Float = 0
            for j in wlo...whi { mean += values[j] }
            mean /= Float(whi - wlo + 1)
            guard v >= mean + delta else { continue }
            // The flux rises in the frame whose window first holds the attack: the attack lies in the
            // window's later half. The waveform search finds where it starts.
            let center = i * hop + n / 2
            let frame = refine(pcm, around: center, reach: n / 2 + hop)
            if let last = picked.last, frame - last < minGap { continue }
            picked.append(frame)
        }
        return picked
    }

    /// The start of the attack near `around`: the 32-frame block whose energy rises most over the blocks
    /// before it, then back to where the rise begins.
    static func refine(_ pcm: PCMBuffer, around center: Int, reach: Int) -> Int {
        let block = 32
        let start = max(0, center - reach - 4 * block)
        let end = min(pcm.frames, center + reach)
        let blocks = (end - start) / block
        guard blocks > 6 else { return max(0, min(pcm.frames - 1, center)) }
        var energy = [Float](repeating: 0, count: blocks)
        for c in 0..<pcm.channels {
            let x = pcm.channel(c)
            for b in 0..<blocks {
                var e: Float = 0
                vDSP_svesq(x + start + b * block, 1, &e, vDSP_Length(block))
                energy[b] += e
            }
        }
        var best = 4, bestRise = -Float.infinity
        for b in 4..<blocks {
            let before = (energy[b - 4] + energy[b - 3] + energy[b - 2] + energy[b - 1]) / 4
            let rise = energy[b] - before
            if rise > bestRise { bestRise = rise; best = b }
        }
        // Step back over blocks that already rise, to the quiet before the attack.
        var b = best
        let floor = energy[max(0, best - 4)...best].min() ?? 0
        while b > 0 && energy[b - 1] > floor * 1.5 + 1e-12 && energy[b - 1] < energy[b] { b -= 1 }
        return start + b * block
    }
}
