import Foundation
import Synchronization

/// A single-producer, single-consumer ring of one or two planar channels.
///
/// The capture callback writes; a writer thread reads. Both sides only copy into memory allocated up
/// front and move one atomic counter, so the callback never allocates, locks, or waits for the disk.
/// A buffer that does not fit is dropped whole and counted. The reader puts silence in its place,
/// so the audio after a drop stays at its right time.
final class CaptureRing: @unchecked Sendable {
    let channels: Int
    let capacity: Int
    private let data: UnsafeMutablePointer<Float>
    /// Frames ever written and ever read. Their difference is what the ring holds.
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    private let droppedFrames = Atomic<Int>(0)
    private let firstHostTime = Atomic<UInt64>(0)
    private let firstFrame = Atomic<Int64>(-1)
    /// Gaps: where in the stream frames were dropped, and how many. An entry is fixed once published.
    private static let gapSlots = 256
    private let gapAt: UnsafeMutablePointer<Int>, gapLength: UnsafeMutablePointer<Int>
    private let gapsWritten = Atomic<Int>(0), gapsRead = Atomic<Int>(0)
    /// Producer only: dropped frames not yet published as a gap.
    private var unpublishedGap = 0
    /// Consumer only: silence already given for the current gap.
    private var gapDone = 0

    init(channels: Int, capacity: Int) {
        self.channels = max(1, min(2, channels))
        self.capacity = max(1, capacity)
        data = .allocate(capacity: self.channels * self.capacity)
        data.initialize(repeating: 0, count: self.channels * self.capacity)
        gapAt = .allocate(capacity: Self.gapSlots); gapAt.initialize(repeating: 0, count: Self.gapSlots)
        gapLength = .allocate(capacity: Self.gapSlots); gapLength.initialize(repeating: 0, count: Self.gapSlots)
    }

    deinit { data.deallocate(); gapAt.deallocate(); gapLength.deallocate() }

    var dropped: Int { droppedFrames.load(ordering: .relaxed) }
    /// Host time of the first captured buffer, 0 before it.
    var startHostTime: UInt64 { firstHostTime.load(ordering: .relaxed) }

    /// Timeline frame of the first buffer, when the producer knows it (the renderer does).
    var startFrame: Int64? { let f = firstFrame.load(ordering: .relaxed); return f < 0 ? nil : f }

    /// Producer side: keeps the timeline frame of the first buffer only.
    func noteStart(frame: Int64) {
        _ = firstFrame.compareExchange(expected: -1, desired: max(0, frame), ordering: .relaxed)
    }

    /// Producer side: keeps the host time of the first buffer only.
    func noteStart(hostTime: UInt64) {
        _ = firstHostTime.compareExchange(expected: 0, desired: max(1, hostTime), ordering: .relaxed)
    }

    /// Producer side. Returns false when the frames did not fit and were dropped.
    @discardableResult
    func write(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>?, frames: Int) -> Bool {
        let w = written.load(ordering: .relaxed), r = read.load(ordering: .acquiring)
        guard frames <= capacity - (w - r) else {
            droppedFrames.add(frames, ordering: .relaxed)
            unpublishedGap += frames
            return false
        }
        if unpublishedGap > 0 {
            // The gap goes in before the frames that follow it. A full gap list keeps it for the next write.
            let g = gapsWritten.load(ordering: .relaxed)
            if g - gapsRead.load(ordering: .acquiring) < Self.gapSlots {
                gapAt[g % Self.gapSlots] = w; gapLength[g % Self.gapSlots] = unpublishedGap
                gapsWritten.store(g + 1, ordering: .releasing)
                unpublishedGap = 0
            }
        }
        copy(from: left, channel: 0, at: w, frames: frames)
        if channels == 2 { copy(from: right ?? left, channel: 1, at: w, frames: frames) }
        written.store(w + frames, ordering: .releasing)
        return true
    }

    /// Consumer side. Copies up to `max` frames into `left` (and `right` for two channels).
    func read(into left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>?, max: Int) -> Int {
        let r = read.load(ordering: .relaxed), w = written.load(ordering: .acquiring)
        var n = min(max, w - r)
        let g = gapsRead.load(ordering: .relaxed)
        if g < gapsWritten.load(ordering: .acquiring) {
            let at = gapAt[g % Self.gapSlots]
            if at == r {
                // Silence for the dropped frames.
                let count = min(max, gapLength[g % Self.gapSlots] - gapDone)
                left.update(repeating: 0, count: count)
                if channels == 2, let right { right.update(repeating: 0, count: count) }
                gapDone += count
                if gapDone >= gapLength[g % Self.gapSlots] { gapDone = 0; gapsRead.store(g + 1, ordering: .releasing) }
                return count
            }
            n = min(n, at - r)
        }
        guard n > 0 else { return 0 }
        paste(into: left, channel: 0, at: r, frames: n)
        if channels == 2, let right { paste(into: right, channel: 1, at: r, frames: n) }
        read.store(r + n, ordering: .releasing)
        return n
    }

    private func copy(from src: UnsafePointer<Float>, channel: Int, at position: Int, frames: Int) {
        let base = data + channel * capacity, start = position % capacity
        let first = min(frames, capacity - start)
        (base + start).update(from: src, count: first)
        if frames > first { base.update(from: src + first, count: frames - first) }
    }

    private func paste(into dst: UnsafeMutablePointer<Float>, channel: Int, at position: Int, frames: Int) {
        let base = data + channel * capacity, start = position % capacity
        let first = min(frames, capacity - start)
        dst.update(from: base + start, count: first)
        if frames > first { (dst + first).update(from: base, count: frames - first) }
    }
}
