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

/// A control from before envelopes had ramps has no `ramp` key and is a step. A ramp comes back as one, and
/// its wide value reads and writes the bend's 14 bits.
@Test func aRampDecodesTolerantlyAndKeepsItsWideValue() throws {
    let json = """
    {"tick":480,"status":176,"data1":1,"data2":64}
    """
    let old = try JSONDecoder().decode(MIDIControlEvent.self, from: Data(json.utf8))
    #expect(old.ramp == false && old.controller == 1 && old.value == 64)
    let ramp = MIDIControlEvent.pitchBend(-4096, tick: 0, ramp: true)
    let again = try JSONDecoder().decode(MIDIControlEvent.self, from: JSONEncoder().encode(ramp))
    #expect(again.ramp && again.bend == -4096)
    #expect(ramp.wideValue == 8192 - 4096 && ramp.with(wideValue: 16_383).bend == 8191 && ramp.with(wideValue: -5).bend == -8192)
    #expect(MIDIControlEvent.controller(1, 0, tick: 0).sameKind(as: MIDIControlEvent.controller(1, 127, tick: 960)))
    #expect(!MIDIControlEvent.controller(1, 0, tick: 0).sameKind(as: MIDIControlEvent.controller(64, 127, tick: 960)))
    #expect(!MIDIControlEvent.controller(1, 0, tick: 0, channel: 1).sameKind(as: MIDIControlEvent.controller(1, 127, tick: 960)))
    #expect(MIDIControlEvent.pitchBend(0, tick: 0).sameKind(as: MIDIControlEvent.pitchBend(100, tick: 1)))
    // The command keeps the flag.
    var p = Fixture.baseProject()
    let track = Track(name: "Keys", kind: .midi)
    try Command.insertTrack(track: track, index: 0).apply(to: &p)
    let clip = MIDIClip(length: 1920)
    try Command.insertClip(track: track.id, clip: .midi(clip)).apply(to: &p)
    try Command.setMIDIControls(clip: clip.id, controls: [MIDIControlEvent.controller(1, 127, tick: 960), ramp]).apply(to: &p)
    guard case .midi(let c) = p.findClip(clip.id)!.1 else { Issue.record("not a MIDI clip"); return }
    #expect(c.controls.map { $0.ramp } == [true, false])
}
