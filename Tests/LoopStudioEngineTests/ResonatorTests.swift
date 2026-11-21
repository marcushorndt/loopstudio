import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

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

/// The normalised correlation of `x` with itself `lag` frames later.
private func correlation(_ x: ArraySlice<Float>, lag: Int) -> Double {
    var ab = 0.0, aa = 0.0, bb = 0.0
    let start = x.startIndex
    for i in start..<(x.endIndex - lag) {
        let a = Double(x[i]), b = Double(x[i + lag])
        ab += a * b; aa += a * a; bb += b * b
    }
    return ab / max(1e-12, sqrt(aa * bb))
}

/// The lag of the strongest repeat between `lo` and `hi` frames: the period of the ringing.
private func period(_ x: ArraySlice<Float>, _ lo: Int, _ hi: Int) -> Int {
    (lo...hi).max { correlation(x, lag: $0) < correlation(x, lag: $1) }!
}

private func impulse(seconds: Double) -> [Float] {
    var x = [Float](repeating: 0, count: Int(rate * seconds))
    x[0] = 1
    return x
}

/// Only resonator I, bright, fully wet: an impulse rings at the period of the note.
private func single(_ extra: [String: Double] = [:]) -> DSPEffect {
    let fx = DSPEffect.make("resonator", sampleRate: rate)!
    var p: [String: Double] = ["note": 57, "color": 1, "decay": 2, "mix": 1, "r2.on": 0, "r3.on": 0, "r4.on": 0, "r5.on": 0, "width": 0]
    for (k, v) in extra { p[k] = v }
    fx.configure(p)
    fx.reset()
    return fx
}

/// A3 is 220 Hz: the ringing repeats every 48000 / 220 = 218 frames.
@Test func aResonatorRingsAtItsNote() {
    let out = feed(single(), impulse(seconds: 0.5))
    let lag = period(out[2_400..<14_400], 150, 300)
    #expect(abs(lag - 218) <= 1)
}

/// Hollow keeps the note: the sound repeats every period, and half a period later it is upside down
/// (only odd partials).
@Test func hollowKeepsTheNoteWithOddPartials() {
    let out = feed(single(["mode": 1]), impulse(seconds: 0.5))
    let lag = period(out[2_400..<14_400], 150, 300)
    #expect(abs(lag - 218) <= 1)
    #expect(correlation(out[2_400..<14_400], lag: 109) < -0.5)
}

/// A note of the track sets the root: A4 rings at 109 frames; when it ends, the knob's A3 is back.
@Test func aHeldNoteSetsTheRoot() {
    let fx = single()
    let receiver = fx as! any MIDIReceiver
    receiver.sendMIDI(0x90, 69, 100, sampleOffset: 0)
    var out = feed(fx, impulse(seconds: 0.5))
    #expect(abs(period(out[2_400..<14_400], 80, 160) - 109) <= 1)
    receiver.sendMIDI(0x80, 69, 0, sampleOffset: 0)
    fx.reset()
    out = feed(fx, impulse(seconds: 0.5))
    #expect(abs(period(out[2_400..<14_400], 150, 300) - 218) <= 1)
}

/// The decay knob is the time to fall by 60 dB: half a second later the ringing is far quieter.
@Test func decayIsTheTimeToFallBySixtyDecibels() {
    let out = feed(single(["decay": 0.5]), impulse(seconds: 0.8))
    func rms(_ s: ArraySlice<Float>) -> Double { sqrt(s.reduce(0) { $0 + Double($1 * $1) } / Double(s.count)) }
    let early = rms(out[1_000..<3_400]), late = rms(out[25_000..<27_400])
    let fall = 20 * log10(early / max(late, 1e-12))
    #expect(fall > 45 && fall < 75)
}
