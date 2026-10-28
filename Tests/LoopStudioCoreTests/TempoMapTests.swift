import Foundation
import Testing
@testable import LoopStudioCore

@Test func constantTempoConvertsExactly() {
    let map = TempoMap(bpm: 120)
    #expect(abs(map.seconds(at: 960) - 0.5) < 1e-12)
    #expect(map.frame(at: 3840, sampleRate: 48_000) == Frame(96_000))
    #expect(map.tick(atFrame: 96_000, sampleRate: 48_000) == Tick(3840))
}

@Test func linearRampMatchesTheIntegral() {
    // 100 to 200 BPM over 4 quarter notes: t = (60/960) * L / (b1 - b0) * ln(b1 / b0)
    let map = TempoMap(points: [TempoPoint(tick: 0, bpm: 100, ramp: true), TempoPoint(tick: 3840, bpm: 200)])
    let expected = (60.0 / 960.0) * 3840.0 / 100.0 * log(2.0)
    #expect(abs(map.seconds(at: 3840) - expected) < 1e-9)
    #expect(abs(map.bpm(at: 1920) - 150) < 1e-9)
}

@Test func roundTripOverManyTicks() {
    let map = TempoMap(points: [
        TempoPoint(tick: 0, bpm: 90, ramp: true),
        TempoPoint(tick: 7680, bpm: 140),
        TempoPoint(tick: 20_000, bpm: 60, ramp: true),
        TempoPoint(tick: 50_000, bpm: 175),
    ])
    var rng = SplitMix64(seed: 7)
    for _ in 0..<20_000 {
        let t = Tick(Int64(rng.int(10_000_000)))
        #expect(map.tick(atSeconds: map.seconds(at: t)) == t)
    }
}

@Test func secondsAreMonotonic() {
    let map = TempoMap(points: [TempoPoint(tick: 0, bpm: 40, ramp: true), TempoPoint(tick: 9600, bpm: 400)])
    var last = -Double.infinity
    for t in stride(from: Int64(-2000), to: 30_000, by: 37) {
        let s = map.seconds(at: Tick(t))
        #expect(s > last)
        last = s
    }
}

@Test func ticksBeforeZeroUseTheFirstTempo() {
    let map = TempoMap(bpm: 120)
    #expect(abs(map.seconds(at: -960) + 0.5) < 1e-12)
    #expect(map.tick(atSeconds: -0.5) == Tick(-960))
    #expect(map.frame(at: -960, sampleRate: 48_000) == Frame(-24_000))
}

@Test func initNormalizesPoints() {
    let map = TempoMap(points: [
        TempoPoint(tick: 500, bpm: 5000),
        TempoPoint(tick: 500, bpm: 90),
        TempoPoint(tick: 100, bpm: 1),
    ])
    #expect(map.points.first?.tick == Tick(0))
    #expect(map.points.map(\.tick) == [0, 100, 500])
    #expect(map.points.allSatisfy { TempoMap.bpmRange.contains($0.bpm) })
    #expect(map.points.last?.bpm == 90)
    #expect(TempoMap(points: []).points.count == 1)
}

@Test func nanTempoBecomesDefault() {
    #expect(TempoMap(bpm: .nan).points[0].bpm == 120)
}

@Test func tempoMapCodableRoundTrip() throws {
    let map = TempoMap(points: [TempoPoint(tick: 0, bpm: 100, ramp: true), TempoPoint(tick: 960, bpm: 130)])
    let data = try JSONEncoder().encode(map)
    #expect(try JSONDecoder().decode(TempoMap.self, from: data) == map)
}

@Test func timeSignatureBarLength() {
    #expect(TimeSignature(4, 4).ticksPerBar == Tick(3840))
    #expect(TimeSignature(6, 8).ticksPerBar == Tick(2880))
    #expect(TimeSignature(3, 3).denominator == 4)
}
