import Foundation
import Testing
@testable import LoopStudioCore
@testable import LoopStudioProject

enum Temp {
    static func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loopstudio-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A project with most features in use.
func richProject() throws -> Project {
    var p = Project(name: "Rich", sampleRate: 44_100)
    let loop = Asset(sha256: "aa", name: "loop.wav", frames: 4 * 44_100, sampleRate: 44_100, channels: 2, sourceTempo: 100)
    try Command.addAsset(asset: loop).apply(to: &p)

    let drums = Track(name: "Drums", kind: .audio, colorIndex: 3,
                      devices: [DeviceSlot(format: "audiounit", identifier: "aufx/dely/appl", name: "AUDelay",
                                           state: Data([1, 2, 3, 250]))])
    let reverb = Track(name: "Reverb", kind: .returnTrack)
    let keys = Track(name: "Keys", kind: .midi)
    for (i, t) in [drums, reverb, keys].enumerated() { try Command.insertTrack(track: t, index: i).apply(to: &p) }
    try Command.setSends(id: drums.id, sends: [Send(target: reverb.id, levelDb: -9.5, preFader: true)]).apply(to: &p)
    try Command.setVolume(id: drums.id, db: -4.25).apply(to: &p)

    let clip = Clip.audio(p.makeAudioClip(asset: loop.id, start: 960, length: 7680))
    try Command.insertClip(track: drums.id, clip: clip).apply(to: &p)
    let follow = FollowActions(a: FollowAction(.next, weight: 3), b: FollowAction(.other, weight: 1),
                               time: .loops(2), edge: .stop)
    try Command.setSlot(track: drums.id, index: 0, slot: SessionSlot(
        clip: .audio(p.makeAudioClip(asset: loop.id, length: 3840)), quantize: .beat, follow: follow)).apply(to: &p)
    try Command.setSlot(track: drums.id, index: 1, slot: Fixture.dummySlot(follow: follow)).apply(to: &p)
    try Command.setSlot(track: keys.id, index: 2, slot: SessionSlot(clip: .midi(MIDIClip(
        length: 1920, loop: true, notes: [MIDINote(tick: 0, length: 480, pitch: 64, velocity: 90)])))).apply(to: &p)

    try Command.setTempoPoints(points: [TempoPoint(tick: 0, bpm: 100, ramp: true), TempoPoint(tick: 7680, bpm: 128)]).apply(to: &p)
    try Command.setLoop(loop: LoopRegion(start: 0, end: 7680)).apply(to: &p)
    try Command.setRandomSeed(seed: 4_000_000_000).apply(to: &p)
    p.markers = [Marker(tick: 3840, name: "Drop")]
    return p
}

enum Fixture {
    static func dummySlot(follow: FollowActions? = nil) -> SessionSlot {
        SessionSlot(clip: .dummy(DummyClip(length: 3840)), follow: follow)
    }
}

private func allFiles(in dir: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    let base = dir.standardizedFileURL.path
    for case let url as URL in FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])! {
        guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
        result[String(url.standardizedFileURL.path.dropFirst(base.count))] = try Data(contentsOf: url)
    }
    return result
}

@Test func packageRoundTrip() throws {
    let dir = Temp.directory()
    let p = try richProject()
    try ProjectPackage.write(p, to: dir)
    let loaded = try ProjectPackage.read(from: dir)
    #expect(loaded.project == p)
    #expect(loaded.issues.isEmpty)
    #expect(loaded.migratedFrom == nil)
}

@Test func sameProjectGivesSameBytes() throws {
    let p = try richProject()
    let a = Temp.directory(), b = Temp.directory()
    try ProjectPackage.write(p, to: a)
    try ProjectPackage.write(p, to: b)
    #expect(try allFiles(in: a) == allFiles(in: b))
}

@Test func oneFilePerTrack() throws {
    let dir = Temp.directory()
    let p = try richProject()
    try ProjectPackage.write(p, to: dir)
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("tracks").path)
    #expect(names.count == p.allTracks.count)
}

@Test func editingOneTrackChangesOnlyItsFile() throws {
    let dir = Temp.directory()
    var p = try richProject()
    try ProjectPackage.write(p, to: dir)
    let before = try allFiles(in: dir)
    let drums = p.tracks[0]
    try Command.setPan(id: drums.id, pan: 0.25).apply(to: &p)
    try ProjectPackage.write(p, to: dir)
    let after = try allFiles(in: dir)
    let changed = before.keys.filter { before[$0] != after[$0] }
    #expect(changed == ["/tracks/\(drums.id.rawValue.uuidString).json"])
}

@Test func deletedTracksLoseTheirFiles() throws {
    let dir = Temp.directory()
    var p = try richProject()
    try ProjectPackage.write(p, to: dir)
    let removed = p.tracks[2]
    try Command.removeTrack(id: removed.id).apply(to: &p)
    try ProjectPackage.write(p, to: dir)
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("tracks").path)
    #expect(!names.contains("\(removed.id.rawValue.uuidString).json"))
    #expect(try ProjectPackage.read(from: dir).project == p)
}

@Test func otherFoldersInThePackageSurviveASave() throws {
    let dir = Temp.directory()
    let cache = dir.appendingPathComponent("cache/peaks.bin")
    try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([9]).write(to: cache)
    try ProjectPackage.write(try richProject(), to: dir)
    #expect(FileManager.default.fileExists(atPath: cache.path))
}

// MARK: Versions and migration

private func rewriteHeader(_ dir: URL, _ edit: (inout [String: Any]) -> Void) throws {
    let url = dir.appendingPathComponent("project.json")
    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    edit(&object)
    try JSONSerialization.data(withJSONObject: object).write(to: url)
}

@Test func newerFilesAreRefused() throws {
    let dir = Temp.directory()
    try ProjectPackage.write(try richProject(), to: dir)
    try rewriteHeader(dir) { $0["schemaVersion"] = 99 }
    #expect(throws: PackageError.newerVersion(found: 99, supported: ProjectPackage.schemaVersion)) {
        try ProjectPackage.read(from: dir)
    }
}

@Test func migrationStepsRunInOrder() throws {
    let dir = Temp.directory()
    try ProjectPackage.write(try richProject(), to: dir)
    let migrator = Migrator(currentVersion: 3, steps: [
        1: { raw in raw.header["name"] = (raw.header["name"] as! String) + "-v2" },
        2: { raw in raw.header["name"] = (raw.header["name"] as! String) + "-v3" },
    ])
    let loaded = try ProjectPackage.read(from: dir, migrator: migrator)
    #expect(loaded.project.name == "Rich-v2-v3")
    #expect(loaded.migratedFrom == 1)
}

@Test func migrationCanEditTrackFiles() throws {
    let dir = Temp.directory()
    try ProjectPackage.write(try richProject(), to: dir)
    let migrator = Migrator(currentVersion: 2, steps: [1: { raw in
        for key in raw.tracks.keys { raw.tracks[key]!["name"] = "migrated" }
    }])
    let loaded = try ProjectPackage.read(from: dir, migrator: migrator)
    #expect(loaded.project.allTracks.allSatisfy { $0.name == "migrated" })
}

@Test func missingMigrationStepIsAnError() throws {
    let dir = Temp.directory()
    try ProjectPackage.write(try richProject(), to: dir)
    #expect(throws: PackageError.missingMigration(from: 1)) {
        try ProjectPackage.read(from: dir, migrator: Migrator(currentVersion: 3, steps: [:]))
    }
}

// MARK: Hostile and damaged files

@Test func emptyFolderIsNotAProject() {
    #expect(throws: PackageError.self) { try ProjectPackage.read(from: Temp.directory()) }
}

@Test func trackIDsCannotEscapeThePackage() throws {
    let dir = Temp.directory()
    try ProjectPackage.write(try richProject(), to: dir)
    try rewriteHeader(dir) { $0["trackOrder"] = ["../../../etc/passwd"] }
    #expect(throws: PackageError.invalid("track ID is not a UUID")) { try ProjectPackage.read(from: dir) }
}

@Test func missingTrackFileIsReported() throws {
    let dir = Temp.directory()
    let p = try richProject()
    try ProjectPackage.write(p, to: dir)
    let victim = p.tracks[0].id.rawValue.uuidString
    try FileManager.default.removeItem(at: dir.appendingPathComponent("tracks/\(victim).json"))
    #expect(throws: PackageError.missingTrackFile(victim)) { try ProjectPackage.read(from: dir) }
}

@Test func brokenProjectFilesFailCleanlyAtEveryTruncation() throws {
    let dir = Temp.directory()
    try ProjectPackage.write(try richProject(), to: dir)
    let url = dir.appendingPathComponent("project.json")
    let full = try Data(contentsOf: url)
    for length in stride(from: 0, to: full.count, by: max(1, full.count / 60)) {
        try full.prefix(length).write(to: url)
        #expect(throws: PackageError.self) { try ProjectPackage.read(from: dir) }
    }
}

@Test func garbageInATrackFileFailsCleanly() throws {
    let dir = Temp.directory()
    let p = try richProject()
    try ProjectPackage.write(p, to: dir)
    let file = dir.appendingPathComponent("tracks/\(p.tracks[0].id.rawValue.uuidString).json")
    try Data("{\"name\": 5}".utf8).write(to: file)
    #expect(throws: PackageError.self) { try ProjectPackage.read(from: dir) }
}

@Test func loaderReportsIssuesInsteadOfCrashing() throws {
    let dir = Temp.directory()
    var p = try richProject()
    p.tracks[0].output = TrackID() // route to a track that does not exist
    try ProjectPackage.write(p, to: dir)
    let loaded = try ProjectPackage.read(from: dir)
    #expect(loaded.issues.contains { if case .routeTargetMissing = $0 { true } else { false } })
}

// MARK: Journal

@Test func journalRoundTripAndReset() throws {
    let url = Temp.directory().appendingPathComponent("journal.jsonl")
    let journal = try Journal(url: url, durable: false)
    try journal.append(.setRandomSeed(seed: 5))
    try journal.append(.setRandomSeed(seed: 6))
    #expect(try Journal.read(url: url).commands.count == 2)
    try journal.reset()
    #expect(try Journal.read(url: url).commands.isEmpty)
    try journal.append(.setRandomSeed(seed: 7))
    #expect(try Journal.read(url: url).commands.count == 1)
}

@Test func journalSurvivesACutOffLastLine() throws {
    let url = Temp.directory().appendingPathComponent("journal.jsonl")
    let journal = try Journal(url: url, durable: false)
    try journal.append(.setRandomSeed(seed: 5))
    try journal.append(.setRandomSeed(seed: 6))
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"setRandomSeed\":{\"se".utf8)) // power loss in the middle of a write
    try handle.close()
    let contents = try Journal.read(url: url)
    #expect(contents.commands.count == 2)
    #expect(contents.stoppedEarly)
}

@Test func crashRecoveryRebuildsTheLastState() async throws {
    let dir = Temp.directory()
    let saved = try richProject()
    try ProjectPackage.write(saved, to: dir)

    // Work continues after the save; every change goes to the journal. Then the app "crashes".
    let journal = try Journal(url: dir.appendingPathComponent("journal.jsonl"), durable: false)
    let store = ProjectStore(project: saved, journal: { try journal.append($0) })
    let extra = Track(name: "Bass", kind: .audio)
    try await store.apply(.insertTrack(track: extra, index: 0))
    try await store.apply(.setVolume(id: extra.id, db: -7), coalescingKey: "v")
    try await store.apply(.setVolume(id: extra.id, db: -8), coalescingKey: "v")
    try await store.undo()
    try await store.apply(.setMute(id: extra.id, mute: true))
    let expected = await store.project

    // Next start: load the last save, then replay the journal.
    let loaded = try ProjectPackage.read(from: dir)
    let contents = try Journal.read(url: dir.appendingPathComponent("journal.jsonl"))
    let replay = Journal.replay(contents.commands, onto: loaded.project)
    #expect(replay.failure == nil)
    #expect(replay.applied == contents.commands.count)
    #expect(replay.project == expected)
}

@Test func replayStopsAtTheFirstBadCommand() throws {
    let p = try richProject()
    let commands: [Command] = [.setRandomSeed(seed: 1), .setVolume(id: TrackID(), db: 0), .setRandomSeed(seed: 2)]
    let replay = Journal.replay(commands, onto: p)
    #expect(replay.applied == 1)
    #expect(replay.failure != nil)
    #expect(replay.project.randomSeed == 1)
}
