import Foundation
import LoopStudioCore

/// One grain: where it started in the ring, how long it is, how far it has played, its pitch ratio, its
/// pan gains, its direction and its window.
private struct Grain {
    var active = false
    var start = 0.0
    var length = 1
    var phase = 0
    var ratio = 1.0
    var gainL: Float = 1, gainR: Float = 1
    var reverse = false
    var window = 0
}

/// The granulator: the sound runs into an eight-second ring, and grains read from a position behind the
/// record head. Freeze stops the recording, so the ring stands still and the position moves through it.
/// Every grain is windowed, so the sum stays smooth; the level is scaled by the overlap, so a dense cloud
/// is not louder than a sparse one. The ring's peaks and the grains' positions go to the display.
final class GranulatorDSP: DSPEffect, @unchecked Sendable {
    /// The ring in seconds.
    static let seconds = DSPEffect.granulatorSeconds
    private let size: Int
    private let bufL: UnsafeMutablePointer<Float>, bufR: UnsafeMutablePointer<Float>
    private var write = 0
    private var recording = true
    private var position: Double = 0.25
    private var feedback: Float = 0
    private var grainFrames = 5_760
    private var interval = 3_000.0
    private var window = 0
    private var sprayFrames = 0.0
    private var pitch = 0.0, pitchSpread = 0.0
    private var reverseChance = 0.0
    private var panSpread = 0.0
    private var level: Float = 1, scale: Float = 1
    private var mix: Float = 1
    private var untilNext = 0.0
    private var random = CutRandom(seed: 11)
    private let grains: UnsafeMutablePointer<Grain>
    private static let voices = DSPEffect.markCount

    // The display: one peak per bin of the ring, filled as the record head passes.
    private let binSize: Int
    private var binPeak: Float = 0
    private var bin = 0

    override init(spec: EffectSpec, sampleRate: Double) {
        size = Int(sampleRate * Self.seconds)
        bufL = .allocate(capacity: size); bufL.initialize(repeating: 0, count: size)
        bufR = .allocate(capacity: size); bufR.initialize(repeating: 0, count: size)
        grains = .allocate(capacity: Self.voices); grains.initialize(repeating: Grain(), count: Self.voices)
        binSize = max(1, size / DSPEffect.waveformBins)
        super.init(spec: spec, sampleRate: sampleRate)
        let w = UnsafeMutablePointer<Float>.allocate(capacity: DSPEffect.waveformBins)
        w.initialize(repeating: 0, count: DSPEffect.waveformBins)
        waveform = w
        let m = UnsafeMutablePointer<Float>.allocate(capacity: Self.voices)
        m.initialize(repeating: -1, count: Self.voices)
        marks = m
    }

    deinit {
        bufL.deallocate(); bufR.deallocate(); grains.deallocate()
        waveform?.deallocate(); marks?.deallocate()
    }

    override func configure(_ p: [String: Double]) {
        recording = value(p, "record") >= 0.5
        position = Double(value(p, "position"))
        feedback = value(p, "feedback")
        grainFrames = max(16, Int(Double(value(p, "sizeMs")) * 0.001 * sampleRate))
        let density = Double(value(p, "density"))
        interval = sampleRate / max(0.1, density)
        window = Int(value(p, "window").rounded())
        sprayFrames = Double(value(p, "sprayMs")) * 0.001 * sampleRate
        pitch = Double(value(p, "pitch"))
        pitchSpread = Double(value(p, "pitchSpread"))
        reverseChance = Double(value(p, "reverse"))
        panSpread = Double(value(p, "panSpread"))
        level = powf(10, value(p, "level") / 20)
        // The overlap: grains per second times a grain's length. Equal power over it.
        let overlap = density * Double(grainFrames) / sampleRate
        scale = Float(1 / sqrt(max(1, overlap))) * 0.5
        mix = value(p, "mix")
    }

    override func reset() {
        bufL.update(repeating: 0, count: size); bufR.update(repeating: 0, count: size)
        for i in 0..<Self.voices { grains[i].active = false; marks?[i] = -1 }
        if let w = waveform { w.update(repeating: 0, count: DSPEffect.waveformBins) }
        untilNext = 0
    }

    /// The window's value at `t` in 0...1.
    @inline(__always) private func shape(_ t: Float, _ kind: Int) -> Float {
        switch kind {
        case 1: return 1 - abs(2 * t - 1)
        case 2: // a box with 5 % edges
            let e: Float = 0.05
            return t < e ? t / e : t > 1 - e ? (1 - t) / e : 1
        case 3: let d = (t - 0.5) / 0.18; return expf(-0.5 * d * d)
        case 4: return t < 0.02 ? t / 0.02 : (1 - t) * (1 - t)
        case 5: return t > 0.98 ? (1 - t) / 0.02 : t * t
        default: return 0.5 * (1 - cosf(2 * Float.pi * t))
        }
    }

    private func spawn() {
        var slot = -1
        for i in 0..<Self.voices where !grains[i].active { slot = i; break }
        guard slot >= 0 else { return }
        var g = Grain()
        g.length = grainFrames
        g.window = window
        let semis = pitch + (pitchSpread > 0 ? random.float(-pitchSpread, pitchSpread) : 0)
        g.ratio = pow(2, semis / 12)
        g.reverse = reverseChance > 0 && random.chance(reverseChance)
        // The grain spans `length * ratio` frames of the ring; it must not read past the record head.
        let span = Double(g.length) * g.ratio
        var age = position * Double(size) + (sprayFrames > 0 ? random.float(0, sprayFrames) : 0)
        age = min(max(age, span + 2), Double(size) - 2)
        var start = Double(write) - age
        if start < 0 { start += Double(size) }
        g.start = start
        let pan = panSpread > 0 ? random.float(-panSpread, panSpread) : 0
        let a = Float(pan + 1) * Float.pi / 4
        g.gainL = cosf(a); g.gainR = sinf(a)
        g.active = true
        grains[slot] = g
    }

    @inline(__always) private func read(_ buf: UnsafeMutablePointer<Float>, _ pos: Double) -> Float {
        var p = pos
        if p >= Double(size) { p -= Double(size) }
        if p < 0 { p += Double(size) }
        let i0 = Int(p), i1 = i0 + 1 == size ? 0 : i0 + 1
        let frac = Float(p - Double(i0))
        return buf[i0] + (buf[i1] - buf[i0]) * frac
    }

    override func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        let wet = mix, dry = 1 - mix, gain = scale * level, fb = feedback
        for k in 0..<frames {
            untilNext -= 1
            // A few percent of jitter on the grain clock: grains at an exact hop comb a steady tone.
            if untilNext <= 0 { spawn(); untilNext += interval * random.float(0.96, 1.04) }
            var outL: Float = 0, outR: Float = 0
            for i in 0..<Self.voices where grains[i].active {
                var g = grains[i]
                let t = Float(g.phase) / Float(g.length)
                let offset = Double(g.reverse ? g.length - g.phase : g.phase) * g.ratio
                let w = shape(t, g.window)
                let a = read(bufL, g.start + offset), b = read(bufR, g.start + offset)
                outL += w * g.gainL * a
                outR += w * g.gainR * b
                g.phase += 1
                if g.phase >= g.length { g.active = false }
                grains[i] = g
            }
            outL *= gain; outR *= gain
            let inL = l[k], inR = r[k]
            if recording {
                bufL[write] = inL + fb * outL
                bufR[write] = inR + fb * outR
                binPeak = max(binPeak, max(abs(inL), abs(inR)))
                write += 1
                if write >= size { write = 0 }
                let b = min(DSPEffect.waveformBins - 1, write / binSize)
                if b != bin {
                    waveform?[bin] = binPeak
                    binPeak = 0
                    bin = b
                }
            }
            l[k] = outL * wet + inL * dry
            r[k] = outR * wet + inR * dry
        }
        // For the display: the record head, the read position, and where each grain reads.
        meters[0] = Float(write) / Float(size)
        meters[1] = Float(position)
        var active = 0
        for i in 0..<Self.voices {
            let g = grains[i]
            if g.active {
                active += 1
                var p = g.start + Double(g.reverse ? g.length - g.phase : g.phase) * g.ratio
                if p >= Double(size) { p -= Double(size) }
                marks?[i] = Float(p / Double(size))
            } else {
                marks?[i] = -1
            }
        }
        meters[2] = Float(active) / Float(Self.voices)
        meters[3] = recording ? 1 : 0
    }
}
