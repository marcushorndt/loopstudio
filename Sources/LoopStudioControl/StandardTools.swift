import Foundation
import LoopStudioCore
import LoopStudioEngine

/// The tools every front end shares (MCP, CLI, the app). One list, so they cannot drift apart.
public enum StandardTools {
    public static let instructions = """
    loopstudio is a native macOS audio workstation. Work on one project at a time.
    1. project_new or project_open first. Projects are folders that end in .loopstudio.
    2. Read with project_info, track_list and track_get.
    3. Change with command_apply. It takes one command as JSON; command_examples shows every command type.
       Use a "batch" command to make several changes as one undo step.
    4. Every change goes to a crash journal at once. project_save writes the project files. undo and redo work on commands.
    5. Tick positions use 960 ticks per quarter note. A 4/4 bar is 3840 ticks.
    A rejected command returns isError with the reason. Nothing changes when a command is rejected.
    """

    // MARK: Registry

    public static func registry(session: ProjectSession) -> ToolRegistry {
        var r = ToolRegistry()

        r.add(Tool(
            name: "project_new", title: "New project",
            description: "Create a new empty project folder. Fails if a project already exists at the path. Opens it.",
            inputSchema: Schema.object([
                "path": Schema.string("Absolute path ending in .loopstudio. A leading ~ is allowed."),
                "name": Schema.string("Project name. Default: the folder name."),
                "sampleRate": Schema.number("Sample rate in Hz. Default 48000."),
            ], required: ["path"]),
            annotations: ToolAnnotations(idempotent: false)
        ) { args in
            let url = try fileURL(try args.string("path"))
            let name = args.optionalString("name") ?? url.deletingPathExtension().lastPathComponent
            let rate = args.optionalDouble("sampleRate") ?? 48_000
            guard [44_100, 48_000, 88_200, 96_000, 176_400, 192_000].contains(rate) else {
                throw ToolFailure("sampleRate must be one of 44100, 48000, 88200, 96000, 176400, 192000")
            }
            try await session.create(at: url, name: name, sampleRate: rate)
            return try await summary(session)
        })

        r.add(Tool(
            name: "project_open", title: "Open project",
            description: "Open a project folder. If the app crashed earlier, unsaved changes are restored from the journal and reported.",
            inputSchema: Schema.object(["path": Schema.string("Absolute path ending in .loopstudio.")], required: ["path"]),
            annotations: ToolAnnotations(idempotent: true)
        ) { args in
            let opened = try await session.open(at: try fileURL(try args.string("path")))
            var result = try await summary(session)
            if case .object(var o) = result {
                o["recoveredCommands"] = .number(Double(opened.recoveredCommands))
                o["recoveryFailed"] = .bool(opened.recoveryFailed)
                if let from = opened.migratedFrom { o["migratedFromSchema"] = .number(Double(from)) }
                result = .object(o)
            }
            return result
        })

        r.add(Tool(
            name: "project_save", title: "Save project",
            description: "Write the project files and empty the crash journal.",
            inputSchema: Schema.object(), annotations: ToolAnnotations(idempotent: true)
        ) { _ in
            try await session.save()
            return .object(["saved": .bool(true), "path": .string(await session.path ?? "")])
        })

        r.add(Tool(
            name: "project_info", title: "Project summary",
            description: "Name, tempo, track count, hardware ports, revision, unsaved state, and any problems found in the project.",
            inputSchema: Schema.object(), annotations: .read
        ) { _ in try await summary(session) })

        r.add(Tool(
            name: "track_list", title: "List tracks",
            description: "All tracks with volume, pan, mute, solo, routing and counts of clips and session slots.",
            inputSchema: Schema.object(), annotations: .read
        ) { _ in
            let project = try await session.project()
            return .object(["tracks": try JSONValue(encoding: project.allTracks.map(TrackSummary.init))])
        })

        r.add(Tool(
            name: "track_get", title: "Get track",
            description: "The full data of one track: clips, session slots with follow actions, devices, sends, automation.",
            inputSchema: Schema.object(["id": Schema.string("Track ID (UUID).")], required: ["id"]), annotations: .read
        ) { args in
            let project = try await session.project()
            let id = try trackID(args)
            guard let track = project.track(id) else { throw ToolFailure("no track with id \(id)") }
            return try JSONValue(encoding: track)
        })

        r.add(Tool(
            name: "command_apply", title: "Apply command",
            description: """
            Apply one edit command. The command is a JSON object with one key (the command name) whose value holds the arguments, \
            for example {"setVolume": {"id": "<track id>", "db": -6}}. Call command_examples to see every command. \
            Use {"batch": {"commands": [ ... ]}} for several changes in one undo step. A rejected command changes nothing. \
            Set coalescingKey to merge repeated edits (such as fader moves) into one undo step.
            """,
            inputSchema: Schema.object([
                "command": Schema.anyObject("The command, as described above."),
                "coalescingKey": Schema.string("Optional. Consecutive calls with the same key become one undo step."),
            ], required: ["command"]),
            annotations: ToolAnnotations(destructive: true)
        ) { args in
            let command: Command = try args.decode("command")
            try await session.apply(command, coalescingKey: args.optionalString("coalescingKey"))
            return .object(["applied": .bool(true), "revision": .number(Double(await session.revision()))])
        })

        r.add(Tool(
            name: "command_examples", title: "Command examples",
            description: "One valid example for each kind of command, to copy and change.",
            inputSchema: Schema.object(), annotations: .read
        ) { _ in .object(try examples()) })

        for (name, title, redo) in [("undo", "Undo", false), ("redo", "Redo", true)] {
            r.add(Tool(
                name: name, title: title, description: "\(title) the last change. Returns whether anything changed.",
                inputSchema: Schema.object(), annotations: ToolAnnotations(destructive: false)
            ) { _ in
                let changed = redo ? try await session.redo() : try await session.undo()
                return .object(["changed": .bool(changed), "revision": .number(Double(await session.revision()))])
            })
        }

        r.add(Tool(
            name: "audio_devices", title: "Sound cards",
            description: "All sound cards on this Mac with their channels and names, sample rates, buffer sizes and latency. Use the uid to refer to a device.",
            inputSchema: Schema.object(), annotations: .read
        ) { _ in
            .object([
                "devices": try JSONValue(encoding: AudioDeviceCatalog.devices()),
                "defaultOutputUID": AudioDeviceCatalog.defaultOutputUID().map { .string($0) } ?? .null,
                "defaultInputUID": AudioDeviceCatalog.defaultInputUID().map { .string($0) } ?? .null,
            ])
        })

        r.add(Tool(
            name: "midi_endpoints", title: "MIDI devices",
            description: "MIDI sources (inputs) and destinations (outputs) with their stable unique IDs.",
            inputSchema: Schema.object(), annotations: .read
        ) { _ in
            .object([
                "sources": try JSONValue(encoding: MIDIEndpointCatalog.sources()),
                "destinations": try JSONValue(encoding: MIDIEndpointCatalog.destinations()),
            ])
        })

        r.add(Tool(
            name: "io_resolve", title: "Preview audio routing",
            description: """
            Show how the project's logical ports (Main, Cue, inputs) map to the physical channels of the sound cards connected now. \
            Pass a profile to test a choice of devices and channels; omit it to use the system defaults. \
            Changes nothing. The issues list says what is missing or wrong.
            """,
            inputSchema: Schema.object([
                "profile": Schema.anyObject("Optional AudioIOProfile: outputDeviceUID, inputDeviceUID, sampleRate, bufferFrames, outputs and inputs as [{port, channels}]."),
            ]), annotations: .read
        ) { args in
            let project = try await session.project()
            let profile: AudioIOProfile = try args.decodeOptional("profile") ?? AudioIOProfile(sampleRate: project.sampleRate)
            let resolved = IOResolver.resolve(profile: profile, ports: project.ports, used: project.usedPortIDs,
                                              devices: AudioDeviceCatalog.devices(),
                                              defaultOutputUID: AudioDeviceCatalog.defaultOutputUID(),
                                              defaultInputUID: AudioDeviceCatalog.defaultInputUID())
            func mapping(_ m: [PortID: [Int]]) -> JSONValue {
                .array(project.ports.compactMap { port in
                    m[port.id].map { .object(["port": .string(port.id.description), "name": .string(port.name),
                                              "channels": .array($0.map { .number(Double($0)) })]) }
                })
            }
            return .object([
                "outputDevice": resolved.outputDevice.map { .string($0.name) } ?? .null,
                "inputDevice": resolved.inputDevice.map { .string($0.name) } ?? .null,
                "sampleRate": .number(resolved.sampleRate),
                "bufferFrames": .number(Double(resolved.bufferFrames)),
                "outputs": mapping(resolved.outputs),
                "inputs": mapping(resolved.inputs),
                "issues": .array(resolved.issues.map { .string("\($0)") }),
            ])
        })

        r.add(Tool(
            name: "follow_simulate", title: "Preview follow actions",
            description: """
            Run the follow-action dice for one session slot many times and report how often each outcome happens. \
            Uses the project's random seed and the real decision code. Changes nothing.
            """,
            inputSchema: Schema.object([
                "track": Schema.string("Track ID (UUID)."),
                "slot": Schema.integer("Slot index, starting at 0.", minimum: 0),
                "launches": Schema.integer("How many launches to simulate. Default 1000.", minimum: 1, maximum: 100_000),
            ], required: ["track", "slot"]), annotations: .read
        ) { args in
            let project = try await session.project()
            let id = try trackID(args, key: "track")
            guard let track = project.track(id) else { throw ToolFailure("no track with id \(id)") }
            let index = try args.int("slot")
            guard track.slots.indices.contains(index), let slot = track.slots[index] else { throw ToolFailure("slot \(index) is empty") }
            guard slot.follow != nil else { throw ToolFailure("slot \(index) has no follow actions") }
            let launches = min(max(args.optionalInt("launches") ?? 1_000, 1), 100_000)

            var counts: [String: Int] = [:]
            for n in 0..<launches {
                let random = FollowRandom(seed: project.randomSeed, clip: slot.clip.id, launchCount: n)
                let label: String
                switch FollowResolver.resolve(current: index, slots: track.slots, random: random) {
                case .none: label = "continue"
                case .stop: label = "stop"
                case .play(let target): label = "play slot \(target)"
                }
                counts[label, default: 0] += 1
            }
            let rows = counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { key, value in
                JSONValue.object(["outcome": .string(key), "count": .number(Double(value)),
                                  "percent": .number((Double(value) / Double(launches) * 1000).rounded() / 10)])
            }
            return .object(["launches": .number(Double(launches)), "results": .array(rows)])
        })

        r.add(Tool(
            name: "tempo_convert", title: "Convert time",
            description: "Convert between ticks, seconds and frames using the project's tempo map (including ramps). Give either ticks or seconds.",
            inputSchema: Schema.object([
                "ticks": Schema.integer("Position in ticks (960 per quarter note)."),
                "seconds": Schema.number("Position in seconds."),
            ]), annotations: .read
        ) { args in
            let project = try await session.project()
            let map = project.tempoMap
            let ticks: Tick
            if let t = args.optionalInt("ticks") { ticks = Tick(Int64(t)) }
            else if let s = args.optionalDouble("seconds") { ticks = map.tick(atSeconds: s) }
            else { throw ToolFailure("give ticks or seconds") }
            return .object([
                "ticks": .number(Double(ticks.rawValue)),
                "quarters": .number(ticks.quarters),
                "seconds": .number(map.seconds(at: ticks)),
                "frames": .number(Double(map.frame(at: ticks, sampleRate: project.sampleRate).rawValue)),
                "bpm": .number(map.bpm(at: ticks)),
            ])
        })

        return r
    }

    // MARK: Resources

    public static func resources(session: ProjectSession) -> MCPServer.Resources {
        MCPServer.Resources(
            list: {
                guard await session.isOpen else { return [] }
                return [
                    .init(uri: "loopstudio://project/summary", name: "Project summary", description: "Name, tempo, tracks, ports, problems."),
                    .init(uri: "loopstudio://project/full", name: "Full project", description: "Everything in the project as JSON."),
                ]
            },
            read: { uri in
                switch uri {
                case "loopstudio://project/summary": return try await summary(session).text
                case "loopstudio://project/full": return try JSONValue(encoding: try await session.project()).text
                default: return nil
                }
            })
    }

    // MARK: Shared pieces

    struct TrackSummary: Codable {
        var id: TrackID
        var name: String
        var kind: TrackKind
        var volumeDb: Double
        var pan: Double
        var mute: Bool
        var solo: Bool
        var output: TrackID?
        var hardwareOutput: PortID?
        var audioInput: PortID?
        var clips: Int
        var slots: Int
        var devices: Int

        init(_ t: Track) {
            id = t.id; name = t.name; kind = t.kind; volumeDb = t.volumeDb; pan = t.pan; mute = t.mute; solo = t.solo
            output = t.output; hardwareOutput = t.hardwareOutput; audioInput = t.audioInput
            clips = t.clips.count; slots = t.slots.compactMap { $0 }.count; devices = t.devices.count
        }
    }

    static func summary(_ session: ProjectSession) async throws -> JSONValue {
        let project = try await session.project()
        return .object([
            "path": .string(await session.path ?? ""),
            "name": .string(project.name),
            "sampleRate": .number(project.sampleRate),
            "bpm": .number(project.tempoMap.bpm(at: 0)),
            "tracks": .number(Double(project.tracks.count)),
            "assets": .number(Double(project.assets.count)),
            "ports": try JSONValue(encoding: project.ports),
            "masterId": .string(project.master.id.description),
            "randomSeed": .number(Double(project.randomSeed)),
            "revision": .number(Double(await session.revision())),
            "unsavedChanges": .bool(await session.isDirty()),
            "issues": .array(project.validate().map { .string($0.description) }),
        ])
    }

    /// Expands `~`, then requires an absolute path. A relative path would depend on the server's working directory.
    static func fileURL(_ path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw ToolFailure("path must be absolute (it may start with ~)") }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    static func trackID(_ args: ToolArguments, key: String = "id") throws -> TrackID {
        guard let uuid = UUID(uuidString: try args.string(key)) else { throw ToolFailure("'\(key)' is not a valid UUID") }
        return TrackID(uuid)
    }

    /// Real values, encoded by the real encoder: the examples cannot go out of date without a test failing.
    static func examples() throws -> [String: JSONValue] {
        func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
        let track = Track(id: TrackID(uuid(1)), name: "Drums", kind: .audio)
        let ret = Track(id: TrackID(uuid(2)), name: "Reverb", kind: .returnTrack)
        let follow = FollowActions(a: FollowAction(.next, weight: 3), b: FollowAction(.other, weight: 1), time: .loops(2))
        let slot = SessionSlot(clip: .dummy(DummyClip(id: ClipID(uuid(3)), name: "choose", length: 3840)), follow: follow)
        let commands: [(String, Command)] = [
            ("insertTrack", .insertTrack(track: track, index: 0)),
            ("removeTrack", .removeTrack(id: track.id)),
            ("setTrackName", .setTrackName(id: track.id, name: "Kit")),
            ("setVolume", .setVolume(id: track.id, db: -6)),
            ("setPan", .setPan(id: track.id, pan: -0.25)),
            ("setMute", .setMute(id: track.id, mute: true)),
            ("setSolo", .setSolo(id: track.id, solo: true)),
            ("setOutput", .setOutput(id: track.id, target: ret.id)),
            ("setSends", .setSends(id: track.id, sends: [Send(target: ret.id, levelDb: -12)])),
            ("setSlot (dummy clip with follow actions)", .setSlot(track: track.id, index: 0, slot: slot)),
            ("setSlot (empty a slot)", .setSlot(track: track.id, index: 0, slot: nil)),
            ("removeClip", .removeClip(clip: ClipID(uuid(4)))),
            ("moveClip", .moveClip(clip: ClipID(uuid(4)), toTrack: track.id, start: 3840)),
            ("setClipRange", .setClipRange(clip: ClipID(uuid(4)), start: 0, length: 7680)),
            ("setClipLoop", .setClipLoop(clip: ClipID(uuid(4)), loop: true)),
            ("setTempoPoints", .setTempoPoints(points: [TempoPoint(tick: 0, bpm: 100, ramp: true), TempoPoint(tick: 15360, bpm: 128)])),
            ("setLoop", .setLoop(loop: LoopRegion(start: 0, end: 15360))),
            ("setRandomSeed", .setRandomSeed(seed: 7)),
            ("setAutoLoop", .setAutoLoop(rule: AutoLoopRule(enabled: true, minSeconds: 0, maxSeconds: 20))),
            ("addPort", .addPort(port: IOPort(id: PortID(uuid(5)), name: "Out 5-6", direction: .output, channels: 2), index: nil)),
            ("removePort", .removePort(id: PortID(uuid(5)))),
            ("setHardwareOutput", .setHardwareOutput(id: track.id, port: PortID(uuid(5)))),
            ("setAudioInput", .setAudioInput(id: track.id, port: PortID(uuid(6)))),
            ("setMIDIInput", .setMIDIInput(id: TrackID(uuid(7)), selection: MIDIInputSelection(sourceUID: 12345, sourceName: "Keys", channel: nil))),
            ("batch", .batch(commands: [.setVolume(id: track.id, db: -3), .setPan(id: track.id, pan: 0.5)])),
        ]
        var result: [String: JSONValue] = [:]
        for (name, command) in commands { result[name] = try JSONValue(encoding: command) }
        return result
    }
}
