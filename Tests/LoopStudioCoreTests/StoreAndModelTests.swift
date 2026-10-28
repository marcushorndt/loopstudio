import Foundation
import Testing
@testable import LoopStudioCore

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Command] = []
    func add(_ c: Command) { lock.lock(); items.append(c); lock.unlock() }
    var commands: [Command] { lock.lock(); defer { lock.unlock() }; return items }
}

@Test func storeUndoRedo() async throws {
    let store = ProjectStore(project: Fixture.baseProject())
    let t = Track(name: "A", kind: .audio)
    try await store.apply(.insertTrack(track: t, index: 0))
    try await store.apply(.setVolume(id: t.id, db: -6))
    #expect(await store.project.tracks[0].volumeDb == -6)

    #expect(try await store.undo())
    #expect(await store.project.tracks[0].volumeDb == 0)
    #expect(try await store.undo())
    #expect(await store.project.tracks.isEmpty)
    #expect(try await store.undo() == false)

    #expect(try await store.redo())
    #expect(try await store.redo())
    #expect(await store.project.tracks[0].volumeDb == -6)
    #expect(try await store.redo() == false)
}

@Test func newEditClearsRedo() async throws {
    let store = ProjectStore(project: Fixture.baseProject())
    let t = Track(name: "A", kind: .audio)
    try await store.apply(.insertTrack(track: t, index: 0))
    try await store.undo()
    #expect(await store.canRedo)
    try await store.apply(.insertTrack(track: t, index: 0))
    #expect(await store.canRedo == false)
}

@Test func failedCommandChangesNothing() async throws {
    let log = Log()
    let store = ProjectStore(project: Fixture.baseProject(), journal: { log.add($0) })
    let before = await store.project
    await #expect(throws: CommandError.self) { try await store.apply(.setVolume(id: TrackID(), db: 0)) }
    #expect(await store.project == before)
    #expect(await store.revision == 0)
    #expect(await store.canUndo == false)
    #expect(log.commands.isEmpty)
}

@Test func journalFailureStopsTheChange() async throws {
    struct Disk: Error {}
    let store = ProjectStore(project: Fixture.baseProject(), journal: { _ in throw Disk() })
    let before = await store.project
    await #expect(throws: Disk.self) { try await store.apply(.setRandomSeed(seed: 9)) }
    #expect(await store.project == before)
}

@Test func coalescingMakesOneUndoStep() async throws {
    let store = ProjectStore(project: Fixture.baseProject())
    let t = Track(name: "A", kind: .audio)
    try await store.apply(.insertTrack(track: t, index: 0))
    for i in 1...200 {
        try await store.apply(.setVolume(id: t.id, db: -Double(i) / 10), coalescingKey: "fader")
    }
    #expect(await store.project.tracks[0].volumeDb == -20)
    try await store.undo() // the whole drag
    #expect(await store.project.tracks[0].volumeDb == 0)
    try await store.undo() // the insert
    #expect(await store.project.tracks.isEmpty)
    try await store.redo()
    try await store.redo()
    #expect(await store.project.tracks[0].volumeDb == -20)
}

@Test func differentKeysDoNotMerge() async throws {
    let store = ProjectStore(project: Fixture.baseProject())
    let t = Track(name: "A", kind: .audio)
    try await store.apply(.insertTrack(track: t, index: 0))
    try await store.apply(.setVolume(id: t.id, db: -3), coalescingKey: "volume")
    try await store.apply(.setPan(id: t.id, pan: 0.5), coalescingKey: "pan")
    try await store.undo()
    let after = await store.project.tracks[0]
    #expect(after.volumeDb == -3 && after.pan == 0)
}

@Test func replayingTheJournalGivesTheSameProject() async throws {
    let log = Log()
    let initial = Fixture.baseProject()
    let store = ProjectStore(project: initial, journal: { log.add($0) })
    let a = Track(name: "A", kind: .audio), r = Track(name: "R", kind: .returnTrack)
    try await store.apply(.insertTrack(track: a, index: 0))
    try await store.apply(.insertTrack(track: r, index: 1))
    try await store.apply(.setSends(id: a.id, sends: [Send(target: r.id)]))
    try await store.apply(.setVolume(id: a.id, db: -3), coalescingKey: "v")
    try await store.apply(.setVolume(id: a.id, db: -9), coalescingKey: "v")
    try await store.undo()
    try await store.apply(.removeTrack(id: r.id))
    try await store.undo()
    try await store.redo()

    var replayed = initial
    for command in log.commands { try command.apply(to: &replayed) }
    #expect(replayed == (await store.project))
    #expect(await store.revision == log.commands.count)
}

@Test func undoLimitDropsTheOldestEntries() async throws {
    let store = ProjectStore(project: Fixture.baseProject(), maxUndo: 3)
    for i in 1...10 { try await store.apply(.setRandomSeed(seed: UInt32(i))) }
    var undone = 0
    while try await store.undo() { undone += 1 }
    #expect(undone == 3)
    #expect(await store.project.randomSeed == 7)
}

// MARK: Model

@Test func clipsRoundTripThroughJSON() throws {
    let clips: [Clip] = [
        .audio(AudioClip(asset: AssetID(), start: 960, length: 3840, loop: true, gainDb: -2)),
        .midi(MIDIClip(length: 1920, notes: [MIDINote(tick: 0, length: 480, pitch: 60)])),
        .dummy(DummyClip(name: "choose", length: 1920)),
    ]
    for clip in clips {
        let data = try JSONEncoder().encode(clip)
        #expect(try JSONDecoder().decode(Clip.self, from: data) == clip)
    }
    let json = String(decoding: try JSONEncoder().encode(clips[2]), as: UTF8.self)
    #expect(json.contains("\"kind\":\"dummy\""))
}

@Test func unknownClipKindFailsToDecode() {
    let json = #"{"kind":"hologram","id":"11111111-2222-3333-4444-555555555555"}"#
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(Clip.self, from: Data(json.utf8)) }
}

@Test func newClipsGetTheDefaultFade() {
    var p = Fixture.baseProject()
    #expect(p.makeAudioClip(asset: Fixture.loopAsset.id, length: 960).fadeInMs == 2)
    p.defaultFadeMs = 5
    let clip = p.makeAudioClip(asset: Fixture.loopAsset.id, length: 960)
    #expect(clip.fadeInMs == 5 && clip.fadeOutMs == 5)
}

@Test func shortSamplesLoopAndLongOnesPlayOnce() throws {
    var p = Fixture.baseProject() // loop = 4 s, song = 60 s
    #expect(p.makeAudioClip(asset: Fixture.loopAsset.id, length: 960).loop)
    #expect(p.makeAudioClip(asset: Fixture.songAsset.id, length: 960).loop == false)

    try Command.setAutoLoop(rule: AutoLoopRule(maxSeconds: 120)).apply(to: &p)
    #expect(p.makeAudioClip(asset: Fixture.songAsset.id, length: 960).loop)

    try Command.setAutoLoop(rule: AutoLoopRule(minSeconds: 5, maxSeconds: 20)).apply(to: &p)
    #expect(p.makeAudioClip(asset: Fixture.loopAsset.id, length: 960).loop == false, "a hit below the lower limit plays once")

    try Command.setAutoLoop(rule: AutoLoopRule(enabled: false)).apply(to: &p)
    #expect(p.makeAudioClip(asset: Fixture.loopAsset.id, length: 960).loop == false)

    #expect(throws: CommandError.self) {
        try Command.setAutoLoop(rule: AutoLoopRule(minSeconds: 30, maxSeconds: 10)).apply(to: &p)
    }
}

@Test func validateFindsProblemsInABrokenProject() {
    var p = Fixture.baseProject()
    let a = Track(name: "A", kind: .audio)
    p.tracks = [a, a] // duplicate ID
    p.loop = LoopRegion(start: 100, end: 100)
    p.tracks[0].output = TrackID() // missing target
    p.tracks[0].slots = [Fixture.dummySlot(), nil]
    let issues = p.validate()
    #expect(issues.contains(.duplicateTrackID(a.id)))
    #expect(issues.contains(.invalidLoop))
    #expect(issues.contains(.slotsEndWithEmpty(a.id)))
    #expect(issues.contains { if case .routeTargetMissing = $0 { true } else { false } })
}
