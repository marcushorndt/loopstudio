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

    /// Shape with the slope of a linear segment: `bend` -1...1 bows it; 0 is straight.
    public static func shape(_ curve: Curve, bend: Double?, _ t: Double) -> Double {
        guard curve == .linear, let bend, bend != 0 else { return shape(curve, t) }
        let x = Swift.min(Swift.max(t, 0), 1)
        let e = pow(2, 3 * Swift.min(abs(bend), 1))
        return bend > 0 ? 1 - pow(1 - x, e) : pow(x, e)
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
        return a.value + (b.value - a.value) * shape(a.curve, bend: a.bend, t)
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
        for device in track.devices where device.format != "builtin" {
            for p in device.pluginParams ?? [] {
                add(device.id.rawValue, p.key, "\(device.name) › \(p.name)", p.min, p.max, p.def, p.unit)
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

// MARK: Clip automation

extension Project {
    /// The parameters a clip can move. An audio or MIDI clip moves its own track, with mixer lanes on
    /// `ParameterAddress.ownTrack`; a dummy clip can move every parameter of the project.
    public func clipAutomationTargets(_ clip: Clip, owner: Track) -> [AutomationTarget] {
        if case .dummy = clip { return automationTargets() }
        return automationTargets(of: owner).map { t in
            var t = t
            if t.address.node == owner.id.rawValue { t.address.node = ParameterAddress.ownTrack }
            return t
        }
    }

    /// The lanes of a clip with absolute addresses, as they play. An audio or MIDI clip only moves its own
    /// track: a lane for a device that is not on that track stays in the clip but does nothing.
    public func effectiveLanes(of clip: Clip, owner: Track) -> [AutomationLane] {
        let lanes = clip.lanes.filter { !$0.points.isEmpty }
        if case .dummy = clip { return lanes }
        let devices = Set(owner.devices.map(\.id.rawValue))
        var seen = Set<ParameterAddress>()
        var result: [AutomationLane] = []
        for var lane in lanes {
            lane.target = lane.target.resolved(owner: owner.id)
            guard lane.target.node == owner.id.rawValue || devices.contains(lane.target.node), seen.insert(lane.target).inserted
            else { continue }
            result.append(lane)
        }
        return result
    }

    /// The track that holds a parameter: the track itself or the track of the device.
    public func trackOwning(_ address: ParameterAddress) -> Track? {
        allTracks.first { $0.id.rawValue == address.node || $0.devices.contains { $0.id.rawValue == address.node } }
    }

    /// The value of a parameter without automation: the fader, the knob, or the default.
    public func staticValue(_ address: ParameterAddress) -> Double? {
        guard let track = trackOwning(address) else { return nil }
        if track.id.rawValue == address.node {
            switch address.parameter {
            case "volume": return track.volumeDb
            case "pan": return track.pan
            default:
                let target = address.parameter.hasPrefix("send.") ? String(address.parameter.dropFirst(5)) : ""
                return track.sends.first { $0.target.rawValue.uuidString == target }?.levelDb
            }
        }
        if let device = track.devices.first(where: { $0.id.rawValue == address.node }), let value = device.params[address.parameter] {
            return value
        }
        return automationTargets(of: track).first { $0.address == address }?.def
    }

    /// Writes the automation of an arrangement clip into the track lanes, for the time the clip covers,
    /// and empties the clip's lanes. Outside the clip the track curves keep their values. One undo step.
    /// `nil` when the clip is not on the timeline or has no automation.
    public func clipAutomationToTrack(_ id: ClipID) -> Command? {
        guard let (trackID, clip) = findClip(id), let owner = track(trackID), owner.clips.contains(where: { $0.id == id })
        else { return nil }
        let lanes = effectiveLanes(of: clip, owner: owner)
        guard !lanes.isEmpty else { return nil }
        let s = clip.start, e = clip.start + clip.length, period = clip.automationCycle
        var commands: [Command] = []
        for lane in lanes {
            guard let host = trackOwning(lane.target), let base = staticValue(lane.target) else { continue }
            let old = host.automation.first { $0.target == lane.target }?.points ?? []
            let outside = { (tick: Tick) in AutomationMath.value(old, at: tick) ?? base }
            let inCycle = { (offset: Tick) in AutomationMath.value(lane.points, at: offset) ?? base }
            var points = old.filter { $0.tick < s }
            if s > 0 { points.append(AutomationPoint(tick: s - 1, value: outside(s - 1))) }
            // One copy of the curve per automation cycle, each held at its edges.
            var cycle = s
            while cycle < e {
                let end = min(cycle + period, e)
                points.append(AutomationPoint(tick: cycle, value: inCycle(0)))
                points += lane.points.filter { $0.tick < end - cycle }.map { var p = $0; p.tick = p.tick + cycle; return p }
                points.append(AutomationPoint(tick: end - 1, value: inCycle(end - 1 - cycle)))
                cycle = end
            }
            points.append(AutomationPoint(tick: e, value: outside(e)))
            points += old.filter { $0.tick > e }
            commands.append(.setAutomation(track: host.id, target: lane.target, points: points))
        }
        for lane in clip.lanes { commands.append(.setClipAutomation(clip: id, target: lane.target, points: [])) }
        return .batch(commands: commands)
    }
}

// MARK: Splitting

extension AutomationMath {
    /// The part of an envelope from `offset` on, with ticks counted from there. It starts with the value at `offset`.
    public static func tail(_ points: [AutomationPoint], from offset: Tick) -> [AutomationPoint] {
        guard let start = value(points, at: offset) else { return [] }
        var curve = Curve.linear, bend: Double?
        if let before = points.last(where: { $0.tick <= offset }) { curve = before.curve; bend = before.bend }
        return [AutomationPoint(tick: 0, value: start, curve: curve, bend: bend)]
            + points.filter { $0.tick > offset }.map { var p = $0; p.tick = p.tick - offset; return p }
    }

    /// A curve that repeats every `cycle`, rotated so that it starts at `offset` of the old cycle.
    public static func rotate(_ points: [AutomationPoint], by offset: Tick, cycle: Tick) -> [AutomationPoint] {
        let phase = Tick(((offset.rawValue % max(1, cycle.rawValue)) + cycle.rawValue) % max(1, cycle.rawValue))
        guard phase > 0, !points.isEmpty else { return points }
        let inCycle = points.filter { $0.tick < cycle }
        let head = tail(inCycle, from: phase).filter { $0.tick < cycle - phase }
        let end = AutomationPoint(tick: cycle - phase - 1, value: value(inCycle, at: cycle - 1) ?? 0)
        let first = inCycle.last { $0.tick <= 0 }
        let wrapped = [AutomationPoint(tick: cycle - phase, value: value(inCycle, at: 0) ?? 0, curve: first?.curve ?? .linear, bend: first?.bend)]
            + inCycle.filter { $0.tick > 0 && $0.tick < phase }.map { var p = $0; p.tick = p.tick + cycle - phase; return p }
            + [AutomationPoint(tick: cycle - 1, value: value(inCycle, at: phase - 1) ?? 0)]
        return head + [end] + wrapped
    }
}

extension Clip {
    /// The second half of a split at `head` ticks into the clip: it starts there and keeps sounding and moving
    /// as the whole clip did. Notes that cross the cut continue, envelopes and clip automation go on from the
    /// cut. The caller gives it a new ID; the first half is the old clip shortened to `head`.
    public func tail(from head: Tick) -> Clip? {
        guard head > 0, head < length else { return nil }
        var clip = self
        let rest = length - head
        func lanes(_ list: [AutomationLane]) -> [AutomationLane] {
            list.map { lane in
                var lane = lane
                lane.id = LaneID()
                if let own = automationLength { lane.points = AutomationMath.rotate(lane.points, by: head, cycle: own) }
                else { lane.points = AutomationMath.tail(lane.points, from: head) }
                return lane
            }
        }
        switch self {
        case .audio(var a):
            a.start = a.start + head; a.length = rest; a.offset = a.offset + head
            a.gainEnvelope = a.gainEnvelope.map { AutomationMath.tail($0, from: head) }
            clip = .audio(a)
        case .midi(var m):
            m.start = m.start + head; m.length = rest
            m.notes = m.notes.compactMap { n in
                let end = n.tick + n.length
                guard end > head else { return nil }
                var n = n
                if n.tick < head { n.length = end - head; n.tick = 0 } else { n.tick = n.tick - head }
                return n
            }
            clip = .midi(m)
        case .dummy(var d):
            d.start = d.start + head; d.length = rest
            clip = .dummy(d)
        }
        clip.lanes = lanes(self.lanes)
        return clip
    }
}
