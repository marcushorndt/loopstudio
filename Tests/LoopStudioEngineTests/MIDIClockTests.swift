import CoreMIDI
import Foundation
import Testing
@testable import LoopStudioEngine

/// A virtual destination that counts what arrives, by status byte.
private final class Sink: @unchecked Sendable {
    var client = MIDIClientRef()
    var endpoint = MIDIEndpointRef()
    final class Counts: @unchecked Sendable {
        let lock = NSLock()
        var map: [UInt8: Int] = [:]
        func add(_ status: UInt8) { lock.lock(); map[status, default: 0] += 1; lock.unlock() }
        func get(_ status: UInt8) -> Int { lock.lock(); defer { lock.unlock() }; return map[status] ?? 0 }
    }
    let counts = Counts()
    var uniqueID: Int32 { var id: Int32 = 0; MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id); return id }

    init?() {
        guard MIDIClientCreateWithBlock("LoopStudio Test" as CFString, &client, { _ in }) == noErr else { return nil }
        let status = MIDIDestinationCreateWithProtocol(client, "LoopStudio Clock Test" as CFString, ._1_0, &endpoint) { [counts] list, _ in
            let words = list.unsafeSequence()
            for packet in words {
                let data = packet.words()
                for word in data {
                    let status = UInt8((word >> 16) & 0xFF)
                    if status >= 0xF8 || status == 0xFA || status == 0xFB || status == 0xFC || status == 0xF2 {
                        counts.add(status)
                    }
                }
            }
        }
        guard status == noErr else { return nil }
    }

    deinit { MIDIEndpointDispose(endpoint); MIDIClientDispose(client) }
    func count(_ status: UInt8) -> Int { counts.get(status) }
}

@Test func theClockSendsStartPulsesAndStop() async throws {
    guard let sink = Sink() else { return } // no CoreMIDI server here
    let rate = 48_000.0
    let t0 = mach_absolute_time()
    // A clock that runs with the wall: frame f plays at t0 + f / rate.
    let sender = MIDIClockSender(
        nowFrame: { Int64(HostClock.seconds(fromTicks: Int64(mach_absolute_time() &- t0)) * rate) },
        hostTime: { frame in t0 &+ HostClock.ticks(fromSeconds: Double(frame) / rate) })
    sender.setDestination(uniqueID: sink.uniqueID)
    sender.setTempo(bpm: 120, sampleRate: rate)
    sender.start(atFrame: 0, tick: 0)
    try await Task.sleep(for: .milliseconds(600))
    sender.stop()
    try await Task.sleep(for: .milliseconds(100))
    // 120 BPM: 48 pulses a second. The pulses are stamped ahead, so some more may have been delivered.
    let pulses = sink.count(0xF8)
    #expect(pulses >= 20 && pulses <= 48, "\(pulses) pulses in 0.6 s")
    #expect(sink.count(0xFA) == 1, "Start")
    #expect(sink.count(0xFC) == 1, "Stop")

    // From the middle of the song: the position, then Continue.
    sender.start(atFrame: 0, tick: 3840 * 4)
    try await Task.sleep(for: .milliseconds(100))
    sender.stop()
    try await Task.sleep(for: .milliseconds(50))
    #expect(sink.count(0xF2) == 1 && sink.count(0xFB) == 1)
}
