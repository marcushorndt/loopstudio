import CoreMIDI
import Foundation

/// The tempo of an incoming MIDI clock, from the time stamps of its pulses (24 per quarter note).
///
/// The estimate is the mean over a window of two quarter notes: long enough to smooth USB jitter of a
/// millisecond per pulse to a few hundredths of a beat per minute, short enough to follow a tempo ramp.
/// A gap of three pulse lengths or more (the clock stopped and started again) empties the window.
public struct TempoFollower: Sendable {
    public static let window = 48
    private var times: [UInt64] = []

    public init() {}

    public var pulseCount: Int { times.count }

    /// Adds a pulse and returns the tempo, when at least two pulses are in the window.
    public mutating func pulse(at host: UInt64) -> Double? {
        if let last = times.last {
            if host <= last { return bpm }
            if times.count >= 2 {
                let span = HostClock.seconds(fromTicks: Int64(last &- times[0]))
                let mean = span / Double(times.count - 1)
                if HostClock.seconds(fromTicks: Int64(host &- last)) > mean * 3 { times.removeAll(keepingCapacity: true) }
            }
        }
        times.append(host)
        if times.count > Self.window + 1 { times.removeFirst(times.count - Self.window - 1) }
        return bpm
    }

    public mutating func reset() { times.removeAll(keepingCapacity: true) }

    /// Beats per minute over the window, rounded to a hundredth. `nil` with fewer than two pulses.
    public var bpm: Double? {
        guard times.count >= 2, let first = times.first, let last = times.last, last > first else { return nil }
        let seconds = HostClock.seconds(fromTicks: Int64(last &- first))
        let quarters = Double(times.count - 1) / 24
        let raw = quarters * 60 / seconds
        guard raw.isFinite, raw > 0 else { return nil }
        return (raw * 100).rounded() / 100
    }
}

/// Follows a MIDI clock from one source: Start, Continue, Stop, the song position and the pulses.
///
/// Events are reported on a CoreMIDI thread, with the host time stamp of the message. The transport
/// messages come as they arrive. The pulses are summed up: every quarter note (24 pulses) one `beat`
/// event names the song position the clock has reached, and the tempo measured so far. A clock that
/// runs without a Start (the device was already playing) reports only its tempo, with no position.
public final class MIDIClockReceiver: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        /// Start: the song position is 0, and the transport runs from the next pulse.
        case start(host: UInt64)
        /// Continue from the position set before.
        case `continue`(host: UInt64)
        case stop(host: UInt64)
        /// Song position in MIDI beats (sixteenth notes).
        case position(sixteenths: Int, host: UInt64)
        /// A quarter note passed. `tick` is the song position (960 per quarter), `nil` when the clock
        /// runs without a Start. `bpm` is the measured tempo, `nil` for the first pulses.
        case beat(tick: Int64?, bpm: Double?, host: UInt64)
    }

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private let lock = NSLock()
    private var source: MIDIEndpointRef = 0
    private var sourceUID: Int32?
    private var follower = TempoFollower()
    /// Pulses since the Start or the song position, and the position those count from.
    private var running = false
    private var pulses = 0
    private var originSixteenths = 0
    private var _onEvent: (@Sendable (Event) -> Void)?

    /// Called on a CoreMIDI thread.
    public var onEvent: (@Sendable (Event) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onEvent }
        set { lock.lock(); _onEvent = newValue; lock.unlock() }
    }

    public init() {
        MIDIClientCreateWithBlock("LoopStudio Clock In" as CFString, &client) { [weak self] notification in
            let id = notification.pointee.messageID
            if id == .msgObjectAdded || id == .msgSetupChanged { self?.reconnect() }
        }
        MIDIInputPortCreateWithProtocol(client, "Clock" as CFString, ._1_0, &port) { [weak self] list, _ in
            self?.receive(list)
        }
    }

    deinit {
        if source != 0 { MIDIPortDisconnectSource(port, source) }
        MIDIPortDispose(port)
        MIDIClientDispose(client)
    }

    /// Listens to the source with this unique ID; `nil` stops listening.
    public func setSource(uniqueID: Int32?) {
        lock.lock()
        sourceUID = uniqueID
        lock.unlock()
        reconnect()
    }

    public var isOn: Bool { lock.lock(); defer { lock.unlock() }; return source != 0 }
    /// True between a Start (or Continue) and a Stop.
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    public var bpm: Double? { lock.lock(); defer { lock.unlock() }; return follower.bpm }

    private func reconnect() {
        lock.lock()
        let uid = sourceUID
        let old = source
        var new: MIDIEndpointRef = 0
        if let uid {
            var object = MIDIObjectRef(), type = MIDIObjectType.other
            if MIDIObjectFindByUniqueID(uid, &object, &type) == noErr, type == .source || type == .externalSource { new = object }
        }
        source = new
        if new != old { follower.reset(); running = false; pulses = 0 }
        lock.unlock()
        if old != 0, old != new { MIDIPortDisconnectSource(port, old) }
        if new != 0, new != old { MIDIPortConnectSource(port, new, nil) }
    }

    private func receive(_ list: UnsafePointer<MIDIEventList>) {
        for packet in list.unsafeSequence() {
            let time = packet.pointee.timeStamp == 0 ? mach_absolute_time() : packet.pointee.timeStamp
            for word in packet.words() {
                // Universal MIDI Packet, message type 1: system common and real time.
                guard word >> 28 == 1 else { continue }
                let status = UInt8((word >> 16) & 0xFF)
                handle(status: status, data1: UInt8((word >> 8) & 0x7F), data2: UInt8(word & 0x7F), host: time)
            }
        }
    }

    /// One system message. Also the entry point for tests.
    func handle(status: UInt8, data1: UInt8 = 0, data2: UInt8 = 0, host: UInt64) {
        var event: Event?
        lock.lock()
        switch status {
        case 0xF8:
            let bpm = follower.pulse(at: host)
            if running {
                pulses += 1
                // The first pulse after Start is the downbeat; every 24th pulse after it is a quarter note.
                if pulses > 1, (pulses - 1) % 24 == 0 {
                    event = .beat(tick: Int64(originSixteenths) * 240 + Int64(pulses - 1) * 40, bpm: bpm, host: host)
                }
            } else if follower.pulseCount > 1, (follower.pulseCount - 1) % 24 == 0 {
                event = .beat(tick: nil, bpm: bpm, host: host)
            }
        case 0xFA:
            running = true; pulses = 0; originSixteenths = 0
            event = .start(host: host)
        case 0xFB:
            running = true; pulses = 0
            event = .continue(host: host)
        case 0xFC:
            running = false
            event = .stop(host: host)
        case 0xF2:
            originSixteenths = Int(data1) | Int(data2) << 7
            pulses = 0
            event = .position(sixteenths: originSixteenths, host: host)
        default: break
        }
        let handler = _onEvent
        lock.unlock()
        if let event { handler?(event) }
    }
}
