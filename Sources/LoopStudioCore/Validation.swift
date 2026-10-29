import Foundation

public enum Routing {
    /// Tracks that `track` feeds: its output and its send targets. The master has no outgoing edge.
    public static func edges(of track: Track) -> [TrackID] {
        var result = track.sends.map(\.target)
        if let output = track.output { result.append(output) }
        return result
    }

    /// Tracks that `track` feeds: its output and sends, and every track that takes it as input.
    public static func feeds(of track: Track, in project: Project) -> [TrackID] {
        edges(of: track) + project.tracks.filter { $0.inputTrack == track.id }.map(\.id)
    }

    /// True if the routing graph has a cycle (a track feeding itself, directly or through others).
    public static func hasCycle(_ project: Project) -> Bool {
        enum Mark { case visiting, done }
        var marks: [TrackID: Mark] = [:]
        let byID = Dictionary(project.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        func visit(_ id: TrackID) -> Bool {
            switch marks[id] {
            case .done: return false
            case .visiting: return true
            case nil: break
            }
            marks[id] = .visiting
            if let track = byID[id] {
                for next in feeds(of: track, in: project) where visit(next) { return true }
            }
            marks[id] = .done
            return false
        }
        return project.tracks.contains { visit($0.id) }
    }
}

public enum ProjectIssue: Hashable, Sendable, CustomStringConvertible {
    case duplicateTrackID(TrackID)
    case duplicateClipID(ClipID)
    case clipMissingAsset(ClipID, AssetID)
    case clipWrongTrackKind(ClipID, TrackID)
    case clipNotPositive(ClipID)
    case routeTargetMissing(from: TrackID, to: TrackID)
    case routeTargetWrongKind(from: TrackID, to: TrackID)
    case routeCycle
    case masterWrongKind
    case invalidLoop
    case slotsEndWithEmpty(TrackID)
    case portMissing(track: TrackID, port: PortID)
    case portWrongDirection(track: TrackID, port: PortID)
    case outputConflict(TrackID)
    case inputWrongTrackKind(TrackID)
    case duplicatePortID(PortID)
    case launchTrackMissing(TrackID)
    case inputTrackMissing(track: TrackID, source: TrackID)

    public var description: String {
        switch self {
        case .duplicateTrackID(let id): "duplicate track ID \(id)"
        case .duplicateClipID(let id): "duplicate clip ID \(id)"
        case .clipMissingAsset(let clip, let asset): "clip \(clip) uses missing asset \(asset)"
        case .clipWrongTrackKind(let clip, let track): "clip \(clip) does not fit the kind of track \(track)"
        case .clipNotPositive(let id): "clip \(id) has no length"
        case .routeTargetMissing(let from, let to): "track \(from) routes to missing track \(to)"
        case .routeTargetWrongKind(let from, let to): "track \(from) routes to \(to), which cannot take input"
        case .routeCycle: "routing has a cycle"
        case .masterWrongKind: "master track has the wrong kind"
        case .invalidLoop: "loop region is empty or reversed"
        case .slotsEndWithEmpty(let id): "session slots of track \(id) end with an empty slot"
        case .portMissing(let track, let port): "track \(track) uses missing port \(port)"
        case .portWrongDirection(let track, let port): "track \(track) uses port \(port) in the wrong direction"
        case .outputConflict(let id): "track \(id) has both an output track and a hardware output"
        case .inputWrongTrackKind(let id): "track \(id) has an input that does not fit its kind"
        case .duplicatePortID(let id): "duplicate port ID \(id)"
        case .launchTrackMissing(let id): "a launch points at missing track \(id)"
        case .inputTrackMissing(let track, let source): "track \(track) takes input from missing track \(source)"
        }
    }
}

extension Project {
    /// Checks every invariant the commands keep. A project built only through commands has no issues.
    /// A loaded file can have issues; the loader reports them.
    public func validate() -> [ProjectIssue] {
        var issues: [ProjectIssue] = []
        if master.kind != .master { issues.append(.masterWrongKind) }
        if let loop, loop.end <= loop.start { issues.append(.invalidLoop) }

        var trackIDs = Set<TrackID>()
        var clipIDs = Set<ClipID>()
        for track in allTracks {
            if !trackIDs.insert(track.id).inserted { issues.append(.duplicateTrackID(track.id)) }
        }
        let assetIDs = Set(assets.map(\.id))

        func check(_ clip: Clip, on track: Track) {
            if !clipIDs.insert(clip.id).inserted { issues.append(.duplicateClipID(clip.id)) }
            if clip.length.rawValue <= 0 { issues.append(.clipNotPositive(clip.id)) }
            if !Self.clip(clip, fits: track.kind) { issues.append(.clipWrongTrackKind(clip.id, track.id)) }
            if case .audio(let audio) = clip, !assetIDs.contains(audio.asset) {
                issues.append(.clipMissingAsset(clip.id, audio.asset))
            }
        }

        for track in allTracks {
            for clip in track.clips { check(clip, on: track) }
            for case let slot? in track.slots { check(slot.clip, on: track) }
            if track.slots.last == .some(nil) { issues.append(.slotsEndWithEmpty(track.id)) }
            for target in Routing.edges(of: track) {
                guard let t = self.track(target) else {
                    issues.append(.routeTargetMissing(from: track.id, to: target))
                    continue
                }
                if t.kind != .group && t.kind != .returnTrack && t.kind != .master {
                    issues.append(.routeTargetWrongKind(from: track.id, to: target))
                }
            }
        }
        if Routing.hasCycle(self) { issues.append(.routeCycle) }

        for t in allTracks { if let s = t.inputTrack, track(s) == nil { issues.append(.inputTrackMissing(track: t.id, source: s)) } }
        for launch in launches where track(launch.track) == nil { issues.append(.launchTrackMissing(launch.track)) }

        var portIDs = Set<PortID>()
        for port in ports where !portIDs.insert(port.id).inserted { issues.append(.duplicatePortID(port.id)) }
        func check(_ port: PortID?, on track: Track, expect direction: PortDirection) {
            guard let port else { return }
            guard let found = ports.first(where: { $0.id == port }) else {
                issues.append(.portMissing(track: track.id, port: port))
                return
            }
            if found.direction != direction { issues.append(.portWrongDirection(track: track.id, port: port)) }
        }
        for track in allTracks {
            check(track.hardwareOutput, on: track, expect: .output)
            check(track.audioInput, on: track, expect: .input)
            if track.hardwareOutput != nil, track.output != nil { issues.append(.outputConflict(track.id)) }
            if track.audioInput != nil, track.kind != .audio { issues.append(.inputWrongTrackKind(track.id)) }
            if track.midiInput != nil, track.kind != .midi { issues.append(.inputWrongTrackKind(track.id)) }
            if track.midiOutput != nil, track.kind != .midi { issues.append(.inputWrongTrackKind(track.id)) }
        }
        return issues
    }

    /// Audio clips live on audio tracks, MIDI clips on MIDI tracks. Dummy clips fit any track but the master.
    static func clip(_ clip: Clip, fits kind: TrackKind) -> Bool {
        switch clip {
        case .audio: kind == .audio
        case .midi: kind == .midi
        case .dummy: kind != .master
        }
    }
}
