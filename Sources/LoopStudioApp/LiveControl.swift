import Foundation
import LoopStudioControl
import LoopStudioCore
import LoopStudioProject

/// The running app as an MCP server: `loopstudio mcp` finds the socket and forwards to it, so an agent edits
/// the project that is open on screen. Every tool call hops to the main actor, like a click would.
@MainActor
final class LiveControl {
    private var transport: SocketTransport?
    private(set) var socketPath: String?
    private(set) var problem: String?

    func start(model: AppModel) {
        let session = AppSession(model: model)
        let server = LoopStudioServer.make(session: session, extraTools: AppTools.tools(model: model), note: AppTools.note)
        let transport = SocketTransport(server: server)
        do {
            try transport.start()
            self.transport = transport
            socketPath = transport.path
        } catch {
            problem = "\(error)"
        }
    }

    func stop() { transport?.stop() }
}

/// The open project of the app, seen as an `EditSession`. `grouped`: the edits go into the app's open undo
/// group (the in-app assistant: one turn, one undo step).
final class AppSession: EditSession, @unchecked Sendable {
    private let model: AppModel
    private let grouped: Bool

    init(model: AppModel, grouped: Bool = false) {
        self.model = model
        self.grouped = grouped
    }

    var isOpen: Bool { get async { true } }
    var path: String? { get async { await MainActor.run { model.packageURL.path } } }
    var packageURL: URL? { get async { await MainActor.run { model.packageURL } } }

    func create(at url: URL, name: String, sampleRate: Double) async throws {
        try await MainActor.run { try model.createProject(at: url, name: name, sampleRate: sampleRate) }
    }

    func open(at url: URL) async throws -> SessionOpened {
        try await MainActor.run { try model.openForControl(url) }
        return SessionOpened(path: url.path)
    }

    func save() async throws {
        // A save that failed must not come back as success: the agent would go on with edits that are not on disk.
        let saved = await MainActor.run { model.save() }
        guard saved else { throw ToolFailure("save failed: \(await MainActor.run { model.status })") }
    }
    func project() async throws -> Project { await MainActor.run { model.project } }
    func isDirty() async -> Bool { await MainActor.run { model.dirty } }
    func revision() async -> Int { await MainActor.run { model.revision } }

    func apply(_ command: Command, coalescingKey: String?) async throws {
        do { try await MainActor.run { try model.tryApply(command, key: coalescingKey, grouped: grouped) } }
        catch { throw ToolFailure("command rejected: \(error)") }
    }

    /// Before, apply and after in one main-actor step, so a click in between cannot land in the receipt.
    func applied(_ command: Command, coalescingKey: String?) async throws -> AppliedChange {
        try await MainActor.run {
            let before = model.project, revisionBefore = model.revision
            do { try model.tryApply(command, key: coalescingKey, grouped: grouped) }
            catch { throw ToolFailure("command rejected: \(error)") }
            return AppliedChange(before: before, after: model.project, revisionBefore: revisionBefore, revisionAfter: model.revision)
        }
    }

    func undo() async throws -> Bool { await MainActor.run { let could = model.canUndo; model.undo(); return could } }
    func redo() async throws -> Bool { await MainActor.run { let could = model.canRedo; model.redo(); return could } }
}

/// The tools only the app has: it plays.
enum AppTools {
    static let note = """
    This server is the running LoopStudio app: every change shows on screen and sounds at once, on the project the app has open (project_info shows which). project_open and project_new switch the app to another project. transport plays and stops; launch starts session clips and scenes; app_status reads the transport, the position and the selection.
    """

    static func tools(model: AppModel) -> [Tool] {
        let box = ModelBox(model)
        return [
            Tool(name: "app_status", title: "App status",
                 description: "The transport (playing, position, tempo), the open project, the selection, Link peers and the last status line of the app.",
                 inputSchema: Schema.object(), annotations: .read) { _ in
                await box.on { status($0) }
            },
            Tool(name: "ui_state", title: "What is on screen",
                 description: """
                 The screen in its own words: the open view (session or arrangement), the selected track with its position, its device \
                 chain (name, id, position, bypass, the knobs with their keys and values), its session slots (row from 1, clip name, playing), \
                 the marked device, the selected clips, the open panel, the browser tab. Call it before acting on "this", "the marked \
                 device", "slot 2" and the like.
                 """,
                 inputSchema: Schema.object(), annotations: .read) { _ in
                await box.on { uiState($0) }
            },
            Tool(name: "transport", title: "Transport",
                 description: "play: from the cursor. stop: stop; a second stop goes back to the start. pause / continue: stop in place and go on. seek: move the cursor to a tick (also while playing).",
                 inputSchema: Schema.object([
                    "action": Schema.string("play | stop | pause | continue | seek"),
                    "tick": Schema.integer("For seek: the position in ticks (960 per quarter)", minimum: 0),
                 ], required: ["action"]),
                 annotations: ToolAnnotations(idempotent: true)) { args in
                let action = try args.string("action")
                let tick = args.optionalInt("tick")
                return try await box.on { m in
                    switch action {
                    case "play": m.play()
                    case "stop": m.stop()
                    case "pause": m.pause()
                    case "continue": m.play()
                    case "seek":
                        guard let tick else { throw ToolFailure("seek needs 'tick'") }
                        m.seek(to: Tick(Int64(tick)))
                    default: throw ToolFailure("unknown action '\(action)': play, stop, pause, continue or seek")
                    }
                    return status(m)
                }
            },
            Tool(name: "show", title: "Show a track or a clip in the detail panel",
                 description: "Open the detail panel on a track's devices (track) or on a clip (clip), as a click on the Track or Clip tab would. For the person, or for a screenshot.",
                 inputSchema: Schema.object([
                    "track": Schema.string("Track id, name or position from 1: its devices are shown"),
                    "clip": Schema.string("Clip id or name: the clip is shown"),
                 ]),
                 annotations: ToolAnnotations(idempotent: true)) { args in
                let track = args.optionalString("track"), clip = args.optionalString("clip")
                return try await box.on { m in
                    if let clip {
                        let (_, c) = try Resolve.clip(clip, in: m.project)
                        m.selectedClip = c.id
                        m.detailTab = .clip
                        m.detailOpen = true
                    } else if let track {
                        let t = try Resolve.track(track, in: m.project)
                        m.openTrackInspector(t.id)
                    } else {
                        throw ToolFailure("give track or clip")
                    }
                    return status(m)
                }
            },
            Tool(name: "launch", title: "Launch session clips",
                 description: "Start a session slot (track + slot), a whole scene row (scene), stop one track's clips (stopTrack) or all of them (stopAll). Launches follow the slot's launch grid; the transport starts when it was stopped.",
                 inputSchema: Schema.object([
                    "track": Schema.string("Track id, with slot or stopTrack"),
                    "slot": Schema.integer("Slot row, from 0", minimum: 0),
                    "scene": Schema.integer("Scene row, from 0", minimum: 0),
                    "stopTrack": Schema.string("Track id whose clips stop at the next bar"),
                    "stopAll": .object(["type": .string("boolean"), "description": .string("Stop every session clip at the next bar")]),
                 ]),
                 annotations: ToolAnnotations(idempotent: false)) { args in
                let track = args.optionalString("track"), slot = args.optionalInt("slot"), scene = args.optionalInt("scene")
                let stopTrack = args.optionalString("stopTrack"), stopAll = args.raw["stopAll"]?.boolValue ?? false
                return try await box.on { m in
                    if let track, let slot {
                        guard let uuid = UUID(uuidString: track), case let id = TrackID(uuid), let t = m.project.track(id) else { throw ToolFailure("no track \(track)") }
                        guard slot >= 0, slot < t.slots.count, t.slots[slot] != nil else { throw ToolFailure("slot \(slot) of \(t.name) is empty") }
                        m.launch(track: id, row: slot)
                    } else if let scene {
                        m.launchScene(scene)
                    } else if let stopTrack {
                        guard let uuid = UUID(uuidString: stopTrack), case let id = TrackID(uuid), m.project.track(id) != nil else { throw ToolFailure("no track \(stopTrack)") }
                        m.stopTrack(id)
                    } else if stopAll {
                        m.stopAllClips()
                    } else {
                        throw ToolFailure("give track and slot, or scene, or stopTrack, or stopAll")
                    }
                    return status(m)
                }
            },
        ]
    }

    @MainActor
    private static func status(_ m: AppModel) -> JSONValue {
        var o: [String: JSONValue] = [
            "playing": .bool(m.transportPlaying),
            "recording": .bool(m.recording),
            "tick": .number(Double(m.currentTick.rawValue)),
            "position": .string(m.positionText()),
            "time": .string(m.timeText()),
            "bpm": .number(m.bpm),
            "project": .string(m.project.name),
            "path": .string(m.packageURL.path),
            "unsavedChanges": .bool(m.dirty),
            "revision": .number(Double(m.revision)),
            "linkPeers": .number(Double(m.linkPeers)),
            "view": .string(m.viewMode == .session ? "session" : "arrangement"),
            "status": .string(m.status),
        ]
        if let t = m.selectedTrack { o["selectedTrack"] = .string(t.description) }
        if let c = m.selectedClip { o["selectedClip"] = .string(c.description) }
        // The session clips that sound now, per track.
        let now = m.sessionTick
        let playing: [JSONValue] = m.project.tracks.flatMap { t -> [JSONValue] in
            t.slots.indices.compactMap { row -> JSONValue? in
                guard case .playing = m.slotState(track: t, row: row, at: now) else { return nil }
                return .object(["track": .string(t.id.description), "trackName": .string(t.name), "slot": .number(Double(row)),
                                "clip": .string(t.slots[row].map { m.clipName($0.clip) } ?? "")])
            }
        }
        if !playing.isEmpty { o["sessionPlaying"] = .array(playing) }
        return .object(o)
    }

    /// The screen as a structured snapshot, in the words of the UI.
    @MainActor
    static func uiState(_ m: AppModel) -> JSONValue {
        let p = m.project
        let reader = ReadBack.Reader(p)
        func device(_ d: DeviceSlot, position: Int, on track: Track) -> JSONValue {
            var o: [String: JSONValue] = [
                "id": .string(d.id.description), "name": .string(d.name), "position": .number(Double(position)),
                "format": .string(d.format), "identifier": .string(d.identifier), "bypassed": .bool(d.bypassed),
                "folded": .bool(m.foldedDevices.contains(d.id)), "marked": .bool(m.selectedDevice == d.id),
            ]
            if let spec = d.spec {
                o["knobs"] = .array(spec.params.map { param in
                    var k: [String: JSONValue] = ["key": .string(param.key), "name": .string(param.name),
                                                  "value": .number(d.params[param.key] ?? param.def)]
                    if let text = reader.paramValue(track.id, d.id, param.key) { k["shown"] = .string(text) }
                    return .object(k)
                })
            } else if let params = d.pluginParams {
                o["knobs"] = .array(params.prefix(64).map { .object(["key": .string($0.key), "name": .string($0.name), "value": .number(d.params[$0.key] ?? $0.def)]) })
            }
            if let rack = d.rack {
                o["chains"] = .array(rack.chains.map { chain in
                    .object(["id": .string(chain.id.description), "name": .string(chain.name),
                             "devices": .array(chain.devices.enumerated().map { device($0.element, position: $0.offset + 1, on: track) })])
                })
            }
            return .object(o)
        }
        func trackSummary(_ t: Track, position: Int?) -> JSONValue {
            var o: [String: JSONValue] = [
                "id": .string(t.id.description), "name": .string(t.name), "kind": .string(t.kind.rawValue),
                "volumeDb": .number(t.volumeDb), "pan": .number(t.pan), "mute": .bool(t.mute), "solo": .bool(t.solo),
                "armed": .bool(m.armedTracks.contains(t.id)),
            ]
            if let position { o["position"] = .number(Double(position)) }
            return .object(o)
        }
        var o: [String: JSONValue] = [
            "view": .string(m.viewMode.rawValue),
            "browserTab": .string(m.sidebarTab.rawValue),
            "panel": .string(m.detailOpen ? (m.detailTab == .devices ? "devices" : "clip") : "closed"),
            "playing": .bool(m.transportPlaying),
            "position": .string(m.positionText()),
            "bpm": .number(m.bpm),
            "tracks": .array(p.tracks.enumerated().map { trackSummary($0.element, position: $0.offset + 1) }),
        ]
        if let id = m.selectedTrack, let t = p.track(id) {
            let position = p.tracks.firstIndex { $0.id == id }.map { $0 + 1 }
            var sel = trackSummary(t, position: position).objectValue ?? [:]
            sel["devices"] = .array(t.devices.enumerated().map { device($0.element, position: $0.offset + 1, on: t) })
            let now = m.sessionTick
            sel["slots"] = .array(t.slots.enumerated().map { row, slot in
                guard let slot else { return .object(["row": .number(Double(row + 1)), "empty": .bool(true)]) }
                var s: [String: JSONValue] = ["row": .number(Double(row + 1)), "clip": .string(m.clipName(slot.clip)), "clipId": .string(slot.clip.id.description)]
                if case .playing = m.slotState(track: t, row: row, at: now) { s["playing"] = .bool(true) }
                return .object(s)
            })
            sel["sends"] = .array(t.sends.map { .object(["to": .string(reader.trackName($0.target)), "db": .number($0.levelDb)]) })
            o["selectedTrack"] = .object(sel)
        }
        if let d = m.selectedDevice, let tid = m.selectedTrack, let t = p.track(tid), let dev = t.device(d) {
            o["markedDevice"] = .object(["id": .string(d.description), "name": .string(dev.name), "track": .string(t.name)])
        }
        if !m.selectedClips.isEmpty {
            o["selectedClips"] = .array(m.selectedClips.compactMap { id in
                guard let info = reader.clipInfo(id) else { return nil }
                return .object(["id": .string(id.description), "name": .string(info.name), "where": .string(info.path), "detail": .string(info.detail)])
            })
        }
        if let row = m.selectedSceneRow { o["selectedScene"] = .number(Double(row + 1)) }
        if let l = p.loop { o["loop"] = .string("\(ReadBack.ticks(l.start)) to \(ReadBack.ticks(l.end))\(l.enabled ? "" : " (off)")") }
        return .object(o)
    }

    /// Carries the model into Sendable tool handlers; every use hops to the main actor.
    private final class ModelBox: @unchecked Sendable {
        let model: AppModel
        init(_ model: AppModel) { self.model = model }
        func on<T: Sendable>(_ body: @MainActor (AppModel) throws -> T) async rethrows -> T {
            try await MainActor.run { try body(model) }
        }
    }
}
