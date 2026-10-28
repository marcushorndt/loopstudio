import Foundation
import Testing
@testable import LoopStudioEngine

private let sampleRate = 48_000.0

/// Runs `seconds` of audio through the effect in blocks and returns the output of channel 0.
/// The input is a 440 Hz sine for the first `toneSeconds`, then silence.
private func run(_ effect: AudioUnitEffect, seconds: Double, toneSeconds: Double, block: Int = 512) -> [Float] {
    let total = Int(seconds * sampleRate)
    let toneFrames = Int(toneSeconds * sampleRate)
    var result: [Float] = []
    result.reserveCapacity(total)

    let channels = effect.channels
    let inBuffers = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: block) }
    let outBuffers = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: block) }
    defer { inBuffers.forEach { $0.deallocate() }; outBuffers.forEach { $0.deallocate() } }
    let inPointers = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: channels)
    let outPointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channels)
    defer { inPointers.deallocate(); outPointers.deallocate() }
    for ch in 0..<channels { inPointers[ch] = UnsafePointer(inBuffers[ch]); outPointers[ch] = outBuffers[ch] }

    var position = 0
    while position < total {
        let frames = min(block, total - position)
        for ch in 0..<channels {
            for i in 0..<frames {
                let n = position + i
                inBuffers[ch][i] = n < toneFrames ? 0.5 * sinf(2 * .pi * 440 * Float(n) / Float(sampleRate)) : 0
            }
        }
        let status = effect.process(frames: frames, input: inPointers, output: outPointers)
        #expect(status == noErr, "status \(status)")
        result.append(contentsOf: UnsafeBufferPointer(start: outBuffers[0], count: frames))
        position += frames
    }
    return result
}

private func energy(_ samples: ArraySlice<Float>) -> Float {
    samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))
}

/// Spike S1: can our own code host an Apple Audio Unit through its render block?
@Test func hostsAppleDelayThroughTheRenderBlock() async throws {
    let delay = try await AudioUnitEffect.instantiate(type: "aufx", subtype: "dely", manufacturer: "appl",
                                                      sampleRate: sampleRate)
    // AUDelay defaults: 1 s delay time, 50% wet. The tone ends at 0.5 s.
    let out = run(delay, seconds: 2.5, toneSeconds: 0.5)
    let first = Int(0.1 * sampleRate)
    let secondStart = Int(1.1 * sampleRate)
    #expect(energy(out[first..<first + 4800]) > 0.001, "dry part must be audible")
    #expect(energy(out[secondStart..<secondStart + 4800]) > 0.0005, "echo must arrive after the delay time")
    #expect(energy(out[Int(0.7 * sampleRate)..<Int(0.9 * sampleRate)]) < 0.0001, "silence between tone and echo")
}

@Test func blockSizeDoesNotChangeTheResult() async throws {
    // The same input in 64-frame and 1024-frame blocks must give the same output.
    func render(block: Int) async throws -> [Float] {
        let fx = try await AudioUnitEffect.instantiate(type: "aufx", subtype: "dely", manufacturer: "appl",
                                                       sampleRate: sampleRate)
        return run(fx, seconds: 1.5, toneSeconds: 0.5, block: block)
    }
    let a = try await render(block: 64)
    let b = try await render(block: 1024)
    #expect(a.count == b.count)
    let worst = zip(a, b).map { abs($0 - $1) }.max() ?? 0
    #expect(worst < 1e-4, "block size changed the sound (max difference \(worst))")
}

@Test func unknownAudioUnitIsAnErrorNotACrash() async {
    await #expect(throws: AudioUnitEffect.HostError.self) {
        _ = try await AudioUnitEffect.instantiate(type: "aufx", subtype: "nope", manufacturer: "none", sampleRate: sampleRate)
    }
}

@Test func reportsLatency() async throws {
    let fx = try await AudioUnitEffect.instantiate(type: "aufx", subtype: "dely", manufacturer: "appl", sampleRate: sampleRate)
    #expect(fx.latencySamples >= 0)
}
