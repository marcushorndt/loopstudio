import Foundation
import LoopStudioCore

@inline(__always) private func dbToLinear(_ db: Float) -> Float { powf(10, db / 20) }
@inline(__always) private func linearToDb(_ x: Float) -> Float { 20 * log10f(max(x, 1e-6)) }

/// One compressor's gain computer and envelope: the part the compressor and each band of the multiband share.
struct GainComputer {
    var threshold: Float = -18, slope: Float = 0.75, knee: Float = 6
    var attack: Float = 0.01, release: Float = 0.001
    var env: Float = 0

    mutating func configure(threshold: Float, ratio: Float, knee: Float, attackMs: Float, releaseMs: Float, rate: Float) {
        self.threshold = threshold
        slope = 1 - 1 / max(ratio, 1)
        self.knee = knee
        attack = 1 - expf(-1 / (max(attackMs, 0.01) * 0.001 * rate))
        release = 1 - expf(-1 / (max(releaseMs, 1) * 0.001 * rate))
    }

    /// The gain reduction in dB for a detector level (linear), after the envelope.
    @inline(__always) mutating func reductionDb(level: Float) -> Float {
        env += (level - env) * (level > env ? attack : release)
        let over = linearToDb(env) - threshold
        if knee > 0, abs(over) <= knee / 2 {
            let x = over + knee / 2
            return slope * x * x / (2 * knee)
        }
        return over > 0 ? slope * over : 0
    }

    mutating func reset() { env = 0 }
}

/// A compressor with a soft knee, a parallel mix and a sidechain input with its own low cut.
final class CompressorDSP: DSPEffect, @unchecked Sendable {
    private var computer = GainComputer()
    private var makeup: Float = 1, mix: Float = 1
    private var scCut = false
    private var scL = Biquad(), scR = Biquad()

    override func configure(_ p: [String: Double]) {
        computer.configure(threshold: value(p, "threshold"), ratio: value(p, "ratio"), knee: value(p, "knee"),
                           attackMs: value(p, "attack"), releaseMs: value(p, "release"), rate: Float(sampleRate))
        makeup = dbToLinear(value(p, "makeup"))
        mix = value(p, "mix")
        let cut = Double(value(p, "scLowCut"))
        scCut = cut > 25
        if scCut {
            var f = Biquad()
            f.highpass(cut, q: 0.707, rate: sampleRate)
            f.z1 = scL.z1; f.z2 = scL.z2; scL = f
            f.z1 = scR.z1; f.z2 = scR.z2; scR = f
        }
    }

    override func reset() { computer.reset(); scL.reset(); scR.reset(); meters[0] = 0 }

    override func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        process(l, r, sidechainL: nil, sidechainR: nil, frames: frames)
    }

    override func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>,
                          sidechainL: UnsafePointer<Float>?, sidechainR: UnsafePointer<Float>?, frames: Int) {
        let m = mix, mk = makeup, cut = scCut
        var worst: Float = 0
        for i in 0..<frames {
            var a = sidechainL?[i] ?? l[i], b = sidechainR?[i] ?? r[i]
            if cut { a = scL.tick(a); b = scR.tick(b) }
            let reduction = computer.reductionDb(level: max(abs(a), abs(b)))
            if reduction > worst { worst = reduction }
            let gain = dbToLinear(-reduction) * mk
            l[i] = l[i] * (1 - m) + l[i] * gain * m
            r[i] = r[i] * (1 - m) + r[i] * gain * m
        }
        meters[0] = worst
    }
}

/// A brick-wall limiter with look-ahead: the input waits in a short line while the gain already moves
/// down for the peak that is coming, so nothing passes the ceiling and nothing clicks.
final class LimiterDSP: DSPEffect, @unchecked Sendable {
    private var inGain: Float = 1, ceiling: Float = 0.97, release: Float = 0.001
    private var gain: Float = 1
    /// The delay line of the input and the sliding window of wanted gains, both `lookahead` + 1 long.
    private let capacity: Int
    private let lineL: UnsafeMutablePointer<Float>, lineR: UnsafeMutablePointer<Float>
    private var linePos = 0
    private var lookahead = 0
    /// A monotonic queue of (wanted gain, sample index): the front is the smallest gain in the window.
    private let queueGain: UnsafeMutablePointer<Float>, queueIndex: UnsafeMutablePointer<Int64>
    private var head = 0, tail = 0
    private var sample: Int64 = 0

    override init(spec: EffectSpec, sampleRate: Double) {
        capacity = Int(0.010 * sampleRate) + 2
        lineL = .allocate(capacity: capacity); lineL.initialize(repeating: 0, count: capacity)
        lineR = .allocate(capacity: capacity); lineR.initialize(repeating: 0, count: capacity)
        queueGain = .allocate(capacity: capacity); queueGain.initialize(repeating: 1, count: capacity)
        queueIndex = .allocate(capacity: capacity); queueIndex.initialize(repeating: 0, count: capacity)
        super.init(spec: spec, sampleRate: sampleRate)
    }

    deinit { lineL.deallocate(); lineR.deallocate(); queueGain.deallocate(); queueIndex.deallocate() }

    override func configure(_ p: [String: Double]) {
        inGain = dbToLinear(value(p, "gain"))
        ceiling = dbToLinear(value(p, "ceiling"))
        release = 1 - expf(-1 / (value(p, "release") * 0.001 * Float(sampleRate)))
        let want = min(capacity - 2, Int(value(p, "lookahead") * 0.001 * Float(sampleRate)))
        if want != lookahead { lookahead = want; reset() }
    }

    override func reset() {
        gain = 1
        lineL.update(repeating: 0, count: capacity); lineR.update(repeating: 0, count: capacity)
        linePos = 0; head = 0; tail = 0; sample = 0
        meters[0] = 0
    }

    override func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        let n = lookahead
        var worst: Float = 1
        for i in 0..<frames {
            let a = l[i] * inGain, b = r[i] * inGain
            let peak = max(abs(a), abs(b))
            let want = peak > ceiling ? ceiling / peak : 1
            // The window: the smallest wanted gain of the last `n` + 1 samples, in O(1) per sample.
            while tail != head {
                let last = (tail + capacity - 1) % capacity
                if queueGain[last] >= want { tail = last } else { break }
            }
            queueGain[tail] = want; queueIndex[tail] = sample
            tail = (tail + 1) % capacity
            if queueIndex[head] < sample - Int64(n) { head = (head + 1) % capacity }
            let floor = queueGain[head]
            // Down at once (the look-ahead made it early), up with the release.
            if floor < gain { gain = floor } else { gain += (floor - gain) * release }
            if gain < worst { worst = gain }
            // The input leaves the line `n` samples late.
            let outL = lineL[linePos], outR = lineR[linePos]
            lineL[linePos] = a; lineR[linePos] = b
            linePos += 1
            if linePos >= n { linePos = 0 }
            if n == 0 {
                l[i] = a * min(gain, want); r[i] = b * min(gain, want)
            } else {
                l[i] = outL * gain; r[i] = outR * gain
            }
            sample += 1
        }
        meters[0] = -linearToDb(worst)
    }
}

/// A three-band compressor on Linkwitz-Riley crossovers. The low band passes the upper crossover's
/// all-pass too, so the three bands add up flat when nothing compresses.
final class MultibandDSP: DSPEffect, @unchecked Sendable {
    /// The crossover filters of one channel: 4th-order Linkwitz-Riley = two Butterworth sections each.
    private struct Split {
        var lo1 = Biquad(), lo2 = Biquad(), hi1 = Biquad(), hi2 = Biquad()
        var mlo1 = Biquad(), mlo2 = Biquad(), mhi1 = Biquad(), mhi2 = Biquad()
        // The all-pass for the low band at the upper crossover: its low-pass plus its high-pass.
        var ap1 = Biquad(), ap2 = Biquad(), ap3 = Biquad(), ap4 = Biquad()

        mutating func design(lowX: Double, highX: Double, rate: Double) {
            func keep(_ f: inout Biquad, _ design: (inout Biquad) -> Void) { var n = Biquad(); design(&n); n.z1 = f.z1; n.z2 = f.z2; f = n }
            keep(&lo1) { $0.butterworthLow(lowX, rate: rate) }; keep(&lo2) { $0.butterworthLow(lowX, rate: rate) }
            keep(&hi1) { $0.butterworthHigh(lowX, rate: rate) }; keep(&hi2) { $0.butterworthHigh(lowX, rate: rate) }
            keep(&mlo1) { $0.butterworthLow(highX, rate: rate) }; keep(&mlo2) { $0.butterworthLow(highX, rate: rate) }
            keep(&mhi1) { $0.butterworthHigh(highX, rate: rate) }; keep(&mhi2) { $0.butterworthHigh(highX, rate: rate) }
            keep(&ap1) { $0.butterworthLow(highX, rate: rate) }; keep(&ap2) { $0.butterworthLow(highX, rate: rate) }
            keep(&ap3) { $0.butterworthHigh(highX, rate: rate) }; keep(&ap4) { $0.butterworthHigh(highX, rate: rate) }
        }

        @inline(__always) mutating func split(_ x: Float) -> (low: Float, mid: Float, high: Float) {
            let low = lo2.tick(lo1.tick(x))
            let rest = hi2.tick(hi1.tick(x))
            let mid = mlo2.tick(mlo1.tick(rest))
            let high = mhi2.tick(mhi1.tick(rest))
            let lowAligned = ap2.tick(ap1.tick(low)) + ap4.tick(ap3.tick(low))
            return (lowAligned, mid, high)
        }

        mutating func reset() {
            lo1.reset(); lo2.reset(); hi1.reset(); hi2.reset(); mlo1.reset(); mlo2.reset(); mhi1.reset(); mhi2.reset()
            ap1.reset(); ap2.reset(); ap3.reset(); ap4.reset()
        }
    }

    private var splitL = Split(), splitR = Split(), scSplitL = Split(), scSplitR = Split()
    private var low = GainComputer(), mid = GainComputer(), high = GainComputer()
    private var gainLow: Float = 1, gainMid: Float = 1, gainHigh: Float = 1
    private var makeup: Float = 1, mix: Float = 1
    private var scCut = false
    private var scL = Biquad(), scR = Biquad()

    override func configure(_ p: [String: Double]) {
        let rate = Float(sampleRate)
        let lowX = Double(value(p, "lowX")), highX = max(Double(value(p, "highX")), lowX * 1.5)
        splitL.design(lowX: lowX, highX: highX, rate: sampleRate); splitR.design(lowX: lowX, highX: highX, rate: sampleRate)
        scSplitL.design(lowX: lowX, highX: highX, rate: sampleRate); scSplitR.design(lowX: lowX, highX: highX, rate: sampleRate)
        func band(_ c: inout GainComputer, _ key: String) {
            c.configure(threshold: value(p, "\(key).threshold"), ratio: value(p, "\(key).ratio"), knee: 6,
                        attackMs: value(p, "\(key).attack"), releaseMs: value(p, "\(key).release"), rate: rate)
        }
        band(&low, "low"); band(&mid, "mid"); band(&high, "high")
        gainLow = dbToLinear(value(p, "low.gain")); gainMid = dbToLinear(value(p, "mid.gain")); gainHigh = dbToLinear(value(p, "high.gain"))
        makeup = dbToLinear(value(p, "makeup"))
        mix = value(p, "mix")
        let cut = Double(value(p, "scLowCut"))
        scCut = cut > 25
        if scCut {
            var f = Biquad()
            f.highpass(cut, q: 0.707, rate: sampleRate)
            f.z1 = scL.z1; f.z2 = scL.z2; scL = f
            f.z1 = scR.z1; f.z2 = scR.z2; scR = f
        }
    }

    override func reset() {
        splitL.reset(); splitR.reset(); scSplitL.reset(); scSplitR.reset()
        low.reset(); mid.reset(); high.reset(); scL.reset(); scR.reset()
        meters[0] = 0; meters[1] = 0; meters[2] = 0; meters[3] = 0
    }

    override func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        process(l, r, sidechainL: nil, sidechainR: nil, frames: frames)
    }

    override func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>,
                          sidechainL: UnsafePointer<Float>?, sidechainR: UnsafePointer<Float>?, frames: Int) {
        let m = mix, mk = makeup, cut = scCut, external = sidechainL != nil && sidechainR != nil
        var worstLow: Float = 0, worstMid: Float = 0, worstHigh: Float = 0
        for i in 0..<frames {
            let a = splitL.split(l[i]), b = splitR.split(r[i])
            // The detector: the band of the sidechain (another track, or the own sound), through the low cut.
            let dl: (low: Float, mid: Float, high: Float), dr: (low: Float, mid: Float, high: Float)
            if external {
                var sa = sidechainL![i], sb = sidechainR![i]
                if cut { sa = scL.tick(sa); sb = scR.tick(sb) }
                dl = scSplitL.split(sa); dr = scSplitR.split(sb)
            } else if cut {
                dl = scSplitL.split(scL.tick(l[i])); dr = scSplitR.split(scR.tick(r[i]))
            } else {
                dl = a; dr = b
            }
            let rl = low.reductionDb(level: max(abs(dl.low), abs(dr.low)))
            let rm = mid.reductionDb(level: max(abs(dl.mid), abs(dr.mid)))
            let rh = high.reductionDb(level: max(abs(dl.high), abs(dr.high)))
            if rl > worstLow { worstLow = rl }
            if rm > worstMid { worstMid = rm }
            if rh > worstHigh { worstHigh = rh }
            let gl = dbToLinear(-rl) * gainLow, gm = dbToLinear(-rm) * gainMid, gh = dbToLinear(-rh) * gainHigh
            let wetL = (a.low * gl + a.mid * gm + a.high * gh) * mk
            let wetR = (b.low * gl + b.mid * gm + b.high * gh) * mk
            l[i] = l[i] * (1 - m) + wetL * m
            r[i] = r[i] * (1 - m) + wetR * m
        }
        meters[0] = worstLow; meters[1] = worstMid; meters[2] = worstHigh
        meters[3] = max(worstLow, max(worstMid, worstHigh))
        spectrum?.write(l, r, frames: frames)
    }
}
