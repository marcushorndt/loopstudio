import Foundation

/// What a Session slot shows, at one moment of the session clock.
public enum SlotState: Hashable, Sendable {
    case empty
    case stopped
    /// The transport is stopped, and this clip played when it stopped: the next Play starts it again.
    case ready
    /// A launch waits for the grid.
    case queued
    case playing(progress: Double)
    /// Playing, with a stop waiting for the grid.
    case stopping(progress: Double)

    public var isQueued: Bool { self == .queued }
    public var isStopping: Bool { if case .stopping = self { true } else { false } }
    /// How far the clip is through its loop, while it plays.
    public var progress: Double? {
        switch self {
        case .playing(let p), .stopping(let p): p
        default: nil
        }
    }
}

/// The live Session of a project: the launches made since the last stop, what plays because of them,
/// and what the next Play starts after a stop.
///
/// A value with no clock and no audio: callers pass the session tick. The launch list only grows while the
/// transport runs. A stop keeps one entry per track (what played then), so the next Play starts exactly that.
/// Each launch remembers the clip it started, so a slot that moves (a scene inserted above it, an undo)
/// keeps playing the same clip.
public struct SessionPerformance: Sendable {
    /// One track's state when the transport stopped. `slot` nil: the track was stopped, so it stays silent.
    public struct Kept: Hashable, Sendable {
        public var track: TrackID
        public var slot: Int?
        /// The clip in that slot, so the choice follows the clip when its slot moves.
        public var clip: ClipID?
        /// When the clip began, on the session clock that ran before the stop.
        public var start: Tick
    }

    public private(set) var launches: [Launch] = []
    private var clips: [ClipID?] = []
    public private(set) var kept: [Kept] = []
    /// Session clock and timeline position at the stop.
    private var keptAt: (session: Tick, timeline: Tick)?
    public private(set) var simulation = SessionSimulation()
    /// The plays of each track, sorted by start, for fast lookups many times a second.
    private var byTrack: [TrackID: [SessionEvent]] = [:]

    public init() {}

    /// No launch since the last stop: the arrangement plays.
    public var isEmpty: Bool { launches.isEmpty }

    // MARK: Launches

    public mutating func add(_ launch: Launch, in project: Project) {
        launches.append(launch)
        clips.append(launch.slot.flatMap { row in
            project.track(launch.track).flatMap { row < $0.slots.count ? $0.slots[row]?.clip.id : nil }
        })
    }

    /// Forgets every launch and what a stop kept: the arrangement plays again.
    public mutating func clear() {
        launches = []
        clips = []
        kept = []
        keptAt = nil
    }

    /// After an edit: points each launch at the row where its clip is now. A clip that is gone stops.
    /// `true` when a launch changed.
    @discardableResult
    public mutating func followMovedSlots(in project: Project) -> Bool {
        var changed = false
        for (i, clip) in clips.enumerated() {
            guard let clip, i < launches.count else { continue }
            let row = project.track(launches[i].track)?.slots.firstIndex { $0?.clip.id == clip }
            if row != launches[i].slot { launches[i].slot = row; changed = true }
        }
        for (i, k) in kept.enumerated() {
            guard let clip = k.clip else { continue }
            let row = project.track(k.track)?.slots.firstIndex { $0?.clip.id == clip }
            if row != k.slot { kept[i].slot = row; changed = true }
        }
        return changed
    }

    // MARK: Plays

    /// Runs the simulator over the launches, up to `horizon` on the session clock.
    public mutating func simulate(_ project: Project, horizon: Tick) {
        var p = project
        p.launches = launches
        simulation = SessionSimulator.run(p, horizon: horizon)
        byTrack = Dictionary(grouping: simulation.events, by: \.track).mapValues { $0.sorted { $0.startTick < $1.startTick } }
    }

    /// The play of a track at `tick`, and the next one after it. Binary search in the sorted plays.
    public func plays(of track: TrackID, at tick: Tick) -> (now: SessionEvent?, next: SessionEvent?) {
        guard let events = byTrack[track], !events.isEmpty else { return (nil, nil) }
        var lo = 0, hi = events.count
        while lo < hi { let mid = (lo + hi) / 2; if events[mid].startTick <= tick { lo = mid + 1 } else { hi = mid } }
        // lo: the first play that starts after `tick`. One of the few before it may still be playing
        // (plays of one track follow each other; a stop can sit on the same tick as a start).
        let now = stride(from: lo - 1, through: max(0, lo - 4), by: -1).lazy.map { events[$0] }
            .first { $0.startTick <= tick && tick < $0.endTick }
        return (now, lo < events.count ? events[lo] : nil)
    }

    /// The track plays now, and its latest launch is a stop that has not come yet.
    public func stopPending(_ track: TrackID, at tick: Tick) -> Bool {
        guard let last = launches.last(where: { $0.track == track }), last.slot == nil, last.tick > tick else { return false }
        return plays(of: track, at: tick).now != nil
    }

    /// The slot that the next Play starts on this track, while the transport is stopped.
    public func readySlot(of track: TrackID) -> Int? {
        kept.first { $0.track == track }?.slot
    }

    public func slotState(of track: Track, row: Int, at tick: Tick, playing: Bool) -> SlotState {
        guard row < track.slots.count, let slot = track.slots[row] else { return .empty }
        if !playing { return readySlot(of: track.id) == row ? .ready : .stopped }
        let (now, next) = plays(of: track.id, at: tick)
        if let e = now, e.slot == row {
            let length = max(1, slot.clip.length.rawValue)
            let progress = Double((tick - e.startTick).rawValue % length) / Double(length)
            return stopPending(track.id, at: tick) ? .stopping(progress: progress) : .playing(progress: progress)
        }
        if let next, next.slot == row, next.cause == .launch { return .queued }
        return .stopped
    }

    // MARK: Stop and Play

    /// The transport stops at `session` (session clock) and `timeline`. Keeps what plays now on each track
    /// that has a launch; launches still waiting, and the history before, go. Otherwise the next Play,
    /// which starts the session clock at the timeline position again, would find old launches after it
    /// and play them as if they were new.
    public mutating func stop(at session: Tick, timeline: Tick, trackOrder: [TrackID]) {
        guard !launches.isEmpty else { return }
        let tracks = Set(launches.map(\.track))
        kept = trackOrder.filter(tracks.contains).map { id in
            let now = plays(of: id, at: session).now
            return Kept(track: id, slot: now?.slot, clip: now?.clip, start: now?.startTick ?? session)
        }
        keptAt = (session, timeline)
        launches = []
        clips = []
    }

    /// Play from `start` (timeline, which the session clock also starts from) after a stop: the kept clips
    /// start again, nothing else. From the same place each goes on where it was; from elsewhere each starts
    /// on the bar at or before `start`, in time with the bars. `false` when nothing was kept.
    @discardableResult
    public mutating func resume(at start: Tick, in project: Project) -> Bool {
        guard !kept.isEmpty, let at = keptAt else { return false }
        let barBefore = project.barBoundary(atOrBefore: start)
        let sameSpot = at.timeline == start
        let list = kept
        kept = []
        keptAt = nil
        for k in list {
            // A stop sits on the bar before too, so a stopped track is silent from the first frame.
            let tick = k.slot == nil || !sameSpot ? barBefore : k.start - at.session + start
            add(Launch(track: k.track, slot: k.slot, tick: tick), in: project)
        }
        return true
    }

    /// A launch while the transport is stopped starts that clip only, not what played before the stop.
    public mutating func forgetKept() {
        kept = []
        keptAt = nil
    }
}

extension Project {
    /// The last bar line at or before `tick`, using the project's time signatures.
    public func barBoundary(atOrBefore tick: Tick) -> Tick {
        let after = barBoundary(atOrAfter: tick)
        if after == tick { return tick }
        let changes = timeSignatures.sorted { $0.tick < $1.tick }
        guard let change = changes.last(where: { $0.tick <= tick }) else { return Tick(0) }
        let bar = change.signature.ticksPerBar.rawValue
        guard bar > 0 else { return tick }
        let steps = (tick.rawValue - change.tick.rawValue) / bar
        return Tick(change.tick.rawValue + steps * bar)
    }
}
