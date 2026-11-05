import Foundation
import LoopStudioCore

/// What the store did for one tool call. The receipt is built from the project before and after the
/// change, never from the arguments: the read-back is the truth, whatever the caller claimed.
public struct Receipt: Codable, Sendable, Hashable {
    public struct Change: Codable, Sendable, Hashable {
        /// Where, in the words of the screen: "Drums › Delay › Feedback".
        public var path: String
        public var before: String?
        public var after: String?

        public init(path: String, before: String? = nil, after: String? = nil) {
            self.path = path
            self.before = before
            self.after = after
        }

        /// One line: "Drums › Delay › Feedback: 0.35 to 0.55".
        public var line: String {
            switch (before, after) {
            case let (b?, a?) where b == a: "\(path): \(a) (unchanged)"
            case let (b?, a?): "\(path): \(b) to \(a)"
            case let (nil, a?): "\(path): \(a)"
            case let (b?, nil): "\(path): \(b) removed"
            case (nil, nil): path
            }
        }
    }

    /// The command kind, "setTrackName".
    public var command: String
    public var revisionBefore: Int
    public var revisionAfter: Int
    public var changes: [Change]

    public init(command: String, revisionBefore: Int, revisionAfter: Int, changes: [Change]) {
        self.command = command
        self.revisionBefore = revisionBefore
        self.revisionAfter = revisionAfter
        self.changes = changes
    }

    /// The first line for a card.
    public var summary: String { changes.first?.line ?? command }

    public var json: JSONValue { (try? JSONValue(encoding: self)) ?? .object(["command": .string(command)]) }
}

/// The project before and after one applied command, with the revisions.
public struct AppliedChange: Sendable {
    public var before: Project
    public var after: Project
    public var revisionBefore: Int
    public var revisionAfter: Int

    public init(before: Project, after: Project, revisionBefore: Int, revisionAfter: Int) {
        self.before = before
        self.after = after
        self.revisionBefore = revisionBefore
        self.revisionAfter = revisionAfter
    }

    public func receipt(for command: Command) -> Receipt {
        Receipt(command: command.kind, revisionBefore: revisionBefore, revisionAfter: revisionAfter,
                changes: ReadBack.changes(for: command, before: before, after: after))
    }
}

public extension EditSession {
    /// Applies a command and reads the project back. The default reads before and after around `apply`;
    /// a session that can do it in one step (the app, on the main actor) overrides it.
    func applied(_ command: Command, coalescingKey: String? = nil) async throws -> AppliedChange {
        let before = try await project()
        let revisionBefore = await revision()
        try await apply(command, coalescingKey: coalescingKey)
        return AppliedChange(before: before, after: try await project(), revisionBefore: revisionBefore, revisionAfter: await revision())
    }

    /// Applies and returns the receipt as the tool result.
    func receipt(_ command: Command, coalescingKey: String? = nil, extra: [String: JSONValue] = [:]) async throws -> JSONValue {
        let change = try await applied(command, coalescingKey: coalescingKey)
        var o: [String: JSONValue] = ["receipt": change.receipt(for: command).json]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }
}

public extension Command {
    /// "setTrackName", "batch", from the case label.
    var kind: String { Mirror(reflecting: self).children.first?.label ?? "\(self)" }

    /// Removes something undo must bring back: a track, a clip, a device, an asset, or all notes of a clip.
    var isDestructive: Bool {
        switch self {
        case .removeTrack, .removeClip, .removeDevice, .removeAsset, .removeChain, .removePort: true
        case .setMIDINotes(_, let notes): notes.isEmpty
        case .setDevices(_, _, let devices): devices.isEmpty
        case .setSlot(_, _, let slot): slot == nil
        case .batch(let commands): commands.contains { $0.isDestructive }
        default: false
        }
    }
}

/// Reads the touched values back from the project after a command.
public enum ReadBack {
    public static func changes(for command: Command, before: Project, after: Project) -> [Receipt.Change] {
        var out: [Receipt.Change] = []
        let b = Reader(before), a = Reader(after)
        func pair(_ path: String, _ x: String?, _ y: String?) { out.append(.init(path: path, before: x, after: y)) }

        switch command {
        case .batch(let commands):
            for c in commands { out += changes(for: c, before: before, after: after) }
        case .insertTrack, .removeTrack:
            pair("tracks", b.trackList, a.trackList)
        case .setTrackName(let id, _):
            pair("\(b.trackName(id)) › name", b.trackName(id), a.trackName(id))
        case .setTrackColor(let id, _):
            pair("\(a.trackName(id)) › color", b.track(id).map { "\($0.colorIndex)" }, a.track(id).map { "\($0.colorIndex)" })
        case .setVolume(let id, _):
            pair("\(a.trackName(id)) › volume", b.track(id).map { db($0.volumeDb) }, a.track(id).map { db($0.volumeDb) })
        case .setPan(let id, _):
            pair("\(a.trackName(id)) › pan", b.track(id).map { pan($0.pan) }, a.track(id).map { pan($0.pan) })
        case .setMute(let id, _):
            pair("\(a.trackName(id)) › mute", b.track(id).map { onOff($0.mute) }, a.track(id).map { onOff($0.mute) })
        case .setSolo(let id, _):
            pair("\(a.trackName(id)) › solo", b.track(id).map { onOff($0.solo) }, a.track(id).map { onOff($0.solo) })
        case .setOutput(let id, _):
            pair("\(a.trackName(id)) › output", b.output(id), a.output(id))
        case .setSends(let id, _):
            pair("\(a.trackName(id)) › sends", b.sends(id), a.sends(id))
        case .setInputTrack(let id, _), .setMonitor(let id, _), .setSendsOnly(let id, _), .setHardwareOutput(let id, _),
             .setAudioInput(let id, _), .setMIDIInput(let id, _), .setMIDIOutput(let id, _), .setInputChannels(let id, _):
            pair("\(a.trackName(id)) › \(command.kind)", nil, "changed")
        case .insertDevice(let t, _, _), .removeDevice(let t, _), .moveDevice(let t, _, _), .setDevices(let t, nil, _):
            pair("\(a.trackName(t)) › devices", b.deviceList(t), a.deviceList(t))
        case .insertDeviceInChain(let t, let chain, _, _), .setDevices(let t, .some(let chain), _):
            pair("\(a.trackName(t)) › \(a.chainName(t, chain)) › devices", b.chainDevices(t, chain), a.chainDevices(t, chain))
        case .setDeviceParam(let t, let d, let key, _):
            let name = a.paramName(t, d, key)
            pair("\(a.trackName(t)) › \(a.deviceName(t, d)) › \(name)", b.paramValue(t, d, key), a.paramValue(t, d, key))
        case .setDeviceBypass(let t, let d, _):
            pair("\(a.trackName(t)) › \(a.deviceName(t, d)) › bypass", b.bypass(t, d), a.bypass(t, d))
        case .setDeviceSidechain(let t, let d, _):
            pair("\(a.trackName(t)) › \(a.deviceName(t, d)) › sidechain", b.sidechain(t, d), a.sidechain(t, d))
        case .setDeviceSource(let t, let d, _, _):
            pair("\(a.trackName(t)) › \(a.deviceName(t, d)) › patch", b.patchSummary(t, d), a.patchSummary(t, d))
        case .setPluginParams(let t, let d, _):
            pair("\(a.trackName(t)) › \(a.deviceName(t, d)) › plugin parameters", nil, "updated")
        case .addChain(let t, let r, _, _), .removeChain(let t, let r, _), .moveChain(let t, let r, _, _), .setChain(let t, let r, _):
            pair("\(a.trackName(t)) › \(a.deviceName(t, r)) › chains", b.chains(t, r), a.chains(t, r))
        case .setMacroMapping(let t, let r, _), .removeMacroMapping(let t, let r, _), .setMacroName(let t, let r, _, _):
            pair("\(a.trackName(t)) › \(a.deviceName(t, r)) › macros", nil, "changed")
        case .insertClip(let t, let clip):
            pair("\(a.trackName(t)) › clips", b.clipList(t), a.clipList(t))
            if let c = a.clipInfo(clip.id) { out.append(.init(path: c.path, after: c.detail)) }
        case .removeClip(let id):
            if let c = b.clipInfo(id) { pair(c.path, c.detail, nil) }
        case .moveClip(let id, _, _), .setClipRange(let id, _, _):
            pair(a.clipInfo(id)?.path ?? b.clipInfo(id)?.path ?? "clip", b.clipInfo(id)?.detail, a.clipInfo(id)?.detail)
        case .setClip(let clip):
            pair(a.clipInfo(clip.id)?.path ?? "clip", b.clipInfo(clip.id)?.detail, a.clipInfo(clip.id)?.detail)
        case .setClipName(let id, _):
            pair("\(a.clipInfo(id)?.path ?? "clip") › name", b.clipInfo(id)?.name, a.clipInfo(id)?.name)
        case .setClipLoop(let id, _):
            pair("\(a.clipInfo(id)?.path ?? "clip") › loop", b.clipInfo(id)?.loop, a.clipInfo(id)?.loop)
        case .setClipColor(let id, _):
            pair("\(a.clipInfo(id)?.path ?? "clip") › color", nil, "changed")
        case .setMIDINotes(let id, _):
            pair("\(a.clipInfo(id)?.path ?? "clip") › notes", b.clipInfo(id)?.notes, a.clipInfo(id)?.notes)
        case .setMIDIControls(let id, _):
            pair("\(a.clipInfo(id)?.path ?? "clip") › controllers", nil, "changed")
        case .setClipEnvelope(let id, _), .setClipAutomation(let id, _, _), .setClipAutomationLength(let id, _),
             .setDummyAutomation(let id, _, _), .setClipGroove(let id, _), .commitGroove(let id), .setAudioClip(let id, _, _, _, _),
             .setClipWarp(let id, _, _):
            pair("\(a.clipInfo(id)?.path ?? "clip") › \(command.kind)", nil, "changed")
        case .setSlot(let t, let index, _):
            pair("\(a.trackName(t)) › slot \(index + 1)", b.slot(t, index), a.slot(t, index))
        case .setAutomation(let t, let target, let points):
            pair("\(a.trackName(t)) › automation \(target)", nil, "\(points.count) points")
        case .setTempoPoints:
            pair("tempo", b.tempo, a.tempo)
        case .setLoop:
            pair("loop", b.loop, a.loop)
        case .setLaunches(let launches):
            pair("launches", nil, "\(launches.count)")
        case .setRandomSeed, .setDefaultFade, .setAutoLoop:
            pair("project › \(command.kind)", nil, "changed")
        case .addAsset, .removeAsset, .setAssetTempo:
            pair("assets", "\(before.assets.count)", "\(after.assets.count)")
        case .addPort, .removePort:
            pair("ports", "\(before.ports.count)", "\(after.ports.count)")
        }
        return out
    }

    // MARK: Formatting

    static func db(_ v: Double) -> String { String(format: "%.1f dB", v) }
    static func pan(_ v: Double) -> String { v == 0 ? "center" : v < 0 ? String(format: "%.0f L", -v * 50) : String(format: "%.0f R", v * 50) }
    static func onOff(_ v: Bool) -> String { v ? "on" : "off" }
    public static func ticks(_ t: Tick) -> String {
        let bar = Double(t.rawValue) / Double(Tick.perQuarter * 4)
        return bar == bar.rounded() ? "\(Int(bar)) bars" : String(format: "%.2f bars", bar)
    }

    /// Reads one project.
    public struct Reader {
        let p: Project
        public init(_ p: Project) { self.p = p }

        func track(_ id: TrackID) -> Track? { p.track(id) }
        public func trackName(_ id: TrackID) -> String { p.track(id)?.name ?? "track" }
        var trackList: String { p.tracks.map(\.name).joined(separator: ", ") }
        func output(_ id: TrackID) -> String? {
            guard let t = track(id) else { return nil }
            return t.output.map(trackName) ?? "Master"
        }
        func sends(_ id: TrackID) -> String? {
            guard let t = track(id) else { return nil }
            if t.sends.isEmpty { return "none" }
            return t.sends.map { "\(trackName($0.target)) \(ReadBack.db($0.levelDb))" }.joined(separator: ", ")
        }
        func deviceList(_ id: TrackID) -> String? {
            guard let t = track(id) else { return nil }
            return t.devices.isEmpty ? "none" : t.devices.map(\.name).joined(separator: ", ")
        }
        func device(_ t: TrackID, _ d: DeviceID) -> DeviceSlot? { track(t)?.allDevices.first { $0.id == d } }
        func deviceName(_ t: TrackID, _ d: DeviceID) -> String { device(t, d)?.name ?? "device" }
        func chainName(_ t: TrackID, _ c: ChainID) -> String { track(t)?.chain(c)?.name ?? "chain" }
        func chainDevices(_ t: TrackID, _ c: ChainID) -> String? {
            guard let chain = track(t)?.chain(c) else { return nil }
            return chain.devices.isEmpty ? "none" : chain.devices.map(\.name).joined(separator: ", ")
        }
        func chains(_ t: TrackID, _ r: DeviceID) -> String? {
            device(t, r)?.rack?.chains.map(\.name).joined(separator: ", ")
        }
        func paramName(_ t: TrackID, _ d: DeviceID, _ key: String) -> String {
            guard let dev = device(t, d) else { return key }
            if let spec = dev.spec,
               let p = spec.params.first(where: { $0.key == key }) { return p.name }
            return dev.pluginParams?.first { $0.key == key }?.name ?? key
        }
        public func paramValue(_ t: TrackID, _ d: DeviceID, _ key: String) -> String? {
            guard let dev = device(t, d) else { return nil }
            if let spec = dev.spec,
               let p = spec.params.first(where: { $0.key == key }) {
                let v = dev.params[key] ?? p.def
                if !p.choices.isEmpty, !p.rotary, Int(v.rounded()) >= 0, Int(v.rounded()) < p.choices.count { return p.choices[Int(v.rounded())] }
                let text = v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
                return p.unit.isEmpty ? text : "\(text) \(p.unit)"
            }
            return dev.params[key].map { String(format: "%.3f", $0) } ?? "default"
        }
        func bypass(_ t: TrackID, _ d: DeviceID) -> String? { device(t, d).map { ReadBack.onOff($0.bypassed) } }
        func sidechain(_ t: TrackID, _ d: DeviceID) -> String? { device(t, d).map { $0.sidechain.map(trackName) ?? "own input" } }
        /// A patch in one line: its name, its knobs, its length; or its compile error.
        func patchSummary(_ t: TrackID, _ d: DeviceID) -> String? {
            guard let dev = device(t, d) else { return nil }
            if let e = dev.patchError { return "does not compile (\(e))" }
            let spec = dev.spec ?? BuiltInEffects.patch
            let lines = (dev.source ?? "").split(separator: "\n").count
            return "\(spec.name), \(spec.params.count) knobs (\(spec.params.map(\.key).joined(separator: ", "))), \(lines) lines"
        }
        func clipList(_ id: TrackID) -> String? { track(id).map { "\($0.clips.count) clips" } }
        func slot(_ t: TrackID, _ i: Int) -> String? {
            guard let track = track(t) else { return nil }
            guard i >= 0, i < track.slots.count, let s = track.slots[i] else { return "empty" }
            return clipLabel(s.clip)
        }
        public func clipLabel(_ c: Clip) -> String {
            switch c {
            case .audio(let a): a.name ?? p.asset(a.asset)?.name ?? "audio clip"
            case .midi(let m): m.name ?? "MIDI clip"
            case .dummy(let d): d.name.isEmpty ? "Dummy" : d.name
            }
        }
        public struct ClipInfo { public var path: String; public var name: String; public var detail: String; public var loop: String; public var notes: String }
        public func clipInfo(_ id: ClipID) -> ClipInfo? {
            guard let (t, c) = p.findClip(id), let track = track(t) else { return nil }
            let name = clipLabel(c)
            var place = "\(track.name) › \(name)"
            if let row = track.slots.firstIndex(where: { $0?.clip.id == id }) { place = "\(track.name) › slot \(row + 1) › \(name)" }
            let loop: Bool = switch c { case .audio(let a): a.loop; case .midi(let m): m.loop; case .dummy: false }
            let notes: Int = if case .midi(let m) = c { m.notes.count } else { 0 }
            let detail = "start \(ReadBack.ticks(c.start)), length \(ReadBack.ticks(c.length))"
            return ClipInfo(path: place, name: name, detail: detail, loop: ReadBack.onOff(loop), notes: "\(notes) notes")
        }
        var tempo: String? { String(format: "%.1f bpm", p.tempoMap.bpm(at: 0)) }
        var loop: String? {
            guard let l = p.loop else { return "off" }
            return "\(ReadBack.ticks(l.start)) to \(ReadBack.ticks(l.end))\(l.enabled ? "" : " (off)")"
        }
    }
}
