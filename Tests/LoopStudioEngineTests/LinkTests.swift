import Foundation
import Testing
@testable import LoopStudioEngine

@Test func theLinkClockIsTheHostClockInMicroseconds() {
    let link = LinkSession(bpm: 120)
    let host = mach_absolute_time()
    let micros = LinkSession.micros(fromHost: host)
    #expect(abs(micros - link.nowMicros) < 5_000, "within 5 ms of Link's own reading")
    let back = LinkSession.host(fromMicros: micros)
    #expect(abs(Int64(bitPattern: back) - Int64(bitPattern: host)) < 100, "round trip to within 100 host ticks")
}

@Test func aloneInTheSessionTheTempoAndTheBeatAreOurs() {
    let link = LinkSession(bpm: 120)
    #expect(!link.isEnabled, "off until the app turns it on: no network traffic from a test")
    #expect(link.snapshot().tempo == 120)
    let now = link.nowMicros
    link.setTempo(100, atMicros: now)
    #expect(link.snapshot().tempo == 100)

    // Alone, beat 7.5 goes exactly where it was asked for, and the phase in a bar of 4 is 3.5 there.
    let at = now + 10_000
    let start = link.requestBeat(7.5, atMicros: at, quantum: 4)
    #expect(start == at)
    #expect(abs(link.beat(atMicros: at, quantum: 4) - 7.5) < 1e-6)
    #expect(abs(link.phase(atMicros: at, quantum: 4) - 3.5) < 1e-6)
    // One beat at 100 BPM is 600 ms.
    #expect(abs(link.beat(atMicros: at + 600_000, quantum: 4) - 8.5) < 1e-3)

    link.setIsPlaying(true, atMicros: at)
    let snap = link.snapshot()
    #expect(snap.isPlaying && snap.playTimeMicros == at)
    link.setIsPlaying(false, atMicros: at + 1)
    #expect(!link.snapshot().isPlaying)
}
