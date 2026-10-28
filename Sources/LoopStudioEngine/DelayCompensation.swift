import Foundation

/// A plain delay in frames for a stereo signal. Used on the connections of the mix graph, so that
/// sounds which went through plugins with latency line up with the sounds that did not.
final class DelayLine {
    let delay: Int
    private let size: Int
    private var left: [Float], right: [Float]
    private var position = 0
    let outLeft: UnsafeMutablePointer<Float>
    let outRight: UnsafeMutablePointer<Float>

    init(delay: Int, maxBlock: Int) {
        self.delay = delay
        size = delay + maxBlock
        left = [Float](repeating: 0, count: size)
        right = [Float](repeating: 0, count: size)
        outLeft = .allocate(capacity: maxBlock); outLeft.initialize(repeating: 0, count: maxBlock)
        outRight = .allocate(capacity: maxBlock); outRight.initialize(repeating: 0, count: maxBlock)
    }

    deinit { outLeft.deallocate(); outRight.deallocate() }

    func reset() {
        for i in 0..<size { left[i] = 0; right[i] = 0 }
        position = 0
    }

    /// Writes the block in, and fills `outLeft` and `outRight` with the same signal `delay` frames later.
    func process(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, frames: Int) {
        for k in 0..<frames {
            left[position] = l[k]; right[position] = r[k]
            var read = position - delay
            if read < 0 { read += size }
            outLeft[k] = left[read]; outRight[k] = right[read]
            position += 1
            if position == size { position = 0 }
        }
    }
}

extension RenderPlan {
    /// Plugin delay compensation. Every plugin with latency delays its own sound. This pass adds delay to the
    /// connections that did not go through it, so all paths into a node arrive together.
    ///
    /// A track that takes another track as input and also plays its own clips cannot be fully aligned:
    /// its own clips count as arriving at once.
    mutating func applyDelayCompensation() {
        let count = nodes.count
        var incoming = [[Int]](repeating: [], count: count)
        for (i, node) in nodes.enumerated() {
            if let o = node.output { incoming[o].append(i) }
            for s in node.sends { incoming[s.target].append(i) }
            for t in node.taps { incoming[t].append(i) }
        }
        // Nodes are sorted sources first, so one pass in order is enough.
        var arrival = [Int](repeating: 0, count: count)
        var arrivalIn = [Int](repeating: 0, count: count)
        for i in 0..<count {
            arrivalIn[i] = incoming[i].map { arrival[$0] }.max() ?? 0
            arrival[i] = arrivalIn[i] + nodes[i].latency
        }
        for i in 0..<count {
            if let o = nodes[i].output { nodes[i].outputDelay = max(0, arrivalIn[o] - arrival[i]) }
            for k in nodes[i].sends.indices { nodes[i].sends[k].delay = max(0, arrivalIn[nodes[i].sends[k].target] - arrival[i]) }
            nodes[i].tapDelays = nodes[i].taps.map { max(0, arrivalIn[$0] - arrival[i]) }
        }
        // The whole mix is late by the master's arrival time. Say so, so a caller can account for it.
        latencyFrames = arrival.last ?? 0
    }
}
