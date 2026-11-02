import Foundation
import LoopStudioCore

/// A tape echo. The playback head reads the tape at the delay time, which moves slowly when the time knob
/// turns (the pitch bends like a varispeed motor), and wobbles with the motor's wow (slow) and flutter (fast).
/// The loop loses highs (Tone) and lows (Low Cut) with every pass and saturates like tape, so a feedback
/// above 1 sings instead of exploding.
final class TapeEchoDSP: DSPEffect, @unchecked Sendable {
    private let size: Int
    private let bufL: UnsafeMutablePointer<Float>
    private let bufR: UnsafeMutablePointer<Float>
    private var write = 0
    private var target: Float = 0, current: Float = 0
    private var started = false
    private var feedback: Float = 0.45, mix: Float = 0.3, spreadFrames: Float = 0
    private var wow: Float = 0, flutter: Float = 0, drive: Float = 0.3
    private var freeMs: Float = 375
    private var syncQuarters: Double?
    // The loop filters: one pole each, per channel.
    private var toneCo: Float = 0.3, lowCutCo: Float = 0.01
    private var lpL: Float = 0, lpR: Float = 0, hpL: Float = 0, hpR: Float = 0
    // The motor: two slow phases for the wow (so it never repeats exactly) and one fast for the flutter.
    private var wowPhase: Float = 0, wowPhase2: Float = 0.37, flutterPhase: Float = 0
    private var wowStep: Float = 0, wowStep2: Float = 0, flutterStep: Float = 0
    private var noise: UInt32 = 0x9E37_79B9, noiseLow: Float = 0

    override init(spec: EffectSpec, sampleRate: Double) {
        // Room for a synced 1/1 (the longest note value offered) at 30 BPM, plus the wobble.
        size = Int(sampleRate * 8.1) + 64
        bufL = .allocate(capacity: size); bufL.initialize(repeating: 0, count: size)
        bufR = .allocate(capacity: size); bufR.initialize(repeating: 0, count: size)
        super.init(spec: spec, sampleRate: sampleRate)
        let rate = Float(sampleRate)
        wowStep = 0.6 / rate; wowStep2 = 0.23 / rate; flutterStep = 7.3 / rate
    }

    deinit { bufL.deallocate(); bufR.deallocate() }

    override func configure(_ p: [String: Double]) {
        freeMs = value(p, "timeMs")
        syncQuarters = syncedQuarters(p, "timeMs")
        followsTempo = syncQuarters != nil
        updateTarget()
        feedback = value(p, "feedback")
        mix = value(p, "mix")
        wow = value(p, "wow")
        flutter = value(p, "flutter")
        drive = value(p, "drive")
        spreadFrames = value(p, "spread") * 0.025 * Float(sampleRate)
        toneCo = 1 - expf(-2 * .pi * value(p, "tone") / Float(sampleRate))
        lowCutCo = 1 - expf(-2 * .pi * value(p, "lowCut") / Float(sampleRate))
    }

    override func tempoChanged() { if syncQuarters != nil { updateTarget() } }

    private func updateTarget() {
        let seconds = syncQuarters.map { $0 * quarterSeconds } ?? Double(freeMs) / 1000
        // Room for the whole wobble (wow and flutter at full) behind the longest time.
        let headroom = 0.009 * sampleRate + 8
        target = Float(min(seconds * sampleRate, Double(size) - headroom))
        if !started { current = target }
    }

    override func reset() {
        bufL.update(repeating: 0, count: size); bufR.update(repeating: 0, count: size)
        current = target
        lpL = 0; lpR = 0; hpL = 0; hpR = 0
    }

    @inline(__always) private func read(_ buf: UnsafeMutablePointer<Float>, _ delay: Float) -> Float {
        var pos = Float(write) - min(max(1, delay), Float(size - 2))
        if pos < 0 { pos += Float(size) }
        let i0 = Int(pos) % size, i1 = (i0 + 1) % size
        let frac = pos - floorf(pos)
        return buf[i0] * (1 - frac) + buf[i1] * frac
    }

    /// Tape saturation: soft, and unity for small signals.
    @inline(__always) private func saturate(_ x: Float, _ k: Float, _ norm: Float) -> Float { tanhf(x * k) * norm }

    override func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        started = true
        let fb = feedback, m = mix, rate = Float(sampleRate)
        let k = 0.3 + 6 * drive, norm = 1 / tanhf(k)
        let wowDepth = wow * 0.004 * rate, flutterDepth = flutter * 0.0004 * rate
        let spread = spreadFrames
        for i in 0..<frames {
            // The motor: the head moves slowly to a new time (varispeed), and wobbles.
            current += (target - current) * 0.0006
            wowPhase += wowStep; if wowPhase >= 1 { wowPhase -= 1 }
            wowPhase2 += wowStep2; if wowPhase2 >= 1 { wowPhase2 -= 1 }
            flutterPhase += flutterStep; if flutterPhase >= 1 { flutterPhase -= 1 }
            noise = noise &* 1_664_525 &+ 1_013_904_223
            noiseLow += ((Float(noise >> 8) / 16_777_216 - 0.5) - noiseLow) * 0.0005
            let wobble = wowDepth * (0.7 * sinf(2 * .pi * wowPhase) + 0.3 * sinf(2 * .pi * wowPhase2) + noiseLow * 2)
                + flutterDepth * sinf(2 * .pi * flutterPhase)
            let wl = read(bufL, current + wobble), wr = read(bufR, current + wobble * 0.8 + spread)
            // The loop: tone and low cut, then feedback, then the tape saturates what it records.
            lpL += (wl - lpL) * toneCo; lpR += (wr - lpR) * toneCo
            hpL += (lpL - hpL) * lowCutCo; hpR += (lpR - hpR) * lowCutCo
            let loopL = lpL - hpL, loopR = lpR - hpR
            let inL = l[i], inR = r[i]
            bufL[write] = saturate(inL + fb * loopL, k, norm)
            bufR[write] = saturate(inR + fb * loopR, k, norm)
            write += 1
            if write >= size { write = 0 }
            l[i] = inL * (1 - m) + wl * m
            r[i] = inR * (1 - m) + wr * m
        }
    }
}
