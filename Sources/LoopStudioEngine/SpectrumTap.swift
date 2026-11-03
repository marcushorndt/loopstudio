import Foundation

import Synchronization

/// The last moment of a device's output, for a spectrum behind its curve. The audio thread writes the
/// mono sum into a ring; the display copies the newest samples. A sequence counter guards the copy: it is
/// odd while the audio thread writes, and a copy that saw it change starts again, so the display never
/// shows a block half old and half new.
public final class SpectrumTap: @unchecked Sendable {
    public static let size = 4096
    private let ring: UnsafeMutablePointer<Float>
    private var write = 0
    /// Even between writes, odd during one. Two steps per write.
    private let sequence = Atomic<Int>(0)
    /// Counts up with every write, so a display can skip a frame nothing new arrived for.
    public var generation: Int { sequence.load(ordering: .acquiring) / 2 }

    init() {
        ring = .allocate(capacity: Self.size)
        ring.initialize(repeating: 0, count: Self.size)
    }

    deinit { ring.deallocate() }

    @inline(__always) func write(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        sequence.wrappingAdd(1, ordering: .releasing)
        var w = write
        for i in 0..<frames {
            ring[w] = (l[i] + r[i]) * 0.5
            w += 1
            if w == Self.size { w = 0 }
        }
        write = w
        sequence.wrappingAdd(1, ordering: .releasing)
    }

    /// The newest `count` samples, oldest first. A copy torn by a write is made again, up to a few times;
    /// the audio thread is never held up for it.
    public func copyLatest(into out: UnsafeMutablePointer<Float>, count: Int) {
        let n = min(count, Self.size)
        for _ in 0..<4 {
            let before = sequence.load(ordering: .acquiring)
            if before & 1 == 1 { continue }
            var start = write - n
            if start < 0 { start += Self.size }
            for i in 0..<n {
                out[i] = ring[start]
                start += 1
                if start == Self.size { start = 0 }
            }
            if sequence.load(ordering: .acquiring) == before { return }
        }
    }
}
