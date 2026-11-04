import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

private func sine(_ hz: Double, seconds: Double, amplitude: Float = 0.5) -> [Float] {
    (0..<Int(rate * seconds)).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / rate)) }
}

private func rms(_ x: ArraySlice<Float>) -> Float { sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))) }

/// Zero crossings per second: twice the frequency of a tone.
private func crossings(_ x: ArraySlice<Float>) -> Double {
    var n = 0
    var last = x.first ?? 0
    for v in x.dropFirst() { if (v >= 0) != (last >= 0) { n += 1 }; last = v }
    return Double(n) / (Double(x.count) / rate)
}

/// Feeds `input` through the effect in 256-frame blocks and returns the output.
private func feed(_ effect: DSPEffect, _ input: [Float]) -> [Float] {
    var l = input, r = input
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        var k = 0
        while k < input.count {
            let n = min(256, input.count - k)
            effect.process(lp.baseAddress! + k, rp.baseAddress! + k, frames: n)
            k += n
        }
    } }
    return l
}

private let base: [String: Double] = ["sizeMs": 100, "density": 40, "window": 0, "sprayMs": 0, "pitch": 0, "pitchSpread": 0,
                                      "reverse": 0, "panSpread": 0, "level": 0, "mix": 1, "feedback": 0, "position": 0.05]

/// A frozen buffer plays on without input, at the pitch it was recorded; a pitch of twelve doubles it.
@Test func aFrozenBufferPlaysOnAndPitches() {
    let effect = DSPEffect.make("granulator", sampleRate: rate)!
    effect.configure(base.merging(["record": 1]) { $1 })
    _ = feed(effect, sine(440, seconds: 1))
    effect.configure(base.merging(["record": 0]) { $1 })
    let frozen = feed(effect, [Float](repeating: 0, count: Int(rate)))
    #expect(rms(frozen[...]) > 0.05, "sound without input: \(rms(frozen[...]))")
    let hz = crossings(frozen[...]) / 2
    #expect(abs(hz - 440) < 25, "the recorded tone: \(hz) Hz")
    effect.configure(base.merging(["record": 0, "pitch": 12]) { $1 })
    let up = feed(effect, [Float](repeating: 0, count: Int(rate)))
    let hzUp = crossings(up[Int(rate / 4)...]) / 2
    #expect(abs(hzUp - 880) < 50, "an octave up: \(hzUp) Hz")
}

/// The position reads back through the buffer: near the head the tone, further back the silence before it.
@Test func thePositionReadsBackThroughTheBuffer() {
    let effect = DSPEffect.make("granulator", sampleRate: rate)!
    effect.configure(base.merging(["record": 1]) { $1 })
    _ = feed(effect, [Float](repeating: 0, count: Int(rate)) + sine(300, seconds: 1))
    effect.configure(base.merging(["record": 0, "position": 0.05]) { $1 }) // 0.4 s back: the tone
    let near = feed(effect, [Float](repeating: 0, count: Int(rate / 2)))
    effect.configure(base.merging(["record": 0, "position": 0.2]) { $1 }) // 1.6 s back: the silence
    let far = feed(effect, [Float](repeating: 0, count: Int(rate / 2)))
    #expect(rms(near[...]) > 0.05, "the tone: \(rms(near[...]))")
    #expect(rms(far[Int(rate / 8)...]) < 0.01, "the silence before it: \(rms(far[Int(rate / 8)...]))")
}

/// A dense cloud of long grains with feedback stays bounded; the grains are marked for the display.
@Test func aDenseCloudStaysBounded() {
    let effect = DSPEffect.make("granulator", sampleRate: rate)!
    effect.configure(base.merging(["record": 1, "density": 100, "sizeMs": 500, "feedback": 0.9, "window": 2, "sprayMs": 500, "pitchSpread": 12, "reverse": 0.5, "panSpread": 1]) { $1 })
    var r = CutRandom(seed: 3)
    let noise = (0..<Int(rate * 3)).map { _ in Float(r.float(-0.9, 0.9)) }
    let out = feed(effect, noise)
    #expect(out.allSatisfy { $0.isFinite && abs($0) < 4 }, "bounded")
    #expect(rms(out[Int(rate * 2)...]) > 0.05, "a cloud: \(rms(out[Int(rate * 2)...]))")
    #expect(effect.meters[2] > 0.3, "many grains sound: \(effect.meters[2])")
    #expect((0..<DSPEffect.markCount).contains { effect.marks![$0] >= 0 })
    #expect((0..<DSPEffect.waveformBins).contains { effect.waveform![$0] > 0.5 }, "the peaks reach the display")
}

/// Dry/wet at zero passes the sound as it is, and every window keeps the level in range.
@Test func dryPassesAndEveryWindowIsSane() {
    let input = sine(220, seconds: 0.5)
    let dryEffect = DSPEffect.make("granulator", sampleRate: rate)!
    dryEffect.configure(base.merging(["record": 1, "mix": 0]) { $1 })
    #expect(feed(dryEffect, input) == input)
    for window in 0..<6 {
        let effect = DSPEffect.make("granulator", sampleRate: rate)!
        effect.configure(base.merging(["record": 1, "window": Double(window), "density": 60]) { $1 })
        let out = feed(effect, sine(220, seconds: 1))
        let level = rms(out[Int(rate / 2)...])
        #expect(level > 0.05 && level < 1, "window \(window): \(level)")
    }
}

/// The cloud is as loud as the sound that goes in, give or take 3 dB, with every window and at any density.
@Test func theCloudKeepsTheLevelOfTheInput() {
    let input = sine(220, seconds: 2)
    let inLevel = rms(input[...])
    for (window, density, sizeMs) in [(0, 40.0, 120.0), (1, 80.0, 60.0), (2, 20.0, 200.0), (3, 60.0, 90.0), (4, 100.0, 40.0), (5, 100.0, 40.0)] {
        let effect = DSPEffect.make("granulator", sampleRate: rate)!
        effect.configure(base.merging(["record": 1, "window": Double(window), "density": density, "sizeMs": sizeMs]) { $1 })
        let out = feed(effect, input)
        let level = rms(out[Int(rate)...])
        let dB = 20 * log10(level / inLevel)
        #expect(abs(dB) < 3, "window \(window) at \(density)/s, \(sizeMs) ms: \(dB) dB")
    }
}

/// Feedback at its top with a loud input stays below full scale: the knee in the loop.
@Test func feedbackStaysBounded() {
    let effect = DSPEffect.make("granulator", sampleRate: rate)!
    effect.configure(base.merging(["record": 1, "feedback": 1, "density": 60]) { $1 })
    let out = feed(effect, sine(110, seconds: 4, amplitude: 0.95))
    #expect(out.allSatisfy { $0.isFinite && abs($0) < 2 })
}
