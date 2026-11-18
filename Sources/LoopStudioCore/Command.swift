import Foundation

public enum CommandError: Error, Equatable {
    case trackNotFound(TrackID)
    case clipNotFound(ClipID)
    case assetNotFound(AssetID)
    case duplicateID(String)
    case cannotChangeMaster
    case wouldCreateCycle
    case invalidRoute(String)
    case invalidValue(String)
    case assetInUse(AssetID)
    case portNotFound(PortID)
    case portInUse(PortID)
    case deviceNotFound(DeviceID)
    case chainNotFound(ChainID)
}

extension CommandError: CustomStringConvertible {
    /// The reason in plain words, for the status bar and an agent's error.
    public var description: String {
        switch self {
        case .trackNotFound: "that track no longer exists"
        case .clipNotFound: "that clip no longer exists"
        case .assetNotFound: "that sample is not in the project"
        case .duplicateID(let what): "\(what) exists already"
        case .cannotChangeMaster: "the master track cannot change this way"
        case .wouldCreateCycle: "that routing would feed a track into itself"
        case .invalidRoute(let why): "that routing is not possible: \(why)"
        case .invalidValue(let why): "that value is not possible: \(why)"
        case .assetInUse: "that sample is still in use"
        case .portNotFound: "that port no longer exists"
        case .portInUse: "that port is still in use"
        case .deviceNotFound: "that device no longer exists"
        case .chainNotFound: "that chain no longer exists"
        }
    }
}

/// Every edit to a project is a command. Commands are plain data (Codable), so the same type serves
/// undo, the crash journal, and an agent or script API.
///
/// `apply(to:)` is atomic: on a throw the project is unchanged. It returns the inverse command.
public enum Command: Codable, Sendable {
    case batch(commands: [Command])

    case insertTrack(track: Track, index: Int)
    case removeTrack(id: TrackID)
    /// Moves a track to `index` in the track list; the master stays where it is.
    case moveTrack(id: TrackID, index: Int)
    case setTrackName(id: TrackID, name: String)
    case setTrackColor(id: TrackID, colorIndex: Int)
    case setVolume(id: TrackID, db: Double)
    case setPan(id: TrackID, pan: Double)
    case setMute(id: TrackID, mute: Bool)
    case setSolo(id: TrackID, solo: Bool)
    case setOutput(id: TrackID, target: TrackID?)
    case setSends(id: TrackID, sends: [Send])
    /// Audio From another track. `nil` is the sound card ("Ext. In"). A source clears "No Input".
    case setInputTrack(id: TrackID, source: TrackID?)
    /// Audio From: No Input. The track then takes only what other tracks send to it ("Audio To").
    case setNoInput(id: TrackID, noInput: Bool)
    case setMonitor(id: TrackID, mode: MonitorMode)
    case setSendsOnly(id: TrackID, sendsOnly: Bool)

    case insertClip(track: TrackID, clip: Clip)
    case removeClip(clip: ClipID)
    case moveClip(clip: ClipID, toTrack: TrackID, start: Tick)
    case setClipRange(clip: ClipID, start: Tick, length: Tick)
    /// Replaces a clip with a changed copy (same ID, same track or slot). For edits that change several
    /// fields at once, like trimming the start.
    case setClip(clip: Clip)
    case setClipLoop(clip: ClipID, loop: Bool)
    /// Own colour of a clip. `nil` goes back to the track colour.
    case setClipColor(clip: ClipID, colorIndex: Int?)
    case setClipName(clip: ClipID, name: String)
    case setClipEnvelope(clip: ClipID, points: [AutomationPoint])
    case setPluginParams(track: TrackID, device: DeviceID, params: [PluginParam]?)
    /// Sets the envelope of one parameter on a track. Empty points remove the lane.
    case setAutomation(track: TrackID, target: ParameterAddress, points: [AutomationPoint])
    /// Sets the envelope of one parameter inside a clip (ticks relative to the clip start). Empty points remove the lane.
    /// See `Clip.lanes` for which parameters a clip can move.
    case setClipAutomation(clip: ClipID, target: ParameterAddress, points: [AutomationPoint])
    /// Unlinks the clip automation from the clip length (`length` set) or links it again (`nil`).
    case setClipAutomationLength(clip: ClipID, length: Tick?)
    /// The older name of `setClipAutomation`. It still works, for any clip.
    case setDummyAutomation(clip: ClipID, target: ParameterAddress, points: [AutomationPoint])
    /// Replaces the notes of a MIDI clip. Notes are kept sorted by time, then pitch.
    case setMIDINotes(clip: ClipID, notes: [MIDINote])
    /// Replaces the controllers, pitch bend and pressure of a MIDI clip (sustain, mod wheel, bend).
    case setMIDIControls(clip: ClipID, controls: [MIDIControlEvent])
    /// The groove a MIDI clip plays with. `nil` plays the notes straight.
    case setClipGroove(clip: ClipID, groove: GrooveSetting?)
    /// Burns the groove of a MIDI clip into its notes: they move and take their accents, the setting goes.
    case commitGroove(clip: ClipID)
    /// Gain, fades and mute of an audio clip.
    case setAudioClip(clip: ClipID, gainDb: Double, fadeInMs: Double, fadeOutMs: Double, muted: Bool)
    /// Puts a clip (with its follow actions) into a session slot, or empties the slot with `nil`.
    case setSlot(track: TrackID, index: Int, slot: SessionSlot?)

    case setTempoPoints(points: [TempoPoint])
    case setLoop(loop: LoopRegion?)
    case setRandomSeed(seed: UInt32)
    /// The fade every new audio clip gets at both ends, so a cut never clicks. 0 to 1000 ms.
    case setDefaultFade(ms: Double)
    case setAutoLoop(rule: AutoLoopRule)
    case addAsset(asset: Asset)
    /// The tempo a loop was recorded at. `nil` means unknown.
    case setAssetTempo(id: AssetID, bpm: Double?)
    /// Warp mode and markers of an audio clip. Markers pair a source frame with a tick, counted from the start of the audio.
    case setClipWarp(clip: ClipID, mode: WarpMode, markers: [WarpMarker])
    case removeAsset(id: AssetID)

    /// `index` is where the port goes; `nil` means the end.
    case addPort(port: IOPort, index: Int?)
    /// Fails while a track still uses the port.
    case removePort(id: PortID)
    case setHardwareOutput(id: TrackID, port: PortID?)
    case setAudioInput(id: TrackID, port: PortID?)
    case setMIDIInput(id: TrackID, selection: MIDIInputSelection?)
    /// The hardware destination a MIDI track sends its notes to. `nil` sends to none.
    case setMIDIOutput(id: TrackID, selection: MIDIOutputSelection?)
    /// The sound card channels an audio track records. `nil` uses the channels of the audio settings.
    case setInputChannels(id: TrackID, channels: InputChannels?)

    /// Device chain of a track. `index` nil means the end. Devices inside a rack's chain: `insertDeviceInChain`.
    /// Every other device command finds its device at any depth (a device id is unique in the project).
    case insertDevice(track: TrackID, device: DeviceSlot, index: Int?)
    /// Puts a device into a chain of a rack on the track (any depth). `index` nil means the end of the chain.
    case insertDeviceInChain(track: TrackID, chain: ChainID, device: DeviceSlot, index: Int?)
    case removeDevice(track: TrackID, device: DeviceID)
    /// Moves a device within its own list (the track's, or its chain's).
    case moveDevice(track: TrackID, device: DeviceID, to: Int)
    /// Replaces the whole device list of the track (`chain` nil) or of a chain. The devices keep their IDs:
    /// this is how devices move between chains, and how a rack is grouped or ungrouped.
    case setDevices(track: TrackID, chain: ChainID?, devices: [DeviceSlot])
    /// Sets a built-in parameter. `nil` returns it to the default. A rack's macros are "macro1"..."macro8",
    /// its chain selector "selector", all 0...127.
    case setDeviceParam(track: TrackID, device: DeviceID, key: String, value: Double?)
    case setDeviceBypass(track: TrackID, device: DeviceID, bypassed: Bool)
    /// The text of a patch device, and its name when the text names it.
    case setDeviceSource(track: TrackID, device: DeviceID, source: String?, name: String?)
    /// The track a sidechain effect listens to. `nil`: its own input.
    case setDeviceSidechain(track: TrackID, device: DeviceID, source: TrackID?)
    /// Where the sidechain taps that track: before its devices, after them, or after its mixer.
    case setDeviceSidechainTap(track: TrackID, device: DeviceID, tap: SidechainTap)

    /// Racks. `rack` is the rack device (any depth on the track).
    case addChain(track: TrackID, rack: DeviceID, chain: RackChain, index: Int?)
    case removeChain(track: TrackID, rack: DeviceID, chain: ChainID)
    case moveChain(track: TrackID, rack: DeviceID, chain: ChainID, to: Int)
    /// Name, colour, mixer and zones of a chain. Its devices stay as they are (use the device commands).
    case setChain(track: TrackID, rack: DeviceID, chain: RackChain)
    /// Adds or replaces (same id) a macro mapping. A parameter can hang on one macro only, in the whole track.
    case setMacroMapping(track: TrackID, rack: DeviceID, mapping: MacroMapping)
    case removeMacroMapping(track: TrackID, rack: DeviceID, mapping: UUID)
    case setMacroName(track: TrackID, rack: DeviceID, index: Int, name: String)

    /// Replaces the whole launch list. The list is sorted by tick and track.
    case setLaunches(launches: [Launch])
}

extension Command {
    /// Joins two commands into one batch, flattening nested batches.
    public static func combined(_ first: Command, _ second: Command) -> Command {
        func parts(_ c: Command) -> [Command] {
            if case .batch(let commands) = c { return commands }
            return [c]
        }
        return .batch(commands: parts(first) + parts(second))
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> Command {
        var working = project
        let inverse = try working.perform(self)
        project = working
        return inverse
    }
}

private let maxSlotIndex = 9_999

extension Project {
    /// Sorted by time, one point per tick (the later one wins), finite numbers only, slopes in -1...1.
    static func cleanPoints(_ points: [AutomationPoint]) throws -> [AutomationPoint] {
        guard points.allSatisfy({ $0.value.isFinite && ($0.bend?.isFinite ?? true) }) else {
            throw CommandError.invalidValue("automation value is not a number")
        }
        var byTick: [Tick: AutomationPoint] = [:]
        for var p in points where p.tick.rawValue >= 0 {
            if let b = p.bend { p.bend = b == 0 ? nil : min(max(b, -1), 1) }
            byTick[p.tick] = p
        }
        return byTick.values.sorted { $0.tick < $1.tick }
    }

    mutating func perform(_ command: Command) throws -> Command {
        switch command {
        case .batch(let commands):
            var inverses: [Command] = []
            for c in commands { inverses.append(try perform(c)) }
            return .batch(commands: inverses.reversed())

        case .insertTrack(let track, let index):
            guard track.kind != .master else { throw CommandError.cannotChangeMaster }
            guard allTracks.allSatisfy({ $0.id != track.id }) else { throw CommandError.duplicateID(track.id.description) }
            guard (0...tracks.count).contains(index) else { throw CommandError.invalidValue("track index \(index)") }
            tracks.insert(track, at: index)
            try checkRouting()
            return .removeTrack(id: track.id)

        case .moveTrack(let id, let index):
            guard id != master.id else { throw CommandError.cannotChangeMaster }
            guard let from = tracks.firstIndex(where: { $0.id == id }) else { throw CommandError.trackNotFound(id) }
            guard tracks.indices.contains(index) else { throw CommandError.invalidValue("track index \(index)") }
            let moved = tracks.remove(at: from)
            tracks.insert(moved, at: index)
            return .moveTrack(id: id, index: from)

        case .removeTrack(let id):
            guard id != master.id else { throw CommandError.cannotChangeMaster }
            guard let index = tracks.firstIndex(where: { $0.id == id }) else { throw CommandError.trackNotFound(id) }
            let removed = tracks.remove(at: index)
            var restore: [Command] = [.insertTrack(track: removed, index: index)]
            for i in tracks.indices {
                if tracks[i].output == id {
                    restore.append(.setOutput(id: tracks[i].id, target: id))
                    tracks[i].output = nil
                }
                // A sidechain that listened to the removed track falls back to its own input.
                for d in tracks[i].devices.indices where tracks[i].devices[d].sidechain == id {
                    restore.append(.setDeviceSidechain(track: tracks[i].id, device: tracks[i].devices[d].id, source: id))
                    tracks[i].devices[d].sidechain = nil
                }
                if tracks[i].sends.contains(where: { $0.target == id }) {
                    restore.append(.setSends(id: tracks[i].id, sends: tracks[i].sends))
                    tracks[i].sends.removeAll { $0.target == id }
                }
                if tracks[i].inputTrack == id {
                    restore.append(.setInputTrack(id: tracks[i].id, source: id))
                    tracks[i].inputTrack = nil
                }
            }
            if launches.contains(where: { $0.track == id }) {
                restore.append(.setLaunches(launches: launches))
                launches.removeAll { $0.track == id }
            }
            // Lanes that pointed at the track or its devices (a send to it, a dummy clip that drove it) go too.
            let devices = Set(removed.devices.map(\.id.rawValue))
            let send = "send.\(id.rawValue.uuidString)"
            restore += dropLanes { $0.node == id.rawValue || devices.contains($0.node) || $0.parameter == send }
            return .batch(commands: restore)

        case .setTrackName(let id, let name):
            let old = try withTrack(id) { t -> String in defer { t.name = name }; return t.name }
            return .setTrackName(id: id, name: old)

        case .setTrackColor(let id, let colorIndex):
            let old = try withTrack(id) { t -> Int in defer { t.colorIndex = max(0, colorIndex) }; return t.colorIndex }
            return .setTrackColor(id: id, colorIndex: old)

        case .setVolume(let id, let db):
            guard !db.isNaN else { throw CommandError.invalidValue("volume NaN") }
            let value = min(max(db, Track.dbRange.lowerBound), Track.dbRange.upperBound)
            let old = try withTrack(id) { t -> Double in defer { t.volumeDb = value }; return t.volumeDb }
            return .setVolume(id: id, db: old)

        case .setPan(let id, let pan):
            guard !pan.isNaN else { throw CommandError.invalidValue("pan NaN") }
            let value = min(max(pan, -1), 1)
            let old = try withTrack(id) { t -> Double in defer { t.pan = value }; return t.pan }
            return .setPan(id: id, pan: old)

        case .setMute(let id, let mute):
            let old = try withTrack(id) { t -> Bool in defer { t.mute = mute }; return t.mute }
            return .setMute(id: id, mute: old)

        case .setSolo(let id, let solo):
            let old = try withTrack(id) { t -> Bool in defer { t.solo = solo }; return t.solo }
            return .setSolo(id: id, solo: old)

        case .setOutput(let id, let target):
            guard id != master.id else { throw CommandError.cannotChangeMaster }
            // The master is the same as "no output".
            let normalized = target == master.id ? nil : target
            if normalized != nil, track(id)?.hardwareOutput != nil {
                throw CommandError.invalidRoute("track sends to a hardware port; clear that first")
            }
            let old = try withTrack(id) { t -> TrackID? in defer { t.output = normalized }; return t.output }
            try checkRouting()
            return .setOutput(id: id, target: old)

        case .setInputTrack(let id, let source):
            guard id != master.id else { throw CommandError.cannotChangeMaster }
            if let source {
                guard source != id else { throw CommandError.wouldCreateCycle }
                // The master as the source records the whole mix (Live: "Resampling"). It is never monitored,
                // because the track feeds the master: that would be a loop.
                guard track(source) != nil else { throw CommandError.trackNotFound(source) }
            }
            let (old, wasNoInput) = try withTrack(id) { t -> (TrackID?, Bool) in
                guard source == nil || t.kind == .audio else { throw CommandError.invalidValue("only audio tracks take an input track") }
                defer {
                    t.inputTrack = source
                    if source != nil { t.noInput = nil }
                }
                return (t.inputTrack, t.hasNoInput)
            }
            try checkRouting()
            let inverse = Command.setInputTrack(id: id, source: old)
            return source != nil && wasNoInput ? .batch(commands: [inverse, .setNoInput(id: id, noInput: true)]) : inverse

        case .setNoInput(let id, let noInput):
            guard id != master.id else { throw CommandError.cannotChangeMaster }
            let old = try withTrack(id) { t -> Bool in
                guard t.kind == .audio else { throw CommandError.invalidValue("only audio tracks have an audio input") }
                defer { t.noInput = noInput ? true : nil }
                return t.hasNoInput
            }
            return .setNoInput(id: id, noInput: old)

        case .setMonitor(let id, let mode):
            // `.auto` is stored as nil, so undo lands on the same stored value.
            let old = try withTrack(id) { t -> MonitorMode in defer { t.monitor = mode == .auto ? nil : mode }; return t.monitorMode }
            return .setMonitor(id: id, mode: old)

        case .setSendsOnly(let id, let sendsOnly):
            guard id != master.id else { throw CommandError.cannotChangeMaster }
            let old = try withTrack(id) { t -> Bool in defer { t.sendsOnly = sendsOnly ? true : nil }; return t.isSendsOnly }
            return .setSendsOnly(id: id, sendsOnly: old)

        case .setSends(let id, let sends):
            guard id != master.id else { throw CommandError.cannotChangeMaster }
            for send in sends {
                guard !send.levelDb.isNaN else { throw CommandError.invalidValue("send level NaN") }
            }
            let old = try withTrack(id) { t -> [Send] in defer { t.sends = sends }; return t.sends }
            try checkRouting()
            return .setSends(id: id, sends: old)

        case .insertClip(let trackID, let clip):
            try validate(clip)
            guard findClip(clip.id) == nil else { throw CommandError.duplicateID(clip.id.description) }
            try withTrack(trackID) { t in
                guard Self.clip(clip, fits: t.kind) else { throw CommandError.invalidValue("clip does not fit track kind") }
                t.insertSorted(clip)
            }
            return .removeClip(clip: clip.id)

        case .removeClip(let id):
            guard let (trackID, clip) = findClip(id) else { throw CommandError.clipNotFound(id) }
            try withTrack(trackID) { t in
                if let i = t.clips.firstIndex(where: { $0.id == id }) { t.clips.remove(at: i) }
                else { throw CommandError.invalidValue("clip \(id) is in a session slot; empty the slot instead") }
            }
            return .insertClip(track: trackID, clip: clip)

        case .moveClip(let id, let toTrack, let start) where start.rawValue < 0:
            throw CommandError.invalidValue("clip start \(start.rawValue)")

        case .moveClip(let id, let toTrack, let start):
            guard let (fromTrack, clip) = findClip(id) else { throw CommandError.clipNotFound(id) }
            let moved = clip.with(start: start, length: clip.length)
            try withTrack(fromTrack) { t in
                guard let i = t.clips.firstIndex(where: { $0.id == id }) else {
                    throw CommandError.invalidValue("clip \(id) is in a session slot")
                }
                t.clips.remove(at: i)
            }
            try withTrack(toTrack) { t in
                guard Self.clip(moved, fits: t.kind) else { throw CommandError.invalidValue("clip does not fit track kind") }
                t.insertSorted(moved)
            }
            return .moveClip(clip: id, toTrack: fromTrack, start: clip.start)

        case .setClipRange(let id, let start, let length) where start.rawValue < 0 || length.rawValue <= 0:
            throw CommandError.invalidValue("clip range")

        case .setClipRange(let id, let start, let length):
            guard length.rawValue > 0 else { throw CommandError.invalidValue("clip length must be positive") }
            guard let (trackID, clip) = findClip(id) else { throw CommandError.clipNotFound(id) }
            let changed = clip.with(start: start, length: length)
            try withTrack(trackID) { t in try t.replaceClip(changed) }
            return .setClipRange(clip: id, start: clip.start, length: clip.length)

        case .setClip(let clip):
            try validate(clip)
            guard let (trackID, old) = findClip(clip.id) else { throw CommandError.clipNotFound(clip.id) }
            try withTrack(trackID) { t in
                guard Self.clip(clip, fits: t.kind) else { throw CommandError.invalidValue("clip does not fit track kind") }
                try t.replaceClip(clip)
            }
            return .setClip(clip: old)

        case .setClipLoop(let id, let loop):
            guard let (trackID, clip) = findClip(id) else { throw CommandError.clipNotFound(id) }
            var changed = clip
            var old = loop
            switch clip {
            case .audio(var c): old = c.loop; c.loop = loop; changed = .audio(c)
            case .midi(var c): old = c.loop; c.loop = loop; changed = .midi(c)
            case .dummy: throw CommandError.invalidValue("a dummy clip has no loop flag")
            }
            try withTrack(trackID) { t in try t.replaceClip(changed) }
            return .setClipLoop(clip: id, loop: old)

        case .setAutomation(let trackID, let target, let points):
            let clean = try Self.cleanPoints(points)
            return try withTrack(trackID) { t in
                let old = t.automation.first { $0.target == target }?.points ?? []
                if let i = t.automation.firstIndex(where: { $0.target == target }) {
                    if clean.isEmpty { t.automation.remove(at: i) } else { t.automation[i].points = clean }
                } else if !clean.isEmpty {
                    t.automation.append(AutomationLane(target: target, points: clean))
                }
                return .setAutomation(track: trackID, target: target, points: old)
            }

        case .setClipAutomation(let id, let target, let points), .setDummyAutomation(let id, let target, let points):
            let clean = try Self.cleanPoints(points)
            guard let (trackID, found) = findClip(id) else { throw CommandError.clipNotFound(id) }
            var clip = found
            var lanes = clip.lanes
            let old = lanes.first { $0.target == target }?.points ?? []
            if let i = lanes.firstIndex(where: { $0.target == target }) {
                if clean.isEmpty { lanes.remove(at: i) } else { lanes[i].points = clean }
            } else if !clean.isEmpty {
                lanes.append(AutomationLane(target: target, points: clean))
            }
            clip.lanes = lanes
            try withTrack(trackID) { t in try t.replaceClip(clip) }
            return .setClipAutomation(clip: id, target: target, points: old)

        case .setMIDINotes(let id, let notes):
            guard let (trackID, clip) = findClip(id) else { throw CommandError.clipNotFound(id) }
            guard case .midi(var c) = clip else { throw CommandError.invalidValue("only MIDI clips have notes") }
            let old = c.notes
            c.notes = notes.sorted { ($0.tick, $0.pitch) < ($1.tick, $1.pitch) }
            try withTrack(trackID) { t in try t.replaceClip(.midi(c)) }
            return .setMIDINotes(clip: id, notes: old)

        case .setMIDIControls(let id, let controls):
            guard let (trackID, clip) = findClip(id) else { throw CommandError.clipNotFound(id) }
            guard case .midi(var c) = clip else { throw CommandError.invalidValue("only MIDI clips have controls") }
            guard controls.allSatisfy({ MIDIControlEvent.isControl(status: $0.status) && $0.tick >= 0 }) else {
                throw CommandError.invalidValue("a control is a controller, pitch bend, pressure or program change at a tick of 0 or more")
            }
            let old = c.controls
            c.controls = controls.sorted { ($0.tick, $0.status, $0.data1) < ($1.tick, $1.status, $1.data1) }
            try withTrack(trackID) { t in try t.replaceClip(.midi(c)) }
            return .setMIDIControls(clip: id, controls: old)

        case .setClipGroove(let id, let groove):
            guard let (trackID, clip) = findClip(id) else { throw CommandError.clipNotFound(id) }
            guard case .midi(var c) = clip else { throw CommandError.invalidValue("only MIDI clips have a groove") }
            if let groove, Groove.named(groove.groove) == nil { throw CommandError.invalidValue("unknown groove \(groove.groove)") }
            let old = c.groove
            c.groove = groove
            try withTrack(trackID) { t in try t.replaceClip(.midi(c)) }
            return .setClipGroove(clip: id, groove: old)

        case .commitGroove(let id):
            guard let (trackID, clip) = findClip(id) else { throw CommandError.clipNotFound(id) }
            guard case .midi(var c) = clip else { throw CommandError.invalidValue("only MIDI clips have a groove") }
            guard c.groove != nil else { throw CommandError.invalidValue("the clip has no groove") }
            let before = c
            c.notes = c.playedNotes.sorted { ($0.tick, $0.pitch) < ($1.tick, $1.pitch) }
            c.groove = nil
            try withTrack(trackID) { t in try t.replaceClip(.midi(c)) }
            return .setClip(clip: .midi(before))

        case .setClipAutomationLength(let id, let length):
            guard let (trackID, found) = findClip(id) else { throw CommandError.clipNotFound(id) }
            if case .dummy = found { throw CommandError.invalidValue("a dummy clip's automation always has the clip length") }
            if let length, length.rawValue < Tick.perQuarter / 4 { throw CommandError.invalidValue("automation length too short") }
            var clip = found
            let old = clip.automationLength
            clip.automationLength = length
            try withTrack(trackID) { t in try t.replaceClip(clip) }
            return .setClipAutomationLength(clip: id, length: old)

        case .setClipEnvelope(let id, let points):
            guard let (trackID, clip) = findClip(id) else { throw CommandError.clipNotFound(id) }
            guard case .audio(var c) = clip else { throw CommandError.invalidValue("only audio clips have a gain envelope") }
            guard points.allSatisfy({ $0.value.isFinite && $0.tick.rawValue >= 0 }) else { throw CommandError.invalidValue("envelope point") }
            let old = Command.setClipEnvelope(clip: id, points: c.gainEnvelope ?? [])
            let sorted = points.sorted { $0.tick < $1.tick }.map { p -> AutomationPoint in
                var p = p; p.value = min(max(p.value, -96), 12); return p
            }
            c.gainEnvelope = sorted.isEmpty ? nil : sorted
            try withTrack(trackID) { t in try t.replaceClip(.audio(c)) }
            return old

        case .setClipName(let id, let name):
            guard let (trackID, clip) = findClip(id) else { throw CommandError.clipNotFound(id) }
            let old = Command.setClipName(clip: id, name: clip.ownName)
            try withTrack(trackID) { t in try t.replaceClip(clip.with(name: name)) }
            return old

        case .setClipColor(let id, let colorIndex):
            guard let (trackID, clip) = findClip(id) else { throw CommandError.clipNotFound(id) }
            let old = Command.setClipColor(clip: id, colorIndex: clip.colorIndex)
            try withTrack(trackID) { t in try t.replaceClip(clip.with(colorIndex: colorIndex.map { max(0, $0) })) }
            return old

        case .setAudioClip(let id, let gainDb, let fadeIn, let fadeOut, let muted):
            guard let (trackID, clip) = findClip(id) else { throw CommandError.clipNotFound(id) }
            guard case .audio(var c) = clip else { throw CommandError.invalidValue("only audio clips have gain and fades") }
            guard gainDb.isFinite, fadeIn.isFinite, fadeOut.isFinite else { throw CommandError.invalidValue("not a number") }
            let old = Command.setAudioClip(clip: id, gainDb: c.gainDb, fadeInMs: c.fadeInMs, fadeOutMs: c.fadeOutMs, muted: c.muted)
            c.gainDb = min(max(gainDb, -96), 24)
            c.fadeInMs = min(max(fadeIn, 0), 10_000)
            c.fadeOutMs = min(max(fadeOut, 0), 10_000)
            c.muted = muted
            try withTrack(trackID) { t in try t.replaceClip(.audio(c)) }
            return old

        case .setSlot(let trackID, let index, let slot):
            guard (0...maxSlotIndex).contains(index) else { throw CommandError.invalidValue("slot index \(index)") }
            if let slot {
                try validate(slot.clip)
                try validate(slot.follow)
            }
            let existing = try withTrack(trackID) { $0.slots.indices.contains(index) ? $0.slots[index] : nil }
            if let slot {
                // The clip ID must be new, unless it is the clip that already sits in this slot.
                if let found = findClip(slot.clip.id), existing?.clip.id != slot.clip.id || found.track != trackID {
                    throw CommandError.duplicateID(slot.clip.id.description)
                }
            }
            try withTrack(trackID) { t in
                if let slot, !Self.clip(slot.clip, fits: t.kind) {
                    throw CommandError.invalidValue("clip does not fit track kind")
                }
                while t.slots.count <= index { t.slots.append(nil) }
                t.slots[index] = slot
                t.trimTrailingEmptySlots()
            }
            return .setSlot(track: trackID, index: index, slot: existing)

        case .setTempoPoints(let points):
            let old = tempoMap.points
            tempoMap = TempoMap(points: points)
            return .setTempoPoints(points: old)

        case .setLoop(let region):
            if let region, region.end <= region.start { throw CommandError.invalidValue("loop end must be after start") }
            let old = loop
            loop = region
            return .setLoop(loop: old)

        case .setRandomSeed(let seed):
            let old = randomSeed
            randomSeed = seed
            return .setRandomSeed(seed: old)

        case .setDefaultFade(let ms):
            guard ms.isFinite, (0...1000).contains(ms) else { throw CommandError.invalidValue("default fade \(ms) ms") }
            let old = defaultFadeMs
            defaultFadeMs = ms
            return .setDefaultFade(ms: old)

        case .setAutoLoop(let rule):
            guard rule.minSeconds >= 0, rule.maxSeconds >= rule.minSeconds, !rule.maxSeconds.isNaN else {
                throw CommandError.invalidValue("auto-loop limits")
            }
            let old = autoLoop
            autoLoop = rule
            return .setAutoLoop(rule: old)

        case .addAsset(let asset):
            guard assets.allSatisfy({ $0.id != asset.id }) else { throw CommandError.duplicateID(asset.id.description) }
            guard asset.frames >= 0, asset.sampleRate > 0, asset.channels > 0 else {
                throw CommandError.invalidValue("asset format")
            }
            assets.append(asset)
            return .removeAsset(id: asset.id)

        case .setAssetTempo(let id, let bpm):
            guard let i = assets.firstIndex(where: { $0.id == id }) else { throw CommandError.assetNotFound(id) }
            if let bpm { guard bpm.isFinite, (20...400).contains(bpm) else { throw CommandError.invalidValue("tempo \(bpm)") } }
            let old = assets[i].sourceTempo
            assets[i].sourceTempo = bpm
            return .setAssetTempo(id: id, bpm: old)

        case .setClipWarp(let id, let mode, let markers):
            guard let (trackID, clip) = findClip(id) else { throw CommandError.clipNotFound(id) }
            guard case .audio(var c) = clip else { throw CommandError.invalidValue("only audio clips warp") }
            guard markers.allSatisfy({ $0.sourceFrame >= 0 && $0.tick.rawValue >= 0 }) else { throw CommandError.invalidValue("warp marker") }
            let sorted = markers.sorted { $0.tick < $1.tick }
            for i in sorted.indices.dropFirst() {
                guard sorted[i].tick > sorted[i - 1].tick, sorted[i].sourceFrame > sorted[i - 1].sourceFrame else {
                    throw CommandError.invalidValue("warp markers must move forward in both time and source")
                }
            }
            let old = Command.setClipWarp(clip: id, mode: c.warpMode, markers: c.warpMarkers)
            c.warpMode = mode
            c.warpMarkers = sorted
            try withTrack(trackID) { t in try t.replaceClip(.audio(c)) }
            return old

        case .removeAsset(let id):
            guard let index = assets.firstIndex(where: { $0.id == id }) else { throw CommandError.assetNotFound(id) }
            for t in allTracks {
                let used = t.clips.contains { $0.usesAsset(id) } || t.slots.contains { $0?.clip.usesAsset(id) ?? false }
                if used { throw CommandError.assetInUse(id) }
            }
            let removed = assets.remove(at: index)
            return .addAsset(asset: removed)

        case .addPort(let port, let index):
            guard ports.allSatisfy({ $0.id != port.id }) else { throw CommandError.duplicateID(port.id.description) }
            guard (1...64).contains(port.channels), !port.name.isEmpty else { throw CommandError.invalidValue("port") }
            guard (0...ports.count).contains(index ?? ports.count) else { throw CommandError.invalidValue("port index") }
            ports.insert(port, at: index ?? ports.count)
            return .removePort(id: port.id)

        case .removePort(let id):
            guard let index = ports.firstIndex(where: { $0.id == id }) else { throw CommandError.portNotFound(id) }
            guard !usedPortIDs.contains(id) else { throw CommandError.portInUse(id) }
            return .addPort(port: ports.remove(at: index), index: index)

        case .setHardwareOutput(let id, let port):
            if let port { try requirePort(port, direction: .output) }
            let old = try withTrack(id) { t -> PortID? in
                if port != nil, t.output != nil { throw CommandError.invalidRoute("track routes to another track; clear its output first") }
                defer { t.hardwareOutput = port }
                return t.hardwareOutput
            }
            return .setHardwareOutput(id: id, port: old)

        case .setAudioInput(let id, let port):
            if let port { try requirePort(port, direction: .input) }
            let old = try withTrack(id) { t -> PortID? in
                guard port == nil || t.kind == .audio else { throw CommandError.invalidValue("only audio tracks take an audio input") }
                defer { t.audioInput = port }
                return t.audioInput
            }
            return .setAudioInput(id: id, port: old)

        case .insertDevice(let trackID, let device, let index):
            try checkNewDevice(device, on: trackID)
            return try withTrack(trackID) { t in
                let at = min(max(0, index ?? t.devices.count), t.devices.count)
                t.devices.insert(device, at: at)
                return .removeDevice(track: trackID, device: device.id)
            }

        case .insertDeviceInChain(let trackID, let chainID, let device, let index):
            try checkNewDevice(device, on: trackID)
            return try withTrack(trackID) { t in
                try t.withChain(chainID) { chain in
                    let at = min(max(0, index ?? chain.devices.count), chain.devices.count)
                    chain.devices.insert(device, at: at)
                }
                return .removeDevice(track: trackID, device: device.id)
            }

        case .removeDevice(let trackID, let id):
            var gone = Set<UUID>()
            let restore = try withTrack(trackID) { t -> Command in
                if let i = t.devices.firstIndex(where: { $0.id == id }) {
                    let removed = t.devices.remove(at: i)
                    gone = Set(removed.selfAndNested.map(\.id.rawValue) + removed.nestedChainIDs)
                    return .insertDevice(track: trackID, device: removed, index: i)
                }
                guard let chain = t.chainHolding(id) else { throw CommandError.deviceNotFound(id) }
                var removed: DeviceSlot?, at = 0
                try t.withChain(chain.id) { c in
                    at = c.devices.firstIndex { $0.id == id } ?? 0
                    removed = c.devices.remove(at: at)
                }
                gone = Set(removed!.selfAndNested.map(\.id.rawValue) + removed!.nestedChainIDs)
                return .insertDeviceInChain(track: trackID, chain: chain.id, device: removed!, index: at)
            }
            // Its automation goes with it (a rack's: everything inside), and comes back on undo. So do the
            // macro mappings of enclosing racks that pointed into it.
            var restoreMappings: [Command] = []
            try withTrack(trackID) { t in
                for rack in t.allDevices where rack.rack != nil {
                    for m in rack.rack!.mappings where gone.contains(m.target.node) {
                        restoreMappings.append(.setMacroMapping(track: trackID, rack: rack.id, mapping: m))
                    }
                    if rack.rack!.mappings.contains(where: { gone.contains($0.target.node) }) {
                        try t.withDevice(rack.id) { $0.rack?.mappings.removeAll { gone.contains($0.target.node) } }
                    }
                }
            }
            return restore.then(dropLanes { gone.contains($0.node) } + restoreMappings)

        case .moveDevice(let trackID, let id, let to):
            return try withTrack(trackID) { t in
                let chain = t.chainHolding(id)
                var from = 0
                try t.withDevices(in: chain?.id) { list in
                    guard let i = list.firstIndex(where: { $0.id == id }) else { throw CommandError.deviceNotFound(id) }
                    from = i
                    let d = list.remove(at: i)
                    list.insert(d, at: min(max(0, to), list.count))
                }
                return .moveDevice(track: trackID, device: id, to: from)
            }

        case .setDevices(let trackID, let chainID, let devices):
            // The new list may only hold devices that are new to the project or that leave this very list
            // (or any list on this track: a device may move from one chain to another).
            var old: [DeviceSlot] = []
            try withTrack(trackID) { t in
                try t.withDevices(in: chainID) { old = $0 }
            }
            let staying = Set(old.flatMap(\.selfAndNested).map(\.id))
            for d in devices {
                for inner in d.selfAndNested where !staying.contains(inner.id) {
                    if allTracks.contains(where: { $0.device(inner.id) != nil }) {
                        // It sits elsewhere on this track: fine when the caller moves it in the same batch; refuse other tracks.
                        guard track(trackID)?.device(inner.id) != nil else { throw CommandError.duplicateID(inner.id.description) }
                    }
                    if inner.format == "builtin", BuiltInEffects.spec(inner.identifier) == nil { throw CommandError.invalidValue("unknown built-in device \(inner.identifier)") }
                }
                let issues = d.rackIssues()
                if let first = issues.first { throw CommandError.invalidValue(first) }
            }
            var ids = Set<DeviceID>()
            for d in devices.flatMap(\.selfAndNested) where !ids.insert(d.id).inserted { throw CommandError.duplicateID(d.id.description) }
            try withTrack(trackID) { t in
                try t.withDevices(in: chainID) { $0 = devices }
            }
            return .setDevices(track: trackID, chain: chainID, devices: old)

        case .setDeviceParam(let trackID, let id, let key, let value):
            if let value, !value.isFinite { throw CommandError.invalidValue("not a number") }
            return try withTrack(trackID) { t in
                var old: Double?
                try t.withDevice(id) { device in
                    var value = value
                    // A key the device does not have would be stored and do nothing. Values outside the range are clamped.
                    if let spec = device.spec {
                        guard let param = spec.params.first(where: { $0.key == key }) else {
                            throw CommandError.invalidValue("\(spec.name) has no parameter \"\(key)\"; it has \(spec.params.map(\.key).joined(separator: ", "))")
                        }
                        value = value.map(param.clamp)
                    } else if let known = device.pluginParams, !known.contains(where: { $0.key == key }) {
                        throw CommandError.invalidValue("\(device.name) has no parameter \"\(key)\"")
                    }
                    old = device.params[key]
                    device.params[key] = value
                }
                return .setDeviceParam(track: trackID, device: id, key: key, value: old)
            }

        case .setPluginParams(let trackID, let id, let params):
            guard (params ?? []).allSatisfy({ $0.min.isFinite && $0.max.isFinite && $0.min <= $0.max }) else {
                throw CommandError.invalidValue("plugin parameter range")
            }
            return try withTrack(trackID) { t in
                var old: [PluginParam]?
                try t.withDevice(id) { old = $0.pluginParams; $0.pluginParams = params }
                return .setPluginParams(track: trackID, device: id, params: old)
            }

        case .setDeviceBypass(let trackID, let id, let bypassed):
            return try withTrack(trackID) { t in
                var old = false
                try t.withDevice(id) { old = $0.bypassed; $0.bypassed = bypassed }
                return .setDeviceBypass(track: trackID, device: id, bypassed: old)
            }

        case .setDeviceSource(let trackID, let id, let source, let name):
            return try withTrack(trackID) { t in
                var oldSource: String?, oldName: String?
                try t.withDevice(id) {
                    oldSource = $0.source; $0.source = source
                    if let name { oldName = $0.name; $0.name = name }
                }
                return .setDeviceSource(track: trackID, device: id, source: oldSource, name: oldName)
            }

        case .setDeviceSidechain(let trackID, let id, let source):
            if let source {
                guard source != trackID else { throw CommandError.invalidValue("a sidechain cannot listen to its own track") }
                guard let s = track(source), s.kind != .master else { throw CommandError.trackNotFound(source) }
            }
            return try withTrack(trackID) { t in
                var old: TrackID?
                try t.withDevice(id) { device in
                    guard device.format == "builtin", BuiltInEffects.spec(device.identifier)?.sidechain == true else {
                        throw CommandError.invalidValue("\(device.name) has no sidechain input")
                    }
                    old = device.sidechain
                    device.sidechain = source
                }
                return .setDeviceSidechain(track: trackID, device: id, source: old)
            }

        case .setDeviceSidechainTap(let trackID, let id, let tap):
            return try withTrack(trackID) { t in
                var old: SidechainTap = .postMixer
                try t.withDevice(id) { device in
                    guard device.format == "builtin", BuiltInEffects.spec(device.identifier)?.sidechain == true else {
                        throw CommandError.invalidValue("\(device.name) has no sidechain input")
                    }
                    old = device.tap
                    device.sidechainTap = tap
                }
                return .setDeviceSidechainTap(track: trackID, device: id, tap: old)
            }

        case .addChain(let trackID, let rackID, let chain, let index):
            guard !allTracks.contains(where: { $0.chain(chain.id) != nil }) else { throw CommandError.duplicateID(chain.id.description) }
            for d in chain.devices { try checkNewDevice(d, on: trackID) }
            return try withTrack(trackID) { t in
                try t.withDevice(rackID) { rack in
                    guard rack.rack != nil else { throw CommandError.invalidValue("\(rack.name) is not a rack") }
                    var c = chain
                    c.zone = c.zone.normalized; c.keyZone = c.keyZone?.normalized; c.velocityZone = c.velocityZone?.normalized
                    let at = min(max(0, index ?? rack.rack!.chains.count), rack.rack!.chains.count)
                    rack.rack!.chains.insert(c, at: at)
                }
                return .removeChain(track: trackID, rack: rackID, chain: chain.id)
            }

        case .removeChain(let trackID, let rackID, let chainID):
            var removed: RackChain?, at = 0
            var gone = Set<UUID>()
            try withTrack(trackID) { t in
                try t.withDevice(rackID) { rack in
                    guard let i = rack.rack?.chains.firstIndex(where: { $0.id == chainID }) else { throw CommandError.chainNotFound(chainID) }
                    at = i
                    removed = rack.rack!.chains.remove(at: i)
                }
            }
            gone = Set(removed!.devices.flatMap(\.selfAndNested).map(\.id.rawValue) + removed!.devices.flatMap(\.nestedChainIDs) + [chainID.rawValue])
            var restoreMappings: [Command] = []
            try withTrack(trackID) { t in
                for rack in t.allDevices where rack.rack != nil {
                    for m in rack.rack!.mappings where gone.contains(m.target.node) {
                        restoreMappings.append(.setMacroMapping(track: trackID, rack: rack.id, mapping: m))
                    }
                    if rack.rack!.mappings.contains(where: { gone.contains($0.target.node) }) {
                        try t.withDevice(rack.id) { $0.rack?.mappings.removeAll { gone.contains($0.target.node) } }
                    }
                }
            }
            return Command.addChain(track: trackID, rack: rackID, chain: removed!, index: at)
                .then(dropLanes { gone.contains($0.node) } + restoreMappings)

        case .moveChain(let trackID, let rackID, let chainID, let to):
            return try withTrack(trackID) { t in
                var from = 0
                try t.withDevice(rackID) { rack in
                    guard let i = rack.rack?.chains.firstIndex(where: { $0.id == chainID }) else { throw CommandError.chainNotFound(chainID) }
                    from = i
                    let c = rack.rack!.chains.remove(at: i)
                    rack.rack!.chains.insert(c, at: min(max(0, to), rack.rack!.chains.count))
                }
                return .moveChain(track: trackID, rack: rackID, chain: chainID, to: from)
            }

        case .setChain(let trackID, let rackID, let chain):
            guard chain.volumeDb.isFinite, chain.pan.isFinite else { throw CommandError.invalidValue("not a number") }
            return try withTrack(trackID) { t in
                var old: RackChain?
                try t.withDevice(rackID) { rack in
                    guard let i = rack.rack?.chains.firstIndex(where: { $0.id == chain.id }) else { throw CommandError.chainNotFound(chain.id) }
                    old = rack.rack!.chains[i]
                    var c = chain
                    c.devices = old!.devices
                    c.volumeDb = min(max(c.volumeDb, RackChain.volumeRange.lowerBound), RackChain.volumeRange.upperBound)
                    c.pan = min(max(c.pan, -1), 1)
                    c.zone = c.zone.normalized; c.keyZone = c.keyZone?.normalized; c.velocityZone = c.velocityZone?.normalized
                    rack.rack!.chains[i] = c
                }
                return .setChain(track: trackID, rack: rackID, chain: old!)
            }

        case .setMacroMapping(let trackID, let rackID, let mapping):
            guard mapping.macro >= 0, mapping.macro < Rack.macroCount else { throw CommandError.invalidValue("macro \(mapping.macro + 1) does not exist") }
            guard mapping.min.isFinite, mapping.max.isFinite, mapping.curve.isFinite else { throw CommandError.invalidValue("not a number") }
            guard let t = track(trackID) else { throw CommandError.trackNotFound(trackID) }
            guard let rack = t.device(rackID), rack.rack != nil else { throw CommandError.deviceNotFound(rackID) }
            // The target must sit inside this rack: a device in a chain (any depth), a chain of this rack, or the selector.
            let inside = Set(rack.rack!.chains.flatMap { $0.devices.flatMap(\.selfAndNested) }.map(\.id.rawValue))
            let chains = Set(rack.rack!.chains.flatMap { chain in [chain.id.rawValue] + chain.devices.flatMap(\.nestedChainIDs) })
            let target = mapping.target
            if target.node == rackID.rawValue {
                guard target.parameter == "selector" else { throw CommandError.invalidValue("a macro can drive the rack's own selector only") }
            } else if chains.contains(target.node) {
                guard target.parameter == "volume" || target.parameter == "pan" else { throw CommandError.invalidValue("a chain has volume and pan only") }
            } else if inside.contains(target.node) {
                guard automationTargets(of: t).contains(where: { $0.address == target }) else {
                    throw CommandError.invalidValue("no parameter \"\(target.parameter)\" in that device")
                }
            } else {
                throw CommandError.invalidValue("the target is not inside \(rack.name)")
            }
            // One macro per parameter, in the whole track: a knob cannot serve two masters.
            for other in t.allDevices where other.rack != nil && other.id != rackID {
                if other.rack!.mappings.contains(where: { $0.target == target }) {
                    throw CommandError.invalidValue("\(other.name) already drives that parameter")
                }
            }
            if rack.rack!.mappings.contains(where: { $0.target == target && $0.id != mapping.id }) {
                throw CommandError.invalidValue("that parameter already hangs on a macro of \(rack.name)")
            }
            return try withTrack(trackID) { t in
                var old: MacroMapping?
                try t.withDevice(rackID) { r in
                    if let i = r.rack!.mappings.firstIndex(where: { $0.id == mapping.id }) {
                        old = r.rack!.mappings[i]; r.rack!.mappings[i] = mapping
                    } else {
                        r.rack!.mappings.append(mapping)
                    }
                }
                return old.map { .setMacroMapping(track: trackID, rack: rackID, mapping: $0) }
                    ?? .removeMacroMapping(track: trackID, rack: rackID, mapping: mapping.id)
            }

        case .removeMacroMapping(let trackID, let rackID, let mappingID):
            return try withTrack(trackID) { t in
                var old: MacroMapping?
                try t.withDevice(rackID) { r in
                    guard let i = r.rack?.mappings.firstIndex(where: { $0.id == mappingID }) else { throw CommandError.invalidValue("no such mapping") }
                    old = r.rack!.mappings.remove(at: i)
                }
                return .setMacroMapping(track: trackID, rack: rackID, mapping: old!)
            }

        case .setMacroName(let trackID, let rackID, let index, let name):
            guard index >= 0, index < Rack.macroCount else { throw CommandError.invalidValue("macro \(index + 1) does not exist") }
            return try withTrack(trackID) { t in
                var old = ""
                try t.withDevice(rackID) { r in
                    guard r.rack != nil else { throw CommandError.invalidValue("\(r.name) is not a rack") }
                    while r.rack!.macroNames.count < Rack.macroCount { r.rack!.macroNames.append("") }
                    old = r.rack!.macroNames[index]
                    r.rack!.macroNames[index] = name
                }
                return .setMacroName(track: trackID, rack: rackID, index: index, name: old)
            }

        case .setLaunches(let list):
            for launch in list {
                guard track(launch.track) != nil else { throw CommandError.trackNotFound(launch.track) }
                if let slot = launch.slot, !(0...maxSlotIndex).contains(slot) { throw CommandError.invalidValue("launch slot \(slot)") }
            }
            let old = launches
            launches = list.enumerated().sorted {
                ($0.element.tick, $0.element.track.description, $0.offset) < ($1.element.tick, $1.element.track.description, $1.offset)
            }.map(\.element)
            return .setLaunches(launches: old)

        case .setMIDIInput(let id, let selection):
            let old = try withTrack(id) { t -> MIDIInputSelection? in
                guard selection == nil || t.kind == .midi else { throw CommandError.invalidValue("only MIDI tracks take a MIDI input") }
                defer { t.midiInput = selection }
                return t.midiInput
            }
            return .setMIDIInput(id: id, selection: old)

        case .setMIDIOutput(let id, let selection):
            let old = try withTrack(id) { t -> MIDIOutputSelection? in
                guard selection == nil || t.kind == .midi else { throw CommandError.invalidValue("only MIDI tracks take a MIDI output") }
                defer { t.midiOutput = selection }
                return t.midiOutput
            }
            return .setMIDIOutput(id: id, selection: old)

        case .setInputChannels(let id, let channels):
            let old = try withTrack(id) { t -> InputChannels? in
                guard channels == nil || t.kind == .audio else { throw CommandError.invalidValue("only audio tracks take input channels") }
                defer { t.inputChannels = channels }
                return t.inputChannels
            }
            return .setInputChannels(id: id, channels: old)
        }
    }

    private func requirePort(_ id: PortID, direction: PortDirection) throws {
        guard let port = ports.first(where: { $0.id == id }) else { throw CommandError.portNotFound(id) }
        guard port.direction == direction else { throw CommandError.invalidValue("port \(port.name) is an \(port.direction.rawValue) port") }
    }

    // MARK: Checks

    private func validate(_ clip: Clip) throws {
        guard clip.length.rawValue > 0 else { throw CommandError.invalidValue("clip length must be positive") }
        guard clip.start.rawValue >= 0 else { throw CommandError.invalidValue("clip start \(clip.start.rawValue)") }
        if case .audio(let audio) = clip {
            guard asset(audio.asset) != nil else { throw CommandError.assetNotFound(audio.asset) }
            guard audio.offset.rawValue >= 0 else { throw CommandError.invalidValue("clip offset") }
            guard !audio.gainDb.isNaN, audio.fadeInMs >= 0, audio.fadeOutMs >= 0,
                  audio.fadeInMs.isFinite, audio.fadeOutMs.isFinite else {
                throw CommandError.invalidValue("clip gain or fade")
            }
        }
    }

    private func validate(_ follow: FollowActions?) throws {
        guard let follow else { return }
        for action in [follow.a, follow.b] {
            guard !action.weight.isNaN, action.weight >= 0 else { throw CommandError.invalidValue("follow weight") }
            if action.kind == .jump, (action.jumpIndex ?? -1) < 0 {
                throw CommandError.invalidValue("jump needs a slot index")
            }
        }
        guard follow.time.amount >= 1 else { throw CommandError.invalidValue("follow time must be at least 1") }
    }

    /// Every route target exists and can take input; no cycles.
    private func checkRouting() throws {
        for track in tracks {
            for target in Routing.edges(of: track) {
                guard target != track.id else { throw CommandError.wouldCreateCycle }
                guard self.track(target) != nil else { throw CommandError.trackNotFound(target) }
            }
            // The output goes to a bus, or into the input of an audio track (Live: "Audio To" a track).
            if let target = track.output, let t = self.track(target), !Routing.takesOutput(t) {
                throw CommandError.invalidRoute("\(t.name) cannot take input")
            }
            for send in track.sends {
                guard let t = self.track(send.target), t.kind == .group || t.kind == .returnTrack else {
                    throw CommandError.invalidRoute("a send needs a return or group track")
                }
            }
            if Set(track.sends.map(\.target)).count != track.sends.count {
                throw CommandError.invalidRoute("two sends to the same track")
            }
        }
        if Routing.hasCycle(self) { throw CommandError.wouldCreateCycle }
    }
}

extension Command {
    /// This command, then `more`, as one undo step.
    func then(_ more: [Command]) -> Command { more.isEmpty ? self : .batch(commands: [self] + more) }
}

extension Project {
    /// A device about to join a track: new to the project, a known kind, a valid sidechain, a sound rack.
    func checkNewDevice(_ device: DeviceSlot, on trackID: TrackID) throws {
        for inner in device.selfAndNested {
            if allTracks.contains(where: { $0.device(inner.id) != nil }) { throw CommandError.duplicateID(inner.id.description) }
            if inner.format == "builtin" {
                guard let spec = BuiltInEffects.spec(inner.identifier) else { throw CommandError.invalidValue("unknown built-in device \(inner.identifier)") }
                if let source = inner.sidechain {
                    guard spec.sidechain else { throw CommandError.invalidValue("\(spec.name) has no sidechain input") }
                    guard source != trackID, source != master.id, track(source) != nil else { throw CommandError.invalidRoute("sidechain source") }
                }
            }
        }
        for chain in device.rack?.chains ?? [] where allTracks.contains(where: { $0.chain(chain.id) != nil }) {
            throw CommandError.duplicateID(chain.id.description)
        }
        if let first = device.rackIssues().first { throw CommandError.invalidValue(first) }
    }
}

extension DeviceSlot {
    /// The ids of every chain inside this device, any depth.
    public var nestedChainIDs: [UUID] {
        (rack?.chains ?? []).flatMap { chain in [chain.id.rawValue] + chain.devices.flatMap(\.nestedChainIDs) }
    }
}

extension Project {
    /// Removes every automation lane, on tracks and in clips, whose target matches. Returns the commands
    /// that put the points back, so the removal undoes with the rest of the change.
    mutating func dropLanes(_ match: (ParameterAddress) -> Bool) -> [Command] {
        var restore: [Command] = []
        for id in allTracks.map(\.id) {
            try? withTrack(id) { t in
                for lane in t.automation where match(lane.target) {
                    restore.append(.setAutomation(track: id, target: lane.target, points: lane.points))
                }
                t.automation.removeAll { match($0.target) }
                func clean(_ clip: inout Clip) {
                    let gone = clip.lanes.filter { match($0.target) }
                    guard !gone.isEmpty else { return }
                    let command: (AutomationLane) -> Command = if case .dummy = clip {
                        { [id = clip.id] in .setDummyAutomation(clip: id, target: $0.target, points: $0.points) }
                    } else {
                        { [id = clip.id] in .setClipAutomation(clip: id, target: $0.target, points: $0.points) }
                    }
                    restore += gone.map(command)
                    clip.lanes.removeAll { match($0.target) }
                }
                for i in t.clips.indices { clean(&t.clips[i]) }
                for i in t.slots.indices { if var slot = t.slots[i] { clean(&slot.clip); t.slots[i] = slot } }
            }
        }
        return restore
    }
}

extension Track {
    mutating func replaceClip(_ clip: Clip) throws {
        if let i = clips.firstIndex(where: { $0.id == clip.id }) {
            clips.remove(at: i)
            insertSorted(clip)
        } else if let i = slots.firstIndex(where: { $0?.clip.id == clip.id }), var slot = slots[i] {
            slot.clip = clip
            slots[i] = slot
        } else {
            throw CommandError.clipNotFound(clip.id)
        }
    }
}

extension Clip {
    func usesAsset(_ id: AssetID) -> Bool {
        if case .audio(let a) = self { return a.asset == id }
        return false
    }
}
