import Testing
import LoopStudioCore

/// Notes of one pitch and channel never overlap: the earlier gives way, the later keeps its start.
@Suite struct NoteOverlapTests {
    @Test func theEarlierNoteEndsWhereTheNextStarts() {
        let notes = [MIDINote(tick: 0, length: 1920, pitch: 60), MIDINote(tick: 960, length: 480, pitch: 60)]
        let fixed = notes.withoutOverlaps()
        #expect(fixed.map(\.tick.rawValue) == [0, 960])
        #expect(fixed.map(\.length.rawValue) == [960, 480])
    }

    @Test func otherPitchesAndChannelsAreLeftAlone() {
        let notes = [MIDINote(tick: 0, length: 1920, pitch: 60), MIDINote(tick: 960, length: 480, pitch: 64),
                     MIDINote(tick: 480, length: 480, pitch: 60, channel: 1)]
        let fixed = notes.withoutOverlaps()
        #expect(fixed.count == 3)
        #expect(fixed.first { $0.pitch == 60 && $0.channel == 0 }?.length == 1920)
    }

    @Test func aNoteDroppedOnAnotherStartReplacesIt() {
        let notes = [MIDINote(tick: 960, length: 480, pitch: 60, velocity: 50), MIDINote(tick: 960, length: 240, pitch: 60, velocity: 120)]
        let fixed = notes.withoutOverlaps()
        #expect(fixed.count == 1)
        #expect(fixed[0].velocity == 120 && fixed[0].length == 240)
    }

    @Test func theCommandAppliesTheRule() throws {
        var p = Project(name: "t")
        let track = Track(id: TrackID(), name: "Keys", kind: .midi)
        _ = try Command.insertTrack(track: track, index: 0).apply(to: &p)
        let clip = MIDIClip(id: ClipID(), start: 0, length: 3840, loop: true, notes: [])
        _ = try Command.insertClip(track: track.id, clip: .midi(clip)).apply(to: &p)
        _ = try Command.setMIDINotes(clip: clip.id, notes: [MIDINote(tick: 0, length: 3840, pitch: 48), MIDINote(tick: 1920, length: 960, pitch: 48)]).apply(to: &p)
        guard case .midi(let c)? = p.findClip(clip.id)?.clip else { Issue.record("no clip"); return }
        #expect(c.notes.map(\.length.rawValue) == [1920, 960])
    }
}
