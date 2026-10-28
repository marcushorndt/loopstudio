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
}

/// Every edit to a project is a command. Commands are plain data (Codable), so the same type serves
/// undo, the crash journal, and an agent or script API.
///
/// `apply(to:)` is atomic: on a throw the project is unchanged. It returns the inverse command.
public enum Command: Codable, Sendable {
    case batch(commands: [Command])

    case insertTrack(track: Track, index: Int)
    case removeTrack(id: TrackID)
    case setTrackName(id: TrackID, name: String)
    case setVolume(id: TrackID, db: Double)
    case setPan(id: TrackID, pan: Double)
    case setMute(id: TrackID, mute: Bool)
    case setSolo(id: TrackID, solo: Bool)
    case setOutput(id: TrackID, target: TrackID?)
    case setSends(id: TrackID, sends: [Send])

    case insertClip(track: TrackID, clip: Clip)
    case removeClip(clip: ClipID)
    case moveClip(clip: ClipID, toTrack: TrackID, start: Tick)
    case setClipRange(clip: ClipID, start: Tick, length: Tick)
    case setClipLoop(clip: ClipID, loop: Bool)
    /// Sets the envelope of one parameter on a track. Empty points remove the lane.
    case setAutomation(track: TrackID, target: ParameterAddress, points: [AutomationPoint])
    /// Sets the envelope of one parameter inside a dummy clip (ticks relative to the clip start).
    case setDummyAutomation(clip: ClipID, target: ParameterAddress, points: [AutomationPoint])
    /// Replaces the notes of a MIDI clip. Notes are kept sorted by time, then pitch.
    case setMIDINotes(clip: ClipID, notes: [MIDINote])
    /// Gain, fades and mute of an audio clip.
    case setAudioClip(clip: ClipID, gainDb: Double, fadeInMs: Double, fadeOutMs: Double, muted: Bool)
    /// Puts a clip (with its follow actions) into a session slot, or empties the slot with `nil`.
    case setSlot(track: TrackID, index: Int, slot: SessionSlot?)

    case setTempoPoints(points: [TempoPoint])
    case setLoop(loop: LoopRegion?)
    case setRandomSeed(seed: UInt32)
    case setAutoLoop(rule: AutoLoopRule)
    case addAsset(asset: Asset)
    case removeAsset(id: AssetID)

    /// `index` is where the port goes; `nil` means the end.
    case addPort(port: IOPort, index: Int?)
    /// Fails while a track still uses the port.
    case removePort(id: PortID)
    case setHardwareOutput(id: TrackID, port: PortID?)
    case setAudioInput(id: TrackID, port: PortID?)
    case setMIDIInput(id: TrackID, selection: MIDIInputSelection?)

    /// Device chain of a track. `index` nil means the end.
    case insertDevice(track: TrackID, device: DeviceSlot, index: Int?)
    case removeDevice(track: TrackID, device: DeviceID)
    case moveDevice(track: TrackID, device: DeviceID, to: Int)
    /// Sets a built-in parameter. `nil` returns it to the default.
    case setDeviceParam(track: TrackID, device: DeviceID, key: String, value: Double?)
    case setDeviceBypass(track: TrackID, device: DeviceID, bypassed: Bool)

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
    /// Sorted by time, one point per tick (the later one wins), finite numbers only.
    static func cleanPoints(_ points: [AutomationPoint]) throws -> [AutomationPoint] {
        guard points.allSatisfy({ $0.value.isFinite }) else { throw CommandError.invalidValue("automation value is not a number") }
        var byTick: [Tick: AutomationPoint] = [:]
        for p in points where p.tick.rawValue >= 0 { byTick[p.tick] = p }
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
                if tracks[i].sends.contains(where: { $0.target == id }) {
                    restore.append(.setSends(id: tracks[i].id, sends: tracks[i].sends))
                    tracks[i].sends.removeAll { $0.target == id }
                }
            }
            return .batch(commands: restore)

        case .setTrackName(let id, let name):
            let old = try withTrack(id) { t -> String in defer { t.name = name }; return t.name }
            return .setTrackName(id: id, name: old)

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

        case .setClipRange(let id, let start, let length):
            guard length.rawValue > 0 else { throw CommandError.invalidValue("clip length must be positive") }
            guard let (trackID, clip) = findClip(id) else { throw CommandError.clipNotFound(id) }
            let changed = clip.with(start: start, length: length)
            try withTrack(trackID) { t in try t.replaceClip(changed) }
            return .setClipRange(clip: id, start: clip.start, length: clip.length)

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
                t.automation.removeAll { $0.target == target }
                if !clean.isEmpty { t.automation.append(AutomationLane(target: target, points: clean)) }
                return .setAutomation(track: trackID, target: target, points: old)
            }

        case .setDummyAutomation(let id, let target, let points):
            let clean = try Self.cleanPoints(points)
            guard let (trackID, clip) = findClip(id) else { throw CommandError.clipNotFound(id) }
            guard case .dummy(var d) = clip else { throw CommandError.invalidValue("only dummy clips carry automation") }
            let old = d.lanes.first { $0.target == target }?.points ?? []
            d.lanes.removeAll { $0.target == target }
            if !clean.isEmpty { d.lanes.append(AutomationLane(target: target, points: clean)) }
            try withTrack(trackID) { t in try t.replaceClip(.dummy(d)) }
            return .setDummyAutomation(clip: id, target: target, points: old)

        case .setMIDINotes(let id, let notes):
            guard let (trackID, clip) = findClip(id) else { throw CommandError.clipNotFound(id) }
            guard case .midi(var c) = clip else { throw CommandError.invalidValue("only MIDI clips have notes") }
            let old = c.notes
            c.notes = notes.sorted { ($0.tick, $0.pitch) < ($1.tick, $1.pitch) }
            try withTrack(trackID) { t in try t.replaceClip(.midi(c)) }
            return .setMIDINotes(clip: id, notes: old)

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
                guard t.kind != .master else { throw CommandError.cannotChangeMaster }
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
            let exists = allTracks.contains { $0.devices.contains { $0.id == device.id } }
            guard !exists else { throw CommandError.duplicateID(device.id.description) }
            return try withTrack(trackID) { t in
                let at = min(max(0, index ?? t.devices.count), t.devices.count)
                t.devices.insert(device, at: at)
                return .removeDevice(track: trackID, device: device.id)
            }

        case .removeDevice(let trackID, let id):
            return try withTrack(trackID) { t in
                guard let i = t.devices.firstIndex(where: { $0.id == id }) else { throw CommandError.deviceNotFound(id) }
                let removed = t.devices.remove(at: i)
                return .insertDevice(track: trackID, device: removed, index: i)
            }

        case .moveDevice(let trackID, let id, let to):
            return try withTrack(trackID) { t in
                guard let i = t.devices.firstIndex(where: { $0.id == id }) else { throw CommandError.deviceNotFound(id) }
                let d = t.devices.remove(at: i)
                t.devices.insert(d, at: min(max(0, to), t.devices.count))
                return .moveDevice(track: trackID, device: id, to: i)
            }

        case .setDeviceParam(let trackID, let id, let key, let value):
            if let value, !value.isFinite { throw CommandError.invalidValue("not a number") }
            return try withTrack(trackID) { t in
                guard let i = t.devices.firstIndex(where: { $0.id == id }) else { throw CommandError.deviceNotFound(id) }
                let old = t.devices[i].params[key]
                t.devices[i].params[key] = value
                return .setDeviceParam(track: trackID, device: id, key: key, value: old)
            }

        case .setDeviceBypass(let trackID, let id, let bypassed):
            return try withTrack(trackID) { t in
                guard let i = t.devices.firstIndex(where: { $0.id == id }) else { throw CommandError.deviceNotFound(id) }
                let old = t.devices[i].bypassed
                t.devices[i].bypassed = bypassed
                return .setDeviceBypass(track: trackID, device: id, bypassed: old)
            }

        case .setLaunches(let list):
            for launch in list {
                guard let t = track(launch.track), t.kind != .master else { throw CommandError.trackNotFound(launch.track) }
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
        }
    }

    private func requirePort(_ id: PortID, direction: PortDirection) throws {
        guard let port = ports.first(where: { $0.id == id }) else { throw CommandError.portNotFound(id) }
        guard port.direction == direction else { throw CommandError.invalidValue("port \(port.name) is an \(port.direction.rawValue) port") }
    }

    // MARK: Checks

    private func validate(_ clip: Clip) throws {
        guard clip.length.rawValue > 0 else { throw CommandError.invalidValue("clip length must be positive") }
        if case .audio(let audio) = clip {
            guard asset(audio.asset) != nil else { throw CommandError.assetNotFound(audio.asset) }
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
                guard let t = self.track(target) else { throw CommandError.trackNotFound(target) }
                guard t.kind == .group || t.kind == .returnTrack || t.kind == .master else {
                    throw CommandError.invalidRoute("\(t.name) cannot take input")
                }
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
