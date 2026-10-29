import Foundation
import Synchronization

/// The last moments of the sound card input, for tracks that monitor "Ext. In".
///
/// The input callback writes every channel; the output callback reads what each monitoring track needs.
/// Both run on their own device clock, so the reader keeps a small lead: about one input block. When the
/// input runs ahead (the output stalled), the reader jumps forward; when it falls behind, the block is
/// silent and counted. Neither side allocates, locks, or waits.
///
/// The output renders at the project rate; an input at another rate is read with linear interpolation.
public final class InputMonitor: @unchecked Sendable {
    public let channels: Int
    public let sampleRate: Double
    let capacity: Int
    private let data: UnsafeMutablePointer<Float>
    /// Frames ever written, per channel.
    private let written = Atomic<Int>(0)
    /// Frames of the last input callback. Sets how much lead the reader keeps.
    private let inputBlock = Atomic<Int>(512)
    private let underruns = Atomic<Int>(0)
    /// Reader side only: where the current block reads from, in input frames.
    private var cursor = 0.0
    private var step = 1.0
    private var blockReady = false
    private var blockFrames = 0

    public init(channels: Int, sampleRate: Double, capacity: Int = 1 << 16) {
        self.channels = max(1, channels)
        self.sampleRate = sampleRate
        self.capacity = max(4096, capacity)
        data = .allocate(capacity: self.channels * self.capacity)
        data.initialize(repeating: 0, count: self.channels * self.capacity)
    }

    deinit { data.deallocate() }

    /// Blocks the output had to leave silent, because the input had not arrived.
    public var underrunCount: Int { underruns.load(ordering: .relaxed) }

    // MARK: Input side

    /// Copies `frames` of each channel. `source(c)` is the planar buffer of channel `c`.
    func write(frames: Int, source: (Int) -> UnsafePointer<Float>?) {
        guard frames > 0, frames <= capacity else { return }
        let w = written.load(ordering: .relaxed)
        for c in 0..<channels {
            let base = data + c * capacity, start = w % capacity
            let first = min(frames, capacity - start)
            guard let src = source(c) else { (base + start).update(repeating: 0, count: first); continue }
            (base + start).update(from: src, count: first)
            if frames > first { base.update(from: src + first, count: frames - first) }
        }
        inputBlock.store(frames, ordering: .relaxed)
        written.store(w + frames, ordering: .releasing)
    }

    // MARK: Output side

    /// Places the read cursor for a block of `frames` at `outputRate`. `false`: the input is not there yet,
    /// so `add` gives nothing for this block.
    func beginBlock(frames: Int, outputRate: Double) -> Bool {
        step = outputRate > 0 ? sampleRate / outputRate : 1
        blockFrames = frames
        let need = Int((Double(frames) * step).rounded(.up)) + 2
        let w = written.load(ordering: .acquiring)
        let lead = inputBlock.load(ordering: .relaxed) + need
        let available = w - Int(cursor)
        if available > lead * 3 || available < 0 {
            // Too far behind (or the first block ever): start again, one input block behind the writer.
            cursor = Double(max(0, w - lead))
        }
        blockReady = w - Int(cursor) >= need
        if !blockReady { underruns.add(1, ordering: .relaxed) }
        return blockReady
    }

    /// Adds channel `channel` of the current block to `out`.
    func add(channel: Int, into out: UnsafeMutablePointer<Float>, frames: Int) {
        guard blockReady, channel >= 0, channel < channels else { return }
        let base = data + channel * capacity
        if step == 1 {
            let start = Int(cursor)
            for i in 0..<frames { out[i] += base[(start + i) % capacity] }
            return
        }
        var pos = cursor
        for i in 0..<frames {
            let k = Int(pos), f = Float(pos - Double(k))
            out[i] += base[k % capacity] * (1 - f) + base[(k + 1) % capacity] * f
            pos += step
        }
    }

    /// The block is done: the next one reads on from here. A block that had no input does not move the cursor,
    /// so the sound that comes late is not thrown away.
    func endBlock() {
        if blockReady { cursor += Double(blockFrames) * step }
        blockReady = false
    }
}
