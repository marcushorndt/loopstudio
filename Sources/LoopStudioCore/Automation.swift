import Foundation

/// A parameter that automation can move, with its range and a display name.
public struct AutomationTarget: Hashable, Sendable {
    public var address: ParameterAddress
    public var name: String
    public var min: Double
    public var max: Double
    public var def: Double
    public var unit: String
    public var logarithmic: Bool
    public var choices: [String]

    public init(address: ParameterAddress, name: String, min: Double, max: Double, def: Double,
                unit: String = "", logarithmic: Bool = false, choices: [String] = []) {
        self.address = address
        self.name = name
        self.min = min
        self.max = max
        self.def = def
        self.unit = unit
        self.logarithmic = logarithmic
        self.choices = choices
    }

    public func clamp(_ v: Double) -> Double { Swift.min(Swift.max(v, min), max) }

    public func position(_ v: Double) -> Double {
        let x = clamp(v)
        if logarithmic, min > 0 { return log(x / min) / log(max / min) }
        return max > min ? (x - min) / (max - min) : 0
    }

    public func value(atPosition p: Double) -> Double {
        let q = Swift.min(Swift.max(p, 0), 1)
        if logarithmic, min > 0 { return min * pow(max / min, q) }
        let v = min + q * (max - min)
        return choices.isEmpty ? v : v.rounded()
    }
}

public enum AutomationMath {
    /// Shape of a segment: 0...1 in, 0...1 out.
    public static func shape(_ curve: Curve, _ t: Double) -> Double {
        let x = Swift.min(Swift.max(t, 0), 1)
        switch curve {
        case .linear: return x
        case .hold: return 0
        case .easeIn: return x * x
        case .easeOut: return 1 - (1 - x) * (1 - x)
        case .easeInOut: return x * x * (3 - 2 * x)
        }
    }

    /// The lane value at a tick. Before the first point it holds the first value, after the last it holds the last.
    public static func value(_ points: [AutomationPoint], at tick: Tick) -> Double? {
        guard let first = points.first, let last = points.last else { return nil }
        if tick <= first.tick { return first.value }
        if tick >= last.tick { return last.value }
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].tick <= tick { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        let t = Double((tick - a.tick).rawValue) / Double(max(1, (b.tick - a.tick).rawValue))
        return a.value + (b.value - a.value) * shape(a.curve, t)
    }
}

extension Project {
    /// Everything on a track that automation can move: volume, pan, sends, and the knobs of its built-in effects.
    public func automationTargets(of track: Track) -> [AutomationTarget] {
        var list: [AutomationTarget] = []
        func add(_ node: UUID, _ key: String, _ name: String, _ lo: Double, _ hi: Double, _ def: Double, _ unit: String = "",
                 log: Bool = false, choices: [String] = []) {
            list.append(AutomationTarget(address: ParameterAddress(node: node, parameter: key), name: name, min: lo, max: hi,
                                         def: def, unit: unit, logarithmic: log, choices: choices))
        }
        add(track.id.rawValue, "volume", "Volume", -60, 6, 0, "dB")
        add(track.id.rawValue, "pan", "Pan", -1, 1, 0)
        for send in track.sends {
            if let target = self.track(send.target) {
                add(track.id.rawValue, "send.\(send.target.rawValue.uuidString)", "Send to \(target.name)", -60, 0, -60, "dB")
            }
        }
        for device in track.devices where device.format == "builtin" {
            guard let spec = BuiltInEffects.spec(device.identifier) else { continue }
            for p in spec.params {
                add(device.id.rawValue, p.key, "\(device.name) › \(p.name)", p.min, p.max, p.def, p.unit, log: p.logarithmic, choices: p.choices)
            }
        }
        return list
    }

    /// Every target in the project, for dummy clips. Names carry the track name.
    public func automationTargets() -> [AutomationTarget] {
        allTracks.flatMap { track in
            automationTargets(of: track).map { t in
                var t = t
                t.name = "\(track.name) › \(t.name)"
                return t
            }
        }
    }

    public func automationTarget(_ address: ParameterAddress) -> AutomationTarget? {
        automationTargets().first { $0.address == address }
    }
}
