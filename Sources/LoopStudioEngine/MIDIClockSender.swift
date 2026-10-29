import CoreMIDI
import Foundation

/// Sends MIDI clock (24 pulses per quarter note), Start, Stop and the song position to one destination, so
/// hardware follows the transport.
///
/// Pulses are scheduled ahead with CoreMIDI time stamps, from the session clock: a timer every 50 ms
/// puts the next 200 ms of pulses on the wire, each stamped with the host time at which the engine plays
/// that frame. The sound card drives the clock, so the pulses stay in step with the audio.
public final class MIDIClockSender: @unchecked Sendable {
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private let lock = NSLock()
    private var destination: MIDIEndpointRef = 0
    private var bpm = 120.0
    private var sampleRate = 48_000.0
    private var running = false
    /// The session frame of the next pulse, and how many frames one pulse takes at the tempo.
    private var nextPulse = 0.0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "app.loopstudio.midiclock", qos: .userInteractive)
    /// The engine's clock: the session frame now, and the host time at which a session frame plays.
    private let nowFrame: @Sendable () -> Int64
    private let hostTime: @Sendable (Int64) -> UInt64

    public init(nowFrame: @escaping @Sendable () -> Int64, hostTime: @escaping @Sendable (Int64) -> UInt64) {
        self.nowFrame = nowFrame
        self.hostTime = hostTime
        MIDIClientCreateWithBlock("LoopStudio Clock" as CFString, &client) { _ in }
        MIDIOutputPortCreate(client, "Clock" as CFString, &port)
    }

    deinit {
        timer?.cancel()
        MIDIPortDispose(port)
        MIDIClientDispose(client)
    }

    /// The destination by its unique ID; `nil` turns the clock off.
    public func setDestination(uniqueID: Int32?) {
        var endpoint: MIDIEndpointRef = 0
        if let uid = uniqueID {
            var object = MIDIObjectRef(), type = MIDIObjectType.other
            if MIDIObjectFindByUniqueID(uid, &object, &type) == noErr, type == .destination || type == .externalDestination {
                endpoint = object
            }
        }
        lock.lock()
        let was = destination
        destination = endpoint
        lock.unlock()
        if was != 0, was != endpoint { send([0xFC], at: 0, to: was) }
    }

    public var isOn: Bool { lock.lock(); defer { lock.unlock() }; return destination != 0 }

    public func setTempo(bpm: Double, sampleRate: Double) {
        lock.lock()
        self.bpm = max(20, min(999, bpm)); self.sampleRate = sampleRate
        lock.unlock()
    }

    /// The transport starts at session frame `frame` (now, or after a count-in). `tick`: the song position
    /// there, in ticks of 960 per quarter, for the song position pointer.
    public func start(atFrame frame: Int64, tick: Int64) {
        lock.lock()
        guard destination != 0 else { lock.unlock(); return }
        running = true
        nextPulse = Double(frame)
        let to = destination
        lock.unlock()
        let at = hostTime(frame)
        // Song position in MIDI beats (sixteenths), then Start or Continue: Start from the song's start,
        // Continue from anywhere else, as the MIDI spec has it.
        let beats = max(0, min(16_383, tick / 240))
        if beats == 0 {
            send([0xFA], at: at, to: to)
        } else {
            send([0xF2, UInt8(beats & 0x7F), UInt8((beats >> 7) & 0x7F)], at: at > 0 ? at &- 1 : 0, to: to)
            send([0xFB], at: at, to: to)
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.pump() }
        timer?.cancel()
        timer = t
        t.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        lock.lock()
        let was = running, to = destination
        running = false
        lock.unlock()
        if was, to != 0 { send([0xFC], at: 0, to: to) }
    }

    /// Puts the pulses of the next 200 ms on the wire.
    private func pump() {
        lock.lock()
        guard running, destination != 0 else { lock.unlock(); return }
        let to = destination
        let perPulse = sampleRate * 60 / bpm / 24
        let horizon = Double(nowFrame()) + sampleRate * 0.2
        var pulses: [UInt64] = []
        // Far behind (the transport jumped, or the app was asleep): catch up from now, not with a burst.
        if nextPulse < horizon - sampleRate * 0.5 { nextPulse = Double(nowFrame()) }
        while nextPulse < horizon, pulses.count < 256 {
            pulses.append(hostTime(Int64(nextPulse.rounded())))
            nextPulse += perPulse
        }
        lock.unlock()
        for at in pulses { send([0xF8], at: at, to: to) }
    }

    private func send(_ bytes: [UInt8], at time: UInt64, to endpoint: MIDIEndpointRef) {
        guard endpoint != 0 else { return }
        var list = MIDIPacketList()
        let packet = MIDIPacketListInit(&list)
        _ = MIDIPacketListAdd(&list, MemoryLayout<MIDIPacketList>.size, packet, time, bytes.count, bytes)
        MIDISend(port, endpoint, &list)
    }
}
