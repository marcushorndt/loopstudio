import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

private func sine(_ hz: Double, seconds: Double) -> PCMBuffer {
    let n = Int(seconds * rate)
    let s = (0..<n).map { Float(0.5 * sin(2 * Double.pi * hz * Double($0) / rate)) }
    return PCMBuffer(samples: [s, s], sampleRate: rate)
}

/// Counts upward zero crossings per second in a window.
private func frequency(_ x: UnsafePointer<Float>, from: Int, count: Int) -> Double {
    var crossings = 0
    for i in from + 1..<from + count where x[i - 1] < 0 && x[i] >= 0 { crossings += 1 }
    return Double(crossings) / (Double(count) / rate)
}

@Test func stretchKeepsPitchAndChangesLength() {
    let src = sine(440, seconds: 2)
    for ratio in [0.5, 0.8, 1.25, 2.0] {
        let out = TimeStretch.stretch(src, mode: .tones, outFrames: Int(Double(src.frames) * ratio)) { $0 / ratio }
        #expect(out.frames == Int(Double(src.frames) * ratio))
        let f = frequency(out.channel(0), from: 8_000, count: 24_000)
        #expect(abs(f - 440) < 6, "ratio \(ratio): \(f) Hz")
    }
}

@Test func ratioOneIsTransparent() {
    let src = sine(220, seconds: 1)
    let out = TimeStretch.stretch(src, mode: .beats, outFrames: src.frames) { $0 }
    var worst: Float = 0
    for i in 2_000..<(src.frames - 2_000) { worst = max(worst, abs(out.channel(0)[i] - src.channel(0)[i])) }
    #expect(worst < 1e-3, "worst difference \(worst)")
}

@Test func stretchIsDeterministic() {
    let src = sine(330, seconds: 1)
    let a = TimeStretch.stretch(src, mode: .tones, outFrames: 60_000) { $0 / 1.25 }
    let b = TimeStretch.stretch(src, mode: .tones, outFrames: 60_000) { $0 / 1.25 }
    #expect((0..<60_000).allSatisfy { a.channel(0)[$0] == b.channel(0)[$0] })
}

@Test func warpMappingMatchesTheTempoRatio() {
    // A 100 BPM loop of 4 beats (2.4 s) at a project tempo of 120 BPM lasts 2.0 s.
    let frames = Int(2.4 * rate)
    let m = WarpMapping.make(sourceFrames: frames, sourceTempo: 100, markers: [], assetRate: rate,
                             tempoMap: TempoMap(bpm: 120), startTick: 0, sampleRate: rate)
    #expect(m != nil)
    #expect(abs(Double(m!.outFrames) - 2.0 * rate) < 3)
    #expect(abs(m!.source(24_000) - 28_800) < 1, "half a second out is 0.6 s of source")
}

@Test func warpMarkersBendTime() {
    // Beat 1 of the audio at source frame 24000 (0.5 s), beat 2 at frame 72000 (1.5 s).
    let markers = [WarpMarker(sourceFrame: 24_000, tick: Tick(960)), WarpMarker(sourceFrame: 72_000, tick: Tick(1_920))]
    let m = WarpMapping.make(sourceFrames: 96_000, sourceTempo: nil, markers: markers, assetRate: rate,
                             tempoMap: TempoMap(bpm: 120), startTick: 0, sampleRate: rate)!
    // At 120 BPM, beat 1 is 0.5 s out and beat 2 is 1.0 s out.
    #expect(abs(m.source(24_000) - 24_000) < 2)
    #expect(abs(m.source(48_000) - 72_000) < 2)
}

@Test func warpedClipRendersAtTheProjectTempo() {
    var project = Project(name: "W", sampleRate: rate)
    let bank = AudioBank()
    // A 100 BPM two-beat loop (1.2 s) with a 440 Hz tone.
    let src = sine(440, seconds: 1.2)
    let asset = Asset(sha256: "w", name: "w", frames: Int64(src.frames), sampleRate: rate, channels: 2, sourceTempo: 100)
    try! Command.addAsset(asset: asset).apply(to: &project)
    bank.insert(src, for: asset.id)
    let t = Track(name: "T", kind: .audio)
    try! Command.insertTrack(track: t, index: 0).apply(to: &project)
    var clip = project.makeAudioClip(asset: asset.id, start: 0, length: Tick(1_920))
    clip.warpMode = .tones; clip.fadeInMs = 0; clip.fadeOutMs = 0
    try! Command.insertClip(track: t.id, clip: .audio(clip)).apply(to: &project)

    let plan = RenderPlan.compile(project, bank: bank)
    #expect(plan.warnings.isEmpty, "\(plan.warnings)")
    let out = Bounce.render(plan, startFrame: 0, endFrame: Int64(rate))   // 2 beats at 120 BPM = 1 s
    let f = frequency(out.left.withUnsafeBufferPointer { $0.baseAddress! }, from: 6_000, count: 36_000)
    #expect(abs(f - 440) < 8, "\(f) Hz")
    #expect(out.peak > 0.3)
}

@Test func warpWithoutTempoPlaysUnwarpedAndSaysSo() {
    var project = Project(name: "W", sampleRate: rate)
    let bank = AudioBank()
    let src = sine(440, seconds: 1)
    let asset = Asset(sha256: "w2", name: "w", frames: Int64(src.frames), sampleRate: rate, channels: 2)
    try! Command.addAsset(asset: asset).apply(to: &project)
    bank.insert(src, for: asset.id)
    let t = Track(name: "T", kind: .audio)
    try! Command.insertTrack(track: t, index: 0).apply(to: &project)
    var clip = project.makeAudioClip(asset: asset.id, start: 0, length: Tick(1_920))
    clip.warpMode = .beats
    try! Command.insertClip(track: t.id, clip: .audio(clip)).apply(to: &project)
    #expect(RenderPlan.compile(project, bank: bank).warnings.contains { $0.contains("no source tempo") })
}

@Test func warpCommandsUndoAndValidate() throws {
    var project = Project(name: "W", sampleRate: rate)
    let asset = Asset(sha256: "w3", name: "w", frames: 48_000, sampleRate: rate, channels: 2)
    try Command.addAsset(asset: asset).apply(to: &project)
    let undoTempo = try Command.setAssetTempo(id: asset.id, bpm: 128).apply(to: &project)
    #expect(project.asset(asset.id)?.sourceTempo == 128)
    _ = try undoTempo.apply(to: &project)
    #expect(project.asset(asset.id)?.sourceTempo == nil)
    #expect(throws: (any Error).self) { try Command.setAssetTempo(id: asset.id, bpm: 5).apply(to: &project) }

    let t = Track(name: "T", kind: .audio)
    try Command.insertTrack(track: t, index: 0).apply(to: &project)
    let clip = project.makeAudioClip(asset: asset.id, start: 0, length: Tick(1_920))
    try Command.insertClip(track: t.id, clip: .audio(clip)).apply(to: &project)
    let bad = [WarpMarker(sourceFrame: 100, tick: 960), WarpMarker(sourceFrame: 50, tick: 1_920)]
    #expect(throws: (any Error).self) { try Command.setClipWarp(clip: clip.id, mode: .beats, markers: bad).apply(to: &project) }
    let undo = try Command.setClipWarp(clip: clip.id, mode: .beats, markers: []).apply(to: &project)
    if case .audio(let c)? = project.findClip(clip.id)?.clip { #expect(c.warpMode == .beats) }
    _ = try undo.apply(to: &project)
    if case .audio(let c)? = project.findClip(clip.id)?.clip { #expect(c.warpMode == .off) }
}
