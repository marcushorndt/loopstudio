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
        #expect(DSPEffect.make(spec.id, sampleRate: rate) != nil, "\(spec.id)")
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
