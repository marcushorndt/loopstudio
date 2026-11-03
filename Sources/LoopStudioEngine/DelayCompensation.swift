import LoopStudioCore
import Foundation

/// A plain delay in frames for a stereo signal. Used on the connections of the mix graph, so that
/// sounds which went through plugins with latency line up with the sounds that did not.
final class DelayLine {
    let delay: Int
    let maxBlock: Int
    private let size: Int
    private var left: [Float], right: [Float]
    private var position = 0
    let outLeft: UnsafeMutablePointer<Float>
    let outRight: UnsafeMutablePointer<Float>

    init(delay: Int, maxBlock: Int) {
        self.delay = delay
        self.maxBlock = maxBlock
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
    /// How many frames the sound of `track` is late after its fader, from plugin latency on its way there.
    public func arrival(of track: TrackID) -> Int {
        trackOrder.firstIndex(of: track).map { nodes[$0].arrival } ?? 0
    }

    mutating func applyDelayCompensation() {
        let count = nodes.count
        var incoming = [[Int]](repeating: [], count: count)
        for (i, node) in nodes.enumerated() {
            if let o = node.output { incoming[o].append(i) }
            for s in node.sends { incoming[s.target].append(i) }
            for t in node.taps { incoming[t].append(i) }
            // A sidechain is an input too: the listener's other inputs wait for the source, and the
            // detector waits for them (below), so the ducking lands on the beat it listens to.
            for s in Self.sidechains(of: node.effects) where s != i { incoming[i].append(s) }
        }
        // Nodes are sorted sources first, so one pass in order is enough.
        var arrival = [Int](repeating: 0, count: count)
        var arrivalIn = [Int](repeating: 0, count: count)
        for i in 0..<count {
            arrivalIn[i] = incoming[i].map { arrival[$0] }.max() ?? 0
            arrival[i] = arrivalIn[i] + nodes[i].latency
        }
        let rate = sampleRate
        for i in 0..<count {
            nodes[i].arrival = arrival[i]
            if let o = nodes[i].output { nodes[i].outputDelay = max(0, arrivalIn[o] - arrival[i]) }
            for k in nodes[i].sends.indices { nodes[i].sends[k].delay = max(0, arrivalIn[nodes[i].sends[k].target] - arrival[i]) }
            nodes[i].tapDelays = nodes[i].taps.map { max(0, arrivalIn[$0] - arrival[i]) }
            // The node's own clips and notes play as late as its inputs arrive, so both line up inside it.
            // The signal at an effect is late by that plus the devices before it in the chain.
            nodes[i].inputShift = arrivalIn[i]
            nodes[i].outputShift = arrival[i]
            let instrumentLatency = nodes[i].instrument?.latencySamples ?? nodes[i].rackSynth?.latency ?? 0
            Self.align(&nodes[i].effects, inputArrival: arrivalIn[i] + instrumentLatency, shift: arrivalIn[i] + instrumentLatency, arrival: arrival, rate: rate)
        }
        // The whole mix is late by the master's arrival time. Say so, so a caller can account for it.
        latencyFrames = arrival.last ?? 0
    }

    /// The nodes the effects of a chain listen to, racks included.
    private static func sidechains(of effects: [EffectPlan]) -> [Int] {
        var result: [Int] = []
        for e in effects where !e.bypassed {
            if let s = e.sidechain { result.append(s) }
            if let rack = e.rack { for c in rack.chains { result += sidechains(of: c.effects) } }
        }
        return result
    }

    /// Sets `sidechainDelay` and `shift` on every effect of a chain whose input arrives `inputArrival` frames
    /// late against the song. `shift` is what the chain's first effect reads its automation late by: the
    /// node's shift for a track chain, 0 for the chain of a rack (the rack's slot is already shifted).
    private static func align(_ effects: inout [EffectPlan], inputArrival: Int, shift: Int, arrival: [Int], rate: Double) {
        var here = inputArrival, late = shift
        for k in effects.indices {
            if let s = effects[k].sidechain, s < arrival.count { effects[k].sidechainDelay = max(0, here - arrival[s]) }
            effects[k].shift = late
            if var rack = effects[k].rack {
                for c in rack.chains.indices {
                    let chainInstrument = rack.chains[c].instrument?.latencySamples ?? rack.chains[c].rackSynth?.latency ?? 0
                    align(&rack.chains[c].effects, inputArrival: here + chainInstrument, shift: chainInstrument, arrival: arrival, rate: rate)
                }
                effects[k].rack = rack
            }
            guard !effects[k].bypassed else { continue }
            let latency = effects[k].unit?.latencySamples ?? effects[k].rack?.latency
                ?? DSPEffect.latency(kind: effects[k].kind, params: effects[k].params, sampleRate: rate)
            here += latency
            late += latency
        }
    }
}
