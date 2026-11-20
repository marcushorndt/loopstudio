import Foundation

/// A warp mapping sampled into tables, so a stretcher can ask it millions of times. Between two table
/// points the curve is a straight line; the points sit every `step` output frames.
///
/// `scale` stretches the output axis: a curve with scale 2 is twice as long and reaches every source frame
/// at twice the output frame. The pitch shift uses it: stretch longer by the pitch ratio, then resample.
struct WarpCurve: Sendable {
    static let step = 64
    let outFrames: Int
    let scale: Double
    private let src: [Double]
    private let bts: [Double]

    init(_ m: WarpMapping) {
        let count = m.outFrames / Self.step + 3
        outFrames = m.outFrames
        scale = 1
        src = (0..<count).map { m.source(Double($0 * Self.step)) }
        bts = (0..<count).map { m.beats(Double($0 * Self.step)) }
    }

    private init(outFrames: Int, scale: Double, src: [Double], bts: [Double]) {
        self.outFrames = outFrames; self.scale = scale; self.src = src; self.bts = bts
    }

    /// The same curve over an output `factor` times as long.
    func scaled(by factor: Double) -> WarpCurve {
        WarpCurve(outFrames: Int((Double(outFrames) * factor).rounded(.up)), scale: scale * factor, src: src, bts: bts)
    }

    @inline(__always) private func lookup(_ table: [Double], _ o: Double) -> Double {
        let x = o / scale / Double(Self.step)
        let i = min(max(Int(x.rounded(.down)), 0), table.count - 2)
        return table[i] + (table[i + 1] - table[i]) * (x - Double(i))
    }

    /// The fractional source frame that sounds at output frame `o`.
    func source(_ o: Double) -> Double { lookup(src, o) }

    /// Beats on the timeline since the start of the clip, at output frame `o`.
    func beats(_ o: Double) -> Double { lookup(bts, o) }

    /// The output frame where the curve reaches `value` in `table`. The tables only rise.
    private func inverse(_ table: [Double], _ value: Double) -> Double {
        guard let first = table.first, let last = table.last else { return 0 }
        let step = Double(Self.step) * scale
        if value <= first {
            let slope = (table[1] - table[0]) / step
            return slope > 0 ? (value - first) / slope : 0
        }
        if value >= last {
            let n = table.count - 1
            let slope = (table[n] - table[n - 1]) / step
            return Double(n) * step + (slope > 0 ? (value - last) / slope : 0)
        }
        var lo = 0, hi = table.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if table[mid] <= value { lo = mid } else { hi = mid }
        }
        let span = table[hi] - table[lo]
        return (Double(lo) + (span > 0 ? (value - table[lo]) / span : 0)) * step
    }

    /// The output frame where source frame `s` sounds.
    func output(forSource s: Double) -> Double { inverse(src, s) }

    /// The output frame at timeline beat `b` of the clip.
    func output(forBeat b: Double) -> Double { inverse(bts, b) }

    /// True when the source runs at one speed from start to end: a constant tempo, no markers.
    var isLinear: Bool {
        guard src.count > 2 else { return true }
        let a = src[0], slope = (src[src.count - 1] - a) / Double(src.count - 1)
        return src.indices.allSatisfy { abs(src[$0] - (a + slope * Double($0))) < 0.5 }
    }
}
