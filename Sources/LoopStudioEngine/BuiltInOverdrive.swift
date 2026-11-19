import Foundation
import LoopStudioCore

@inline(__always) private func dbToLinear(_ db: Float) -> Float { powf(10, db / 20) }

/// An overdrive with six shapes, run at twice the sample rate so the harmonics do not fold back.
/// Soft is a tanh, Hard a clip, Tube an asymmetric tanh (even harmonics), Tape a gentle x/√(1+x²),
/// Fold a sine wavefolder that bends back past the top, Diode an exponential clipper with a hard edge.
/// A low cut before the drive keeps the bass clean; the tone lowpass after it takes the fizz off.
final class OverdriveDSP: DSPEffect, @unchecked Sendable {
    private var drive: Float = 1, comp: Float = 1, output: Float = 1, mix: Float = 1
    private var shape = 0
    private var lowCut = false
    private var cutL = Biquad(), cutR = Biquad()
    private var toneL = Biquad(), toneR = Biquad()
    /// The anti-alias lowpass at the doubled rate, two stages each side, and a DC block after the shaper.
    private var aaL1 = Biquad(), aaL2 = Biquad(), aaR1 = Biquad(), aaR2 = Biquad()
    private var dcL = Biquad(), dcR = Biquad()
    private var lastL: Float = 0, lastR: Float = 0

    override init(spec: EffectSpec, sampleRate: Double) {
        super.init(spec: spec, sampleRate: sampleRate)
        let twice = sampleRate * 2
        let edge = min(20_000, sampleRate * 0.45)
        aaL1.lowpass(edge, q: 0.54, rate: twice); aaL2.lowpass(edge, q: 1.31, rate: twice)
        aaR1.lowpass(edge, q: 0.54, rate: twice); aaR2.lowpass(edge, q: 1.31, rate: twice)
        dcL.highpass(10, q: 0.707, rate: twice); dcR.highpass(10, q: 0.707, rate: twice)
    }

    override func configure(_ p: [String: Double]) {
        let db = value(p, "drive")
        drive = dbToLinear(db)
        // The louder the drive, the more the shaper flattens: take about half of it back, so the knob
        // changes the colour more than the level.
        comp = 1 / dbToLinear(db * 0.5)
        shape = Int(value(p, "shape").rounded())
        output = dbToLinear(value(p, "output"))
        mix = value(p, "mix")
        let cut = value(p, "lowCut")
        lowCut = cut > 20.5
        if lowCut { cutL.highpass(Double(cut), q: 0.707, rate: sampleRate); cutR.highpass(Double(cut), q: 0.707, rate: sampleRate) }
        let tone = Double(min(value(p, "tone"), Float(sampleRate * 0.45)))
        toneL.lowpass(tone, q: 0.707, rate: sampleRate); toneR.lowpass(tone, q: 0.707, rate: sampleRate)
    }

    @inline(__always) private func shaped(_ x: Float) -> Float {
        switch shape {
        case 1: return min(max(x, -1), 1)
        case 2:
            // Tube: the curve sits off centre, so one half clips earlier than the other.
            let bias: Float = 0.3
            return tanhf(x + bias) - tanhf(bias)
        case 3: return x / (1 + x * x).squareRoot()
        case 4: return sinf(x * 1.5708)
        case 5: return x < 0 ? -(1 - expf(x)) : 1 - expf(-x)
        default: return tanhf(x)
        }
    }

    override func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        let g = drive, c = comp, o = output, m = mix, cut = lowCut
        for i in 0..<frames {
            var a = l[i], b = r[i]
            let dryL = a, dryR = b
            if cut { a = cutL.tick(a); b = cutR.tick(b) }
            // Two samples at the doubled rate: the midpoint and the sample. Each goes through the shaper,
            // the DC block and the anti-alias filter; the second one comes back down.
            let midL = (lastL + a) * 0.5, midR = (lastR + b) * 0.5
            lastL = a; lastR = b
            _ = aaL2.tick(aaL1.tick(dcL.tick(shaped(midL * g))))
            _ = aaR2.tick(aaR1.tick(dcR.tick(shaped(midR * g))))
            var wetL = aaL2.tick(aaL1.tick(dcL.tick(shaped(a * g)))) * c
            var wetR = aaR2.tick(aaR1.tick(dcR.tick(shaped(b * g)))) * c
            wetL = toneL.tick(wetL) * o
            wetR = toneR.tick(wetR) * o
            l[i] = dryL + (wetL - dryL) * m
            r[i] = dryR + (wetR - dryR) * m
        }
    }
}
