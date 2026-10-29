import CoreMIDI
import Foundation
import Synchronization

/// Where a track's notes go on the wire: one CoreMIDI destination, with the channel and the time shift.
public struct MIDIOutTarget: Sendable, Equatable {
    public var endpoint: MIDIEndpointRef
    /// 0 to 15 puts every note on that channel; -1 keeps the channel of the note.
    public var channel: Int8
    /// Added to the time stamp of every message. Negative sends earlier.
    public var latencyFrames: Int64

    public init(endpoint: MIDIEndpointRef, channel: Int8 = -1, latencyFrames: Int64 = 0) {
        self.endpoint = endpoint
        self.channel = channel
        self.latencyFrames = latencyFrames
    }

    /// Finds the destination by its unique ID; `nil` when it is not online.
    public static func resolve(uniqueID: Int32, channel: UInt8?, latencyFrames: Int64 = 0) -> MIDIOutTarget? {
        var object = MIDIObjectRef(), type = MIDIObjectType.other
        guard MIDIObjectFindByUniqueID(uniqueID, &object, &type) == noErr,
              type == .destination || type == .externalDestination, object != 0 else { return nil }
        return MIDIOutTarget(endpoint: object, channel: channel.map { Int8(min($0, 15)) } ?? -1, latencyFrames: latencyFrames)
    }
}

/// MIDI messages from the audio thread to hardware destinations.
///
/// The renderer pushes each note with the session frame at which it plays. A sender thread takes the
/// messages, stamps them with the host time of that frame (the engine knows it from the last block) and
/// hands them to CoreMIDI, which delivers them on time. The ring is fixed in size; the audio thread only
/// copies into it and moves one counter, so it never allocates or waits. The audio thread wakes the
/// sender once per callback with a semaphore. A message that does not fit is dropped and counted.
public final class MIDIOutQueue: @unchecked Sendable {
    /// `frame == Int64.min` means "now" (a live note).
    struct Entry {
        var endpoint: MIDIEndpointRef
        var frame: Int64
        var status: UInt8, data1: UInt8, data2: UInt8
    }
    public static let now = Int64.min

    private let capacity: Int
    private let entries: UnsafeMutablePointer<Entry>
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    private let droppedCount = Atomic<Int>(0)
    private let sentCount = Atomic<Int>(0)
    private let pendingWake = Atomic<Bool>(false)
    private let wake = DispatchSemaphore(value: 0)
    private let stopped = Atomic<Bool>(false)
    private var thread: Thread?
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    /// Host time at which a session frame plays. The engine sets it; before that, messages go out at once.
    private let clockLock = NSLock()
    private var _hostTime: (@Sendable (Int64) -> UInt64)?
    public var hostTime: (@Sendable (Int64) -> UInt64)? {
        get { clockLock.lock(); defer { clockLock.unlock() }; return _hostTime }
        set { clockLock.lock(); _hostTime = newValue; clockLock.unlock() }
    }
    /// What puts the bytes on the wire. Tests replace it.
    private let send: @Sendable (MIDIEndpointRef, UInt64, UnsafeBufferPointer<UInt8>) -> Void

    public init(capacity: Int = 4096, send: (@Sendable (MIDIEndpointRef, UInt64, UnsafeBufferPointer<UInt8>) -> Void)? = nil) {
        self.capacity = max(16, capacity)
        entries = .allocate(capacity: self.capacity)
        entries.initialize(repeating: Entry(endpoint: 0, frame: 0, status: 0, data1: 0, data2: 0), count: self.capacity)
        var client = MIDIClientRef(), port = MIDIPortRef()
        if send == nil {
            MIDIClientCreateWithBlock("LoopStudio MIDI Out" as CFString, &client) { _ in }
            MIDIOutputPortCreate(client, "Notes" as CFString, &port)
        }
        self.client = client
        self.port = port
        let outPort = port
        self.send = send ?? { endpoint, time, bytes in
            var list = MIDIPacketList()
            let packet = MIDIPacketListInit(&list)
            _ = MIDIPacketListAdd(&list, MemoryLayout<MIDIPacketList>.size, packet, time, bytes.count, bytes.baseAddress!)
            MIDISend(outPort, endpoint, &list)
        }
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "app.loopstudio.midi-out"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    deinit {
        stopped.store(true, ordering: .releasing)
        wake.signal()
        if port != 0 { MIDIPortDispose(port) }
        if client != 0 { MIDIClientDispose(client) }
        entries.deallocate()
    }

    /// Messages that did not fit in the ring.
    public var dropped: Int { droppedCount.load(ordering: .relaxed) }
    /// Messages handed to CoreMIDI so far.
    public var sent: Int { sentCount.load(ordering: .relaxed) }

    /// Audio thread. `frame` is the session frame of the message, or `MIDIOutQueue.now`.
    /// The target's channel and latency are applied here.
    @inline(__always)
    func push(_ target: MIDIOutTarget, frame: Int64, _ status: UInt8, _ data1: UInt8, _ data2: UInt8) {
        let w = written.load(ordering: .relaxed), r = read.load(ordering: .acquiring)
        guard w - r < capacity else { droppedCount.wrappingAdd(1, ordering: .relaxed); return }
        var s = status
        if target.channel >= 0, status < 0xF0 { s = (status & 0xF0) | UInt8(target.channel) }
        let f = frame == Self.now ? frame : frame + target.latencyFrames
        entries[w % capacity] = Entry(endpoint: target.endpoint, frame: f, status: s, data1: data1, data2: data2)
        written.store(w + 1, ordering: .releasing)
        pendingWake.store(true, ordering: .relaxed)
    }

    /// Audio thread, once per callback: wakes the sender when something was pushed.
    func flush() {
        if pendingWake.exchange(false, ordering: .relaxed) { wake.signal() }
    }

    /// Sender thread: takes everything in the ring and puts it on the wire with its time stamp.
    @discardableResult
    func drain() -> Int {
        let clock = hostTime
        var bytes: [UInt8] = [0, 0, 0]
        var count = 0
        while true {
            let r = read.load(ordering: .relaxed), w = written.load(ordering: .acquiring)
            guard r < w else { break }
            let e = entries[r % capacity]
            read.store(r + 1, ordering: .releasing)
            let time: UInt64 = e.frame == Self.now ? 0 : (clock?(e.frame) ?? 0)
            bytes[0] = e.status; bytes[1] = e.data1; bytes[2] = e.data2
            let kind = e.status & 0xF0
            let length = (kind == 0xC0 || kind == 0xD0) ? 2 : 3
            bytes.withUnsafeBufferPointer { send(e.endpoint, time, UnsafeBufferPointer(rebasing: $0[0..<length])) }
            count += 1
        }
        if count > 0 { sentCount.wrappingAdd(count, ordering: .relaxed) }
        return count
    }

    private func run() {
        while !stopped.load(ordering: .acquiring) {
            wake.wait()
            if stopped.load(ordering: .acquiring) { return }
            drain()
        }
    }
}
