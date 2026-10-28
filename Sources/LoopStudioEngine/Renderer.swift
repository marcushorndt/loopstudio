import AVFoundation
import Foundation
import LoopStudioCore

/// Turns a `RenderPlan` into audio, block by block.
///
/// Every output sample depends only on its absolute frame position, never on block boundaries.
/// So rendering in 64-frame or 4096-frame blocks, live or offline, gives bit-identical results.
/// `process` uses only memory allocated in `init`: no allocation, no locks, no Swift arrays of references.
public final class Renderer {
    public let plan: RenderPlan
    public let maxBlock: Int
    private let nodes: UnsafeMutablePointer<NodePlan>
    private let nodeCount: Int
    private let buffers: UnsafeMutablePointer<Float> // per node: left block, right block
    private let peaks: UnsafeMutablePointer<Float>   // per node: largest sample since the last `takePeak`

    private final class Slot {
        let effect: DSPEffect?
        let unit: AudioUnitEffect?
        let bypassed: Bool
        let auto: [(key: String, lane: AutoLane)]
        var live: [String: Double]
        init(effect: DSPEffect?, unit: AudioUnitEffect?, bypassed: Bool, auto: [String: AutoLane], params: [String: Double]) {
            self.effect = effect; self.unit = unit; self.bypassed = bypassed
            self.auto = auto.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
            self.live = params
        }
    }
    private let scratchIn: UnsafeMutablePointer<Float>
    private let scratchOut: UnsafeMutablePointer<Float>
    private let inPointers: UnsafeMutablePointer<UnsafePointer<Float>>
    private let outPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let chains: [[Slot]]
    private let outputLines: [DelayLine?]
    private let sendLines: [[DelayLine?]]
    private let tapLines: [[DelayLine?]]
    private let instances: [DeviceID: DSPEffect]

    /// With `reusing`, effects that exist in both plans keep their memory (reverb tails, filter state),
    /// so changing a knob does not cut the sound.
    public init(plan: RenderPlan, maxBlock: Int = 4096, reusing old: Renderer? = nil) {
        var made: [DeviceID: DSPEffect] = [:]
        var built: [[Slot]] = []
        for node in plan.nodes {
            var chain: [Slot] = []
            for e in node.effects {
                if let unit = e.unit { chain.append(Slot(effect: nil, unit: unit, bypassed: e.bypassed, auto: [:], params: [:])); continue }
                let effect: DSPEffect
                if let kept = old?.instances[e.device], kept.spec.id == e.kind, kept.sampleRate == plan.sampleRate {
                    effect = kept
                } else if let new = DSPEffect.make(e.kind, sampleRate: plan.sampleRate) {
                    effect = new
                } else { continue }
                effect.configure(e.params)
                made[e.device] = effect
                chain.append(Slot(effect: effect, unit: nil, bypassed: e.bypassed, auto: e.auto, params: e.params))
            }
            built.append(chain)
        }
        chains = built
        func line(_ d: Int) -> DelayLine? { d > 0 ? DelayLine(delay: d, maxBlock: maxBlock) : nil }
        outputLines = plan.nodes.map { line($0.outputDelay) }
        sendLines = plan.nodes.map { $0.sends.map { line($0.delay) } }
        tapLines = plan.nodes.map { $0.tapDelays.map(line) }
        instances = made
        self.plan = plan
        self.maxBlock = maxBlock
        nodeCount = plan.nodes.count
        nodes = .allocate(capacity: nodeCount)
        nodes.initialize(from: plan.nodes, count: nodeCount)
        buffers = .allocate(capacity: nodeCount * 2 * maxBlock)
        buffers.initialize(repeating: 0, count: nodeCount * 2 * maxBlock)
        scratchIn = .allocate(capacity: 2 * maxBlock); scratchIn.initialize(repeating: 0, count: 2 * maxBlock)
        scratchOut = .allocate(capacity: 2 * maxBlock); scratchOut.initialize(repeating: 0, count: 2 * maxBlock)
        inPointers = .allocate(capacity: 2)
        inPointers.initialize(to: UnsafePointer(scratchIn))
        (inPointers + 1).initialize(to: UnsafePointer(scratchIn + maxBlock))
        outPointers = .allocate(capacity: 2)
        outPointers.initialize(to: scratchOut)
        (outPointers + 1).initialize(to: scratchOut + maxBlock)
        peaks = .allocate(capacity: max(1, nodeCount))
        peaks.initialize(repeating: 0, count: max(1, nodeCount))
    }

    deinit {
        nodes.deinitialize(count: nodeCount)
        nodes.deallocate()
        buffers.deallocate()
        peaks.deallocate()
        scratchIn.deallocate(); scratchOut.deallocate(); inPointers.deallocate(); outPointers.deallocate()
    }

    var instancesForTesting: [DeviceID: DSPEffect] { instances }

    /// Clears every effect's memory (delay lines, reverb tails). Called after a stop or a jump.
    public func reset() {
        for effect in instances.values { effect.reset() }
        for line in outputLines { line?.reset() }
        for lines in sendLines { for line in lines { line?.reset() } }
        for lines in tapLines { for line in lines { line?.reset() } }
        silenceNotes()
    }

    /// Sends a MIDI message to the instrument of a node right now (a note you play, not one from a clip).
    public func sendLive(node: Int, _ status: UInt8, _ data1: UInt8, _ data2: UInt8) {
        guard node >= 0, node < nodeCount else { return }
        nodes[node].instrument?.sendMIDI(status, data1, data2)
    }

    /// Releases every note of every hosted instrument. Called on stop, on a jump and when the loop wraps.
    public func silenceNotes() {
        for i in 0..<nodeCount { nodes[i].instrument?.silenceNotes() }
    }

    private func run(_ unit: AudioUnitEffect, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        scratchIn.update(from: l, count: frames)
        (scratchIn + maxBlock).update(from: r, count: frames)
        guard unit.process(frames: frames, input: inPointers, output: outPointers) == noErr else { return } // keep the dry signal
        l.update(from: scratchOut, count: frames)
        r.update(from: scratchOut + maxBlock, count: frames)
    }

    private func play(_ unit: AudioUnitEffect, _ events: [MIDIEvent], into l: UnsafeMutablePointer<Float>,
                      _ r: UnsafeMutablePointer<Float>, startFrame: Int64, frames: Int) {
        // First event at or after the block start (events are sorted by frame).
        var lo = 0, hi = events.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if events[mid].frame < startFrame { lo = mid + 1 } else { hi = mid }
        }
        let end = startFrame + Int64(frames)
        while lo < events.count, events[lo].frame < end {
            let e = events[lo]
            unit.sendMIDI(e.status, e.data1, e.data2, sampleOffset: Int(e.frame - startFrame))
            lo += 1
        }
        scratchIn.update(repeating: 0, count: 2 * maxBlock)
        guard unit.process(frames: frames, input: inPointers, output: outPointers) == noErr else { return }
        for k in 0..<frames { l[k] += scratchOut[k]; r[k] += scratchOut[maxBlock + k] }
    }

    /// The largest absolute sample of a node (after its fader) since the last call. For meters.
    public func takePeak(node: Int) -> Float {
        guard node >= 0, node < nodeCount else { return 0 }
        let p = peaks[node]
        peaks[node] = 0
        return p
    }

    @inline(__always) private func left(_ node: Int) -> UnsafeMutablePointer<Float> { buffers + node * 2 * maxBlock }
    @inline(__always) private func right(_ node: Int) -> UnsafeMutablePointer<Float> { buffers + (node * 2 + 1) * maxBlock }

    /// Renders `frames` frames that start at project frame `startFrame` into `outLeft` and `outRight`.
    /// With `transport` false the arrangement and session clips and the MIDI clips stay silent, but hosted
    /// instruments and effects keep running. That is how a stopped project still plays live notes and rings out.
    public func process(startFrame: Int64, frames: Int, transport: Bool = true,
                        outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>) {
        precondition(frames <= maxBlock)
        buffers.update(repeating: 0, count: nodeCount * 2 * maxBlock)

        for i in 0..<nodeCount {
            let node = nodes[i]
            let l = left(i), r = right(i)

            if transport { for clip in node.clips { mix(clip, into: l, r, blockStart: startFrame, frames: frames) } }
            if let instrument = node.instrument { play(instrument, transport ? node.midi : [], into: l, r, startFrame: startFrame, frames: frames) }
            for slot in chains[i] where !slot.bypassed { runSlot(slot, l, r, startFrame: startFrame, frames: frames) }

            for (k, send) in node.sends.enumerated() where send.preFader { sendOut(send, sendLines[i][k], l, r, startFrame: startFrame, frames: frames) }

            let peak: Float
            if node.isMaster {
                peak = fader(node, l, r, outLeft, outRight, startFrame: startFrame, frames: frames)
            } else {
                peak = fader(node, l, r, l, r, startFrame: startFrame, frames: frames)
            }
            peaks[i] = max(peaks[i], peak)
            if node.isMaster { continue }

            for (k, send) in node.sends.enumerated() where !send.preFader { sendOut(send, sendLines[i][k], l, r, startFrame: startFrame, frames: frames) }
            if let target = node.output { addDelayed(l, r, to: target, line: outputLines[i], frames: frames) }
            for (k, tap) in node.taps.enumerated() { addDelayed(l, r, to: tap, line: tapLines[i][k], frames: frames) }
        }
    }

    // MARK: Automation

    /// Walks a block in pieces that end on multiples of 32 absolute frames.
    /// Automation is evaluated on that grid, so the result does not depend on how the host cuts blocks.
    @inline(__always)
    private func eachGridChunk(startFrame: Int64, frames: Int, _ body: (_ offset: Int, _ count: Int, _ gridStart: Int64, _ position: Float) -> Void) {
        var k = 0
        while k < frames {
            let f = startFrame + Int64(k)
            let gridStart = (f >> 5) << 5
            let count = min(frames - k, Int(gridStart + 32 - f))
            body(k, count, gridStart, Float(f - gridStart) / 32)
            k += count
        }
    }

    private func gains(_ node: NodePlan, at frame: Int64) -> (Float, Float) {
        var volume = node.gain
        if let lane = node.volumeAuto, let v = lane.value(at: frame) { volume = node.silenced ? 0 : RenderPlan.dB(Double(v)) }
        var pl = node.panLeft, pr = node.panRight
        if let lane = node.panAuto, let v = lane.value(at: frame) { (pl, pr) = RenderPlan.balance(Double(v)) }
        return (volume * pl, volume * pr)
    }

    /// Applies volume and pan from `l`, `r` into `outL`, `outR` (the same memory for a normal track). Returns the peak.
    private func fader(_ node: NodePlan, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>,
                       _ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>,
                       startFrame: Int64, frames: Int) -> Float {
        var peak: Float = 0
        if node.volumeAuto == nil && node.panAuto == nil {
            let gl = node.gain * node.panLeft, gr = node.gain * node.panRight
            for k in 0..<frames {
                let a = l[k] * gl, b = r[k] * gr
                outL[k] = a; outR[k] = b
                peak = max(peak, abs(a), abs(b))
            }
            return peak
        }
        eachGridChunk(startFrame: startFrame, frames: frames) { offset, count, grid, t0 in
            let (al, ar) = gains(node, at: grid), (bl, br) = gains(node, at: grid + 32)
            for j in 0..<count {
                let t = t0 + Float(j) / 32
                let a = l[offset + j] * (al + (bl - al) * t), b = r[offset + j] * (ar + (br - ar) * t)
                outL[offset + j] = a; outR[offset + j] = b
                peak = max(peak, abs(a), abs(b))
            }
        }
        return peak
    }

    private func addSend(_ send: SendPlan, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>,
                         startFrame: Int64, frames: Int) {
        guard let lane = send.auto else { add(l, r, gain: send.gain, to: send.target, frames: frames); return }
        let tl = left(send.target), tr = right(send.target)
        func gain(_ f: Int64) -> Float {
            guard let v = lane.value(at: f) else { return send.gain }
            return v <= -59.9 ? 0 : RenderPlan.dB(Double(v))
        }
        eachGridChunk(startFrame: startFrame, frames: frames) { offset, count, grid, t0 in
            let a = gain(grid), b = gain(grid + 32)
            for j in 0..<count {
                let g = a + (b - a) * (t0 + Float(j) / 32)
                tl[offset + j] += l[offset + j] * g; tr[offset + j] += r[offset + j] * g
            }
        }
    }

    /// Runs one effect. A built-in effect with automated knobs gets its values set at every grid step.
    private func runSlot(_ slot: Slot, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>,
                         startFrame: Int64, frames: Int) {
        if let unit = slot.unit { run(unit, l, r, frames: frames); return }
        guard let effect = slot.effect else { return }
        guard !slot.auto.isEmpty else { effect.process(l, r, frames: frames); return }
        eachGridChunk(startFrame: startFrame, frames: frames) { offset, count, grid, _ in
            var changed = false
            for (key, lane) in slot.auto {
                if let v = lane.value(at: grid), slot.live[key] != Double(v) { slot.live[key] = Double(v); changed = true }
            }
            if changed { effect.configure(slot.live) }
            effect.process(l + offset, r + offset, frames: count)
        }
    }

    @inline(__always)
    private func addDelayed(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, to target: Int, line: DelayLine?, frames: Int) {
        guard let line else { add(l, r, gain: 1, to: target, frames: frames); return }
        line.process(l, r, frames: frames)
        add(line.outLeft, line.outRight, gain: 1, to: target, frames: frames)
    }

    private func sendOut(_ send: SendPlan, _ line: DelayLine?, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>,
                         startFrame: Int64, frames: Int) {
        guard let line else { addSend(send, l, r, startFrame: startFrame, frames: frames); return }
        line.process(l, r, frames: frames)
        addSend(send, line.outLeft, line.outRight, startFrame: startFrame, frames: frames)
    }

    private func add(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, gain: Float, to target: Int, frames: Int) {
        let tl = left(target), tr = right(target)
        for k in 0..<frames { tl[k] += l[k] * gain; tr[k] += r[k] * gain }
    }

    private func mix(_ clip: ClipPlan, into l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>,
                     blockStart: Int64, frames: Int) {
        let from = max(blockStart, clip.start)
        let to = min(blockStart + Int64(frames), clip.end)
        guard from < to else { return }
        let length = clip.end - clip.start
        let total = Int64(clip.pcm.frames)
        let srcL = clip.pcm.channel(0), srcR = clip.pcm.channel(1)

        var f = from
        while f < to {
            let p = f - clip.start
            var s = clip.sourceOffset + p
            if clip.loop { s %= total } else if s >= total { break } // a one-shot ends with its audio

            var g = clip.gain
            if p < clip.fadeIn { g *= sinf(.pi / 2 * Float(p) / Float(clip.fadeIn)) }
            let remaining = length - 1 - p
            if remaining < clip.fadeOut { g *= sinf(.pi / 2 * Float(remaining) / Float(clip.fadeOut)) }

            let k = Int(f - blockStart)
            l[k] += srcL[Int(s)] * g
            r[k] += srcR[Int(s)] * g
            f += 1
        }
    }
}

// MARK: Offline bounce

public struct RenderedAudio {
    public var left: [Float]
    public var right: [Float]
    public var sampleRate: Double

    public init(left: [Float], right: [Float], sampleRate: Double) {
        self.left = left
        self.right = right
        self.sampleRate = sampleRate
    }

    public var frames: Int { left.count }
    public var peak: Float { max(left.reduce(0) { max($0, abs($1)) }, right.reduce(0) { max($0, abs($1)) }) }

    public var rms: Float {
        guard frames > 0 else { return 0 }
        let sum = zip(left, right).reduce(Double(0)) { $0 + Double($1.0 * $1.0 + $1.1 * $1.1) }
        return Float((sum / Double(frames * 2)).squareRoot())
    }
}

public enum Bounce {
    /// Renders the project's master mix from `startFrame` up to (not including) `endFrame`.
    /// With `endFrame` nil it renders to the end of the last clip plus `tailSeconds`.
    public static func render(_ plan: RenderPlan, startFrame: Int64 = 0, endFrame: Int64? = nil,
                              tailSeconds: Double = 0, block: Int = 4096) -> RenderedAudio {
        let end = endFrame ?? (plan.endFrame + Int64((tailSeconds * plan.sampleRate).rounded()))
        let total = Int(max(0, end - startFrame))
        var left = [Float](repeating: 0, count: total)
        var right = [Float](repeating: 0, count: total)
        let renderer = Renderer(plan: plan, maxBlock: block)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                var done = 0
                while done < total {
                    let n = min(block, total - done)
                    renderer.process(startFrame: startFrame + Int64(done), frames: n,
                                     outLeft: l.baseAddress! + done, outRight: r.baseAddress! + done)
                    done += n
                }
            }
        }
        return RenderedAudio(left: left, right: right, sampleRate: plan.sampleRate)
    }

    /// Writes a 24-bit WAV file.
    public static func writeWAV(_ audio: RenderedAudio, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: audio.sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(audio.frames, 1))) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = AVAudioFrameCount(audio.frames)
        audio.left.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: audio.frames) }
        audio.right.withUnsafeBufferPointer { buffer.floatChannelData![1].update(from: $0.baseAddress!, count: audio.frames) }
        if audio.frames > 0 { try file.write(from: buffer) }
    }
}
