import Testing
@testable import LoopStudioCore

@Test func warpedLoopKeepsItsBeats() {
    var p = Project(name: "t", sampleRate: 48_000)
    p.tempoMap = TempoMap(bpm: 120)
    // Four beats at 100 BPM: 2.4 s.
    let loop = Asset(sha256: "a", name: "loop", frames: 115_200, sampleRate: 48_000, channels: 2, sourceTempo: 100)
    #expect(p.naturalLength(of: loop) == Tick(4 * Tick.perQuarter))
}

@Test func unwarpedAudioKeepsItsSeconds() {
    var p = Project(name: "t", sampleRate: 48_000)
    p.tempoMap = TempoMap(bpm: 120)
    // 30 s with no tempo: 60 beats at 120 BPM.
    let song = Asset(sha256: "b", name: "song", frames: 1_440_000, sampleRate: 48_000, channels: 2)
    #expect(p.naturalLength(of: song) == Tick(60 * Tick.perQuarter))
}
