import Accelerate
import LoopStudioEngine
import SwiftUI

/// A waveform at every zoom, like Live's overview data: the lowest and the highest sample of every 32
/// frames, then each level four times coarser. A pixel column reads the level that fits its width, and
/// below one bin it reads the samples themselves. About 2 MB for two minutes of audio; it is made from the
/// decoded audio in a few milliseconds, so it needs no file of its own.
final class WavePeaks: @unchecked Sendable {
    let pcm: PCMBuffer
    private var mins: [[Float]] = [], maxs: [[Float]] = [], binFrames: [Int] = []
    static let base = 32

    init(_ pcm: PCMBuffer) {
        self.pcm = pcm
        let n = pcm.frames, bins = max(1, (n + Self.base - 1) / Self.base)
        var lo = [Float](repeating: 0, count: bins), hi = [Float](repeating: 0, count: bins)
        for c in 0..<max(1, min(2, pcm.channels)) where n > 0 {
            let x = pcm.channel(c)
            for b in 0..<bins {
                let from = b * Self.base, count = min(n, from + Self.base) - from
                guard count > 0 else { continue }
                var mn: Float = 0, mx: Float = 0
                vDSP_minv(x + from, 1, &mn, vDSP_Length(count))
                vDSP_maxv(x + from, 1, &mx, vDSP_Length(count))
                if c == 0 { lo[b] = mn; hi[b] = mx } else { lo[b] = min(lo[b], mn); hi[b] = max(hi[b], mx) }
            }
        }
        mins = [lo]; maxs = [hi]; binFrames = [Self.base]
        while let l = mins.last, l.count > 64, let h = maxs.last {
            let count = (l.count + 3) / 4
            mins.append((0..<count).map { i in l[(i * 4)..<min(l.count, i * 4 + 4)].min() ?? 0 })
            maxs.append((0..<count).map { i in h[(i * 4)..<min(h.count, i * 4 + 4)].max() ?? 0 })
            binFrames.append(binFrames[binFrames.count - 1] * 4)
        }
    }

    /// The sample at a file position (0 to 1), between the frames and over the channels.
    func sample(at f: Double) -> Float {
        let n = pcm.frames
        guard n > 1 else { return 0 }
        let p = min(Double(n - 1), max(0, f * Double(n)))
        let i = Int(p), j = min(n - 1, i + 1), t = Float(p - Double(i))
        var s: Float = 0
        let channels = max(1, min(2, pcm.channels))
        for c in 0..<channels { let x = pcm.channel(c); s += x[i] + (x[j] - x[i]) * t }
        return s / Float(channels)
    }

    /// The lowest and the highest sample between two file positions (0 to 1).
    func range(_ f0: Double, _ f1: Double) -> (min: Float, max: Float) {
        let n = Double(pcm.frames)
        let a = max(0, min(f0, f1) * n), b = min(n, max(f0, f1) * n)
        guard pcm.frames > 0, b > a else { let v = sample(at: f0); return (v, v) }
        if b - a < Double(Self.base) {
            var mn = Float.infinity, mx = -Float.infinity
            let i0 = Int(a), i1 = min(pcm.frames, max(i0 + 1, Int(b.rounded(.up))))
            for c in 0..<max(1, min(2, pcm.channels)) {
                let x = pcm.channel(c)
                for i in i0..<i1 { mn = min(mn, x[i]); mx = max(mx, x[i]) }
            }
            return (mn, mx)
        }
        var k = 0
        while k + 1 < binFrames.count && Double(binFrames[k + 1]) <= b - a { k += 1 }
        let size = Double(binFrames[k])
        let i0 = Int(a / size), i1 = min(mins[k].count, max(i0 + 1, Int((b / size).rounded(.up))))
        guard i0 < i1 else { return (0, 0) }
        var mn = Float.infinity, mx = -Float.infinity
        for i in i0..<i1 { mn = min(mn, mins[k][i]); mx = max(mx, maxs[k][i]) }
        return (mn, mx)
    }

    /// Draws the waveform from `x0` to `x1` in one-point columns. `fileAt(x)` is the file position (0 to 1)
    /// at an x of the canvas: the clip's warp mapping. Where a sample is wider than a point the waveform is
    /// a line through the samples, and from 6 points per sample every sample gets a dot, like in Live.
    func draw(in ctx: GraphicsContext, from x0: CGFloat, to x1: CGFloat, mid: CGFloat, half: CGFloat, color: Color,
              fileAt: (CGFloat) -> Double) {
        let n = Double(pcm.frames)
        guard n > 0, x1 > x0 else { return }
        var bars = Path(), line = Path(), dots = Path()
        var lineOpen = false
        var x = floor(x0)
        while x < x1 {
            let f = fileAt(x)
            var g = fileAt(x + 1)
            if g < f { g = 1 }   // a looping clip wraps to the file start in this column
            defer { x += 1 }
            guard f >= 0, f < 1 else { lineOpen = false; continue }
            let perPoint = (g - f) * n
            if perPoint < 1 {
                // Samples wider than a point: a line through them.
                let y = mid - CGFloat(sample(at: f)) * half
                if lineOpen { line.addLine(to: CGPoint(x: x, y: y)) } else { line.move(to: CGPoint(x: x, y: y)); lineOpen = true }
                if perPoint > 0, perPoint <= 1.0 / 6 {
                    let first = (f * n).rounded(.up), last = g * n
                    var s = first
                    while s < last {
                        let dx = x + CGFloat((s - f * n) / perPoint)
                        let dy = mid - CGFloat(sample(at: s / n)) * half
                        dots.addEllipse(in: CGRect(x: dx - 2, y: dy - 2, width: 4, height: 4))
                        s += 1
                    }
                }
            } else {
                lineOpen = false
                let r = range(f, min(1, g))
                let top = mid - CGFloat(r.max) * half, bottom = mid - CGFloat(r.min) * half
                bars.addRect(CGRect(x: x, y: top, width: 1, height: max(1, bottom - top)))
            }
        }
        ctx.fill(bars, with: .color(color))
        ctx.stroke(line, with: .color(color), lineWidth: 1.2)
        ctx.fill(dots, with: .color(color))
    }
}
