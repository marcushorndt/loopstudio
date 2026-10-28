import CoreMIDI
import Foundation

/// Listens to every MIDI source and hands each channel message to `handler`.
/// New devices that appear later are connected too.
public final class MIDIInputMonitor: @unchecked Sendable {
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private let lock = NSLock()
    private var _handler: (@Sendable (UInt8, UInt8, UInt8) -> Void)?

    /// Called on a CoreMIDI thread with status, data1, data2.
    public var handler: (@Sendable (UInt8, UInt8, UInt8) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }

    public private(set) var sourceCount = 0

    public init() {
        MIDIClientCreateWithBlock("LoopStudio" as CFString, &client) { [weak self] notification in
            let id = notification.pointee.messageID
            if id == .msgObjectAdded || id == .msgObjectRemoved || id == .msgSetupChanged { self?.connectAll() }
        }
        MIDIInputPortCreateWithBlock(client, "Input" as CFString, &port) { [weak self] list, _ in
            self?.receive(list)
        }
        connectAll()
    }

    deinit {
        MIDIPortDispose(port)
        MIDIClientDispose(client)
    }

    private func connectAll() {
        let n = MIDIGetNumberOfSources()
        sourceCount = n
        for i in 0..<n { MIDIPortConnectSource(port, MIDIGetSource(i), nil) }
    }

    private func receive(_ list: UnsafePointer<MIDIPacketList>) {
        guard let handler else { return }
        var packet = UnsafeRawPointer(list).advanced(by: MemoryLayout<UInt32>.size).assumingMemoryBound(to: MIDIPacket.self)
        for _ in 0..<list.pointee.numPackets {
            let length = Int(packet.pointee.length)
            withUnsafeBytes(of: packet.pointee.data) { raw in
                var i = 0
                while i < min(length, raw.count) {
                    let status = raw[i]
                    guard status >= 0x80 else { i += 1; continue }       // running status is not handled
                    if status >= 0xF0 { i += 1; continue }              // system messages are ignored
                    let size = (status & 0xF0 == 0xC0 || status & 0xF0 == 0xD0) ? 2 : 3
                    guard i + size <= length else { break }
                    handler(status, raw[i + 1], size == 3 ? raw[i + 2] : 0)
                    i += size
                }
            }
            packet = UnsafePointer(MIDIPacketNext(packet))
        }
    }
}
