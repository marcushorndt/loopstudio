import AVFoundation
import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

/// A live engine fed by hand: the tests call the audio callback themselves, no sound card involved.
private final class Harness {
    let engine = LiveEngine(sampleRate: rate)
    let frames: Int
    let list: UnsafeMutableAudioBufferListPointer
    let channels: [UnsafeMutablePointer<Float>]
    var left: UnsafeMutablePointer<Float> { channels[0] }

    init(frames: Int = 512, channels count: Int = 2) {
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: count)
        channels = (0..<count).map { _ in .allocate(capacity: frames) }
        for (i, c) in channels.enumerated() { list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: c) }
    }

    deinit { channels.forEach { $0.deallocate() }; list.unsafeMutablePointer.deallocate() }

    func peak(_ channel: Int) -> Float { (0..<frames).reduce(0) { max($0, abs(channels[channel][$1])) } }

    /// One callback. Returns the peak of the left channel.
    @discardableResult
    func callback() -> Float {
        engine.render(frameCount: frames, bufferList: list.unsafeMutablePointer, host: 0)
        return (0..<frames).reduce(0) { max($0, abs(left[$1])) }
    }
}

/// A project with one audio track that plays a steady 0.5 for four seconds, optionally to a direct port.
private func plan(direct: Bool = false) -> RenderPlan {
    var project = Project(name: "L", sampleRate: rate)
    let bank = AudioBank()
    let n = Int(4 * rate)
    let asset = Asset(sha256: "live", name: "dc", frames: Int64(n), sampleRate: rate, channels: 2)
    try! Command.addAsset(asset: asset).apply(to: &project)
    bank.insert(PCMBuffer(samples: [Array(repeating: 0.5, count: n), Array(repeating: 0.5, count: n)], sampleRate: rate), for: asset.id)
    let t = Track(name: "A", kind: .audio)
    try! Command.insertTrack(track: t, index: 0).apply(to: &project)
    var c = project.makeAudioClip(asset: asset.id, start: 0, length: 7680)
    c.fadeInMs = 0; c.fadeOutMs = 0
    try! Command.insertClip(track: t.id, clip: .audio(c)).apply(to: &project)
    if direct { try! Command.setHardwareOutput(id: t.id, port: project.ports[1].id).apply(to: &project) }
    return RenderPlan.compile(project, bank: bank)
}

@Test func livePlaybackAdvancesTheClocksAndSounds() {
    let h = Harness()
    h.engine.setRenderer(Renderer(plan: plan()))
    #expect(h.callback() == 0, "stopped: no clip plays")
    #expect(h.engine.positionFrame == 0)
    h.engine.play()
    let peak = h.callback()
    #expect(abs(peak - 0.5) < 0.01)
    #expect(h.engine.positionFrame == 512 && h.engine.sessionFrame == 512)
    h.engine.pause()
    h.callback()
    #expect(h.engine.positionFrame == 512, "paused: the clock stands")
}

@Test func aSeekBetweenCallbacksWinsAndMetersReachTheControlThread() {
    let h = Harness()
    h.engine.setRenderer(Renderer(plan: plan()))
    h.engine.play()
    h.callback()
    h.engine.seek(to: 48_000)
    h.callback()
    #expect(h.engine.positionFrame == 48_512)
    #expect(h.engine.takePeak(node: 0) > 0.4 || h.engine.takePeak(node: 1) > 0.4, "a meter got the peak")
}

@Test func controlThreadsNeverWaitForARender() async {
    // A render runs while other threads seek, swap renderers and send notes. Nothing crashes, and the
    // clocks stay inside the song.
    let h = Harness(frames: 256)
    let p = plan()
    h.engine.setRenderer(Renderer(plan: p))
    h.engine.play()
    let engine = h.engine
    let control = Task.detached {
        for i in 0..<300 {
            if i % 3 == 0 { engine.seek(to: Int64(i * 100)) }
            if i % 7 == 0 { engine.setRenderer(Renderer(plan: p)) }
            engine.sendLiveMIDI(track: TrackID(), 0x90, 60, 100)
            _ = engine.takePeak(node: 0)
        }
    }
    for _ in 0..<600 { h.callback() }
    await control.value
    #expect(h.engine.positionFrame >= 0 && h.engine.positionFrame < 600 * 256 + 30_000)
}

@Test func onAStereoOutputADirectPortPlaysOnTheMasterPair() {
    let h = Harness()
    h.engine.setRenderer(Renderer(plan: plan(direct: true)))
    h.engine.play()
    #expect(abs(h.callback() - 0.5) < 0.01, "two channels only: the port folds onto the master pair")
}

@Test func onAFourChannelCardADirectPortPlaysOnItsOwnPair() {
    let h = Harness(channels: 4)
    let p = plan(direct: true)
    h.engine.setRenderer(Renderer(plan: p))
    h.engine.setRoutes(channels: 4, left: 0, right: 1, ports: [p.outputPorts[0]: (2, 3)])
    h.engine.play()
    h.callback()
    #expect(h.peak(0) == 0 && h.peak(1) == 0, "the master pair is silent")
    #expect(abs(h.peak(2) - 0.5) < 0.01 && abs(h.peak(3) - 0.5) < 0.01, "the port plays on channels 3 and 4")
}
