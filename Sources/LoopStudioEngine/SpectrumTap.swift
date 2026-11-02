import Foundation

/// The last moment of a device's output, for a spectrum behind its curve. The audio thread writes the
/// mono sum into a ring; the display copies the newest samples. A torn copy only blurs one frame.
public final class SpectrumTap: @unchecked Sendable {
    public static let size = 4096
    private let ring: UnsafeMutablePointer<Float>
    private var write = 0
    /// Counts up with every write, so a display can skip a frame nothing new arrived for.
    public private(set) var generation = 0

    init() {
        ring = .allocate(capacity: Self.size)
        ring.initialize(repeating: 0, count: Self.size)
    }

    deinit { ring.deallocate() }

    @inline(__always) func write(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        var w = write
        for i in 0..<frames {
            ring[w] = (l[i] + r[i]) * 0.5
            w += 1
            if w == Self.size { w = 0 }
        }
        write = w
        generation &+= 1
    }

    /// The newest `count` samples, oldest first.
    public func copyLatest(into out: UnsafeMutablePointer<Float>, count: Int) {
        let n = min(count, Self.size)
        var start = write - n
        if start < 0 { start += Self.size }
        for i in 0..<n {
            out[i] = ring[start]
            start += 1
            if start == Self.size { start = 0 }
        }
    }
}
