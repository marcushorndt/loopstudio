import Foundation
import Testing
@testable import LoopStudioCore

private let s16 = Tick.perQuarter / 4

private func sixteenths(_ count: Int) -> [MIDINote] {
    (0..<count).map { MIDINote(tick: Tick(Int64($0) * s16), length: Tick(s16), pitch: 60, velocity: 100) }
}

@Test func aTripletSwingMovesEverySecondSixteenthAThirdOfAStepLate() {
    let swing = Groove.swing(id: "t", name: "t", group: "t", step: s16, percent: 200.0 / 3)
    let out = swing.apply(sixteenths(4), timing: 1, velocity: 1, length: 3840)
    #expect(out[0].tick.rawValue == 0)
    #expect(out[1].tick.rawValue == s16 + Int64((Double(s16) / 3).rounded()))
    #expect(out[2].tick.rawValue == 2 * s16)
    #expect(out[3].tick.rawValue == 3 * s16 + Int64((Double(s16) / 3).rounded()))
    // Half the timing amount: half the move.
    let half = swing.apply(sixteenths(2), timing: 0.5, velocity: 1, length: 3840)
    #expect(half[1].tick.rawValue == s16 + Int64((Double(s16) / 6).rounded()))
}

@Test func aNoteNearAStepTakesThatStep() {
    let swing = Groove.swing(id: "t", name: "t", group: "t", step: s16, percent: 58)
    // 20 ticks before the second sixteenth: still the swung step.
    let out = swing.apply([MIDINote(tick: Tick(s16 - 20), length: 100, pitch: 60)], timing: 1, velocity: 1, length: 3840)
    #expect(out[0].tick.rawValue == s16 - 20 + Int64((0.16 * Double(s16)).rounded()))
}

@Test func accentsChangeVelocityWithinLimitsAndTheClipEndHolds() {
    let g = Groove(id: "g", name: "g", group: "g", step: s16, timing: [0, 0.5], velocity: [0.5, -1])
    let notes = [MIDINote(tick: 0, length: 100, pitch: 60, velocity: 120), MIDINote(tick: Tick(s16), length: 100, pitch: 60, velocity: 10),
                 MIDINote(tick: Tick(3 * s16), length: 100, pitch: 60, velocity: 100)]
    // The clip ends 20 ticks after the last note: that note would move past the end, so it keeps its place.
    let out = g.apply(notes, timing: 1, velocity: 1, length: 3 * s16 + 20)
    #expect(out[0].velocity == 127, "clamped at the top")
    #expect(out[1].velocity == 1, "clamped at the bottom")
    #expect(out[1].tick.rawValue == s16 + s16 / 2, "the swung step moves half a step")
    #expect(out[2].tick.rawValue == 3 * s16)
    // Accents at half: +16 on the first.
    #expect(g.apply(notes, timing: 0, velocity: 0.5, length: 4 * s16)[1].velocity == 1)
    #expect(g.apply([MIDINote(tick: 0, length: 100, pitch: 60, velocity: 100)], timing: 0, velocity: 0.5, length: 4 * s16)[0].velocity == 116)
}

@Test func everyTemplateHasAnIDANameAndAsManyAccentsAsSteps() {
    #expect(Set(Groove.all.map(\.id)).count == Groove.all.count)
    for g in Groove.all {
        #expect(!g.name.isEmpty && !g.group.isEmpty && g.step > 0, "\(g.id)")
        #expect(g.velocity.count == g.timing.count, "\(g.id)")
        #expect(g.timing.allSatisfy { abs($0) < 1 }, "\(g.id) moves a note less than a step")
    }
    #expect(Groove.named("swing16-58") != nil)
    #expect(Groove.named("nope") == nil)
}

@Test func theGrooveIsASettingUntilItIsCommitted() throws {
    var p = Fixture.baseProject()
    let keys = Track(name: "Keys", kind: .midi)
    try Command.insertTrack(track: keys, index: 0).apply(to: &p)
    let clip = MIDIClip(start: 0, length: 3840, notes: sixteenths(4))
    try Command.insertClip(track: keys.id, clip: .midi(clip)).apply(to: &p)

    // Setting a groove leaves the notes alone, but the played notes move.
    let set = try Command.setClipGroove(clip: clip.id, groove: GrooveSetting(groove: "triplet")).apply(to: &p)
    guard case .midi(let grooved)? = p.findClip(clip.id)?.1 else { Issue.record("clip"); return }
    #expect(grooved.notes == clip.notes)
    #expect(grooved.playedNotes[1].tick.rawValue == s16 + Int64((Double(s16) / 3).rounded()))
    if case .setClipGroove(let id, let old) = set { #expect(id == clip.id && old == nil) } else { Issue.record("inverse \(set)") }

    // An unknown template is refused.
    #expect(throws: CommandError.self) { try Command.setClipGroove(clip: clip.id, groove: GrooveSetting(groove: "nope")).apply(to: &p) }

    // Committing moves the notes and drops the setting; the inverse brings the clip back as it was.
    let inverse = try Command.commitGroove(clip: clip.id).apply(to: &p)
    guard case .midi(let burned)? = p.findClip(clip.id)?.1 else { Issue.record("clip"); return }
    #expect(burned.groove == nil)
    #expect(burned.notes == grooved.playedNotes)
    #expect(burned.playedNotes == burned.notes)
    try inverse.apply(to: &p)
    guard case .midi(let back)? = p.findClip(clip.id)?.1 else { Issue.record("clip"); return }
    #expect(back == grooved)
    // Committed once more, the clip is straight: there is nothing left to commit.
    _ = try Command.commitGroove(clip: clip.id).apply(to: &p)
    #expect(throws: CommandError.self) { try Command.commitGroove(clip: clip.id).apply(to: &p) }
}

@Test func aMutedNoteStaysInTheClipButDoesNotPlay() throws {
    var notes = sixteenths(2)
    notes[1].muted = true
    let clip = MIDIClip(start: 0, length: 3840, notes: notes)
    #expect(clip.playedNotes.count == 1)
    #expect(clip.notes.count == 2)
    // A project from before notes could be muted decodes with the note active.
    let json = #"{"tick":0,"length":240,"pitch":60,"velocity":100,"channel":0}"#.data(using: .utf8)!
    let old = try JSONDecoder().decode(MIDINote.self, from: json)
    #expect(!old.muted)
    let roundTrip = try JSONDecoder().decode(MIDINote.self, from: JSONEncoder().encode(notes[1]))
    #expect(roundTrip.muted)
}
