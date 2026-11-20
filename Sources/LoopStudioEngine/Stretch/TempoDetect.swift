import Foundation

/// The tempo of an audio file, so a dropped file can follow the project tempo.
///
/// Three sources, in this order: a tempo in the file name ("Funk Loop 96 BPM"); for a loop, the tempo at
/// which its length is a whole number of bars, chosen closest to what the onsets say; for a longer file,
/// the onsets alone: their autocorrelation gives the beat period, and a phase-locked pulse over the whole
/// file refines it to a few thousandths of a BPM, so a five-minute song does not drift against the grid.
/// Tempos fold into 80 ..< 160 BPM; the clip panel's ÷2 and ×2 fix a half or double reading.
public enum TempoDetect {
    public enum Method: String, Sendable { case name, loopLength, onsets }

    public struct Estimate: Sendable, Equatable {
        public var bpm: Double
        /// 0...1. The name and the loop length count as 1.
        public var confidence: Double
        public var method: Method
    }

    public static let range = 80.0..<160.0
    /// Below this, a long file keeps no tempo (speech, ambience, rubato).
    public static let minConfidence = 0.35

    public static func estimate(_ pcm: PCMBuffer, name: String, loop: Bool) -> Estimate? {
        if let bpm = fromName(name) { return Estimate(bpm: bpm, confidence: 1, method: .name) }
        let seconds = Double(pcm.frames) / max(1, pcm.sampleRate)
        guard seconds > 0.2, !isSilent(pcm) else { return nil }
        let heard = onsetTempo(pcm)
        if loop {
            // A hit (a crash, a clap) is no loop: it gets no tempo, so it keeps its own speed.
            guard !isOneShot(pcm) else { return nil }
            let hint = heard.flatMap { $0.confidence >= 0.2 ? $0.bpm : nil }
            return Estimate(bpm: loopFit(seconds: seconds, hint: hint), confidence: 1, method: .loopLength)
        }
        guard let heard, heard.confidence >= minConfidence else { return nil }
        return Estimate(bpm: heard.bpm, confidence: heard.confidence, method: .onsets)
    }

    /// True for a single hit: shorter than a second, or loud at the start and decayed by the end (the last
    /// half below a sixth of the level of the first eighth). A loop keeps its level from end to end.
    public static func isOneShot(_ pcm: PCMBuffer) -> Bool {
        let n = pcm.frames
        guard Double(n) >= pcm.sampleRate else { return true }
        func level(_ from: Int, _ to: Int) -> Double {
            var s = 0.0
            for c in 0..<pcm.channels {
                let x = pcm.channel(c)
                for i in from..<to { s += Double(x[i] * x[i]) }
            }
            return (s / Double(max(1, (to - from) * pcm.channels))).squareRoot()
        }
        let head = level(0, n / 8), rest = level(n / 2, n)
        return head > 1e-4 && rest < head / 6
    }

    /// True when no sample reaches -80 dB: a silent file has no tempo of its own.
    public static func isSilent(_ pcm: PCMBuffer) -> Bool {
        for c in 0..<pcm.channels {
            let x = pcm.channel(c)
            for i in 0..<pcm.frames where abs(x[i]) > 1e-4 { return false }
        }
        return true
    }

    /// "96bpm", "96 BPM", "96_bpm", "bpm96", "BPM 128.5". 50...250.
    public static func fromName(_ name: String) -> Double? {
        let patterns = [#"(?i)(?<![\d.,])(\d{2,3}(?:[.,]\d{1,2})?)\s*[-_ ]?\s*bpm"#, #"(?i)bpm\s*[-_ ]?\s*(\d{2,3}(?:[.,]\d{1,2})?)(?![\d])"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let r = Range(m.range(at: 1), in: name),
                  let bpm = Double(name[r].replacingOccurrences(of: ",", with: ".")), (50...250).contains(bpm) else { continue }
            return bpm
        }
        return nil
    }

    /// The tempo at which `seconds` is a whole number of beats, in `range`. A power-of-two count of bars
    /// wins unless `hint` (from the onsets) sits closer to another count.
    public static func loopFit(seconds: Double, hint: Double?) -> Double {
        let counts: [Double] = [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256]
        let candidates = counts.compactMap { beats -> (bpm: Double, beats: Double)? in
            let bpm = beats * 60 / seconds
            return range.contains(bpm) ? (bpm, beats) : nil
        }
        let powerOfTwo = candidates.first { b in let bars = b.beats / 4; return bars >= 1 && bars == pow(2, (log2(bars)).rounded()) }
            ?? candidates.first { $0.beats == pow(2, log2($0.beats).rounded()) }
        if let hint {
            let h = fold(hint)
            if let best = candidates.min(by: { abs(log2($0.bpm / h)) < abs(log2($1.bpm / h)) }),
               abs(log2(best.bpm / h)) < 0.06 {
                return best.bpm
            }
        }
        if let p = powerOfTwo { return p.bpm }
        return fold(60 / seconds * 4)
    }

    static func fold(_ bpm: Double) -> Double {
        guard bpm > 0 else { return 120 }
        var b = bpm
        while b >= range.upperBound { b /= 2 }
        while b < range.lowerBound { b *= 2 }
        return b
    }

    /// The beat tempo the onsets show, and how clearly. `nil` without enough onsets.
    public static func onsetTempo(_ pcm: PCMBuffer) -> (bpm: Double, confidence: Double)? {
        let (raw, hop) = Onsets.strength(pcm)
        guard raw.count > 64 else { return nil }
        let hopSeconds = Double(hop) / pcm.sampleRate
        // Take out the slow level, keep the rises.
        let v = highPass(raw, width: max(3, Int(0.4 / hopSeconds)))
        let minLag = Int((60 / 200 / hopSeconds).rounded(.down))
        let maxLag = min(v.count / 2, Int((60 / 50 / hopSeconds).rounded(.up)) * 4)
        guard maxLag > minLag + 4 else { return nil }
        var acf = [Double](repeating: 0, count: maxLag + 2)
        v.withUnsafeBufferPointer { x in
            let n = x.count
            for lag in 0...(maxLag + 1) {
                var s = 0.0
                var i = 0
                while i + lag < n { s += Double(x[i] * x[i + lag]); i += 1 }
                acf[lag] = s / Double(n - lag)
            }
        }
        guard acf[0] > 0 else { return nil }
        func at(_ lag: Double) -> Double {
            let i = Int(lag), f = lag - Double(i)
            guard i + 1 < acf.count else { return 0 }
            return acf[i] + (acf[i + 1] - acf[i]) * f
        }
        // A comb over the first four multiples of the period, weighted toward 120 BPM.
        var scores: [(bpm: Double, score: Double)] = []
        var bpm = 60.0
        while bpm <= 200 {
            let lag = 60 / bpm / hopSeconds
            var s = 0.0
            for k in 1...4 where Double(k) * lag < Double(acf.count - 1) { s += at(Double(k) * lag) / Double(k) }
            let prior = exp(-0.5 * pow(log2(bpm / 120) / 1.0, 2))
            scores.append((bpm, s * prior / acf[0]))
            bpm += 0.25
        }
        guard let best = scores.max(by: { $0.score < $1.score }), best.score > 0 else { return nil }
        let sorted = scores.map(\.score).sorted()
        let median = sorted[sorted.count / 2]
        let confidence = max(0, min(1, (best.score - max(0, median)) / best.score))
        let refined = refine(v, hopSeconds: hopSeconds, around: fold(best.bpm))
        return (refined, confidence)
    }

    /// The period that lines up best with the onsets over the whole file: for each candidate tempo, the
    /// strongest phase of a pulse train; first in steps of 0.05 BPM over ±2 %, then 0.002 BPM.
    static func refine(_ v: [Float], hopSeconds: Double, around bpm: Double) -> Double {
        func score(_ bpm: Double) -> Double {
            let period = 60 / bpm / hopSeconds
            let phases = max(8, Int(period.rounded()))
            var best = -Double.infinity
            v.withUnsafeBufferPointer { x in
                let n = x.count
                for p in 0..<phases {
                    var pos = Double(p) * period / Double(phases)
                    var s = 0.0
                    while pos < Double(n - 1) {
                        let i = Int(pos), f = Float(pos - Double(i))
                        s += Double(x[i] + (x[i + 1] - x[i]) * f)
                        pos += period
                    }
                    best = max(best, s)
                }
            }
            return best
        }
        func search(_ center: Double, span: Double, step: Double) -> Double {
            var best = center, bestScore = -Double.infinity
            var b = center - span
            while b <= center + span {
                let s = score(b)
                if s > bestScore { bestScore = s; best = b }
                b += step
            }
            return best
        }
        let coarse = search(bpm, span: bpm * 0.02, step: 0.05)
        return search(coarse, span: 0.06, step: 0.002)
    }

    static func highPass(_ x: [Float], width: Int) -> [Float] {
        var out = [Float](repeating: 0, count: x.count)
        var sum: Float = 0
        var window: [Float] = []
        window.reserveCapacity(width)
        for i in 0..<x.count {
            sum += x[i]; window.append(x[i])
            if window.count > width { sum -= window.removeFirst() }
            out[i] = max(0, x[i] - sum / Float(window.count))
        }
        return out
    }
}
