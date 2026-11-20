import Foundation
import LoopStudioCore
import RubberBandBridge

/// Complex and Complex Pro: Rubber Band Library, offline, with the warp as a key frame map. Complex runs
/// the R2 engine (a phase vocoder with phase resets at transients). Complex Pro runs the R3 engine (several
/// resolutions at once) and keeps the formants when the pitch moves, as much as `formants` says.
enum ComplexStretch {
    static func render(_ pcm: PCMBuffer, curve: WarpCurve, finer: Bool, pitch: Double, formants: Double) -> PCMBuffer? {
        let outFrames = max(1, curve.outFrames)
        let total = pcm.frames
        // The input runs from the source frame the curve starts at; a start before the file is silence.
        let s0 = curve.source(0)
        let begin = Int(s0.rounded(.down))
        let pad = max(0, -begin)
        let skip = max(0, begin)
        let inFrames = total - skip + pad
        guard inFrames > 1 else { return nil }
        var input: [[Float]] = []
        for c in 0..<pcm.channels {
            var x = [Float](repeating: 0, count: inFrames)
            x.withUnsafeMutableBufferPointer { b in
                (b.baseAddress! + pad).update(from: pcm.channel(c) + skip, count: total - skip)
            }
            input.append(x)
        }
        // Key frames every 50 ms of output where the speed changes; none at one speed.
        var keySource: [Int] = [], keyOutput: [Int] = []
        if !curve.isLinear {
            let step = max(256, Int(0.05 * pcm.sampleRate))
            var o = step
            while o < outFrames - step {
                let s = curve.source(Double(o)) - Double(begin)
                if s > 0, s < Double(inFrames) { keySource.append(Int(s.rounded())); keyOutput.append(o) }
                o += step
            }
        }
        let out = PCMBuffer(channels: pcm.channels, frames: outFrames, sampleRate: pcm.sampleRate)
        var settings = rb_settings()
        settings.engine = finer ? 1 : 0
        settings.pitch = pitch
        settings.channelsTogether = 1
        settings.transients = 0
        let f = min(1, max(0, formants / 100))
        if finer, pitch != 1, f > 0 {
            settings.formantPreserved = 1
            settings.formantScale = f >= 1 ? 0 : pow(1 / pitch, f)
        }
        let written: Int = input.withPointers { inPointers in
            out.withMutablePointers { outPointers in
                keySource.withUnsafeBufferPointer { ks in
                    keyOutput.withUnsafeBufferPointer { ko in
                        Int(rb_stretch_offline(inPointers, Int32(pcm.channels), inFrames, pcm.sampleRate,
                                               outPointers, outFrames, ks.baseAddress, ko.baseAddress, Int32(ks.count), &settings))
                    }
                }
            }
        }
        return written == outFrames ? out : nil
    }
}

private extension Array where Element == [Float] {
    /// Pointers to every channel, valid inside `body`.
    func withPointers<R>(_ body: (UnsafePointer<UnsafePointer<Float>?>) -> R) -> R {
        var pointers: [UnsafePointer<Float>?] = []
        func nest(_ i: Int) -> R {
            if i == count { return pointers.withUnsafeBufferPointer { body($0.baseAddress!) } }
            return self[i].withUnsafeBufferPointer { b in pointers.append(b.baseAddress); return nest(i + 1) }
        }
        return nest(0)
    }
}

private extension PCMBuffer {
    func withMutablePointers<R>(_ body: (UnsafePointer<UnsafeMutablePointer<Float>?>) -> R) -> R {
        let pointers: [UnsafeMutablePointer<Float>?] = (0..<channels).map { mutableChannel($0) }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
