import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

/// A project with one audio track that plays a loud 440 Hz tone for 4 seconds.
private struct Rig {
    var project = Project(name: "A", sampleRate: rate)
    let bank = AudioBank()
    var track: Track

    init() {
        let n = Int(4 * rate)
        let samples = (0..<n).map { 0.5 * Float(sin(2 * .pi * 440 * Double($0) / rate)) }
        let asset = Asset(sha256: "t", name: "tone", frames: Int64(n), sampleRate: rate, channels: 2)
        try! Command.addAsset(asset: asset).apply(to: &project)
        bank.insert(PCMBuffer(samples: [samples, samples], sampleRate: rate), for: asset.id)
        var clip = project.makeAudioClip(asset: asset.id, start: 0, length: 7_680) // 4 s at 120 BPM
        clip.fadeInMs = 0; clip.fadeOutMs = 0
        track = Track(name: "T", kind: .audio, clips: [.audio(clip)])
        try! Command.insertTrack(track: track, index: 0).apply(to: &project)
    }

    func render(session: SessionSimulation? = nil, block: Int = 4096, seconds: Double = 4) -> RenderedAudio {
        Bounce.render(RenderPlan.compile(project, bank: bank, session: session), endFrame: Int64(seconds * rate), block: block)
    }
}

private func rms(_ x: ArraySlice<Float>) -> Float {
    guard !x.isEmpty else { return 0 }
    return (x.reduce(Float(0)) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
}

private func volumeLane(_ rig: Rig, _ points: [AutomationPoint]) -> Command {
    .setAutomation(track: rig.track.id, target: ParameterAddress(node: rig.track.id.rawValue, parameter: "volume"), points: points)
}

@Test func volumeEnvelopeFadesTheTrackIn() throws {
    var rig = Rig()
    try volumeLane(rig, [AutomationPoint(tick: 0, value: -60), AutomationPoint(tick: 3_840, value: 0)]).apply(to: &rig.project)
    let audio = rig.render()
    let start = rms(audio.left[0..<4800]), middle = rms(audio.left[48_000..<52_800]), end = rms(audio.left[100_000..<104_800])
    #expect(start < 0.01)
    #expect(middle > start * 10)
    #expect(abs(Double(end) - 0.5 / 2.0.squareRoot()) < 0.01, "after the last point the value holds: unity gain")
}

@Test func automationGivesTheSameSamplesAtAnyBlockSize() throws {
    var rig = Rig()
    try volumeLane(rig, [AutomationPoint(tick: 0, value: -30), AutomationPoint(tick: 1_920, value: 0, curve: .easeInOut),
                         AutomationPoint(tick: 3_840, value: -12)]).apply(to: &rig.project)
    try Command.setAutomation(track: rig.track.id, target: ParameterAddress(node: rig.track.id.rawValue, parameter: "pan"),
                              points: [AutomationPoint(tick: 0, value: -1), AutomationPoint(tick: 3_840, value: 1)]).apply(to: &rig.project)
    var filter = BuiltInEffects.makeSlot("filter")!
    filter.params = ["cutoff": 800]
    try Command.insertDevice(track: rig.track.id, device: filter, index: nil).apply(to: &rig.project)
    try Command.setAutomation(track: rig.track.id, target: ParameterAddress(node: filter.id.rawValue, parameter: "cutoff"),
                              points: [AutomationPoint(tick: 0, value: 200), AutomationPoint(tick: 3_840, value: 8_000)]).apply(to: &rig.project)
    let a = rig.render(block: 64), b = rig.render(block: 4096), c = rig.render(block: 333)
    #expect(a.left == b.left && a.right == b.right, "block 64 and 4096 are bit-identical")
    #expect(a.left == c.left, "an odd block size too")
}

@Test func panEnvelopeMovesTheSound() throws {
    var rig = Rig()
    try Command.setAutomation(track: rig.track.id, target: ParameterAddress(node: rig.track.id.rawValue, parameter: "pan"),
                              points: [AutomationPoint(tick: 0, value: -1), AutomationPoint(tick: 3_840, value: 1)]).apply(to: &rig.project)
    let audio = rig.render()
    #expect(rms(audio.left[0..<480]) > 0.3 && rms(audio.right[0..<480]) < 0.02, "starts on the left")
    #expect(rms(audio.right[100_000..<104_800]) > 0.3 && rms(audio.left[100_000..<104_800]) < 0.02, "ends on the right")
}

@Test func sendEnvelopeOpensASend() throws {
    var rig = Rig()
    let ret = Track(name: "R", kind: .returnTrack)
    try Command.insertTrack(track: ret, index: 1).apply(to: &rig.project)
    try Command.setVolume(id: rig.track.id, db: -96).apply(to: &rig.project)
    try Command.setSends(id: rig.track.id, sends: [Send(target: ret.id, levelDb: -60, preFader: true)]).apply(to: &rig.project)
    try Command.setAutomation(track: rig.track.id,
                              target: ParameterAddress(node: rig.track.id.rawValue, parameter: "send.\(ret.id.rawValue.uuidString)"),
                              points: [AutomationPoint(tick: 0, value: -60), AutomationPoint(tick: 3_840, value: 0)]).apply(to: &rig.project)
    let audio = rig.render()
    #expect(rms(audio.left[0..<4800]) < 0.001)
    #expect(rms(audio.left[100_000..<104_800]) > 0.3)
}

@Test func dummyClipAutomatesOnlyWhilePlaying() throws {
    var rig = Rig()
    // A dummy clip in a slot of the same track: for 1 bar (2 s) it mutes the track by volume.
    let target = ParameterAddress(node: rig.track.id.rawValue, parameter: "volume")
    let dummy = DummyClip(length: 3_840, lanes: [AutomationLane(target: target, points: [AutomationPoint(tick: 0, value: -96)])])
    try Command.setSlot(track: rig.track.id, index: 0, slot: SessionSlot(clip: .dummy(dummy), quantize: .none)).apply(to: &rig.project)
    try Command.setLaunches(launches: [Launch(track: rig.track.id, slot: 0, tick: 1_920)]).apply(to: &rig.project)
    let session = SessionSimulator.run(rig.project, horizon: 20_000)
    #expect(session.events.count == 1)

    let audio = rig.render(session: session)
    #expect(rms(audio.left[0..<40_000]) > 0.3, "before the dummy clip: normal")
    #expect(rms(audio.left[50_000..<140_000]) < 0.001, "while it plays: silent")
    #expect(rms(audio.left[150_000..<190_000]) > 0.3, "after it ended: normal again")
}

@Test func automationCommandsUndoAndCleanUp() throws {
    var rig = Rig()
    let target = ParameterAddress(node: rig.track.id.rawValue, parameter: "volume")
    let messy = [AutomationPoint(tick: 960, value: -6), AutomationPoint(tick: 0, value: -12), AutomationPoint(tick: 960, value: -3)]
    let before = rig.project
    let inverse = try Command.setAutomation(track: rig.track.id, target: target, points: messy).apply(to: &rig.project)
    let lane = try #require(rig.project.tracks[0].automation.first)
    #expect(lane.points.map(\.tick) == [0, 960], "sorted, one point per tick")
    #expect(lane.points[1].value == -3, "the later point wins")
    try inverse.apply(to: &rig.project)
    #expect(rig.project == before)
    #expect(throws: CommandError.self) {
        try Command.setAutomation(track: rig.track.id, target: target, points: [AutomationPoint(tick: 0, value: .nan)]).apply(to: &rig.project)
    }
    // Empty points remove the lane.
    try Command.setAutomation(track: rig.track.id, target: target, points: messy).apply(to: &rig.project)
    try Command.setAutomation(track: rig.track.id, target: target, points: []).apply(to: &rig.project)
    #expect(rig.project.tracks[0].automation.isEmpty)
}

@Test func curvesAndTargets() {
    let pts = [AutomationPoint(tick: 0, value: 0, curve: .hold), AutomationPoint(tick: 100, value: 10, curve: .easeIn), AutomationPoint(tick: 200, value: 20)]
    #expect(AutomationMath.value(pts, at: -5) == 0)
    #expect(AutomationMath.value(pts, at: 50) == 0, "hold keeps the value until the next point")
    #expect(AutomationMath.value(pts, at: 150) == 12.5, "ease-in at half is a quarter of the way")
    #expect(AutomationMath.value(pts, at: 999) == 20)
    #expect(AutomationMath.value([], at: 0) == nil)

    var p = Project(name: "T")
    var t = Track(name: "A", kind: .audio)
    t.devices = [BuiltInEffects.makeSlot("delay")!]
    try! Command.insertTrack(track: t, index: 0).apply(to: &p)
    let names = p.automationTargets(of: p.tracks[0]).map(\.name)
    #expect(names.contains("Volume") && names.contains("Pan") && names.contains("Delay › Feedback"))
}

@Test func clipGainEnvelopeShapesTheClipAndIgnoresBlockSize() throws {
    var rig = Rig()
    let clip = rig.track.clips[0].id
    try Command.setClipEnvelope(clip: clip, points: [AutomationPoint(tick: 0, value: 0), AutomationPoint(tick: 3_840, value: -60)])
        .apply(to: &rig.project)
    let audio = rig.render()
    let start = rms(audio.left[0..<960]), late = rms(audio.left[150_000..<154_800])
    #expect(abs(Double(start) - 0.5 / 2.0.squareRoot()) < 0.02, "near 0 dB at the clip start")
    #expect(late < 0.001, "-60 dB after the last point")
    let small = rig.render(block: 113)
    #expect(audio.left == small.left)
}

@Test func clipEnvelopeCommandUndoes() throws {
    var rig = Rig()
    let clip = rig.track.clips[0].id
    let before = rig.project
    let inverse = try Command.setClipEnvelope(clip: clip, points: [AutomationPoint(tick: 0, value: -6)]).apply(to: &rig.project)
    _ = try inverse.apply(to: &rig.project)
    #expect(rig.project == before)
}

/// The arrangement loop jumps the timeline back, but session clips run on the session clock.
@Test func sessionClipsFollowTheSessionClockNotTheLoop() throws {
    var rig = Rig()
    guard case .audio(var c) = rig.track.clips[0] else { Issue.record("no clip"); return }
    c.id = ClipID(); c.loop = true
    let session = Track(name: "S", kind: .audio, slots: [SessionSlot(clip: .audio(c))])
    try Command.insertTrack(track: session, index: 1).apply(to: &rig.project)
    try Command.removeTrack(id: rig.track.id).apply(to: &rig.project)
    rig.project.launches = [Launch(track: session.id, slot: 0, tick: 0)]
    let sim = SessionSimulator.run(rig.project, horizon: 38_400)
    let plan = RenderPlan.compile(rig.project, bank: rig.bank, session: sim)

    func render(timeline: Int64, session: Int64) -> [Float] {
        let renderer = Renderer(plan: plan, maxBlock: 512)
        var l = [Float](repeating: 0, count: 512), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            renderer.process(startFrame: timeline, sessionFrame: session, frames: 512, outLeft: lp.baseAddress!, outRight: rp.baseAddress!)
        } }
        return l
    }
    // Same session clock, different timeline position (a loop jumped back): the same sound.
    #expect(render(timeline: 96_000, session: 24_000) == render(timeline: 0, session: 24_000))
    // A stop at a later session time stays a stop after the loop jumps back.
    rig.project.launches.append(Launch(track: session.id, slot: nil, tick: 1_920))
    let stopped = RenderPlan.compile(rig.project, bank: rig.bank, session: SessionSimulator.run(rig.project, horizon: 38_400))
    let renderer = Renderer(plan: stopped, maxBlock: 512)
    var l = [Float](repeating: 0, count: 512), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        renderer.process(startFrame: 0, sessionFrame: 72_000, frames: 512, outLeft: lp.baseAddress!, outRight: rp.baseAddress!)
    } }
    #expect(l.allSatisfy { $0 == 0 }, "timeline at 0, but the session clock is past the stop")
}
