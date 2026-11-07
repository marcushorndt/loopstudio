import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0
/// Frames per unit at 120 BPM, 4/4, eight units a bar.
private let spu = 12_000

/// Runs Live Cut over `input` with the song clock of the renderer: one clock per 32 frames, at 120 BPM
/// unless `quarter` says otherwise, in 4/4.
private func runCut(_ params: [String: Double], _ input: [Float], startBeat: Double = 0, quarter: Double = 0.5,
                    barBeats: Double = 4, effect given: DSPEffect? = nil) -> [Float] {
    let effect = given ?? DSPEffect.make("livecut", sampleRate: rate)!
    if given == nil { effect.configure(params) }
    var l = input, r = input
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        var k = 0
        while k < input.count {
            let n = min(32, input.count - k)
            let frame = Int64(k)
            let beat = startBeat + Double(frame) / (quarter * rate)
            let barStart = (beat / barBeats).rounded(.down) * barBeats
            effect.clock(frame: frame, beat: beat, quarterSeconds: quarter, barStart: barStart, barBeats: barBeats)
            effect.process(lp.baseAddress! + k, rp.baseAddress! + k, frames: n)
            k += n
        }
    } }
    return l
}

private func noise(_ count: Int, seed: UInt64 = 7) -> [Float] {
    var r = CutRandom(seed: seed)
    return (0..<count).map { _ in Float(r.float(-0.5, 0.5)) }
}

private func impulses(_ out: [Float]) -> [Int] { out.indices.filter { abs(out[$0]) > 0.5 } }

/// Flat shaping: every cut at full level, centred, in tune, whole.
private let flat: [String: Double] = ["minAmp": 1, "maxAmp": 1, "minPan": 0, "maxPan": 0, "minPitch": 0, "maxPitch": 0,
                                      "duty": 1, "fillDuty": 1, "fadeMs": 0, "mix": 1, "subdiv": 1, "minPhrase": 0, "maxPhrase": 0]

/// The same seed cuts the same way twice; another seed cuts another way.
@Test func theCutterIsDeterministicForItsSeed() {
    let input = noise(Int(rate * 4))
    let p = flat.merging(["proc": 0, "seed": 2, "minPan": -1, "maxPan": 1, "minAmp": 0.3]) { $1 }
    let a = runCut(p, input), b = runCut(p, input)
    #expect(a == b, "the same seed, the same cuts")
    let c = runCut(p.merging(["seed": 3]) { $1 }, input)
    #expect(a != c, "another seed, other cuts")
    #expect(a.allSatisfy { $0.isFinite && abs($0) <= 1 })
}

/// Before the first downbeat the sound passes dry; from the bar on it is cut.
@Test func theSoundPassesDryUntilTheFirstDownbeat() {
    let input = noise(Int(rate * 3))
    // Starts at beat 2.5: one and a half beats (36 000 frames) to the next bar.
    let out = runCut(flat.merging(["proc": 0, "minPan": -1, "maxPan": 1, "minAmp": 0]) { $1 }, input, startBeat: 2.5)
    #expect(Array(out[..<36_000]) == Array(input[..<36_000]), "dry before the bar")
    #expect(Array(out[36_000...]) != Array(input[36_000...]), "cut from the bar on")
}

/// CutProc11 at one occurrence per cut plays the first block live and stutters the rest of the bar: an
/// impulse once per unit comes out once per unit during the first cut, then every cell of the stutter.
@Test func cutProc11StuttersTheEndOfThePhrase() {
    var input = [Float](repeating: 0, count: 8 * spu)
    for u in 0..<8 { input[u * spu + 10] = 1 }
    var stuttered = 0
    for seed in 0..<12 {
        let p = flat.merging(["proc": 0, "seed": Double(seed), "minRep": 0, "maxRep": 0, "stutter": 1, "area": 1]) { $1 }
        let out = runCut(p, input)
        let hits = impulses(out)
        #expect(hits.first == 10, "the live impulse comes through: \(hits.prefix(3))")
        let gaps = Set(zip(hits.dropFirst(), hits).map { $0 - $1 })
        #expect(gaps.count <= 2 && gaps.allSatisfy { spu % $0 == 0 }, "seed \(seed): the gaps are the unit or a cell of it: \(gaps.sorted())")
        #expect(hits.count >= 8, "seed \(seed): at least one hit per unit: \(hits.count)")
        // A stutter cell of one unit sounds like the beat itself; a finer cell shows as a shorter gap.
        if gaps.contains(where: { $0 < spu }) { stuttered += 1 }
    }
    #expect(stuttered >= 3, "finer stutters among the seeds: \(stuttered)")
}

/// A normal cut with two occurrences replays its first unit once, at an odd number of units.
@Test func aRepeatedCutReplaysItsFirstPass() {
    var input = [Float](repeating: 0, count: 8 * spu)
    input[10] = 1
    var seen = Set<Int>()
    for seed in 0..<12 {
        let p = flat.merging(["proc": 0, "seed": Double(seed), "minRep": 1, "maxRep": 1, "stutter": 0]) { $1 }
        let hits = impulses(runCut(p, input))
        #expect(hits.first == 10 && hits.count <= 2, "seed \(seed): \(hits)")
        if hits.count == 2 {
            let units = (hits[1] - hits[0]) / spu
            #expect((hits[1] - hits[0]) % spu == 0 && units % 2 == 1, "seed \(seed): an odd number of units apart: \(hits)")
            seen.insert(units)
        }
    }
    #expect(!seen.isEmpty, "some seed repeats")
}

/// The procedures fill a phrase exactly, for many seeds and subdivisions, and their cuts span their block.
@Test func theProceduresFillTheirPhrases() {
    let cuts = CutList()
    for subdiv in [6, 8, 16, 32] {
        for seed in 0..<40 {
            var random = CutRandom(seed: UInt64(seed))
            var shaping = CutShaping()
            shaping.minPhrase = 1; shaping.maxPhrase = 4
            let total = shaping.choosePhraseLength(&random) * subdiv
            var done = 0, block = 0
            let proc11 = CutProc11(), warp = WarpCutProc()
            var pusher = SQPusherProc()
            var guardCount = 0
            while done < total {
                guardCount += 1
                if guardCount > 1_000 { Issue.record("no progress"); break }
                switch seed % 3 {
                case 0: proc11.chooseCuts(cuts, unitsInBlock: &block, unitsDone: done, totalUnits: total, subdiv: subdiv, spu: 1_000, shaping: shaping, random: &random)
                case 1: warp.chooseCuts(cuts, unitsInBlock: &block, unitsDone: done, totalUnits: total, subdiv: subdiv, spu: 1_000, shaping: shaping, random: &random)
                default: pusher.chooseCuts(cuts, unitsInBlock: &block, unitsDone: done, totalUnits: total, subdiv: subdiv, spu: 1_000, shaping: shaping, random: &random)
                }
                #expect(block >= 1 && cuts.count >= 1, "a block has a size and cuts")
                var span = 0
                for i in 0..<cuts.count { span += cuts[i].size; #expect(cuts[i].length <= cuts[i].size) }
                if seed % 3 != 2 {
                    #expect(abs(span - block * 1_000) <= cuts.count + 1, "subdiv \(subdiv) seed \(seed): the cuts span the block: \(span) vs \(block * 1_000)")
                }
                done += max(1, block)
            }
        }
    }
}

/// A WarpCut roll that slows down has cuts that grow; one that speeds up has cuts that shrink.
@Test func warpCutRollsSpeedUpOrSlowDown() {
    let cuts = CutList()
    var shaping = CutShaping()
    shaping.minPan = -1; shaping.maxPan = 1
    var growing = 0, shrinking = 0, regular = 0, straight = 0
    for seed in 0..<60 {
        var random = CutRandom(seed: UInt64(seed))
        var block = 0
        var warp = WarpCutProc()
        warp.straightChance = 0.2; warp.regularChance = 0.3; warp.ritardChance = 0.5; warp.accel = 0.8
        warp.chooseCuts(cuts, unitsInBlock: &block, unitsDone: 0, totalUnits: 32, subdiv: 8, spu: 10_000, shaping: shaping, random: &random)
        let sizes = (0..<cuts.count).map { cuts[$0].size }
        if sizes.count == 1 { straight += 1; continue }
        if Set(sizes).count <= 2 && abs(sizes.max()! - sizes.min()!) <= 1 { regular += 1; continue }
        if sizes == sizes.sorted() { growing += 1 } else if sizes == sizes.sorted(by: >) { shrinking += 1 } else { Issue.record("neither: \(sizes)") }
        // The pans move from one end of the roll to the other.
        #expect(cuts.count >= 4)
    }
    #expect(growing > 0 && shrinking > 0 && regular > 0 && straight > 0, "all kinds: \(growing) \(shrinking) \(regular) \(straight)")
}

/// Every SQPusher fill template is one bar long.
@Test func theSQPusherFillsAreOneBar() {
    for (n, template) in SQPusherProc.templates.enumerated() {
        let beats = template.flatMap { $0 }.reduce(0, +)
        #expect(abs(beats - 4) < 0.02, "template \(n): \(beats) beats")
    }
}

/// A seek, a loop and a tempo change do not trap the cutter or make it loud.
@Test func seeksAndTempoChangesKeepTheCutterSane() {
    let effect = DSPEffect.make("livecut", sampleRate: rate)!
    effect.configure(flat.merging(["proc": 2, "activity": 1, "minPan": -1, "maxPan": 1, "minPitch": -1_200, "maxPitch": 1_200]) { $1 })
    let input = noise(Int(rate))
    var out: [Float] = []
    for (startBeat, quarter) in [(0.0, 0.5), (7.75, 0.5), (1.5, 0.3), (0.0, 0.5), (14.0, 0.7), (3.9, 0.5)] {
        out += runCut([:], input, startBeat: startBeat, quarter: quarter, effect: effect)
    }
    #expect(out.allSatisfy { $0.isFinite && abs($0) <= 1.01 }, "bounded")
    #expect(out.contains { $0 != 0 })
}

/// The Offset knob moves the cutter's bar behind the song's downbeat. At a quarter bar the first beat still
/// passes dry (it belongs to the bar before, which has no downbeat yet), and the cuts start one beat late.
@Test func theOffsetMovesTheCuttersBar() {
    let input = noise(Int(rate * 3))
    let params = flat.merging(["proc": 0, "minPan": -1, "maxPan": 1, "minAmp": 0, "offset": 0.25]) { $1 }
    let out = runCut(params, input)
    #expect(Array(out[..<24_000]) == Array(input[..<24_000]), "dry for one beat")
    #expect(Array(out[24_000...]) != Array(input[24_000...]), "cut from the moved bar on")
    let plain = runCut(flat.merging(["proc": 0, "minPan": -1, "maxPan": 1, "minAmp": 0]) { $1 }, input)
    #expect(Array(plain[..<96_000]) != Array(input[..<96_000]), "without an offset the first bar is cut")
}
