import Foundation
import LoopStudioCore

/// Resonator: five tuned delay loops fed by the incoming sound (see `BuiltInEffects.resonator`).
///
/// Each loop is a delay line one period long, read with linear interpolation, with a one-pole low-pass in the
/// feedback (Color) and a feedback gain from the decay time: after `decay` seconds a resonance has fallen by
/// 60 dB. Harmonic feeds back with a plus sign and rings on every partial of its note. Hollow feeds back with a
/// minus sign: the loop then rings on the odd partials of a note an octave below its length, so it is half
/// as long for the same note. The input is scaled so an impulse gives the same energy at every decay, and a
/// soft clip keeps a long decay on a sustained note from running away.
///
/// The notes reach it through the MIDI fanout of its own track, or of the track that MIDI From names. The
/// last note played sets the root and stays after its key is released, also over a stop; a turn of the Note
/// knob (or MIDI off and on) gives the root back to the knob. The loop lengths glide to a new note over a few
/// milliseconds, so a change does not click.
final class ResonatorDSP: DSPEffect, MIDIReceiver, @unchecked Sendable {
    static let voices = 5
    private let capacity: Int
    private let lines: UnsafeMutablePointer<Float>
    private var write = 0
    /// Per voice: the loop length in frames now and its target, the low-pass memory, the feedback gain, the
    /// input scale, the level and the left and right gains of its pan.
    private var length = [Double](repeating: 100, count: voices)
    private var target = [Double](repeating: 100, count: voices)
    private var damp = [Float](repeating: 0, count: voices)
    private var feedback = [Float](repeating: 0, count: voices)
    private var inScale = [Float](repeating: 0, count: voices)
    private var level = [Float](repeating: 0, count: voices)
    private var panL = [Float](repeating: 0.707, count: voices)
    private var panR = [Float](repeating: 0.707, count: voices)
    private var color: Float = 0.5
    private var hollow = false
    private var outGain: Float = 1
    private var mix: Float = 0.5
    /// The knob values the loop lengths come from, kept so a note can retune without a configure.
    private var knobNote = 48.0, fine = 0.0, decay = 2.5, listens = true
    private var intervals = [Double](repeating: 0, count: voices)
    /// The last note played, or -1: the knob sets the root.
    private(set) var heldNote = -1
    private var glide: Double = 0

    override init(spec: EffectSpec, sampleRate: Double) {
        // The lowest note (C-2, 8.2 Hz) is the longest loop.
        capacity = Int(sampleRate / 8) + 8
        lines = .allocate(capacity: capacity * Self.voices)
        lines.initialize(repeating: 0, count: capacity * Self.voices)
        super.init(spec: spec, sampleRate: sampleRate)
        glide = 1 - exp(-1 / (0.005 * sampleRate))
    }

    deinit { lines.deallocate() }

    override func configure(_ p: [String: Double]) {
        hollow = value(p, "mode") >= 0.5
        let knob = Double(value(p, "note")).rounded(), listening = value(p, "midi") >= 0.5
        // A turn of the Note knob, or MIDI switched on again, gives the root back to the knob.
        if knob != knobNote || (listening && !listens) { heldNote = -1 }
        knobNote = knob
        fine = Double(value(p, "fine"))
        listens = listening
        decay = Double(value(p, "decay"))
        color = value(p, "color")
        let width = value(p, "width")
        outGain = powf(10, value(p, "gain") / 20)
        mix = value(p, "mix")
        level[0] = value(p, "r1.gain")
        intervals[0] = 0
        for k in 2...Self.voices {
            let on = value(p, "r\(k).on") >= 0.5
            level[k - 1] = on ? value(p, "r\(k).gain") : 0
            intervals[k - 1] = Double(value(p, "r\(k).pitch")).rounded()
        }
        // I in the middle, II and III to the sides, IV and V halfway: Width spreads them.
        let spread: [Float] = [0, -1, 1, -0.5, 0.5]
        for v in 0..<Self.voices {
            let pan = spread[v] * width
            let angle = (pan + 1) * Float.pi / 4
            panL[v] = cosf(angle)
            panR[v] = sinf(angle)
        }
        retune(snap: false)
    }

    /// Loop lengths and feedback gains for the root note now (a held note, else the knob).
    private func retune(snap: Bool) {
        let root = (listens && heldNote >= 0 ? Double(heldNote) : knobNote) + fine / 100
        for v in 0..<Self.voices {
            let note = root + intervals[v]
            let hz = 440 * pow(2, (note - 69) / 12)
            // Hollow rings an octave below its loop: half the loop for the same note.
            var frames = sampleRate / hz / (hollow ? 2 : 1)
            // The low-pass in the loop delays low partials by about c / (1 - c) frames; take that off.
            let c = Double(dampCoefficient)
            frames -= c / (1 - c)
            frames = min(max(frames, 2), Double(capacity - 4))
            target[v] = frames
            if snap { length[v] = frames }
            let g = pow(0.001, frames * (hollow ? 2 : 1) / (decay * sampleRate))
            feedback[v] = Float(min(g, 0.99995))
            inScale[v] = Float(sqrt(max(1 - g * g, 1e-6)))
        }
    }

    /// The low-pass coefficient of Color: 0 dark (strong damping), 1 bright (none).
    private var dampCoefficient: Float { (1 - color) * 0.85 }

    override func reset() {
        lines.update(repeating: 0, count: capacity * Self.voices)
        for v in 0..<Self.voices { damp[v] = 0; length[v] = target[v] }
    }

    func sendMIDI(_ status: UInt8, _ data1: UInt8, _ data2: UInt8, sampleOffset: Int) {
        let kind = status & 0xF0
        // A note off changes nothing: the root stays on the last note.
        if kind == 0x90, data2 > 0, Int(data1) != heldNote { heldNote = Int(data1); retune(snap: false) }
    }

    /// A stop or a jump: the root stays where the last note put it.
    func silenceNotes() {}

    override func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        let c = dampCoefficient, sign: Float = hollow ? -1 : 1
        let dry = 1 - mix, wet = mix * outGain
        for i in 0..<frames {
            let input = (l[i] + r[i]) * 0.5
            var outL: Float = 0, outR: Float = 0
            for v in 0..<Self.voices where level[v] > 0 {
                length[v] += (target[v] - length[v]) * glide
                let base = v * capacity
                // The sound one loop ago, between two frames.
                var pos = Double(write) - length[v]
                if pos < 0 { pos += Double(capacity) }
                let i0 = Int(pos), frac = Float(pos - Double(i0))
                let i1 = i0 + 1 == capacity ? 0 : i0 + 1
                let delayed = lines[base + i0] * (1 - frac) + lines[base + i1] * frac
                damp[v] = delayed * (1 - c) + damp[v] * c
                let y = input * inScale[v] + sign * feedback[v] * damp[v]
                lines[base + write] = y
                let out = y * level[v]
                outL += out * panL[v]
                outR += out * panR[v]
            }
            write += 1
            if write == capacity { write = 0 }
            // A soft clip on the wet sound only: a long decay on a held note stays bounded.
            l[i] = l[i] * dry + tanhf(outL * 2) * 0.5 * wet
            r[i] = r[i] * dry + tanhf(outR * 2) * 0.5 * wet
        }
        meters[0] = Float(listens && heldNote >= 0 ? heldNote : Int(knobNote))
    }
}
