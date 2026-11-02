import Foundation
import LoopStudioCore

/// EQ One to EQ Eight: one biquad per band and channel. A band that is off, or a bell or shelf at 0 dB,
/// costs nothing: only the bands that change the sound run.
public final class EQDSP: DSPEffect, @unchecked Sendable {
    /// One band's design, read from the parameters.
    struct Band {
        var on: Bool
        var type: Int
        var freq: Double
        var gain: Double
        var q: Double

        /// True when the band changes nothing: off, or a gain band at 0 dB. A cut or a notch always does.
        var isFlat: Bool { !on || ((type == 1 || type == 2 || type == 4) && abs(gain) < 0.01) }

        func filter(rate: Double) -> Biquad {
            var f = Biquad()
            switch type {
            case 0: f.highpass(freq, q: q, rate: rate)
            case 1: f.lowShelf(freq, gainDb: gain, rate: rate)
            case 3: f.notch(freq, q: q, rate: rate)
            case 4: f.highShelf(freq, gainDb: gain, rate: rate)
            case 5: f.lowpass(freq, q: q, rate: rate)
            case 6: f.bandpass(freq, q: q, rate: rate)
            default: f.peaking(freq, gainDb: gain, q: q, rate: rate)
            }
            return f
        }
    }

    private let count: Int
    private let left: UnsafeMutablePointer<Biquad>
    private let right: UnsafeMutablePointer<Biquad>
    private let active: UnsafeMutablePointer<Bool>
    private var outGain: Float = 1

    override init(spec: EffectSpec, sampleRate: Double) {
        count = spec.bands
        left = .allocate(capacity: count); left.initialize(repeating: Biquad(), count: count)
        right = .allocate(capacity: count); right.initialize(repeating: Biquad(), count: count)
        active = .allocate(capacity: count); active.initialize(repeating: false, count: count)
        super.init(spec: spec, sampleRate: sampleRate)
    }

    deinit { left.deallocate(); right.deallocate(); active.deallocate() }

    /// The bands as the parameters describe them.
    static func bands(_ spec: EffectSpec, _ p: [String: Double]) -> [Band] {
        func v(_ key: String) -> Double {
            guard let param = spec.param(key) else { return 0 }
            return param.clamp(p[key] ?? param.def)
        }
        return (1...max(1, spec.bands)).map { i in
            Band(on: v("b\(i).on") >= 0.5, type: Int(v("b\(i).type")), freq: v("b\(i).freq"), gain: v("b\(i).gain"), q: v("b\(i).q"))
        }
    }

    public override func configure(_ p: [String: Double]) {
        for (i, band) in Self.bands(spec, p).enumerated() where i < count {
            active[i] = !band.isFlat
            guard active[i] else { continue }
            let f = band.filter(rate: sampleRate)
            left[i].b0 = f.b0; left[i].b1 = f.b1; left[i].b2 = f.b2; left[i].a1 = f.a1; left[i].a2 = f.a2
            right[i].b0 = f.b0; right[i].b1 = f.b1; right[i].b2 = f.b2; right[i].a1 = f.a1; right[i].a2 = f.a2
        }
        outGain = powf(10, value(p, "gain") / 20)
    }

    public override func reset() {
        for i in 0..<count { left[i].reset(); right[i].reset() }
    }

    public override func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        for b in 0..<count where active[b] {
            for i in 0..<frames {
                l[i] = left[b].tick(l[i])
                r[i] = right[b].tick(r[i])
            }
        }
        if outGain != 1 {
            for i in 0..<frames { l[i] *= outGain; r[i] *= outGain }
        }
        spectrum?.write(l, r, frames: frames)
    }

    /// The gain of the whole EQ at each frequency in dB, for the curve on the device.
    public static func responseDb(at frequencies: [Double], spec: EffectSpec, params: [String: Double], sampleRate: Double) -> [Double] {
        let filters = bands(spec, params).filter { !$0.isFlat }.map { $0.filter(rate: sampleRate) }
        let out = spec.param("gain").map { $0.clamp(params["gain"] ?? $0.def) } ?? 0
        return frequencies.map { f in filters.reduce(out) { $0 + $1.magnitudeDb(at: f, rate: sampleRate) } }
    }

    /// The gain of one band alone, for its handle and its own curve.
    public static func bandResponseDb(at frequencies: [Double], band: Int, spec: EffectSpec, params: [String: Double], sampleRate: Double) -> [Double] {
        let bands = bands(spec, params)
        guard band < bands.count, !bands[band].isFlat else { return frequencies.map { _ in 0 } }
        let f = bands[band].filter(rate: sampleRate)
        return frequencies.map { f.magnitudeDb(at: $0, rate: sampleRate) }
    }
}
