import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

/// A listener whose own chain has latency before the compressor: the sidechain source waits by that much, and
/// the source's other paths wait for the listener, so a kick ducks the bass on the kick, not two blocks later.
@Test func aSidechainWaitsForTheLatencyInFrontOfTheListener() throws {
    var project = Project(name: "PDC", sampleRate: rate)
    let kick = Track(name: "Kick", kind: .audio)
    var bass = Track(name: "Bass", kind: .audio)
    var limiter = BuiltInEffects.makeSlot("limiter")!
    limiter.params["lookahead"] = 10 // 480 frames
    let comp = BuiltInEffects.makeSlot("compressor")!
    bass.devices = [limiter, comp]
    try Command.insertTrack(track: kick, index: 0).apply(to: &project)
    try Command.insertTrack(track: bass, index: 1).apply(to: &project)
    try Command.setDeviceSidechain(track: bass.id, device: comp.id, source: kick.id).apply(to: &project)

    let plan = RenderPlan.compile(project, bank: AudioBank())
    let kickNode = plan.trackOrder.firstIndex(of: kick.id)!, bassNode = plan.trackOrder.firstIndex(of: bass.id)!
    let compPlan = plan.nodes[bassNode].effects.first { $0.device == comp.id }!
    #expect(compPlan.sidechain == kickNode)
    #expect(compPlan.sidechainDelay == 480, "\(compPlan.sidechainDelay)")
    #expect(plan.nodes[bassNode].effects[0].sidechainDelay == 0)
    // The kick itself is late by nothing; the mix waits for the bass.
    #expect(plan.nodes[kickNode].outputDelay == 480)
    #expect(plan.latencyFrames == 480)

    // The renderer gives the compressor a line of that length and runs without a trap.
    let renderer = Renderer(plan: plan)
    var l = [Float](repeating: 0, count: 512), r = [Float](repeating: 0, count: 512)
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        renderer.process(startFrame: 0, frames: 512, outLeft: lp.baseAddress!, outRight: rp.baseAddress!)
    } }
}

/// The source has the latency: the listener's inputs already wait for it, so the detector needs no line.
@Test func aLateSourceNeedsNoSidechainLine() throws {
    var project = Project(name: "PDC", sampleRate: rate)
    var kick = Track(name: "Kick", kind: .audio)
    var limiter = BuiltInEffects.makeSlot("limiter")!
    limiter.params["lookahead"] = 5
    kick.devices = [limiter]
    var bass = Track(name: "Bass", kind: .audio)
    let comp = BuiltInEffects.makeSlot("compressor")!
    bass.devices = [comp]
    try Command.insertTrack(track: kick, index: 0).apply(to: &project)
    try Command.insertTrack(track: bass, index: 1).apply(to: &project)
    try Command.setDeviceSidechain(track: bass.id, device: comp.id, source: kick.id).apply(to: &project)
    let plan = RenderPlan.compile(project, bank: AudioBank())
    let bassNode = plan.trackOrder.firstIndex(of: bass.id)!
    #expect(plan.nodes[bassNode].effects[0].sidechainDelay == 0)
    // The bass arrives as late as the kick: its output needs no delay into the master either.
    #expect(plan.nodes[bassNode].arrival == 240)
    #expect(plan.nodes[bassNode].outputDelay == 0)
}

/// The look-ahead sets the latency the plan compensates: a curve on it is dropped, a knob turn still rebuilds.
@Test func aFixedLookaheadTakesNoAutomationCurve() throws {
    var project = Project(name: "Fixed", sampleRate: rate)
    var t = Track(name: "A", kind: .audio)
    let limiter = BuiltInEffects.makeSlot("limiter")!
    t.devices = [limiter]
    try Command.insertTrack(track: t, index: 0).apply(to: &project)
    let points = [AutomationPoint(tick: 0, value: 0), AutomationPoint(tick: Tick(Tick.perQuarter * 4), value: 10)]
    try Command.setAutomation(track: t.id, target: ParameterAddress(node: limiter.id.rawValue, parameter: "lookahead"), points: points).apply(to: &project)
    try Command.setAutomation(track: t.id, target: ParameterAddress(node: limiter.id.rawValue, parameter: "ceiling"), points: points).apply(to: &project)
    let plan = RenderPlan.compile(project, bank: AudioBank())
    let effect = plan.nodes[0].effects[0]
    #expect(effect.auto["lookahead"] == nil, "a fixed parameter has no curve in the plan")
    #expect(effect.auto["ceiling"] != nil)
    #expect(BuiltInEffects.spec("limiter")?.param("lookahead")?.fixed == true)
    #expect(plan.nodes[0].latency == 96, "the default 2 ms")
}

/// The index answers for every key and frame like the event scan did.
@Test func theNoteIndexAnswersLikeTheEventScan() {
    var events: [MIDIEvent] = []
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<400 {
        let on = Int64.random(in: 0..<100_000, using: &rng), length = Int64.random(in: 1..<5_000, using: &rng)
        let pitch = UInt8.random(in: 36..<48, using: &rng), channel = UInt8.random(in: 0..<2, using: &rng)
        events.append(MIDIEvent(frame: on, status: 0x90 | channel, data1: pitch, data2: 100))
        events.append(MIDIEvent(frame: on + length, status: 0x80 | channel, data1: pitch, data2: 0))
    }
    events.sort { ($0.frame, $0.status & 0xF0 == 0x90 ? 1 : 0) < ($1.frame, $1.status & 0xF0 == 0x90 ? 1 : 0) }
    let index = NoteIndex(events)
    for _ in 0..<2_000 {
        let frame = Int64.random(in: 0..<110_000, using: &rng)
        let key = Int(UInt8.random(in: 0..<2, using: &rng)) << 7 | Int(UInt8.random(in: 36..<48, using: &rng))
        #expect(index.heldAt(key, frame: frame) == Renderer.hasNoteOff(events, key: key, from: frame), "key \(key) frame \(frame)")
    }
    #expect(index.heldAt(1, frame: 0) == false, "a key that never plays")
}

/// A copy of the spectrum ring is the newest samples in order, never a block half old and half new.
@Test func theSpectrumTapCopiesTheNewestSamplesInOrder() {
    let tap = SpectrumTap()
    var l = (0..<SpectrumTap.size + 100).map { Float($0) }, r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        tap.write(lp.baseAddress!, rp.baseAddress!, frames: 3_000)
        tap.write(lp.baseAddress! + 3_000, rp.baseAddress! + 3_000, frames: SpectrumTap.size + 100 - 3_000)
    } }
    var out = [Float](repeating: -1, count: 2_048)
    out.withUnsafeMutableBufferPointer { tap.copyLatest(into: $0.baseAddress!, count: 2_048) }
    let last = Float(SpectrumTap.size + 100 - 1)
    #expect(out[2_047] == last && out[0] == last - 2_047, "\(out[0]) ... \(out[2_047])")
    #expect(tap.generation == 2)
}

/// Clip controls play at their ticks with the notes, a bend before the note-on it belongs to, and loop with the
/// clip. A stop releases the pedal and centres the bend.
@Test func clipControlsPlayWithTheNotesAndLoop() throws {
    var project = Project(name: "Controls", sampleRate: rate)
    var track = Track(name: "Keys", kind: .midi)
    track.devices = [BuiltInEffects.makeSlot("acid")!]
    try Command.insertTrack(track: track, index: 0).apply(to: &project)
    let clip = MIDIClip(start: 0, length: 3840, loop: true,
                        notes: [MIDINote(tick: 0, length: 960, pitch: 48)],
                        controls: [MIDIControlEvent.pitchBend(4096, tick: 0), MIDIControlEvent.controller(64, 127, tick: 960), MIDIControlEvent.controller(64, 0, tick: 2880)])
    try Command.setSlot(track: track.id, index: 0, slot: SessionSlot(clip: .midi(clip), quantize: .none)).apply(to: &project)
    try Command.setLaunches(launches: [Launch(track: track.id, slot: 0, tick: 0)]).apply(to: &project)
    let plan = RenderPlan.compile(project, bank: AudioBank(), session: SessionSimulator.run(project, horizon: 38_400))
    let events = plan.nodes[0].sessionMidi
    #expect(events.count >= 6, "\(events.count) events")
    guard events.count >= 6 else { return }
    let kinds = events.prefix(4).map { $0.status & 0xF0 }
    // The note ends on the frame the pedal goes down: note-off, then the control, then any note-on.
    #expect(kinds == [0xE0, 0x90, 0x80, 0xB0], "bend, note-on, note-off, pedal: \(events.prefix(6).map { "\($0.frame):\(String($0.status, radix: 16)):\($0.data1):\($0.data2)" })")
    #expect(events[0].data2 == 96 && events[0].data1 == 0)
    let bar = Int64(rate * 2) // one bar at 120 BPM
    let secondPass = events.filter { $0.frame >= bar && $0.frame < 2 * bar }
    #expect(secondPass.filter { $0.status & 0xF0 == 0xB0 }.count == 2, "the pedal loops with the clip")
    #expect(plan.nodes[0].noteIndex.heldAt(48, frame: 0) == false && plan.nodes[0].sessionNoteIndex.heldAt(48, frame: 100))
    // The renderer runs the controls without a trap and silences them on a stop.
    let renderer = Renderer(plan: plan, maxBlock: 512)
    var l = [Float](repeating: 0, count: 512), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        for i in 0..<8 { renderer.process(startFrame: Int64(i * 512), sessionFrame: Int64(i * 512), frames: 512, outLeft: lp.baseAddress!, outRight: rp.baseAddress!) }
    } }
    renderer.silenceNotes()
    #expect(renderer.heldMask(track: track.id) == (0, 0))
}
