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

/// The open project of the app, seen as an `EditSession`.
final class AppSession: EditSession, @unchecked Sendable {
    private let model: AppModel

    init(model: AppModel) { self.model = model }

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

    func save() async throws { await MainActor.run { model.save() } }
    func project() async throws -> Project { await MainActor.run { model.project } }
    func isDirty() async -> Bool { await MainActor.run { model.dirty } }
    func revision() async -> Int { await MainActor.run { model.revision } }

    func apply(_ command: Command, coalescingKey: String?) async throws {
        do { try await MainActor.run { try model.tryApply(command, key: coalescingKey) } }
        catch { throw ToolFailure("command rejected: \(error)") }
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

    /// Carries the model into Sendable tool handlers; every use hops to the main actor.
    private final class ModelBox: @unchecked Sendable {
        let model: AppModel
        init(_ model: AppModel) { self.model = model }
        func on<T: Sendable>(_ body: @MainActor (AppModel) throws -> T) async rethrows -> T {
            try await MainActor.run { try body(model) }
        }
    }
}
