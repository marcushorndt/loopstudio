import AVFoundation
import CoreMIDI
import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

/// Collects what the queue puts on the wire, in place of CoreMIDI.
private final class Wire: @unchecked Sendable {
    struct Message: Equatable { var endpoint: UInt32; var time: UInt64; var bytes: [UInt8] }
    private let lock = NSLock()
    private var messages: [Message] = []
    func record(_ endpoint: MIDIEndpointRef, _ time: UInt64, _ bytes: UnsafeBufferPointer<UInt8>) {
        lock.lock(); messages.append(Message(endpoint: endpoint, time: time, bytes: Array(bytes))); lock.unlock()
    }
    var all: [Message] { lock.lock(); defer { lock.unlock() }; return messages }
}

private func queue(_ wire: Wire, capacity: Int = 64) -> MIDIOutQueue {
    let q = MIDIOutQueue(capacity: capacity) { e, t, b in wire.record(e, t, b) }
    q.hostTime = { frame in UInt64(1000 + frame) } // host ticks are frames plus 1000
    return q
}

@Test func thePushAppliesChannelAndLatencyAndTheDrainStampsFromTheClock() {
    let wire = Wire(), q = queue(wire)
    let synth = MIDIOutTarget(endpoint: 7, channel: 2, latencyFrames: -10)
    q.push(synth, frame: 100, 0x90, 60, 100)
    q.push(synth, frame: MIDIOutQueue.now, 0xC0, 5, 0)
    q.push(MIDIOutTarget(endpoint: 8), frame: 50, 0x91, 61, 0)
    #expect(q.drain() == 3)
    let m = wire.all
    #expect(m[0] == .init(endpoint: 7, time: 1090, bytes: [0x92, 60, 100]), "on channel 3, ten frames early")
    #expect(m[1] == .init(endpoint: 7, time: 0, bytes: [0xC2, 5]), "a live program change: two bytes, now")
    #expect(m[2] == .init(endpoint: 8, time: 1050, bytes: [0x91, 61, 0]), "channel kept")
    #expect(q.sent == 3 && q.dropped == 0)
}

@Test func aFullRingDropsAndCounts() {
    let wire = Wire(), q = queue(wire, capacity: 16)
    for i in 0..<20 { q.push(MIDIOutTarget(endpoint: 1), frame: Int64(i), 0x90, UInt8(i), 1) }
    #expect(q.dropped == 4)
    #expect(q.drain() == 16)
    #expect(wire.all.map(\.bytes[1]) == Array(0..<16).map { UInt8($0) })
}

private func keysProject(notes: [MIDINote]) -> (Project, Track) {
    var project = Project(name: "H", sampleRate: rate)
    var track = Track(name: "Keys", kind: .midi)
    track.clips = [.midi(MIDIClip(start: 0, length: 3840, notes: notes))]
    try! Command.insertTrack(track: track, index: 0).apply(to: &project)
    return (project, track)
}

private final class Blocks {
    let l = UnsafeMutablePointer<Float>.allocate(capacity: 512), r = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    deinit { l.deallocate(); r.deallocate() }
    /// Renders from `from` up to `to` in blocks of 512, with the session clock `lead` frames ahead.
    func run(_ renderer: Renderer, from: Int64, to: Int64, lead: Int64 = 0) {
        var frame = from
        while frame < to { renderer.process(startFrame: frame, sessionFrame: frame + lead, frames: 512, outLeft: l, outRight: r); frame += 512 }
    }
}

@Test func theNotesOfAMIDITrackGoToItsHardwareOnTheSessionClock() {
    // 120 BPM at 48 kHz: a quarter note is 24 000 frames.
    let (project, track) = keysProject(notes: [MIDINote(tick: 0, length: 960, pitch: 60),
                                              MIDINote(tick: 960, length: 960, pitch: 64, velocity: 90, channel: 3)])
    let plan = RenderPlan.compile(project, bank: AudioBank(), midiOutputs: [track.id: MIDIOutTarget(endpoint: 42)])
    #expect(plan.warnings.isEmpty, "a hardware output counts as an instrument: \(plan.warnings)")
    let renderer = Renderer(plan: plan, maxBlock: 512)
    let wire = Wire(), q = queue(wire)
    renderer.midiOut = q
    let blocks = Blocks()
    blocks.run(renderer, from: 0, to: 30_000, lead: 1000)
    q.drain()
    let m = wire.all
    #expect(m.map(\.bytes) == [[0x90, 60, 100], [0x80, 60, 0], [0x93, 64, 90]], "note-off before note-on on the same frame")
    #expect(m.map(\.time) == [2000, 26_000, 26_000], "session frame (timeline plus the lead) plus the clock's 1000")
    // Stop: the note still on gets its note-off, now.
    renderer.silenceNotes()
    q.drain()
    #expect(wire.all.last == .init(endpoint: 42, time: 0, bytes: [0x83, 64, 0]))
    // Nothing is held any more: a second stop sends nothing.
    renderer.silenceNotes()
    #expect(q.drain() == 0)
}

@Test func withoutAnOnlineDestinationTheTrackWarnsInsteadOfPlaying() {
    var (project, track) = keysProject(notes: [MIDINote(tick: 0, length: 960, pitch: 60)])
    try! Command.setMIDIOutput(id: track.id, selection: MIDIOutputSelection(destinationUID: 99, destinationName: "Volca")).apply(to: &project)
    track = project.tracks[0]
    let plan = RenderPlan.compile(project, bank: AudioBank())
    #expect(plan.warnings.contains { $0.contains("Volca") && $0.contains("not connected") })
    #expect(plan.nodes[0].midi.isEmpty)
}

@Test func aNewPlanKeepsHardwareNotesWhoseEndIsAheadAndReleasesTheOthers() {
    let (project, track) = keysProject(notes: [MIDINote(tick: 0, length: 1920, pitch: 60), MIDINote(tick: 0, length: 1920, pitch: 67)])
    let target = MIDIOutTarget(endpoint: 5)
    let first = Renderer(plan: RenderPlan.compile(project, bank: AudioBank(), midiOutputs: [track.id: target]), maxBlock: 512)
    let wire = Wire(), q = queue(wire)
    first.midiOut = q
    let blocks = Blocks()
    blocks.run(first, from: 0, to: 512)
    q.drain()
    #expect(wire.all.map(\.bytes) == [[0x90, 60, 100], [0x90, 67, 100]])

    // The edit keeps the note 60 and removes the note 67. Note 60 stays held; note 67 ends now.
    var edited = project
    try! Command.setClip(clip: .midi(MIDIClip(id: project.tracks[0].clips[0].id, start: 0, length: 3840,
                                              notes: [MIDINote(tick: 0, length: 1920, pitch: 60)]))).apply(to: &edited)
    let second = Renderer(plan: RenderPlan.compile(edited, bank: AudioBank(), midiOutputs: [track.id: target]), maxBlock: 512, reusing: first)
    second.midiOut = q
    second.takeOverNotes(from: first, at: 512, sessionFrame: 512)
    q.drain()
    #expect(wire.all.last == .init(endpoint: 5, time: 0, bytes: [0x80, 67, 0]))
    #expect(wire.all.count == 3, "note 60 is not released")
    // The second renderer plays on: the note-off of 60 comes at two beats (48 000 frames).
    blocks.run(second, from: 512, to: 49_152)
    q.drain()
    #expect(wire.all.last == .init(endpoint: 5, time: 49_000, bytes: [0x80, 60, 0]))
    #expect(wire.all.count == 4)
}

@Test func aLiveNoteReachesTheHardwareAtOnceAndIsReleasedOnStop() {
    let (project, track) = keysProject(notes: [])
    let renderer = Renderer(plan: RenderPlan.compile(project, bank: AudioBank(), midiOutputs: [track.id: MIDIOutTarget(endpoint: 9, channel: 0)]), maxBlock: 512)
    let wire = Wire(), q = queue(wire)
    renderer.midiOut = q
    renderer.sendLive(track: track.id, 0x95, 48, 120)
    q.drain()
    #expect(wire.all == [.init(endpoint: 9, time: 0, bytes: [0x90, 48, 120])], "the track's channel wins")
    renderer.silenceNotes()
    q.drain()
    #expect(wire.all.last == .init(endpoint: 9, time: 0, bytes: [0x80, 48, 0]))
    // A release the player sent itself leaves nothing for the stop.
    renderer.sendLive(track: track.id, 0x90, 50, 1)
    renderer.sendLive(track: track.id, 0x80, 50, 0)
    renderer.silenceNotes()
    #expect(q.drain() == 2)
}

@Test func theLoopWrapReleasesArrangementNotesAtTheWrapFrame() {
    let (project, track) = keysProject(notes: [MIDINote(tick: 0, length: 3840, pitch: 60)])
    let renderer = Renderer(plan: RenderPlan.compile(project, bank: AudioBank(), midiOutputs: [track.id: MIDIOutTarget(endpoint: 1)]), maxBlock: 512)
    let wire = Wire(), q = queue(wire)
    renderer.midiOut = q
    Blocks().run(renderer, from: 0, to: 24_064, lead: 0)
    renderer.releaseArrangementNotes()
    q.drain()
    #expect(wire.all.map(\.bytes) == [[0x90, 60, 100], [0x80, 60, 0]])
    #expect(wire.all[1].time == 1000 + 24_064, "released at the end of the last block, not 'now'")
}

/// A virtual destination that counts the channel messages it gets.
private final class Sink: @unchecked Sendable {
    var client = MIDIClientRef(), endpoint = MIDIEndpointRef()
    private let lock = NSLock()
    private var bytes: [[UInt8]] = []
    var received: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return bytes }

    init?() {
        guard MIDIClientCreateWithBlock("LoopStudio Out Test" as CFString, &client, { _ in }) == noErr else { return nil }
        let status = MIDIDestinationCreateWithProtocol(client, "LoopStudio Note Sink" as CFString, ._1_0, &endpoint) { [weak self] list, _ in
            guard let self else { return }
            for packet in list.unsafeSequence() {
                for word in packet.words() where word >> 28 == 2 {
                    self.lock.lock()
                    self.bytes.append([UInt8((word >> 16) & 0xFF), UInt8((word >> 8) & 0x7F), UInt8(word & 0x7F)])
                    self.lock.unlock()
                }
            }
        }
        guard status == noErr else { return nil }
    }
    deinit { MIDIEndpointDispose(endpoint); MIDIClientDispose(client) }
}

@Test func theLiveEngineSendsAHardwareNoteThroughCoreMIDI() async throws {
    guard let sink = Sink() else { return } // no CoreMIDI server here
    let (project, track) = keysProject(notes: [MIDINote(tick: 0, length: 960, pitch: 72)])
    let engine = LiveEngine(sampleRate: rate)
    engine.setRenderer(Renderer(plan: RenderPlan.compile(project, bank: AudioBank(), midiOutputs: [track.id: MIDIOutTarget(endpoint: sink.endpoint)])))
    let list = AudioBufferList.allocate(maximumBuffers: 2)
    let channels = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 512) }
    defer { channels.forEach { $0.deallocate() }; list.unsafeMutablePointer.deallocate() }
    for (i, c) in channels.enumerated() { list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 2048, mData: c) }
    engine.play()
    engine.render(frameCount: 512, bufferList: list.unsafeMutablePointer, host: mach_absolute_time())
    var waited = 0
    while sink.received.isEmpty, waited < 100 { try await Task.sleep(for: .milliseconds(10)); waited += 1 }
    #expect(sink.received.first == [0x90, 72, 100])
    engine.pause()
    engine.render(frameCount: 512, bufferList: list.unsafeMutablePointer, host: mach_absolute_time())
    waited = 0
    while sink.received.count < 2, waited < 100 { try await Task.sleep(for: .milliseconds(10)); waited += 1 }
    #expect(sink.received.last == [0x80, 72, 0], "the stop releases the note on the hardware")
}
