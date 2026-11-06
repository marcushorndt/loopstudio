import Foundation

/// The type of a port. Cables join equal types; `control` also goes into `audio` (a knob into a cutoff).
/// `event`, `clock` and `data` are reserved for the later stages (`docs/patcher.md` §2).
public enum PortType: String, Codable, Sendable, CaseIterable {
    case audio, control, event, clock, data

    public static func connects(_ from: PortType, to: PortType) -> Bool {
        from == to || (from == .control && to == .audio)
    }
}

/// A port of a module kind. An input without a cable takes `def`; on the panel it is a knob from `min` to `max`.
/// `unit`: "" plain, "Hz", "s", "ms", "dB", or "note" (a note value; the stored value is the index into
/// `NoteDivision.all`).
public struct ModulePort: Sendable, Hashable, Codable {
    public var name: String
    public var type: PortType
    public var def: Double = 0
    public var min: Double = 0
    public var max: Double = 1
    public var unit: String = ""
    public var log = false

    public init(_ name: String, _ type: PortType = .audio, def: Double = 0, min: Double = 0, max: Double = 1, unit: String = "", log: Bool = false) {
        self.name = name; self.type = type; self.def = def; self.min = min; self.max = max; self.unit = unit; self.log = log
    }

    public var isNote: Bool { unit == "note" }
}

/// A text setting of a module kind with its choices (an oscillator's shape).
public struct ModuleSetting: Sendable, Hashable {
    public var key: String
    public var choices: [String]
    public var def: String
    public init(_ key: String, _ choices: [String], def: String) { self.key = key; self.choices = choices; self.def = def }
}

/// What a module kind is: its ports, its settings, and the words for the palette and an agent.
public struct ModuleSpec: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var category: String
    public var help: String
    public var inputs: [ModulePort]
    public var outputs: [ModulePort]
    public var settings: [ModuleSetting] = []
    /// Numeric settings with their defaults (a knob's `min`, `max`, `def`, `log`; a delay's `length` in seconds).
    public var numbers: [String: Double] = [:]
    /// One per patch: the device's own ports.
    public var single = false
    /// A display: it shows a value and has no output.
    public var display = false

    public init(_ id: String, _ name: String, category: String, help: String, inputs: [ModulePort] = [], outputs: [ModulePort] = [],
                settings: [ModuleSetting] = [], numbers: [String: Double] = [:], single: Bool = false, display: Bool = false) {
        self.id = id; self.name = name; self.category = category; self.help = help
        self.inputs = inputs; self.outputs = outputs; self.settings = settings; self.numbers = numbers
        self.single = single; self.display = display
    }
}

/// The module kinds of stage 2: the device's ports, the VM's ops, the panel items, and the Script.
public enum PatchModules {
    static let shapes = ModuleSetting("shape", ["sine", "saw", "square", "tri"], def: "sine")
    static let audioIn = ModulePort("in", .audio)
    static let audioOut = ModulePort("out", .audio)
    static func hz(_ name: String, _ def: Double) -> ModulePort { ModulePort(name, .audio, def: def, min: 20, max: 20_000, unit: "Hz", log: true) }
    static func ms(_ name: String, _ def: Double, max: Double = 2000) -> ModulePort { ModulePort(name, .audio, def: def, min: 0, max: max, unit: "ms") }

    public static let all: [ModuleSpec] = [
        // I/O
        ModuleSpec("in", "Audio In", category: "I/O", help: "The sound that comes into the device.", outputs: [audioOut], single: true),
        ModuleSpec("out", "Audio Out", category: "I/O", help: "The sound the device gives out. A patch needs one.", inputs: [audioIn], single: true),
        ModuleSpec("clock", "Clock", category: "I/O", help: "The song: the beat count, the position inside the bar (0 to 1) and the tempo.",
                   outputs: [ModulePort("beat", .control), ModulePort("bar", .control), ModulePort("tempo", .control)], single: true),
        // Panel
        ModuleSpec("knob", "Knob", category: "Panel", help: "A value to turn: a knob on the panel. Set its range, default and unit in the inspector.",
                   outputs: [ModulePort("out", .control)], numbers: ["min": 0, "max": 1, "def": 0.5, "log": 0]),
        ModuleSpec("toggle", "Toggle", category: "Panel", help: "A switch on the panel: 0 or 1.", outputs: [ModulePort("out", .control)], numbers: ["def": 0]),
        ModuleSpec("meter", "Meter", category: "Panel", help: "Shows the level of its input on the panel. At most four per patch.", inputs: [audioIn], display: true),
        // Generate
        ModuleSpec("osc", "Oscillator", category: "Generate", help: "A waveform at a frequency, -1 to 1.", inputs: [hz("freq", 440)], outputs: [audioOut], settings: [shapes]),
        ModuleSpec("lfo", "LFO", category: "Generate", help: "A slow waveform at a rate in Hz, 0 to 1.",
                   inputs: [ModulePort("rate", .audio, def: 2, min: 0.01, max: 50, unit: "Hz", log: true)], outputs: [audioOut], settings: [shapes]),
        ModuleSpec("lfosync", "LFO (synced)", category: "Generate", help: "A slow waveform locked to the song at a note value, 0 to 1.",
                   inputs: [ModulePort("rate", .audio, def: Double(NoteDivision.index("1/4")), unit: "note")], outputs: [audioOut], settings: [shapes]),
        ModuleSpec("phase", "Phase", category: "Generate", help: "The position inside a note value, 0 to 1, on the song clock.",
                   inputs: [ModulePort("note", .audio, def: Double(NoteDivision.index("1/4")), unit: "note")], outputs: [audioOut]),
        ModuleSpec("noise", "Noise", category: "Generate", help: "White noise, -1 to 1.", outputs: [audioOut]),
        ModuleSpec("const", "Number", category: "Generate", help: "A fixed number.", outputs: [ModulePort("out", .control)], numbers: ["value": 1]),
        // Filter
        ModuleSpec("lp", "Low-pass", category: "Filter", help: "A state-variable low-pass. q from 0 to 1.", inputs: [audioIn, hz("cutoff", 1000), ModulePort("q", .audio, def: 0.2)], outputs: [audioOut]),
        ModuleSpec("hp", "High-pass", category: "Filter", help: "A state-variable high-pass.", inputs: [audioIn, hz("cutoff", 200), ModulePort("q", .audio, def: 0.2)], outputs: [audioOut]),
        ModuleSpec("bp", "Band-pass", category: "Filter", help: "A state-variable band-pass.", inputs: [audioIn, hz("cutoff", 1000), ModulePort("q", .audio, def: 0.5)], outputs: [audioOut]),
        // Shape
        ModuleSpec("slew", "Slew", category: "Shape", help: "Limits how fast the input rises and falls: a smoother.", inputs: [audioIn, ms("up", 10), ms("down", 100)], outputs: [audioOut]),
        ModuleSpec("follow", "Envelope", category: "Shape", help: "The envelope of the input's level, with attack and release times.", inputs: [audioIn, ms("attack", 10), ms("release", 100)], outputs: [audioOut]),
        ModuleSpec("sah", "Sample & Hold", category: "Shape", help: "Holds the input each time the trigger rises above 0.5.", inputs: [audioIn, ModulePort("trigger", .audio)], outputs: [audioOut]),
        ModuleSpec("tanh", "Saturate", category: "Shape", help: "Soft clipping: tanh of the input.", inputs: [audioIn], outputs: [audioOut]),
        ModuleSpec("clip", "Clip", category: "Shape", help: "Hard clipping between lo and hi.", inputs: [audioIn, ModulePort("lo", .audio, def: -1, min: -1, max: 1), ModulePort("hi", .audio, def: 1, min: -1, max: 1)], outputs: [audioOut]),
        // Delay
        ModuleSpec("delay", "Delay", category: "Delay", help: "A delay line with feedback. The time in ms, the feedback from 0 to 0.95. Its length is the longest time it holds.",
                   inputs: [audioIn, ModulePort("time", .audio, def: 250, min: 1, max: 2000, unit: "ms", log: true), ModulePort("feedback", .audio, def: 0.3, min: 0, max: 0.95)],
                   outputs: [audioOut], numbers: ["length": 2]),
        ModuleSpec("delaysync", "Delay (synced)", category: "Delay", help: "A delay line at a note value, with feedback. Holds up to 8 seconds.",
                   inputs: [audioIn, ModulePort("time", .audio, def: Double(NoteDivision.index("1/8")), unit: "note"), ModulePort("feedback", .audio, def: 0.3, min: 0, max: 0.95)],
                   outputs: [audioOut], numbers: ["length": 8]),
        // Math
        ModuleSpec("add", "Add", category: "Math", help: "a + b", inputs: [ModulePort("a"), ModulePort("b")], outputs: [audioOut]),
        ModuleSpec("sub", "Subtract", category: "Math", help: "a - b", inputs: [ModulePort("a"), ModulePort("b")], outputs: [audioOut]),
        ModuleSpec("mul", "Multiply", category: "Math", help: "a × b: a VCA, a ring modulator.", inputs: [ModulePort("a"), ModulePort("b", def: 1)], outputs: [audioOut]),
        ModuleSpec("div", "Divide", category: "Math", help: "a / b (0 when b is 0).", inputs: [ModulePort("a"), ModulePort("b", def: 1)], outputs: [audioOut]),
        ModuleSpec("min", "Min", category: "Math", help: "The smaller of a and b.", inputs: [ModulePort("a"), ModulePort("b")], outputs: [audioOut]),
        ModuleSpec("max", "Max", category: "Math", help: "The larger of a and b.", inputs: [ModulePort("a"), ModulePort("b")], outputs: [audioOut]),
        ModuleSpec("pow", "Power", category: "Math", help: "a to the power b.", inputs: [ModulePort("a"), ModulePort("b", def: 2)], outputs: [audioOut]),
        ModuleSpec("gt", "Greater", category: "Math", help: "1 when a is greater than b, else 0: a gate from a comparison.", inputs: [ModulePort("a"), ModulePort("b")], outputs: [audioOut]),
        ModuleSpec("lt", "Less", category: "Math", help: "1 when a is less than b, else 0.", inputs: [ModulePort("a"), ModulePort("b")], outputs: [audioOut]),
        ModuleSpec("mix", "Crossfade", category: "Math", help: "From a (t = 0) to b (t = 1).", inputs: [ModulePort("a"), ModulePort("b"), ModulePort("t", def: 0.5)], outputs: [audioOut]),
        ModuleSpec("router", "Router", category: "Route",
                   help: "The input goes to one of four outputs. 'to' picks it: 0 = a, 1 = b, 2 = c, 3 = d (rounded). A toggle on 'to' switches between a and b.",
                   inputs: [audioIn, ModulePort("to", .audio, def: 0, min: 0, max: 3)],
                   outputs: [ModulePort("a"), ModulePort("b"), ModulePort("c"), ModulePort("d")]),
        ModuleSpec("selector", "Selector", category: "Route",
                   help: "One of four inputs goes to the output. 'from' picks it: 0 = a, 1 = b, 2 = c, 3 = d (rounded). A Crossfade blends instead.",
                   inputs: [ModulePort("a"), ModulePort("b"), ModulePort("c"), ModulePort("d"), ModulePort("from", .audio, def: 0, min: 0, max: 3)],
                   outputs: [audioOut]),
        ModuleSpec("gate", "Gate", category: "Route", help: "The input passes while 'open' is above 0.5, else silence. A toggle or a comparison opens it.",
                   inputs: [audioIn, ModulePort("open", .audio, def: 1)], outputs: [audioOut]),
        ModuleSpec("counter", "Counter", category: "Route",
                   help: "Counts each rise of the trigger above 0.5: 0, 1, … steps-1, then 0 again. 'reset' above 0.5 holds it at 0. A Phase or a square LFO as the trigger steps a Router or a Selector in time.",
                   inputs: [ModulePort("trigger", .audio), ModulePort("steps", .audio, def: 4, min: 1, max: 16), ModulePort("reset", .audio)],
                   outputs: [audioOut]),
        ModuleSpec("gain", "Gain", category: "Math", help: "The input scaled by a level in dB.", inputs: [audioIn, ModulePort("db", .audio, def: 0, min: -60, max: 24, unit: "dB")], outputs: [audioOut]),
        ModuleSpec("scale", "Scale", category: "Math", help: "Maps the input from one range to another: 0..1 from a knob to 200..2000 for a cutoff.",
                   inputs: [audioIn, ModulePort("from", .audio, def: 0, min: -1, max: 1), ModulePort("to", .audio, def: 1, min: -1, max: 1),
                            ModulePort("lo", .audio, def: 0, min: -20_000, max: 20_000), ModulePort("hi", .audio, def: 1, min: -20_000, max: 20_000)], outputs: [audioOut]),
        ModuleSpec("neg", "Negate", category: "Math", help: "-input", inputs: [audioIn], outputs: [audioOut]),
        ModuleSpec("abs", "Absolute", category: "Math", help: "|input|", inputs: [audioIn], outputs: [audioOut]),
        ModuleSpec("sqrt", "Square root", category: "Math", help: "√input", inputs: [audioIn], outputs: [audioOut]),
        ModuleSpec("sin", "Sine", category: "Math", help: "sin(input)", inputs: [audioIn], outputs: [audioOut]),
        ModuleSpec("exp", "Exp", category: "Math", help: "e to the input", inputs: [audioIn], outputs: [audioOut]),
        ModuleSpec("log", "Log", category: "Math", help: "The natural logarithm of the input.", inputs: [audioIn], outputs: [audioOut]),
        ModuleSpec("floor", "Floor", category: "Math", help: "The input rounded down: a quantizer with a scale before it.", inputs: [audioIn], outputs: [audioOut]),
        // Script
        ModuleSpec("script", "Script", category: "Script", help: "A text in the patch language. Its in, out and param lines are its ports; param lines are knobs on the panel.",
                   inputs: [audioIn], outputs: [audioOut]),
    ]

    public static let categories = ["I/O", "Panel", "Generate", "Filter", "Shape", "Delay", "Route", "Math", "Script"]

    public static func spec(_ kind: String) -> ModuleSpec? { all.first { $0.id == kind } }

    /// The ports of a module as placed: a Script's come from its text, the others from the kind.
    public static func ports(of module: PatchModule) -> (inputs: [ModulePort], outputs: [ModulePort]) {
        guard let spec = spec(module.kind) else { return ([], []) }
        guard module.kind == "script" else { return (spec.inputs, spec.outputs) }
        guard let shape = try? PatchCompiler.shape(of: module.source ?? "") else { return (spec.inputs, spec.outputs) }
        var inputs = [ModulePort(shape.input, .audio)]
        for p in shape.params {
            inputs.append(ModulePort(p.key, .control, def: p.def, min: p.min, max: p.max, unit: p.isNote ? "note" : p.unit, log: p.log))
        }
        return (inputs, [ModulePort(shape.output ?? "out", .audio)])
    }

    /// The knob of an input that has no cable, on the panel. Its key is `module.port`; a Script's param keeps
    /// its own name as the key, so automation and MIDI learn on a text patch survive the move to a graph.
    /// The compiler prefixes a key that is taken already.
    public static func param(_ module: PatchModule, _ port: ModulePort) -> EffectParam {
        let title = port.name.prefix(1).uppercased() + port.name.dropFirst()
        let key = module.kind == "script" ? port.name : "\(module.id).\(port.name)"
        if port.isNote {
            var p = EffectParam(key, title, 0, Double(NoteDivision.all.count - 1), port.def, choices: NoteDivision.all.map(\.name))
            p.rotary = true
            return p
        }
        return EffectParam(key, title, port.min, port.max, port.def, unit: port.unit, log: port.log)
    }

    /// The knob a Knob or Toggle module is.
    public static func ownParam(_ module: PatchModule) -> EffectParam? {
        let label = module.label ?? module.id
        switch module.kind {
        case "knob":
            let min = module.values["min"] ?? 0, max = module.values["max"] ?? 1
            let def = Swift.min(Swift.max(module.values["def"] ?? 0.5, Swift.min(min, max)), Swift.max(min, max))
            let unit = module.settings["unit"] ?? ""
            if unit == "note" {
                var p = EffectParam(module.id, label, 0, Double(NoteDivision.all.count - 1), def, choices: NoteDivision.all.map(\.name))
                p.rotary = true
                return p
            }
            return EffectParam(module.id, label, min, max, def, unit: unit, log: (module.values["log"] ?? 0) > 0.5 && min > 0 && max > min)
        case "toggle":
            return EffectParam(module.id, label, 0, 1, module.values["def"] ?? 0, choices: ["Off", "On"])
        default:
            return nil
        }
    }

    /// The name shown for a module.
    public static func label(_ module: PatchModule) -> String {
        if module.kind == "knob" || module.kind == "toggle" { return module.label ?? module.id }
        return module.label ?? spec(module.kind)?.name ?? module.kind
    }
}
