import Foundation
import LoopStudioCore
import LoopStudioEngine
import LoopStudioProject

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
            name: "asset_import", title: "Import audio file",
            description: """
            Copy an audio file into the project (stored by content hash, so the same file is never stored twice) and register it as an asset. \
            Returns the asset ID, its length, and whether it would loop or play once under the project's auto-loop rule.
            """,
            inputSchema: Schema.object(["path": Schema.string("Absolute path of an audio file (wav, aiff, caf, mp3, m4a, flac).")], required: ["path"]),
            annotations: ToolAnnotations(idempotent: true)
        ) { args in
            guard let package = await session.packageURL else { throw ToolFailure("no project is open; call project_new or project_open first") }
            let source = try fileURL(try args.string("path"))
            guard FileManager.default.fileExists(atPath: source.path) else { throw ToolFailure("file not found: \(source.path)") }
            var project = try await session.project()

            let imported: Asset
            do { imported = try AssetStore.importFile(source, into: package) }
            catch { throw ToolFailure("cannot import: \(error)") }
            if let existing = project.assets.first(where: { $0.sha256 == imported.sha256 }) {
                return try assetInfo(existing, project: project, alreadyInProject: true)
            }
            try await session.apply(.addAsset(asset: imported))
            project = try await session.project()
            return try assetInfo(imported, project: project, alreadyInProject: false)
        })

        r.add(Tool(
            name: "sample_drop", title: "Drop a sample",
            description: """
            Put a sample on an audio track, on the timeline or in a session slot, the way dragging it in would. \
            The clip gets the project's default fade (so it never clicks) and loops or plays once by the auto-loop rule \
            (short samples loop, long samples play once). Override with 'loop'. Without 'lengthTicks' the clip is as long as the sample at the project tempo.
            """,
            inputSchema: Schema.object([
                "track": Schema.string("Track ID of an audio track."),
                "asset": Schema.string("Asset ID from asset_import."),
                "startTick": Schema.integer("Timeline position in ticks. Default 0. Ignored for a session slot."),
                "lengthTicks": Schema.integer("Clip length in ticks.", minimum: 1),
                "slot": Schema.integer("Put the clip in this session slot instead of on the timeline.", minimum: 0),
                "loop": .object(["type": .string("boolean"), "description": .string("Force loop (true) or one-shot (false).")]),
            ], required: ["track", "asset"]),
            annotations: ToolAnnotations(destructive: true)
        ) { args in
            let project = try await session.project()
            let trackID = try trackID(args, key: "track")
            guard let assetUUID = UUID(uuidString: try args.string("asset")) else { throw ToolFailure("'asset' is not a valid UUID") }
            guard let asset = project.asset(AssetID(assetUUID)) else { throw ToolFailure("no asset with id \(assetUUID)") }
            let start = Tick(Int64(args.optionalInt("startTick") ?? 0))

            let length: Tick
            if let t = args.optionalInt("lengthTicks") { length = Tick(Int64(t)) }
            else { length = project.naturalLength(of: asset, from: start) }
            var clip = project.makeAudioClip(asset: asset.id, start: start, length: max(length, Tick(1)))
            if let loop = args.raw["loop"]?.boolValue { clip.loop = loop }

            if let slot = args.optionalInt("slot") {
                clip.start = 0
                try await session.apply(.setSlot(track: trackID, index: slot, slot: SessionSlot(clip: .audio(clip))))
            } else {
                try await session.apply(.insertClip(track: trackID, clip: .audio(clip)))
            }
            return .object(["clip": .string(clip.id.description), "loop": .bool(clip.loop),
                            "fadeMs": .number(clip.fadeInMs), "lengthTicks": .number(Double(clip.length.rawValue))])
        })

        r.add(Tool(
            name: "render_bounce", title: "Render to WAV",
            description: """
            Render the master mix offline to a 24-bit WAV file. The result is the same as live playback would sound. \
            Returns length, peak and RMS in dB, a loudness curve (RMS per second) and any warnings, so the result can be checked without listening. \
            Tracks sent straight to a hardware port are not in the master mix.
            """,
            inputSchema: Schema.object([
                "path": Schema.string("Absolute path of the WAV file to write. Must end in .wav."),
                "startTick": Schema.integer("Start in ticks. Default 0."),
                "endTick": Schema.integer("End in ticks. Default: the end of the last clip."),
                "tailSeconds": Schema.number("Extra seconds after the last clip (for reverb tails). Default 0."),
                "overwrite": .object(["type": .string("boolean"), "description": .string("Replace an existing file. Default false.")]),
            ], required: ["path"]),
            annotations: ToolAnnotations(destructive: false)
        ) { args in
            let out = try fileURL(try args.string("path"))
            guard out.pathExtension.lowercased() == "wav" else { throw ToolFailure("path must end in .wav") }
            if FileManager.default.fileExists(atPath: out.path), args.raw["overwrite"]?.boolValue != true {
                throw ToolFailure("file exists; pass overwrite: true to replace it")
            }
            guard let package = await session.packageURL else { throw ToolFailure("no project is open") }
            let project = try await session.project()
            let loaded = AudioBank.load(project: project) { AssetStore.fileURL(for: $0, in: package) }
            // Hosted plugins in their own instances, and the saved Session launches.
            let prepared = await OfflineRender.prepare(project, bank: loaded.bank)
            let plan = prepared.plan

            let map = project.tempoMap
            let start = args.optionalInt("startTick").map { map.frame(at: Tick(Int64($0)), sampleRate: project.sampleRate).rawValue } ?? 0
            let end = args.optionalInt("endTick").map { map.frame(at: Tick(Int64($0)), sampleRate: project.sampleRate).rawValue }
            let tail = Int64(((args.optionalDouble("tailSeconds") ?? 0) * project.sampleRate).rounded())
            let audio = withExtendedLifetime(prepared.host) {
                Bounce.render(plan, startFrame: start, endFrame: (end ?? prepared.endFrame) + tail)
            }
            guard audio.frames > 0 else { throw ToolFailure("nothing to render: the range is empty (no clips on audible tracks?)") }

            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: out)
            try Bounce.writeWAV(audio, to: out)

            func dBFS(_ x: Float) -> Double { x <= 0 ? -200 : (Double(20 * log10(x)) * 10).rounded() / 10 }
            let perSecond = Int(project.sampleRate)
            var curve: [JSONValue] = []
            var i = 0
            while i < audio.frames {
                let n = min(perSecond, audio.frames - i)
                var sum = 0.0
                for k in i..<(i + n) { sum += Double(audio.left[k] * audio.left[k] + audio.right[k] * audio.right[k]) }
                curve.append(.number(dBFS(Float((sum / Double(n * 2)).squareRoot()))))
                i += n
            }
            var warnings = plan.warnings + prepared.warnings
            for (id, reason) in loaded.failed.sorted(by: { $0.key.description < $1.key.description }) {
                warnings.append("asset \(id): \(reason)")
            }
            return .object([
                "path": .string(out.path),
                "seconds": .number((Double(audio.frames) / audio.sampleRate * 1000).rounded() / 1000),
                "frames": .number(Double(audio.frames)),
                "sampleRate": .number(audio.sampleRate),
                "peakDb": .number(dBFS(audio.peak)),
                "rmsDb": .number(dBFS(audio.rms)),
                "clipping": .bool(audio.peak > 1),
                "rmsDbPerSecond": .array(curve),
                "warnings": .array(warnings.map { .string($0) }),
            ])
        })

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
            name: "effect_catalog", title: "Built-in effects",
            description: """
            Every built-in effect with its parameters: key, range, default, unit and choices. Use the effect id with \
            insertDevice (BuiltInEffects id) and the keys with setDeviceParam. A key with a "Sync" switch and a \
            "Division" note value follows the song tempo when the switch is 1; the division is an index into "divisions".
            """,
            inputSchema: Schema.object(), annotations: .read
        ) { _ in
            let effects = BuiltInEffects.all.map { spec in
                JSONValue.object([
                    "id": .string(spec.id), "name": .string(spec.name),
                    "params": .array(spec.params.map { p in
                        var o: [String: JSONValue] = ["key": .string(p.key), "name": .string(p.name), "min": .number(p.min),
                                                      "max": .number(p.max), "default": .number(p.def)]
                        if !p.unit.isEmpty { o["unit"] = .string(p.unit) }
                        if !p.choices.isEmpty && !p.rotary { o["choices"] = .array(p.choices.map(JSONValue.string)) }
                        return .object(o)
                    }),
                ])
            }
            return .object(["effects": .array(effects), "divisions": .array(NoteDivision.all.map { .string($0.name) })])
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
        var inputTrack: TrackID?
        var inputChannels: InputChannels?
        var midiInput: MIDIInputSelection?
        var clips: Int
        var slots: Int
        var devices: Int

        init(_ t: Track) {
            id = t.id; name = t.name; kind = t.kind; volumeDb = t.volumeDb; pan = t.pan; mute = t.mute; solo = t.solo
            output = t.output; hardwareOutput = t.hardwareOutput; audioInput = t.audioInput
            inputTrack = t.inputTrack; inputChannels = t.inputChannels; midiInput = t.midiInput
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

    static func assetInfo(_ asset: Asset, project: Project, alreadyInProject: Bool) throws -> JSONValue {
        let seconds = Double(asset.frames) / asset.sampleRate
        return .object([
            "asset": .string(asset.id.description),
            "name": .string(asset.name),
            "seconds": .number((seconds * 1000).rounded() / 1000),
            "sampleRate": .number(asset.sampleRate),
            "channels": .number(Double(asset.channels)),
            "alreadyInProject": .bool(alreadyInProject),
            "wouldLoop": .bool(project.autoLoop.shouldLoop(seconds: seconds)),
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
            ("insertClip (MIDI clip with two notes)", .insertClip(track: TrackID(uuid(7)), clip: .midi(MIDIClip(
                id: ClipID(uuid(4)), start: 0, length: 3840, loop: true,
                notes: [MIDINote(tick: 0, length: 480, pitch: 60), MIDINote(tick: 960, length: 480, pitch: 64, velocity: 90)])))),
            ("setClip (replace a clip by its ID, here trimmed to start one bar later)", .setClip(clip: .midi(MIDIClip(
                id: ClipID(uuid(4)), start: 3840, length: 3840, loop: false, notes: [MIDINote(tick: 0, length: 480, pitch: 67)])))),
            ("removeClip", .removeClip(clip: ClipID(uuid(4)))),
            ("moveClip", .moveClip(clip: ClipID(uuid(4)), toTrack: track.id, start: 3840)),
            ("setClipRange", .setClipRange(clip: ClipID(uuid(4)), start: 0, length: 7680)),
            ("setClipLoop", .setClipLoop(clip: ClipID(uuid(4)), loop: true)),
            ("setTempoPoints", .setTempoPoints(points: [TempoPoint(tick: 0, bpm: 100, ramp: true), TempoPoint(tick: 15360, bpm: 128)])),
            ("setLoop", .setLoop(loop: LoopRegion(start: 0, end: 15360))),
            ("setRandomSeed", .setRandomSeed(seed: 7)),
            ("setDefaultFade", .setDefaultFade(ms: 5)),
            ("setAutoLoop", .setAutoLoop(rule: AutoLoopRule(enabled: true, minSeconds: 0, maxSeconds: 20))),
            ("addPort", .addPort(port: IOPort(id: PortID(uuid(5)), name: "Out 5-6", direction: .output, channels: 2), index: nil)),
            ("removePort", .removePort(id: PortID(uuid(5)))),
            ("setHardwareOutput", .setHardwareOutput(id: track.id, port: PortID(uuid(5)))),
            ("setAudioInput", .setAudioInput(id: track.id, port: PortID(uuid(6)))),
            ("setMIDIInput", .setMIDIInput(id: TrackID(uuid(7)), selection: MIDIInputSelection(sourceUID: 12345, sourceName: "Keys", channel: nil))),
            ("setInputChannels (sound card channels to record, from 0)", .setInputChannels(id: track.id, channels: InputChannels(first: 2, stereo: false))),
            ("setClipColor", .setClipColor(clip: ClipID(uuid(4)), colorIndex: 3)),
            ("setPluginParams", .setPluginParams(track: TrackID(uuid(1)), device: DeviceID(uuid(5)), params: [PluginParam(key: "au.0", name: "Cutoff", min: 20, max: 20000, def: 1000, unit: "Hz")])),
            ("setClipName", .setClipName(clip: ClipID(uuid(4)), name: "Verse")),
            ("setClipEnvelope", .setClipEnvelope(clip: ClipID(uuid(4)), points: [AutomationPoint(tick: 0, value: 0), AutomationPoint(tick: 1920, value: -12)])),
            ("setTrackColor", .setTrackColor(id: track.id, colorIndex: 5)),
            ("setInputTrack (Audio From another track)", .setInputTrack(id: TrackID(uuid(7)), source: track.id)),
            ("setMonitor", .setMonitor(id: TrackID(uuid(7)), mode: .auto)),
            ("setSendsOnly", .setSendsOnly(id: track.id, sendsOnly: true)),
            ("setAssetTempo", .setAssetTempo(id: AssetID(uuid(8)), bpm: 92)),
            ("setClipWarp", .setClipWarp(clip: ClipID(uuid(4)), mode: .beats, markers: [WarpMarker(sourceFrame: 48_000, tick: 960)])),
            ("setAutomation (a volume curve)", .setAutomation(track: track.id, target: ParameterAddress(node: track.id.rawValue, parameter: "volume"),
                                                              points: [AutomationPoint(tick: 0, value: -12), AutomationPoint(tick: 3840, value: 0, curve: .easeInOut)])),
            ("setClipAutomation (a dummy clip moves any track; an audio or MIDI clip moves its own track, node 00000000-0000-0000-0000-000000000000 = own track)",
             .setClipAutomation(clip: ClipID(uuid(3)), target: ParameterAddress(node: track.id.rawValue, parameter: "pan"),
                                points: [AutomationPoint(tick: 0, value: -1, bend: 0.5), AutomationPoint(tick: 1920, value: 1)])),
            ("setClipAutomationLength (unlink: a 16-bar curve over a 1-bar loop; null links it again)",
             .setClipAutomationLength(clip: ClipID(uuid(4)), length: 61_440)),
            ("setMIDINotes", .setMIDINotes(clip: ClipID(uuid(9)), notes: [MIDINote(tick: 0, length: 480, pitch: 60, velocity: 100)])),
            ("insertDevice (built-in effect)", .insertDevice(track: track.id, device: BuiltInEffects.makeSlot("reverb")!, index: nil)),
            ("removeDevice", .removeDevice(track: track.id, device: DeviceID(uuid(10)))),
            ("moveDevice", .moveDevice(track: track.id, device: DeviceID(uuid(10)), to: 0)),
            ("setDeviceParam", .setDeviceParam(track: track.id, device: DeviceID(uuid(10)), key: "mix", value: 0.3)),
            ("setDeviceBypass", .setDeviceBypass(track: track.id, device: DeviceID(uuid(10)), bypassed: true)),
            ("setAudioClip (gain and fades)", .setAudioClip(clip: ClipID(uuid(4)), gainDb: -3, fadeInMs: 2, fadeOutMs: 10, muted: false)),
            ("setLaunches", .setLaunches(launches: [Launch(track: track.id, slot: 0, tick: 0)])),
            ("batch", .batch(commands: [.setVolume(id: track.id, db: -3), .setPan(id: track.id, pan: 0.5)])),
        ]
        var result: [String: JSONValue] = [:]
        for (name, command) in commands { result[name] = try JSONValue(encoding: command) }
        return result
    }
}
