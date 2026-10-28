import Foundation
import Testing
@testable import LoopStudioCore

private func setup() -> (Project, TrackID) {
    var p = Fixture.baseProject()
    var t = Track(name: "A", kind: .audio)
    t.slots = [SessionSlot(clip: .audio(AudioClip(asset: Fixture.loopAsset.id, start: 0, length: 3_840, loop: true, fadeInMs: 2, fadeOutMs: 2)))]
    // An arrangement clip from bar 1 to bar 5.
    t.clips = [.audio(AudioClip(asset: Fixture.songAsset.id, start: 0, length: 15_360, loop: false, fadeInMs: 2, fadeOutMs: 2))]
    p.tracks = [t]
    return (p, t.id)
}

@Test func captureWritesEveryPassAndCutsTheArrangement() throws {
    var (p, id) = setup()
    let clipID = p.tracks[0].slots[0]!.clip.id
    // The looping slot played from bar 2 for two and a half bars.
    let events = [SessionEvent(track: id, slot: 0, clip: clipID, startTick: 3_840, endTick: 100_000, cause: .launch)]
    let commands = p.captureCommands(events, until: 13_440)
    try Command.batch(commands: commands).apply(to: &p)

    let clips = p.tracks[0].clips.sorted { $0.start < $1.start }
    #expect(clips.map(\.start) == [0, 3_840, 7_680, 11_520, 13_440])
    #expect(clips.map(\.length) == [3_840, 3_840, 3_840, 1_920, 1_920])
    // The arrangement clip keeps its head and its tail; the captured passes sit between them.
    #expect(clips.first?.loops == false && clips.last?.loops == false)
    #expect(Set(clips.map(\.id)).count == 5)
}

@Test func captureIsOneUndoStep() throws {
    let (p, id) = setup()
    let clipID = p.tracks[0].slots[0]!.clip.id
    let events = [SessionEvent(track: id, slot: 0, clip: clipID, startTick: 0, endTick: 7_680, cause: .launch)]
    var edited = p
    let inverse = try Command.batch(commands: p.captureCommands(events, until: 20_000)).apply(to: &edited)
    try inverse.apply(to: &edited)
    #expect(edited.tracks[0].clips == p.tracks[0].clips)
}

@Test func nothingPlayedMeansNothingToCapture() {
    let (p, id) = setup()
    let clipID = p.tracks[0].slots[0]!.clip.id
    let later = [SessionEvent(track: id, slot: 0, clip: clipID, startTick: 7_680, endTick: 9_000, cause: .launch)]
    #expect(p.captureCommands(later, until: 3_840).isEmpty)
}

@Test func clickFollowsTheTimeSignatures() {
    var p = Project(name: "M")
    // Two bars of 4/4, then 3/4.
    p.timeSignatures = [TimeSignatureChange(tick: 0, signature: TimeSignature(4, 4)),
                        TimeSignatureChange(tick: 7_680, signature: TimeSignature(3, 4))]
    let beats = p.clickBeats(upTo: Tick(7_680 + 2_880 * 2))
    #expect(beats.count == 8 + 6)
    #expect(beats.filter { $0.accent }.map { $0.tick.rawValue } == [0, 3_840, 7_680, 10_560])
    #expect(beats.allSatisfy { $0.tick.rawValue % 960 == 0 })
}

@Test func captureCutsTheArrangementFromTheFirstLaunchToNow() throws {
    var (p, id) = setup()
    let clipID = p.tracks[0].slots[0]!.clip.id
    // Two short parts with a gap: the arrangement stayed silent in the gap too.
    let events = [SessionEvent(track: id, slot: 0, clip: clipID, startTick: 0, endTick: 1_920, cause: .launch),
                  SessionEvent(track: id, slot: 0, clip: clipID, startTick: 7_680, endTick: 9_600, cause: .launch)]
    try Command.batch(commands: p.captureCommands(events, until: 11_520)).apply(to: &p)
    let clips = p.tracks[0].clips.sorted { $0.start < $1.start }
    #expect(clips.map(\.start) == [0, 7_680, 11_520], "only the tail of the arrangement clip stays")
}

@Test func captureSkipsASlotThatHoldsAnotherClipNow() {
    let (p, id) = setup()
    let events = [SessionEvent(track: id, slot: 0, clip: ClipID(), startTick: 0, endTick: 3_840, cause: .launch)]
    #expect(p.captureCommands(events, until: 3_840).isEmpty)
}

@Test func capturedPassesKeepTheAutomationPhase() throws {
    var (p, id) = setup()
    var slotClip = p.tracks[0].slots[0]!.clip
    // A two-bar ramp over a one-bar loop.
    slotClip.lanes = [AutomationLane(target: ParameterAddress(node: ParameterAddress.ownTrack, parameter: "volume"), points: [AutomationPoint(tick: 0, value: 0), AutomationPoint(tick: 7_680, value: 1)])]
    slotClip.automationLength = 7_680
    p.tracks[0].slots[0] = SessionSlot(clip: slotClip)
    let events = [SessionEvent(track: id, slot: 0, clip: slotClip.id, startTick: 0, endTick: 7_680, cause: .launch)]
    try Command.batch(commands: p.captureCommands(events, until: 7_680)).apply(to: &p)
    let clips = p.tracks[0].clips.sorted { $0.start < $1.start }
    try #require(clips.count == 3, "two passes, then the tail of the arrangement clip")
    #expect(clips[0].lanes[0].points.first?.value == 0)
    #expect(abs((clips[1].lanes[0].points.first?.value ?? 0) - 0.5) < 1e-9, "the second pass starts halfway up the ramp")
}

@Test func aSlotTakeIsCutToWholeBars() {
    let p = Project(name: "B")
    let asset = AssetID(UUID())
    // Recording began a quarter before bar 2 and ran just short of bar 4.
    let take = Clip.audio(AudioClip(asset: asset, start: 2_880, length: 8_400, loop: false))
    let aligned = p.barAligned(take)
    #expect(aligned.start == 3_840)
    #expect(aligned.length == 7_680, "two whole bars")
    if case .audio(let a) = aligned { #expect(a.offset == 960, "the audio before the bar line is skipped") }
    let short = Clip.audio(AudioClip(asset: asset, start: 0, length: 960, loop: false))
    #expect(p.barAligned(short) == short, "less than half a bar stays as it is")
}

@Test func sessionEventsMoveOntoTheTimeline() {
    let p = Fixture.baseProject()
    let bar = p.tempoMap.frame(at: 3_840, sampleRate: p.sampleRate).rawValue
    let e = SessionEvent(track: TrackID(), slot: 0, clip: ClipID(), startTick: 0, endTick: 3_840, cause: .launch)
    // Playback began at bar 3 while the session clock began at 0.
    let moved = p.onTimeline([e], shift: 2 * bar)
    #expect(moved.map(\.startTick) == [7_680] && moved.map(\.endTick) == [11_520])
    #expect(p.onTimeline([e], shift: -2 * bar).isEmpty, "a part before the timeline start goes")
}
