import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

/// A session clip on a track with a built-in instrument, launched at the start.
private func acidSession(noteTick: Tick) throws -> (Project, Track) {
    var project = Project(name: "Stuck", sampleRate: rate)
    var track = Track(name: "Acid", kind: .midi)
    track.devices = [try #require(BuiltInEffects.makeSlot("acid"))]
    try Command.insertTrack(track: track, index: 0).apply(to: &project)
    let clip = MIDIClip(start: 0, length: 3840, notes: [MIDINote(tick: noteTick, length: 1900, pitch: 45, velocity: 90)])
    try Command.setSlot(track: track.id, index: 0, slot: SessionSlot(clip: .midi(clip), quantize: .none)).apply(to: &project)
    try Command.setLaunches(launches: [Launch(track: track.id, slot: 0, tick: 0)]).apply(to: &project)
    track = project.tracks[0]
    return (project, track)
}

private func plan(_ project: Project) -> RenderPlan {
    RenderPlan.compile(project, bank: AudioBank(), session: SessionSimulator.run(project, horizon: 38_400))
}

private final class Blocks {
    let l = UnsafeMutablePointer<Float>.allocate(capacity: 512), r = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    deinit { l.deallocate(); r.deallocate() }
    /// Renders blocks of 512 from `from` to `to`, the session clock on the timeline clock. Returns the peak
    /// from `measureFrom` on (default: the last fifth).
    func run(_ renderer: Renderer, from: Int64, to: Int64, measureFrom: Int64? = nil) -> Float {
        var frame = from, peak: Float = 0
        let start = measureFrom ?? to - (to - from) / 5
        while frame < to {
            renderer.process(startFrame: frame, sessionFrame: frame, frames: 512, outLeft: l, outRight: r)
            if frame >= start { for i in 0..<512 { peak = max(peak, abs(l[i])) } }
            frame += 512
        }
        return peak
    }
}

@Test func movingASessionNoteWhileItSoundsEndsTheOldNote() throws {
    // The note starts at the top of the clip and lasts two beats. Half a beat in, the note moves to beat 3:
    // the new plan has no note-off for the sounding note, so the takeover must send it.
    let (project, track) = try acidSession(noteTick: 0)
    var moved = project
    let old = try #require(project.tracks[0].slots[0])
    guard case .midi(var clip) = old.clip else { Issue.record("a MIDI clip"); return }
    clip.notes[0].tick = 1920
    try Command.setSlot(track: track.id, index: 0, slot: SessionSlot(clip: .midi(clip), quantize: .none)).apply(to: &moved)
    func tail(takeOver: Bool) -> Float {
        let first = Renderer(plan: plan(project), maxBlock: 512)
        let blocks = Blocks()
        _ = blocks.run(first, from: 0, to: 12_288)
        let second = Renderer(plan: plan(moved), maxBlock: 512, reusing: first)
        if takeOver { second.takeOverNotes(from: first, at: 12_288, sessionFrame: 12_288) }
        // Up to beat 2 (48 000 frames) nothing new starts in the moved clip. The acid's level sinks while a
        // key is held, so the measure starts a tenth of a second after the takeover, when a released note is gone.
        return blocks.run(second, from: 12_288, to: 30_000, measureFrom: 12_288 + 4_800)
    }
    let stuck = tail(takeOver: false)
    let released = tail(takeOver: true)
    #expect(stuck > 0.05, "the note sounds on without the takeover: \(stuck)")
    #expect(released < stuck / 8, "stuck \(stuck), released \(released)")
}

@Test func theHeldMaskShowsTheKeysATrackPlays() throws {
    let (project, track) = try acidSession(noteTick: 0)
    let renderer = Renderer(plan: plan(project), maxBlock: 512)
    let blocks = Blocks()
    #expect(renderer.heldMask(track: track.id) == (0, 0))
    _ = blocks.run(renderer, from: 0, to: 4096)
    #expect(renderer.heldMask(track: track.id).low == 1 << 45)
    // Two beats later the note has ended.
    _ = blocks.run(renderer, from: 4096, to: 60_000)
    #expect(renderer.heldMask(track: track.id) == (0, 0))
    // A live note counts too, on the same key or another.
    renderer.sendLive(track: track.id, 0x90, 70, 100)
    #expect(renderer.heldMask(track: track.id).high == 1 << (70 - 64))
    renderer.sendLive(track: track.id, 0x80, 70, 0)
    #expect(renderer.heldMask(track: track.id) == (0, 0))
}
