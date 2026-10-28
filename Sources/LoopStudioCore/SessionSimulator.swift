import Foundation

/// One stretch of a session clip playing on a track.
public struct SessionEvent: Hashable, Codable, Sendable {
    public enum Cause: String, Codable, Sendable {
        /// A launch from the project's launch list.
        case launch
        /// A follow action ended the previous clip and started this one on the same tick.
        case follow
    }

    public var track: TrackID
    public var slot: Int
    public var clip: ClipID
    public var startTick: Tick
    public var endTick: Tick
    public var cause: Cause

    public init(track: TrackID, slot: Int, clip: ClipID, startTick: Tick, endTick: Tick, cause: Cause) {
        self.track = track
        self.slot = slot
        self.clip = clip
        self.startTick = startTick
        self.endTick = endTick
        self.cause = cause
    }
}

public struct SessionSimulation: Hashable, Sendable {
    public var events: [SessionEvent]
    public var warnings: [String]

    public init(events: [SessionEvent] = [], warnings: [String] = []) {
        self.events = events
        self.warnings = warnings
    }
}

extension Project {
    /// The first bar line at or after `tick`, using the project's time signatures.
    public func barBoundary(atOrAfter tick: Tick) -> Tick {
        let changes = timeSignatures.sorted { $0.tick < $1.tick }
        guard !changes.isEmpty else { return tick }
        var i = 0
        while i + 1 < changes.count, changes[i + 1].tick <= tick { i += 1 }
        let start = changes[i].tick
        let bar = changes[i].signature.ticksPerBar.rawValue
        guard bar > 0 else { return tick }
        var steps = (tick.rawValue - start.rawValue)
        steps = steps >= 0 ? (steps + bar - 1) / bar : -((-steps) / bar)
        let candidate = Tick(start.rawValue + steps * bar)
        if i + 1 < changes.count, candidate >= changes[i + 1].tick { return changes[i + 1].tick }
        return candidate
    }

    /// When a launch actually starts, after the slot's launch quantize.
    func quantizedStart(of launch: Launch) -> Tick {
        guard let index = launch.slot, let track = track(launch.track),
              track.slots.indices.contains(index), let slot = track.slots[index] else { return launch.tick }
        switch slot.quantize {
        case .none: return launch.tick
        case .beat:
            let q = Tick.perQuarter
            let r = launch.tick.rawValue
            return Tick(r >= 0 ? (r + q - 1) / q * q : -((-r) / q * q))
        case .bar: return barBoundary(atOrAfter: launch.tick)
        }
    }
}

/// Expands launches and follow actions into the exact list of what plays when.
///
/// A pure function of the project: no clock, no randomness except `FollowRandom`.
/// Offline bounce, preview, and the live engine all use these rules.
///
/// Rules:
/// - Tracks are independent. A new launch on a track ends its current clip at the launch tick and
///   cancels any follow action still waiting.
/// - A clip decides its follow action when it starts (the choice depends only on seed, clip and launch count).
/// - Follow time is counted from the clip start: `loops(n)` is n passes (a one-shot has one pass), `ticks(t)` is t ticks.
/// - A one-shot clip ends at its length even when its follow time is later; the track is then silent until the follow action.
/// - A launch and a follow action on the same tick: the launch wins.
public enum SessionSimulator {
    public static let eventLimit = 100_000
    static let chainLimit = 8

    public static func run(_ project: Project, horizon: Tick) -> SessionSimulation {
        var events: [SessionEvent] = []
        var warnings: [String] = []

        for track in project.allTracks where !track.slots.isEmpty {
            let launches = project.launches
                .filter { $0.track == track.id }
                .map { (launch: $0, at: project.quantizedStart(of: $0)) }
                .enumerated()
                .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
                .map(\.element)
            guard !launches.isEmpty else { continue }
            simulate(track, launches: launches, project: project, horizon: horizon, events: &events, warnings: &warnings)
            if events.count >= eventLimit { break }
        }
        events.sort { ($0.startTick, $0.track.description) < ($1.startTick, $1.track.description) }
        return SessionSimulation(events: events, warnings: warnings)
    }

    private struct Playing {
        var slot: Int
        var eventIndex: Int
        var followTick: Tick?
        var outcome: FollowOutcome
    }

    private static func simulate(_ track: Track, launches: [(launch: Launch, at: Tick)], project: Project, horizon: Tick,
                                 events: inout [SessionEvent], warnings: inout [String]) {
        var playing: Playing?
        var startCounts: [Int: Int] = [:]
        var next = 0
        var chainTick: Tick?
        var chainLength = 0

        func end(at tick: Tick) {
            guard let p = playing else { return }
            events[p.eventIndex].endTick = min(events[p.eventIndex].endTick, tick)
            playing = nil
        }

        func begin(slot: Int, at tick: Tick, cause: SessionEvent.Cause) {
            guard let sessionSlot = track.slots[slot] else { return }
            let clip = sessionSlot.clip
            let length = clip.length
            let loops: Bool
            switch clip {
            case .audio(let c): loops = c.loop
            case .midi(let c): loops = c.loop
            case .dummy: loops = false
            }
            let count = startCounts[slot, default: 0]
            startCounts[slot] = count + 1

            let naturalEnd = loops ? horizon : min(tick + length, horizon)
            events.append(SessionEvent(track: track.id, slot: slot, clip: clip.id, startTick: tick,
                                       endTick: naturalEnd, cause: cause))

            var followTick: Tick?
            var outcome = FollowOutcome.none
            if let follow = sessionSlot.follow {
                let random = FollowRandom(seed: project.randomSeed, clip: clip.id, launchCount: count)
                outcome = FollowResolver.resolve(current: slot, slots: track.slots, random: random)
                if outcome != .none {
                    switch follow.time.unit {
                    case .loops:
                        let passes = loops ? max(1, follow.time.amount) : 1
                        followTick = tick + Tick(length.rawValue * passes)
                    case .ticks:
                        followTick = tick + Tick(max(1, follow.time.amount))
                    }
                }
            }
            playing = Playing(slot: slot, eventIndex: events.count - 1, followTick: followTick, outcome: outcome)
        }

        while events.count < eventLimit {
            let nextLaunch = next < launches.count ? launches[next] : nil
            if let p = playing, let ft = p.followTick, ft < horizon, nextLaunch == nil || ft < nextLaunch!.at {
                switch p.outcome {
                case .none:
                    playing?.followTick = nil
                case .stop:
                    end(at: ft)
                case .play(let target):
                    end(at: ft)
                    chainLength = (chainTick == ft) ? chainLength + 1 : 0
                    chainTick = ft
                    if chainLength >= chainLimit {
                        warnings.append("track \"\(track.name)\": follow actions loop without time passing; stopped")
                        return
                    }
                    begin(slot: target, at: ft, cause: .follow)
                }
            } else if let l = nextLaunch, l.at < horizon {
                next += 1
                end(at: l.at)
                guard let slot = l.launch.slot else { continue } // a stop
                if track.slots.indices.contains(slot), track.slots[slot] != nil {
                    begin(slot: slot, at: l.at, cause: .launch)
                } else {
                    warnings.append("track \"\(track.name)\": launch of empty slot \(slot) ignored")
                }
            } else {
                break
            }
        }
        if events.count >= eventLimit { warnings.append("track \"\(track.name)\": too many events; the schedule is cut off") }
    }
}
