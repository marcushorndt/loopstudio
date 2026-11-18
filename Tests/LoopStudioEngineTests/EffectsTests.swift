import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

private func sine(_ hz: Double, seconds: Double, amplitude: Float = 0.5) -> [Float] {
    (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / rate)) }
}

private func rms(_ x: ArraySlice<Float>) -> Float {
    guard !x.isEmpty else { return 0 }
    return (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
}

private func peak(_ x: ArraySlice<Float>) -> Float { x.reduce(0) { max($0, abs($1)) } }
private func db(_ a: Float, _ b: Float) -> Float { 20 * log10f(max(a, 1e-9) / max(b, 1e-9)) }

/// Runs an effect over a stereo signal (the same on both sides, or a separate sidechain) in blocks of 256.
private func run(_ id: String, _ params: [String: Double], _ input: [Float], sidechain: [Float]? = nil, block: Int = 256) -> [Float] {
    let effect = DSPEffect.make(id, sampleRate: rate)!
    effect.configure(params)
    var l = input, r = input
    let sc = sidechain ?? []
    var done = 0
    while done < input.count {
        let n = min(block, input.count - done)
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            if let sidechain, sidechain.count >= done + n {
                sc.withUnsafeBufferPointer { sp in
                    effect.process(lp.baseAddress! + done, rp.baseAddress! + done, sidechainL: sp.baseAddress! + done, sidechainR: sp.baseAddress! + done, frames: n)
                }
            } else {
                effect.process(lp.baseAddress! + done, rp.baseAddress! + done, frames: n)
            }
        } }
        done += n
    }
    return l
}

// MARK: EQ

@Test func everyEQHasItsBandsAndStartsFlat() {
    for n in 1...8 {
        let spec = BuiltInEffects.spec("peq\(n)")!
        #expect(spec.bands == n)
        #expect(spec.params.count == n * 5 + 1)
        #expect(DSPEffect.make("peq\(n)", sampleRate: rate) is EQDSP)
        let out = run("peq\(n)", [:], sine(440, seconds: 0.5))
        #expect(abs(db(rms(out[12_000...]), rms(sine(440, seconds: 0.5)[12_000...]))) < 0.05, "EQ \(n) flat by default")
    }
}

@Test func aBellRaisesItsFrequencyAndLeavesTheRest() {
    let p: [String: Double] = ["b1.type": 2, "b1.freq": 1_000, "b1.gain": 12, "b1.q": 2]
    let at = run("peq1", p, sine(1_000, seconds: 0.5)), off = run("peq1", p, sine(100, seconds: 0.5))
    let reference = rms(sine(1_000, seconds: 0.5)[12_000...])
    #expect(abs(db(rms(at[12_000...]), reference) - 12) < 0.5)
    #expect(abs(db(rms(off[12_000...]), reference)) < 0.5)
    // The curve display agrees with the sound.
    let curve = EQDSP.responseDb(at: [100, 1_000], spec: BuiltInEffects.spec("peq1")!, params: p, sampleRate: rate)
    #expect(abs(curve[1] - 12) < 0.2)
    #expect(abs(curve[0]) < 0.2)
}

@Test func aLowCutRemovesTheLowsAndABandThatIsOffDoesNothing() {
    let cut: [String: Double] = ["b1.type": 0, "b1.freq": 1_000, "b1.q": 0.71]
    let low = run("peq1", cut, sine(50, seconds: 0.5)), high = run("peq1", cut, sine(8_000, seconds: 0.5))
    #expect(db(rms(low[12_000...]), rms(sine(50, seconds: 0.5)[12_000...])) < -40)
    #expect(abs(db(rms(high[12_000...]), rms(sine(8_000, seconds: 0.5)[12_000...]))) < 0.5)
    var off = cut
    off["b1.on"] = 0
    let kept = run("peq1", off, sine(50, seconds: 0.5))
    #expect(abs(db(rms(kept[12_000...]), rms(sine(50, seconds: 0.5)[12_000...]))) < 0.05)
}

@Test func eightBandsWorkTogetherAndTheOutputGainApplies() {
    var p: [String: Double] = ["gain": -6]
    for i in 1...8 { p["b\(i).gain"] = 1 } // eight bells of +1 dB spread over the spectrum
    let out = run("peq8", p, sine(1_000, seconds: 0.5))
    let change = db(rms(out[12_000...]), rms(sine(1_000, seconds: 0.5)[12_000...]))
    #expect(change > -6.5 && change < -3, "about -6 dB plus the bells near 1 kHz: \(change)")
}

// MARK: Tape echo

@Test func theTapeEchoRepeatsAfterItsTimeAndFadesWithTheFeedback() {
    var input = [Float](repeating: 0, count: Int(rate * 1.2))
    for i in 0..<48 { input[i] = 0.8 } // a short burst at the start
    let out = run("tapeEcho", ["timeMs": 250, "feedback": 0.5, "wow": 0, "flutter": 0, "mix": 1, "drive": 0], input)
    let step = Int(0.25 * rate)
    func around(_ frame: Int) -> Float { peak(out[max(0, frame - 300)..<min(out.count, frame + 400)]) }
    let first = around(step), second = around(2 * step), third = around(3 * step)
    #expect(first > 0.3, "first echo \(first)")
    #expect(second > first * 0.3 && second < first * 0.8, "second echo \(second) after first \(first)")
    #expect(third < second, "fading")
    // Between the echoes: silence.
    #expect(peak(out[(step + 2_000)..<(2 * step - 2_000)]) < 0.02)
}

@Test func theTapeEchoFollowsTheTempoWhenSynced() {
    let effect = DSPEffect.make("tapeEcho", sampleRate: rate)!
    effect.configure(["timeMs": 10, "timeMsSync": 1, "timeMsDivision": Double(NoteDivision.index("1/4")), "feedback": 0, "wow": 0, "flutter": 0, "mix": 1, "drive": 0])
    #expect(effect.followsTempo)
    effect.clock(frame: 0, beat: 0, quarterSeconds: 0.5) // 120 BPM: a quarter is 24 000 frames
    var l = [Float](repeating: 0, count: Int(rate)), r = l
    for i in 0..<48 { l[i] = 0.8; r[i] = 0.8 }
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in effect.process(lp.baseAddress!, rp.baseAddress!, frames: lp.count) } }
    let echoAt = l.enumerated().dropFirst(2_000).max { $0.element < $1.element }!.offset
    #expect(abs(echoAt - 24_000) < 100, "echo at \(echoAt)")
}

@Test func feedbackPastOneSingsInsteadOfExploding() {
    var input = [Float](repeating: 0, count: Int(rate * 3))
    for i in 0..<48 { input[i] = 0.8 }
    let out = run("tapeEcho", ["timeMs": 100, "feedback": 1.2, "wow": 0, "flutter": 0, "mix": 1, "drive": 0.5], input)
    #expect(peak(out[Int(rate * 2.5)...]) > 0.05, "still ringing")
    #expect(peak(out[...]) < 4, "bounded by the tape saturation")
}

// MARK: Dynamics

@Test func theCompressorDucksToItsSidechain() {
    let quiet = sine(220, seconds: 1, amplitude: 0.05)
    let loud = sine(220, seconds: 1, amplitude: 0.9)
    let p: [String: Double] = ["threshold": -22, "ratio": 10, "knee": 0, "attack": 1, "release": 50, "mix": 1]
    let alone = run("compressor", p, quiet)
    #expect(abs(db(rms(alone[24_000...]), rms(quiet[24_000...]))) < 0.2, "under the threshold on its own")
    let ducked = run("compressor", p, quiet, sidechain: loud)
    let reduction = db(rms(ducked[24_000...]), rms(quiet[24_000...]))
    #expect(reduction < -15, "ducked by the loud sidechain: \(reduction) dB")
}

@Test func theSidechainLowCutIgnoresABassOnTheSidechain() {
    let quiet = sine(2_000, seconds: 1, amplitude: 0.05)
    let bass = sine(40, seconds: 1, amplitude: 0.9)
    let p: [String: Double] = ["threshold": -22, "ratio": 10, "knee": 0, "attack": 1, "release": 50, "scLowCut": 500]
    let out = run("compressor", p, quiet, sidechain: bass)
    #expect(abs(db(rms(out[24_000...]), rms(quiet[24_000...]))) < 1, "the bass does not pass the sidechain low cut")
}

@Test func theSidechainHighCutIgnoresAHatOnTheSidechain() {
    let quiet = sine(200, seconds: 1, amplitude: 0.05)
    let hat = sine(8_000, seconds: 1, amplitude: 0.9)
    let p: [String: Double] = ["threshold": -22, "ratio": 10, "knee": 0, "attack": 1, "release": 50, "scHighCut": 1_000]
    let out = run("compressor", p, quiet, sidechain: hat)
    #expect(abs(db(rms(out[24_000...]), rms(quiet[24_000...]))) < 1, "the hat does not pass the sidechain high cut")
}

@Test func sidechainListenPutsTheFilteredSidechainOnTheOutput() {
    let quiet = sine(200, seconds: 1, amplitude: 0.05)
    let bass = sine(40, seconds: 1, amplitude: 0.9)
    let p: [String: Double] = ["threshold": -22, "ratio": 10, "knee": 0, "attack": 1, "release": 50, "scLowCut": 500, "scListen": 1]
    let out = run("compressor", p, quiet, sidechain: bass)
    // The bass is on the sidechain, the low cut takes it out, and Listen plays what is left: next to nothing.
    #expect(rms(out[24_000...]) < 0.02, "listen plays the filtered sidechain, not the input: \(rms(out[24_000...]))")
    let heard = run("compressor", ["threshold": -22, "ratio": 10, "knee": 0, "attack": 1, "release": 50, "scListen": 1], quiet, sidechain: bass)
    #expect(abs(db(rms(heard[24_000...]), rms(bass[24_000...]))) < 1, "without a filter, listen plays the sidechain as it is")
}

@Test func theOptoCharacterLetsGoFastThenCreeps() {
    // One second loud, then quiet. VCA has released 400 ms later; Opto, lit for a second, still holds some reduction.
    let signal = sine(440, seconds: 1, amplitude: 0.9) + sine(440, seconds: 1, amplitude: 0.05)
    let base: [String: Double] = ["threshold": -20, "ratio": 10, "knee": 0, "attack": 1, "release": 100]
    let vca = run("compressor", base.merging(["character": 0]) { $1 }, signal)
    let opto = run("compressor", base.merging(["character": 1]) { $1 }, signal)
    let at = 48_000 + 19_200 ..< 48_000 + 21_600 // 400 to 450 ms into the quiet part
    let vcaDb = db(rms(vca[at]), rms(signal[at])), optoDb = db(rms(opto[at]), rms(signal[at]))
    #expect(abs(vcaDb) < 0.5, "VCA has released: \(vcaDb) dB")
    #expect(optoDb < -1, "Opto still creeps back: \(optoDb) dB")
    // Right after the loud part both still hold the signal down: the opto starts fast, not slow.
    let early = 48_000 + 480 ..< 48_000 + 960
    #expect(db(rms(opto[early]), rms(signal[early])) < -3, "Opto lets go fast at first")
}

@Test func theKneeMakesTheOnsetGradual() {
    let s = sine(440, seconds: 0.5, amplitude: 0.1) // -20 dB: right at the threshold
    let hard = run("compressor", ["threshold": -20, "ratio": 4, "knee": 0, "attack": 1, "release": 50], s)
    let soft = run("compressor", ["threshold": -20, "ratio": 4, "knee": 12, "attack": 1, "release": 50], s)
    let hardDb = db(rms(hard[12_000...]), rms(s[12_000...])), softDb = db(rms(soft[12_000...]), rms(s[12_000...]))
    #expect(abs(hardDb) < 0.5, "at the threshold a hard knee does nothing yet: \(hardDb)")
    #expect(softDb < -0.6 && softDb > -5, "a soft knee already works at the threshold: \(softDb)")
}

@Test func theLimiterWithLookaheadNeverPassesTheCeiling() {
    var input = sine(100, seconds: 0.5, amplitude: 0.3)
    for i in 10_000..<10_100 { input[i] = 1.0 } // a sudden burst
    let out = run("limiter", ["gain": 12, "ceiling": -1, "lookahead": 2, "release": 80], input)
    let ceiling = powf(10, -1 / 20)
    #expect(peak(out[...]) <= ceiling + 0.001, "peak \(peak(out[...])) over \(ceiling)")
    #expect(DSPEffect.latency(kind: "limiter", params: ["lookahead": 2], sampleRate: rate) == 96)
    // Without look-ahead the first sample of the burst still passes (the old behaviour: clamped, not smoothed).
    let fast = run("limiter", ["gain": 12, "ceiling": -1, "lookahead": 0, "release": 80], input)
    #expect(peak(fast[...]) <= ceiling + 0.001)
}

@Test func theMultibandCompressesOnlyTheBandThatIsLoud() {
    let bass = sine(60, seconds: 1, amplitude: 0.8), top = sine(6_000, seconds: 1, amplitude: 0.05)
    let both = zip(bass, top).map(+)
    let p: [String: Double] = ["lowX": 200, "highX": 2_500, "low.threshold": -30, "low.ratio": 10, "low.attack": 1, "low.release": 50,
                               "mid.threshold": 0, "high.threshold": 0]
    let out = run("multiband", p, both)
    // The high band passes: filter the output through a high-pass to measure it. A quick two-pole at 2 kHz.
    func highs(_ x: [Float]) -> Float {
        var f = Biquad(); f.highpass(2_000, q: 0.707, rate: rate)
        var g = f
        return rms(x.map { g.tick(f.tick($0)) }[24_000...])
    }
    func lows(_ x: [Float]) -> Float {
        var f = Biquad(); f.lowpass(120, q: 0.707, rate: rate)
        var g = f
        return rms(x.map { g.tick(f.tick($0)) }[24_000...])
    }
    #expect(db(lows(out), lows(both)) < -8, "the low band is compressed: \(db(lows(out), lows(both)))")
    #expect(abs(db(highs(out), highs(both))) < 1.5, "the high band is not: \(db(highs(out), highs(both)))")
}

@Test func theMultibandIsFlatWhenNothingCompresses() {
    let p: [String: Double] = ["low.threshold": 0, "mid.threshold": 0, "high.threshold": 0]
    for hz in [50.0, 200, 700, 2_500, 8_000] {
        let s = sine(hz, seconds: 0.5)
        let out = run("multiband", p, s)
        let change = db(rms(out[12_000...]), rms(s[12_000...]))
        #expect(abs(change) < 1, "\(hz) Hz changes by \(change) dB")
    }
}

// MARK: Routing

@Test func aSidechainSourceRendersBeforeItsListener() throws {
    var project = Project(name: "SC", sampleRate: rate)
    // The listener comes first in the project; its sidechain source after it.
    var listener = Track(name: "Bass", kind: .audio)
    var comp = BuiltInEffects.makeSlot("compressor")!
    let source = Track(name: "Kick", kind: .audio)
    comp.sidechain = source.id
    listener.devices = [comp]
    try Command.insertTrack(track: listener, index: 0).apply(to: &project)
    try Command.insertTrack(track: source, index: 1).apply(to: &project)
    let plan = RenderPlan.compile(project, bank: AudioBank())
    let order = plan.trackOrder.compactMap { $0 }
    #expect(order.firstIndex(of: source.id)! < order.firstIndex(of: listener.id)!)
    let node = plan.nodes[order.firstIndex(of: listener.id)!]
    #expect(node.effects[0].sidechain == order.firstIndex(of: source.id))
    #expect(plan.warnings.isEmpty)
}

@Test func aSidechainThatClosesALoopFallsBackToTheOwnInput() throws {
    var project = Project(name: "SC", sampleRate: rate)
    var a = Track(name: "A", kind: .audio)
    let b = Track(name: "B", kind: .returnTrack)
    var comp = BuiltInEffects.makeSlot("compressor")!
    comp.sidechain = b.id
    a.devices = [comp]
    try Command.insertTrack(track: a, index: 0).apply(to: &project)
    try Command.insertTrack(track: b, index: 1).apply(to: &project)
    // B listens to A by a send: A -> B -> (sidechain) A.
    try Command.setSends(id: a.id, sends: [Send(target: b.id)]).apply(to: &project)
    let plan = RenderPlan.compile(project, bank: AudioBank())
    #expect(plan.trackOrder.compactMap { $0 }.count == 2)
    #expect(plan.warnings.contains { $0.contains("loop") })
    #expect(plan.nodes.allSatisfy { $0.effects.allSatisfy { $0.sidechain == nil } })
}

@Test func theSidechainCommandValidatesAndUndoes() throws {
    var project = Project(name: "SC", sampleRate: rate)
    var a = Track(name: "A", kind: .audio)
    let b = Track(name: "B", kind: .audio)
    let comp = BuiltInEffects.makeSlot("compressor")!, eq = BuiltInEffects.makeSlot("eq3")!
    a.devices = [comp, eq]
    try Command.insertTrack(track: a, index: 0).apply(to: &project)
    try Command.insertTrack(track: b, index: 1).apply(to: &project)
    let inverse = try Command.setDeviceSidechain(track: a.id, device: comp.id, source: b.id).apply(to: &project)
    #expect(project.tracks[0].devices[0].sidechain == b.id)
    #expect(throws: CommandError.self) { try Command.setDeviceSidechain(track: a.id, device: comp.id, source: a.id).apply(to: &project) }
    #expect(throws: CommandError.self) { try Command.setDeviceSidechain(track: a.id, device: eq.id, source: b.id).apply(to: &project) }
    _ = try inverse.apply(to: &project)
    #expect(project.tracks[0].devices[0].sidechain == nil)
    // The field survives a round trip through JSON, and an old file without it loads.
    let data = try JSONEncoder().encode(DeviceSlot(format: "builtin", identifier: "compressor", name: "C", sidechain: b.id))
    #expect(try JSONDecoder().decode(DeviceSlot.self, from: data).sidechain == b.id)
}

// MARK: Reverb room shaping, tape wobble, multiband solo

/// How much of the signal is high-frequency: the level of its first difference against its own level.
private func brightness(_ x: ArraySlice<Float>) -> Float {
    let diff = zip(x.dropFirst(), x).map { $0 - $1 }
    return rms(diff[...]) / max(rms(x), 1e-9)
}

@Test func aSmallRoomDiesFasterThanAHall() {
    var impulse = [Float](repeating: 0, count: Int(3 * rate))
    impulse[0] = 1
    let small = run("reverb", ["mix": 1, "size": 0, "damping": 1], impulse)
    let hall = run("reverb", ["mix": 1, "size": 1, "damping": 0], impulse)
    let at = Int(0.5 * rate), end = Int(0.6 * rate)
    #expect(rms(small[at..<end]) < rms(hall[at..<end]) / 20, "small \(rms(small[at..<end])) hall \(rms(hall[at..<end]))")
    #expect(rms(small[Int(1.0 * rate)...]) < 1e-3, "the small damped room is gone after a second")
}

@Test func reverbHighCutDarkensAndLowCutThinsTheTail() {
    var impulse = [Float](repeating: 0, count: Int(1 * rate))
    impulse[0] = 1
    let plain = run("reverb", ["mix": 1, "size": 0.8, "damping": 0], impulse)
    let dark = run("reverb", ["mix": 1, "size": 0.8, "damping": 0, "highCut": 1_500], impulse)
    let window = Int(0.1 * rate)..<Int(0.4 * rate)
    #expect(brightness(dark[window]) < brightness(plain[window]) * 0.6)
    // A low cut on the tail: a 100 Hz tone through the reverb leaves far less wet sound than without it.
    let tone = sine(100, seconds: 1)
    let full = run("reverb", ["mix": 1, "size": 0.5], tone)
    let thin = run("reverb", ["mix": 1, "size": 0.5, "lowCut": 1_000], tone)
    #expect(rms(thin[Int(0.5 * rate)...]) < rms(full[Int(0.5 * rate)...]) * 0.3)
}

@Test func reverbFreezeHoldsTheTail() {
    let fx = DSPEffect.make("reverb", sampleRate: rate)!
    fx.configure(["mix": 1, "size": 0.6])
    var l = sine(440, seconds: 0.5), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in fx.process(lp.baseAddress!, rp.baseAddress!, frames: lp.count) } }
    // Freeze, then feed silence for three seconds: the tail neither grows nor dies.
    fx.configure(["mix": 1, "size": 0.6, "freeze": 1])
    var sl = [Float](repeating: 0, count: Int(3 * rate)), sr = sl
    sl.withUnsafeMutableBufferPointer { lp in sr.withUnsafeMutableBufferPointer { rp in fx.process(lp.baseAddress!, rp.baseAddress!, frames: lp.count) } }
    let early = rms(sl[0..<Int(0.2 * rate)]), late = rms(sl[Int(2.8 * rate)...])
    #expect(early > 0.01)
    #expect(late > early * 0.5 && late < early * 2, "early \(early) late \(late)")
    #expect(sl.allSatisfy { $0.isFinite && abs($0) < 4 })
}

@Test func tapeWowAtFullIsAudibleAndStaysInTheBuffer() {
    // A steady tone through a wobbling tape comes back frequency-modulated: its first difference varies.
    let tone = sine(1_000, seconds: 3)
    let still = run("tapeEcho", ["mix": 1, "feedback": 0, "wow": 0, "flutter": 0, "timeMs": 300, "drive": 0], tone)
    let wobbly = run("tapeEcho", ["mix": 1, "feedback": 0, "wow": 1, "flutter": 1, "timeMs": 300, "drive": 0], tone)
    func spread(_ x: [Float]) -> Float {
        // The brightness over short windows: a modulated pitch makes it vary.
        let win = 2_400
        let values = stride(from: Int(0.5 * rate), to: x.count - win, by: win).map { brightness(x[$0..<$0 + win]) }
        return (values.max() ?? 0) - (values.min() ?? 0)
    }
    #expect(spread(wobbly) > spread(still) * 10 + 1e-4, "still \(spread(still)) wobbly \(spread(wobbly))")
    #expect(wobbly.allSatisfy { $0.isFinite })
}

@Test func multibandSoloHearsOneBand() {
    // A low tone and a high tone: solo on the high band removes the low one, and the other way round.
    let n = Int(1 * rate)
    let mixTone = (0..<n).map { 0.3 * Float(sin(2 * .pi * 80 * Double($0) / rate)) + 0.3 * Float(sin(2 * .pi * 6_000 * Double($0) / rate)) }
    let window = Int(0.5 * rate)..<n
    let both = run("multiband", ["low.threshold": 0, "mid.threshold": 0, "high.threshold": 0], mixTone)
    let highOnly = run("multiband", ["low.threshold": 0, "mid.threshold": 0, "high.threshold": 0, "high.solo": 1], mixTone)
    let lowOnly = run("multiband", ["low.threshold": 0, "mid.threshold": 0, "high.threshold": 0, "low.solo": 1], mixTone)
    #expect(brightness(highOnly[window]) > brightness(both[window]) * 1.3)
    #expect(brightness(lowOnly[window]) < brightness(both[window]) * 0.3)
    #expect(rms(highOnly[window]) < rms(both[window]), "one band is quieter than both")
}
