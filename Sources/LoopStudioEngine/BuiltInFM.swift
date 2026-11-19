import Foundation
import LoopStudioCore

/// The DX7: six sine operators in one of 32 algorithms, phase modulation, sixteen voices.
///
/// The numbers follow the chip, not a textbook. Levels live in a logarithmic scale where one unit is an
/// octave of gain (6 dB) and 1/256 of it is the smallest step; the output level knob moves in 0.75 dB
/// steps above 20, finer below (`levelTable`). An envelope rises on a curve toward 17 octaves and falls
/// in straight log steps, both at a rate from the 0...99 table; a segment that does not move still
/// takes its time (`statics`). A modulator at full level swings the carrier's phase two whole cycles;
/// velocity can push it past that. The feedback operator reads the mean of its own last two outputs.
/// The LFO has the six shapes with the DX7's start phase, the pitch envelope its ±4 octaves.
///
/// Telemetry: 0...5 the envelope level of each operator of the newest voice, 0...1; 6 the voices sounding;
/// 7 the LFO value 0...1; 8 the newest voice's pitch envelope in octaves.
final class FMDSP: DSPInstrument, @unchecked Sendable {
    static let voiceCount = 16
    /// Envelopes, pitch and LFO move once per this many frames; the operator gains interpolate between.
    static let step = 16

    /// One operator of the patch, as the knobs stand.
    struct OpPatch {
        var rates = SIMD4<Float>(99, 99, 99, 99)
        var levels = SIMD4<Float>(99, 99, 99, 0)
        var bp: Int32 = 39, ld: Int32 = 0, rd: Int32 = 0, lc: Int32 = 0, rc: Int32 = 0
        var rs: Int32 = 0, ams: Int32 = 0, kvs: Int32 = 0, ol: Int32 = 0
        var mode: Int32 = 0, coarse: Int32 = 1, fine: Int32 = 0, det: Int32 = 7
        var on = true
    }

    /// An operator envelope: four rates, four levels, the DX7 way.
    struct Env {
        var state: Int32 = 4
        /// The level in octaves of gain; 15 is the full output of a level-99 operator.
        var level: Float = 0
        var target: Float = 0
        /// Octaves per frame.
        var inc: Float = 0
        var rising = false
        var down = false
        /// Frames left in a segment whose level does not move.
        var staticCount: Int32 = 0
        var rates = SIMD4<Float>(99, 99, 99, 99)
        var levels = SIMD4<Float>(99, 99, 99, 0)
        /// The operator's output level with its scalings, in 1/256 octave.
        var outLevel: Int32 = 0
        var rateScaling: Int32 = 0

        /// The smallest level: about -90 dB.
        static let floor: Float = 16.0 / 256
        /// The attack starts here when it starts lower: about -44 dB.
        static let jump: Float = 1716.0 / 256

        mutating func start(srMul: Float) {
            level = 0
            down = true
            advance(0, srMul: srMul)
        }

        mutating func advance(_ new: Int32, srMul: Float) {
            state = new
            guard new < 4 else { return }
            let l = Int32(levels[Int(new)])
            let actual = max(16, (Int32(FMDSP.scaledLevel(l)) >> 1) << 6 + outLevel - 4256)
            target = Float(actual) / 256
            rising = target > level
            let q = min(63, (Int32(rates[Int(new)]) * 41) >> 6 + rateScaling)
            inc = Float(4 + (q & 3)) * exp2f(Float((q >> 2) - 22)) * srMul
            // A segment that stays at its level still lasts: the chip counts it down.
            if target == level || (new == 0 && l == 0) {
                let rate = min(99, Int(rates[Int(new)]) + Int(rateScaling))
                var frames = rate < FMDSP.statics.count ? FMDSP.statics[rate] : 20 * (99 - rate)
                if rate < FMDSP.statics.count, new == 0, l == 0 { frames /= 20 }
                staticCount = Int32(Float(frames) / srMul)
            } else {
                staticCount = 0
            }
        }

        /// Moves `frames` on and returns the level.
        mutating func step(_ frames: Int32, srMul: Float) -> Float {
            if staticCount > 0 {
                staticCount -= frames
                if staticCount <= 0 { staticCount = 0; advance(state + 1, srMul: srMul) }
                return level
            }
            guard state < 3 || (state < 4 && !down) else { return level }
            if rising {
                if level < Env.jump { level = Env.jump }
                level += floorf(17 - level) * inc * Float(frames)
                if level >= target { level = target; advance(state + 1, srMul: srMul) }
            } else {
                level -= inc * Float(frames)
                if level <= target { level = target; advance(state + 1, srMul: srMul) }
            }
            return level
        }

    }

    /// The pitch envelope of a voice: ±4 octaves, straight segments.
    struct PitchEnv {
        var state: Int32 = 4
        var level: Float = 0, target: Float = 0, inc: Float = 0
        var rising = false, down = false

        mutating func start(rates: SIMD4<Float>, levels: SIMD4<Float>, unit: Float) {
            level = Float(FMDSP.pitchLevels[Int(levels[3])]) / 32
            down = true
            advance(0, rates: rates, levels: levels, unit: unit)
        }

        mutating func advance(_ new: Int32, rates: SIMD4<Float>, levels: SIMD4<Float>, unit: Float) {
            state = new
            guard new < 4 else { return }
            target = Float(FMDSP.pitchLevels[Int(levels[Int(new)])]) / 32
            rising = target > level
            inc = Float(FMDSP.pitchRates[Int(rates[Int(new)])]) * unit
        }

        mutating func step(_ frames: Int32, rates: SIMD4<Float>, levels: SIMD4<Float>, unit: Float) -> Float {
            guard state < 3 || (state < 4 && !down) else { return level }
            if rising {
                level += inc * Float(frames)
                if level >= target { level = target; advance(state + 1, rates: rates, levels: levels, unit: unit) }
            } else {
                level -= inc * Float(frames)
                if level <= target { level = target; advance(state + 1, rates: rates, levels: levels, unit: unit) }
            }
            return level
        }
    }

    struct Op {
        var phase: UInt32 = 0
        var inc: UInt32 = 0
        var env = Env()
        /// log2 of the operator's frequency in Hz, before pitch modulation.
        var baseLog: Float = 0
        var fixed = false
        var gain: Float = 0, gainStep: Float = 0
        var ams: Float = 0
        /// The last two outputs, for the feedback.
        var fb0: Float = 0, fb1: Float = 0
    }

    struct Voice {
        var active = false, keyDown = false
        var note: UInt8 = 0
        var transposed: Int32 = 60
        var velocity: Int32 = 100
        var serial: UInt32 = 0
        var pitch = PitchEnv()
    }

    // The patch.
    private let ops: UnsafeMutablePointer<OpPatch>
    private var pitchRates = SIMD4<Float>(99, 99, 99, 99), pitchLevelsP = SIMD4<Float>(50, 50, 50, 50)
    private var algorithm = 0, feedback = 0, keySync = true, transpose = 24
    private var lfoSpeed = 35, lfoDelay = 0, lfoPMD = 0, lfoAMD = 0, lfoSync = true, lfoWave = 0, lfoPMS = 3
    private var volume: Float = 1
    /// Per operator a bit for every operator that modulates it, and the feedback path.
    private var modMask: SIMD8<UInt8> = .zero
    private var carrierMask: UInt8 = 0
    private var fbFrom = 5, fbTo = 5
    private var fbScale: Float = 0
    private let keys: [[String]]
    private let defaults: [String: Double]

    // The voices.
    private let voices: UnsafeMutablePointer<Voice>
    private let voiceOps: UnsafeMutablePointer<Op>
    private var serial: UInt32 = 0
    private var newest = -1

    // The LFO, shared by every voice as on the instrument.
    private var lfoPhase: UInt32 = 0, lfoDelta: UInt32 = 0
    private var lfoDelayState: UInt64 = 0, lfoDelayInc1: UInt64 = 0, lfoDelayInc2: UInt64 = 0, lfoDelayOff = true
    private var lfoRandom: UInt32 = 0
    private var lfoValue: Float = 0.5

    private var bend: Float = 0
    private let rate: Float
    /// 44.1 kHz was the chip's clock: the envelope and LFO constants scale by this.
    private let srMul: Float
    private let pitchUnit: Float
    private let sine: UnsafeMutablePointer<Float>
    private var sounding = 0

    override init(spec: EffectSpec, sampleRate: Double) {
        rate = Float(sampleRate)
        srMul = 44100 / Float(sampleRate)
        pitchUnit = 1 / (21.3 * Float(sampleRate))
        ops = .allocate(capacity: 6)
        ops.initialize(repeating: OpPatch(), count: 6)
        voices = .allocate(capacity: Self.voiceCount)
        voices.initialize(repeating: Voice(), count: Self.voiceCount)
        voiceOps = .allocate(capacity: Self.voiceCount * 6)
        voiceOps.initialize(repeating: Op(), count: Self.voiceCount * 6)
        keys = (1...6).map { op in DX7.operatorKeys.map { DX7.key(op, $0) } + [DX7.key(op, "on")] }
        var d: [String: Double] = [:]
        for p in spec.params { d[p.key] = p.def }
        defaults = d
        sine = Self.sineTable
        super.init(spec: spec, sampleRate: sampleRate)
    }

    deinit {
        ops.deallocate(); voices.deallocate(); voiceOps.deallocate()
    }

    // MARK: Tables

    /// 1024 points of a sine and one more for the wrap.
    nonisolated(unsafe) static let sineTable: UnsafeMutablePointer<Float> = {
        let t = UnsafeMutablePointer<Float>.allocate(capacity: 1025)
        for i in 0...1024 { t[i] = sinf(Float(i) / 1024 * 2 * .pi) }
        return t
    }()

    /// Output levels 0...19: the fine end of the level knob. From 20 up every step is 0.75 dB.
    static let levelTable: [UInt8] = [0, 5, 9, 13, 17, 20, 23, 25, 27, 29, 31, 33, 35, 37, 39, 41, 42, 43, 45, 46]
    @inline(__always) static func scaledLevel(_ l: Int32) -> UInt8 { l >= 20 ? UInt8(28 + l) : levelTable[Int(max(0, l))] }

    /// Frames at 44.1 kHz that a segment lasts when its level does not change, by rate 0...76.
    static let statics: [Int] = [
        1_764_000, 1_764_000, 1_411_200, 1_411_200, 1_190_700, 1_014_300, 992_250, 882_000, 705_600, 705_600, 584_325, 507_150, 502_740,
        441_000, 418_950, 352_800, 308_700, 286_650, 253_575, 220_500, 220_500, 176_400, 145_530, 145_530, 125_685, 110_250, 110_250,
        88_200, 88_200, 74_970, 61_740, 61_740, 55_125, 48_510, 44_100, 37_485, 31_311, 30_870, 27_562, 27_562, 22_050, 18_522, 17_640,
        15_435, 14_112, 13_230, 11_025, 9_261, 9_261, 7_717, 6_615, 6_615, 5_512, 5_512, 4_410, 3_969, 3_969, 3_439, 2_866, 2_690,
        2_249, 1_984, 1_896, 1_808, 1_411, 1_367, 1_234, 1_146, 926, 837, 837, 705, 573, 573, 529, 441, 441,
    ]

    /// Velocity 0...127 in pairs: the level a key adds, before the sensitivity.
    static let velocityTable: [Int32] = [
        0, 70, 86, 97, 106, 114, 121, 126, 132, 138, 142, 148, 152, 156, 160, 163, 166, 170, 173, 174, 178, 181, 184, 186, 189, 190,
        194, 196, 198, 200, 202, 205, 206, 209, 211, 214, 216, 218, 220, 222, 224, 225, 227, 229, 230, 232, 233, 235, 237, 238, 240,
        241, 242, 243, 244, 246, 246, 248, 249, 250, 251, 252, 253, 254,
    ]

    /// The exponential level-scaling curve by groups of three keys from the break point.
    static let expScale: [Int32] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 14, 16, 19, 23, 27, 33, 39, 47, 56, 66, 80, 94, 110, 126, 142, 158, 174, 190, 206, 222, 238, 250]

    static let pitchModSens: [Int32] = [0, 10, 20, 33, 55, 92, 153, 255]
    static let ampModSens: [Float] = [0, 4_342_338.0 / 16_777_216, 7_171_437.0 / 16_777_216, 1]

    static let pitchRates: [Int32] = [
        1, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 16, 16, 17, 18, 18, 19, 20, 21, 22,
        23, 24, 25, 26, 27, 28, 30, 31, 33, 34, 36, 37, 38, 39, 41, 42, 44, 46, 47, 49, 51, 53, 54, 56, 58, 60, 62, 64, 66, 68, 70, 72,
        74, 76, 79, 82, 85, 88, 91, 94, 98, 102, 106, 110, 115, 120, 125, 130, 135, 141, 147, 153, 159, 165, 171, 178, 185, 193, 202,
        211, 232, 243, 254, 255,
    ]
    /// Pitch envelope levels 0...99 in 1/32 octave: 50 is no change, 99 four octaves up.
    static let pitchLevels: [Int32] = [
        -128, -116, -104, -95, -85, -76, -68, -61, -56, -52, -49, -46, -43, -41, -39, -37, -35, -33, -32, -31, -30, -29, -28, -27, -26,
        -25, -24, -23, -22, -21, -20, -19, -18, -17, -16, -15, -14, -13, -12, -11, -10, -9, -8, -7, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4,
        5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 38, 40,
        43, 46, 49, 53, 58, 65, 73, 82, 92, 103, 115, 127,
    ]
    /// The LFO speed knob in Hz, measured on the instrument.
    static let lfoHz: [Float] = [
        0.062541, 0.125031, 0.312393, 0.437120, 0.624610, 0.750694, 0.936330, 1.125302, 1.249609, 1.436782, 1.560915, 1.752081,
        1.875117, 2.062494, 2.247191, 2.374451, 2.560492, 2.686728, 2.873976, 2.998950, 3.188013, 3.369840, 3.500175, 3.682224,
        3.812065, 4.000800, 4.186202, 4.310716, 4.501260, 4.623209, 4.814636, 4.930480, 5.121901, 5.315191, 5.434783, 5.617346,
        5.750431, 5.946717, 6.062811, 6.248438, 6.431695, 6.564264, 6.749460, 6.868132, 7.052186, 7.250580, 7.375719, 7.556294,
        7.687577, 7.877738, 7.993605, 8.181967, 8.372405, 8.504848, 8.685079, 8.810573, 8.986341, 9.122423, 9.300595, 9.500285,
        9.607994, 9.798158, 9.950249, 10.117361, 11.251125, 11.384335, 12.562814, 13.676149, 13.904338, 15.092062, 16.366612,
        16.638935, 17.869907, 19.193858, 19.425019, 20.833333, 21.034918, 22.502250, 24.003841, 24.260068, 25.746653, 27.173913,
        27.578599, 29.052876, 30.693677, 31.191516, 32.658393, 34.317090, 34.674064, 36.416606, 38.197097, 38.550501, 40.387722,
        40.749796, 42.625746, 44.326241, 44.883303, 46.772685, 48.590865, 49.261084,
    ]

    // MARK: Scalings

    /// The velocity's addition to the output level, in 1/256 octave. Sensitivity 0 ignores it.
    static func velocityLevel(_ velocity: Int32, sensitivity: Int32) -> Int32 {
        let v = velocityTable[Int(max(0, min(127, velocity))) >> 1] - 239
        return ((sensitivity * v + 7) >> 3) << 4
    }

    static func scaleCurve(group: Int32, depth: Int32, curve: Int32) -> Int32 {
        var scale: Int32
        if curve == 0 || curve == 3 {
            scale = (group * depth * 329) >> 12
        } else {
            scale = (expScale[Int(min(group, Int32(expScale.count - 1)))] * depth * 329) >> 15
        }
        if curve < 2 { scale = -scale }
        return scale
    }

    /// Keyboard level scaling: the output level change (in the 0...127 scale) for a key.
    static func levelScaling(note: Int32, op: OpPatch) -> Int32 {
        let offset = note - op.bp - 17
        if offset >= 0 { return scaleCurve(group: (offset + 1) / 3, depth: op.rd, curve: op.rc) }
        return scaleCurve(group: -(offset - 1) / 3, depth: op.ld, curve: op.lc)
    }

    static func rateScaling(note: Int32, sensitivity: Int32) -> Int32 {
        (sensitivity * min(31, max(0, note / 3 - 7))) >> 3
    }

    /// log2 of the frequency the operator plays for a key, before pitch modulation.
    static func frequencyLog(note: Int32, op: OpPatch) -> Float {
        if op.mode == 0 {
            var lf = log2f(440) + Float(note - 69) / 12
            let detuneRatio = 0.0209 * expf(-0.396 * lf) / 7
            lf += detuneRatio * lf * Float(op.det - 7)
            lf += op.coarse == 0 ? -1 : log2f(Float(op.coarse))
            if op.fine > 0 { lf += log2f(1 + 0.01 * Float(op.fine)) }
            return lf
        }
        var lf = log2f(10) * 0.01 * Float((op.coarse & 3) * 100 + op.fine)
        if op.det > 7 { lf += 13457.0 / 16_777_216 * Float(op.det - 7) }
        return lf
    }

    // MARK: Patch

    override func configure(_ p: [String: Double]) {
        @inline(__always) func v(_ key: String) -> Double { p[key] ?? defaults[key] ?? 0 }
        @inline(__always) func i(_ key: String) -> Int32 { Int32(v(key).rounded()) }
        for op in 0..<6 {
            let k = keys[op]
            var o = OpPatch()
            o.rates = SIMD4(Float(i(k[0])), Float(i(k[1])), Float(i(k[2])), Float(i(k[3])))
            o.levels = SIMD4(Float(i(k[4])), Float(i(k[5])), Float(i(k[6])), Float(i(k[7])))
            o.bp = i(k[8]); o.ld = i(k[9]); o.rd = i(k[10]); o.lc = i(k[11]); o.rc = i(k[12])
            o.rs = i(k[13]); o.ams = i(k[14]); o.kvs = i(k[15]); o.ol = i(k[16])
            o.mode = i(k[17]); o.coarse = i(k[18]); o.fine = i(k[19]); o.det = i(k[20])
            o.on = v(k[21]) >= 0.5
            ops[op] = o
        }
        pitchRates = SIMD4(Float(i("pr1")), Float(i("pr2")), Float(i("pr3")), Float(i("pr4")))
        pitchLevelsP = SIMD4(Float(i("pl1")), Float(i("pl2")), Float(i("pl3")), Float(i("pl4")))
        algorithm = Int(max(0, min(31, i("alg"))))
        feedback = Int(max(0, min(7, i("fb"))))
        keySync = v("oks") >= 0.5
        transpose = Int(i("transpose"))
        lfoSpeed = Int(max(0, min(99, i("lfs")))); lfoDelay = Int(max(0, min(99, i("lfd"))))
        lfoPMD = Int(i("lpmd")); lfoAMD = Int(i("lamd")); lfoSync = v("lfks") >= 0.5
        lfoWave = Int(max(0, min(5, i("lfw")))); lfoPMS = Int(max(0, min(7, i("lpms"))))
        volume = powf(10, Float(v("volume")) / 20)

        let alg = DX7.algorithms[algorithm]
        var masks = SIMD8<UInt8>.zero
        for op in 0..<6 { for m in alg.modulators[op] { masks[op] |= 1 << UInt8(m) } }
        modMask = masks
        carrierMask = alg.carriers.reduce(0) { $0 | 1 << UInt8($1) }
        fbFrom = alg.feedbackFrom; fbTo = alg.feedbackTo
        fbScale = feedback == 0 ? 0 : exp2f(Float(feedback - 8))
        lfoDelta = UInt32(min(0.45, Self.lfoHz[lfoSpeed] * 1.03319 / rate) * 4_294_967_296)
        let a = 99 - lfoDelay
        lfoDelayOff = a == 99
        if !lfoDelayOff {
            let unit = 25_190_424.0 / Double(rate)
            let a1 = (16 + (a & 15)) << (1 + (a >> 4))
            lfoDelayInc1 = UInt64(unit * Double(a1))
            lfoDelayInc2 = UInt64(unit * Double(max(0x80, a1 & 0xff80)))
        }

        // The notes sounding take the new values: a knob turn is heard while a key is held.
        for vi in 0..<Self.voiceCount where voices[vi].active {
            let voice = voices[vi]
            for op in 0..<6 {
                let o = voiceOps + vi * 6 + op
                prepare(o, patch: ops[op], note: voice.transposed, velocity: voice.velocity)
                if o.pointee.env.state < 4 { o.pointee.env.advance(o.pointee.env.state, srMul: srMul) }
            }
            if voices[vi].pitch.state < 4 {
                voices[vi].pitch.advance(voices[vi].pitch.state, rates: pitchRates, levels: pitchLevelsP, unit: pitchUnit)
            }
        }
    }

    /// Sets an operator's levels, scalings and frequency for a key.
    private func prepare(_ o: UnsafeMutablePointer<Op>, patch: OpPatch, note: Int32, velocity: Int32) {
        var level = Int32(Self.scaledLevel(patch.ol)) + Self.levelScaling(note: note, op: patch)
        level = min(127, level) << 5
        level += Self.velocityLevel(velocity, sensitivity: patch.kvs)
        o.pointee.env.outLevel = patch.on ? max(0, level) : 0
        o.pointee.env.rateScaling = Self.rateScaling(note: note, sensitivity: patch.rs)
        o.pointee.env.rates = patch.rates
        o.pointee.env.levels = patch.levels
        o.pointee.baseLog = Self.frequencyLog(note: note, op: patch)
        o.pointee.fixed = patch.mode != 0
        o.pointee.ams = Self.ampModSens[Int(max(0, min(3, patch.ams)))]
    }

    // MARK: Notes

    override func noteOn(_ note: UInt8, _ velocity: UInt8) {
        // A free voice, else the oldest released one, else the oldest.
        var pick = -1
        var released = -1, oldest = -1
        for vi in 0..<Self.voiceCount {
            let v = voices[vi]
            if !v.active { pick = vi; break }
            if !v.keyDown, released < 0 || v.serial < voices[released].serial { released = vi }
            if oldest < 0 || v.serial < voices[oldest].serial { oldest = vi }
        }
        if pick < 0 { pick = released >= 0 ? released : oldest }
        serial &+= 1
        let transposed = Int32(note) + Int32(transpose) - 24
        voices[pick] = Voice(active: true, keyDown: true, note: note, transposed: transposed, velocity: Int32(velocity), serial: serial)
        voices[pick].pitch.start(rates: pitchRates, levels: pitchLevelsP, unit: pitchUnit)
        for op in 0..<6 {
            let o = voiceOps + pick * 6 + op
            let keepPhase = o.pointee.phase
            o.pointee = Op()
            if !keySync { o.pointee.phase = keepPhase }
            prepare(o, patch: ops[op], note: transposed, velocity: Int32(velocity))
            o.pointee.env.start(srMul: srMul)
        }
        if lfoSync { lfoPhase = (1 << 31) - 1 }
        lfoDelayState = 0
        newest = pick
    }

    override func noteOff(_ note: UInt8) {
        for vi in 0..<Self.voiceCount where voices[vi].active && voices[vi].keyDown && voices[vi].note == note {
            release(vi)
        }
    }

    private func release(_ vi: Int) {
        voices[vi].keyDown = false
        voices[vi].pitch.down = false
        voices[vi].pitch.advance(3, rates: pitchRates, levels: pitchLevelsP, unit: pitchUnit)
        for op in 0..<6 {
            let o = voiceOps + vi * 6 + op
            o.pointee.env.down = false
            o.pointee.env.advance(3, srMul: srMul)
        }
    }

    override func allNotesOff() {
        for vi in 0..<Self.voiceCount where voices[vi].active && voices[vi].keyDown { release(vi) }
    }

    override func clearState() {
        for vi in 0..<Self.voiceCount { voices[vi].active = false }
        sounding = 0
    }

    override func pitchBend(_ amount: Float) { bend = amount * 2 / 12 }

    // MARK: Sound

    @inline(__always) private func lfoSample() -> Float {
        lfoPhase &+= lfoDelta &* UInt32(Self.step)
        let p = lfoPhase
        switch lfoWave {
        case 1: return Float((~p ^ (1 << 31)) >> 8) / 16_777_216
        case 2: return Float((p ^ (1 << 31)) >> 8) / 16_777_216
        case 3: return p < (1 << 31) ? 1 : 0
        case 4: return 0.5 + 0.5 * sine[Int(p >> 22)]
        case 5:
            if p < lfoDelta &* UInt32(Self.step) { lfoRandom = (lfoRandom &* 179 &+ 17) & 0xff }
            return Float((lfoRandom ^ 0x80) + 1) / 256
        default:
            var x = Int32(bitPattern: p >> 7)
            if p >= (1 << 31) { x = ~x }
            return Float(x & ((1 << 24) - 1)) / 16_777_216
        }
    }

    /// The LFO's fade-in after a key: 0 during the delay, then a ramp to 1.
    @inline(__always) private func lfoDelayValue() -> Float {
        if lfoDelayOff { return 1 }
        let delta = lfoDelayState < (1 << 31) ? lfoDelayInc1 : lfoDelayInc2
        let d = lfoDelayState + delta * UInt64(Self.step)
        if d > 0xFFFF_FFFF { return 1 }
        lfoDelayState = d
        if d < (1 << 31) { return 0 }
        return Float(d - (1 << 31)) / 2_147_483_648
    }

    override func renderVoices(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        var anyActive = false
        for vi in 0..<Self.voiceCount where voices[vi].active { anyActive = true; break }
        if !anyActive { return }
        let pmDepth = Float((lfoPMD * 165) >> 6), amDepth = Float((lfoAMD * 165) >> 6) / 256
        let pms = Float(Self.pitchModSens[lfoPMS])
        // One carrier at level 99 and velocity 100 sits near -15 dBFS: room for chords of several carriers.
        let outScale = volume / 12
        let fbTo = self.fbTo, fbFrom = self.fbFrom, fbScale = self.fbScale, masks = modMask, carriers = carrierMask
        let sine = self.sine
        let scale32: Float = 4_294_967_296
        while done < frames {
            let n = min(Self.step, frames - done)
            let nf = Float(n)
            // One LFO reading for the step.
            let lfo = lfoSample()
            let delay = lfoDelayValue()
            lfoValue = lfo
            let pitchLFO = pmDepth * delay * pms * (lfo - 0.5) / 32768
            let amd = amDepth * delay * (1 - lfo)
            for vi in 0..<Self.voiceCount where voices[vi].active {
                let base = voiceOps + vi * 6
                // Pitch for the step: envelope, LFO and bend in octaves.
                let pitchEnv = voices[vi].pitch.step(Int32(n), rates: pitchRates, levels: pitchLevelsP, unit: pitchUnit)
                let modOct = pitchEnv + pitchLFO + bend
                let modFactor = exp2f(modOct), bendFactor = exp2f(bend)
                var alive = voices[vi].keyDown
                for op in 0..<6 {
                    let o = base + op
                    var level = o.pointee.env.step(Int32(n), srMul: srMul)
                    if o.pointee.ams > 0 {
                        // The amplitude modulation takes a share of the level that grows with the depth.
                        let sens = amd * o.pointee.ams
                        level -= level * 0.011849 * expf(4.48 * sens)
                    }
                    var gain = level > Env.floor + 0.001 ? exp2f(level - 14) : 0
                    if gain < 1e-4 { gain = 0 }
                    if gain > 0 { alive = true }
                    o.pointee.gainStep = (gain - o.pointee.gain) / nf
                    let hz = exp2f(o.pointee.baseLog) * (o.pointee.fixed ? bendFactor : modFactor)
                    o.pointee.inc = UInt32(min(0.49, hz / rate) * scale32)
                }
                if !alive {
                    // Silent, key up, every envelope at its last level: the voice is free.
                    var finished = true
                    for op in 0..<6 where (base + op).pointee.env.state != 4 { finished = false; break }
                    if finished { voices[vi].active = false; continue }
                }
                // The frames of the step: operators 6 to 1, modulators before the carriers they drive.
                var y0: Float = 0, y1: Float = 0, y2: Float = 0, y3: Float = 0, y4: Float = 0, y5: Float = 0
                for f in 0..<n {
                    var sum: Float = 0
                    var op = 5
                    while op >= 0 {
                        let o = base + op
                        var mod: Float = 0
                        let m = masks[op]
                        if m != 0 {
                            if m & 1 != 0 { mod += y0 }; if m & 2 != 0 { mod += y1 }; if m & 4 != 0 { mod += y2 }
                            if m & 8 != 0 { mod += y3 }; if m & 16 != 0 { mod += y4 }; if m & 32 != 0 { mod += y5 }
                        }
                        if op == fbTo, fbScale > 0 {
                            let src = base + fbFrom
                            mod += (src.pointee.fb0 + src.pointee.fb1) * fbScale
                        }
                        o.pointee.gain += o.pointee.gainStep
                        let phase = o.pointee.phase &+ UInt32(truncatingIfNeeded: Int64(mod * scale32))
                        o.pointee.phase &+= o.pointee.inc
                        let idx = Int(phase >> 22)
                        let frac = Float(phase & 0x3F_FFFF) * (1.0 / 4_194_304)
                        let s = sine[idx] + (sine[idx + 1] - sine[idx]) * frac
                        let y = s * o.pointee.gain
                        switch op { case 0: y0 = y; case 1: y1 = y; case 2: y2 = y; case 3: y3 = y; case 4: y4 = y; default: y5 = y }
                        if op == fbFrom { o.pointee.fb0 = o.pointee.fb1; o.pointee.fb1 = y }
                        if carriers & (1 << UInt8(op)) != 0 { sum += y }
                        op -= 1
                    }
                    let out = sum * outScale
                    l[done + f] += out
                    r[done + f] += out
                }
            }
            done += n
        }
        var count = 0
        for vi in 0..<Self.voiceCount where voices[vi].active { count += 1 }
        sounding = count
    }

    override func writeTelemetry() {
        if newest >= 0, voices[newest].active {
            for op in 0..<6 { telemetry[op] = max(0, (voiceOps + newest * 6 + op).pointee.env.level) / 16 }
            telemetry[8] = voices[newest].pitch.level
        } else {
            for op in 0..<6 { telemetry[op] = 0 }
            telemetry[8] = 0
        }
        telemetry[6] = Float(sounding)
        telemetry[7] = lfoValue
    }
}
