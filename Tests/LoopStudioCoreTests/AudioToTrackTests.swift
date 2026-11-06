import Foundation
import Testing
@testable import LoopStudioCore

/// "Audio To" an audio track, and "Audio From: No Input".
@Test func aTrackCanSendItsOutputIntoAnAudioTrack() throws {
    var p = Fixture.baseProject()
    let synth = Track(name: "Synth", kind: .midi), target = Track(name: "Target", kind: .audio), other = Track(name: "Other", kind: .midi)
    try Command.insertTrack(track: synth, index: 0).apply(to: &p)
    try Command.insertTrack(track: target, index: 1).apply(to: &p)
    try Command.insertTrack(track: other, index: 2).apply(to: &p)

    let inverse = try Command.setOutput(id: synth.id, target: target.id).apply(to: &p)
    #expect(p.track(synth.id)?.output == target.id)
    #expect(p.validate().isEmpty, "an audio track takes an output like a bus")
    #expect(p.track(target.id)?.feeders(in: p).map(\.id) == [synth.id])

    #expect(throws: CommandError.self, "a MIDI track takes notes, not sound") {
        try Command.setOutput(id: synth.id, target: other.id).apply(to: &p)
    }
    let back = Track(name: "Back", kind: .audio)
    try Command.insertTrack(track: back, index: 3).apply(to: &p)
    try Command.setOutput(id: back.id, target: target.id).apply(to: &p)
    #expect(throws: CommandError.self, "the target cannot feed a track that feeds it") {
        try Command.setOutput(id: target.id, target: back.id).apply(to: &p)
    }
    #expect(throws: CommandError.self, "nor take it as its Audio From") {
        try Command.setInputTrack(id: back.id, source: target.id).apply(to: &p)
    }
    #expect(throws: CommandError.self, "a send still needs a return or group") {
        try Command.setSends(id: synth.id, sends: [Send(target: target.id)]).apply(to: &p)
    }
    try inverse.apply(to: &p)
    #expect(p.track(synth.id)?.output == nil)
}

@Test func noInputIsAnAudioSourceOfItsOwn() throws {
    var p = Fixture.baseProject()
    let t = Track(name: "T", kind: .audio), m = Track(name: "M", kind: .midi), s = Track(name: "S", kind: .audio)
    try Command.insertTrack(track: t, index: 0).apply(to: &p)
    try Command.insertTrack(track: m, index: 1).apply(to: &p)
    try Command.insertTrack(track: s, index: 2).apply(to: &p)
    #expect(p.track(t.id)?.audioSource == .external)

    let inverse = try Command.setNoInput(id: t.id, noInput: true).apply(to: &p)
    #expect(p.track(t.id)?.audioSource == .noInput)
    #expect(p.validate().isEmpty)
    try inverse.apply(to: &p)
    #expect(p.track(t.id)?.audioSource == .external)
    #expect(p.track(t.id)?.noInput == nil, "undo lands on the stored value of a fresh track")

    #expect(throws: CommandError.self, "only audio tracks have an audio input") {
        try Command.setNoInput(id: m.id, noInput: true).apply(to: &p)
    }

    // A source track clears No Input; undo brings both back.
    try Command.setNoInput(id: t.id, noInput: true).apply(to: &p)
    let back = try Command.setInputTrack(id: t.id, source: s.id).apply(to: &p)
    #expect(p.track(t.id)?.audioSource == .track(s.id))
    #expect(p.track(t.id)?.noInput == nil)
    try back.apply(to: &p)
    #expect(p.track(t.id)?.audioSource == .noInput)
    #expect(p.track(t.id)?.inputTrack == nil)
}
