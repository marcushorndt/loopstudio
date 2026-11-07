import Foundation
import LoopStudioCore

// Live Cut is a port of Livecut by Rémy Muller (mdsp @ smartelectronix, 2003-2004), released under the
// GNU General Public License, version 2 or later. Livecut carries the cut procedures of the BBCut library
// by Nick Collins for SuperCollider ("Algorithmic Composition Methods for Breakbeat Science"). This file
// keeps the procedures as they are, including the weights and templates, and changes the player where the
// engine asks for it: a seeded random source, a sound that passes dry outside a phrase, a pitch that is
// read on the fly, and a cut that starts on its exact frame.

/// A seeded random source for the cutter. The same seed and bar give the same cuts, so an export sounds
/// like the playback and a looped bar cuts the same way every pass.
struct CutRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed ^ 0xD1B5_4A32_D192_ED03
        _ = next()
    }

    /// SplitMix64.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func float(_ min: Double, _ max: Double) -> Double {
        min + (max - min) * Double(next() >> 11) / Double(1 << 53)
    }

    /// An integer in `min...max`, as Livecut rounds it.
    mutating func int(_ min: Int, _ max: Int) -> Int {
        Int((0.5000001 + float(Double(min), Double(max))).rounded(.down))
    }

    mutating func chance(_ p: Double) -> Bool { float(0, 1) < p }

    /// The index of one of `weights`, drawn by weight.
    mutating func weighted(_ weights: [Double]) -> Int {
        let total = weights.reduce(0, +)
        let v = float(0, total)
        var sum = 0.0
        for (i, w) in weights.enumerated() {
            sum += w
            if v < sum { return i }
        }
        return weights.count - 1
    }
}

/// One cut: `size` frames in the block, of which the first `length` play (the duty), with its level, its pan
/// (-1 left, 1 right) and its pitch in cents.
struct CutInfo {
    var size = 0
    var length = 0
    var pan: Float = 0
    var amp: Float = 1
    var cents: Float = 0
}

/// The cuts of one block, in memory allocated once: no procedure makes more than `capacity` cuts.
final class CutList {
    static let capacity = 512
    let cuts: UnsafeMutablePointer<CutInfo>
    private(set) var count = 0

    init() {
        cuts = .allocate(capacity: Self.capacity)
        cuts.initialize(repeating: CutInfo(), count: Self.capacity)
    }

    deinit { cuts.deallocate() }

    /// Starts a block of `n` fresh cuts (clamped to the capacity) and returns how many.
    @discardableResult
    func resize(_ n: Int) -> Int {
        count = max(0, min(n, Self.capacity))
        for i in 0..<count { cuts[i] = CutInfo() }
        return count
    }

    subscript(i: Int) -> CutInfo {
        get { cuts[i] }
        set { cuts[i] = newValue }
    }

    func reverse() {
        var a = 0, b = count - 1
        while a < b { swap(&cuts[a], &cuts[b]); a += 1; b -= 1 }
    }
}

/// What every procedure shapes its cuts with: the ranges a cut's level, pan and pitch are drawn from, the
/// duty of a cut and of a fill cut, and the phrase length in bars.
struct CutShaping {
    var minAmp = 1.0, maxAmp = 1.0
    var minPan = 0.0, maxPan = 0.0
    var minDetune = 0.0, maxDetune = 0.0
    var duty = 1.0, fillDuty = 1.0
    var minPhrase = 1, maxPhrase = 4
    /// A cut longer than this is clamped: the player's buffer.
    var maxCut = Int.max

    mutating func choosePhraseLength(_ random: inout CutRandom) -> Int { random.int(minPhrase, maxPhrase) }
}

/// Nick Collins's BBCutProc11: cuts of an odd number of units, each played `repeats` times, and a stutter
/// of one unit cell (or a fraction of it) in the last part of a phrase.
struct CutProc11 {
    var stutterChance = 0.8, stutterArea = 0.5
    /// How often a cut sounds in a row, the first time included.
    var minRepeats = 1, maxRepeats = 2

    private static let stutterMultipliers = [1, 2, 3, 4, 6, 8]
    private static let stutterWeights = [0.4, 0.3, 0.1, 0.1, 0.05, 0.05]

    func chooseCuts(_ cuts: CutList, unitsInBlock: inout Int, unitsDone: Int, totalUnits: Int, subdiv: Int,
                    spu: Double, shaping: CutShaping, random: inout CutRandom) {
        let unitsLeft = totalUnits - unitsDone
        if Double(unitsLeft) / Double(subdiv) < stutterArea && random.chance(stutterChance) {
            // The end of the phrase: a stutter of a unit cell divided by the multiplier.
            let multiplier = Self.stutterMultipliers[random.weighted(Self.stutterWeights)]
            let repeats = cuts.resize(unitsLeft * multiplier)
            let unitsInThisCut = 1.0 / Double(multiplier)
            unitsInBlock = Int(Double(repeats) * unitsInThisCut)
            let startPan = random.float(shaping.minPan, shaping.maxPan), endPan = random.float(shaping.minPan, shaping.maxPan)
            let startAmp = random.float(shaping.minAmp, shaping.maxAmp), endAmp = random.float(shaping.minAmp, shaping.maxAmp)
            let endDetune = random.float(shaping.minDetune, shaping.maxDetune)
            let cutLength = min(shaping.maxCut, Int(unitsInThisCut * spu))
            for i in 0..<repeats {
                let phase = Double(i) / Double(repeats)
                var c = CutInfo()
                c.size = cutLength
                c.length = Int(Double(cutLength) * shaping.fillDuty)
                c.pan = Float(startPan + (endPan - startPan) * phase)
                c.amp = Float(startAmp + (endAmp - startAmp) * phase)
                c.cents = Float(endDetune * phase)
                cuts[i] = c
            }
            return
        }
        // units = 2x + 1, so the cuts syncopate against the beat.
        var unitsInCut = 2 * Int(random.float(0, Double(subdiv) / 4) + 0.5) + 1
        var repeats = random.int(minRepeats, maxRepeats)
        while unitsInCut > unitsLeft { unitsInCut -= 2 }
        if unitsInCut < 0 { unitsInCut = 0 }
        while repeats * unitsInCut > unitsLeft {
            if repeats > 1 {
                repeats -= 1
            } else if unitsLeft <= subdiv / 2 + 1 {
                unitsInCut = unitsLeft; repeats = 1
            } else {
                unitsInCut = 1; repeats = 1
            }
        }
        unitsInBlock = repeats * unitsInCut
        let n = cuts.resize(repeats)
        for i in 0..<n {
            var c = CutInfo()
            c.size = min(shaping.maxCut, Int(Double(unitsInCut) * spu))
            c.length = Int(shaping.duty * Double(unitsInCut) * spu)
            c.amp = Float(random.float(shaping.minAmp, shaping.maxAmp))
            cuts[i] = c
        }
    }
}

/// WarpCut: blocks of one, two or four units, played straight, as a regular roll, or as a roll that speeds
/// up (or, reversed, slows down) by `accel` from cut to cut.
struct WarpCutProc {
    var straightChance = 0.3, regularChance = 0.5, ritardChance = 0.5, accel = 0.9

    private static let blockSizes = [1, 2, 4]
    private static let blockWeights = [0.5, 0.4, 0.1]
    private static let repeatChoices = [4, 8, 16, 32]

    private func chooseRepeats(barsInBlock: Double, _ random: inout CutRandom) -> Int {
        barsInBlock < 1 ? Self.repeatChoices[random.int(0, 2)] : Self.repeatChoices[random.int(1, 3)]
    }

    func chooseCuts(_ cuts: CutList, unitsInBlock: inout Int, unitsDone: Int, totalUnits: Int, subdiv: Int,
                    spu: Double, shaping: CutShaping, random: inout CutRandom) {
        let unitsLeft = totalUnits - unitsDone
        unitsInBlock = min(Self.blockSizes[random.weighted(Self.blockWeights)], unitsLeft)
        if random.chance(straightChance) {
            let temp = Double(unitsInBlock)
            cuts.resize(1)
            var c = CutInfo()
            c.size = min(shaping.maxCut, Int(spu * temp))
            // The duty is quantized to units, so the cut ends on the grid.
            c.length = Int(Double(max(Int(shaping.duty * temp), 1)) * spu)
            c.amp = Float(random.float(shaping.minAmp, shaping.maxAmp))
            cuts[0] = c
            return
        }
        let repeats = cuts.resize(chooseRepeats(barsInBlock: Double(unitsInBlock) / Double(subdiv), &random))
        let startPan = random.float(shaping.minPan, shaping.maxPan), endPan = random.float(shaping.minPan, shaping.maxPan)
        let startAmp = random.float(shaping.minAmp, shaping.maxAmp), endAmp = random.float(shaping.minAmp, shaping.maxAmp)
        let endDetune = random.float(shaping.minDetune, shaping.maxDetune)
        if random.chance(regularChance) {
            let temp = Double(unitsInBlock) / Double(repeats)
            for i in 0..<repeats {
                let phase = Double(i) / Double(repeats)
                var c = CutInfo()
                c.size = min(shaping.maxCut, Int(spu * temp + 0.5))
                c.length = Int(Double(c.size) * shaping.fillDuty)
                c.pan = Float(startPan + (endPan - startPan) * phase)
                c.amp = Float(startAmp + (endAmp - startAmp) * phase)
                c.cents = Float(endDetune * phase)
                cuts[i] = c
            }
            return
        }
        // A geometric roll: the sizes sum to the block, each `accel` times the one before.
        let temp = Double(unitsInBlock) * (1 - accel) / (1 - pow(accel, Double(repeats)))
        for i in 0..<repeats {
            let phase = Double(i) / Double(repeats)
            var c = CutInfo()
            c.size = min(shaping.maxCut, Int(spu * temp * pow(accel, Double(i))))
            c.length = Int(Double(c.size) * shaping.fillDuty)
            c.pan = Float(startPan + (endPan - startPan) * phase)
            c.amp = Float(startAmp + (endAmp - startAmp) * phase)
            c.cents = Float(endDetune * phase)
            cuts[i] = c
        }
        if random.chance(ritardChance) { cuts.reverse() }
    }
}

/// SQPusher: Squarepusher's drum programming. Quaver by quaver, the chance of a pair of semiquavers in place
/// of a quaver follows the position in the bar times `activity`; the last bar of a phrase plays one of
/// thirteen fill templates, in beats.
struct SQPusherProc {
    var activity = 0.5
    private var fill = false
    private var fillNumber = 0, fillPos = 0

    /// The weight of a busy quaver by its place in the bar.
    private static let quaverWeights = [0.0, 0.3, 0.0, 0.5, 0.7, 0.8, 0.9, 0.6]

    /// The fill templates of Livecut: each a list of sub-blocks, each sub-block the cut lengths in beats.
    /// Every template sums to four beats. Two of them carry Livecut's own slips (a length pushed into the
    /// wrong sub-block); they still sum to a bar, so they stay as they are.
    static let templates: [[[Double]]] = [
        [[0.75, 0.75, 0.75, 0.75], [1.0]],
        [[0.5, 1.0], [1.0], [1.0, 0.5]],
        [[0.5], [1.0, 1.0, 1.0], [0.5]],
        [[0.571429], [0.571429, 0.571429], [0.571429, 0.571429], [0.571429], [0.285714, 0.285716]],
        [[1.0, 0.5], [1.0, 0.5], [0.5, 0.5]],
        [[0.5, 0.5], [0.66, 0.67, 0.67], [1.0]],
        [[0.34], [0.33, 0.33, 2.33], [0.34, 0.33], []],
        [[1.4], [0.4, 0.4], [0.6, 0.2], [1.0]],
        [[0.167, 0.167, 0.166, 1.0, 1.0, 0.5], [1.0], []],
        [[1.5, 0.5, 1.0], [0.25, 0.25, 0.25, 0.25]],
        [[0.2, 0.2], [0.4, 0.4], [0.4, 0.4], [2.0]],
        [[0.75, 0.75, 1.0], [0.25, 0.25, 0.25, 0.25, 0.25, 0.25]],
        [[0.5, 1.0], [0.5], [0.125, 0.125, 0.125, 0.125], [1.0], [0.167, 0.167, 0.166]],
    ]

    mutating func startPhrase() { fill = false; fillPos = 0 }

    mutating func chooseCuts(_ cuts: CutList, unitsInBlock: inout Int, unitsDone: Int, totalUnits: Int, subdiv: Int,
                             spu: Double, shaping: CutShaping, random: inout CutRandom) {
        let unitsLeft = subdiv - unitsDone % subdiv // one bar at a time
        let done = Double(unitsDone) / Double(subdiv)
        let beatPos = Int(done * 16) % 4
        let quaver = Int(done * 8) % 8
        let sqChance = Self.quaverWeights[quaver] * activity
        let spb = spu * Double(subdiv) / 4 // frames per beat

        if totalUnits - unitsDone == subdiv {
            fill = true
            fillNumber = random.int(0, Self.templates.count - 1)
            fillPos = 0
        }
        if fill {
            let template = Self.templates[fillNumber]
            // Skip an empty sub-block (a slip in the template).
            while fillPos < template.count && template[fillPos].isEmpty { fillPos += 1 }
            if fillPos < template.count {
                let lengths = template[fillPos]
                let n = cuts.resize(lengths.count)
                var beatsDone = 0.0
                for i in 0..<n {
                    beatsDone += lengths[i]
                    var c = CutInfo()
                    c.size = min(shaping.maxCut, Int(spb * lengths[i]))
                    c.length = Int(spb * lengths[i] * shaping.fillDuty)
                    c.pan = Float(random.float(shaping.minPan, shaping.maxPan))
                    c.amp = Float(random.float(shaping.minAmp, shaping.maxAmp))
                    c.cents = Float(random.float(shaping.minDetune, shaping.maxDetune))
                    cuts[i] = c
                }
                // The block lasts as long as its cuts (Livecut kept the previous block's length here).
                unitsInBlock = max(1, min(unitsLeft, Int((Double(subdiv) * beatsDone / 4).rounded())))
                fillPos += 1
                return
            }
            fill = false
            fillPos = 0
        }

        var temp = 1 + 2 * random.int(0, 1)
        if beatPos == 2 { temp = 1 }
        unitsInBlock = max(1, min(unitsLeft, temp * 8 / subdiv))
        if random.chance(sqChance) {
            // 2 × temp semiquavers.
            let n = cuts.resize(temp * 2)
            for i in 0..<n {
                var c = CutInfo()
                c.size = min(shaping.maxCut, Int(0.25 * spb))
                c.length = Int(0.25 * spb * shaping.duty)
                c.pan = Float(random.float(shaping.minPan, shaping.maxPan))
                c.amp = Float(random.float(shaping.minAmp, shaping.maxAmp))
                c.cents = Float(random.float(shaping.minDetune, shaping.maxDetune))
                cuts[i] = c
            }
        } else {
            // temp quavers: the same span.
            let n = cuts.resize(temp)
            for i in 0..<n {
                var c = CutInfo()
                c.size = min(shaping.maxCut, Int(0.5 * spb))
                c.length = Int(0.5 * spb * shaping.duty)
                c.amp = Float(random.float(shaping.minAmp, shaping.maxAmp))
                c.cents = Float(random.float(shaping.minDetune, shaping.maxDetune))
                cuts[i] = c
            }
        }
    }
}

enum CutProcKind: Int { case cutProc11 = 0, warpCut, sqPusher }

/// The cutter: it counts units through phrases and blocks and asks the chosen procedure for the cuts of
/// each block. The random source is seeded again at every phrase from the seed and the bar.
struct BBCutter {
    var kind = CutProcKind.cutProc11
    var subdiv = 8
    var seed: UInt64 = 1
    var shaping = CutShaping()
    var proc11 = CutProc11()
    var warp = WarpCutProc()
    var pusher = SQPusherProc()

    private(set) var unitsDone = 0, totalUnits = 0, unitsInBlock = 0, unitsInsideBlock = 0
    private var random = CutRandom(seed: 1)
    /// The block the cutter chose last; the player takes it when `blockReady` is set.
    let cuts = CutList()
    private(set) var blockReady = false

    /// Frames per unit at the current tempo.
    var samplesPerUnit = 1_000.0

    var inPhrase: Bool { totalUnits > 0 && unitsDone < totalUnits }
    var phraseProgress: Float { totalUnits > 0 ? Float(unitsDone) / Float(totalUnits) : 0 }
    var blockProgress: Float { unitsInBlock > 0 ? Float(unitsInsideBlock) / Float(unitsInBlock) : 0 }

    mutating func takeBlock() { blockReady = false }

    mutating func reset() {
        unitsDone = 0; totalUnits = 0; unitsInBlock = 0; unitsInsideBlock = 0
        blockReady = false
    }

    private mutating func phrase(bar: Int) {
        random = CutRandom(seed: seed &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(bitPattern: Int64(bar)))
        pusher.startPhrase()
        totalUnits = shaping.choosePhraseLength(&random) * subdiv
        unitsDone = 0
    }

    private mutating func block() {
        unitsInsideBlock = 0
        switch kind {
        case .cutProc11: proc11.chooseCuts(cuts, unitsInBlock: &unitsInBlock, unitsDone: unitsDone, totalUnits: totalUnits, subdiv: subdiv, spu: samplesPerUnit, shaping: shaping, random: &random)
        case .warpCut: warp.chooseCuts(cuts, unitsInBlock: &unitsInBlock, unitsDone: unitsDone, totalUnits: totalUnits, subdiv: subdiv, spu: samplesPerUnit, shaping: shaping, random: &random)
        case .sqPusher: pusher.chooseCuts(cuts, unitsInBlock: &unitsInBlock, unitsDone: unitsDone, totalUnits: totalUnits, subdiv: subdiv, spu: samplesPerUnit, shaping: shaping, random: &random)
        }
        if unitsInBlock < 1 { unitsInBlock = 1 }
        blockReady = cuts.count > 0
    }

    /// One unit passed: `sd` is the unit in its bar, `bar` the bar. A phrase starts only on a downbeat;
    /// a block starts when the one before is done.
    mutating func unit(bar: Int, sd: Int) {
        if totalUnits <= 0 || unitsDone >= totalUnits || unitsDone < 0 {
            guard sd == 0 else { return }
            phrase(bar: bar)
        }
        if unitsInsideBlock >= unitsInBlock || unitsInsideBlock < 0 { block() }
        unitsInsideBlock += 1
        unitsDone += 1
    }

    /// The song jumped (a seek, a loop): the counters move by the difference, then the unit passes.
    mutating func setPosition(bar: Int, sd: Int) {
        let delta = sd - unitsDone % max(1, subdiv)
        unitsInsideBlock += delta
        unitsDone += delta
        unit(bar: bar, sd: sd)
    }
}

/// The Live Cut effect: the cutter drives a player that records the first cut of every block and replays it
/// for the repeats, each at its own level, pan and pitch. Outside a phrase (before the first downbeat) the
/// sound passes dry.
final class LiveCutDSP: DSPEffect, @unchecked Sendable {
    private var cutter = BBCutter()
    private var mix: Float = 1
    private var fade = 1
    /// Where the cutter's bar starts, as a share of the song's bar. Its units count from there.
    private var offset = 0.0

    // The player.
    private let capacity: Int
    private let bufL: UnsafeMutablePointer<Float>, bufR: UnsafeMutablePointer<Float>
    private var active = false
    private var currentCut = 0
    private var inputIndex = 0, readIndex = 0, maxCutLength = 0
    private var readPhase = 0.0, ratio = 1.0
    private var ll: Float = 1, lr: Float = 0, rl: Float = 0, rr: Float = 1

    // The position: units are counted from the bar; a boundary inside a grid step fires on its frame.
    private var lastUnit = Int.min
    private var gridFrame = Int64.min
    private var gridOffset = 0
    private var pendingOffset = -1, pendingUnit = 0, pendingBar = 0, pendingSd = 0

    private static let subdivisions = [6, 8, 12, 16, 18, 24, 32]

    override init(spec: EffectSpec, sampleRate: Double) {
        capacity = Int(sampleRate * 4)
        bufL = .allocate(capacity: capacity); bufL.initialize(repeating: 0, count: capacity)
        bufR = .allocate(capacity: capacity); bufR.initialize(repeating: 0, count: capacity)
        super.init(spec: spec, sampleRate: sampleRate)
        followsTempo = true
        cutter.shaping.maxCut = capacity
    }

    deinit { bufL.deallocate(); bufR.deallocate() }

    override func configure(_ p: [String: Double]) {
        cutter.kind = CutProcKind(rawValue: Int(value(p, "proc").rounded())) ?? .cutProc11
        cutter.subdiv = Self.subdivisions[max(0, min(Self.subdivisions.count - 1, Int(value(p, "subdiv").rounded())))]
        cutter.seed = UInt64(Int(value(p, "seed").rounded()) + 1)
        offset = Double(value(p, "offset"))
        fade = max(1, Int(Double(value(p, "fadeMs")) * 0.001 * sampleRate))
        mix = value(p, "mix")
        var s = cutter.shaping
        s.minAmp = Double(value(p, "minAmp")); s.maxAmp = Double(value(p, "maxAmp"))
        s.minPan = Double(value(p, "minPan")); s.maxPan = Double(value(p, "maxPan"))
        s.minDetune = Double(value(p, "minPitch")); s.maxDetune = Double(value(p, "maxPitch"))
        s.duty = Double(value(p, "duty")); s.fillDuty = Double(value(p, "fillDuty"))
        s.minPhrase = Int(value(p, "minPhrase").rounded()) + 1
        s.maxPhrase = max(s.minPhrase, Int(value(p, "maxPhrase").rounded()) + 1)
        cutter.shaping = s
        cutter.proc11.minRepeats = Int(value(p, "minRep").rounded()) + 1
        cutter.proc11.maxRepeats = max(cutter.proc11.minRepeats, Int(value(p, "maxRep").rounded()) + 1)
        cutter.proc11.stutterChance = Double(value(p, "stutter"))
        cutter.proc11.stutterArea = Double(value(p, "area"))
        cutter.warp.straightChance = Double(value(p, "straight"))
        cutter.warp.regularChance = Double(value(p, "regular"))
        cutter.warp.ritardChance = Double(value(p, "ritard"))
        cutter.warp.accel = Double(value(p, "speed"))
        cutter.pusher.activity = Double(value(p, "activity"))
    }

    override func reset() {
        cutter.reset()
        active = false
        lastUnit = Int.min
        pendingOffset = -1
        gridFrame = Int64.min
    }

    /// The cutter's bar at `beat`: its number and the units since its start. The offset moves the start
    /// behind the song's downbeat; before it, the position still belongs to the bar before.
    private func position(at beat: Double) -> (bar: Int, units: Double) {
        let length = max(0.001, barBeats)
        var start = barStart + offset * length
        var bar = Int((barStart / length).rounded(.down))
        if beat < start { start -= length; bar -= 1 }
        return (bar, (beat - start) / length * Double(cutter.subdiv))
    }

    override func step(frame: Int64, beat: Double) {
        if frame != gridFrame { gridFrame = frame; gridOffset = 0; pendingOffset = -1 }
        cutter.samplesPerUnit = quarterSeconds * sampleRate * barBeats / Double(cutter.subdiv)
        let subdiv = cutter.subdiv
        // Units are counted across bars, so a bar line is one more unit, not a jump; the bar number seeds the phrase.
        let (barIndex, u) = position(at: beat)
        let sd = max(0, min(subdiv - 1, Int(u.rounded(.down))))
        let index = barIndex * subdiv + sd
        func place(_ i: Int) -> (bar: Int, sd: Int) {
            let sd = ((i % subdiv) + subdiv) % subdiv
            return ((i - sd) / subdiv, sd)
        }
        if index != lastUnit {
            if index == lastUnit + 1 { cutter.unit(bar: barIndex, sd: sd) } else { cutter.setPosition(bar: barIndex, sd: sd) }
            lastUnit = index
        }
        // The next boundary inside this grid step starts its block on the frame, not at the step's start.
        let toNext = Int(((Double(sd + 1) - u) * cutter.samplesPerUnit).rounded())
        if toNext < 32 {
            pendingOffset = max(0, toNext)
            pendingUnit = index + 1
            let at = place(pendingUnit)
            pendingBar = at.bar; pendingSd = at.sd
        }
    }

    private func startBlock() {
        guard cutter.blockReady else { return }
        cutter.takeBlock()
        let cuts = cutter.cuts
        active = cuts.count > 0
        guard active else { return }
        currentCut = 0
        inputIndex = 0; readIndex = 0; readPhase = 0; ratio = 1
        maxCutLength = 0
        for i in 0..<cuts.count { maxCutLength = max(maxCutLength, cuts[i].size) }
        maxCutLength = min(maxCutLength, capacity)
        setMatrix(cuts[0])
    }

    private func setMatrix(_ c: CutInfo) {
        let pan = c.pan, amp = c.amp, a = pan * Float.pi / 2
        ll = amp * (pan < 0 ? 1 : cosf(a))
        lr = amp * (pan < 0 ? 0 : sinf(a))
        rl = amp * (pan > 0 ? 0 : -sinf(a))
        rr = amp * (pan > 0 ? 1 : cosf(a))
    }

    @inline(__always) private func envelope(_ i: Int, _ size: Int) -> Float {
        let span = fade * 3
        var env: Float = 1
        if i < span { env *= 1 - expf(-5 * Float(i) / Float(fade)) }
        if size - i < span { env *= 1 - expf(5 * Float(i - size) / Float(fade)) }
        return env
    }

    override func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        var k = 0
        while k < frames {
            if pendingOffset >= 0 && pendingOffset == gridOffset + k {
                pendingOffset = -1
                if pendingUnit != lastUnit {
                    if pendingUnit == lastUnit + 1 { cutter.unit(bar: pendingBar, sd: pendingSd) } else { cutter.setPosition(bar: pendingBar, sd: pendingSd) }
                    lastUnit = pendingUnit
                }
            }
            if cutter.blockReady { startBlock() }
            let stop = pendingOffset >= 0 ? min(frames, pendingOffset - gridOffset) : frames
            if stop <= k { k = frames; continue }
            tick(l, r, from: k, to: stop)
            k = stop
        }
        gridOffset += frames
        meters[0] = cutter.blockProgress
        meters[1] = cutter.phraseProgress
        meters[2] = active ? 1 : 0
    }

    private func tick(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, from: Int, to: Int) {
        let cuts = cutter.cuts
        let wet = mix, dry = 1 - mix
        for k in from..<to {
            let inL = l[k], inR = r[k]
            guard active else { continue }
            if inputIndex < maxCutLength { bufL[inputIndex] = inL; bufR[inputIndex] = inR; inputIndex += 1 }
            let cut = cuts[currentCut]
            var outL: Float = 0, outR: Float = 0
            if readIndex < cut.length {
                let pos = Int(readPhase)
                var a: Float = 0, b: Float = 0
                if pos < inputIndex {
                    a = bufL[pos]; b = bufR[pos]
                    let frac = Float(readPhase - Double(pos))
                    if frac > 0 && pos + 1 < inputIndex {
                        a += (bufL[pos + 1] - a) * frac
                        b += (bufR[pos + 1] - b) * frac
                    }
                }
                let env = envelope(readIndex, cut.length)
                outL = env * (ll * a + rl * b)
                outR = env * (lr * a + rr * b)
                readIndex += 1
                readPhase += ratio
            } else {
                readIndex += 1
            }
            if readIndex >= cut.size {
                currentCut += 1
                readIndex = 0; readPhase = 0
                if currentCut < cuts.count {
                    let next = cuts[currentCut]
                    setMatrix(next)
                    ratio = abs(next.cents) > 1e-6 ? pow(2, Double(next.cents) / 1_200) : 1
                } else {
                    active = false
                }
            }
            l[k] = outL * wet + inL * dry
            r[k] = outR * wet + inR * dry
        }
    }
}
