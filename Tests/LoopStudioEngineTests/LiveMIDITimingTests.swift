import AVFoundation
import CoreMIDI
import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

/// A virtual destination that keeps the time stamp of every channel message it gets.
private final class StampSink: @unchecked Sendable {
    var client = MIDIClientRef(), endpoint = MIDIEndpointRef()
    private let lock = NSLock()
    private var stamps: [(UInt64, [UInt8])] = []
    var received: [(UInt64, [UInt8])] { lock.lock(); defer { lock.unlock() }; return stamps }

    init?() {
        guard MIDIClientCreateWithBlock("LoopStudio Timing Test" as CFString, &client, { _ in }) == noErr else { return nil }
        let status = MIDIDestinationCreateWithProtocol(client, "LoopStudio Stamp Sink" as CFString, ._1_0, &endpoint) { [weak self] list, _ in
            guard let self else { return }
            for packet in list.unsafeSequence() {
                let time = packet.pointee.timeStamp
                for word in packet.words() where word >> 28 == 2 {
                    self.lock.lock()
                    self.stamps.append((time, [UInt8((word >> 16) & 0xFF), UInt8((word >> 8) & 0x7F), UInt8(word & 0x7F)]))
                    self.lock.unlock()
                }
            }
        }
        guard status == noErr else { return nil }
    }
    deinit { MIDIEndpointDispose(endpoint); MIDIClientDispose(client) }
}

private func engineWithHardware(_ sink: StampSink) -> (LiveEngine, TrackID) {
    var project = Project(name: "T", sampleRate: rate)
    let track = Track(name: "Keys", kind: .midi)
    project.tracks = [track]
    let engine = LiveEngine(sampleRate: rate)
    engine.setRenderer(Renderer(plan: RenderPlan.compile(project, bank: AudioBank(), midiOutputs: [track.id: MIDIOutTarget(endpoint: sink.endpoint)])))
    return (engine, track.id)
}

private func render(_ engine: LiveEngine, host: UInt64) {
    let list = AudioBufferList.allocate(maximumBuffers: 2)
    let channels = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 512) }
    defer { channels.forEach { $0.deallocate() }; list.unsafeMutablePointer.deallocate() }
    for (i, c) in channels.enumerated() { list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 2048, mData: c) }
    engine.render(frameCount: 512, bufferList: list.unsafeMutablePointer, host: host)
}

private func wait(for sink: StampSink, count: Int) async throws {
    var waited = 0
    while sink.received.count < count, waited < 200 { try await Task.sleep(for: .milliseconds(10)); waited += 1 }
}

/// A live note with a due time goes out at that time, to the sample, not at the top of the block. A note
/// due in a later block waits for it. A note whose time is past goes out at once.
@Test func liveNotesWithADueTimeSoundAtThatTime() async throws {
    guard let sink = StampSink() else { return } // no CoreMIDI server here
    let (engine, track) = engineWithHardware(sink)
    let host = mach_absolute_time() &+ HostClock.ticks(fromSeconds: 0.5)
    func later(_ frames: Int) -> UInt64 { host &+ HostClock.ticks(fromSeconds: Double(frames) / rate) }
    engine.sendLiveMIDI(track: track, 0x90, 60, 100, atHost: later(100))
    engine.sendLiveMIDI(track: track, 0x90, 62, 100, atHost: later(600))
    engine.sendLiveMIDI(track: track, 0x90, 64, 100, atHost: host &- HostClock.ticks(fromSeconds: 0.1))
    engine.sendLiveMIDI(track: track, 0x90, 65, 100)
    render(engine, host: host)
    try await wait(for: sink, count: 3)
    let first = sink.received
    #expect(first.map { $0.1[1] }.sorted() == [60, 64, 65], "the note 600 frames ahead waits for the next block")
    func offset(_ pitch: UInt8) -> Int64? {
        first.first { $0.1[1] == pitch }.map { HostClock.frames(from: host, to: $0.0, rate: rate) }
    }
    #expect(abs((offset(60) ?? -1) - 100) <= 1, "due 100 frames in: stamped 100 frames in")
    #expect(first.first { $0.1[1] == 64 }?.0 == 0, "a past due time goes out at once (stamp 0)")
    #expect(first.first { $0.1[1] == 65 }?.0 == 0, "no due time goes out at once (stamp 0)")
    render(engine, host: later(512))
    try await wait(for: sink, count: 4)
    let second = sink.received.first { $0.1[1] == 62 }
    #expect(abs((second.map { HostClock.frames(from: host, to: $0.0, rate: rate) } ?? -1) - 600) <= 1, "stamped 600 frames in, 88 into the second block")
}
