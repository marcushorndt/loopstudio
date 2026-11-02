import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

private func sine(_ hz: Double, _ n: Int, amp: Float = 0.5) -> [Float] {
    (0..<n).map { amp * Float(sin(2 * .pi * hz * Double($0) / rate)) }
}

/// Runs a block through an effect and returns the left channel.
private func run(_ id: String, _ params: [String: Double] = [:], _ input: [Float], block: Int = 512) -> [Float] {
    let fx = DSPEffect.make(id, sampleRate: rate)!
    fx.configure(params)
    var l = input, r = input
    var done = 0
    while done < input.count {
        let n = min(block, input.count - done)
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            fx.process(lp.baseAddress! + done, rp.baseAddress! + done, frames: n)
        } }
        done += n
    }
    return l
}

private func peak(_ x: ArraySlice<Float>) -> Float { x.reduce(0) { max($0, abs($1)) } }

@Test func everyCatalogEffectHasDSP() {
    for spec in BuiltInEffects.all {
        // A rack has no DSP of its own: its chains carry the devices.
        if !spec.isRack { #expect(DSPEffect.make(spec.id, sampleRate: rate) != nil, "\(spec.id)") }
        for p in spec.params { #expect(p.min <= p.def && p.def <= p.max, "\(spec.id).\(p.key) default in range") }
    }
}

@Test func utilityGainAndWidth() {
    let quiet = run("utility", ["gain": -6.0206], sine(440, 4800))
    #expect(abs(peak(quiet[1000...]) - 0.25) < 0.01)
    let mono = run("utility", ["width": 0], sine(440, 4800)) // identical channels stay identical
    #expect(abs(peak(mono[1000...]) - 0.5) < 0.01)
}

@Test func lowPassRemovesHighFrequencies() {
    let high = run("filter", ["type": 0, "cutoff": 500], sine(10_000, 9600))
    #expect(peak(high[2000...]) < 0.01)
    let low = run("filter", ["type": 0, "cutoff": 5_000], sine(200, 9600))
    #expect(peak(low[2000...]) > 0.45)
    let hp = run("filter", ["type": 1, "cutoff": 5_000], sine(200, 9600))
    #expect(peak(hp[2000...]) < 0.02)
}

@Test func eqBoostsTheBand() {
    let boosted = run("eq3", ["mid": 12, "midFreq": 1_000], sine(1_000, 9600))
    #expect(peak(boosted[3000...]) > 1.8) // 0.5 amplitude plus 12 dB is about 2.0
    let flat = run("eq3", [:], sine(1_000, 9600))
    #expect(abs(peak(flat[3000...]) - 0.5) < 0.02)
}

@Test func delayRepeatsAfterTheSetTime() {
    var impulse = [Float](repeating: 0, count: 48_000)
    impulse[0] = 1
    let out = run("delay", ["timeMs": 100, "feedback": 0, "mix": 1, "pingPong": 0], impulse)
    let echo = 4_800
    #expect(abs(out[echo] - 1) < 0.01)
    #expect(peak(out[0..<(echo - 5)]) < 0.001)
}

@Test func delayFeedbackDecays() {
    var impulse = [Float](repeating: 0, count: 96_000)
    impulse[0] = 1
    let out = run("delay", ["timeMs": 100, "feedback": 0.5, "mix": 1, "pingPong": 0], impulse)
    #expect(abs(out[9_600] - 0.5) < 0.02)
    #expect(abs(out[14_400] - 0.25) < 0.02)
}

@Test func reverbMakesATailAndResetClearsIt() {
    var impulse = [Float](repeating: 0, count: 48_000)
    impulse[0] = 1
    let out = run("reverb", ["mix": 1, "size": 0.8], impulse)
    #expect(peak(out[12_000..<24_000]) > 0.0005, "there is a tail half a second later")
    #expect(!out.contains { $0.isNaN || abs($0) > 4 })

    let fx = DSPEffect.make("reverb", sampleRate: rate)!
    fx.configure(["mix": 1])
    var l = impulse, r = impulse
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in fx.process(lp.baseAddress!, rp.baseAddress!, frames: 4_800) } }
    fx.reset()
    var silent = [Float](repeating: 0, count: 4_800), silentR = silent
    silent.withUnsafeMutableBufferPointer { lp in silentR.withUnsafeMutableBufferPointer { rp in fx.process(lp.baseAddress!, rp.baseAddress!, frames: 4_800) } }
    #expect(peak(silent[...]) == 0)
}

@Test func compressorReducesLoudSignals() {
    let loud = run("compressor", ["threshold": -20, "ratio": 8, "attack": 1, "release": 100], sine(440, 48_000, amp: 0.9))
    #expect(peak(loud[24_000...]) < 0.5)
    let quiet = run("compressor", ["threshold": -20, "ratio": 8], sine(440, 48_000, amp: 0.05))
    #expect(abs(peak(quiet[24_000...]) - 0.05) < 0.005)
}

@Test func limiterNeverPassesTheCeiling() {
    let out = run("limiter", ["gain": 12, "ceiling": -6], sine(440, 48_000, amp: 0.9))
    #expect(peak(out[...]) <= Float(pow(10, -6.0 / 20)) + 0.0001)
}

@Test func blockSizeDoesNotChangeEffectOutput() {
    let input = sine(330, 20_000) + sine(1_500, 20_000)
    for id in ["utility", "filter", "eq3", "delay", "reverb", "compressor", "limiter"] {
        let a = run(id, [:], input, block: 64)
        let b = run(id, [:], input, block: 4096)
        #expect(a == b, "\(id) gives the same samples at block 64 and 4096")
    }
}

@Test func rebuiltRendererKeepsTheTail() {
    var project = Project(name: "T", sampleRate: rate)
    var track = Track(name: "A", kind: .audio)
    var delay = BuiltInEffects.makeSlot("delay")!
    delay.params = ["timeMs": 100, "feedback": 0.5, "mix": 1]
    track.devices = [delay]
    try! Command.insertTrack(track: track, index: 0).apply(to: &project)
    let bank = AudioBank()

    let first = Renderer(plan: RenderPlan.compile(project, bank: bank))
    var l = [Float](repeating: 0, count: 512), r = l
    // Feed an impulse through the delay by hand: the renderer has no clip, so use the effect directly.
    let fx = first.instancesForTesting[delay.id]!
    l[0] = 1; r[0] = 1
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in fx.process(lp.baseAddress!, rp.baseAddress!, frames: 512) } }

    let second = Renderer(plan: RenderPlan.compile(project, bank: bank), reusing: first)
    #expect(second.instancesForTesting[delay.id] === fx, "same instance carried over")

    var changed = project
    try! Command.setDeviceParam(track: track.id, device: delay.id, key: "mix", value: 0.5).apply(to: &changed)
    let third = Renderer(plan: RenderPlan.compile(changed, bank: bank), reusing: second)
    #expect(third.instancesForTesting[delay.id] === fx, "a knob change keeps the instance")

    try! Command.removeDevice(track: track.id, device: delay.id).apply(to: &changed)
    let fourth = Renderer(plan: RenderPlan.compile(changed, bank: bank), reusing: third)
    #expect(fourth.instancesForTesting.isEmpty)
}

@Test func aKeptEffectChangesOnlyOnTheAudioThread() {
    var project = Project(name: "K", sampleRate: rate)
    var track = Track(name: "A", kind: .audio)
    var utility = BuiltInEffects.makeSlot("utility")!
    utility.params = ["gain": 0, "width": 1]
    track.devices = [utility]
    try! Command.insertTrack(track: track, index: 0).apply(to: &project)
    let first = Renderer(plan: RenderPlan.compile(project, bank: AudioBank()))
    let fx = first.instancesForTesting[utility.id]!

    func level() -> Float {
        var l = [Float](repeating: 0.5, count: 64), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in fx.process(lp.baseAddress!, rp.baseAddress!, frames: 64) } }
        return l[0]
    }
    var changed = project
    try! Command.setDeviceParam(track: track.id, device: utility.id, key: "gain", value: -100).apply(to: &changed)
    let second = Renderer(plan: RenderPlan.compile(changed, bank: AudioBank()), reusing: first)
    #expect(level() == 0.5, "building the new renderer leaves the running effect alone")

    var l = [Float](repeating: 0, count: 64), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        second.process(startFrame: 0, frames: 64, outLeft: lp.baseAddress!, outRight: rp.baseAddress!)
    } }
    #expect(level() == 0, "the first block of the new renderer applies the knob")
}

// MARK: Tempo sync

/// Like `run`, but clocks the effect on the 32-frame grid at a constant tempo, as the renderer does.
private func runClocked(_ id: String, _ params: [String: Double], _ input: [Float], bpm: Double, block: Int) -> [Float] {
    let fx = DSPEffect.make(id, sampleRate: rate)!
    fx.configure(params)
    var l = input, r = input
    var done = 0
    let quarter = 60 / bpm
    while done < input.count {
        let n = min(block, input.count - done)
        var k = 0
        while k < n {
            let f = done + k, grid = f / 32 * 32
            let count = min(n - k, grid + 32 - f)
            fx.clock(frame: Int64(grid), beat: Double(grid) / rate / quarter, quarterSeconds: quarter)
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                fx.process(lp.baseAddress! + f, rp.baseAddress! + f, frames: count)
            } }
            k += count
        }
        done += n
    }
    return l
}

private func division(_ name: String) -> Double { Double(NoteDivision.index(name)) }

@Test func noteValuesHaveTheirLengths() {
    #expect(NoteDivision.all[NoteDivision.index("1/4")].quarters == 1)
    #expect(NoteDivision.all[NoteDivision.index("1/3")].quarters == 4.0 / 3)
    #expect(NoteDivision.all[NoteDivision.index("1/8.")].quarters == 0.75)
    #expect(NoteDivision.all[NoteDivision.index("1/16")].quarters == 0.25)
    let names = NoteDivision.all.map(\.name)
    for name in ["1/1", "1/2", "1/3", "1/4", "1/6", "1/8", "1/16"] { #expect(names.contains(name)) }
}

@Test func aSyncedDelayRepeatsOnTheNoteValue() {
    var impulse = [Float](repeating: 0, count: 48_000)
    impulse[0] = 1
    let params = ["timeMsSync": 1, "timeMsDivision": division("1/8"), "feedback": 0, "mix": 1, "pingPong": 0]
    let out = runClocked("delay", params, impulse, bpm: 120, block: 512)
    #expect(abs(out[12_000] - 1) < 0.01, "an eighth note at 120 BPM is 250 ms")
    #expect(peak(out[0..<11_990]) < 0.001)
    let slow = runClocked("delay", params, impulse, bpm: 60, block: 512)
    #expect(abs(slow[24_000] - 1) < 0.01, "at 60 BPM it is 500 ms")
}

@Test func aSyncedReverbPreDelayHoldsTheWetSound() {
    var impulse = [Float](repeating: 0, count: 48_000)
    impulse[0] = 1
    let params = ["preDelayMsSync": 1, "preDelayMsDivision": division("1/16"), "mix": 1]
    let out = runClocked("reverb", params, impulse, bpm: 120, block: 512)
    #expect(peak(out[0..<6_000]) == 0, "a sixteenth at 120 BPM is 125 ms of silence")
    #expect(peak(out[6_000..<24_000]) > 0.0005)
    let free = run("reverb", ["preDelayMs": 50, "mix": 1], impulse)
    #expect(peak(free[0..<2_400]) == 0)
    #expect(peak(free[2_400..<24_000]) > 0.0005)
}

@Test func theFilterLFOMovesTheSoundAndIgnoresTheBlockSize() {
    let input = sine(330, 24_000) + sine(3_000, 24_000)
    let params = ["cutoff": 800, "lfoAmount": 0.8, "lfoRateSync": 1, "lfoRateDivision": division("1/8")]
    let a = runClocked("filter", params, input, bpm: 120, block: 64)
    let b = runClocked("filter", params, input, bpm: 120, block: 4096)
    #expect(a == b)
    let still = runClocked("filter", ["cutoff": 800], input, bpm: 120, block: 512)
    #expect(a != still)
    let free = runClocked("filter", ["cutoff": 800, "lfoAmount": 0.8, "lfoRate": 3], input, bpm: 120, block: 64)
    #expect(free == runClocked("filter", ["cutoff": 800, "lfoAmount": 0.8, "lfoRate": 3], input, bpm: 120, block: 4096))
}

@Test func theRendererGivesEffectsTheSongTempo() {
    var project = Project(name: "T", sampleRate: rate)
    project.tempoMap = TempoMap(bpm: 90)
    var track = Track(name: "A", kind: .audio)
    var delay = BuiltInEffects.makeSlot("delay")!
    delay.params = ["timeMsSync": 1, "timeMsDivision": division("1/4"), "feedback": 0, "mix": 1, "pingPong": 0]
    track.devices = [delay]
    try! Command.insertTrack(track: track, index: 0).apply(to: &project)
    let renderer = Renderer(plan: RenderPlan.compile(project, bank: AudioBank()), maxBlock: 512)
    var outL = [Float](repeating: 0, count: 512), outR = outL
    outL.withUnsafeMutableBufferPointer { lp in outR.withUnsafeMutableBufferPointer { rp in
        renderer.process(startFrame: 0, frames: 512, outLeft: lp.baseAddress!, outRight: rp.baseAddress!)
    } }
    let fx = renderer.instancesForTesting[delay.id]!
    fx.reset()
    var impulse = [Float](repeating: 0, count: 40_000)
    impulse[0] = 1
    var r = impulse
    impulse.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in fx.process(lp.baseAddress!, rp.baseAddress!, frames: 40_000) } }
    #expect(abs(impulse[32_000] - 1) < 0.01, "a quarter note at 90 BPM is 2/3 s")
}

@Test func syncedKnobsHideTheirSwitchAndNoteValue() {
    let delay = BuiltInEffects.spec("delay")!
    #expect(delay.shownParams.map(\.key) == ["timeMs", "feedback", "pingPong", "mix"])
    #expect(delay.params.contains { $0.key == "timeMsSync" && $0.isSwitch })
    #expect(BuiltInEffects.makeSlot("delay")!.params["timeMsSync"] == 1, "a new delay follows the tempo")
}

@Test func aFreeLFOKeepsMovingWhileTheTransportIsStopped() {
    var project = Project(name: "L", sampleRate: rate)
    var track = Track(name: "A", kind: .audio)
    var filter = BuiltInEffects.makeSlot("filter")!
    filter.params = ["cutoff": 800, "lfoAmount": 0.8, "lfoRate": 3]
    track.devices = [filter]
    try! Command.insertTrack(track: track, index: 0).apply(to: &project)
    let renderer = Renderer(plan: RenderPlan.compile(project, bank: AudioBank()), maxBlock: 512)
    let fx = renderer.instancesForTesting[filter.id]!
    var outL = [Float](repeating: 0, count: 512), outR = outL
    func block(_ start: Int64, transport: Bool) {
        outL.withUnsafeMutableBufferPointer { lp in outR.withUnsafeMutableBufferPointer { rp in
            renderer.process(startFrame: start, frames: 512, transport: transport, outLeft: lp.baseAddress!, outRight: rp.baseAddress!)
        } }
    }
    block(96_000, transport: true)
    #expect(fx.lastClockFrame == 96_000 + 480, "playing: the clock is the song position")
    // Stopped at 96_512: the engine renders the same position again and again; the effect clock runs on.
    block(96_512, transport: false)
    let first = fx.lastClockFrame
    block(96_512, transport: false)
    #expect(fx.lastClockFrame == first + 512, "stopped: one block later, the LFO is one block further")
    block(96_512, transport: true)
    #expect(fx.lastClockFrame == 96_512 + 480, "playing again: back on the song position")
}
