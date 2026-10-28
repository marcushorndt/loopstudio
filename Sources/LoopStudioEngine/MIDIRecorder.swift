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

    /// Stops and returns what came in.
    public func end() -> [Event] {
        lock.lock(); defer { lock.unlock() }
        active = false
        return events
    }

    /// Turns note on and off messages into notes. `toTick` maps a frame to a tick relative to the clip start.
    /// A note still held at `endFrame` ends there. A note-on of a pitch that is still held closes the old note first.
    public static func notes(from events: [Event], endFrame: Int64, toTick: (Int64) -> Int64) -> [MIDINote] {
        var open: [UInt8: (frame: Int64, velocity: UInt8, channel: UInt8)] = [:]
        var result: [MIDINote] = []
        func close(_ pitch: UInt8, at frame: Int64) {
            guard let o = open.removeValue(forKey: pitch) else { return }
            let start = toTick(o.frame), end = max(start + 1, toTick(frame))
            result.append(MIDINote(tick: Tick(start), length: Tick(end - start), pitch: pitch, velocity: o.velocity, channel: o.channel))
        }
        for e in events {
            let kind = e.status & 0xF0, channel = e.status & 0x0F
            if kind == 0x90 && e.data2 > 0 {
                close(e.data1, at: e.frame)
                open[e.data1] = (e.frame, e.data2, channel)
            } else if kind == 0x80 || (kind == 0x90 && e.data2 == 0) {
                close(e.data1, at: e.frame)
            }
        }
        for pitch in Array(open.keys) { close(pitch, at: endFrame) }
        return result.sorted { ($0.tick, $0.pitch) < ($1.tick, $1.pitch) }
    }
}
