import Foundation
import LoopStudioCore

/// Beats: the audio is cut into pieces at its transients (or on a note grid), and every piece starts at the
/// output frame the warp gives its first source frame. A piece plays at its own speed, so attacks stay
/// exactly as recorded. A slower tempo leaves a gap after a piece; the loop mode fills it. A faster tempo
/// cuts a piece short where the next one starts.
///
/// Neighbouring pieces cross over `xf` frames before the next piece's first frame, with gains that sum to 1.
/// At a ratio of 1 both pieces read the same frames there, so the result equals the input.
enum BeatsStretch {
    struct Piece { var source: Double; var output: Double }

    static func render(_ pcm: PCMBuffer, curve: WarpCurve, settings: WarpSettings) -> PCMBuffer {
        let rate = pcm.sampleRate
        let outFrames = max(1, curve.outFrames)
        let xf = max(16, Int(0.003 * rate))
        let pieces = cuts(pcm, curve: curve, settings: settings, minGap: Double(4 * xf))
        let out = PCMBuffer(channels: pcm.channels, frames: outFrames, sampleRate: rate)
        let total = pcm.frames
        let envelope = settings.transientEnvelope

        for (k, piece) in pieces.enumerated() {
            let o0 = Int(piece.output.rounded())
            let s0 = Int(piece.source.rounded())
            let o1 = k + 1 < pieces.count ? Int(pieces[k + 1].output.rounded()) : outFrames
            let s1 = k + 1 < pieces.count ? Int(pieces[k + 1].source.rounded()) : total
            let slot = o1 - o0
            let length = s1 - s0
            guard slot > 0, length > 0 else { continue }
            let first = k == 0
            let last = k + 1 == pieces.count
            let lead = first ? 0 : xf                       // fade-in before o0, under the previous piece's fade-out
            let tail = last ? 0 : xf                        // fade-out before o1
            let from = max(0, o0 - lead), to = min(outFrames, o1)
            // The second half of the piece is the loop that fills a gap.
            let loopStart = length / 2
            let loopLength = length - loopStart
            let canLoop = loopLength >= 2 * xf
            let mode: WarpSettings.TransientLoop = canLoop ? settings.transientLoop : .off
            let decay = envelope >= 100 ? Double.infinity : max(Double(xf), Double(slot) * envelope / 100)

            for o in from..<to {
                let t = o - o0                              // -lead ..< slot
                var gain: Float = 1
                if t < 0 { gain = Float(t + lead) / Float(lead) }
                if tail > 0, o >= o1 - tail { gain *= Float(o1 - o) / Float(tail) }
                if decay.isFinite, t > 0 { gain *= Float(max(0, 1 - Double(t) / decay)) }
                var pos: Int
                var mix: (pos: Int, weight: Float)? = nil
                let fills = slot > length
                if !fills || t < length && mode != .forward || t < loopStart {
                    pos = s0 + t
                    // Loop off: the piece fades out over its last frames when the slot runs on past it.
                    if fills, mode == .off, t >= length - xf { gain *= Float(max(0, length - t)) / Float(xf) }
                    if fills, mode == .off, t >= length { gain = 0 }
                } else if mode == .forward {
                    // The piece's second half, again and again. The last frames of every pass blend into the
                    // frames before the loop start, so the jump back lands on what the loop start follows.
                    let q = (t - loopStart) % loopLength
                    pos = s0 + loopStart + q
                    let blend = min(xf, loopLength / 4)
                    if q >= loopLength - blend, t + (loopLength - q) < slot {
                        let a = Float(q - (loopLength - blend)) / Float(blend)
                        mix = (s0 + loopStart - (loopLength - q), a)
                    }
                } else if mode == .backAndForth {
                    // Back from the end to the loop start, then forward again. The turns are continuous.
                    let v = (t - length) % (2 * loopLength)
                    pos = v < loopLength ? s0 + length - 1 - v : s0 + loopStart + (v - loopLength)
                } else {
                    gain = 0; pos = s0
                }
                guard gain > 0 else { continue }
                for c in 0..<pcm.channels {
                    let x = pcm.channel(c)
                    var value = pos >= 0 && pos < total ? x[pos] : 0
                    if let m = mix {
                        let other = m.pos >= 0 && m.pos < total ? x[m.pos] : 0
                        value = value * (1 - m.weight) + other * m.weight
                    }
                    out.mutableChannel(c)[o] += value * gain
                }
            }
        }
        return out
    }

    /// The pieces: a source frame and the output frame where it starts, both rising, none closer than `minGap`
    /// output frames. The first piece starts where the curve starts.
    static func cuts(_ pcm: PCMBuffer, curve: WarpCurve, settings: WarpSettings, minGap: Double) -> [Piece] {
        let outFrames = Double(curve.outFrames)
        var pieces = [Piece(source: curve.source(0), output: 0)]
        if let grid = settings.preserve.beats {
            var b = grid
            while true {
                let o = curve.output(forBeat: b)
                guard o < outFrames else { break }
                pieces.append(Piece(source: curve.source(o), output: o))
                b += grid
            }
        } else {
            // A cut sits 1 ms before the attack, so the piece holds all of it.
            let pre = 0.001 * pcm.sampleRate
            for t in pcm.transients {
                let s = max(0, Double(t) - pre)
                let o = curve.output(forSource: s)
                guard o > 0 else { continue }
                guard o < outFrames else { break }
                pieces.append(Piece(source: s, output: o))
            }
        }
        var kept: [Piece] = []
        for p in pieces {
            if let last = kept.last, p.output - last.output < minGap || p.source <= last.source { continue }
            kept.append(p)
        }
        return kept
    }
}
