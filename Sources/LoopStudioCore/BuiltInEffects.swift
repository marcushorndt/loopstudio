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
    /// A value the plan is compiled with (a limiter's look-ahead sets its latency, which the delay compensation
    /// lines the other tracks up by). A knob turn rebuilds the plan; automation and macros cannot move it,
    /// or the compensation would be wrong between rebuilds.
    public var fixed = false

    public init(_ key: String, _ name: String, _ min: Double, _ max: Double, _ def: Double,
                unit: String = "", choices: [String] = [], log: Bool = false, fixed: Bool = false) {
        self.key = key; self.name = name; self.min = min; self.max = max; self.def = def
        self.unit = unit; self.choices = choices; self.logarithmic = log; self.fixed = fixed
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

/// A titled group of knobs on a device panel, like the sections of an instrument. `row` places it: the
/// groups of one row sit side by side, the rows under each other.
public struct EffectGroup: Sendable, Hashable {
    public var title: String
    public var keys: [String]
    public var row: Int
    /// The group shows only while the parameter `whenKey` stands at `whenValue` (the knobs of one cut
    /// procedure, of one mode). `nil`: always shown.
    public var whenKey: String?
    public var whenValue: Double = 0

    public init(_ title: String, _ keys: [String], row: Int = 0, when: (key: String, value: Double)? = nil) {
        self.title = title
        self.keys = keys
        self.row = row
        whenKey = when?.key
        whenValue = when?.value ?? 0
    }

    /// Whether the group shows for a device whose knobs stand at `params`.
    public func shown(_ params: [String: Double], spec: EffectSpec) -> Bool {
        guard let whenKey else { return true }
        return (params[whenKey] ?? spec.param(whenKey)?.def ?? 0).rounded() == whenValue
    }
}

public struct EffectSpec: Sendable, Hashable {
    public var id: String
    public var name: String
    public var params: [EffectParam]
    /// An instrument makes sound from notes and takes no audio in. It sits on a MIDI track, where the
    /// first one that is not bypassed plays; the effects after it shape its sound.
    public var isInstrument = false
    /// The knobs in titled groups. Empty: one row of knobs.
    public var groups: [EffectGroup] = []
    /// The effect can listen to another track (`DeviceSlot.sidechain`): a compressor ducks to it.
    public var sidechain = false
    /// A special panel instead of knobs: "eq" draws the curve of a multi-band EQ.
    public var view = ""
    /// Bands of a multi-band EQ. Zero for every other device.
    public var bands = 0
    /// A dynamics device reports its gain reduction in `DSPEffect.meters`; the card shows it.
    public var isDynamics: Bool { id == "compressor" || id == "limiter" || id == "multiband" }
    /// A rack: chains of devices behind macro knobs and a chain selector. See `Rack`.
    public var isRack: Bool { id == "audiorack" || id == "midirack" }

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
    /// The knobs every rack has: eight macros and the chain selector, all 0...127 like Live's.
    static func rackParams() -> [EffectParam] {
        (1...Rack.macroCount).map { EffectParam("macro\($0)", "Macro \($0)", 0, 127, 0) }
            + [EffectParam("selector", "Chain Selector", 0, 127, 0)]
    }

    /// An Audio Effect Rack: parallel chains of effects. `Rack` explains the model.
    public static let audioRack = EffectSpec(id: "audiorack", name: "Audio Effect Rack", params: rackParams(),
                                             groups: [EffectGroup("Macros 1–4", ["macro1", "macro2", "macro3", "macro4"]),
                                                      EffectGroup("Macros 5–8", ["macro5", "macro6", "macro7", "macro8"], row: 1)])

    /// A MIDI Rack (Live: Instrument Rack): chains with instruments, notes routed by key and velocity zones.
    public static let midiRack = EffectSpec(id: "midirack", name: "MIDI Rack", params: rackParams(), isInstrument: true,
                                            groups: audioRack.groups)

    public static let all: [EffectSpec] = [
        EffectSpec(id: "utility", name: "Utility", params: [
            EffectParam("gain", "Gain", -96, 24, 0, unit: "dB"),
            EffectParam("width", "Width", 0, 2, 1),
        ], groups: [EffectGroup("Gain", ["gain"]), EffectGroup("Stereo", ["width"])]),
        audioRack,
        EffectSpec(id: "filter", name: "Auto Filter", params: [
            EffectParam("type", "Type", 0, 2, 0, choices: ["Low-pass", "High-pass", "Band-pass"]),
            EffectParam("cutoff", "Cutoff", 20, 20_000, 1_000, unit: "Hz", log: true),
            EffectParam("resonance", "Resonance", 0.3, 12, 0.707),
            // The LFO moves the cutoff up and down by up to four octaves each way.
            EffectParam("lfoAmount", "LFO", 0, 1, 0),
        ] + EffectParam.synced("lfoRate", "Rate", 0.05, 20, 1, unit: "Hz", division: "1/4"),
        groups: [EffectGroup("Filter", ["type", "cutoff", "resonance"]), EffectGroup("LFO", ["lfoAmount", "lfoRate"])]),
        EffectSpec(id: "eq3", name: "Tone EQ", params: [
            EffectParam("low", "Low", -18, 18, 0, unit: "dB"),
            EffectParam("mid", "Mid", -18, 18, 0, unit: "dB"),
            EffectParam("midFreq", "Mid Freq", 200, 8_000, 1_000, unit: "Hz", log: true),
            EffectParam("high", "High", -18, 18, 0, unit: "dB"),
        ], groups: [EffectGroup("Tone", ["low", "mid", "midFreq", "high"])]),
        EffectSpec(id: "delay", name: "Delay", params: EffectParam.synced("timeMs", "Time", 1, 2_000, 375, unit: "ms", division: "1/8.", longest: "1/1") + [
            EffectParam("feedback", "Feedback", 0, 0.95, 0.4),
            EffectParam("pingPong", "Ping Pong", 0, 1, 1, choices: ["Off", "On"]),
            EffectParam("mix", "Dry/Wet", 0, 1, 0.3),
        ], groups: [EffectGroup("Delay", ["timeMs", "feedback", "pingPong"]), EffectGroup("Out", ["mix"])]),
        reverb,
        tapeEcho,
        liveCut,
        granulator,
        compressor,
        limiter,
        multiband,
    ] + (1...8).map(eq)

    /// Granulator: the sound runs into an eight-second buffer, and grains are read from a position behind the
    /// record head, each of a size and a window shape, at a rate, with a pitch and a random spread of position,
    /// pitch and pan. Freeze stops the recording: the buffer stands still and the position reads through it like
    /// a tape head. The display shows the buffer scrolling by, the read position (drag it) and the grains.
    static let granulator: EffectSpec = {
        var spec = EffectSpec(id: "granulator", name: "Granulator", params: [
            EffectParam("record", "Record", 0, 1, 1, choices: ["Freeze", "Record"]),
            EffectParam("position", "Position", 0, 1, 0.25),
            EffectParam("feedback", "Feedback", 0, 0.9, 0),
            EffectParam("sizeMs", "Size", 2, 2_000, 120, unit: "ms", log: true),
            EffectParam("density", "Density", 0.5, 100, 16, unit: "/s", log: true),
            EffectParam("window", "Window", 0, 5, 0, choices: ["Hann", "Triangle", "Box", "Gauss", "Decay", "Attack"]),
            EffectParam("sprayMs", "Spray", 0, 2_000, 0, unit: "ms"),
            EffectParam("pitch", "Pitch", -24, 24, 0, unit: "st"),
            EffectParam("pitchSpread", "Pitch Rnd", 0, 24, 0, unit: "st"),
            EffectParam("reverse", "Reverse", 0, 1, 0),
            EffectParam("panSpread", "Pan Rnd", 0, 1, 0.3),
            EffectParam("level", "Level", -24, 12, 0, unit: "dB"),
            EffectParam("mix", "Dry/Wet", 0, 1, 1),
        ])
        spec.view = "granulator"
        spec.groups = [EffectGroup("Buffer", ["record", "position", "feedback"]), EffectGroup("Grain", ["sizeMs", "density", "window", "sprayMs"]),
                       EffectGroup("Pitch", ["pitch", "pitchSpread", "reverse"], row: 1), EffectGroup("Out", ["panSpread", "level", "mix"], row: 1)]
        return spec
    }()

    /// Live Cut: a breakbeat cutter on the sound that runs through it, after Livecut (Rémy Muller) and the
    /// BBCut library (Nick Collins). The bar is divided into units; a cut procedure groups units into blocks
    /// of cuts, and blocks into phrases that end in a fill. The first cut of a block is the live sound, the
    /// repeats replay it, each with its own level, pan and pitch from the ranges here. Three procedures:
    /// CutProc11 (Collins's classic: odd-length cuts, repeats, a stutter at the end of a phrase), WarpCut
    /// (regular rolls and accelerating or slowing ones) and SQPusher (Squarepusher's drum programming: busy
    /// semiquavers by activity, and a fill template on the last bar of a phrase).
    static let liveCut: EffectSpec = {
        func stepped(_ key: String, _ name: String, _ names: [String], def: Int) -> EffectParam {
            var p = EffectParam(key, name, 0, Double(names.count - 1), Double(def), choices: names)
            p.rotary = true
            return p
        }
        var spec = EffectSpec(id: "livecut", name: "Live Cut", params: [
            EffectParam("proc", "Cut Proc", 0, 2, 0, choices: ["CutProc11", "WarpCut", "SQPusher"]),
            stepped("subdiv", "Subdiv", ["6", "8", "12", "16", "18", "24", "32"], def: 1),
            stepped("seed", "Seed", (1...16).map(String.init), def: 0),
            EffectParam("fadeMs", "Fade", 0, 100, 0, unit: "ms"),
            EffectParam("mix", "Dry/Wet", 0, 1, 1),
            EffectParam("minAmp", "Min Amp", 0, 1, 1),
            EffectParam("maxAmp", "Max Amp", 0, 1, 1),
            EffectParam("minPan", "Min Pan", -1, 1, -0.2),
            EffectParam("maxPan", "Max Pan", -1, 1, 0.2),
            EffectParam("minPitch", "Min Pitch", -2_400, 2_400, 0, unit: "ct"),
            EffectParam("maxPitch", "Max Pitch", -2_400, 2_400, 0, unit: "ct"),
            stepped("minPhrase", "Min Phrase", (1...8).map { "\($0) bar" }, def: 0),
            stepped("maxPhrase", "Max Phrase", (1...8).map { "\($0) bar" }, def: 3),
            EffectParam("duty", "Duty", 0, 1, 1),
            EffectParam("fillDuty", "Fill Duty", 0, 1, 1),
            stepped("minRep", "Min Rep", (1...5).map(String.init), def: 0),
            stepped("maxRep", "Max Rep", (1...5).map(String.init), def: 1),
            EffectParam("stutter", "Stutter", 0, 1, 0.8),
            EffectParam("area", "Area", 0, 1, 0.5),
            EffectParam("straight", "Straight", 0, 1, 0.3),
            EffectParam("regular", "Regular", 0, 1, 0.5),
            EffectParam("ritard", "Ritard", 0, 1, 0.5),
            EffectParam("speed", "Speed", 0.5, 0.999, 0.9),
            EffectParam("activity", "Activity", 0, 1, 0.5),
        ])
        spec.groups = [
            EffectGroup("Cutter", ["proc", "subdiv", "seed", "fadeMs", "mix"]),
            EffectGroup("Random", ["minAmp", "maxAmp", "minPan", "maxPan", "minPitch", "maxPitch"]),
            EffectGroup("Phrase", ["minPhrase", "maxPhrase"], row: 1),
            EffectGroup("Duty", ["duty", "fillDuty"], row: 1),
            EffectGroup("CutProc11", ["minRep", "maxRep", "stutter", "area"], row: 1, when: ("proc", 0)),
            EffectGroup("WarpCut", ["straight", "regular", "ritard", "speed"], row: 1, when: ("proc", 1)),
            EffectGroup("SQPusher", ["activity"], row: 1, when: ("proc", 2)),
        ]
        return spec
    }()

    /// Band types of the multi-band EQs, in the order of the "type" choice.
    public static let eqTypes = ["Low Cut", "Low Shelf", "Bell", "Notch", "High Shelf", "High Cut", "Band Pass"]

    /// EQ One to EQ Eight (ids "peq1"..."peq8"): the same EQ with one to eight bands, so a track that needs
    /// one bell does not pay for eight. ("eq3" is the older fixed three-knob Tone EQ.) Every band has a type, a frequency, a gain and a Q, and can be off. The bands start as bells
    /// spread over the spectrum, flat: a new EQ changes nothing until a band moves.
    static func eq(bands n: Int) -> EffectSpec {
        var params: [EffectParam] = []
        for i in 1...n {
            // Log-spaced from 80 Hz to 8 kHz; one band sits at 1 kHz.
            let f = n == 1 ? 1_000.0 : 80 * pow(100, Double(i - 1) / Double(n - 1))
            params.append(EffectParam("b\(i).on", "On", 0, 1, 1, choices: ["Off", "On"]))
            params.append(EffectParam("b\(i).type", "Type", 0, Double(eqTypes.count - 1), 2, choices: eqTypes))
            params.append(EffectParam("b\(i).freq", "Freq", 10, 22_000, (f * 10).rounded() / 10, unit: "Hz", log: true))
            params.append(EffectParam("b\(i).gain", "Gain", -24, 24, 0, unit: "dB"))
            params.append(EffectParam("b\(i).q", "Q", 0.1, 18, 0.71, log: true))
        }
        params.append(EffectParam("gain", "Output", -24, 24, 0, unit: "dB"))
        let names = ["One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight"]
        var spec = EffectSpec(id: "peq\(n)", name: "EQ \(names[n - 1])", params: params)
        spec.view = "eq"
        spec.bands = n
        return spec
    }

    /// A reverb (Freeverb layout): the room's size sets how long the tail rings, the damping how fast its highs
    /// die. The wet sound passes a low cut and a high cut, so a room can sit under or over the dry sound.
    /// Freeze holds the tail as it is: nothing new goes in, nothing decays.
    static let reverb: EffectSpec = {
        var spec = EffectSpec(id: "reverb", name: "Reverb", params:
            EffectParam.synced("preDelayMs", "Pre-Delay", 0, 500, 0, unit: "ms", division: "1/32", longest: "1/4", log: false) + [
            EffectParam("size", "Size", 0, 1, 0.6),
            EffectParam("damping", "Damping", 0, 1, 0.5),
            EffectParam("freeze", "Freeze", 0, 1, 0, choices: ["Off", "On"]),
            EffectParam("lowCut", "Low Cut", 20, 2_000, 20, unit: "Hz", log: true),
            EffectParam("highCut", "High Cut", 1_000, 20_000, 20_000, unit: "Hz", log: true),
            EffectParam("mix", "Dry/Wet", 0, 1, 0.25),
        ])
        spec.groups = [EffectGroup("Room", ["preDelayMs", "size", "damping"]), EffectGroup("Filter", ["lowCut", "highCut"]),
                       EffectGroup("Hold", ["freeze"], row: 1), EffectGroup("Out", ["mix"], row: 1)]
        return spec
    }()

    /// A tape echo: a delay with the tape's wow and flutter, its tone (the loop loses highs and lows with
    /// every pass), its saturation, and a feedback that can run away into self-oscillation (the saturation
    /// keeps it in check). The time runs free or follows the tempo in note values.
    static let tapeEcho: EffectSpec = {
        var spec = EffectSpec(id: "tapeEcho", name: "Tape Echo", params:
            EffectParam.synced("timeMs", "Time", 10, 2_000, 375, unit: "ms", division: "1/8.", longest: "1/1") + [
            EffectParam("feedback", "Feedback", 0, 1.2, 0.45),
            EffectParam("wow", "Wow", 0, 1, 0.25),
            EffectParam("flutter", "Flutter", 0, 1, 0.15),
            EffectParam("tone", "Tone", 500, 16_000, 4_500, unit: "Hz", log: true),
            EffectParam("lowCut", "Low Cut", 20, 800, 120, unit: "Hz", log: true),
            EffectParam("drive", "Saturation", 0, 1, 0.3),
            EffectParam("spread", "Spread", 0, 1, 0.2),
            EffectParam("mix", "Dry/Wet", 0, 1, 0.3),
        ])
        spec.groups = [EffectGroup("Tape", ["timeMs", "feedback", "spread"]), EffectGroup("Motor", ["wow", "flutter"]),
                       EffectGroup("Tone", ["tone", "lowCut", "drive"], row: 1), EffectGroup("Out", ["mix"], row: 1)]
        return spec
    }()

    /// A compressor with a soft knee, a parallel mix, and a sidechain: its own input, or another track
    /// (`DeviceSlot.sidechain`), through a low cut, so a kick on the sidechain ducks a bass without the bass's
    /// own lows pumping it.
    static let compressor: EffectSpec = {
        var spec = EffectSpec(id: "compressor", name: "Compressor", params: [
            EffectParam("threshold", "Threshold", -60, 0, -18, unit: "dB"),
            EffectParam("ratio", "Ratio", 1, 20, 4),
            EffectParam("knee", "Knee", 0, 24, 6, unit: "dB"),
            EffectParam("attack", "Attack", 0.1, 100, 10, unit: "ms", log: true),
            EffectParam("release", "Release", 10, 1_000, 120, unit: "ms", log: true),
            EffectParam("scLowCut", "SC Low Cut", 20, 2_000, 20, unit: "Hz", log: true),
            EffectParam("makeup", "Makeup", 0, 24, 0, unit: "dB"),
            EffectParam("mix", "Dry/Wet", 0, 1, 1),
        ])
        spec.groups = [EffectGroup("Detect", ["threshold", "ratio", "knee"]), EffectGroup("Time", ["attack", "release"]),
                       EffectGroup("Sidechain", ["scLowCut"], row: 1), EffectGroup("Out", ["makeup", "mix"], row: 1)]
        spec.sidechain = true
        return spec
    }()

    /// A brick-wall limiter: the look-ahead sees a peak before it arrives, so the gain is down when it comes.
    static let limiter: EffectSpec = {
        var spec = EffectSpec(id: "limiter", name: "Limiter", params: [
            EffectParam("gain", "Gain", 0, 24, 0, unit: "dB"),
            EffectParam("ceiling", "Ceiling", -12, 0, -0.3, unit: "dB"),
            EffectParam("lookahead", "Lookahead", 0, 10, 2, unit: "ms", fixed: true),
            EffectParam("release", "Release", 10, 500, 80, unit: "ms", log: true),
        ])
        spec.groups = [EffectGroup("Limit", ["gain", "ceiling"]), EffectGroup("Time", ["lookahead", "release"])]
        return spec
    }()

    /// A three-band compressor: Linkwitz-Riley crossovers split the sound, each band has its own compressor,
    /// and the bands add up flat when nothing compresses. The sidechain, own or another track, is split the
    /// same way, so a band reacts to its own range of the sidechain.
    static let multiband: EffectSpec = {
        func band(_ key: String, _ name: String, threshold: Double) -> [EffectParam] {
            [EffectParam("\(key).threshold", "Threshold", -60, 0, threshold, unit: "dB"),
             EffectParam("\(key).ratio", "Ratio", 1, 20, 3),
             EffectParam("\(key).attack", "Attack", 0.1, 100, key == "low" ? 20 : key == "mid" ? 10 : 3, unit: "ms", log: true),
             EffectParam("\(key).release", "Release", 10, 1_000, key == "low" ? 200 : key == "mid" ? 120 : 60, unit: "ms", log: true),
             // After the band's compression: its make-up.
             EffectParam("\(key).gain", "Makeup", -12, 12, 0, unit: "dB"),
             // Solo: hear this band alone (the display's S buttons). Not a knob.
             EffectParam("\(key).solo", "Solo", 0, 1, 0, choices: ["Off", "On"])]
        }
        var spec = EffectSpec(id: "multiband", name: "Multiband Compressor", params: [
            EffectParam("lowX", "Low / Mid", 40, 1_000, 200, unit: "Hz", log: true),
            EffectParam("highX", "Mid / High", 1_000, 12_000, 2_500, unit: "Hz", log: true),
        ] + band("low", "Low", threshold: -20) + band("mid", "Mid", threshold: -18) + band("high", "High", threshold: -16) + [
            EffectParam("scLowCut", "SC Low Cut", 20, 2_000, 20, unit: "Hz", log: true),
            EffectParam("makeup", "Output", 0, 24, 0, unit: "dB"),
            EffectParam("mix", "Dry/Wet", 0, 1, 1),
        ])
        spec.groups = [EffectGroup("Crossover", ["lowX", "highX"]),
                       EffectGroup("Low", ["low.threshold", "low.ratio", "low.attack", "low.release", "low.gain"]),
                       EffectGroup("Mid", ["mid.threshold", "mid.ratio", "mid.attack", "mid.release", "mid.gain"]),
                       EffectGroup("High", ["high.threshold", "high.ratio", "high.attack", "high.release", "high.gain"], row: 1),
                       EffectGroup("Sidechain · Out", ["scLowCut", "makeup", "mix"], row: 1)]
        spec.sidechain = true
        return spec
    }()

    /// The spec of a built-in device: an effect from `all` or an instrument from `BuiltInInstruments.all`.
    public static func spec(_ id: String) -> EffectSpec? {
        all.first { $0.id == id } ?? BuiltInInstruments.all.first { $0.id == id }
    }

    public static func makeSlot(_ id: String) -> DeviceSlot? {
        guard let s = spec(id) else { return nil }
        var slot = DeviceSlot(format: "builtin", identifier: id, name: s.name)
        // A new rack starts with one empty chain, so a dropped device has a place to go.
        if s.isRack { slot.rack = Rack(chains: [RackChain(name: "Chain 1")]) }
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
        // A white noise layer over the body: its own high-pass and its own tail.
        EffectParam("cp.noise", "Noise", 0, 1, 0.35),
        EffectParam("cp.noiseFilter", "Noise HP", 200, 10_000, 3_000, unit: "Hz", log: true),
        EffectParam("cp.noiseDecay", "Noise Tail", 20, 3_000, 250, unit: "ms", log: true),
        EffectParam("cp.level", "Level", -24, 6, 0, unit: "dB"),
        EffectParam("cp.random", "Timing", 0, 1, 0.2),
        EffectParam("cp.shape", "Shape", 0, 1, 0.5),
        EffectParam("cp.tuneRandom", "Tune", 0, 1, 0.15),
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

    public static let all: [EffectSpec] = [acid, drums, BuiltInEffects.midiRack]

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
        /// A second group of knobs beside the first, with its own title. Empty for most pads.
        public var moreTitle: String = ""
        public var more: [String] = []
    }

    /// The pads in display order: four per row, three rows.
    public static let drumPads: [DrumPad] = [
        DrumPad(key: "bd", name: "Kick", notes: [36, 35], params: ["bd.tune", "bd.decay", "bd.tone", "bd.level"], pan: 0),
        DrumPad(key: "sd", name: "Snare", notes: [38, 40], params: ["sd.tune", "sd.snappy", "sd.decay", "sd.level"], pan: 0),
        DrumPad(key: "cp", name: "Clap", notes: [39],
                params: ["cp.count", "cp.space", "cp.tune", "cp.filter", "cp.level"], pan: 0.25,
                random: ["cp.random", "cp.shape", "cp.tuneRandom", "cp.filterRandom", "cp.panRandom"],
                moreTitle: "Tail · Noise", more: ["cp.tail", "cp.decay", "cp.noise", "cp.noiseFilter", "cp.noiseDecay"]),
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
