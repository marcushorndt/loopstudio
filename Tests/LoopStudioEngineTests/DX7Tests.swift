import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

private typealias Script = [(Int, UInt8, UInt8, UInt8)]

private func play(_ params: [String: Double], _ script: Script, seconds: Double, block: Int = 256) -> [Float] {
    let synth = DSPEffect.make("dx7", sampleRate: rate) as! DSPInstrument
    synth.configure(params)
    let n = Int(seconds * rate)
    var l = [Float](repeating: 0, count: n), r = l
    var done = 0
    while done < n {
        let count = min(block, n - done)
        for e in script where e.0 >= done && e.0 < done + count { synth.sendMIDI(e.1, e.2, e.3, sampleOffset: e.0 - done) }
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            synth.render(lp.baseAddress! + done, rp.baseAddress! + done, frames: count)
        } }
        done += count
    }
    return l
}

private func rms(_ x: ArraySlice<Float>) -> Float {
    guard !x.isEmpty else { return 0 }
    return (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
}

private func peak(_ x: ArraySlice<Float>) -> Float { x.reduce(0) { max($0, abs($1)) } }

/// The magnitude of one frequency in the signal, by a plain correlation.
private func magnitude(_ x: ArraySlice<Float>, _ hz: Double) -> Float {
    var re: Double = 0, im: Double = 0
    for (i, v) in x.enumerated() {
        let a = 2 * .pi * hz * Double(i) / rate
        re += Double(v) * cos(a); im += Double(v) * sin(a)
    }
    return Float((re * re + im * im).squareRoot() / Double(x.count) * 2)
}

private func frame(_ seconds: Double) -> Int { Int(seconds * rate) }

/// Operator 1 at level 99 alone, instant envelopes, the others silent.
private func initVoice() -> [String: Double] { DX7.initVoice }

private func set(_ p: inout [String: Double], _ op: Int, _ values: [String: Double]) {
    for (k, v) in values { p[DX7.key(op, k)] = v }
}

@Test func theInitVoiceIsAPureSineAtThePitch() {
    let a = play(initVoice(), [(0, 0x90, 69, 100)], seconds: 0.5)
    let body = a[frame(0.1)..<frame(0.5)]
    let fundamental = magnitude(body, 440), second = magnitude(body, 880), third = magnitude(body, 1320)
    #expect(fundamental > 0.05, "a level-99 carrier is heard: \(fundamental)")
    #expect(second < fundamental * 0.02 && third < fundamental * 0.02, "no harmonics on a bare sine: \(second) \(third)")
    // The carrier at full level and velocity 100 sits near -15 dBFS: the output has room for chords.
    #expect(peak(body) > 0.1 && peak(body) < 0.25)
}

@Test func aModulatorAddsHarmonicsAndTheLevelKnobSetsHowMany() {
    var p = initVoice()
    set(&p, 2, ["ol": 80])
    let a = play(p, [(0, 0x90, 69, 100)], seconds: 0.5)
    let body = a[frame(0.1)..<frame(0.5)]
    let f = magnitude(body, 440), h2 = magnitude(body, 880), h3 = magnitude(body, 1320)
    #expect(h2 > f * 0.2 && h3 > f * 0.05, "phase modulation at ratio 1 makes a harmonic series: \(f) \(h2) \(h3)")
    set(&p, 2, ["ol": 99])
    let bright = play(p, [(0, 0x90, 69, 100)], seconds: 0.5)[frame(0.1)..<frame(0.5)]
    #expect(magnitude(bright, 2200) > magnitude(body, 2200) * 2, "a louder modulator reaches further up the series")
}

@Test func theOutputLevelStepsAre075dBAboveTwenty() {
    func level(_ ol: Double) -> Float {
        var p = initVoice()
        set(&p, 1, ["ol": ol])
        return rms(play(p, [(0, 0x90, 69, 100)], seconds: 0.3)[frame(0.1)..<frame(0.3)])
    }
    let db = 20 * log10(level(99) / level(91))
    #expect(abs(db - 6) < 0.3, "8 steps = 6 dB: \(db)")
    #expect(level(0) < 1e-3, "level 0 is silence")
}

@Test func feedbackOnASingleOperatorMakesASawLikeSpectrum() {
    var p = initVoice()
    p["alg"] = 31 // algorithm 32: six carriers, operator 6 with feedback
    set(&p, 1, ["ol": 0]); set(&p, 6, ["ol": 99])
    p["fb"] = 7
    let a = play(p, [(0, 0x90, 69, 100)], seconds: 0.5)[frame(0.1)..<frame(0.5)]
    let f = magnitude(a, 440), h2 = magnitude(a, 880), h3 = magnitude(a, 1320), h4 = magnitude(a, 1760)
    #expect(h2 > f * 0.25 && h3 > f * 0.1 && h4 > f * 0.05, "the feedback bends the sine toward a saw: \(f) \(h2) \(h3) \(h4)")
    p["fb"] = 0
    let clean = play(p, [(0, 0x90, 69, 100)], seconds: 0.5)[frame(0.1)..<frame(0.5)]
    #expect(magnitude(clean, 880) < magnitude(clean, 440) * 0.02)
}

@Test func theRatioAndFixedModesSetTheOperatorPitch() {
    var p = initVoice()
    set(&p, 1, ["coarse": 2])
    let two = play(p, [(0, 0x90, 69, 100)], seconds: 0.3)[frame(0.1)..<frame(0.3)]
    #expect(magnitude(two, 880) > magnitude(two, 440) * 10, "coarse 2 doubles the pitch")
    set(&p, 1, ["coarse": 0])
    let half = play(p, [(0, 0x90, 69, 100)], seconds: 0.3)[frame(0.1)..<frame(0.3)]
    #expect(magnitude(half, 220) > magnitude(half, 440) * 10, "coarse 0 is half")
    set(&p, 1, ["mode": 1, "coarse": 2, "fine": 0]) // fixed 100 Hz, whatever the key
    let fixed = play(p, [(0, 0x90, 40, 100)], seconds: 0.3)[frame(0.1)..<frame(0.3)]
    #expect(magnitude(fixed, 100) > magnitude(fixed, 82.4) * 10, "fixed mode ignores the key")
}

@Test func theEnvelopeReleasesOnKeyUpAndTheVoiceFrees() {
    var p = initVoice()
    set(&p, 1, ["r4": 60])
    let a = play(p, [(0, 0x90, 69, 100), (frame(0.2), 0x80, 69, 0)], seconds: 1.5)
    #expect(rms(a[frame(0.1)..<frame(0.2)]) > 0.05)
    let soon = rms(a[frame(0.25)..<frame(0.3)]), later = rms(a[frame(0.6)..<frame(0.7)])
    #expect(soon < rms(a[frame(0.1)..<frame(0.2)]) && later < soon, "the release falls: \(soon) \(later)")
    #expect(rms(a[frame(1.3)..<frame(1.5)]) < 1e-3, "and ends")
}

@Test func aSlowAttackTakesItsTime() {
    var p = initVoice()
    set(&p, 1, ["r1": 40])
    let a = play(p, [(0, 0x90, 69, 100)], seconds: 1.5)
    let early = rms(a[frame(0.02)..<frame(0.05)]), mid = rms(a[frame(0.3)..<frame(0.35)]), late = rms(a[frame(1.2)..<frame(1.5)])
    #expect(early < mid && mid < late, "a rate-40 attack rises over a second: \(early) \(mid) \(late)")
}

@Test func velocitySensitivityScalesTheOperator() {
    var p = initVoice()
    let flat = play(p, [(0, 0x90, 69, 30)], seconds: 0.3)[frame(0.1)..<frame(0.3)]
    let flatLoud = play(p, [(0, 0x90, 69, 127)], seconds: 0.3)[frame(0.1)..<frame(0.3)]
    #expect(abs(rms(flat) - rms(flatLoud)) < 1e-3, "sensitivity 0 ignores velocity")
    set(&p, 1, ["kvs": 7])
    let soft = play(p, [(0, 0x90, 69, 30)], seconds: 0.3)[frame(0.1)..<frame(0.3)]
    let loud = play(p, [(0, 0x90, 69, 127)], seconds: 0.3)[frame(0.1)..<frame(0.3)]
    #expect(rms(loud) > rms(soft) * 4, "sensitivity 7 spreads the keys: \(rms(soft)) \(rms(loud))")
}

@Test func levelScalingLowersTheHighKeys() {
    var p = initVoice()
    set(&p, 1, ["bp": 39, "rd": 99, "rc": 0]) // -Lin to the right of C3
    let low = play(p, [(0, 0x90, 48, 100)], seconds: 0.3)[frame(0.1)..<frame(0.3)]
    let high = play(p, [(0, 0x90, 96, 100)], seconds: 0.3)[frame(0.1)..<frame(0.3)]
    #expect(rms(high) < rms(low) * 0.3, "four octaves above the break point the level is well down: \(rms(low)) \(rms(high))")
}

@Test func sixteenVoicesPlayTogether() {
    let script: Script = (0..<16).map { (0, 0x90, UInt8(48 + $0 * 2), 100) }
    let a = play(initVoice(), script, seconds: 0.3)
    let one = play(initVoice(), [(0, 0x90, 60, 100)], seconds: 0.3)
    #expect(rms(a[frame(0.1)..<frame(0.3)]) > rms(one[frame(0.1)..<frame(0.3)]) * 3)
}

@Test func thePitchEnvelopeBendsTheNote() {
    var p = initVoice()
    p["pl1"] = 99; p["pl2"] = 50; p["pl3"] = 50; p["pl4"] = 50
    p["pr1"] = 99; p["pr2"] = 90
    // Rate 99 takes a third of a second over four octaves, rate 90 half a second: the chip was not quick here.
    let a = play(p, [(0, 0x90, 69, 100)], seconds: 1.5)
    let start = a[frame(0.02)..<frame(0.06)], settled = a[frame(1.2)..<frame(1.5)]
    #expect(magnitude(start, 440) < magnitude(settled, 440) * 0.3, "the note starts away from its pitch")
    #expect(magnitude(settled, 440) > 0.05, "and lands on it")
}

@Test func theLFOShakesTheAmplitude() {
    var p = initVoice()
    set(&p, 1, ["ams": 3])
    p["lamd"] = 99; p["lfs"] = 60; p["lfw"] = 0
    let a = play(p, [(0, 0x90, 69, 100)], seconds: 1.0)
    // The level of consecutive 10 ms windows must swing.
    var levels: [Float] = []
    var i = frame(0.2)
    while i + frame(0.01) < a.count { levels.append(rms(a[i..<(i + frame(0.01))])); i += frame(0.01) }
    #expect(levels.max()! > levels.min()! * 2, "amplitude modulation: \(levels.min()!) \(levels.max()!)")
    p["lamd"] = 0
    let still = play(p, [(0, 0x90, 69, 100)], seconds: 1.0)
    let a1 = rms(still[frame(0.5)..<frame(0.51)]), a2 = rms(still[frame(0.7)..<frame(0.71)])
    #expect(abs(a1 - a2) < a1 * 0.05, "no depth, no shake")
}

@Test func everyAlgorithmRendersAndStaysBounded() {
    var p = initVoice()
    for op in 1...6 { set(&p, op, ["ol": 99, "kvs": 7]) }
    p["fb"] = 7
    for alg in 0..<32 {
        p["alg"] = Double(alg)
        let a = play(p, [(0, 0x90, 60, 127), (0, 0x90, 64, 127), (0, 0x90, 67, 127)], seconds: 0.2)
        let pk = peak(a[...])
        // Six carriers at full velocity, three notes: hot, as on the instrument, but finite and in order.
        #expect(pk > 0.01 && pk < 8 && pk.isFinite, "algorithm \(alg + 1): \(pk)")
    }
}

@Test func theAlgorithmTableIsConsistent() {
    for (i, alg) in DX7.algorithms.enumerated() {
        #expect(!alg.carriers.isEmpty, "algorithm \(i + 1) has a carrier")
        for op in 0..<6 {
            let reaches = alg.isCarrier(op) || !alg.targets(of: op).isEmpty
            #expect(reaches, "algorithm \(i + 1): operator \(op + 1) is heard")
            #expect(!alg.modulators[op].contains(op), "no operator lists itself as its modulator")
        }
        #expect((0..<6).contains(alg.feedbackFrom) && (0..<6).contains(alg.feedbackTo))
    }
    // The charted counts: six algorithms with a single chain of four, 32 is six carriers.
    #expect(DX7.algorithms[31].carriers.count == 6)
    #expect(DX7.algorithms[0].modulators[2] == [3] && DX7.algorithms[0].modulators[3] == [4])
    #expect(DX7.algorithms[3].feedbackFrom == 3 && DX7.algorithms[3].feedbackTo == 5)
}
