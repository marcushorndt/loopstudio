import LoopStudioCore
import Testing
@testable import LoopStudioEngine

@Suite struct RecorderTests {
    typealias E = MIDIRecorder.Event

    @Test func pairsNotesAndClosesHeldOnes() {
        let events = [
            E(frame: 100, status: 0x90, data1: 60, data2: 90),
            E(frame: 300, status: 0x80, data1: 60, data2: 0),
            E(frame: 400, status: 0x90, data1: 64, data2: 80),
            E(frame: 500, status: 0x90, data1: 67, data2: 0), // note-on with velocity 0 for a pitch never opened
        ]
        let notes = MIDIRecorder.notes(from: events, endFrame: 1000) { $0 }
        #expect(notes.count == 2)
        #expect(notes[0].pitch == 60 && notes[0].tick == Tick(100) && notes[0].length == Tick(200))
        #expect(notes[1].pitch == 64 && notes[1].length == Tick(600)) // held until the end
    }

    @Test func retriggerClosesTheOldNote() {
        let events = [
            E(frame: 0, status: 0x90, data1: 60, data2: 100),
            E(frame: 50, status: 0x90, data1: 60, data2: 100),
            E(frame: 80, status: 0x80, data1: 60, data2: 0),
        ]
        let notes = MIDIRecorder.notes(from: events, endFrame: 100) { $0 }
        #expect(notes.count == 2)
        #expect(notes[0].length == Tick(50) && notes[1].length == Tick(30))
    }

    @Test func zeroLengthNoteGetsOneTick() {
        let events = [E(frame: 10, status: 0x90, data1: 60, data2: 100), E(frame: 10, status: 0x80, data1: 60, data2: 0)]
        let notes = MIDIRecorder.notes(from: events, endFrame: 100) { $0 }
        #expect(notes.first?.length == Tick(1))
    }
}

@Test func hostClockConvertsBothWays() {
    let ticks = HostClock.ticks(fromSeconds: 0.25)
    #expect(abs(HostClock.seconds(fromTicks: Int64(ticks)) - 0.25) < 1e-6)
    // The transport began 0.1 s after the take: 4800 frames at 48 kHz.
    let base: UInt64 = 1_000_000
    #expect(abs(HostClock.frames(from: base, to: base + HostClock.ticks(fromSeconds: 0.1), rate: 48_000) - 4_800) <= 1)
    // And before it: negative.
    #expect(HostClock.frames(from: base + HostClock.ticks(fromSeconds: 0.1), to: base, rate: 48_000) < 0)
}
