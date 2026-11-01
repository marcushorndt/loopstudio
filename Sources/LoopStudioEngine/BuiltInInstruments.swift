import Foundation
import LoopStudioCore

/// What takes the notes of a MIDI track: a hosted instrument or a built-in one.
protocol MIDIReceiver: AnyObject {
    func sendMIDI(_ status: UInt8, _ data1: UInt8, _ data2: UInt8, sampleOffset: Int)
    func silenceNotes()
}

extension AudioUnitEffect: MIDIReceiver {}

extension MIDIReceiver {
    /// A message at the top of the next block.
    func sendMIDI(_ status: UInt8, _ data1: UInt8, _ data2: UInt8) { sendMIDI(status, data1, data2, sampleOffset: 0) }
}

/// A built-in instrument. It takes MIDI messages with a sample offset into the next `render` call and adds
/// its sound to a stereo block. Like an effect it uses only memory from `init`, and once it runs only the
/// audio thread calls it. `configure` gives it the knob values, `reset` ends every note.
///
/// `telemetry` holds a few numbers for the display (a filter position, pad levels). The audio thread writes
/// them at the end of each block; the display reads them without a lock, as it reads the meters.
public class DSPInstrument: DSPEffect, MIDIReceiver, @unchecked Sendable {
    private struct Event {
        var offset: Int32
        var status: UInt8
        var data1: UInt8
        var data2: UInt8
    }

    private let capacity = 1024
    private let queue: UnsafeMutablePointer<Event>
    private var count = 0
    public static let telemetryCount = 16
    public let telemetry: UnsafeMutablePointer<Float>

    override init(spec: EffectSpec, sampleRate: Double) {
        queue = .allocate(capacity: capacity)
        telemetry = .allocate(capacity: Self.telemetryCount)
        telemetry.initialize(repeating: 0, count: Self.telemetryCount)
        super.init(spec: spec, sampleRate: sampleRate)
    }

    deinit {
        queue.deallocate()
        telemetry.deallocate()
    }

    /// Queues one message for `sampleOffset` frames into the next `render`. Messages stay in time order.
    public func sendMIDI(_ status: UInt8, _ data1: UInt8, _ data2: UInt8, sampleOffset: Int = 0) {
        guard count < capacity else { return }
        let offset = Int32(clamping: max(0, sampleOffset))
        var i = count
        while i > 0, queue[i - 1].offset > offset { queue[i] = queue[i - 1]; i -= 1 }
        queue[i] = Event(offset: offset, status: status, data1: data1, data2: data2)
        count += 1
    }

    /// Ends every note at once and drops the queued messages.
    public func silenceNotes() {
        count = 0
        allNotesOff()
    }

    public override func reset() {
        count = 0
        allNotesOff()
        clearState()
    }

    /// An instrument has no audio input: as an effect it leaves the block alone.
    public override func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {}

    /// Adds `frames` frames of sound to `l` and `r`. Messages due inside the block take effect on their frame.
    public func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0, head = 0
        while done < frames {
            while head < count, Int(queue[head].offset) <= done {
                handle(queue[head])
                head += 1
            }
            let next = head < count ? min(frames, Int(queue[head].offset)) : frames
            if next > done {
                renderVoices(l + done, r + done, frames: next - done)
                done = next
            }
        }
        // What is still ahead moves up by this block.
        var k = 0
        for i in head..<count {
            queue[k] = queue[i]
            queue[k].offset = max(0, queue[k].offset - Int32(frames))
            k += 1
        }
        count = k
        writeTelemetry()
    }

    private func handle(_ e: Event) {
        switch e.status & 0xF0 {
        case 0x90 where e.data2 > 0: noteOn(e.data1 & 127, e.data2 & 127)
        case 0x80, 0x90: noteOff(e.data1 & 127)
        case 0xB0 where e.data1 == 123 || e.data1 == 120: allNotesOff()
        case 0xE0: pitchBend(Float(Int(e.data2 & 127) << 7 | Int(e.data1 & 127)) / 8192 - 1)
        default: break
        }
    }

    func noteOn(_ pitch: UInt8, _ velocity: UInt8) {}
    func noteOff(_ pitch: UInt8) {}
    /// Every note ends now, with its release.
    func allNotesOff() {}
    /// Forgets the sound in flight (tails, envelopes). Called with `allNotesOff` on a stop or a jump.
    func clearState() {}
    /// Pitch bend, -1 to 1.
    func pitchBend(_ amount: Float) {}
    /// Adds the voices to the block. No messages fall inside it.
    func renderVoices(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {}
    func writeTelemetry() {}

    /// Reads one telemetry value. For the display.
    public func telemetryValue(_ i: Int) -> Float { i >= 0 && i < Self.telemetryCount ? telemetry[i] : 0 }

    static func makeInstrument(_ id: String, sampleRate: Double) -> DSPInstrument? {
        guard let spec = BuiltInInstruments.spec(id) else { return nil }
        let instrument: DSPInstrument
        switch id {
        case "acid": instrument = AcidBassDSP(spec: spec, sampleRate: sampleRate)
        case "drum808": instrument = Drum808DSP(spec: spec, sampleRate: sampleRate)
        default: return nil
        }
        instrument.configure([:])
        return instrument
    }
}

// MARK: Shared pieces

@inline(__always) private func dbToLinear(_ db: Float) -> Float { powf(10, db / 20) }

/// The correction that takes the step out of a saw or square at a phase wrap. `t` is the phase 0..<1,
/// `dt` the phase increment per sample.
@inline(__always) private func polyBlep(_ t: Float, _ dt: Float) -> Float {
    if t < dt {
        let x = t / dt
        return x + x - x * x - 1
    } else if t > 1 - dt {
        let x = (t - 1) / dt
        return x * x + x + x + 1
    }
    return 0
}

/// A saw with the step smoothed. Phase 0..<1.
@inline(__always) private func blepSaw(_ phase: Float, _ dt: Float) -> Float {
    2 * phase - 1 - polyBlep(phase, dt)
}

/// A square with both steps smoothed. Phase 0..<1.
@inline(__always) private func blepSquare(_ phase: Float, _ dt: Float) -> Float {
    var y: Float = phase < 0.5 ? 1 : -1
    y += polyBlep(phase, dt)
    var t = phase + 0.5
    if t >= 1 { t -= 1 }
    y -= polyBlep(t, dt)
    return y
}

/// A xorshift noise source. Deterministic, so a test renders the same sound twice.
private struct Noise {
    var state: UInt32 = 0x9E37_79B9

    @inline(__always) mutating func next() -> Float {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return Float(Int32(bitPattern: state)) / 2_147_483_648
    }
}

/// The per-sample factor that takes a level to -40 dB in `ms` milliseconds.
@inline(__always) private func decayCoefficient(ms: Float, rate: Float, db: Float = 40) -> Float {
    let tau = max(0.0005, ms / 1000) / (db / 8.686)
    return expf(-1 / (tau * rate))
}

/// A 4-pole transistor ladder (Huovilainen's model, DAFX 2004) with a saturating stage, run at twice the
/// sample rate. Resonance 0...1 self-oscillates near 1.
private struct Ladder {
    var stage: (Float, Float, Float, Float) = (0, 0, 0, 0)
    var stageTanh: (Float, Float, Float) = (0, 0, 0)
    var delay: (Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0)
    var tune: Float = 0
    var resQuad: Float = 0
    var lastInput: Float = 0
    private static let thermal: Float = 0.000025

    mutating func reset() {
        stage = (0, 0, 0, 0); stageTanh = (0, 0, 0); delay = (0, 0, 0, 0, 0, 0); lastInput = 0
    }

    /// `cutoff` in Hz at the base rate `rate`; `resonance` 0...1.
    @inline(__always) mutating func set(cutoff: Float, resonance: Float, rate: Float) {
        let fc = min(cutoff, rate * 0.45) / rate
        let f = fc * 0.5 // the loop runs twice per sample
        let fc2 = fc * fc, fc3 = fc2 * fc
        let fcr = 1.8730 * fc3 + 0.4955 * fc2 - 0.6490 * fc + 0.9988
        let acr = -3.9364 * fc2 + 1.8409 * fc + 0.9968
        tune = (1 - expf(-(2 * .pi * f * fcr))) / Self.thermal
        resQuad = 4 * resonance * acr
    }

    @inline(__always) private mutating func step(_ x: Float) {
        let t = Self.thermal
        var input = x - resQuad * delay.5
        stage.0 = delay.0 + tune * (tanhf(input * t) - stageTanh.0)
        delay.0 = stage.0
        input = stage.0
        stageTanh.0 = tanhf(input * t)
        stage.1 = delay.1 + tune * (stageTanh.0 - stageTanh.1)
        delay.1 = stage.1
        input = stage.1
        stageTanh.1 = tanhf(input * t)
        stage.2 = delay.2 + tune * (stageTanh.1 - stageTanh.2)
        delay.2 = stage.2
        input = stage.2
        stageTanh.2 = tanhf(input * t)
        stage.3 = delay.3 + tune * (stageTanh.2 - tanhf(delay.3 * t))
        delay.3 = stage.3
        delay.5 = (stage.3 + delay.4) * 0.5
        delay.4 = stage.3
    }

    /// One sample in, one out. The input is interpolated for the half step.
    @inline(__always) mutating func tick(_ x: Float) -> Float {
        step((lastInput + x) * 0.5)
        step(x)
        lastInput = x
        return delay.5
    }
}

// MARK: Acid Bass

/// Telemetry: 0 the filter cutoff in Hz as it sounds, 1 the amplitude envelope, 2 the gate, 3 the accent,
/// 4 the filter envelope, 5 the pitch as a MIDI note.
final class AcidBassDSP: DSPInstrument, @unchecked Sendable {
    // Knobs.
    private var square = false
    private var tune: Float = 0, sub: Float = 0
    private var cutoff: Float = 700, resonance: Float = 0.65, envMod: Float = 0.6
    private var decayMs: Float = 400, accentAmount: Float = 0.7, slideMs: Float = 60
    private var drive: Float = 0.15, gain: Float = 0.5

    // Coefficients from the knobs.
    private var megCoefficient: Float = 0.9999, accentCoefficient: Float = 0.9999, slideCoefficient: Float = 0.001
    private var accentSmooth: Float = 0.01
    private let attackCoefficient: Float, releaseCoefficient: Float, sustainDecay: Float

    // Notes held, newest last.
    private let stack: UnsafeMutablePointer<UInt8>
    private var stackCount = 0

    // Voice.
    private var gate = false, accent = false
    private var pitch: Float = 48, targetPitch: Float = 48, bend: Float = 0
    private var phase: Float = 0, subPhase: Float = 0
    private var meg: Float = 0, accentEnv: Float = 0, vca: Float = 0, vcaPeak: Float = 0
    private var ladder = Ladder()
    private var dcState: Float = 0, dcLast: Float = 0
    private var liveCutoff: Float = 700
    private let rate: Float

    override init(spec: EffectSpec, sampleRate: Double) {
        rate = Float(sampleRate)
        stack = .allocate(capacity: 16)
        stack.initialize(repeating: 0, count: 16)
        attackCoefficient = 1 - expf(-1 / (0.003 * rate))
        releaseCoefficient = 1 - expf(-1 / (0.012 * rate))
        sustainDecay = expf(-1 / (3.5 * rate))
        super.init(spec: spec, sampleRate: sampleRate)
    }

    deinit { stack.deallocate() }

    override func configure(_ p: [String: Double]) {
        square = value(p, "wave") >= 0.5
        tune = value(p, "tune"); sub = value(p, "sub")
        cutoff = value(p, "cutoff"); resonance = value(p, "resonance"); envMod = value(p, "envMod")
        decayMs = value(p, "decay"); accentAmount = value(p, "accent"); slideMs = value(p, "slide")
        drive = value(p, "drive"); gain = dbToLinear(value(p, "volume"))
        // The knob decay takes the filter envelope to 10 %. An accented note uses the fixed, short decay.
        megCoefficient = decayCoefficient(ms: decayMs, rate: rate, db: 20)
        accentCoefficient = decayCoefficient(ms: 200, rate: rate, db: 20)
        slideCoefficient = 1 - expf(-1 / (max(0.001, slideMs / 1000) / 4.6 * rate))
        // The accent sweep: a capacitor charged through the resonance, so more resonance makes a slower "wow".
        accentSmooth = 1 - expf(-1 / ((0.002 + resonance * resonance * 0.06) * rate))
    }

    override func clearState() {
        meg = 0; accentEnv = 0; vca = 0; vcaPeak = 0; gate = false; accent = false
        ladder.reset()
        dcState = 0; dcLast = 0
        phase = 0; subPhase = 0
    }

    override func noteOn(_ note: UInt8, _ velocity: UInt8) {
        let legato = stackCount > 0
        if stackCount == 16 {
            for i in 1..<16 { stack[i - 1] = stack[i] }
            stackCount = 15
        }
        stack[stackCount] = note
        stackCount += 1
        targetPitch = Float(note)
        if legato { return } // a slide: the pitch glides, the envelopes run on
        pitch = targetPitch
        gate = true
        accent = velocity >= BuiltInInstruments.accentVelocity
        meg = 1
        vcaPeak = 1
    }

    override func noteOff(_ note: UInt8) {
        var i = stackCount - 1
        while i >= 0 {
            if stack[i] == note {
                for k in i..<(stackCount - 1) { stack[k] = stack[k + 1] }
                stackCount -= 1
            }
            i -= 1
        }
        if stackCount > 0 {
            targetPitch = Float(stack[stackCount - 1]) // back to the note still held, with a slide
        } else {
            gate = false
        }
    }

    override func allNotesOff() {
        stackCount = 0
        gate = false
    }

    override func pitchBend(_ amount: Float) { bend = amount * 2 }

    override func renderVoices(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        // Nothing sounds and nothing rings: skip the block, but keep the filter quiet.
        if !gate, vca < 1e-5, meg < 1e-4 { vca = 0; return }
        let sq = square, subAmount = sub, drv = drive, outGain = gain
        let pre = 1 + drv * 14
        let driveMakeup = 1 / (1 + drv * 2.2)
        let accentLevel = accent ? accentAmount : 0
        let megCo = accent ? accentCoefficient : megCoefficient
        let res = resonance
        let dcCo: Float = 0.9985
        for i in 0..<frames {
            // Pitch, with the slide.
            pitch += (targetPitch - pitch) * slideCoefficient
            let hz = 440 * exp2f((pitch + tune + bend - 69) / 12)
            let dt = min(0.45, hz / rate)
            phase += dt
            if phase >= 1 { phase -= 1 }
            var osc = sq ? blepSquare(phase, dt) : blepSaw(phase, dt)
            if subAmount > 0 {
                subPhase += dt * 0.5
                if subPhase >= 1 { subPhase -= 1 }
                osc += subAmount * 0.7 * blepSquare(subPhase, dt * 0.5)
            }

            // Envelopes.
            meg *= megCo
            accentEnv += ((accent ? meg : 0) - accentEnv) * accentSmooth
            if gate {
                vcaPeak *= sustainDecay
                vca += (vcaPeak - vca) * attackCoefficient
            } else {
                vca += (0 - vca) * releaseCoefficient
            }

            // The filter follows its envelope, the accent adds a slower sweep.
            let octaves = envMod * 4.5 * meg + accentLevel * 3 * accentEnv
            let fc = min(cutoff * exp2f(octaves), rate * 0.45)
            liveCutoff = fc
            ladder.set(cutoff: fc, resonance: res, rate: rate)
            var y = ladder.tick(osc * 0.6) * (1 + 0.8 * res)

            // Drive, amplitude and a DC block (the ladder shifts the centre at high drive).
            y = tanhf(y * pre) * driveMakeup
            y *= vca * (1 + accentLevel * 0.6) * outGain
            let blocked = y - dcLast + dcCo * dcState
            dcLast = y
            dcState = blocked
            l[i] += blocked
            r[i] += blocked
        }
    }

    override func writeTelemetry() {
        telemetry[0] = liveCutoff
        telemetry[1] = vca
        telemetry[2] = gate ? 1 : 0
        telemetry[3] = accent && gate ? 1 : 0
        telemetry[4] = meg
        telemetry[5] = pitch + tune
    }
}

// MARK: 808 Drums

/// Telemetry: the level of each pad, in the order of `BuiltInInstruments.drumPads`.
final class Drum808DSP: DSPInstrument, @unchecked Sendable {
    private struct Voice {
        var env: Float = 0      // the main amplitude envelope
        var env2: Float = 0     // a second envelope: a noise burst, a short body
        var penv: Float = 0     // pitch envelope
        var phase: Float = 0
        var phase2: Float = 0
        var t = 0               // frames since the hit
        var vel: Float = 0
        var on = false
    }

    private static let padCount = 12
    private let voices: UnsafeMutablePointer<Voice>
    private let rate: Float
    private var noise = Noise()
    private let pads = BuiltInInstruments.drumPads
    // Per pad: the level after the knob, the stereo gains.
    private let level: UnsafeMutablePointer<Float>
    private let gainL: UnsafeMutablePointer<Float>
    private let gainR: UnsafeMutablePointer<Float>
    private let peak: UnsafeMutablePointer<Float>
    private var velocityAmount: Float = 0.6, volume: Float = 1

    // Knobs, as coefficients or frequencies.
    private var bdHz: Float = 55, bdDecay: Float = 0.999, bdTone: Float = 0.4
    private var sdHz: Float = 185, sdSnappy: Float = 0.6, sdDecay: Float = 0.999
    private var cpDecay: Float = 0.999
    private var rsHz: Float = 1_700
    private var ltHz: Float = 80, mtHz: Float = 120, htHz: Float = 165, tomDecay: Float = 0.999
    private var cbHz: Float = 587
    private var chDecay: Float = 0.999, ohDecay: Float = 0.999
    private var cyDecayA: Float = 0.999, cyDecayB: Float = 0.999

    // Fixed coefficients.
    private let bdPitchDecay: Float, bdClickDecay: Float, sdBodyDecay: Float, rsDecay: Float, rsClick: Float
    private let clapBurst: Int, clapBurstDecay: Float, tomPitchDecay: Float, tomNoiseDecay: Float
    private let cbDecayA: Float, cbDecayB: Float, clDecay: Float, chokeDecay: Float

    // Filters.
    private var sdNoise = Biquad(), cpBand = Biquad(), cbBand = Biquad()
    private var hhHigh = Biquad(), cyBandA = Biquad(), cyBandB = Biquad()
    // The metallic oscillators of the hats and the cymbal: six squares at the 808's frequencies.
    private static let metallicHz: [Float] = [205.3, 304.4, 369.6, 522.7, 540, 800]
    private var metallic: (Float, Float, Float, Float, Float, Float) = (0, 0.17, 0.41, 0.63, 0.78, 0.92)

    override init(spec: EffectSpec, sampleRate: Double) {
        rate = Float(sampleRate)
        voices = .allocate(capacity: Self.padCount)
        voices.initialize(repeating: Voice(), count: Self.padCount)
        level = .allocate(capacity: Self.padCount); level.initialize(repeating: 1, count: Self.padCount)
        gainL = .allocate(capacity: Self.padCount); gainL.initialize(repeating: 0.707, count: Self.padCount)
        gainR = .allocate(capacity: Self.padCount); gainR.initialize(repeating: 0.707, count: Self.padCount)
        peak = .allocate(capacity: Self.padCount); peak.initialize(repeating: 0, count: Self.padCount)
        let r = rate
        bdPitchDecay = decayCoefficient(ms: 35, rate: r)
        bdClickDecay = decayCoefficient(ms: 4, rate: r)
        sdBodyDecay = decayCoefficient(ms: 110, rate: r)
        rsDecay = decayCoefficient(ms: 14, rate: r)
        rsClick = decayCoefficient(ms: 2.5, rate: r)
        clapBurst = Int(0.0105 * r)
        clapBurstDecay = decayCoefficient(ms: 5, rate: r)
        tomPitchDecay = decayCoefficient(ms: 60, rate: r)
        tomNoiseDecay = decayCoefficient(ms: 25, rate: r)
        cbDecayA = decayCoefficient(ms: 30, rate: r)
        cbDecayB = decayCoefficient(ms: 220, rate: r)
        clDecay = decayCoefficient(ms: 35, rate: r)
        chokeDecay = decayCoefficient(ms: 6, rate: r)
        super.init(spec: spec, sampleRate: sampleRate)
        sdNoise.highpass(1_400, q: 0.8, rate: sampleRate)
        cpBand.bandpass(1_300, q: 1.4, rate: sampleRate)
        cbBand.bandpass(2_640, q: 2.2, rate: sampleRate)
    }

    deinit {
        voices.deallocate(); level.deallocate(); gainL.deallocate(); gainR.deallocate(); peak.deallocate()
    }

    override func configure(_ p: [String: Double]) {
        let r = rate
        func st(_ key: String) -> Float { exp2f(value(p, key) / 12) }
        bdHz = 55 * st("bd.tune"); bdDecay = decayCoefficient(ms: value(p, "bd.decay"), rate: r); bdTone = value(p, "bd.tone")
        sdHz = 185 * st("sd.tune"); sdSnappy = value(p, "sd.snappy"); sdDecay = decayCoefficient(ms: value(p, "sd.decay"), rate: r)
        cpDecay = decayCoefficient(ms: value(p, "cp.decay"), rate: r)
        rsHz = 1_700 * st("rs.tune")
        ltHz = 80 * st("lt.tune"); mtHz = 120 * st("mt.tune"); htHz = 165 * st("ht.tune")
        tomDecay = decayCoefficient(ms: value(p, "tom.decay"), rate: r)
        cbHz = 587 * st("cb.tune")
        chDecay = decayCoefficient(ms: value(p, "ch.decay"), rate: r)
        ohDecay = decayCoefficient(ms: value(p, "oh.decay"), rate: r)
        let cyMs = value(p, "cy.decay")
        cyDecayA = decayCoefficient(ms: cyMs, rate: r); cyDecayB = decayCoefficient(ms: cyMs * 0.35, rate: r)
        velocityAmount = value(p, "accent")
        volume = dbToLinear(value(p, "volume"))
        let spread = value(p, "spread")
        for (i, pad) in pads.enumerated() {
            level[i] = dbToLinear(value(p, pad.params.last!))
            let pan = Float(pad.pan) * spread
            let angle = (pan + 1) * 0.25 * Float.pi
            gainL[i] = cosf(angle); gainR[i] = sinf(angle)
        }
        // The hats: the tone knob moves the high-pass from 4 kHz to 11 kHz. The cymbal: two bands around it.
        var f = Biquad(); f.highpass(Double(4_000 * exp2f(value(p, "hh.tone") * 1.5)), q: 1.0, rate: Double(r))
        f.z1 = hhHigh.z1; f.z2 = hhHigh.z2; hhHigh = f
        let cyCentre = Double(3_000 * exp2f(value(p, "cy.tone") * 1.4))
        var a = Biquad(); a.bandpass(cyCentre, q: 1.0, rate: Double(r)); a.z1 = cyBandA.z1; a.z2 = cyBandA.z2; cyBandA = a
        var b = Biquad(); b.bandpass(min(cyCentre * 2.6, 16_000), q: 1.6, rate: Double(r)); b.z1 = cyBandB.z1; b.z2 = cyBandB.z2; cyBandB = b
    }

    override func clearState() {
        for i in 0..<Self.padCount { voices[i] = Voice(); peak[i] = 0 }
        sdNoise.reset(); cpBand.reset(); cbBand.reset(); hhHigh.reset(); cyBandA.reset(); cyBandB.reset()
    }

    override func noteOn(_ note: UInt8, _ velocity: UInt8) {
        guard let i = BuiltInInstruments.drumPadIndex(forNote: note) else { return }
        let v = Float(velocity) / 127
        var voice = voices[i]
        // The phase runs on, so a retrigger does not click.
        voice.on = true
        voice.t = 0
        voice.vel = 1 - velocityAmount * (1 - v)
        voice.env = 1
        voice.env2 = 1
        voice.penv = 1
        voices[i] = voice
        // A closed hat chokes the open hat, as the 808's one hat voice does.
        if i == 8, voices[9].on { voices[9].on = false }
        peak[i] = max(peak[i], voice.vel)
    }

    override func noteOff(_ note: UInt8) {} // a drum plays out
    override func allNotesOff() {}

    override func renderVoices(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        var anyOn = false
        for i in 0..<Self.padCount where voices[i].on || voices[i].env > 1e-4 { anyOn = true; break }
        guard anyOn else { return }
        // The kit sits about 6 dB under full scale at its defaults, so a kick plus hats do not clip the track.
        let vol = volume * 0.5
        let metallicOn = voices[8].env > 1e-4 || voices[9].env > 1e-4 || voices[9].env2 > 1e-4 || voices[10].env > 1e-4
        for n in 0..<frames {
            // The hats share one source and one high-pass, so the filter ticks once per sample.
            var metal: Float = 0, hat: Float = 0
            if metallicOn {
                metal = metallicSample()
                hat = hhHigh.tick(metal)
            }
            for i in 0..<Self.padCount {
                var v = voices[i]
                guard v.on || v.env > 1e-4 else { continue }
                var s: Float = 0
                switch i {
                case 0: s = kick(&v)
                case 1: s = snare(&v)
                case 2: s = clap(&v)
                case 3: s = rimshot(&v)
                case 4: s = tom(&v, hz: ltHz)
                case 5: s = tom(&v, hz: mtHz)
                case 6: s = tom(&v, hz: htHz)
                case 7: s = cowbell(&v)
                case 8: s = closedHat(&v, hat)
                case 9: s = openHat(&v, hat)
                case 10: s = cymbal(&v, metal)
                default: s = clave(&v)
                }
                v.t += 1
                if v.env < 1e-4, v.env2 < 1e-4 { v.on = false; v.env = 0; v.env2 = 0 }
                voices[i] = v
                s *= v.vel * level[i] * vol
                l[n] += s * gainL[i]
                r[n] += s * gainR[i]
            }
        }
    }

    override func writeTelemetry() {
        for i in 0..<Self.padCount {
            telemetry[i] = max(peak[i], voices[i].env * voices[i].vel)
            peak[i] = 0
        }
    }

    // MARK: Voices. Each returns one sample and moves its envelopes on.

    @inline(__always) private func sine(_ phase: inout Float, _ hz: Float) -> Float {
        phase += hz / rate
        if phase >= 1 { phase -= 1 }
        return sinf(phase * 2 * .pi)
    }

    private func kick(_ v: inout Voice) -> Float {
        let hz = bdHz * (1 + 1.6 * v.penv)
        let body = sine(&v.phase, hz)
        // The tone knob adds a click and bends the body into its harmonics.
        let click = noise.next() * v.env2 * bdTone * 0.5
        let s = tanhf(body * (1.1 + bdTone * 1.5) * v.env) * 0.9 + click
        v.env *= bdDecay; v.env2 *= bdClickDecay; v.penv *= bdPitchDecay
        return s
    }

    private func snare(_ v: inout Voice) -> Float {
        let body = (sine(&v.phase, sdHz) + 0.7 * sine(&v.phase2, sdHz * 1.78)) * v.env2 * (1 - sdSnappy * 0.4)
        let snap = sdNoise.tick(noise.next()) * v.env * sdSnappy * 1.4
        v.env *= sdDecay; v.env2 *= sdBodyDecay
        return tanhf((body * 0.6 + snap) * 1.2)
    }

    private func clap(_ v: inout Voice) -> Float {
        // Three bursts about ten milliseconds apart, then a tail.
        if v.t < 3 * clapBurst {
            if v.t % clapBurst == 0 { v.env2 = 1 }
            v.env2 *= clapBurstDecay
        } else {
            v.env2 *= cpDecay
            if v.t == 3 * clapBurst { v.env2 = 0.8 }
        }
        v.env = v.env2 // for the "is it done" check and the pad light
        return cpBand.tick(noise.next()) * v.env2 * 2.2
    }

    private func rimshot(_ v: inout Voice) -> Float {
        let ping = (sine(&v.phase, rsHz) + 0.6 * sine(&v.phase2, rsHz * 0.28)) * v.env
        let click = noise.next() * v.env2 * 0.5
        v.env *= rsDecay; v.env2 *= rsClick
        return tanhf(ping * 1.6 + click)
    }

    private func tom(_ v: inout Voice, hz: Float) -> Float {
        let body = sine(&v.phase, hz * (1 + 0.6 * v.penv)) * v.env
        let breath = noise.next() * v.env2 * 0.12
        v.env *= tomDecay; v.env2 *= tomNoiseDecay; v.penv *= tomPitchDecay
        return tanhf(body * 1.3 + breath)
    }

    private func cowbell(_ v: inout Voice) -> Float {
        let dt1 = cbHz / rate, dt2 = cbHz * 1.44 / rate
        v.phase += dt1; if v.phase >= 1 { v.phase -= 1 }
        v.phase2 += dt2; if v.phase2 >= 1 { v.phase2 -= 1 }
        let raw = blepSquare(v.phase, dt1) + blepSquare(v.phase2, dt2)
        let env = v.env * 0.7 + v.env2 * 0.5
        v.env *= cbDecayA; v.env2 *= cbDecayB
        return cbBand.tick(raw) * env * 1.6
    }

    /// The six metallic squares, high-passed once for both hats and the cymbal.
    @inline(__always) private func metallicSample() -> Float {
        var sum: Float = 0
        let hz = Self.metallicHz
        func osc(_ phase: inout Float, _ f: Float) {
            let dt = f / rate
            phase += dt
            if phase >= 1 { phase -= 1 }
            sum += blepSquare(phase, dt)
        }
        osc(&metallic.0, hz[0]); osc(&metallic.1, hz[1]); osc(&metallic.2, hz[2])
        osc(&metallic.3, hz[3]); osc(&metallic.4, hz[4]); osc(&metallic.5, hz[5])
        return sum / 6
    }

    private func closedHat(_ v: inout Voice, _ hat: Float) -> Float {
        let s = hat * v.env * 2.4
        v.env *= chDecay
        v.env2 = v.env
        return s
    }

    private func openHat(_ v: inout Voice, _ hat: Float) -> Float {
        // `on` turned off while it still sounds: choked by the closed hat, so it dies fast.
        let s = hat * v.env * 2.4
        v.env *= v.on ? ohDecay : chokeDecay
        v.env2 = v.env
        return s
    }

    private func cymbal(_ v: inout Voice, _ metal: Float) -> Float {
        let src = metal + noise.next() * 0.25
        let a = cyBandA.tick(src) * v.env
        let b = cyBandB.tick(src) * v.env2
        v.env *= cyDecayA; v.env2 *= cyDecayB
        return (a * 1.4 + b * 1.8)
    }

    private func clave(_ v: inout Voice) -> Float {
        let s = sine(&v.phase, 2_500) * v.env
        v.env *= clDecay
        v.env2 = v.env
        return s * 0.9
    }
}
