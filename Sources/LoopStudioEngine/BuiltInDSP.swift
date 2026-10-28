import Foundation
import LoopStudioCore

/// A built-in effect. `process` works in place on one stereo block and uses only memory from `init`.
/// `configure` writes plain numbers and allocates nothing. Once an effect has run, only the audio thread
/// calls it (for automation, and for the knob values of a new renderer on its first block).
public class DSPEffect: @unchecked Sendable {
    public let sampleRate: Double
    let spec: EffectSpec

    /// True while a knob follows the song tempo or an LFO runs. The renderer then calls `clock` at every
    /// grid step. Set in `configure`, so an effect without sync runs in whole blocks.
    var followsTempo = false
    /// Seconds per quarter note at the current grid step. Set by `clock`.
    private(set) var quarterSeconds = 0.5

    init(spec: EffectSpec, sampleRate: Double) {
        self.spec = spec
        self.sampleRate = sampleRate
    }

    func value(_ p: [String: Double], _ key: String) -> Float {
        let param = spec.params.first { $0.key == key }!
        return Float(param.clamp(p[key] ?? param.def))
    }

    /// The note value of a syncable knob in quarter notes, or `nil` when the knob is free.
    func syncedQuarters(_ p: [String: Double], _ key: String) -> Double? {
        guard let param = spec.params.first(where: { $0.key == key }), param.syncable,
              value(p, param.syncKey) >= 0.5 else { return nil }
        return NoteDivision.at(Double(value(p, param.divisionKey))).quarters
    }

    /// The song position for one grid step: `frame` on the timeline, `beat` in quarter notes, and the tempo.
    /// Only the audio thread calls it, before `process`. An effect that follows the tempo overrides `tempoChanged`
    /// or `step`.
    func clock(frame: Int64, beat: Double, quarterSeconds q: Double) {
        if q != quarterSeconds { quarterSeconds = q; tempoChanged() }
        step(frame: frame, beat: beat)
    }

    func tempoChanged() {}
    func step(frame: Int64, beat: Double) {}

    public func configure(_ params: [String: Double]) {}
    public func reset() {}
    public func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {}

    public static func make(_ id: String, sampleRate: Double) -> DSPEffect? {
        guard let spec = BuiltInEffects.spec(id) else { return nil }
        let effect: DSPEffect
        switch id {
        case "utility": effect = UtilityDSP(spec: spec, sampleRate: sampleRate)
        case "filter": effect = FilterDSP(spec: spec, sampleRate: sampleRate)
        case "eq3": effect = EQ3DSP(spec: spec, sampleRate: sampleRate)
        case "delay": effect = DelayDSP(spec: spec, sampleRate: sampleRate)
        case "reverb": effect = ReverbDSP(spec: spec, sampleRate: sampleRate)
        case "compressor": effect = CompressorDSP(spec: spec, sampleRate: sampleRate)
        case "limiter": effect = LimiterDSP(spec: spec, sampleRate: sampleRate)
        default: return nil
        }
        effect.configure([:])
        return effect
    }
}

@inline(__always) private func dbToLinear(_ db: Float) -> Float { powf(10, db / 20) }

// MARK: Utility

final class UtilityDSP: DSPEffect, @unchecked Sendable {
    private var gain: Float = 1
    private var width: Float = 1

    override func configure(_ p: [String: Double]) {
        let g = value(p, "gain")
        gain = g <= -96 ? 0 : dbToLinear(g)
        width = value(p, "width")
    }

    override func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        let g = gain, w = width
        for i in 0..<frames {
            let m = (l[i] + r[i]) * 0.5, s = (l[i] - r[i]) * 0.5 * w
            l[i] = (m + s) * g
            r[i] = (m - s) * g
        }
    }
}

// MARK: Biquad

struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0

    @inline(__always) mutating func tick(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func reset() { z1 = 0; z2 = 0 }

    mutating func set(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = Float(b0 / a0); self.b1 = Float(b1 / a0); self.b2 = Float(b2 / a0)
        self.a1 = Float(a1 / a0); self.a2 = Float(a2 / a0)
    }

    // RBJ audio EQ cookbook.
    mutating func lowpass(_ f: Double, q: Double, rate: Double) {
        let w = 2 * .pi * min(f, rate * 0.45) / rate, c = cos(w), a = sin(w) / (2 * q)
        set(b0: (1 - c) / 2, b1: 1 - c, b2: (1 - c) / 2, a0: 1 + a, a1: -2 * c, a2: 1 - a)
    }
    mutating func highpass(_ f: Double, q: Double, rate: Double) {
        let w = 2 * .pi * min(f, rate * 0.45) / rate, c = cos(w), a = sin(w) / (2 * q)
        set(b0: (1 + c) / 2, b1: -(1 + c), b2: (1 + c) / 2, a0: 1 + a, a1: -2 * c, a2: 1 - a)
    }
    mutating func bandpass(_ f: Double, q: Double, rate: Double) {
        let w = 2 * .pi * min(f, rate * 0.45) / rate, c = cos(w), a = sin(w) / (2 * q)
        set(b0: a, b1: 0, b2: -a, a0: 1 + a, a1: -2 * c, a2: 1 - a)
    }
    mutating func peaking(_ f: Double, gainDb: Double, q: Double, rate: Double) {
        let A = pow(10, gainDb / 40), w = 2 * .pi * min(f, rate * 0.45) / rate, c = cos(w), a = sin(w) / (2 * q)
        set(b0: 1 + a * A, b1: -2 * c, b2: 1 - a * A, a0: 1 + a / A, a1: -2 * c, a2: 1 - a / A)
    }
    mutating func lowShelf(_ f: Double, gainDb: Double, rate: Double) {
        let A = pow(10, gainDb / 40), w = 2 * .pi * f / rate, c = cos(w), s = sin(w)
        let alpha = s / 2 * sqrt(2.0), t = 2 * sqrt(A) * alpha
        set(b0: A * ((A + 1) - (A - 1) * c + t), b1: 2 * A * ((A - 1) - (A + 1) * c), b2: A * ((A + 1) - (A - 1) * c - t),
            a0: (A + 1) + (A - 1) * c + t, a1: -2 * ((A - 1) + (A + 1) * c), a2: (A + 1) + (A - 1) * c - t)
    }
    mutating func highShelf(_ f: Double, gainDb: Double, rate: Double) {
        let A = pow(10, gainDb / 40), w = 2 * .pi * f / rate, c = cos(w), s = sin(w)
        let alpha = s / 2 * sqrt(2.0), t = 2 * sqrt(A) * alpha
        set(b0: A * ((A + 1) + (A - 1) * c + t), b1: -2 * A * ((A - 1) + (A + 1) * c), b2: A * ((A + 1) + (A - 1) * c - t),
            a0: (A + 1) - (A - 1) * c + t, a1: 2 * ((A - 1) - (A + 1) * c), a2: (A + 1) - (A - 1) * c - t)
    }
}

final class FilterDSP: DSPEffect, @unchecked Sendable {
    private var left = Biquad(), right = Biquad()
    private var type = 0, cutoff = 1_000.0, q = 0.707
    private var lfoAmount = 0.0, lfoHz = 1.0
    private var lfoQuarters: Double?
    /// The free LFO's phase, carried from grid step to grid step, so a rate change does not jump.
    private var lfoPhase = 0.0, lfoFrame = Int64.min

    override func configure(_ p: [String: Double]) {
        type = Int(value(p, "type"))
        cutoff = Double(value(p, "cutoff")); q = Double(value(p, "resonance"))
        lfoAmount = Double(value(p, "lfoAmount")); lfoHz = Double(value(p, "lfoRate"))
        lfoQuarters = syncedQuarters(p, "lfoRate")
        followsTempo = lfoAmount > 0
        design(cutoff)
    }

    /// The LFO position comes from the song position, never from a running counter. So a synced LFO sits on
    /// the beat, and an export sounds exactly like the playback.
    override func step(frame: Int64, beat: Double) {
        guard lfoAmount > 0 else { return }
        let phase: Double
        if let q = lfoQuarters {
            phase = beat / q
        } else {
            // One grid step on: add this step's share. After a jump, start from the absolute frame.
            lfoPhase = frame == lfoFrame + 32 ? lfoPhase + 32 / sampleRate * lfoHz : Double(frame) / sampleRate * lfoHz
            lfoPhase -= lfoPhase.rounded(.down)
            phase = lfoPhase
        }
        lfoFrame = frame
        let lfo = sin(2 * .pi * (phase - phase.rounded(.down)))
        design(min(20_000, max(20, cutoff * pow(2, 4 * lfoAmount * lfo))))
    }

    private func design(_ cutoff: Double) {
        var f = Biquad()
        switch type {
        case 1: f.highpass(cutoff, q: q, rate: sampleRate)
        case 2: f.bandpass(cutoff, q: q, rate: sampleRate)
        default: f.lowpass(cutoff, q: q, rate: sampleRate)
        }
        f.z1 = left.z1; f.z2 = left.z2
        var g = f
        g.z1 = right.z1; g.z2 = right.z2
        left = f; right = g
    }

    override func reset() { left.reset(); right.reset() }

    override func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        for i in 0..<frames { l[i] = left.tick(l[i]); r[i] = right.tick(r[i]) }
    }
}

final class EQ3DSP: DSPEffect, @unchecked Sendable {
    private var lowL = Biquad(), midL = Biquad(), highL = Biquad()
    private var lowR = Biquad(), midR = Biquad(), highR = Biquad()

    override func configure(_ p: [String: Double]) {
        var lo = Biquad(), mid = Biquad(), hi = Biquad()
        lo.lowShelf(250, gainDb: Double(value(p, "low")), rate: sampleRate)
        mid.peaking(Double(value(p, "midFreq")), gainDb: Double(value(p, "mid")), q: 0.8, rate: sampleRate)
        hi.highShelf(4_000, gainDb: Double(value(p, "high")), rate: sampleRate)
        func keep(_ new: Biquad, _ old: Biquad) -> Biquad { var n = new; n.z1 = old.z1; n.z2 = old.z2; return n }
        lowL = keep(lo, lowL); lowR = keep(lo, lowR)
        midL = keep(mid, midL); midR = keep(mid, midR)
        highL = keep(hi, highL); highR = keep(hi, highR)
    }

    override func reset() {
        lowL.reset(); midL.reset(); highL.reset(); lowR.reset(); midR.reset(); highR.reset()
    }

    override func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        for i in 0..<frames {
            l[i] = highL.tick(midL.tick(lowL.tick(l[i])))
            r[i] = highR.tick(midR.tick(lowR.tick(r[i])))
        }
    }
}

// MARK: Delay

final class DelayDSP: DSPEffect, @unchecked Sendable {
    private let size: Int
    private let bufL: UnsafeMutablePointer<Float>
    private let bufR: UnsafeMutablePointer<Float>
    private var write = 0
    private var target: Float = 0, current: Float = 0
    private var started = false
    private var feedback: Float = 0.4, mix: Float = 0.3, pingPong = true
    private var freeMs: Float = 375
    private var syncQuarters: Double?

    override init(spec: EffectSpec, sampleRate: Double) {
        // Room for a synced 1/1 (the longest note value offered) at 30 BPM.
        size = Int(sampleRate * 8.1) + 8
        bufL = .allocate(capacity: size); bufL.initialize(repeating: 0, count: size)
        bufR = .allocate(capacity: size); bufR.initialize(repeating: 0, count: size)
        super.init(spec: spec, sampleRate: sampleRate)
    }

    deinit { bufL.deallocate(); bufR.deallocate() }

    override func configure(_ p: [String: Double]) {
        freeMs = value(p, "timeMs")
        syncQuarters = syncedQuarters(p, "timeMs")
        followsTempo = syncQuarters != nil
        updateTarget()
        feedback = value(p, "feedback")
        mix = value(p, "mix")
        pingPong = value(p, "pingPong") >= 0.5
    }

    override func tempoChanged() { if syncQuarters != nil { updateTarget() } }

    /// A tempo change glides the time like a turned knob, so a tempo ramp does not click.
    private func updateTarget() {
        let seconds = syncQuarters.map { $0 * quarterSeconds } ?? Double(freeMs) / 1000
        target = Float(min(seconds * sampleRate, Double(size - 4)))
        if !started { current = target } // glide only once audio has run
    }

    override func reset() {
        bufL.update(repeating: 0, count: size); bufR.update(repeating: 0, count: size)
        current = target
    }

    @inline(__always) private func read(_ buf: UnsafeMutablePointer<Float>, _ delay: Float) -> Float {
        var pos = Float(write) - delay
        if pos < 0 { pos += Float(size) }
        let i0 = Int(pos) % size, i1 = (i0 + 1) % size
        let frac = pos - floorf(pos)
        return buf[i0] * (1 - frac) + buf[i1] * frac
    }

    override func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        started = true
        let fb = feedback, m = mix, pp = pingPong
        for i in 0..<frames {
            current += (target - current) * 0.002 // glide, so turning the time knob does not click
            let wl = read(bufL, current), wr = read(bufR, current)
            let inL = l[i], inR = r[i]
            bufL[write] = inL + fb * (pp ? wr : wl)
            bufR[write] = inR + fb * (pp ? wl : wr)
            write += 1
            if write >= size { write = 0 }
            l[i] = inL * (1 - m) + wl * m
            r[i] = inR * (1 - m) + wr * m
        }
    }
}

// MARK: Reverb (Freeverb layout)

private struct Comb {
    var buf: UnsafeMutablePointer<Float>
    var size: Int
    var index = 0
    var store: Float = 0
}

private struct AllPass {
    var buf: UnsafeMutablePointer<Float>
    var size: Int
    var index = 0
}

final class ReverbDSP: DSPEffect, @unchecked Sendable {
    private static let combTunings = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    private static let allPassTunings = [556, 441, 341, 225]
    private static let spread = 23

    private let combs: UnsafeMutablePointer<Comb>   // 8 left, then 8 right
    private let allPasses: UnsafeMutablePointer<AllPass> // 4 left, then 4 right
    private var feedback: Float = 0.8, damp: Float = 0.2, mix: Float = 0.25
    /// The pre-delay: the wet sound starts this many frames after the dry sound.
    private let preSize: Int
    private let preBuf: UnsafeMutablePointer<Float>
    private var preWrite = 0, preFrames = 0
    private var preFreeMs: Float = 0
    private var preQuarters: Double?

    override init(spec: EffectSpec, sampleRate: Double) {
        let scale = sampleRate / 44_100
        preSize = Int(sampleRate * 2) + 2
        preBuf = .allocate(capacity: preSize); preBuf.initialize(repeating: 0, count: preSize)
        combs = .allocate(capacity: 16)
        allPasses = .allocate(capacity: 8)
        func line(_ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            return p
        }
        for side in 0..<2 {
            for (i, t) in Self.combTunings.enumerated() {
                let n = max(8, Int(Double(t + side * Self.spread) * scale))
                (combs + side * 8 + i).initialize(to: Comb(buf: line(n), size: n))
            }
            for (i, t) in Self.allPassTunings.enumerated() {
                let n = max(8, Int(Double(t + side * Self.spread) * scale))
                (allPasses + side * 4 + i).initialize(to: AllPass(buf: line(n), size: n))
            }
        }
        super.init(spec: spec, sampleRate: sampleRate)
    }

    deinit {
        for i in 0..<16 { combs[i].buf.deallocate() }
        for i in 0..<8 { allPasses[i].buf.deallocate() }
        combs.deallocate(); allPasses.deallocate(); preBuf.deallocate()
    }

    override func configure(_ p: [String: Double]) {
        feedback = value(p, "size") * 0.28 + 0.7
        damp = value(p, "damping") * 0.4
        mix = value(p, "mix")
        preFreeMs = value(p, "preDelayMs")
        preQuarters = syncedQuarters(p, "preDelayMs")
        followsTempo = preQuarters != nil
        updatePreDelay()
    }

    override func tempoChanged() { if preQuarters != nil { updatePreDelay() } }

    private func updatePreDelay() {
        let seconds = preQuarters.map { $0 * quarterSeconds } ?? Double(preFreeMs) / 1000
        preFrames = min(Int((seconds * sampleRate).rounded()), preSize - 1)
    }

    override func reset() {
        preBuf.update(repeating: 0, count: preSize)
        for i in 0..<16 { combs[i].buf.update(repeating: 0, count: combs[i].size); combs[i].store = 0 }
        for i in 0..<8 { allPasses[i].buf.update(repeating: 0, count: allPasses[i].size) }
    }

    override func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        let fb = feedback, d = damp, m = mix, pre = preFrames
        for i in 0..<frames {
            var input = (l[i] + r[i]) * 0.015
            // The line always runs, so turning the pre-delay on later does not replay old sound.
            preBuf[preWrite] = input
            if pre > 0 {
                var read = preWrite - pre
                if read < 0 { read += preSize }
                input = preBuf[read]
            }
            preWrite += 1
            if preWrite >= preSize { preWrite = 0 }
            var outL: Float = 0, outR: Float = 0
            for k in 0..<8 {
                outL += step(&combs[k], input, fb, d)
                outR += step(&combs[8 + k], input, fb, d)
            }
            for k in 0..<4 {
                outL = step(&allPasses[k], outL)
                outR = step(&allPasses[4 + k], outR)
            }
            l[i] = l[i] * (1 - m) + outL * 3 * m
            r[i] = r[i] * (1 - m) + outR * 3 * m
        }
    }

    @inline(__always) private func step(_ c: inout Comb, _ x: Float, _ fb: Float, _ d: Float) -> Float {
        let out = c.buf[c.index]
        c.store = out * (1 - d) + c.store * d
        c.buf[c.index] = x + c.store * fb
        c.index += 1
        if c.index >= c.size { c.index = 0 }
        return out
    }

    @inline(__always) private func step(_ a: inout AllPass, _ x: Float) -> Float {
        let buffered = a.buf[a.index]
        let out = buffered - x
        a.buf[a.index] = x + buffered * 0.5
        a.index += 1
        if a.index >= a.size { a.index = 0 }
        return out
    }
}

// MARK: Dynamics

final class CompressorDSP: DSPEffect, @unchecked Sendable {
    private var threshold: Float = -18, ratio: Float = 4, makeup: Float = 1
    private var attack: Float = 0.01, release: Float = 0.001
    private var env: Float = 0

    override func configure(_ p: [String: Double]) {
        threshold = value(p, "threshold")
        ratio = value(p, "ratio")
        makeup = dbToLinear(value(p, "makeup"))
        attack = 1 - expf(-1 / (value(p, "attack") * 0.001 * Float(sampleRate)))
        release = 1 - expf(-1 / (value(p, "release") * 0.001 * Float(sampleRate)))
    }

    override func reset() { env = 0 }

    override func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        let slope = 1 - 1 / ratio
        for i in 0..<frames {
            let level = max(abs(l[i]), abs(r[i]))
            env += (level - env) * (level > env ? attack : release)
            let db = 20 * log10f(max(env, 1e-6))
            let over = db - threshold
            let gain = (over > 0 ? dbToLinear(-over * slope) : 1) * makeup
            l[i] *= gain; r[i] *= gain
        }
    }
}

final class LimiterDSP: DSPEffect, @unchecked Sendable {
    private var inGain: Float = 1, ceiling: Float = 0.97, release: Float = 0.001
    private var gain: Float = 1

    override func configure(_ p: [String: Double]) {
        inGain = dbToLinear(value(p, "gain"))
        ceiling = dbToLinear(value(p, "ceiling"))
        release = 1 - expf(-1 / (value(p, "release") * 0.001 * Float(sampleRate)))
    }

    override func reset() { gain = 1 }

    override func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        for i in 0..<frames {
            let a = l[i] * inGain, b = r[i] * inGain
            let peak = max(abs(a), abs(b))
            let want = peak > ceiling ? ceiling / peak : 1
            if want < gain { gain = want } else { gain += (want - gain) * release }
            // The gain is already at or below `want` here, so the output never passes the ceiling.
            l[i] = a * min(gain, want); r[i] = b * min(gain, want)
        }
    }
}
