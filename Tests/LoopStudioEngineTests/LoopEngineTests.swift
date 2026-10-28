import AVFoundation
import Testing
@testable import LoopStudioEngine

private func makeSine(seconds: Double, sampleRate: Double = 44100) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sine-\(UUID().uuidString).caf")
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buf.frameLength = frames
    for ch in 0..<2 {
        for i in 0..<Int(frames) {
            buf.floatChannelData![ch][i] = 0.5 * sinf(2 * .pi * 440 * Float(i) / Float(sampleRate))
        }
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buf)
    return url
}

private func peak(_ buf: AVAudioPCMBuffer) -> Float {
    let data = buf.floatChannelData![0]
    return (0..<Int(buf.frameLength)).map { abs(data[$0]) }.max() ?? 0
}

@Test func rateFollowsProjectTempo() throws {
    let engine = try LoopEngine(mode: .offline(sampleRate: 44100))
    try engine.load(url: makeSine(seconds: 1), sourceTempo: 100)
    engine.projectTempo = 150
    #expect(engine.rate == 1.5)
}

@Test func offlineRenderIsNotSilent() throws {
    let engine = try LoopEngine(mode: .offline(sampleRate: 44100))
    try engine.load(url: makeSine(seconds: 1), sourceTempo: 120)
    try engine.start()
    let out = try engine.render(frames: 44100 * 2)
    #expect(out.frameLength == 44100 * 2)
    #expect(peak(out) > 0.1)
}

@Test func loopContinuesPastClipLength() throws {
    let engine = try LoopEngine(mode: .offline(sampleRate: 44100))
    try engine.load(url: makeSine(seconds: 1), sourceTempo: 120)
    try engine.start()
    _ = try engine.render(frames: 44100 * 2)
    let tail = try engine.render(frames: 4096)
    #expect(peak(tail) > 0.1)
}

@Test func startWithoutClipThrows() throws {
    let engine = try LoopEngine(mode: .offline(sampleRate: 44100))
    #expect(throws: LoopEngine.EngineError.self) { try engine.start() }
}
