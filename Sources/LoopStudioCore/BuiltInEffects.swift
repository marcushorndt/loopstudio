import Foundation

/// One knob of a built-in effect. The UI and the MCP tools draw and check parameters from this table.
public struct EffectParam: Sendable, Hashable {
    public var key: String
    public var name: String
    public var min: Double
    public var max: Double
    public var def: Double
    public var unit: String
    /// Names for a stepped parameter (min 0, max count - 1). Empty for a continuous one.
    public var choices: [String]
    /// True when the knob moves in a logarithmic scale (frequencies, times).
    public var logarithmic: Bool

    public init(_ key: String, _ name: String, _ min: Double, _ max: Double, _ def: Double,
                unit: String = "", choices: [String] = [], log: Bool = false) {
        self.key = key; self.name = name; self.min = min; self.max = max; self.def = def
        self.unit = unit; self.choices = choices; self.logarithmic = log
    }

    public func clamp(_ v: Double) -> Double { Swift.min(Swift.max(v, min), max) }

    /// Knob position 0...1 for a value.
    public func position(_ v: Double) -> Double {
        let x = clamp(v)
        if logarithmic, min > 0 { return log(x / min) / log(max / min) }
        return (x - min) / (max - min)
    }

    public func value(atPosition p: Double) -> Double {
        let q = Swift.min(Swift.max(p, 0), 1)
        if logarithmic, min > 0 { return min * pow(max / min, q) }
        let v = min + q * (max - min)
        return choices.isEmpty ? v : v.rounded()
    }

    public func format(_ v: Double) -> String {
        if !choices.isEmpty { return choices[Swift.min(Swift.max(0, Int(v.rounded())), choices.count - 1)] }
        let a = abs(v)
        let text = a >= 1000 ? String(format: "%.0f", v) : (a >= 100 ? String(format: "%.0f", v) : (a >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v)))
        return unit.isEmpty ? text : "\(text) \(unit)"
    }
}

public struct EffectSpec: Sendable, Hashable {
    public var id: String
    public var name: String
    public var params: [EffectParam]
}

public enum BuiltInEffects {
    public static let all: [EffectSpec] = [
        EffectSpec(id: "utility", name: "Utility", params: [
            EffectParam("gain", "Gain", -96, 24, 0, unit: "dB"),
            EffectParam("width", "Width", 0, 2, 1),
        ]),
        EffectSpec(id: "filter", name: "Auto Filter", params: [
            EffectParam("type", "Type", 0, 2, 0, choices: ["Low-pass", "High-pass", "Band-pass"]),
            EffectParam("cutoff", "Cutoff", 20, 20_000, 1_000, unit: "Hz", log: true),
            EffectParam("resonance", "Resonance", 0.3, 12, 0.707),
        ]),
        EffectSpec(id: "eq3", name: "EQ Three", params: [
            EffectParam("low", "Low", -18, 18, 0, unit: "dB"),
            EffectParam("mid", "Mid", -18, 18, 0, unit: "dB"),
            EffectParam("midFreq", "Mid Freq", 200, 8_000, 1_000, unit: "Hz", log: true),
            EffectParam("high", "High", -18, 18, 0, unit: "dB"),
        ]),
        EffectSpec(id: "delay", name: "Delay", params: [
            EffectParam("timeMs", "Time", 1, 2_000, 375, unit: "ms", log: true),
            EffectParam("feedback", "Feedback", 0, 0.95, 0.4),
            EffectParam("pingPong", "Ping Pong", 0, 1, 1, choices: ["Off", "On"]),
            EffectParam("mix", "Dry/Wet", 0, 1, 0.3),
        ]),
        EffectSpec(id: "reverb", name: "Reverb", params: [
            EffectParam("size", "Size", 0, 1, 0.6),
            EffectParam("damping", "Damping", 0, 1, 0.5),
            EffectParam("mix", "Dry/Wet", 0, 1, 0.25),
        ]),
        EffectSpec(id: "compressor", name: "Compressor", params: [
            EffectParam("threshold", "Threshold", -60, 0, -18, unit: "dB"),
            EffectParam("ratio", "Ratio", 1, 20, 4),
            EffectParam("attack", "Attack", 0.1, 100, 10, unit: "ms", log: true),
            EffectParam("release", "Release", 10, 1_000, 120, unit: "ms", log: true),
            EffectParam("makeup", "Makeup", 0, 24, 0, unit: "dB"),
        ]),
        EffectSpec(id: "limiter", name: "Limiter", params: [
            EffectParam("gain", "Gain", 0, 24, 0, unit: "dB"),
            EffectParam("ceiling", "Ceiling", -12, 0, -0.3, unit: "dB"),
            EffectParam("release", "Release", 10, 500, 80, unit: "ms", log: true),
        ]),
    ]

    public static func spec(_ id: String) -> EffectSpec? { all.first { $0.id == id } }

    public static func makeSlot(_ id: String) -> DeviceSlot? {
        guard let s = spec(id) else { return nil }
        return DeviceSlot(format: "builtin", identifier: id, name: s.name)
    }
}
