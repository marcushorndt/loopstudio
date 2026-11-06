import Foundation
import LoopStudioCore

/// Finds tracks, devices and clips from the words a person uses: an id, a name, or a position. One match
/// acts; several matches are an error that lists them, so the caller asks instead of guessing.
public enum Resolve {
    static func uuid(_ s: String) -> UUID? { UUID(uuidString: s.trimmingCharacters(in: .whitespaces)) }

    /// A track by id, by name (case does not matter), by "master", or by its 1-based position.
    public static func track(_ ref: String, in project: Project) throws -> Track {
        let key = ref.trimmingCharacters(in: .whitespaces)
        if let u = uuid(key), let t = project.track(TrackID(u)) { return t }
        if key.lowercased() == "master" { return project.master }
        let byName = project.tracks.filter { $0.name.caseInsensitiveCompare(key) == .orderedSame }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 {
            throw ToolFailure("\(byName.count) tracks are named '\(key)': " + byName.map { "\($0.name) (\($0.id))" }.joined(separator: ", ") + ". Use the id.")
        }
        if let n = Int(key), n >= 1, n <= project.tracks.count { return project.tracks[n - 1] }
        let names = project.tracks.map(\.name).joined(separator: ", ")
        throw ToolFailure("no track '\(key)'. Tracks: \(names.isEmpty ? "none" : names), Master.")
    }

    /// A device on a track (any depth) by id, by name, or by its 1-based position in the top-level chain.
    public static func device(_ ref: String, on track: Track) throws -> DeviceSlot {
        let key = ref.trimmingCharacters(in: .whitespaces)
        if let u = uuid(key), let d = track.device(DeviceID(u)) { return d }
        let all = track.allDevices
        let byName = all.filter { $0.name.caseInsensitiveCompare(key) == .orderedSame }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 {
            throw ToolFailure("\(byName.count) devices on \(track.name) are named '\(key)': " + byName.map { "\($0.name) (\($0.id))" }.joined(separator: ", ") + ". Use the id.")
        }
        if let n = Int(key), n >= 1, n <= track.devices.count { return track.devices[n - 1] }
        let names = track.devices.map(\.name).joined(separator: ", ")
        throw ToolFailure("no device '\(key)' on \(track.name). Devices: \(names.isEmpty ? "none" : names).")
    }

    /// A clip by id, or by name over the whole project, or "track/slot N" (1-based) for a session slot.
    public static func clip(_ ref: String, in project: Project) throws -> (track: Track, clip: Clip) {
        let key = ref.trimmingCharacters(in: .whitespaces)
        if let u = uuid(key), let found = project.findClip(ClipID(u)), let t = project.track(found.track) { return (t, found.clip) }
        if let slash = key.lastIndex(of: "/"), key[key.index(after: slash)...].lowercased().hasPrefix("slot") {
            let t = try track(String(key[..<slash]), in: project)
            let rowText = key[key.index(after: slash)...].dropFirst(4).trimmingCharacters(in: .whitespaces)
            guard let row = Int(rowText), row >= 1 else { throw ToolFailure("'\(key)': slot must be a number from 1") }
            guard row <= t.slots.count, let slot = t.slots[row - 1] else { throw ToolFailure("slot \(row) of \(t.name) is empty") }
            return (t, slot.clip)
        }
        let reader = ReadBack.Reader(project)
        var matches: [(Track, Clip)] = []
        for t in project.allTracks {
            for c in t.clips where reader.clipLabel(c).caseInsensitiveCompare(key) == .orderedSame { matches.append((t, c)) }
            for case let s? in t.slots where reader.clipLabel(s.clip).caseInsensitiveCompare(key) == .orderedSame { matches.append((t, s.clip)) }
        }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            throw ToolFailure("\(matches.count) clips are named '\(key)': " + matches.map { "\($0.0.name) › \(reader.clipLabel($0.1)) (\($0.1.id))" }.joined(separator: ", ") + ". Use the id or track/slot N.")
        }
        throw ToolFailure("no clip '\(key)'. Give a clip id, a clip name, or 'track/slot N'.")
    }

    /// A parameter of a device by key or by name.
    public static func param(_ ref: String, of device: DeviceSlot) throws -> (key: String, min: Double, max: Double, name: String) {
        let key = ref.trimmingCharacters(in: .whitespaces)
        if let spec = device.spec {
            if let p = spec.params.first(where: { $0.key == key }) ?? spec.params.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
                return (p.key, p.min, p.max, p.name)
            }
            let keys = spec.params.map { "\($0.key) (\($0.name))" }.joined(separator: ", ")
            throw ToolFailure("no parameter '\(key)' on \(device.name). Parameters: \(keys).")
        }
        if let p = device.pluginParams?.first(where: { $0.key == key }) ?? device.pluginParams?.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
            return (p.key, p.min, p.max, p.name)
        }
        let keys = (device.pluginParams ?? []).prefix(40).map { "\($0.key) (\($0.name))" }.joined(separator: ", ")
        throw ToolFailure("no parameter '\(key)' on \(device.name). " + (keys.isEmpty ? "The plugin has not reported its parameters yet." : "Parameters: \(keys)."))
    }
}

/// Flat, named tools for the common edits. Each one builds a `Command` and returns a receipt. They take
/// names and positions, so a caller can say "Drums" and "Delay" instead of ids.
public extension StandardTools {
    static let namedToolsNote = """
    Named tools: track_add, track_rename, track_set, track_remove, device_add, device_remove, device_move, device_bypass, \
    param_set, clip_create, clip_set, clip_remove, notes_set, send_set, tempo_set, loop_set. A track is an id, a name, "master" \
    or its position from 1. A device is an id, a name or its position in the track's chain from 1. A clip is an id, a name, \
    or "<track>/slot N". A parameter is its key or its name from effect_catalog. Every change returns a receipt with the \
    values read back from the project after the change; the receipt is the proof, the arguments are not.
    """

    static func namedTools(session: any EditSession) -> [Tool] {
        var tools: [Tool] = []

        func bool(_ description: String) -> JSONValue { .object(["type": .string("boolean"), "description": .string(description)]) }
        let trackArg = Schema.string("The track: id, name, \"master\" or position from 1")
        let deviceArg = Schema.string("The device: id, name or position in the chain from 1")
        let clipArg = Schema.string("The clip: id, name or \"<track>/slot N\"")

        tools.append(Tool(
            name: "track_add", title: "Add a track",
            description: "Add an audio, midi or return track. index: where in the list (from 0); omitted: at the end. Returns the new track's id.",
            inputSchema: Schema.object(["name": Schema.string("Track name"), "kind": Schema.string("audio | midi | return"),
                                        "index": Schema.integer("Position from 0", minimum: 0)], required: ["name", "kind"]),
            annotations: ToolAnnotations()
        ) { args in
            let kindText = try args.string("kind")
            guard let kind = TrackKind(rawValue: kindText), [.audio, .midi, .returnTrack].contains(kind) else {
                throw ToolFailure("kind must be audio, midi or return")
            }
            let project = try await session.project()
            let track = Track(name: try args.string("name"), kind: kind)
            let index = min(args.optionalInt("index") ?? project.tracks.count, project.tracks.count)
            return try await session.receipt(.insertTrack(track: track, index: index), extra: ["track": .string(track.id.description)])
        })

        tools.append(Tool(
            name: "track_rename", title: "Rename a track",
            description: "Give a track a new name.",
            inputSchema: Schema.object(["track": trackArg, "name": Schema.string("The new name")], required: ["track", "name"]),
            annotations: ToolAnnotations(idempotent: true)
        ) { args in
            let t = try Resolve.track(try args.string("track"), in: try await session.project())
            return try await session.receipt(.setTrackName(id: t.id, name: try args.string("name")))
        })

        tools.append(Tool(
            name: "track_set", title: "Set mixer values of a track",
            description: "Volume (dB, -96 to 12), pan (-1 left to 1 right), mute, solo, colorIndex. Give only the fields to change.",
            inputSchema: Schema.object(["track": trackArg, "volumeDb": Schema.number("Volume in dB"), "pan": Schema.number("-1 to 1"),
                                        "mute": bool("Mute on or off"), "solo": bool("Solo on or off"),
                                        "colorIndex": Schema.integer("Colour index", minimum: 0)], required: ["track"]),
            annotations: ToolAnnotations(idempotent: true)
        ) { args in
            let t = try Resolve.track(try args.string("track"), in: try await session.project())
            var commands: [Command] = []
            if let v = args.optionalDouble("volumeDb") { commands.append(.setVolume(id: t.id, db: v)) }
            if let v = args.optionalDouble("pan") { commands.append(.setPan(id: t.id, pan: v)) }
            if let v = args.raw["mute"]?.boolValue { commands.append(.setMute(id: t.id, mute: v)) }
            if let v = args.raw["solo"]?.boolValue { commands.append(.setSolo(id: t.id, solo: v)) }
            if let v = args.optionalInt("colorIndex") { commands.append(.setTrackColor(id: t.id, colorIndex: v)) }
            guard !commands.isEmpty else { throw ToolFailure("give at least one of volumeDb, pan, mute, solo, colorIndex") }
            return try await session.receipt(commands.count == 1 ? commands[0] : .batch(commands: commands))
        })

        tools.append(Tool(
            name: "track_remove", title: "Remove a track",
            description: "Remove a track with its clips and devices. Undo brings it back.",
            inputSchema: Schema.object(["track": trackArg], required: ["track"]),
            annotations: ToolAnnotations(destructive: true)
        ) { args in
            let t = try Resolve.track(try args.string("track"), in: try await session.project())
            return try await session.receipt(.removeTrack(id: t.id))
        })

        tools.append(Tool(
            name: "device_add", title: "Add a built-in device",
            description: "Add a built-in effect or instrument (id from effect_catalog) to a track. index: position in the chain from 0; omitted: at the end. An instrument goes to the front of a MIDI track. Returns the device id. For an Audio Unit use command_apply with insertDevice.",
            inputSchema: Schema.object(["track": trackArg, "device": Schema.string("Built-in id from effect_catalog, such as delay, eq3, reverb, acid"),
                                        "index": Schema.integer("Position in the chain from 0", minimum: 0)], required: ["track", "device"]),
            annotations: ToolAnnotations()
        ) { args in
            let project = try await session.project()
            let t = try Resolve.track(try args.string("track"), in: project)
            let id = try args.string("device")
            guard let spec = BuiltInEffects.spec(id), let slot = BuiltInEffects.makeSlot(id) else {
                let ids = (BuiltInEffects.all + BuiltInInstruments.all).map(\.id).joined(separator: ", ")
                throw ToolFailure("no built-in device '\(id)'. Ids: \(ids).")
            }
            if spec.isInstrument {
                guard t.kind == .midi else { throw ToolFailure("\(spec.name) is an instrument; it needs a MIDI track (\(t.name) is \(t.kind.rawValue))") }
                // An instrument takes the place of the one the track has, like a drop in the app.
                if let old = t.devices.firstIndex(where: { d in
                    d.format == "builtin" && (BuiltInInstruments.spec(d.identifier)?.isInstrument ?? false)
                }) {
                    return try await session.receipt(.batch(commands: [.removeDevice(track: t.id, device: t.devices[old].id),
                                                                        .insertDevice(track: t.id, device: slot, index: old)]),
                                                     extra: ["device": .string(slot.id.description)])
                }
                return try await session.receipt(.insertDevice(track: t.id, device: slot, index: 0), extra: ["device": .string(slot.id.description)])
            }
            return try await session.receipt(.insertDevice(track: t.id, device: slot, index: args.optionalInt("index")),
                                             extra: ["device": .string(slot.id.description)])
        })

        tools.append(Tool(
            name: "device_remove", title: "Remove a device",
            description: "Remove a device from a track. Undo brings it back.",
            inputSchema: Schema.object(["track": trackArg, "device": deviceArg], required: ["track", "device"]),
            annotations: ToolAnnotations(destructive: true)
        ) { args in
            let t = try Resolve.track(try args.string("track"), in: try await session.project())
            let d = try Resolve.device(try args.string("device"), on: t)
            return try await session.receipt(.removeDevice(track: t.id, device: d.id))
        })

        tools.append(Tool(
            name: "device_move", title: "Move a device",
            description: "Move a device to a position in the track's chain (from 0).",
            inputSchema: Schema.object(["track": trackArg, "device": deviceArg, "index": Schema.integer("New position from 0", minimum: 0)],
                                       required: ["track", "device", "index"]),
            annotations: ToolAnnotations(idempotent: true)
        ) { args in
            let t = try Resolve.track(try args.string("track"), in: try await session.project())
            let d = try Resolve.device(try args.string("device"), on: t)
            return try await session.receipt(.moveDevice(track: t.id, device: d.id, to: try args.int("index")))
        })

        tools.append(Tool(
            name: "device_bypass", title: "Bypass a device",
            description: "Switch a device off (bypassed: true) or on.",
            inputSchema: Schema.object(["track": trackArg, "device": deviceArg, "bypassed": bool("true: off")], required: ["track", "device", "bypassed"]),
            annotations: ToolAnnotations(idempotent: true)
        ) { args in
            let t = try Resolve.track(try args.string("track"), in: try await session.project())
            let d = try Resolve.device(try args.string("device"), on: t)
            guard let b = args.raw["bypassed"]?.boolValue else { throw ToolFailure("bypassed must be true or false") }
            return try await session.receipt(.setDeviceBypass(track: t.id, device: d.id, bypassed: b))
        })

        tools.append(Tool(
            name: "param_set", title: "Set a device parameter",
            description: "Set one parameter of a device. param: the key or the name from effect_catalog. value: a number in the parameter's range; for a choice parameter the index of the choice. The receipt reads the value back.",
            inputSchema: Schema.object(["track": trackArg, "device": deviceArg, "param": Schema.string("Parameter key or name"),
                                        "value": Schema.number("The new value")], required: ["track", "device", "param", "value"]),
            annotations: ToolAnnotations(idempotent: true)
        ) { args in
            let t = try Resolve.track(try args.string("track"), in: try await session.project())
            let d = try Resolve.device(try args.string("device"), on: t)
            let p = try Resolve.param(try args.string("param"), of: d)
            guard let v = args.optionalDouble("value") else { throw ToolFailure("value must be a number") }
            guard v >= p.min, v <= p.max else { throw ToolFailure("\(p.name) takes \(p.min) to \(p.max); \(v) is outside") }
            return try await session.receipt(.setDeviceParam(track: t.id, device: d.id, key: p.key, value: v))
        })

        tools.append(Tool(
            name: "clip_create", title: "Create a clip",
            description: "Create an empty MIDI clip (kind midi, on a MIDI track) or a dummy clip (kind dummy). Without slot: in the arrangement at start. With slot (from 1): in that session slot. Ticks: 960 per quarter, 3840 per 4/4 bar. For audio use sample_drop. Returns the clip id.",
            inputSchema: Schema.object(["track": trackArg, "kind": Schema.string("midi | dummy"), "length": Schema.integer("Length in ticks", minimum: 1),
                                        "start": Schema.integer("Arrangement start in ticks", minimum: 0), "slot": Schema.integer("Session slot from 1", minimum: 1),
                                        "name": Schema.string("Clip name"), "loop": bool("Loop the clip")], required: ["track", "kind", "length"]),
            annotations: ToolAnnotations()
        ) { args in
            let project = try await session.project()
            let t = try Resolve.track(try args.string("track"), in: project)
            let length = Tick(Int64(try args.int("length")))
            let kind = try args.string("kind")
            let loop = args.raw["loop"]?.boolValue ?? (args.optionalInt("slot") != nil)
            let name = args.optionalString("name")
            let start = Tick(Int64(args.optionalInt("start") ?? 0))
            let clip: Clip
            switch kind {
            case "midi":
                guard t.kind == .midi else { throw ToolFailure("a MIDI clip needs a MIDI track (\(t.name) is \(t.kind.rawValue))") }
                var c = MIDIClip(start: start, length: length, loop: loop); c.name = name
                clip = .midi(c)
            case "dummy":
                clip = .dummy(DummyClip(name: name ?? "", start: start, length: length))
            default: throw ToolFailure("kind must be midi or dummy")
            }
            if let row = args.optionalInt("slot") {
                var sessionClip = clip
                if case .midi(var c) = clip { c.start = 0; sessionClip = .midi(c) }
                if case .dummy(var c) = clip { c.start = 0; sessionClip = .dummy(c) }
                return try await session.receipt(.setSlot(track: t.id, index: row - 1, slot: SessionSlot(clip: sessionClip)),
                                                 extra: ["clip": .string(clip.id.description)])
            }
            return try await session.receipt(.insertClip(track: t.id, clip: clip), extra: ["clip": .string(clip.id.description)])
        })

        tools.append(Tool(
            name: "clip_set", title: "Change a clip",
            description: "Rename, loop, move or resize a clip. Give only the fields to change. start and length in ticks (arrangement clips).",
            inputSchema: Schema.object(["clip": clipArg, "name": Schema.string("New name"), "loop": bool("Loop on or off"),
                                        "start": Schema.integer("Start in ticks", minimum: 0), "length": Schema.integer("Length in ticks", minimum: 1),
                                        "colorIndex": Schema.integer("Colour index", minimum: 0)], required: ["clip"]),
            annotations: ToolAnnotations(idempotent: true)
        ) { args in
            let (_, c) = try Resolve.clip(try args.string("clip"), in: try await session.project())
            var commands: [Command] = []
            if let v = args.optionalString("name") { commands.append(.setClipName(clip: c.id, name: v)) }
            if let v = args.raw["loop"]?.boolValue { commands.append(.setClipLoop(clip: c.id, loop: v)) }
            if args.optionalInt("start") != nil || args.optionalInt("length") != nil {
                let start = Tick(Int64(args.optionalInt("start") ?? Int(c.start.rawValue)))
                let length = Tick(Int64(args.optionalInt("length") ?? Int(c.length.rawValue)))
                commands.append(.setClipRange(clip: c.id, start: start, length: length))
            }
            if let v = args.optionalInt("colorIndex") { commands.append(.setClipColor(clip: c.id, colorIndex: v)) }
            guard !commands.isEmpty else { throw ToolFailure("give at least one of name, loop, start, length, colorIndex") }
            return try await session.receipt(commands.count == 1 ? commands[0] : .batch(commands: commands))
        })

        tools.append(Tool(
            name: "clip_remove", title: "Remove a clip",
            description: "Remove a clip from the arrangement or empty its session slot. Undo brings it back.",
            inputSchema: Schema.object(["clip": clipArg], required: ["clip"]),
            annotations: ToolAnnotations(destructive: true)
        ) { args in
            let (t, c) = try Resolve.clip(try args.string("clip"), in: try await session.project())
            if let row = t.slots.firstIndex(where: { $0?.clip.id == c.id }) {
                return try await session.receipt(.setSlot(track: t.id, index: row, slot: nil))
            }
            return try await session.receipt(.removeClip(clip: c.id))
        })

        tools.append(Tool(
            name: "notes_set", title: "Write MIDI notes",
            description: "Add notes to a MIDI clip, or replace all of them (replace: true). tick and length in ticks from the clip start (960 per quarter); pitch 0 to 127 (60 is C3); velocity 1 to 127, default 100.",
            inputSchema: Schema.object([
                "clip": clipArg, "replace": bool("true: the list replaces every note; false: the notes are added"),
                "notes": .object(["type": .string("array"), "description": .string("The notes"),
                                  "items": Schema.object(["tick": Schema.integer("Start from the clip start", minimum: 0),
                                                          "length": Schema.integer("Length in ticks", minimum: 1),
                                                          "pitch": Schema.integer("MIDI note", minimum: 0, maximum: 127),
                                                          "velocity": Schema.integer("1 to 127", minimum: 1, maximum: 127)],
                                                         required: ["tick", "length", "pitch"])]),
            ], required: ["clip", "notes"]),
            annotations: ToolAnnotations()
        ) { args in
            let (_, c) = try Resolve.clip(try args.string("clip"), in: try await session.project())
            guard case .midi(let m) = c else { throw ToolFailure("notes go into a MIDI clip; this one is not") }
            guard let items = args.raw["notes"]?.arrayValue else { throw ToolFailure("notes must be an array") }
            var added: [MIDINote] = []
            for item in items {
                guard let tick = item["tick"]?.intValue, let length = item["length"]?.intValue, let pitch = item["pitch"]?.intValue,
                      tick >= 0, length >= 1, pitch >= 0, pitch <= 127 else { throw ToolFailure("each note needs tick >= 0, length >= 1, pitch 0 to 127") }
                let velocity = item["velocity"]?.intValue ?? 100
                guard velocity >= 1, velocity <= 127 else { throw ToolFailure("velocity must be 1 to 127") }
                added.append(MIDINote(tick: Tick(Int64(tick)), length: Tick(Int64(length)), pitch: UInt8(pitch), velocity: UInt8(velocity)))
            }
            let replace = args.raw["replace"]?.boolValue ?? false
            let notes = (replace ? [] : m.notes) + added
            if replace, notes.isEmpty, !m.notes.isEmpty { throw ToolFailure("replace with no notes empties the clip; use clip_remove or give notes") }
            return try await session.receipt(.setMIDINotes(clip: c.id, notes: notes.sorted { ($0.tick, $0.pitch) < ($1.tick, $1.pitch) }))
        })

        tools.append(Tool(
            name: "send_set", title: "Set a send",
            description: "Set the level (dB) of a track's send to a return track. -96 or below removes the send.",
            inputSchema: Schema.object(["track": trackArg, "target": Schema.string("The return track: id, name or position"),
                                        "db": Schema.number("Level in dB")], required: ["track", "target", "db"]),
            annotations: ToolAnnotations(idempotent: true)
        ) { args in
            let project = try await session.project()
            let t = try Resolve.track(try args.string("track"), in: project)
            let target = try Resolve.track(try args.string("target"), in: project)
            guard target.kind == .returnTrack else { throw ToolFailure("\(target.name) is not a return track") }
            guard let db = args.optionalDouble("db") else { throw ToolFailure("db must be a number") }
            var sends = t.sends
            if db <= -96 { sends.removeAll { $0.target == target.id } }
            else if let i = sends.firstIndex(where: { $0.target == target.id }) { sends[i].levelDb = db }
            else { sends.append(Send(target: target.id, levelDb: db)) }
            return try await session.receipt(.setSends(id: t.id, sends: sends))
        })

        tools.append(Tool(
            name: "tempo_set", title: "Set the tempo",
            description: "Set the song tempo at the start (bpm, 20 to 999). Later tempo points keep their values.",
            inputSchema: Schema.object(["bpm": Schema.number("Beats per minute")], required: ["bpm"]),
            annotations: ToolAnnotations(idempotent: true)
        ) { args in
            guard let bpm = args.optionalDouble("bpm"), TempoMap.bpmRange.contains(bpm) else { throw ToolFailure("bpm must be 20 to 999") }
            var points = try await session.project().tempoMap.points
            if points.isEmpty { points = [TempoPoint(tick: 0, bpm: bpm)] } else { points[0].bpm = bpm }
            return try await session.receipt(.setTempoPoints(points: points))
        })

        tools.append(Tool(
            name: "loop_set", title: "Set the arrangement loop",
            description: "Set the loop region in ticks, or switch it off (enabled: false keeps the region). Ticks: 3840 per 4/4 bar.",
            inputSchema: Schema.object(["start": Schema.integer("Start in ticks", minimum: 0), "end": Schema.integer("End in ticks", minimum: 1),
                                        "enabled": bool("Loop on or off")]),
            annotations: ToolAnnotations(idempotent: true)
        ) { args in
            let current = try await session.project().loop
            let start = args.optionalInt("start").map { Tick(Int64($0)) } ?? current?.start
            let end = args.optionalInt("end").map { Tick(Int64($0)) } ?? current?.end
            let enabled = args.raw["enabled"]?.boolValue ?? current?.enabled ?? true
            guard let start, let end else { throw ToolFailure("give start and end (ticks)") }
            guard end > start else { throw ToolFailure("end must be after start") }
            return try await session.receipt(.setLoop(loop: LoopRegion(start: start, end: end, enabled: enabled)))
        })

        // MARK: Patches: the programmable device, see docs/scripting.md

        @Sendable func patchReport(_ program: PatchProgram) -> JSONValue {
            .object(["name": .string(program.name), "ops": .number(Double(program.ops.count)),
                     "knobs": .array(program.spec.params.map { .object(["key": .string($0.key), "min": .number($0.min), "max": .number($0.max),
                                                                        "default": .number($0.def), "unit": .string($0.unit)]) }),
                     "delays": .array(program.buffers.map { .string("\($0.name): \($0.seconds) s") })])
        }
        @Sendable func patchDevice(_ args: ToolArguments) async throws -> (Track, DeviceSlot) {
            let t = try Resolve.track(try args.string("track"), in: try await session.project())
            let d = try Resolve.device(try args.string("device"), on: t)
            guard d.format == "builtin", d.identifier == "patch" else { throw ToolFailure("\(d.name) is not a Patch device (device_add with device \"patch\" makes one)") }
            return (t, d)
        }

        tools.append(Tool(
            name: "patch_read", title: "Read a patch",
            description: "The text of a Patch device (the programmable built-in device), with its knobs, or its compile error. The language: patch_check's description, and the resource loopstudio://help/patch.",
            inputSchema: Schema.object(["track": trackArg, "device": deviceArg], required: ["track", "device"]),
            annotations: ToolAnnotations(readOnly: true)
        ) { args in
            let (_, d) = try await patchDevice(args)
            var o: [String: JSONValue] = ["source": .string(d.source ?? ""), "device": .string(d.id.description)]
            if PatchDocument.isDocument(d.source ?? ""), let doc = PatchDocument.parse(d.source ?? "") {
                o["graph"] = .object(["name": .string(doc.name),
                                      "modules": .array(doc.modules.map { m in
                                          let ports = PatchModules.ports(of: m)
                                          var mo: [String: JSONValue] = ["id": .string(m.id), "kind": .string(m.kind), "label": .string(PatchModules.label(m)), "onPanel": .bool(m.isOnPanel),
                                                                         "inputs": .array(ports.inputs.map { .string($0.name) }), "outputs": .array(ports.outputs.map { .string($0.name) })]
                                          if !m.values.isEmpty { mo["values"] = .object(m.values.mapValues { .number($0) }) }
                                          if !m.settings.isEmpty { mo["settings"] = .object(m.settings.mapValues { .string($0) }) }
                                          if let s = m.source { mo["source"] = .string(s) }
                                          return .object(mo) }),
                                      "cables": .array(doc.cables.map { .string("\($0.from).\($0.fromPort) -> \($0.to).\($0.toPort)") })])
            } else {
                o["note"] = .string("a text; patch_edit turns it into a graph with one Script module")
            }
            switch PatchCompiler.cached(d.source ?? "") {
            case .success(let p): o["program"] = patchReport(p)
            case .failure(let e): o["error"] = .string("\(e)")
            }
            return .object(o)
        })

        tools.append(Tool(
            name: "patch_check", title: "Check a patch text",
            description: """
            Compile a patch text without putting it anywhere. Returns the knobs and the op count, or the error with its line. \
            The language, one statement per line: patch "Name"; param key min..max = default [log] ["unit"] (a knob; "ms" knobs \
            are seconds in the program) or param key note = 1/16 (a note value knob that follows the tempo); in x; out y; \
            delay name = 2 s; meter name; name = expression; delay.write(expression). Expressions run once per sample on stereo \
            values: + - * / ^, comparisons (0 or 1), numbers with units (10 ms, 2 s, 440 Hz, 2 kHz, -6 dB) and note values \
            (1/16, 1/8., 1/4T), beat, bar (0..1 inside the bar), tempo, sr, pi. Functions: osc(hz, shape), lfo(rate, shape) 0..1 \
            (a note value locks it to the song), phase(note) 0..1, lp/hp/bp(x, hz, q 0..1), slew(x, up, down), \
            follow(x, attack, release), prev(name) (last frame's value: feedback), sah(x, trigger), noise(), \
            delay.read(time), tanh abs sqrt sin cos exp log floor, clip(x, lo, hi), mix(a, b, t), min max pow, gain(dB). \
            Shapes: sine saw square tri.
            """,
            inputSchema: Schema.object(["source": Schema.string("The patch text")], required: ["source"]),
            annotations: ToolAnnotations(readOnly: true)
        ) { args in
            let source = try args.string("source")
            switch PatchCompiler.cached(source) {
            case .success(let p): return .object(["ok": .bool(true), "program": patchReport(p)])
            case .failure(let e): return .object(["ok": .bool(false), "error": .string("\(e)"), "line": .number(Double(e.line))])
            }
        })

        tools.append(Tool(
            name: "patch_write", title: "Write a patch",
            description: "Put a text on a Patch device. The text is compiled first; an error is returned and nothing changes. A good text replaces the device's program at once (the sound keeps playing, delay lines carry over) and names the device after the patch. Returns a receipt.",
            inputSchema: Schema.object(["track": trackArg, "device": deviceArg, "source": Schema.string("The patch text")], required: ["track", "device", "source"]),
            annotations: ToolAnnotations()
        ) { args in
            let (t, d) = try await patchDevice(args)
            let source = try args.string("source")
            switch PatchCompiler.cached(source) {
            case .failure(let e): throw ToolFailure("the patch does not compile: \(e)")
            case .success(let p):
                return try await session.receipt(.setDeviceSource(track: t.id, device: d.id, source: source, name: p.name == d.name ? nil : p.name),
                                                 extra: ["program": patchReport(p)])
            }
        })

        // MARK: The modular patch, see docs/patcher.md

        @Sendable func portJSON(_ p: ModulePort) -> JSONValue {
            var o: [String: JSONValue] = ["name": .string(p.name), "type": .string(p.type.rawValue)]
            if p.type == .audio || p.type == .control {
                o["default"] = .number(p.def); o["min"] = .number(p.min); o["max"] = .number(p.max)
                if !p.unit.isEmpty { o["unit"] = .string(p.unit) }
            }
            return .object(o)
        }
        @Sendable func moduleJSON(_ m: PatchModule) -> JSONValue {
            let ports = PatchModules.ports(of: m)
            var o: [String: JSONValue] = ["id": .string(m.id), "kind": .string(m.kind), "label": .string(PatchModules.label(m)),
                                          "x": .number(m.x), "y": .number(m.y), "onPanel": .bool(m.isOnPanel),
                                          "inputs": .array(ports.inputs.map(portJSON)), "outputs": .array(ports.outputs.map(portJSON))]
            if !m.values.isEmpty { o["values"] = .object(m.values.mapValues { .number($0) }) }
            if !m.settings.isEmpty { o["settings"] = .object(m.settings.mapValues { .string($0) }) }
            if let s = m.source { o["source"] = .string(s) }
            return .object(o)
        }
        @Sendable func documentJSON(_ doc: PatchDocument) -> JSONValue {
            .object(["name": .string(doc.name), "modules": .array(doc.modules.map(moduleJSON)),
                     "cables": .array(doc.cables.map { .string("\($0.from).\($0.fromPort) -> \($0.to).\($0.toPort)") })])
        }

        tools.append(Tool(
            name: "patch_modules", title: "The module kinds of a patch",
            description: "Every module kind a patch graph can hold, with its ports (name, type, default, range, unit) and settings. Use the ids with patch_edit.",
            inputSchema: Schema.object([:]),
            annotations: ToolAnnotations(readOnly: true)
        ) { _ in
            .object(["modules": .array(PatchModules.all.map { spec in
                var o: [String: JSONValue] = ["kind": .string(spec.id), "name": .string(spec.name), "category": .string(spec.category), "help": .string(spec.help),
                                              "inputs": .array(spec.inputs.map(portJSON)), "outputs": .array(spec.outputs.map(portJSON))]
                if !spec.settings.isEmpty { o["settings"] = .object(Dictionary(uniqueKeysWithValues: spec.settings.map { ($0.key, JSONValue.array($0.choices.map { .string($0) })) })) }
                if !spec.numbers.isEmpty { o["numbers"] = .object(spec.numbers.mapValues { .number($0) }) }
                if spec.single { o["single"] = .bool(true) }
                return .object(o)
            }), "rules": .string("Cables join an output to an input of the same type; control also goes into audio. Several cables into one input sum. A cable that closes a loop gets one frame of delay. A module on the panel shows its inputs without a cable as knobs of the device (key module.port); a Knob module is a knob of its own (key = its id). A Script module's in, out and param lines are its ports. A patch needs an Audio Out module.")])
        })

        tools.append(Tool(
            name: "patch_edit", title: "Edit a patch graph step by step",
            description: """
            Apply steps to the graph of a Patch device, in order; the result is compiled and put on the device as one undo step. \
            A text on the device becomes a graph with one Script module first. Steps (JSON objects): \
            {"op":"add","kind":"osc","id":"osc1","x":100,"y":100} (id optional), {"op":"remove","id":"osc1"}, \
            {"op":"move","id":"osc1","x":..,"y":..}, {"op":"connect","from":"osc1.out","to":"lp1.in"}, {"op":"disconnect","from":..,"to":..}, \
            {"op":"set","id":"lp1","key":"cutoff","value":800} (an input without a cable, or a number such as a knob's min/max/def/log, a delay's length, a const's value), \
            {"op":"setting","id":"osc1","key":"shape","value":"saw"}, {"op":"source","id":"s1","text":"patch …"} (a Script's text), \
            {"op":"label","id":"k1","label":"Cutoff"}, {"op":"expose","id":"lp1","on":true} (on the panel), {"op":"rename","name":"My Patch"}. \
            A step that cannot be done stops the edit; nothing changes. patch_modules lists the kinds and ports.
            """,
            inputSchema: Schema.object(["track": trackArg, "device": deviceArg, "steps": .object(["type": .string("array"), "description": .string("The steps, in order"), "items": Schema.anyObject("One step")])],
                                       required: ["track", "device", "steps"]),
            annotations: ToolAnnotations()
        ) { args in
            let (t, d) = try await patchDevice(args)
            guard var doc = PatchDocument.parse(d.source ?? "") else { throw ToolFailure("the device's patch does not parse") }
            guard case .array(let steps) = args.raw["steps"] ?? .null else { throw ToolFailure("steps is an array of step objects") }
            func str(_ o: [String: JSONValue], _ k: String) -> String? { if case .string(let s) = o[k] ?? .null { return s }; return nil }
            func num(_ o: [String: JSONValue], _ k: String) -> Double? { if case .number(let n) = o[k] ?? .null { return n }; return nil }
            func endpoint(_ s: String?, _ what: String) throws -> (String, String) {
                guard let s, let dot = s.firstIndex(of: ".") else { throw ToolFailure("\(what) is module.port") }
                return (String(s[..<dot]), String(s[s.index(after: dot)...]))
            }
            for (n, step) in steps.enumerated() {
                guard case .object(let o) = step, let op = str(o, "op") else { throw ToolFailure("step \(n + 1) needs an op") }
                let edit: PatchEdit
                switch op {
                case "add":
                    guard let kind = str(o, "kind") else { throw ToolFailure("step \(n + 1): add needs a kind") }
                    edit = .add(kind: kind, id: str(o, "id"), x: num(o, "x") ?? Double(60 + doc.modules.count * 40), y: num(o, "y") ?? 100)
                case "remove": edit = .remove(id: str(o, "id") ?? "")
                case "move": edit = .move(id: str(o, "id") ?? "", x: num(o, "x") ?? 0, y: num(o, "y") ?? 0)
                case "connect", "disconnect":
                    let (a, ap) = try endpoint(str(o, "from"), "from"), (b, bp) = try endpoint(str(o, "to"), "to")
                    edit = op == "connect" ? .connect(from: a, fromPort: ap, to: b, toPort: bp) : .disconnect(from: a, fromPort: ap, to: b, toPort: bp)
                case "set":
                    guard let v = num(o, "value") else { throw ToolFailure("step \(n + 1): set needs a number value") }
                    edit = .setValue(id: str(o, "id") ?? "", key: str(o, "key") ?? "", value: v)
                case "setting": edit = .setSetting(id: str(o, "id") ?? "", key: str(o, "key") ?? "", value: str(o, "value") ?? "")
                case "source": edit = .setSource(id: str(o, "id") ?? "", source: str(o, "text") ?? "")
                case "label": edit = .setLabel(id: str(o, "id") ?? "", label: str(o, "label"))
                case "expose":
                    var on = true
                    if case .bool(let b) = o["on"] ?? .null { on = b }
                    edit = .expose(id: str(o, "id") ?? "", on: on)
                case "rename": edit = .rename(str(o, "name") ?? "Patch")
                default: throw ToolFailure("step \(n + 1): unknown op '\(op)'")
                }
                do { try doc.apply(edit) } catch { throw ToolFailure("step \(n + 1) (\(op)): \(error)") }
            }
            let source = doc.source
            var extra: [String: JSONValue] = ["document": documentJSON(doc)]
            var name: String?
            switch PatchCompiler.cached(source) {
            case .success(let p): extra["program"] = patchReport(p); name = p.name == d.name ? nil : p.name
            case .failure(let e): extra["error"] = .string("\(e)")
            }
            return try await session.receipt(.setDeviceSource(track: t.id, device: d.id, source: source, name: name), extra: extra)
        })

        return tools
    }
}
