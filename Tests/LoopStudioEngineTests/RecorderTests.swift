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

    @Test func samePitchOnTwoChannelsMakesTwoNotes() {
        let events = [
            E(frame: 0, status: 0x90, data1: 60, data2: 100),  // channel 1
            E(frame: 10, status: 0x91, data1: 60, data2: 90),  // channel 2
            E(frame: 40, status: 0x80, data1: 60, data2: 0),   // channel 1 off
            E(frame: 70, status: 0x81, data1: 60, data2: 0),   // channel 2 off
        ]
        let notes = MIDIRecorder.notes(from: events, endFrame: 100) { $0 }
        #expect(notes.count == 2)
        #expect(notes[0].channel == 0 && notes[0].length == Tick(40))
        #expect(notes[1].channel == 1 && notes[1].tick == Tick(10) && notes[1].length == Tick(60))
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

// MARK: Per-track takes and recorded controls

@Suite struct PerTrackRecorderTests {
    typealias E = MIDIRecorder.Event

    /// Two keyboards on two armed tracks: each take holds only what its own input played.
    @Test func eachTrackKeepsItsOwnEvents() {
        let a = TrackID(), b = TrackID()
        let recorder = MIDIRecorder()
        recorder.begin()
        recorder.capture(frame: 0, tracks: [a], 0x90, 60, 100)
        recorder.capture(frame: 10, tracks: [b], 0x90, 64, 100)
        recorder.capture(frame: 20, tracks: [a, b], 0xB0, 64, 127) // a pedal both inputs accept
        recorder.capture(frame: 30, tracks: [a], 0x80, 60, 0)
        recorder.capture(frame: 40, tracks: [b], 0x80, 64, 0)
        let all = recorder.end()
        #expect(all.count == 6)
        let own = MIDIRecorder.events(all, of: a)
        #expect(MIDIRecorder.notes(from: own, endFrame: 100) { $0 }.map(\.pitch) == [60])
        #expect(MIDIRecorder.notes(from: MIDIRecorder.events(all, of: b), endFrame: 100) { $0 }.map(\.pitch) == [64])
        #expect(MIDIRecorder.controls(from: own, endFrame: 100) { $0 }.count == 2, "the pedal down and its release at the end")
        // An event with no track (an old caller) belongs to every track.
        let shared = [E(frame: 0, status: 0x90, data1: 72, data2: 100, track: nil)]
        #expect(MIDIRecorder.events(shared, of: a).count == 1)
    }

    /// Sustain, mod wheel and pitch bend become clip controls. A pedal that was down before the take began
    /// starts the clip down; one still down at the end is released there.
    @Test func controlsBecomeClipControls() {
        let events = [
            E(frame: -50, status: 0xB0, data1: 64, data2: 127),  // pedal down before the start
            E(frame: -40, status: 0xB0, data1: 1, data2: 10),    // wheel moved before the start...
            E(frame: -30, status: 0xB0, data1: 1, data2: 20),    // ...twice: the last one counts
            E(frame: 0, status: 0x90, data1: 60, data2: 100),
            E(frame: 100, status: 0xE0, data1: 0, data2: 96),    // a bend up
            E(frame: 200, status: 0xB0, data1: 64, data2: 0),    // pedal up
            E(frame: 300, status: 0xB0, data1: 64, data2: 127),  // pedal down again, never released
            E(frame: 350, status: 0x80, data1: 60, data2: 0),
        ]
        let controls = MIDIRecorder.controls(from: events, endFrame: 400) { $0 }
        #expect(controls.map(\.tick) == [0, 0, 100, 200, 300, 400], "\(controls.map(\.tick))")
        #expect(controls[0].controller == 1 && controls[0].value == 20, "the last early wheel value, at tick 0")
        #expect(controls[1].controller == 64 && controls[1].value == 127, "the pedal that was down starts the clip down")
        #expect(controls[2].isPitchBend && controls[2].bend == 96 << 7 - 8192)
        #expect(controls[5].controller == 64 && controls[5].value == 0, "released at the end of the take")
        #expect(MIDIRecorder.notes(from: events, endFrame: 400) { $0 }.count == 1, "the notes are untouched")
    }
}
