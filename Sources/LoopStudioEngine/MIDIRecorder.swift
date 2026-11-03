import Foundation
import LoopStudioCore

/// Collects live MIDI messages with the transport frame they arrived at, each for the track it played.
/// Two keyboards on two armed tracks make two takes, not one merged one. Safe from any thread.
public final class MIDIRecorder: @unchecked Sendable {
    public struct Event: Sendable {
        public var frame: Int64
        public var status: UInt8
        public var data1: UInt8
        public var data2: UInt8
        /// The track the message played. `nil` from before takes were per track (tests, old callers): every track.
        public var track: TrackID?
    }

    private let lock = NSLock()
    private var events: [Event] = []
    private var active = false

    public init() {}

    public func begin() { lock.lock(); events = []; active = true; lock.unlock() }

    /// One message for every track in `tracks`: the tracks whose input accepted it.
    public func capture(frame: Int64, tracks: [TrackID], _ status: UInt8, _ data1: UInt8, _ data2: UInt8) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        for track in tracks { events.append(Event(frame: frame, status: status, data1: data1, data2: data2, track: track)) }
    }

    /// A message for every track of the take.
    public func capture(frame: Int64, _ status: UInt8, _ data1: UInt8, _ data2: UInt8) {
        lock.lock(); defer { lock.unlock() }
        if active { events.append(Event(frame: frame, status: status, data1: data1, data2: data2, track: nil)) }
    }

    /// What came in so far, while the take goes on. With `track`, only what played that track.
    public func snapshot(track: TrackID? = nil) -> [Event] {
        lock.lock(); defer { lock.unlock() }
        return Self.events(events, of: track)
    }

    /// Stops and returns what came in.
    public func end() -> [Event] {
        lock.lock(); defer { lock.unlock() }
        active = false
        return events
    }

    /// The events of one track: its own, and the ones captured for every track.
    public static func events(_ events: [Event], of track: TrackID?) -> [Event] {
        guard let track else { return events }
        return events.filter { $0.track == nil || $0.track == track }
    }

    /// Turns note on and off messages into notes. `toTick` maps a frame to a tick relative to the clip start.
    /// A note still held at `endFrame` ends there. A note-on of a pitch that is still held on the same channel
    /// closes the old note first. Notes pair by channel and pitch, so two channels can hold the same pitch.
    public static func notes(from events: [Event], endFrame: Int64, toTick: (Int64) -> Int64) -> [MIDINote] {
        struct Key: Hashable { var channel: UInt8; var pitch: UInt8 }
        var open: [Key: (frame: Int64, velocity: UInt8)] = [:]
        var result: [MIDINote] = []
        func close(_ key: Key, at frame: Int64) {
            guard let o = open.removeValue(forKey: key) else { return }
            let start = toTick(o.frame), end = max(start + 1, toTick(frame))
            result.append(MIDINote(tick: Tick(start), length: Tick(end - start), pitch: key.pitch, velocity: o.velocity, channel: key.channel))
        }
        for e in events {
            let kind = e.status & 0xF0, key = Key(channel: e.status & 0x0F, pitch: e.data1)
            if kind == 0x90 && e.data2 > 0 {
                close(key, at: e.frame)
                open[key] = (e.frame, e.data2)
            } else if kind == 0x80 || (kind == 0x90 && e.data2 == 0) {
                close(key, at: e.frame)
            }
        }
        for key in Array(open.keys) { close(key, at: endFrame) }
        return result.sorted { ($0.tick, $0.pitch, $0.channel) < ($1.tick, $1.pitch, $1.channel) }
    }

    /// The controllers, pitch bends and pressures of a take, as clip controls. A message from before the take
    /// began (a negative tick) is kept at tick 0 when it is the last of its kind there: the pedal that was
    /// already down, the wheel that was already turned. A pedal still down at `endFrame` is released there.
    public static func controls(from events: [Event], endFrame: Int64, toTick: (Int64) -> Int64) -> [MIDIControlEvent] {
        struct Kind: Hashable { var status: UInt8; var number: UInt8? }
        var result: [MIDIControlEvent] = []
        var early: [Kind: MIDIControlEvent] = [:]
        var sustainDown: Set<UInt8> = []
        for e in events where MIDIControlEvent.isControl(status: e.status) {
            let tick = toTick(e.frame)
            let kind = Kind(status: e.status, number: e.status & 0xF0 == 0xB0 || e.status & 0xF0 == 0xA0 ? e.data1 : nil)
            let control = MIDIControlEvent(tick: Tick(max(0, tick)), status: e.status, data1: e.data1, data2: e.data2)
            if tick < 0 { early[kind] = control } else { result.append(control) }
            if e.status & 0xF0 == 0xB0, e.data1 == 64 {
                if e.data2 >= 64 { sustainDown.insert(e.status & 0x0F) } else { sustainDown.remove(e.status & 0x0F) }
            }
        }
        // An early message counts only when nothing of its kind came at tick 0 or later before the first later one;
        // simplest and right for a pedal: the first later message replaces it, so keep it only when it is first.
        for (kind, control) in early where !result.contains(where: { $0.status == kind.status && (kind.number == nil || $0.data1 == kind.number) && $0.tick == 0 }) {
            result.append(control)
        }
        for channel in sustainDown {
            result.append(MIDIControlEvent(tick: Tick(max(0, toTick(endFrame))), status: 0xB0 | channel, data1: 64, data2: 0))
        }
        return result.sorted { ($0.tick, $0.status, $0.data1) < ($1.tick, $1.status, $1.data1) }
    }
}
