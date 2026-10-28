import Foundation
import Testing
@testable import LoopStudioCore

private func track(_ name: String, _ kind: TrackKind) -> Track { Track(name: name, kind: kind) }

@Test func eachCommandUndoesExactly() throws {
    var p = Fixture.baseProject()
    let audio = track("Drums", .audio)
    let ret = track("Reverb", .returnTrack)
    try Command.insertTrack(track: audio, index: 0).apply(to: &p)
    try Command.insertTrack(track: ret, index: 1).apply(to: &p)

    let clip = Clip.audio(p.makeAudioClip(asset: Fixture.loopAsset.id, start: 960, length: 3840))
    let commands: [Command] = [
        .setTrackName(id: audio.id, name: "Kit"),
        .setVolume(id: audio.id, db: -6),
        .setPan(id: audio.id, pan: 0.5),
        .setMute(id: audio.id, mute: true),
        .setSolo(id: audio.id, solo: true),
        .setOutput(id: audio.id, target: ret.id),
        .setSends(id: audio.id, sends: [Send(target: ret.id, levelDb: -12)]),
        .insertClip(track: audio.id, clip: clip),
        .moveClip(clip: clip.id, toTrack: audio.id, start: 7680),
        .setClipRange(clip: clip.id, start: 0, length: 960),
        .setClipLoop(clip: clip.id, loop: false), // the 4 s asset loops by default
        .setSlot(track: audio.id, index: 3, slot: Fixture.dummySlot(follow: Fixture.follow(.next))),
        .setTempoPoints(points: [TempoPoint(tick: 0, bpm: 90)]),
        .setLoop(loop: LoopRegion(start: 0, end: 3840)),
        .setRandomSeed(seed: 42),
        .setAutoLoop(rule: AutoLoopRule(enabled: false)),
        .addAsset(asset: Asset(sha256: "cc", name: "x", frames: 10, sampleRate: 44_100, channels: 1)),
        .removeTrack(id: ret.id),
    ]
    for command in commands {
        let before = p
        let inverse = try command.apply(to: &p)
        #expect(p != before, "\(command) changed nothing")
        try inverse.apply(to: &p)
        #expect(p == before, "inverse of \(command) did not restore the project")
        try command.apply(to: &p)
    }
    #expect(p.validate().isEmpty)
}

@Test func failedCommandLeavesTheProjectUntouched() throws {
    var p = Fixture.baseProject()
    let t = track("A", .audio)
    try Command.insertTrack(track: t, index: 0).apply(to: &p)
    let before = p
    let batch = Command.batch(commands: [
        .setVolume(id: t.id, db: -3),
        .setVolume(id: TrackID(), db: -3), // fails: unknown track
    ])
    #expect(throws: CommandError.self) { try batch.apply(to: &p) }
    #expect(p == before)
}

@Test func routingCyclesAreRejected() throws {
    var p = Fixture.baseProject()
    let g1 = track("G1", .group), g2 = track("G2", .group), a = track("A", .audio)
    for (i, t) in [g1, g2, a].enumerated() { try Command.insertTrack(track: t, index: i).apply(to: &p) }
    try Command.setOutput(id: a.id, target: g1.id).apply(to: &p)
    try Command.setOutput(id: g1.id, target: g2.id).apply(to: &p)
    #expect(throws: CommandError.wouldCreateCycle) { try Command.setOutput(id: g2.id, target: g1.id).apply(to: &p) }
    #expect(throws: CommandError.wouldCreateCycle) { try Command.setOutput(id: g1.id, target: g1.id).apply(to: &p) }
    #expect(throws: CommandError.self) { try Command.setSends(id: g2.id, sends: [Send(target: g1.id)]).apply(to: &p) }
    #expect(p.validate().isEmpty)
}

@Test func tracksCannotFeedAudioTracks() throws {
    var p = Fixture.baseProject()
    let a = track("A", .audio), b = track("B", .audio)
    try Command.insertTrack(track: a, index: 0).apply(to: &p)
    try Command.insertTrack(track: b, index: 1).apply(to: &p)
    #expect(throws: CommandError.self) { try Command.setOutput(id: a.id, target: b.id).apply(to: &p) }
}

@Test func removingATrackFixesRoutesAndUndoRestoresThem() throws {
    var p = Fixture.baseProject()
    let ret = track("R", .returnTrack), a = track("A", .audio)
    try Command.insertTrack(track: ret, index: 0).apply(to: &p)
    try Command.insertTrack(track: a, index: 1).apply(to: &p)
    try Command.setSends(id: a.id, sends: [Send(target: ret.id)]).apply(to: &p)
    try Command.setOutput(id: a.id, target: ret.id).apply(to: &p)
    let before = p

    let inverse = try Command.removeTrack(id: ret.id).apply(to: &p)
    #expect(p.tracks.count == 1)
    #expect(p.tracks[0].sends.isEmpty && p.tracks[0].output == nil)
    #expect(p.validate().isEmpty)

    try inverse.apply(to: &p)
    #expect(p == before)
}

@Test func masterCannotBeChanged() throws {
    var p = Fixture.baseProject()
    #expect(throws: CommandError.cannotChangeMaster) { try Command.removeTrack(id: p.master.id).apply(to: &p) }
    #expect(throws: CommandError.cannotChangeMaster) {
        try Command.insertTrack(track: Track(name: "M2", kind: .master), index: 0).apply(to: &p)
    }
    // Volume of the master is allowed.
    try Command.setVolume(id: p.master.id, db: -3).apply(to: &p)
    #expect(p.master.volumeDb == -3)
}

@Test func clipRulesAreEnforced() throws {
    var p = Fixture.baseProject()
    let audio = track("A", .audio), midi = track("M", .midi)
    try Command.insertTrack(track: audio, index: 0).apply(to: &p)
    try Command.insertTrack(track: midi, index: 1).apply(to: &p)

    let good = Clip.audio(p.makeAudioClip(asset: Fixture.loopAsset.id, length: 960))
    // Wrong track kind.
    #expect(throws: CommandError.self) { try Command.insertClip(track: midi.id, clip: good).apply(to: &p) }
    // Missing asset.
    let orphan = Clip.audio(AudioClip(asset: AssetID(), length: 960))
    #expect(throws: CommandError.self) { try Command.insertClip(track: audio.id, clip: orphan).apply(to: &p) }
    // Zero length.
    let empty = Clip.audio(AudioClip(asset: Fixture.loopAsset.id, length: 0))
    #expect(throws: CommandError.self) { try Command.insertClip(track: audio.id, clip: empty).apply(to: &p) }
    // Duplicate ID.
    try Command.insertClip(track: audio.id, clip: good).apply(to: &p)
    #expect(throws: CommandError.self) { try Command.insertClip(track: audio.id, clip: good).apply(to: &p) }
    // A dummy clip fits a MIDI track; audio does not fit the master.
    try Command.insertClip(track: midi.id, clip: .dummy(DummyClip(length: 960))).apply(to: &p)
    #expect(throws: CommandError.self) { try Command.insertClip(track: p.master.id, clip: good).apply(to: &p) }
}

@Test func clipsStaySortedWhateverTheInsertOrder() throws {
    var p = Fixture.baseProject()
    let t = track("A", .audio)
    try Command.insertTrack(track: t, index: 0).apply(to: &p)
    for start in [3840, 0, 1920, 960] as [Int64] {
        let clip = Clip.audio(p.makeAudioClip(asset: Fixture.loopAsset.id, start: Tick(start), length: 480))
        try Command.insertClip(track: t.id, clip: clip).apply(to: &p)
    }
    #expect(p.tracks[0].clips.map(\.start.rawValue) == [0, 960, 1920, 3840])
}

@Test func assetInUseCannotBeRemoved() throws {
    var p = Fixture.baseProject()
    let t = track("A", .audio)
    try Command.insertTrack(track: t, index: 0).apply(to: &p)
    let clip = Clip.audio(p.makeAudioClip(asset: Fixture.loopAsset.id, length: 960))
    try Command.setSlot(track: t.id, index: 0, slot: SessionSlot(clip: clip)).apply(to: &p)
    #expect(throws: CommandError.assetInUse(Fixture.loopAsset.id)) {
        try Command.removeAsset(id: Fixture.loopAsset.id).apply(to: &p)
    }
    try Command.removeAsset(id: Fixture.songAsset.id).apply(to: &p)
}

@Test func slotsNeverEndWithAnEmptySlot() throws {
    var p = Fixture.baseProject()
    let t = track("A", .audio)
    try Command.insertTrack(track: t, index: 0).apply(to: &p)
    try Command.setSlot(track: t.id, index: 4, slot: Fixture.dummySlot()).apply(to: &p)
    #expect(p.tracks[0].slots.count == 5)
    try Command.setSlot(track: t.id, index: 4, slot: nil).apply(to: &p)
    #expect(p.tracks[0].slots.isEmpty)
    #expect(p.validate().isEmpty)
}

@Test func slotFollowActionsAreChecked() throws {
    var p = Fixture.baseProject()
    let t = track("A", .audio)
    try Command.insertTrack(track: t, index: 0).apply(to: &p)
    func slot(_ f: FollowActions) -> Command { .setSlot(track: t.id, index: 0, slot: Fixture.dummySlot(follow: f)) }

    #expect(throws: CommandError.self) { try slot(Fixture.follow(.next, wa: -1)).apply(to: &p) }
    #expect(throws: CommandError.self) { try slot(Fixture.follow(.next, wa: .nan)).apply(to: &p) }
    let noTarget = FollowActions(a: FollowAction(.jump), b: FollowAction(.stop, weight: 0), time: .loops(1))
    #expect(throws: CommandError.self) { try slot(noTarget).apply(to: &p) }
    let noTime = FollowActions(a: FollowAction(.next), b: FollowAction(.stop, weight: 0), time: .ticks(0))
    #expect(throws: CommandError.self) { try slot(noTime).apply(to: &p) }
    #expect(throws: CommandError.self) {
        try Command.setSlot(track: t.id, index: 20_000, slot: nil).apply(to: &p)
    }
}

@Test func aClipIdCannotLiveInTwoPlaces() throws {
    var p = Fixture.baseProject()
    let t = track("A", .audio)
    try Command.insertTrack(track: t, index: 0).apply(to: &p)
    let dummy = Clip.dummy(DummyClip(length: 960))
    try Command.setSlot(track: t.id, index: 0, slot: SessionSlot(clip: dummy)).apply(to: &p)
    #expect(throws: CommandError.self) { try Command.setSlot(track: t.id, index: 1, slot: SessionSlot(clip: dummy)).apply(to: &p) }
    #expect(throws: CommandError.self) { try Command.insertClip(track: t.id, clip: dummy).apply(to: &p) }
    // Replacing the slot that holds the clip is fine (editing follow actions).
    try Command.setSlot(track: t.id, index: 0, slot: SessionSlot(clip: dummy, follow: Fixture.follow(.replay))).apply(to: &p)
}

@Test func volumeAndPanAreClamped() throws {
    var p = Fixture.baseProject()
    let t = track("A", .audio)
    try Command.insertTrack(track: t, index: 0).apply(to: &p)
    try Command.setVolume(id: t.id, db: 100).apply(to: &p)
    try Command.setPan(id: t.id, pan: -7).apply(to: &p)
    #expect(p.tracks[0].volumeDb == 12 && p.tracks[0].pan == -1)
    #expect(throws: CommandError.self) { try Command.setVolume(id: t.id, db: .nan).apply(to: &p) }
}

@Test func commandsRoundTripThroughJSON() throws {
    let t = track("A", .audio)
    let command = Command.batch(commands: [
        .insertTrack(track: t, index: 0),
        .setSlot(track: t.id, index: 2, slot: Fixture.dummySlot(follow: Fixture.follow(.other, .topOfBlock, wa: 2, wb: 1))),
        .setOutput(id: t.id, target: nil),
    ])
    let data = try JSONEncoder().encode(command)
    let decoded = try JSONDecoder().decode(Command.self, from: data)
    var a = Fixture.baseProject()
    var b = a
    try command.apply(to: &a)
    try decoded.apply(to: &b)
    #expect(a == b)
}

// MARK: Random sequences

private func randomCommand(_ p: Project, _ rng: inout SplitMix64) -> Command {
    func anyTrack() -> Track? { p.tracks.isEmpty ? nil : p.tracks[rng.int(p.tracks.count)] }
    func newTrack() -> Command {
        let kinds: [TrackKind] = [.audio, .audio, .midi, .group, .returnTrack]
        let kind = kinds[rng.int(kinds.count)]
        return .insertTrack(track: Track(name: "T\(rng.int(100))", kind: kind), index: rng.int(p.tracks.count + 1))
    }
    guard let t = anyTrack() else { return newTrack() }

    switch rng.int(12) {
    case 0: return newTrack()
    case 1: return .removeTrack(id: t.id)
    case 2: return .setVolume(id: t.id, db: Double(rng.int(120)) - 100)
    case 3: return .setPan(id: t.id, pan: Double(rng.int(21)) / 10 - 1)
    case 4:
        let targets = p.tracks.filter { $0.kind == .group || $0.kind == .returnTrack }
        return .setOutput(id: t.id, target: targets.isEmpty || rng.int(4) == 0 ? nil : targets[rng.int(targets.count)].id)
    case 5:
        let returns = p.tracks.filter { $0.kind == .returnTrack || $0.kind == .group }
        let sends = returns.isEmpty ? [] : [Send(target: returns[rng.int(returns.count)].id, levelDb: -Double(rng.int(30)))]
        return .setSends(id: t.id, sends: sends)
    case 6:
        let clip = p.makeAudioClip(asset: rng.int(2) == 0 ? Fixture.loopAsset.id : Fixture.songAsset.id,
                                   start: Tick(Int64(rng.int(20) * 960)), length: Tick(Int64(1 + rng.int(8) * 480)))
        return .insertClip(track: t.id, clip: .audio(clip))
    case 7:
        let all = p.tracks.flatMap(\.clips)
        guard !all.isEmpty else { return newTrack() }
        return .moveClip(clip: all[rng.int(all.count)].id, toTrack: anyTrack()!.id, start: Tick(Int64(rng.int(30) * 480)))
    case 8:
        let follow = Fixture.follow([.next, .other, .any, .topOfBlock, .endOfBlock][rng.int(5)], .replay, wa: Double(rng.int(4)), wb: 1)
        let slot: SessionSlot? = rng.int(4) == 0 ? nil : Fixture.dummySlot(follow: follow)
        return .setSlot(track: t.id, index: rng.int(6), slot: slot)
    case 9:
        return .setTempoPoints(points: [TempoPoint(tick: 0, bpm: Double(60 + rng.int(100)), ramp: rng.int(2) == 0),
                                        TempoPoint(tick: Tick(Int64(1 + rng.int(40) * 960)), bpm: Double(60 + rng.int(100)))])
    case 10: return .setLoop(loop: rng.int(3) == 0 ? nil : LoopRegion(start: 0, end: Tick(Int64(960 + rng.int(10) * 960))))
    default: return .setMute(id: t.id, mute: rng.int(2) == 0)
    }
}

@Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64])
func randomEditsKeepInvariantsAndUndoBackToTheStart(seed: UInt64) throws {
    var rng = SplitMix64(seed: seed)
    let initial = Fixture.baseProject()
    var p = initial
    var inverses: [Command] = []
    var states: [Project] = []
    var accepted = 0

    for _ in 0..<500 {
        let before = p
        let command = randomCommand(p, &rng)
        guard let inverse = try? command.apply(to: &p) else {
            #expect(p == before, "a failed command changed the project")
            continue
        }
        accepted += 1
        inverses.append(inverse)
        states.append(before)
        #expect(p.validate().isEmpty, "invariant broken after \(command): \(p.validate())")
    }
    #expect(accepted > 100, "the generator must produce mostly valid commands")

    let final = p
    while let inverse = inverses.popLast() {
        try inverse.apply(to: &p)
        #expect(p == states.removeLast())
    }
    #expect(p == initial)
    #expect(final != initial)
}

// MARK: Devices

@Test func deviceCommandsUndoExactly() throws {
    var p = Fixture.baseProject()
    let t = Track(name: "A", kind: .audio)
    try Command.insertTrack(track: t, index: 0).apply(to: &p)
    let a = BuiltInEffects.makeSlot("delay")!, b = BuiltInEffects.makeSlot("reverb")!
    let commands: [Command] = [
        .insertDevice(track: t.id, device: a, index: nil),
        .insertDevice(track: t.id, device: b, index: 0),
        .moveDevice(track: t.id, device: b.id, to: 1),
        .setDeviceParam(track: t.id, device: a.id, key: "mix", value: 0.9),
        .setDeviceBypass(track: t.id, device: a.id, bypassed: true),
        .removeDevice(track: t.id, device: b.id),
    ]
    for command in commands {
        let before = p
        let inverse = try command.apply(to: &p)
        #expect(p != before)
        try inverse.apply(to: &p)
        #expect(p == before)
        try command.apply(to: &p)
    }
    #expect(p.tracks[0].devices.map(\.id) == [a.id])
    #expect(p.tracks[0].devices[0].params["mix"] == 0.9 && p.tracks[0].devices[0].bypassed)
    #expect(throws: CommandError.self) { try Command.insertDevice(track: t.id, device: a, index: nil).apply(to: &p) }
    #expect(throws: CommandError.self) { try Command.removeDevice(track: t.id, device: DeviceID()).apply(to: &p) }
}

@Test func oldDeviceFilesStillLoad() throws {
    let id = DeviceID()
    let json = #"{"id":"\#(id.rawValue.uuidString)","format":"builtin","identifier":"delay","name":"Delay","bypassed":false}"#
    let slot = try JSONDecoder().decode(DeviceSlot.self, from: Data(json.utf8))
    #expect(slot.params.isEmpty && slot.id == id)
}

@Test func tempoIsGuessedFromFileNames() {
    #expect(TempoGuess.fromFileName("Funky Drums 92 BPM.wav") == 92)
    #expect(TempoGuess.fromFileName("loop_120bpm.aif") == 120)
    #expect(TempoGuess.fromFileName("pad_85_Am.wav") == 85)
    #expect(TempoGuess.fromFileName("bpm128 bass.wav") == 128)
    #expect(TempoGuess.fromFileName("kick.wav") == nil)
    #expect(TempoGuess.fromFileName("take 7.wav") == nil, "7 is not a tempo")
    #expect(TempoGuess.fromFileName("sample_999.wav") == nil)
}

@Test func clipColorSetsAndUndoes() throws {
    var project = Project(name: "C")
    let t = Track(name: "T", kind: .midi)
    try Command.insertTrack(track: t, index: 0).apply(to: &project)
    let clip = MIDIClip(start: 0, length: 3_840)
    try Command.insertClip(track: t.id, clip: .midi(clip)).apply(to: &project)
    let undo = try Command.setClipColor(clip: clip.id, colorIndex: 4).apply(to: &project)
    #expect(project.findClip(clip.id)?.clip.colorIndex == 4)
    _ = try undo.apply(to: &project)
    #expect(project.findClip(clip.id)?.clip.colorIndex == nil)
    // A slot clip takes a colour too.
    let slotClip = MIDIClip(length: 3_840)
    try Command.setSlot(track: t.id, index: 0, slot: SessionSlot(clip: .midi(slotClip))).apply(to: &project)
    try Command.setClipColor(clip: slotClip.id, colorIndex: 2).apply(to: &project)
    #expect(project.findClip(slotClip.id)?.clip.colorIndex == 2)
}

@Test func deviceParamKeysAreCheckedAndValuesClamped() throws {
    var p = Fixture.baseProject()
    let t = Track(name: "A", kind: .audio)
    try Command.insertTrack(track: t, index: 0).apply(to: &p)
    let delay = BuiltInEffects.makeSlot("delay")!
    try Command.insertDevice(track: t.id, device: delay, index: nil).apply(to: &p)
    #expect(throws: CommandError.self, "a typo is refused, not stored") {
        try Command.setDeviceParam(track: t.id, device: delay.id, key: "mixx", value: 0.5).apply(to: &p)
    }
    try Command.setDeviceParam(track: t.id, device: delay.id, key: "mix", value: 7).apply(to: &p)
    let mix = BuiltInEffects.spec("delay")!.params.first { $0.key == "mix" }!
    #expect(p.tracks[0].devices[0].params["mix"] == mix.max)
}
