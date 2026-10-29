import AVFoundation
import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

/// A project at 120 BPM / 48 kHz plus an audio bank with in-memory test signals.
private struct Rig {
    var project = Project(name: "R", sampleRate: rate)
    let bank = AudioBank()

    /// Adds an asset whose left and right channels hold `signal`.
    mutating func asset(seconds: Double, stereo: Bool = true, _ signal: (Int) -> Float) -> AssetID {
        let n = Int(seconds * rate)
        let samples = (0..<n).map(signal)
        let asset = Asset(sha256: UUID().uuidString, name: "t", frames: Int64(n), sampleRate: rate, channels: stereo ? 2 : 1)
        try! Command.addAsset(asset: asset).apply(to: &project)
        bank.insert(PCMBuffer(samples: stereo ? [samples, samples] : [samples], sampleRate: rate), for: asset.id)
        return asset.id
    }

    @discardableResult
    mutating func track(_ name: String, _ kind: TrackKind = .audio, volume: Double = 0, pan: Double = 0,
                        output: TrackID? = nil) -> TrackID {
        let t = Track(name: name, kind: kind, volumeDb: volume, pan: pan, output: output)
        try! Command.insertTrack(track: t, index: project.tracks.count).apply(to: &project)
        return t.id
    }

    /// Puts a clip on a track. Ticks: 960 = one beat = 0.5 s at 120 BPM.
    mutating func clip(_ asset: AssetID, on track: TrackID, startTick: Int64 = 0, lengthTick: Int64 = 1920,
                       fadeMs: Double = 0, loop: Bool = false, gainDb: Double = 0) {
        var c = project.makeAudioClip(asset: asset, start: Tick(startTick), length: Tick(lengthTick))
        c.fadeInMs = fadeMs; c.fadeOutMs = fadeMs; c.loop = loop; c.gainDb = gainDb
        try! Command.insertClip(track: track, clip: .audio(c)).apply(to: &project)
    }

    func render(block: Int = 4096, frames: Int? = nil) -> RenderedAudio {
        let plan = RenderPlan.compile(project, bank: bank)
        return Bounce.render(plan, startFrame: 0, endFrame: frames.map(Int64.init) ?? plan.endFrame, block: block)
    }

    var plan: RenderPlan { RenderPlan.compile(project, bank: bank) }
}

private func db(_ x: Float) -> Float { 20 * log10(x) }

@Test func clipStartsOnTheExactFrame() {
    var rig = Rig()
    let a = rig.asset(seconds: 2) { _ in 0.5 }
    rig.clip(a, on: rig.track("T"), startTick: 960) // beat 2 = 0.5 s = frame 24000
    let out = rig.render()
    #expect(out.left[23_999] == 0 && out.left[24_000] == 0.5)
    #expect(out.frames == 24_000 + 48_000, "ends where the clip ends (1920 ticks = 1 s)")
    #expect(out.left[out.frames - 1] == 0.5 && out.right[24_000] == 0.5)
}

@Test func defaultFadesRemoveClicks() {
    var rig = Rig()
    let a = rig.asset(seconds: 2) { _ in 0.5 }
    rig.clip(a, on: rig.track("T"), fadeMs: 2) // 96 frames
    let out = rig.render()
    #expect(out.left[0] == 0)
    #expect(out.left[95] > 0.49 && out.left[95] < 0.5)
    #expect(out.left[96] == 0.5)
    for i in 1..<96 { #expect(out.left[i] >= out.left[i - 1], "fade-in must rise smoothly") }
    #expect(out.left[out.frames - 1] == 0, "the last frame is silent")
    #expect(out.left[out.frames - 97] == 0.5)
}

@Test func fadesThatDoNotFitShareTheClip() {
    var rig = Rig()
    let a = rig.asset(seconds: 1) { _ in 1 }
    rig.clip(a, on: rig.track("T"), lengthTick: 96, fadeMs: 50) // 96 ticks = 0.05 s = 2400 frames; fades 2400+2400
    let out = rig.render()
    #expect(out.frames == 2_400)
    #expect(out.peak <= 1)
    #expect(out.left[1_199] > 0.99 && out.left[0] == 0 && out.left[out.frames - 1] == 0)
}

@Test func loopRepeatsAndOneShotEnds() {
    func render(loop: Bool) -> RenderedAudio {
        var rig = Rig()
        let a = rig.asset(seconds: 0.5) { _ in 0.25 } // 0.5 s asset, clip is 2 s long
        rig.clip(a, on: rig.track("T"), lengthTick: 3840, loop: loop)
        return rig.render()
    }
    let once = render(loop: false)
    #expect(once.frames == 96_000)
    #expect(once.left[1_000] == 0.25 && once.left[23_999] == 0.25)
    #expect(once.left[24_000] == 0 && once.left[90_000] == 0, "a one-shot plays once, then silence")

    let looped = render(loop: true)
    #expect(looped.left[1_000] == 0.25 && looped.left[25_000] == 0.25 && looped.left[73_000] == 0.25)
    #expect(looped.left[95_999] == 0.25)
}

@Test func faderPanMuteSolo() {
    var rig = Rig()
    let a = rig.asset(seconds: 1) { _ in 0.5 }
    let loud = rig.track("Loud"), quiet = rig.track("Quiet", volume: -6.0206), left = rig.track("Left", pan: -1)
    rig.clip(a, on: loud); rig.clip(a, on: quiet); rig.clip(a, on: left)

    func level(only id: TrackID) -> (Float, Float) {
        var r = rig
        for i in r.project.tracks.indices where r.project.tracks[i].id != id { r.project.tracks[i].mute = true }
        let out = r.render()
        return (out.left[20_000], out.right[20_000])
    }
    #expect(level(only: loud) == (0.5, 0.5))
    #expect(abs(level(only: quiet).0 - 0.25) < 0.001)
    #expect(level(only: left) == (0.5, 0), "hard left: right side silent")

    // Solo keeps only the soloed track.
    var soloed = rig
    soloed.project.tracks[1].solo = true // Quiet
    #expect(abs(soloed.render().left[20_000] - 0.25) < 0.001)

    // Everything muted gives silence.
    var muted = rig
    for i in muted.project.tracks.indices { muted.project.tracks[i].mute = true }
    #expect(muted.render(frames: 48_000).peak == 0)
}

@Test func volumeBelowTheFloorIsSilent() {
    #expect(RenderPlan.dB(-96) == 0 && RenderPlan.dB(-200) == 0)
    #expect(abs(RenderPlan.dB(0) - 1) < 1e-6 && abs(RenderPlan.dB(6.0206) - 2) < 1e-3)
}

@Test func groupSumsItsTracksAndAppliesItsOwnFader() {
    var rig = Rig()
    let a = rig.asset(seconds: 1) { _ in 0.25 }
    let group = rig.track("Group", .group, volume: -6.0206)
    let t1 = rig.track("A", output: group), t2 = rig.track("B", output: group)
    rig.clip(a, on: t1); rig.clip(a, on: t2)
    // Make sure the group sorts before its sources in the project, as users can order tracks freely.
    rig.project.tracks.swapAt(0, 2)
    let out = rig.render()
    #expect(abs(out.left[10_000] - 0.25) < 0.001, "0.25 + 0.25 = 0.5, half of that at -6 dB")
    #expect(rig.plan.warnings.isEmpty)
}

@Test func sendsCanTakeTheSignalBeforeOrAfterTheFader() {
    func render(pre: Bool) -> Float {
        var rig = Rig()
        let a = rig.asset(seconds: 1) { _ in 0.5 }
        let fx = rig.track("Return", .returnTrack)
        let t = rig.track("T", volume: -100) // fader all the way down
        rig.clip(a, on: t)
        try! Command.setSends(id: t, sends: [Send(target: fx, levelDb: 0, preFader: pre)]).apply(to: &rig.project)
        return rig.render().left[10_000]
    }
    #expect(render(pre: true) == 0.5, "pre-fader send ignores the fader")
    #expect(render(pre: false) == 0, "post-fader send follows the fader")
}

@Test func soloAlsoKeepsTheReturnsItFeeds() {
    var rig = Rig()
    let a = rig.asset(seconds: 1) { _ in 0.5 }
    let fx = rig.track("Return", .returnTrack)
    let dry = rig.track("Dry", volume: -100), other = rig.track("Other")
    rig.clip(a, on: dry); rig.clip(a, on: other)
    try! Command.setSends(id: dry, sends: [Send(target: fx, preFader: true)]).apply(to: &rig.project)
    try! Command.setSolo(id: dry, solo: true).apply(to: &rig.project)
    #expect(rig.render().left[10_000] == 0.5, "only the soloed track's send reaches the return; Other is silent")
}

@Test func soloingAGroupKeepsItsSources() {
    var rig = Rig()
    let a = rig.asset(seconds: 1) { _ in 0.5 }
    let group = rig.track("Group", .group)
    let kick = rig.track("Kick", output: group), other = rig.track("Other")
    rig.clip(a, on: kick); rig.clip(a, on: other)
    try! Command.setSolo(id: group, solo: true).apply(to: &rig.project)
    #expect(rig.render().left[10_000] == 0.5, "the group sounds with its source; Other is silent")
}

@Test func soloingAReturnKeepsOnlyTheSendsIntoIt() {
    var rig = Rig()
    let a = rig.asset(seconds: 1) { _ in 0.5 }
    let fx = rig.track("Return", .returnTrack)
    let source = rig.track("Source")
    rig.clip(a, on: source)
    try! Command.setSends(id: source, sends: [Send(target: fx, levelDb: 0, preFader: false)]).apply(to: &rig.project)
    try! Command.setSolo(id: fx, solo: true).apply(to: &rig.project)
    #expect(rig.render().left[10_000] == 0.5, "the send reaches the return, the dry path to the master stays off")
}

@Test func monoSourcesPlayOnBothSides() {
    var rig = Rig()
    let a = rig.asset(seconds: 1, stereo: false) { _ in 0.4 }
    rig.clip(a, on: rig.track("T"))
    let out = rig.render()
    #expect(out.left[1_000] == 0.4 && out.right[1_000] == 0.4)
}

@Test func blockSizeNeverChangesTheSound() {
    var rig = Rig()
    let sine = rig.asset(seconds: 0.7) { 0.6 * sinf(2 * .pi * 440 * Float($0) / Float(rate)) }
    let saw = rig.asset(seconds: 0.3) { Float($0 % 200) / 200 - 0.5 }
    let drums = rig.track("Drums", volume: -3, pan: 0.3), bass = rig.track("Bass", pan: -0.6)
    let group = rig.track("Group", .group, volume: -2), fx = rig.track("FX", .returnTrack)
    rig.clip(sine, on: drums, startTick: 100, lengthTick: 5_000, fadeMs: 2, loop: true, gainDb: -1.5)
    rig.clip(saw, on: bass, startTick: 1_500, lengthTick: 3_000, fadeMs: 5, loop: true)
    rig.clip(saw, on: bass, startTick: 6_000, lengthTick: 700, fadeMs: 2)
    for id in [drums, bass] { try! Command.setOutput(id: id, target: group).apply(to: &rig.project) }
    try! Command.setSends(id: drums, sends: [Send(target: fx, levelDb: -9)]).apply(to: &rig.project)
    try! Command.setSends(id: bass, sends: [Send(target: fx, levelDb: -12, preFader: true)]).apply(to: &rig.project)

    let reference = rig.render(block: 4096)
    #expect(reference.peak > 0.1)
    for block in [1, 64, 333, 1000, 2048] {
        let other = rig.render(block: block)
        #expect(other.left == reference.left && other.right == reference.right, "block size \(block) changed the audio")
    }
}

@Test func renderingTwiceGivesTheSameBytes() {
    var rig = Rig()
    let a = rig.asset(seconds: 1) { sinf(Float($0) * 0.05) }
    rig.clip(a, on: rig.track("T"), fadeMs: 3, loop: true)
    let x = rig.render(), y = rig.render()
    #expect(x.left == y.left && x.right == y.right)
}

@Test func problemsAreReportedNotHidden() {
    var rig = Rig()
    let a = rig.asset(seconds: 1) { _ in 0.5 }
    let direct = rig.track("Direct"), warped = rig.track("Warped"), missing = rig.track("Missing")
    rig.clip(a, on: direct)
    try! Command.setHardwareOutput(id: direct, port: rig.project.ports[1].id).apply(to: &rig.project)
    // Warped clip.
    var w = rig.project.makeAudioClip(asset: a, length: 1920); w.warpMode = .beats
    try! Command.insertClip(track: warped, clip: .audio(w)).apply(to: &rig.project)
    // A clip whose audio is not in the bank.
    let ghost = Asset(sha256: "ghost", name: "ghost", frames: 100, sampleRate: rate, channels: 1)
    try! Command.addAsset(asset: ghost).apply(to: &rig.project)
    try! Command.insertClip(track: missing, clip: .audio(rig.project.makeAudioClip(asset: ghost.id, length: 960))).apply(to: &rig.project)

    let warnings = rig.plan.warnings.joined(separator: "\n")
    #expect(warnings.contains("no source tempo"))
    #expect(warnings.contains("missing or unreadable"))
    #expect(rig.render().peak == 0.5, "the warped clip still plays, unwarped; the direct-out track is not in the master")
}

@Test func tempoChangesMoveClipsOnTheGrid() {
    var rig = Rig()
    let a = rig.asset(seconds: 4) { _ in 0.5 }
    try! Command.setTempoPoints(points: [TempoPoint(tick: 0, bpm: 60)]).apply(to: &rig.project)
    rig.clip(a, on: rig.track("T"), startTick: 960) // one beat at 60 BPM = 1 s
    let out = rig.render()
    #expect(out.left[47_999] == 0 && out.left[48_000] == 0.5)
}

// MARK: Files

private func writeSine(rate: Double, seconds: Double, channels: Int = 2) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sine-\(UUID().uuidString).wav")
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: false)!
    let n = AVAudioFrameCount(seconds * rate)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
    buf.frameLength = n
    for c in 0..<channels { for i in 0..<Int(n) { buf.floatChannelData![c][i] = 0.5 * sinf(2 * .pi * 1000 * Float(i) / Float(rate)) } }
    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                          AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 24])
    try file.write(from: buf)
    return url
}

@Test func filesAtOtherSampleRatesAreConvertedOnLoad() throws {
    let url = try writeSine(rate: 44_100, seconds: 1)
    let pcm = try AudioBank.decode(url, targetRate: 48_000)
    #expect(abs(pcm.frames - 48_000) < 64)
    #expect(pcm.sampleRate == 48_000 && pcm.channels == 2)
    // The tone must still be 1 kHz: count zero crossings in the middle second-half.
    var crossings = 0
    let ch = pcm.channel(0)
    for i in 12_000..<36_000 where (ch[i - 1] < 0) != (ch[i] < 0) { crossings += 1 }
    #expect(abs(crossings - 1_000) < 8, "24000 frames at 1 kHz = 0.5 s = 1000 crossings")
}

@Test func bounceWritesAWavThatReadsBack() throws {
    var rig = Rig()
    let a = rig.asset(seconds: 1) { 0.5 * sinf(2 * .pi * 440 * Float($0) / Float(rate)) }
    rig.clip(a, on: rig.track("T"), fadeMs: 2)
    let out = rig.render()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("bounce-\(UUID().uuidString).wav")
    try Bounce.writeWAV(out, to: url)
    let back = try AudioBank.decode(url, targetRate: rate)
    #expect(back.frames == out.frames)
    var worst: Float = 0
    for i in 0..<out.frames { worst = max(worst, abs(back.channel(0)[i] - out.left[i])) }
    #expect(worst < 1e-5, "24-bit quantisation only (worst error \(worst))")
}

@Test func unreadableFilesAreReportedPerAsset() {
    var project = Project(name: "P", sampleRate: rate)
    let asset = Asset(sha256: "x", name: "gone.wav", frames: 10, sampleRate: rate, channels: 2)
    try! Command.addAsset(asset: asset).apply(to: &project)
    let result = AudioBank.load(project: project) { _ in URL(fileURLWithPath: "/nonexistent/gone.wav") }
    #expect(result.failed[asset.id] != nil)
    let none = AudioBank.load(project: project) { _ in nil }
    #expect(none.failed[asset.id] == "file not found")
}

// MARK: Input from a track and sends-only output

@Test func trackTakesAnotherTrackAsInput() {
    var rig = Rig()
    let a = rig.asset(seconds: 2) { _ in 0.25 }
    let source = rig.track("Source", volume: -6)
    rig.clip(a, on: source)
    let listener = rig.track("Listener")
    try! Command.setInputTrack(id: listener, source: source).apply(to: &rig.project)
    let out = rig.render()
    // Source reaches the master twice: through its own output and through the listener. -6 dB is x0.501.
    #expect(abs(out.left[1_000] - 0.25 * 0.501_187 * 2) < 1e-4)
    // Monitor off cuts the listener's copy.
    try! Command.setMonitor(id: listener, mode: .off).apply(to: &rig.project)
    #expect(abs(rig.render().left[1_000] - 0.25 * 0.501_187) < 1e-4)
}

@Test func sendsOnlyTrackHasNoDirectOutput() {
    var rig = Rig()
    let a = rig.asset(seconds: 2) { _ in 0.25 }
    let t = rig.track("T")
    rig.clip(a, on: t)
    try! Command.setSendsOnly(id: t, sendsOnly: true).apply(to: &rig.project)
    let out = rig.render(frames: 4_000)
    #expect(out.left[1_000] == 0)
}

@Test func inputRoutingCannotCreateACycle() {
    var rig = Rig()
    let a = rig.track("A"), b = rig.track("B")
    try! Command.setInputTrack(id: b, source: a).apply(to: &rig.project)
    #expect(throws: (any Error).self) { try Command.setInputTrack(id: a, source: b).apply(to: &rig.project) }
    #expect(throws: (any Error).self) { try Command.setInputTrack(id: a, source: a).apply(to: &rig.project) }
}

// MARK: Plugin delay compensation

/// The renderer output as it is, without the latency trim of `Bounce` (the tests fake the plugin delay).
private func raw(_ plan: RenderPlan, frames: Int, block: Int = 4096) -> [Float] {
    var l = [Float](repeating: 0, count: frames), r = l
    let renderer = Renderer(plan: plan, maxBlock: block)
    l.withUnsafeMutableBufferPointer { lb in r.withUnsafeMutableBufferPointer { rb in
        for k in stride(from: 0, to: frames, by: block) {
            renderer.process(startFrame: Int64(k), frames: min(block, frames - k), outLeft: lb.baseAddress! + k, outRight: rb.baseAddress! + k)
        }
    } }
    return l
}

@Test func tracksWithoutLatencyWaitForTracksWithLatency() {
    var rig = Rig()
    let a = rig.asset(seconds: 2) { _ in 0.5 }
    let slow = rig.track("Slow"), fast = rig.track("Fast")
    rig.clip(a, on: slow); rig.clip(a, on: fast)
    var plan = rig.plan
    #expect(plan.latencyFrames == 0)
    plan.nodes[0].latency = 256            // the "Slow" track runs a plugin with 256 frames of latency
    plan.applyDelayCompensation()
    #expect(plan.latencyFrames == 256)
    let out = raw(plan, frames: 2_000)
    #expect(out[0] == 0.5 && out[255] == 0.5, "only Slow, whose plugin delay is not simulated here")
    #expect(out[256] == 1.0, "Fast now arrives 256 frames later and lines up")
    #expect(plan.arrival(of: slow) == 256 && plan.arrival(of: fast) == 0, "a resampled take of Slow moves back by 256")
}

@Test func compensationDoesNotDependOnBlockSize() {
    var rig = Rig()
    let a = rig.asset(seconds: 2) { Float(sin(Double($0) * 0.05)) * 0.4 }
    let slow = rig.track("Slow"), fast = rig.track("Fast"), ret = rig.track("Ret", .returnTrack)
    rig.clip(a, on: slow); rig.clip(a, on: fast)
    try! Command.setSends(id: fast, sends: [Send(target: ret, levelDb: -6)]).apply(to: &rig.project)
    var plan = rig.plan
    plan.nodes[0].latency = 300
    plan.applyDelayCompensation()
    let big = Bounce.render(plan, startFrame: 0, endFrame: 20_000, block: 4096)
    for block in [64, 333, 1000] {
        let other = Bounce.render(plan, startFrame: 0, endFrame: 20_000, block: block)
        #expect(zip(big.left, other.left).allSatisfy { $0 == $1 }, "block \(block)")
    }
}

@Test func noLatencyMeansNoDelayLines() {
    var rig = Rig()
    let a = rig.asset(seconds: 1) { _ in 0.5 }
    rig.clip(a, on: rig.track("T"))
    let plan = rig.plan
    #expect(plan.nodes.allSatisfy { $0.outputDelay == 0 && $0.tapDelays.allSatisfy { $0 == 0 } })
}

@Test func sessionTakeOverCutsTheArrangementOnlyFromItsStart() throws {
    var rig = Rig()
    let loud = rig.asset(seconds: 4) { _ in 0.5 }, soft = rig.asset(seconds: 4) { _ in 0.1 }
    let t = rig.track("T")
    rig.clip(loud, on: t, lengthTick: 7_680)
    let slotClip = rig.project.makeAudioClip(asset: soft, start: 0, length: 3_840)
    try Command.setSlot(track: t, index: 0, slot: SessionSlot(clip: .audio(slotClip), quantize: .none)).apply(to: &rig.project)
    try Command.setLaunches(launches: [Launch(track: t, slot: 0, tick: 1_920)]).apply(to: &rig.project)
    let sim = SessionSimulator.run(rig.project, horizon: 7_680)
    let plan = RenderPlan.compile(rig.project, bank: rig.bank, session: sim, arrangementEnds: [t: 48_000])
    let out = Bounce.render(plan, startFrame: 0, endFrame: 96_000, block: 512)
    #expect(out.left[24_000] == 0.5, "before the launch: the arrangement plays alone")
    #expect(abs(out.left[72_000] - 0.1) < 0.0001, "after the launch: only the session clip")
}

@Test func sessionClipPlaysFromItsOffsetAndLoopsItsLength() throws {
    var rig = Rig()
    let ramp = rig.asset(seconds: 2) { Float($0) / 96_000 }
    let t = rig.track("T")
    var c = rig.project.makeAudioClip(asset: ramp, start: 0, length: 960) // 0.5 s
    c.offset = 960; c.loop = true; c.fadeInMs = 0; c.fadeOutMs = 0
    try Command.setSlot(track: t, index: 0, slot: SessionSlot(clip: .audio(c), quantize: .none)).apply(to: &rig.project)
    try Command.setLaunches(launches: [Launch(track: t, slot: 0, tick: 0)]).apply(to: &rig.project)
    let plan = RenderPlan.compile(rig.project, bank: rig.bank, session: SessionSimulator.run(rig.project, horizon: 3_840))
    let out = Bounce.render(plan, startFrame: 0, endFrame: 72_000, block: 512)
    #expect(abs(out.left[0] - 24_000 / 96_000) < 1e-6, "starts at the clip offset, not at the file start")
    #expect(abs(out.left[24_000] - 24_000 / 96_000) < 1e-6, "after one clip length it loops back to the offset")
    #expect(abs(out.left[36_000] - 36_000 / 96_000) < 1e-6)
}

@Test func anEditKeepsTheCompensationDelay() {
    var rig = Rig()
    let a = rig.asset(seconds: 2) { Float(sin(Double($0) * 0.05)) * 0.4 }
    let slow = rig.track("Slow"), fast = rig.track("Fast")
    rig.clip(a, on: slow); rig.clip(a, on: fast)
    var plan = rig.plan
    plan.nodes[0].latency = 300
    plan.applyDelayCompensation()
    let whole = raw(plan, frames: 2_000, block: 500)

    // The same render, but a new renderer (an edit) takes over after 1000 frames.
    var l = [Float](repeating: 0, count: 2_000), r = l
    let first = Renderer(plan: plan, maxBlock: 500)
    l.withUnsafeMutableBufferPointer { lb in r.withUnsafeMutableBufferPointer { rb in
        for k in stride(from: 0, to: 1_000, by: 500) { first.process(startFrame: Int64(k), frames: 500, outLeft: lb.baseAddress! + k, outRight: rb.baseAddress! + k) }
        let second = Renderer(plan: plan, maxBlock: 500, reusing: first)
        for k in stride(from: 1_000, to: 2_000, by: 500) { second.process(startFrame: Int64(k), frames: 500, outLeft: lb.baseAddress! + k, outRight: rb.baseAddress! + k) }
    } }
    #expect(zip(whole, l).allSatisfy { $0 == $1 })
}

@Test func bounceRemovesTheCompensationLatency() {
    var rig = Rig()
    let a = rig.asset(seconds: 1) { _ in 0.5 }
    let slow = rig.track("Slow"), fast = rig.track("Fast")
    rig.clip(a, on: slow); rig.clip(a, on: fast)
    var plan = rig.plan
    plan.nodes[0].latency = 256
    plan.applyDelayCompensation()
    let out = Bounce.render(plan, startFrame: 0, endFrame: 2_000)
    #expect(out.frames == 2_000)
    #expect(out.left[0] == 1.0, "Fast lines up with frame 0 of the file, where Slow (no real delay here) already plays")
    #expect(raw(plan, frames: 2_256)[256...].elementsEqual(out.left))
}

@Test func aTrackCanRecordAnotherTracksSound() {
    var rig = Rig()
    let a = rig.asset(seconds: 1) { _ in 0.5 }
    let source = rig.track("Source", volume: -6)
    rig.clip(a, on: source)
    let renderer = Renderer(plan: rig.plan, maxBlock: 256)
    var l = [Float](repeating: 0, count: 256), r = l
    func block(_ start: Int64, transport: Bool) {
        l.withUnsafeMutableBufferPointer { lb in r.withUnsafeMutableBufferPointer { rb in
            renderer.process(startFrame: start, frames: 256, transport: transport, outLeft: lb.baseAddress!, outRight: rb.baseAddress!)
        } }
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LoopStudio-capture-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let writer = try! CaptureWriter(url: dir.appendingPathComponent("s.caf"), sampleRate: rate, channels: 2)
    let master = try! CaptureWriter(url: dir.appendingPathComponent("m.caf"), sampleRate: rate, channels: 2)
    let set = CaptureSet([(source, writer), (nil, master)])
    let ring = writer.ring, masterRing = master.ring
    renderer.captures = set
    block(0, transport: false)            // a count-in records nothing
    block(512, transport: true)
    block(768, transport: true)
    renderer.captures = nil
    block(1024, transport: true)          // after the stop, nothing more
    #expect(ring.startFrame == 512 && masterRing.startFrame == 512)
    var out = [Float](repeating: 0, count: 1_000), outR = out
    let n = out.withUnsafeMutableBufferPointer { o in outR.withUnsafeMutableBufferPointer { ro in ring.read(into: o.baseAddress!, ro.baseAddress!, max: 1_000) } }
    #expect(n == 512)
    #expect(abs(out[100] - l[100]) < 1e-6, "the recording is what the track sends to the master")
    var m = [Float](repeating: 0, count: 1_000), mR = m
    let mn = m.withUnsafeMutableBufferPointer { o in mR.withUnsafeMutableBufferPointer { ro in masterRing.read(into: o.baseAddress!, ro.baseAddress!, max: 1_000) } }
    #expect(mn == 512)
    #expect(abs(m[100] - l[100]) < 1e-6, "the master take is the mix after the master fader; here that is the one track")
    _ = writer.finish(); _ = master.finish()
}

@Test func sessionTakeOverStopsTheArrangementClipAutomation() throws {
    var rig = Rig()
    let a = rig.asset(seconds: 4) { _ in 0.5 }
    let t = rig.track("T")
    rig.clip(a, on: t, lengthTick: 7_680)
    let clip = rig.project.track(t)!.clips[0].id
    try Command.setClipAutomation(clip: clip, target: ParameterAddress(node: ParameterAddress.ownTrack, parameter: "volume"),
                                  points: [AutomationPoint(tick: 0, value: -12)]).apply(to: &rig.project)
    let plan = RenderPlan.compile(rig.project, bank: rig.bank, arrangementEnds: [t: 48_000])
    let lane = try #require(plan.nodes[0].volumeAuto)
    #expect(lane.value(at: 24_000) == -12, "before the take-over the clip moves the volume")
    #expect(lane.value(at: 72_000) == nil, "after it the clip automation stops")
    #expect(lane.value(at: 24_000, sessionOffset: 48_000) == nil, "the cut counts on the session clock")
}

@Test func aDirectOutputPlaysOnItsPortBusNotTheMaster() {
    var rig = Rig()
    let a = rig.asset(seconds: 1) { _ in 0.5 }
    let direct = rig.track("Direct")
    rig.clip(a, on: direct)
    let cue = rig.project.ports[1].id
    try! Command.setHardwareOutput(id: direct, port: cue).apply(to: &rig.project)
    let plan = rig.plan
    #expect(plan.outputPorts == [cue])
    let renderer = Renderer(plan: plan, maxBlock: 256)
    let l = UnsafeMutablePointer<Float>.allocate(capacity: 256), r = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    defer { l.deallocate(); r.deallocate() }
    renderer.process(startFrame: 0, frames: 256, outLeft: l, outRight: r)
    #expect((0..<256).allSatisfy { l[$0] == 0 }, "the master is silent")
    #expect(abs(renderer.portLeft(0)[100] - 0.5) < 0.001 && abs(renderer.portRight(0)[100] - 0.5) < 0.001)
}
