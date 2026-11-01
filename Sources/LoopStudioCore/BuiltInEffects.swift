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
    /// An instrument makes sound from notes and takes no audio in. It sits on a MIDI track, where the
    /// first one that is not bypassed plays; the effects after it shape its sound.
    public var isInstrument = false

    /// The knobs drawn on the device: the switch and the note value of a synced knob live inside that knob.
    public var shownParams: [EffectParam] {
        let hidden = Set(params.filter(\.syncable).flatMap { [$0.syncKey, $0.divisionKey] })
        return params.filter { !hidden.contains($0.key) }
    }

    public func param(_ key: String) -> EffectParam? { params.first { $0.key == key } }
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

    /// The spec of a built-in device: an effect from `all` or an instrument from `BuiltInInstruments.all`.
    public static func spec(_ id: String) -> EffectSpec? {
        all.first { $0.id == id } ?? BuiltInInstruments.all.first { $0.id == id }
    }

    public static func makeSlot(_ id: String) -> DeviceSlot? {
        guard let s = spec(id) else { return nil }
        var slot = DeviceSlot(format: "builtin", identifier: id, name: s.name)
        // A new delay follows the tempo, like Live's. Older projects keep their free times: the default stays off.
        if id == "delay" { slot.params["timeMsSync"] = 1 }
        return slot
    }
}

/// The instruments that come with the app. Their parameters work like an effect's: automation lanes, MIDI
/// Learn, the MCP tools and undo all go through `setDeviceParam`.
public enum BuiltInInstruments {
    /// A monophonic bass synth in the style of the 303: one oscillator, a resonant 4-pole filter, a decay
    /// envelope, accent and slide. A note with velocity 100 or more is accented. A note that starts before the
    /// one before it ends slides to the new pitch without a new attack.
    public static let acid = EffectSpec(id: "acid", name: "Acid Bass", params: [
        EffectParam("wave", "Wave", 0, 1, 0, choices: ["Saw", "Square"]),
        EffectParam("tune", "Tune", -24, 24, 0, unit: "st"),
        EffectParam("sub", "Sub", 0, 1, 0),
        EffectParam("cutoff", "Cutoff", 60, 18_000, 700, unit: "Hz", log: true),
        EffectParam("resonance", "Resonance", 0, 1, 0.65),
        EffectParam("envMod", "Env Mod", 0, 1, 0.6),
        // How far the cutoff follows the note: 1 is a full octave per octave, measured from C3.
        EffectParam("keyTrack", "Key", 0, 1, 0.3),
        EffectParam("decay", "Decay", 50, 3_000, 400, unit: "ms", log: true),
        EffectParam("accent", "Accent", 0, 1, 0.7),
        EffectParam("slide", "Slide", 5, 500, 60, unit: "ms", log: true),
        EffectParam("drive", "Drive", 0, 1, 0.15),
        EffectParam("volume", "Volume", -24, 12, -6, unit: "dB"),
    ], isInstrument: true)

    /// The accent threshold of the Acid Bass: a note at this velocity or above is accented.
    public static let accentVelocity: UInt8 = 100

    /// A synthesized drum machine in the style of the 808: twelve pads on the General MIDI drum notes.
    public static let drums = EffectSpec(id: "drum808", name: "808 Drums", params: [
        EffectParam("bd.tune", "Tune", -12, 12, 0, unit: "st"),
        EffectParam("bd.decay", "Decay", 50, 2_000, 500, unit: "ms", log: true),
        EffectParam("bd.tone", "Tone", 0, 1, 0.4),
        EffectParam("bd.level", "Level", -24, 6, 0, unit: "dB"),
        EffectParam("sd.tune", "Tune", -12, 12, 0, unit: "st"),
        EffectParam("sd.snappy", "Snappy", 0, 1, 0.6),
        EffectParam("sd.decay", "Decay", 50, 1_000, 200, unit: "ms", log: true),
        EffectParam("sd.level", "Level", -24, 6, 0, unit: "dB"),
        // The clap: a burst of claps (each its own hand), then a tail. The random knobs give each clap its own
        // timing and level, tune, filter and place in the stereo picture.
        EffectParam("cp.count", "Claps", 1, 12, 3),
        EffectParam("cp.space", "Spacing", 4, 60, 10, unit: "ms"),
        EffectParam("cp.tune", "Tune", 400, 5_000, 1_300, unit: "Hz", log: true),
        EffectParam("cp.filter", "Filter", 1_000, 18_000, 12_000, unit: "Hz", log: true),
        EffectParam("cp.tail", "Tail", 0, 1, 0.7),
        EffectParam("cp.decay", "Decay", 50, 3_000, 600, unit: "ms", log: true),
        EffectParam("cp.level", "Level", -24, 6, 0, unit: "dB"),
        EffectParam("cp.random", "Timing", 0, 1, 0.2),
        EffectParam("cp.tuneRandom", "Tune", 0, 1, 0),
        EffectParam("cp.filterRandom", "Filter", 0, 1, 0),
        EffectParam("cp.panRandom", "Pan", 0, 1, 0),
        EffectParam("rs.tune", "Tune", -12, 12, 0, unit: "st"),
        EffectParam("rs.level", "Level", -24, 6, 0, unit: "dB"),
        EffectParam("lt.tune", "Tune", -12, 12, 0, unit: "st"),
        EffectParam("mt.tune", "Tune", -12, 12, 0, unit: "st"),
        EffectParam("ht.tune", "Tune", -12, 12, 0, unit: "st"),
        EffectParam("tom.decay", "Decay", 50, 1_500, 350, unit: "ms", log: true),
        EffectParam("tom.level", "Level", -24, 6, 0, unit: "dB"),
        EffectParam("cb.tune", "Tune", -12, 12, 0, unit: "st"),
        EffectParam("cb.level", "Level", -24, 6, 0, unit: "dB"),
        EffectParam("hh.tone", "Tone", 0, 1, 0.5),
        EffectParam("ch.decay", "Decay", 20, 300, 60, unit: "ms", log: true),
        EffectParam("ch.level", "Level", -24, 6, 0, unit: "dB"),
        EffectParam("oh.decay", "Decay", 100, 2_000, 450, unit: "ms", log: true),
        EffectParam("oh.level", "Level", -24, 6, 0, unit: "dB"),
        EffectParam("cy.tone", "Tone", 0, 1, 0.5),
        EffectParam("cy.decay", "Decay", 200, 4_000, 1_500, unit: "ms", log: true),
        EffectParam("cy.level", "Level", -24, 6, -3, unit: "dB"),
        EffectParam("cl.level", "Level", -24, 6, 0, unit: "dB"),
        EffectParam("accent", "Velocity", 0, 1, 0.6),
        EffectParam("spread", "Spread", 0, 1, 0.3),
        EffectParam("volume", "Volume", -24, 12, 0, unit: "dB"),
    ], isInstrument: true)

    public static let all: [EffectSpec] = [acid, drums]

    public static func spec(_ id: String) -> EffectSpec? { all.first { $0.id == id } }

    /// One pad of the drum machine: its name, the notes that play it and the knobs that shape it.
    public struct DrumPad: Sendable, Hashable, Identifiable {
        public var id: String { key }
        public var key: String
        public var name: String
        /// The notes that play the pad. The first one is the main one, shown on the pad.
        public var notes: [UInt8]
        /// Parameter keys of the drum spec that belong to this pad, in display order.
        public var params: [String]
        /// Where the pad sits in the stereo picture at full spread, -1 (left) to 1 (right).
        public var pan: Double
        /// Knobs that add chance to the pad, shown in their own section. Empty for most pads.
        public var random: [String] = []
    }

    /// The pads in display order: four per row, three rows.
    public static let drumPads: [DrumPad] = [
        DrumPad(key: "bd", name: "Kick", notes: [36, 35], params: ["bd.tune", "bd.decay", "bd.tone", "bd.level"], pan: 0),
        DrumPad(key: "sd", name: "Snare", notes: [38, 40], params: ["sd.tune", "sd.snappy", "sd.decay", "sd.level"], pan: 0),
        DrumPad(key: "cp", name: "Clap", notes: [39], params: ["cp.count", "cp.space", "cp.tune", "cp.filter", "cp.tail", "cp.decay", "cp.level"], pan: 0.25,
                random: ["cp.random", "cp.tuneRandom", "cp.filterRandom", "cp.panRandom"]),
        DrumPad(key: "rs", name: "Rimshot", notes: [37], params: ["rs.tune", "rs.level"], pan: -0.3),
        DrumPad(key: "lt", name: "Low Tom", notes: [41, 43], params: ["lt.tune", "tom.decay", "tom.level"], pan: -0.5),
        DrumPad(key: "mt", name: "Mid Tom", notes: [45, 47], params: ["mt.tune", "tom.decay", "tom.level"], pan: 0),
        DrumPad(key: "ht", name: "Hi Tom", notes: [48, 50], params: ["ht.tune", "tom.decay", "tom.level"], pan: 0.5),
        DrumPad(key: "cb", name: "Cowbell", notes: [56], params: ["cb.tune", "cb.level"], pan: -0.4),
        DrumPad(key: "ch", name: "Closed Hat", notes: [42, 44], params: ["ch.decay", "hh.tone", "ch.level"], pan: 0.35),
        DrumPad(key: "oh", name: "Open Hat", notes: [46], params: ["oh.decay", "hh.tone", "oh.level"], pan: 0.35),
        DrumPad(key: "cy", name: "Cymbal", notes: [49, 51, 57], params: ["cy.tone", "cy.decay", "cy.level"], pan: -0.2),
        DrumPad(key: "cl", name: "Clave", notes: [75, 70, 54], params: ["cl.level"], pan: 0.5),
    ]

    /// The knobs of the whole kit, after the pads.
    public static let drumKitParams = ["accent", "spread", "volume"]

    /// The pad a note plays, or nil for a note the kit does not use.
    public static func drumPad(forNote note: UInt8) -> DrumPad? { drumPads.first { $0.notes.contains(note) } }

    /// The pad index (into `drumPads`) a note plays, or nil.
    public static func drumPadIndex(forNote note: UInt8) -> Int? { drumPads.firstIndex { $0.notes.contains(note) } }
}
