import Foundation

extension Clip {
    /// The clip with a new ID, at `start`, `length` long, looping or not.
    func placed(at start: Tick, length: Tick, loop: Bool) -> Clip {
        switch self {
        case .audio(var c): c.id = ClipID(); c.start = start; c.length = length; c.loop = loop; return .audio(c)
        case .midi(var c): c.id = ClipID(); c.start = start; c.length = length; c.loop = loop; return .midi(c)
        case .dummy(var c): c.id = ClipID(); c.start = start; c.length = length; return .dummy(c)
        }
    }

    /// The part of an arrangement clip inside [from, to), as a new clip, or nil when nothing is left.
    func slice(from: Tick, to: Tick) -> Clip? {
        let a = max(from, start), b = min(to, start + length)
        guard b > a else { return nil }
        let rest = a > start ? tail(from: a - start) : self
        guard let rest else { return nil }
        return rest.placed(at: a, length: b - a, loop: rest.loops)
    }

    var loops: Bool {
        switch self {
        case .audio(let c): c.loop
        case .midi(let c): c.loop
        case .dummy: false
        }
    }
}

extension Project {
    /// The commands that write a Session performance into the arrangement, at the times it played,
    /// up to `now`. From a track's first captured start, its Session part replaced the arrangement, so
    /// arrangement clips there are cut away (the rest of them stays).
    /// A session clip loops its own length, an arrangement clip its whole source, so every pass of a
    /// looping session clip becomes its own arrangement clip. Automation with its own cycle keeps its phase.
    public func captureCommands(_ events: [SessionEvent], until now: Tick) -> [Command] {
        var inserts: [Command] = []
        var firstStart: [TrackID: Tick] = [:]
        for e in events where e.startTick < now {
            // A slot that holds another clip now did not play this event.
            guard let t = track(e.track), t.slots.indices.contains(e.slot), let slot = t.slots[e.slot], slot.clip.id == e.clip else { continue }
            if case .dummy = slot.clip { continue }
            let end = min(e.endTick, now)
            guard end > e.startTick, slot.clip.length > 0 else { continue }
            firstStart[e.track] = min(firstStart[e.track] ?? e.startTick, e.startTick)
            let pass = slot.clip.length
            var at = e.startTick
            while at < end {
                var clip = slot.clip.placed(at: at, length: min(pass, end - at), loop: slot.clip.loops)
                if let cycle = slot.clip.automationLength, at > e.startTick {
                    clip.lanes = slot.clip.lanes.map { lane in
                        var lane = lane
                        lane.id = LaneID()
                        lane.points = AutomationMath.rotate(lane.points, by: at - e.startTick, cycle: cycle)
                        return lane
                    }
                }
                inserts.append(.insertClip(track: e.track, clip: clip))
                if !slot.clip.loops { break }
                at = at + pass
            }
        }

        var cuts: [Command] = []
        for (id, first) in firstStart {
            guard let t = track(id) else { continue }
            for c in t.clips where c.start < now && c.start + c.length > first {
                cuts.append(.removeClip(clip: c.id))
                if let head = c.slice(from: c.start, to: first) { cuts.append(.insertClip(track: id, clip: head)) }
                if let tail = c.slice(from: now, to: c.start + c.length) { cuts.append(.insertClip(track: id, clip: tail)) }
            }
        }
        return cuts + inserts
    }
}

extension Project {
    /// A take made into a Session slot, cut to whole bars so that it loops in time: it starts on the first
    /// bar line inside the take and keeps the whole bars after it (a bar short by at most an eighth counts).
    /// A take shorter than half a bar after that line stays as it is.
    public func barAligned(_ take: Clip) -> Clip {
        let end = take.start + take.length
        let bars = clickBeats(upTo: end + Tick(4 * 3_840)).filter(\.accent).map(\.tick)
        guard let first = bars.first(where: { $0 >= take.start }) else { return take }
        let following = bars.filter { $0 > first }
        guard let nextBar = following.first else { return take }
        let barLength = nextBar - first
        guard end - first >= Tick(barLength.rawValue / 2) else { return take }
        // The last bar line that the take reaches, give or take an eighth of a bar.
        let reach = end + Tick(barLength.rawValue / 8)
        let last = ([first] + following).last { $0 <= reach && $0 > first } ?? nextBar
        guard let clip = first > take.start ? take.tail(from: first - take.start) : take else { return take }
        return clip.placed(at: first, length: last - first, loop: clip.loops)
    }
}
