import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private func plan(groove: GrooveSetting?, muted: Bool = false) -> RenderPlan {
    var project = Project(name: "G", sampleRate: 48_000)
    var track = Track(name: "Keys", kind: .midi)
    let s16 = Tick.perQuarter / 4
    var notes = [MIDINote(tick: 0, length: Tick(s16), pitch: 60), MIDINote(tick: Tick(s16), length: Tick(s16), pitch: 62)]
    notes[1].muted = muted
    var clip = MIDIClip(start: 0, length: 3840, notes: notes)
    clip.groove = groove
    track.clips = [.midi(clip)]
    try! Command.insertTrack(track: track, index: 0).apply(to: &project)
    return RenderPlan.compile(project, bank: AudioBank(), midiOutputs: [track.id: MIDIOutTarget(endpoint: 1)])
}

@Test func theEngineMovesTheNotesOfAGroovedClipAndLeavesTheClipAlone() {
    let straight = plan(groove: nil), swung = plan(groove: GrooveSetting(groove: "triplet"))
    let ons = { (p: RenderPlan) in p.nodes[0].midi.filter { $0.status & 0xF0 == 0x90 }.map(\.frame) }
    let a = ons(straight), b = ons(swung)
    #expect(a.count == 2 && b.count == 2)
    #expect(a[0] == b[0], "the first sixteenth stays")
    #expect(b[1] > a[1], "the second sixteenth plays late")
    // A third of a sixteenth at 120 BPM: a sixteenth is 6000 frames at 48 kHz.
    #expect(abs((b[1] - a[1]) - 2000) <= 2)
}

@Test func aMutedNoteSendsNothing() {
    let p = plan(groove: nil, muted: true)
    let ons = p.nodes[0].midi.filter { $0.status & 0xF0 == 0x90 }
    #expect(ons.count == 1 && ons[0].data1 == 60)
}
