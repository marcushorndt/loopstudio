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

    public init(plan: RenderPlan, maxBlock: Int = 4096) {
        self.plan = plan
        self.maxBlock = maxBlock
        nodeCount = plan.nodes.count
        nodes = .allocate(capacity: nodeCount)
        nodes.initialize(from: plan.nodes, count: nodeCount)
        buffers = .allocate(capacity: nodeCount * 2 * maxBlock)
        buffers.initialize(repeating: 0, count: nodeCount * 2 * maxBlock)
    }

    deinit {
        nodes.deinitialize(count: nodeCount)
        nodes.deallocate()
        buffers.deallocate()
    }

    @inline(__always) private func left(_ node: Int) -> UnsafeMutablePointer<Float> { buffers + node * 2 * maxBlock }
    @inline(__always) private func right(_ node: Int) -> UnsafeMutablePointer<Float> { buffers + (node * 2 + 1) * maxBlock }

    /// Renders `frames` frames that start at project frame `startFrame` into `outLeft` and `outRight`.
    public func process(startFrame: Int64, frames: Int,
                        outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>) {
        precondition(frames <= maxBlock)
        buffers.update(repeating: 0, count: nodeCount * 2 * maxBlock)

        for i in 0..<nodeCount {
            let node = nodes[i]
            let l = left(i), r = right(i)

            for clip in node.clips { mix(clip, into: l, r, blockStart: startFrame, frames: frames) }

            for send in node.sends where send.preFader { add(l, r, gain: send.gain, to: send.target, frames: frames) }

            if node.isMaster {
                let gl = node.gain * node.panLeft, gr = node.gain * node.panRight
                for k in 0..<frames { outLeft[k] = l[k] * gl; outRight[k] = r[k] * gr }
                continue
            }

            let gl = node.gain * node.panLeft, gr = node.gain * node.panRight
            for k in 0..<frames { l[k] *= gl; r[k] *= gr }
            for send in node.sends where !send.preFader { add(l, r, gain: send.gain, to: send.target, frames: frames) }
            if let target = node.output { add(l, r, gain: 1, to: target, frames: frames) }
        }
    }

    @inline(__always)
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
