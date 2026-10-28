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
    /// A time or a speed that can follow the song tempo. The switch is `<key>Sync`, the note value `<key>Division`.
    public var syncable = false
    /// A stepped parameter drawn as a knob that clicks through its choices (a note value), not as a menu.
    public var rotary = false

    public init(_ key: String, _ name: String, _ min: Double, _ max: Double, _ def: Double,
                unit: String = "", choices: [String] = [], log: Bool = false) {
        self.key = key; self.name = name; self.min = min; self.max = max; self.def = def
        self.unit = unit; self.choices = choices; self.logarithmic = log
        syncKey = key + "Sync"; divisionKey = key + "Division"
    }

    public func clamp(_ v: Double) -> Double { Swift.min(Swift.max(v, min), max) }

    /// A switch: two choices, off and on.
    public var isSwitch: Bool { choices == ["Off", "On"] }
    /// Built once here: the audio thread reads them, and building a long string there would allocate.
    public private(set) var syncKey = ""
    public private(set) var divisionKey = ""

    /// A time (unit "ms") or speed (unit "Hz") that can follow the tempo, with its switch and its note value.
    /// `longest`: the longest note value offered, so a synced time fits the effect's buffer at 30 BPM.
    static func synced(_ key: String, _ name: String, _ min: Double, _ max: Double, _ def: Double, unit: String,
                       division: String, longest: String = "8/1", log: Bool = true) -> [EffectParam] {
        var free = EffectParam(key, name, min, max, def, unit: unit, log: log)
        free.syncable = true
        var note = EffectParam(free.divisionKey, name + " Note", Double(NoteDivision.index(longest)), Double(NoteDivision.all.count - 1),
                               Double(NoteDivision.index(division)), choices: NoteDivision.all.map(\.name))
        note.rotary = true
        return [free, EffectParam(free.syncKey, name + " Sync", 0, 1, 0, choices: ["Off", "On"]), note]
    }

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

    /// The knobs drawn on the device: the switch and the note value of a synced knob live inside that knob.
    public var shownParams: [EffectParam] {
        let hidden = Set(params.filter(\.syncable).flatMap { [$0.syncKey, $0.divisionKey] })
        return params.filter { !hidden.contains($0.key) }
    }
}

/// A note value for a time or a speed that follows the tempo. "1/4" is a quarter note, "1/3" a half-note
/// triplet, "1/4." a dotted quarter note.
public struct NoteDivision: Sendable, Hashable {
    public var name: String
    /// Length in quarter notes.
    public var quarters: Double

    public static let all: [NoteDivision] = {
        let table: [(String, Double)] = [
            ("8/1", 32), ("4/1", 16), ("2/1", 8), ("1/1", 4), ("1/2.", 3), ("1/2", 2), ("1/3", 4.0 / 3),
            ("1/4.", 1.5), ("1/4", 1), ("1/6", 2.0 / 3), ("1/8.", 0.75), ("1/8", 0.5), ("1/12", 1.0 / 3),
            ("1/16.", 0.375), ("1/16", 0.25), ("1/24", 1.0 / 6), ("1/32", 0.125), ("1/48", 1.0 / 12), ("1/64", 0.0625),
        ]
        return table.map { NoteDivision(name: $0.0, quarters: $0.1) }
    }()

    public static func index(_ name: String) -> Int { all.firstIndex { $0.name == name } ?? 0 }

    /// The note value at a stored parameter value (its index).
    public static func at(_ value: Double) -> NoteDivision { all[Swift.min(Swift.max(0, Int(value.rounded())), all.count - 1)] }
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
            // The LFO moves the cutoff up and down by up to four octaves each way.
            EffectParam("lfoAmount", "LFO", 0, 1, 0),
        ] + EffectParam.synced("lfoRate", "Rate", 0.05, 20, 1, unit: "Hz", division: "1/4")),
        EffectSpec(id: "eq3", name: "EQ Three", params: [
            EffectParam("low", "Low", -18, 18, 0, unit: "dB"),
            EffectParam("mid", "Mid", -18, 18, 0, unit: "dB"),
            EffectParam("midFreq", "Mid Freq", 200, 8_000, 1_000, unit: "Hz", log: true),
            EffectParam("high", "High", -18, 18, 0, unit: "dB"),
        ]),
        EffectSpec(id: "delay", name: "Delay", params: EffectParam.synced("timeMs", "Time", 1, 2_000, 375, unit: "ms", division: "1/8.", longest: "1/1") + [
            EffectParam("feedback", "Feedback", 0, 0.95, 0.4),
            EffectParam("pingPong", "Ping Pong", 0, 1, 1, choices: ["Off", "On"]),
            EffectParam("mix", "Dry/Wet", 0, 1, 0.3),
        ]),
        EffectSpec(id: "reverb", name: "Reverb", params: EffectParam.synced("preDelayMs", "Pre-Delay", 0, 500, 0, unit: "ms", division: "1/32", longest: "1/4", log: false) + [
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
        var slot = DeviceSlot(format: "builtin", identifier: id, name: s.name)
        // A new delay follows the tempo, like Live's. Older projects keep their free times: the default stays off.
        if id == "delay" { slot.params["timeMsSync"] = 1 }
        return slot
    }
}
