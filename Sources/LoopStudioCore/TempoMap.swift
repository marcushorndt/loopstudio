import Foundation

public struct TempoPoint: Hashable, Codable, Sendable {
    public var tick: Tick
    public var bpm: Double
    /// When true, tempo changes linearly from this point to the next point.
    public var ramp: Bool

    public init(tick: Tick, bpm: Double, ramp: Bool = false) {
        self.tick = tick
        self.bpm = bpm
        self.ramp = ramp
    }
}

/// Converts between ticks, seconds and frames, including linear tempo ramps.
/// A value type. The renderer receives a copy inside each render plan.
///
/// Rules (always true after `init`):
/// - at least one point, and the first point sits at tick 0
/// - points are sorted, with one point per tick (the last one given wins)
/// - every tempo is clamped to `bpmRange`
/// Before tick 0 the first tempo continues backwards, so pre-roll has a defined length.
public struct TempoMap: Hashable, Codable, Sendable {
    public static let bpmRange: ClosedRange<Double> = 20...999
    /// Seconds per tick at 1 BPM.
    private static let k = 60.0 / Double(Tick.perQuarter)

    public private(set) var points: [TempoPoint]
    /// Seconds at the start of each point. Derived from `points`.
    private var startSeconds: [Double]

    public init(points: [TempoPoint] = [TempoPoint(tick: 0, bpm: 120)]) {
        var byTick: [Int64: TempoPoint] = [:]
        for var p in points {
            if p.bpm.isNaN { p.bpm = 120 }
            p.bpm = min(max(p.bpm, Self.bpmRange.lowerBound), Self.bpmRange.upperBound)
            p.tick = Tick(max(0, p.tick.rawValue))
            byTick[p.tick.rawValue] = p
        }
        var sorted = byTick.values.sorted { $0.tick < $1.tick }
        if sorted.isEmpty { sorted = [TempoPoint(tick: 0, bpm: 120)] }
        // The map always starts at tick 0. An earlier tempo continues backwards from the first point.
        if sorted[0].tick.rawValue > 0 { sorted.insert(TempoPoint(tick: 0, bpm: sorted[0].bpm), at: 0) }
        self.points = sorted
        self.startSeconds = []
        self.startSeconds = Self.computeStarts(sorted)
    }

    public init(bpm: Double) { self.init(points: [TempoPoint(tick: 0, bpm: bpm)]) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(points: try container.decode([TempoPoint].self, forKey: .points))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(points, forKey: .points)
    }

    private enum CodingKeys: String, CodingKey { case points }

    // MARK: Conversion

    /// Seconds from tick 0 to `tick`. Negative for ticks before 0.
    public func seconds(at tick: Tick) -> Double {
        let first = points[0]
        if tick.rawValue < 0 { return Double(tick.rawValue) * Self.k / first.bpm }
        let i = segmentIndex(containingTick: tick)
        let p = points[i]
        let dt = Double(tick.rawValue - p.tick.rawValue)
        if let (length, b1) = rampTarget(at: i) {
            let b0 = p.bpm
            let bt = b0 + (b1 - b0) * dt / length
            return startSeconds[i] + Self.k * length / (b1 - b0) * log(bt / b0)
        }
        return startSeconds[i] + Self.k * dt / p.bpm
    }

    /// The tick at `seconds`, rounded to the nearest tick.
    public func tick(atSeconds seconds: Double) -> Tick {
        let first = points[0]
        if seconds < 0 { return Tick(Int64((seconds * first.bpm / Self.k).rounded(.toNearestOrEven))) }
        let i = segmentIndex(containingSeconds: seconds)
        let p = points[i]
        let rem = seconds - startSeconds[i]
        let dt: Double
        if let (length, b1) = rampTarget(at: i) {
            let b0 = p.bpm
            let bt = b0 * exp(rem * (b1 - b0) / (Self.k * length))
            dt = length * (bt - b0) / (b1 - b0)
        } else {
            dt = rem * p.bpm / Self.k
        }
        return Tick(p.tick.rawValue + Int64(dt.rounded(.toNearestOrEven)))
    }

    /// The only place that rounds to a frame: nearest, ties to even.
    public func frame(at tick: Tick, sampleRate: Double) -> Frame {
        Frame(Int64((seconds(at: tick) * sampleRate).rounded(.toNearestOrEven)))
    }

    public func tick(atFrame frame: Frame, sampleRate: Double) -> Tick {
        tick(atSeconds: Double(frame.rawValue) / sampleRate)
    }

    /// The tempo at `tick`. Inside a ramp this is the interpolated value.
    public func bpm(at tick: Tick) -> Double {
        if tick.rawValue < 0 { return points[0].bpm }
        let i = segmentIndex(containingTick: tick)
        let p = points[i]
        if let (length, b1) = rampTarget(at: i) {
            return p.bpm + (b1 - p.bpm) * Double(tick.rawValue - p.tick.rawValue) / length
        }
        return p.bpm
    }

    // MARK: Internals

    /// Length in ticks and end tempo, if segment `i` is a real ramp.
    private func rampTarget(at i: Int) -> (length: Double, endBPM: Double)? {
        guard points[i].ramp, i + 1 < points.count,
              abs(points[i + 1].bpm - points[i].bpm) > 1e-9 else { return nil }
        return (Double(points[i + 1].tick.rawValue - points[i].tick.rawValue), points[i + 1].bpm)
    }

    private func segmentIndex(containingTick tick: Tick) -> Int {
        var lo = 0, hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if points[mid].tick <= tick { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func segmentIndex(containingSeconds s: Double) -> Int {
        var lo = 0, hi = startSeconds.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if startSeconds[mid] <= s { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private static func computeStarts(_ points: [TempoPoint]) -> [Double] {
        var starts = [Double](repeating: 0, count: points.count)
        for i in 1..<max(points.count, 1) {
            let p = points[i - 1]
            let length = Double(points[i].tick.rawValue - p.tick.rawValue)
            let duration: Double
            if p.ramp, abs(points[i].bpm - p.bpm) > 1e-9 {
                duration = k * length / (points[i].bpm - p.bpm) * log(points[i].bpm / p.bpm)
            } else {
                duration = k * length / p.bpm
            }
            starts[i] = starts[i - 1] + duration
        }
        return starts
    }
}
