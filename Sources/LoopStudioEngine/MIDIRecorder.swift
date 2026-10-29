import Foundation
import LoopStudioCore

/// Collects live MIDI messages with the transport frame they arrived at. Safe from any thread.
public final class MIDIRecorder: @unchecked Sendable {
    public struct Event: Sendable { public var frame: Int64; public var status: UInt8; public var data1: UInt8; public var data2: UInt8 }

    private let lock = NSLock()
    private var events: [Event] = []
    private var active = false

    public init() {}

    public func begin() { lock.lock(); events = []; active = true; lock.unlock() }

    public func capture(frame: Int64, _ status: UInt8, _ data1: UInt8, _ data2: UInt8) {
        lock.lock(); defer { lock.unlock() }
        if active { events.append(Event(frame: frame, status: status, data1: data1, data2: data2)) }
    }

    /// What came in so far, while the take goes on.
    public func snapshot() -> [Event] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    /// Stops and returns what came in.
    public func end() -> [Event] {
        lock.lock(); defer { lock.unlock() }
        active = false
        return events
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
}
