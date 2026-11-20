import Foundation
import LoopStudioCore

/// Offline time stretch (WSOLA). Pitch stays; length changes. Deterministic: the same input gives
/// the same output on every run, so a golden test can pin it.
///
/// The caller gives `source`: for an output frame, the (fractional) source frame that should sound there.
/// A constant ratio is a straight line. Warp markers make it a polyline. A tempo ramp makes it a curve.
public enum TimeStretch {
    /// Window size at 48 kHz. Beats uses a short window, so drum hits stay sharp. Tones uses a long one, for smooth pitched sound.
    static func window(for mode: WarpMode, rate: Double) -> Int {
        let base = mode == .tones ? 2048.0 : 512.0
        return max(64, Int((base * rate / 48_000).rounded() / 2) * 2)
    }

    public static func stretch(_ pcm: PCMBuffer, mode: WarpMode, outFrames: Int, source: (Double) -> Double) -> PCMBuffer {
        wsola(pcm, window: window(for: mode, rate: pcm.sampleRate), outFrames: outFrames, source: source)
    }

    /// WSOLA with a window of `n` frames (even): every window is placed where it best continues the last one.
    @_optimize(speed)
    static func wsola(_ pcm: PCMBuffer, window n: Int, outFrames: Int, source: (Double) -> Double) -> PCMBuffer {
        let hs = n / 2
        let tolerance = n / 4
        let total = pcm.frames
        let channels = max(1, pcm.channels)

        // Planar copies the loops can index without bounds worries.
        let input: [[Float]] = (0..<channels).map { Array(UnsafeBufferPointer(start: pcm.channel($0), count: total)) }
        let mono: [Float] = (0..<total).map { i in input.reduce(Float(0)) { $0 + $1[i] } / Float(channels) }
        let decimation = 4
        let coarse: [Float] = (0..<(total / decimation)).map { i in
            var s: Float = 0
            for j in 0..<decimation { s += mono[i * decimation + j] }
            return s / Float(decimation)
        }

        let hann: [Float] = (0..<n).map { 0.5 - 0.5 * cosf(2 * .pi * Float($0) / Float(n)) }
        var out = [[Float]](repeating: [Float](repeating: 0, count: outFrames + n), count: channels)
        var weight = [Float](repeating: 0, count: outFrames + n)

        @inline(__always) func at(_ x: [Float], _ i: Int) -> Float { i >= 0 && i < x.count ? x[i] : 0 }

        /// Normalized correlation of the template (input from `template`) with the input from `candidate`.
        func score(_ template: Int, _ candidate: Int, length: Int, _ x: [Float]) -> Float {
            var dot: Float = 0, energy: Float = 1e-9
            for k in 0..<length {
                let c = at(x, candidate + k), t = at(x, template + k)
                dot += t * c; energy += c * c
            }
            return dot / energy.squareRoot()
        }

        var previous: Int?
        var o = 0
        while o < outFrames {
            let nominal = Int(source(Double(o)).rounded())
            var chosen = nominal
            if let p = previous {
                let template = p + hs
                // Coarse: on the decimated signal.
                var best = nominal, bestScore = -Float.infinity
                let cLen = n / decimation, cTemplate = template / decimation
                var d = -tolerance / decimation
                while d <= tolerance / decimation {
                    let candidate = nominal / decimation + d
                    let s = score(cTemplate, candidate, length: cLen, coarse)
                    if s > bestScore { bestScore = s; best = candidate * decimation }
                    d += 1
                }
                // Fine: on the full signal around the coarse winner.
                bestScore = -Float.infinity
                for d in -decimation...decimation {
                    let candidate = best + d
                    let s = score(template, candidate, length: n, mono)
                    if s > bestScore { bestScore = s; chosen = candidate }
                }
            }
            for c in 0..<channels {
                for i in 0..<n {
                    out[c][o + i] += hann[i] * at(input[c], chosen + i)
                }
            }
            for i in 0..<n { weight[o + i] += hann[i] }
            previous = chosen
            o += hs
        }

        // Where fewer windows overlap (the first and last half window) the weights do not sum to 1. Divide that out.
        let result: [[Float]] = out.map { channel in
            (0..<outFrames).map { i in weight[i] > 1e-3 ? channel[i] / weight[i] : 0 }
        }
        return PCMBuffer(samples: result, sampleRate: pcm.sampleRate)
    }
}

/// How a clip's source maps to the timeline. Built from the source tempo or the warp markers.
public struct WarpMapping {
    /// Output frames until the whole source has played.
    public var outFrames: Int
    /// Fractional source frame at an output frame.
    public var source: (Double) -> Double
    /// Beats on the timeline since the start of the clip, at an output frame. Beats' note grid uses it.
    public var beats: (Double) -> Double

    /// `startFrame` is where the clip begins on the timeline. `markers` count in ticks from the start of the audio.
    public static func make(sourceFrames: Int, sourceTempo: Double?, markers: [WarpMarker], assetRate: Double,
                            tempoMap: TempoMap, startTick: Tick, sampleRate: Double, maxSeconds: Double = 1_200) -> WarpMapping? {
        let startFrame = tempoMap.frame(at: startTick, sampleRate: sampleRate).rawValue
        let startSeconds = Double(startFrame) / sampleRate

        /// Beats on the project timeline since the start of the clip, at an output frame.
        func beats(_ o: Double) -> Double {
            let seconds = startSeconds + o / sampleRate
            return tempoMap.tickAt(seconds: seconds) / Double(Tick.perQuarter) - startTick.quarters
        }

        let scale = sampleRate / max(1, assetRate)
        let sorted = markers.sorted { $0.tick < $1.tick }
        let sourceAtBeat: (Double) -> Double
        if sorted.count >= 2 {
            let b = sorted.map { $0.tick.quarters }
            let s = sorted.map { Double($0.sourceFrame) * scale }
            sourceAtBeat = { x in
                var i = 0
                while i < b.count - 2 && x > b[i + 1] { i += 1 }
                let span = b[i + 1] - b[i]
                guard span > 0 else { return s[i] }
                return s[i] + (x - b[i]) / span * (s[i + 1] - s[i])   // beyond the ends the nearest segment continues
            }
        } else if let tempo = sourceTempo, tempo > 0 {
            sourceAtBeat = { $0 * 60 / tempo * sampleRate }
        } else {
            return nil
        }

        let source: (Double) -> Double = { sourceAtBeat(beats($0)) }
        // Find the output length: the first frame where the source is used up.
        let target = Double(sourceFrames)
        let limit = maxSeconds * sampleRate
        var hi = Double(sourceFrames), lo = 0.0
        while source(hi) < target { hi *= 2; if hi > limit { return nil } }
        for _ in 0..<40 { let mid = (lo + hi) / 2; if source(mid) < target { lo = mid } else { hi = mid } }
        return WarpMapping(outFrames: Int(hi.rounded()), source: source, beats: beats)
    }
}
