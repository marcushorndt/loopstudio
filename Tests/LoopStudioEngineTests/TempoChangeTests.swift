import AVFoundation
import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

/// A plan with one bar of audio at `bpm`.
private func plan(bpm: Double) -> RenderPlan {
    var project = Project(name: "T", sampleRate: rate)
    try! Command.setTempoPoints(points: [TempoPoint(tick: 0, bpm: bpm, ramp: false)]).apply(to: &project)
    let bank = AudioBank()
    let n = Int(8 * rate)
    let asset = Asset(sha256: "tempo", name: "dc", frames: Int64(n), sampleRate: rate, channels: 2)
    try! Command.addAsset(asset: asset).apply(to: &project)
    bank.insert(PCMBuffer(samples: [Array(repeating: 0.5, count: n), Array(repeating: 0.5, count: n)], sampleRate: rate), for: asset.id)
    let t = Track(name: "A", kind: .audio)
    try! Command.insertTrack(track: t, index: 0).apply(to: &project)
    var c = project.makeAudioClip(asset: asset.id, start: 0, length: 15_360)
    c.fadeInMs = 0; c.fadeOutMs = 0
    try! Command.insertClip(track: t.id, clip: .audio(c)).apply(to: &project)
    return RenderPlan.compile(project, bank: bank)
}

/// A tempo change keeps the beat the song stands on (like Live), not the second: at 120 BPM ten blocks in,
/// a plan at 60 BPM continues from the same tick, which is twice as many frames.
@Test func aTempoChangeKeepsTheBeatNotTheSecond() {
    let engine = LiveEngine(sampleRate: rate)
    let frames = 512
    let list = AudioBufferList.allocate(maximumBuffers: 2)
    let channels = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
    defer { channels.forEach { $0.deallocate() }; list.unsafeMutablePointer.deallocate() }
    for (i, c) in channels.enumerated() { list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: c) }
    func callback() { engine.render(frameCount: frames, bufferList: list.unsafeMutablePointer, host: 0) }

    engine.setRenderer(Renderer(plan: plan(bpm: 120)))
    engine.play()
    for _ in 0..<10 { callback() }
    #expect(engine.positionFrame == 5120 && engine.sessionFrame == 5120)

    // Half the tempo: the same tick now sits at twice the frame, plus the block just rendered.
    engine.setRenderer(Renderer(plan: plan(bpm: 60)))
    callback()
    #expect(engine.positionFrame == 10240 + 512, "\(engine.positionFrame)")
    #expect(engine.sessionFrame == 10240 + 512, "\(engine.sessionFrame)")

    // The same tempo again: nothing moves but the block.
    engine.setRenderer(Renderer(plan: plan(bpm: 60)))
    callback()
    #expect(engine.positionFrame == 10240 + 1024)
}

/// A control thread that holds the lock never holds up the audio thread: the callback returns at once, renders
/// with the state of the last block, and writes its clocks back when the lock is free again.
@Test func aHeldLockNeverStopsTheAudioThread() {
    let engine = LiveEngine(sampleRate: rate)
    let frames = 512
    let list = AudioBufferList.allocate(maximumBuffers: 2)
    let channels = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
    defer { channels.forEach { $0.deallocate() }; list.unsafeMutablePointer.deallocate() }
    for (i, c) in channels.enumerated() { list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: c) }
    func callback() { engine.render(frameCount: frames, bufferList: list.unsafeMutablePointer, host: 0) }

    engine.setRenderer(Renderer(plan: plan(bpm: 120)))
    engine.play()
    callback()
    #expect(engine.positionFrame == 512)

    // Hold the lock on another thread while three callbacks run.
    let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        engine.withLockHeldForTesting { held.signal(); release.wait() }
    }
    held.wait()
    let began = Date()
    for _ in 0..<3 { callback() }
    let took = Date().timeIntervalSince(began)
    #expect(took < 0.05, "the callbacks did not wait: \(took) s")
    #expect(engine.missedLocks >= 3)
    release.signal()
    // The lock is free: the next callback writes the four blocks back.
    usleep(20_000)
    callback()
    #expect(engine.positionFrame == 5 * 512, "\(engine.positionFrame)")
    #expect(engine.sessionFrame == 5 * 512)
}
