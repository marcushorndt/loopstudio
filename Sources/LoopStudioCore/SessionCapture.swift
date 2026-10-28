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
    /// up to `now`. Arrangement clips under a captured part are cut away (the rest of them stays).
    /// A session clip loops its own length, an arrangement clip its whole source, so every pass of a
    /// looping session clip becomes its own arrangement clip.
    public func captureCommands(_ events: [SessionEvent], until now: Tick) -> [Command] {
        var inserts: [Command] = []
        var spans: [TrackID: [Range<Tick>]] = [:]
        for e in events where e.startTick < now {
            guard let t = track(e.track), t.slots.indices.contains(e.slot), let slot = t.slots[e.slot] else { continue }
            if case .dummy = slot.clip { continue }
            let end = min(e.endTick, now)
            guard end > e.startTick, slot.clip.length > 0 else { continue }
            spans[e.track, default: []].append(e.startTick..<end)
            let pass = slot.clip.length
            var at = e.startTick
            while at < end {
                inserts.append(.insertClip(track: e.track, clip: slot.clip.placed(at: at, length: min(pass, end - at), loop: slot.clip.loops)))
                if !slot.clip.loops { break }
                at = at + pass
            }
        }

        var cuts: [Command] = []
        for (id, ranges) in spans {
            guard let t = track(id) else { continue }
            let merged = Self.merge(ranges)
            for c in t.clips {
                let clipRange = c.start..<(c.start + c.length)
                guard merged.contains(where: { $0.overlaps(clipRange) }) else { continue }
                cuts.append(.removeClip(clip: c.id))
                // Keep what lies between the captured parts.
                var from = c.start
                for r in merged where r.overlaps(clipRange) {
                    if let piece = c.slice(from: from, to: r.lowerBound) { cuts.append(.insertClip(track: id, clip: piece)) }
                    from = max(from, r.upperBound)
                }
                if let piece = c.slice(from: from, to: clipRange.upperBound) { cuts.append(.insertClip(track: id, clip: piece)) }
            }
        }
        return cuts + inserts
    }

    private static func merge(_ ranges: [Range<Tick>]) -> [Range<Tick>] {
        var out: [Range<Tick>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else { out.append(r) }
        }
        return out
    }
}
