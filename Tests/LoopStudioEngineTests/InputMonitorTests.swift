import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

/// Writes `frames` of channel 0 = `value`, channel 1 = `-value` into the monitor, as the sound card would.
private func feed(_ m: InputMonitor, frames: Int, value: Float, block: Int = 256) {
    var left = [Float](repeating: value, count: frames), right = [Float](repeating: -value, count: frames)
    left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
            var done = 0
            while done < frames {
                let n = min(block, frames - done)
                m.write(frames: n) { c in c == 0 ? UnsafePointer(l.baseAddress! + done) : UnsafePointer(r.baseAddress! + done) }
                done += n
            }
        }
    }
}

/// Reads one output block of `frames`; returns what channel `channel` added, or nil when the input was not there.
private func read(_ m: InputMonitor, frames: Int, channel: Int, outputRate: Double = rate) -> [Float]? {
    var out = [Float](repeating: 0, count: frames)
    let ready = m.beginBlock(frames: frames, outputRate: outputRate)
    out.withUnsafeMutableBufferPointer { m.add(channel: channel, into: $0.baseAddress!, frames: frames) }
    m.endBlock()
    return ready ? out : nil
}

@Test func theOutputHearsWhatTheInputWrote() {
    let m = InputMonitor(channels: 2, sampleRate: rate)
    feed(m, frames: 1024, value: 0.5)
    let left = read(m, frames: 256, channel: 0), right = read(m, frames: 256, channel: 1)
    #expect(left?.allSatisfy { $0 == 0.5 } == true)
    #expect(right?.allSatisfy { $0 == -0.5 } == true)
}

@Test func aBlockWithoutInputIsSilentAndCounted() {
    let m = InputMonitor(channels: 1, sampleRate: rate)
    #expect(read(m, frames: 256, channel: 0) == nil)
    #expect(m.underrunCount == 1)
    // The input arrives: the next blocks play, and the cursor did not run ahead meanwhile.
    feed(m, frames: 2048, value: 0.25)
    #expect(read(m, frames: 256, channel: 0)?.allSatisfy { $0 == 0.25 } == true)
}

@Test func theReaderKeepsAboutOneInputBlockOfLead() {
    let m = InputMonitor(channels: 1, sampleRate: rate)
    feed(m, frames: 256 * 40, value: 1)
    // Far behind: the reader jumps to one input block (plus a block) behind the writer, not to the start.
    _ = read(m, frames: 256, channel: 0)
    // Now the writer adds one block per read: the lead stays, so every block is ready.
    for _ in 0..<50 {
        feed(m, frames: 256, value: 1)
        #expect(read(m, frames: 256, channel: 0) != nil)
    }
    #expect(m.underrunCount == 0)
}

@Test func anInputAtAnotherRateIsResampled() {
    // 96 kHz in, 48 kHz out: every output frame steps two input frames.
    let m = InputMonitor(channels: 1, sampleRate: 96_000)
    var ramp = (0..<4096).map { Float($0) }
    ramp.withUnsafeMutableBufferPointer { p in m.write(frames: 4096) { _ in UnsafePointer(p.baseAddress!) } }
    guard let out = read(m, frames: 256, channel: 0) else { Issue.record("no block"); return }
    // Consecutive output samples are 2 input frames apart.
    #expect(abs((out[10] - out[9]) - 2) < 0.001)
    #expect(abs((out[200] - out[100]) - 200) < 0.001)
}

@Test func aMonitoringTrackPlaysTheInputThroughItsFader() {
    var project = Project(name: "M", sampleRate: rate)
    var track = Track(name: "Mic", kind: .audio, volumeDb: -6)
    track.monitor = .input
    try! Command.insertTrack(track: track, index: 0).apply(to: &project)
    let inputs = [track.id: RenderPlan.MonitorInput(channels: InputChannels(first: 1, stereo: false), mutesClips: true)]
    let plan = RenderPlan.compile(project, bank: AudioBank(), inputs: inputs)
    #expect(plan.nodes[0].input?.left == 1 && plan.nodes[0].input?.right == nil)

    let renderer = Renderer(plan: plan, maxBlock: 256)
    let m = InputMonitor(channels: 2, sampleRate: rate)
    feed(m, frames: 2048, value: 0.5)
    renderer.inputMonitor = m
    var l = [Float](repeating: 0, count: 256), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        // The transport is stopped: monitoring plays anyway, like a live instrument.
        renderer.process(startFrame: 0, frames: 256, transport: false, outLeft: lp.baseAddress!, outRight: rp.baseAddress!)
    } }
    // Channel 1 held -0.5; one channel goes to both sides; the fader at -6 dB halves it.
    let expected = -0.5 * RenderPlan.dB(-6)
    #expect(abs(l[100] - expected) < 0.001 && abs(r[100] - expected) < 0.001)
}

@Test func monitorInSilencesTheClipsAndAutoKeepsThem() {
    var project = Project(name: "M", sampleRate: rate)
    let bank = AudioBank()
    let asset = Asset(sha256: "x", name: "t", frames: 48_000, sampleRate: rate, channels: 1)
    try! Command.addAsset(asset: asset).apply(to: &project)
    bank.insert(PCMBuffer(samples: [[Float](repeating: 0.5, count: 48_000)], sampleRate: rate), for: asset.id)
    let track = Track(name: "Mic", kind: .audio)
    try! Command.insertTrack(track: track, index: 0).apply(to: &project)
    try! Command.insertClip(track: track.id, clip: .audio(project.makeAudioClip(asset: asset.id, start: 0, length: 1920))).apply(to: &project)
    let channels = InputChannels(first: 0, stereo: true)
    let muted = RenderPlan.compile(project, bank: bank, inputs: [track.id: .init(channels: channels, mutesClips: true)])
    #expect(muted.nodes[0].clips.isEmpty && muted.nodes[0].input?.right == 1)
    let kept = RenderPlan.compile(project, bank: bank, inputs: [track.id: .init(channels: channels, mutesClips: false)])
    #expect(kept.nodes[0].clips.count == 1 && kept.nodes[0].input != nil)
    let none = RenderPlan.compile(project, bank: bank)
    #expect(none.nodes[0].input == nil)
}
