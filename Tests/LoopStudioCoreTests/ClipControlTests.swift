import Foundation
import Testing
@testable import LoopStudioCore

/// A clip from before controls were recorded has no `controls` key and still opens.
@Test func anOldMIDIClipWithoutControlsDecodes() throws {
    let json = """
    {"id":"\(UUID().uuidString)","start":0,"length":3840,"loop":true,"notes":[{"tick":0,"length":480,"pitch":60,"velocity":100,"channel":0}]}
    """
    let clip = try JSONDecoder().decode(MIDIClip.self, from: Data(json.utf8))
    #expect(clip.controls.isEmpty && clip.notes.count == 1)
    // And a clip with controls comes back whole.
    var full = MIDIClip(length: 3840, notes: clip.notes, controls: [MIDIControlEvent.controller(64, 127, tick: 0), MIDIControlEvent.pitchBend(-8192, tick: 960)])
    full.groove = nil
    let again = try JSONDecoder().decode(MIDIClip.self, from: JSONEncoder().encode(full))
    #expect(again == full)
    #expect(again.controls[1].bend == -8192 && again.controls[0].controller == 64 && again.controls[0].value == 127)
    #expect(again.controlKinds.controllers == [64] && again.controlKinds.pitchBend)
}

/// The command replaces the controls, sorts them, refuses a note as a control, and undoes exactly.
@Test func theControlsCommandValidatesAndUndoes() throws {
    var p = Fixture.baseProject()
    let t = Track(name: "Keys", kind: .midi)
    try Command.insertTrack(track: t, index: 0).apply(to: &p)
    let clip = MIDIClip(length: 3840)
    try Command.insertClip(track: t.id, clip: .midi(clip)).apply(to: &p)
    let controls = [MIDIControlEvent.controller(1, 40, tick: 960), MIDIControlEvent.controller(64, 127, tick: 0)]
    let inverse = try Command.setMIDIControls(clip: clip.id, controls: controls).apply(to: &p)
    guard case .midi(let c) = p.findClip(clip.id)!.1 else { Issue.record("not a MIDI clip"); return }
    #expect(c.controls.map(\.tick) == [0, 960], "sorted by tick")
    #expect(c.controls(controller: 64).count == 1 && c.controls(controller: nil).isEmpty)
    #expect(throws: CommandError.self) {
        try Command.setMIDIControls(clip: clip.id, controls: [MIDIControlEvent(tick: 0, status: 0x90, data1: 60, data2: 100)]).apply(to: &p)
    }
    _ = try inverse.apply(to: &p)
    guard case .midi(let back) = p.findClip(clip.id)!.1 else { Issue.record("not a MIDI clip"); return }
    #expect(back.controls.isEmpty)
}
