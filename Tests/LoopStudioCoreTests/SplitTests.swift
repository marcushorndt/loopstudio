import Testing
import LoopStudioCore

private let lane = ParameterAddress(node: ParameterAddress.ownTrack, parameter: "volume")

@Test func splitTailContinuesNotesEnvelopesAndAutomation() throws {
    var m = MIDIClip(start: 1_000, length: 4_000, notes: [
        MIDINote(tick: 0, length: 500, pitch: 60), MIDINote(tick: 1_500, length: 1_000, pitch: 62), MIDINote(tick: 3_000, length: 200, pitch: 64)])
    m.lanes = [AutomationLane(target: lane, points: [AutomationPoint(tick: 0, value: -20), AutomationPoint(tick: 4_000, value: 0)])]
    let tail = try #require(Clip.midi(m).tail(from: 2_000))
    guard case .midi(let t) = tail else { Issue.record("not MIDI"); return }
    #expect(t.start == 3_000 && t.length == 2_000)
    #expect(t.notes.map(\.pitch) == [62, 64], "the note across the cut continues; the one before it is gone")
    #expect(t.notes[0].tick == 0 && t.notes[0].length == 500 && t.notes[1].tick == 1_000)
    let points = try #require(t.lanes?.first?.points)
    for offset in stride(from: 0, to: 2_000, by: 250) {
        let original = AutomationMath.value(m.lanes![0].points, at: Tick(2_000 + Int64(offset)))!
        #expect(abs(AutomationMath.value(points, at: Tick(Int64(offset)))! - original) < 1e-9, "the curve goes on from the cut")
    }
}

@Test func splitTailOfAnUnlinkedCurveKeepsItsPhase() throws {
    let cycle = Tick(1_000)
    var a = AudioClip(asset: AssetID(), start: 0, length: 5_000, loop: true)
    a.automationLength = cycle
    a.gainEnvelope = [AutomationPoint(tick: 0, value: 0), AutomationPoint(tick: 5_000, value: -50)]
    let curve = [AutomationPoint(tick: 0, value: 0), AutomationPoint(tick: 400, value: 10, curve: .hold), AutomationPoint(tick: 800, value: 3)]
    a.lanes = [AutomationLane(target: lane, points: curve)]
    let tail = try #require(Clip.audio(a).tail(from: 2_300))
    guard case .audio(let t) = tail else { Issue.record("not audio"); return }
    #expect(t.offset == 2_300 && t.automationLength == cycle)
    #expect(AutomationMath.value(t.gainEnvelope!, at: 0) == AutomationMath.value(a.gainEnvelope!, at: 2_300))
    let rotated = try #require(t.lanes?.first?.points)
    for offset in stride(from: Int64(0), to: 2_700, by: 50) {
        let want = AutomationMath.value(curve, at: Tick((2_300 + offset) % 1_000))!
        let got = AutomationMath.value(rotated, at: Tick(offset % 1_000))!
        #expect(abs(got - want) < 0.05, "tick \(offset): \(got) vs \(want)")
    }
}

@Test func trimmingTheStartKeepsTheContentInPlaceAndUndoes() throws {
    var p = Project(name: "T")
    let t = Track(name: "M", kind: .midi)
    try Command.insertTrack(track: t, index: 0).apply(to: &p)
    let clip = MIDIClip(start: 0, length: 3840, notes: [MIDINote(tick: 0, length: 480, pitch: 60),
                                                         MIDINote(tick: 720, length: 480, pitch: 62),
                                                         MIDINote(tick: 1920, length: 480, pitch: 64)])
    try Command.insertClip(track: t.id, clip: .midi(clip)).apply(to: &p)
    let before = p
    let trimmed = try #require(Clip.midi(clip).trimmingStart(to: 960))
    let undo = try Command.setClip(clip: trimmed).apply(to: &p)
    guard case .midi(let m)? = p.findClip(clip.id)?.1 else { Issue.record("clip gone"); return }
    #expect(m.start == 960 && m.length == 2880)
    #expect(m.notes.map(\.tick) == [0, 960], "the cut note starts at the edge; the later note keeps its place")
    #expect(m.notes.map(\.length) == [240, 480])
    try undo.apply(to: &p)
    #expect(p == before)

    var audio = AudioClip(asset: AssetID(), start: 1920, length: 1920, offset: 0)
    audio.loop = false
    #expect(Clip.audio(audio).trimmingStart(to: 960) == nil, "audio cannot start before its file")
    guard case .audio(let a)? = Clip.audio(audio).trimmingStart(to: 2400) else { Issue.record("no audio"); return }
    #expect(a.offset == 480 && a.length == 1440)
}
