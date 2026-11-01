import Foundation

/// A timing and accent template, like Live's groove pool: straight, swing at several amounts, the feel of
/// known drum machines, and human feels. A groove is a pattern over one cycle of equal steps. Each step says
/// how far a note on it moves (as a fraction of the step, positive is late) and how its velocity changes.
///
/// A clip plays with a groove as a setting (`GrooveSetting`): the notes stay where they are and the engine
/// moves them when it plays. `Command.commitGroove` burns the groove into the notes.
public struct Groove: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// The family the groove sits in: "Swing 8", "Swing 16", "MPC", "Feel".
    public var group: String
    /// The step the pattern runs on, in ticks: a sixteenth for most grooves.
    public var step: Int64
    /// Per step of one cycle: the move of a note on that step, as a fraction of the step. Positive is late.
    public var timing: [Double]
    /// Per step of one cycle: the velocity change at full amount, -1...1. 1 is +64.
    public var velocity: [Double]

    public init(id: String, name: String, group: String, step: Int64, timing: [Double], velocity: [Double]) {
        self.id = id
        self.name = name
        self.group = group
        self.step = step
        self.timing = timing
        self.velocity = velocity
    }

    /// A swing: the second of every two steps moves late. `percent` is the MPC-style amount: 50 is straight,
    /// 66.7 a triplet. `accent` softens the swung step by that much velocity.
    public static func swing(id: String, name: String, group: String, step: Int64, percent: Double, accent: Double = 0) -> Groove {
        Groove(id: id, name: name, group: group, step: step, timing: [0, percent / 50 - 1], velocity: [0, -accent])
    }

    public static let straightID = "straight"
    public static func named(_ id: String) -> Groove? { all.first { $0.id == id } }

    /// The templates that come with the app, in their groups.
    public static let all: [Groove] = {
        let q = Tick.perQuarter, s16 = q / 4, s8 = q / 2
        var list: [Groove] = []
        for p in [54.0, 58, 62, 66] {
            list.append(swing(id: "swing8-\(Int(p))", name: "Swing 8 \(Int(p)) %", group: "Swing 8", step: s8, percent: p))
        }
        for p in [54.0, 58, 62, 66] {
            list.append(swing(id: "swing16-\(Int(p))", name: "Swing 16 \(Int(p)) %", group: "Swing 16", step: s16, percent: p))
        }
        // The MPC swing softens the swung sixteenth a little, the way its sequencer feels.
        for p in [54.0, 58, 62, 66] {
            list.append(swing(id: "mpc16-\(Int(p))", name: "MPC 16 Swing \(Int(p)) %", group: "Machines", step: s16, percent: p, accent: 0.12))
        }
        list.append(Groove(id: "sp1200", name: "SP-1200 16", group: "Machines", step: s16,
                           timing: [0.02, 0.14, 0.02, 0.14], velocity: [0.05, -0.1, 0, -0.1]))
        list.append(Groove(id: "tr909-shuffle", name: "909 Shuffle", group: "Machines", step: s16,
                           timing: [0, 0.2], velocity: [0, -0.06]))
        list.append(Groove(id: "triplet", name: "Triplet 16", group: "Machines", step: s16,
                           timing: [0, 1.0 / 3], velocity: [0, 0]))
        // Feels: hand-made patterns over a bar of sixteenths. Beats a little strong, off-beats softer.
        list.append(Groove(id: "human", name: "Human", group: "Feel", step: s16,
                           timing: [0, 0.03, -0.02, 0.05, -0.01, 0.04, 0.01, -0.03, 0.02, 0.06, -0.02, 0.03, 0, 0.05, -0.03, 0.02],
                           velocity: [0.15, -0.2, -0.05, -0.25, 0.1, -0.2, -0.08, -0.3, 0.12, -0.2, -0.05, -0.25, 0.08, -0.2, -0.1, -0.3]))
        list.append(Groove(id: "laid-back", name: "Laid Back", group: "Feel", step: s16,
                           timing: [0.08], velocity: [0]))
        list.append(Groove(id: "pushed", name: "Pushed", group: "Feel", step: s16,
                           timing: [-0.06], velocity: [0]))
        list.append(Groove(id: "drunk", name: "Drunk", group: "Feel", step: s16,
                           timing: [0, 0.12, -0.08, 0.18, 0, 0.1, -0.05, 0.2, 0, 0.14, -0.1, 0.16, 0, 0.1, -0.06, 0.22],
                           velocity: [0.1, -0.15, 0, -0.3, 0.15, -0.1, 0, -0.25, 0.05, -0.15, 0, -0.3, 0.12, -0.1, 0, -0.25]))
        list.append(Groove(id: "boom-bap", name: "Boom Bap", group: "Feel", step: s16,
                           timing: [0, 0.06, 0.1, 0.06, 0, 0.06, 0.1, 0.06, 0, 0.06, 0.1, 0.06, 0, 0.06, 0.1, 0.06],
                           velocity: [0.2, -0.2, -0.1, -0.25, 0.3, -0.2, -0.1, -0.25, 0.15, -0.2, -0.1, -0.25, 0.3, -0.2, -0.1, -0.25]))
        return list
    }()

    public static var groups: [String] {
        var seen: [String] = []
        for g in all where !seen.contains(g.group) { seen.append(g.group) }
        return seen
    }

    /// The notes as the groove plays them: a note moves by the timing of the step it is nearest to (scaled by
    /// `timing`, 0...1) and its velocity changes by that step's accent (scaled by `velocity`, 0...1). Notes
    /// stay inside `length`; a note that would start past the end of the clip keeps its place.
    public func apply(_ notes: [MIDINote], timing t: Double, velocity v: Double, length: Int64) -> [MIDINote] {
        guard !timing.isEmpty, step > 0 else { return notes }
        let count = Int64(timing.count)
        return notes.map { n in
            var m = n
            let index = Int(((n.tick.rawValue + step / 2) / step) % count)
            let shift = Int64((timing[index] * Double(step) * t).rounded())
            let tick = n.tick.rawValue + shift
            if tick >= 0 && tick < max(1, length) { m.tick = Tick(tick) }
            let dv = velocity.indices.contains(index) ? velocity[index] * 64 * v : 0
            m.velocity = UInt8(min(127, max(1, Int(n.velocity) + Int(dv.rounded()))))
            return m
        }
    }
}

/// A groove on a clip: which template, and how much of its timing and its accents apply.
public struct GrooveSetting: Hashable, Codable, Sendable {
    public var groove: String
    /// 0...1: how far the notes move. 1 is the full template.
    public var timing: Double
    /// 0...1: how much the accents change the velocities.
    public var velocity: Double

    public init(groove: String, timing: Double = 1, velocity: Double = 1) {
        self.groove = groove
        self.timing = min(max(timing, 0), 1)
        self.velocity = min(max(velocity, 0), 1)
    }
}

extension MIDIClip {
    /// The notes as they play: muted notes left out, the groove applied.
    public var playedNotes: [MIDINote] {
        let audible = notes.filter { !$0.muted }
        guard let g = groove, let template = Groove.named(g.groove) else { return audible }
        return template.apply(audible, timing: g.timing, velocity: g.velocity, length: length.rawValue)
    }
}
