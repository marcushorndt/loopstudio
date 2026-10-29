import CoreMIDI
import Foundation
import Testing
@testable import LoopStudioEngine

/// Host time of pulse `i` of a clock at `bpm`, counted from `t0`.
private func pulse(_ i: Int, bpm: Double = 120, from t0: UInt64 = 1_000_000) -> UInt64 {
    t0 &+ HostClock.ticks(fromSeconds: Double(i) * 60 / bpm / 24)
}

@Test func theFollowerMeasuresTheTempoOverTwoQuartersAndForgetsAGap() {
    var f = TempoFollower()
    var bpm: Double?
    for i in 0..<49 { bpm = f.pulse(at: pulse(i)) }
    #expect(bpm == 120)
    // 100 BPM from here: after two quarters the window holds only the new tempo.
    let t1 = pulse(48)
    for i in 1...48 { bpm = f.pulse(at: pulse(i, bpm: 100, from: t1)) }
    #expect(bpm == 100)
    // A gap of a second: the window starts again, with one pulse and no tempo yet.
    _ = f.pulse(at: pulse(48, bpm: 100, from: t1) &+ HostClock.ticks(fromSeconds: 1))
    #expect(f.bpm == nil && f.pulseCount == 1)
    #expect(f.pulse(at: pulse(48, bpm: 100, from: t1) &+ HostClock.ticks(fromSeconds: 1 + 1.0 / 48)) == 120, "the first pulse pair gives a tempo")
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [MIDIClockReceiver.Event] = []
    func add(_ e: MIDIClockReceiver.Event) { lock.lock(); list.append(e); lock.unlock() }
    var all: [MIDIClockReceiver.Event] { lock.lock(); defer { lock.unlock() }; return list }
}

@Test func theReceiverReportsStartBeatsThePositionContinueAndStop() {
    let r = MIDIClockReceiver(), got = Events()
    r.onEvent = { got.add($0) }
    r.handle(status: 0xFA, host: pulse(0))
    for i in 0..<49 { r.handle(status: 0xF8, host: pulse(i)) }
    // Song position bar 2 (16 sixteenths), then Continue and one more quarter.
    r.handle(status: 0xF2, data1: 16, data2: 0, host: pulse(49))
    r.handle(status: 0xFB, host: pulse(49))
    for i in 49..<74 { r.handle(status: 0xF8, host: pulse(i)) }
    r.handle(status: 0xFC, host: pulse(74))
    #expect(got.all == [
        .start(host: pulse(0)),
        .beat(tick: 960, bpm: 120, host: pulse(24)),
        .beat(tick: 1920, bpm: 120, host: pulse(48)),
        .position(sixteenths: 16, host: pulse(49)),
        .continue(host: pulse(49)),
        .beat(tick: 3840 + 960, bpm: 120, host: pulse(73)),
        .stop(host: pulse(74)),
    ])
    #expect(!r.isRunning && r.bpm == 120)
}

@Test func aClockWithoutAStartReportsOnlyItsTempo() {
    let r = MIDIClockReceiver(), got = Events()
    r.onEvent = { got.add($0) }
    for i in 0..<49 { r.handle(status: 0xF8, host: pulse(i, bpm: 90)) }
    #expect(got.all == [.beat(tick: nil, bpm: 90, host: pulse(24, bpm: 90)), .beat(tick: nil, bpm: 90, host: pulse(48, bpm: 90))])
}

@Test func theReceiverHearsAVirtualSource() async throws {
    var client = MIDIClientRef()
    guard MIDIClientCreateWithBlock("LoopStudio Clock Source Test" as CFString, &client, { _ in }) == noErr else { return }
    var source = MIDIEndpointRef()
    guard MIDISourceCreateWithProtocol(client, "LoopStudio Clock Source" as CFString, ._1_0, &source) == noErr else { return }
    defer { MIDIEndpointDispose(source); MIDIClientDispose(client) }
    var uid: Int32 = 0
    MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uid)

    let r = MIDIClockReceiver(), got = Events()
    r.onEvent = { got.add($0) }
    r.setSource(uniqueID: uid)
    #expect(r.isOn)
    try await Task.sleep(for: .milliseconds(100))

    func send(_ word: UInt32, at time: UInt64) {
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, time, 1, [word])
        MIDIReceivedEventList(source, &list)
    }
    let t0 = mach_absolute_time()
    send(0x10FA_0000, at: t0)
    for i in 0..<25 { send(0x10F8_0000, at: pulse(i, from: t0)) }
    send(0x10FC_0000, at: pulse(25, from: t0))
    var waited = 0
    while got.all.count < 3, waited < 100 { try await Task.sleep(for: .milliseconds(10)); waited += 1 }
    let events = got.all
    #expect(events.first == .start(host: t0))
    #expect(events.contains { if case .beat(let tick, let bpm, _) = $0 { return tick == 960 && bpm == 120 } else { return false } }, "\(events)")
    #expect(events.last == .stop(host: pulse(25, from: t0)))
}
