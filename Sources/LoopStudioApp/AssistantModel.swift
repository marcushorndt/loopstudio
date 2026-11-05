import Foundation
import LoopStudioControl
import LoopStudioCore
import Security

/// The in-app assistant: the transcript, the turn loop, plan mode and the key. The model's words are shown
/// as commentary; what the store did is shown as receipt cards built from the tool results.
@MainActor @Observable
final class AssistantModel {
    enum ToolState: Equatable {
        case running
        /// Waits for Apply or Skip (plan mode, or a removal).
        case pending(destructive: Bool)
        case done(summary: [String], isError: Bool, receipt: Receipt?)
        case skipped
    }

    enum Row: Identifiable, Equatable {
        case user(id: String, text: String)
        case assistant(id: String, text: String)
        case progress(id: String, text: String)
        case tool(id: String, name: String, input: JSONValue, state: ToolState)
        case notice(id: String, text: String)

        var id: String {
            switch self {
            case .user(let id, _), .assistant(let id, _), .progress(let id, _), .tool(let id, _, _, _), .notice(let id, _): id
            }
        }
    }

    static let models: [(id: String, name: String)] = [
        ("claude-opus-5-5", "Claude Opus 5.5"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
        ("claude-haiku-5-5", "Claude Haiku 5.5"),
        ("claude-fable-5-1", "Claude Fable 5.1"),
    ]
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    private(set) var rows: [Row] = []
    var input = ""
    private(set) var running = false
    private(set) var usage = TokenUsage()
    private(set) var cost = 0.0
    /// The last finished turn changed the project and nothing was undone since.
    private(set) var lastTurnUndoable = false

    var askBeforeChanges: Bool = UserDefaults.standard.object(forKey: "assistantAsk") as? Bool ?? false {
        didSet { UserDefaults.standard.set(askBeforeChanges, forKey: "assistantAsk") }
    }
    var modelID: String = UserDefaults.standard.string(forKey: "assistantModel") ?? "claude-opus-5-5" {
        didSet { UserDefaults.standard.set(modelID, forKey: "assistantModel"); engine = nil }
    }
    var effort: String = UserDefaults.standard.string(forKey: "assistantEffort") ?? "medium" {
        didSet { UserDefaults.standard.set(effort, forKey: "assistantEffort"); engine = nil }
    }
    /// The key, from the Keychain. Setting it writes the Keychain; empty removes it.
    var apiKey: String = Keychain.read() ?? "" {
        didSet { Keychain.write(apiKey); engine = nil }
    }
    var hasKey: Bool { !apiKey.isEmpty }
    var modelName: String { Self.models.first { $0.id == modelID }?.name ?? modelID }

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var engine: AssistantEngine?
    @ObservationIgnored private var decisions: [String: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pendingSerial = 0

    init(app: AppModel) { self.app = app }

    // MARK: The engine

    private func makeEngine() -> AssistantEngine {
        let session = AppSession(model: app, grouped: true)
        var registry = StandardTools.registry(session: session)
        for tool in StandardTools.namedTools(session: session) { registry.add(tool) }
        for tool in AppTools.tools(model: app) { registry.add(tool) }
        let config = AssistantConfig(model: modelID, effort: effort)
        return AssistantEngine(transport: URLSessionTransport(apiKey: apiKey), registry: registry, config: config)
    }

    /// One line about the screen, so a short request needs no ui_state call.
    private func screenContext() -> String {
        var parts = ["Project \"\(app.project.name)\"", "view \(app.viewMode.rawValue)", String(format: "%.1f bpm", app.bpm)]
        if let id = app.selectedTrack, let t = app.project.track(id) {
            let position = app.project.tracks.firstIndex { $0.id == id }.map { " (track \($0 + 1))" } ?? ""
            parts.append("selected track \"\(t.name)\"\(position)")
            if let d = app.selectedDevice, let dev = t.device(d) { parts.append("marked device \"\(dev.name)\"") }
        }
        if let c = app.selectedClip, let found = app.project.findClip(c) { parts.append("selected clip \"\(app.clipName(found.clip))\"") }
        return "[Screen now: " + parts.joined(separator: ", ") + ". Call ui_state for details.]"
    }

    // MARK: Turns

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running, hasKey else { return }
        input = ""
        rows.append(.user(id: UUID().uuidString, text: text))
        running = true
        lastTurnUndoable = false
        if engine == nil { engine = makeEngine() }
        guard let engine else { return }
        let context = screenContext()
        let ask = askBeforeChanges
        app.beginUndoGroup()

        let (stream, continuation) = AsyncStream<AssistantEvent>.makeStream()
        let gate: ToolGate = { [weak self] name, input, destructive in
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                Task { @MainActor in
                    guard let self else { cont.resume(returning: false); return }
                    self.askPending(name: name, input: input, destructive: destructive, cont)
                }
            }
        }
        task = Task { [weak self] in
            let runner = Task {
                await engine.run(user: text, context: context, askBeforeChanges: ask, gate: gate) { continuation.yield($0) }
                continuation.finish()
            }
            for await event in stream { self?.handle(event) }
            _ = await runner.value
            guard let self else { return }
            self.lastTurnUndoable = self.app.endUndoGroup()
            self.running = false
            self.task = nil
        }
    }

    func stop() {
        guard let engine else { return }
        Task { await engine.stop() }
        for (id, cont) in decisions { cont.resume(returning: false); markSkipped(id) }
        decisions = [:]
    }

    func clear() {
        guard !running else { return }
        rows = []
        engine = nil
        usage = TokenUsage()
        cost = 0
        lastTurnUndoable = false
    }

    func undoLastTurn() {
        guard lastTurnUndoable, !running else { return }
        app.undo()
        lastTurnUndoable = false
        rows.append(.notice(id: UUID().uuidString, text: "The last turn was undone."))
    }

    // MARK: Plan mode

    private func askPending(name: String, input: JSONValue, destructive: Bool, _ cont: CheckedContinuation<Bool, Never>) {
        // The engine reported the call already; turn its running card into a pending one.
        if let i = rows.lastIndex(where: { if case .tool(_, let n, let inp, .running) = $0 { return n == name && inp == input }; return false }) {
            let id = rows[i].id
            rows[i] = .tool(id: id, name: name, input: input, state: .pending(destructive: destructive))
            decisions[id] = cont
        } else {
            pendingSerial += 1
            let id = "pending-\(pendingSerial)"
            rows.append(.tool(id: id, name: name, input: input, state: .pending(destructive: destructive)))
            decisions[id] = cont
        }
    }

    func decide(_ id: String, apply: Bool) {
        guard let cont = decisions.removeValue(forKey: id) else { return }
        if apply {
            if let i = rows.firstIndex(where: { $0.id == id }), case .tool(_, let n, let inp, _) = rows[i] {
                rows[i] = .tool(id: id, name: n, input: inp, state: .running)
            }
        } else {
            markSkipped(id)
        }
        cont.resume(returning: apply)
    }

    private func markSkipped(_ id: String) {
        if let i = rows.firstIndex(where: { $0.id == id }), case .tool(_, let n, let inp, _) = rows[i] {
            rows[i] = .tool(id: id, name: n, input: inp, state: .skipped)
        }
    }

    // MARK: Events

    private func handle(_ event: AssistantEvent) {
        switch event {
        case .text(let delta):
            if case .assistant(let id, let text)? = rows.last {
                rows[rows.count - 1] = .assistant(id: id, text: text + delta)
            } else {
                rows.append(.assistant(id: UUID().uuidString, text: delta))
            }
        case .progress(let delta):
            if case .progress(let id, let text)? = rows.last {
                rows[rows.count - 1] = .progress(id: id, text: text + delta)
            } else {
                rows.append(.progress(id: UUID().uuidString, text: delta))
            }
        case .toolCall(let id, let name, let input):
            rows.append(.tool(id: id, name: name, input: input, state: .running))
        case .toolResult(let id, let name, let result, let isError, let receipt):
            let summary: [String]
            if let receipt { summary = receipt.changes.map(\.line) }
            else if isError { summary = [result["error"]?.stringValue ?? result.text] }
            else { summary = [Self.shortResult(name: name, result: result)] }
            replaceTool(id: id, with: .done(summary: summary, isError: isError, receipt: receipt))
        case .toolSkipped(let id, _):
            replaceTool(id: id, with: .skipped)
        case .notice(let text):
            rows.append(.notice(id: UUID().uuidString, text: text))
        case .usage(let u, let model):
            usage.add(u)
            cost += u.cost(model: model)
        case .finished(let reason):
            if reason == "stopped" { rows.append(.notice(id: UUID().uuidString, text: "Stopped.")) }
        }
    }

    private func replaceTool(id: String, with state: ToolState) {
        guard let i = rows.lastIndex(where: { $0.id == id }), case .tool(_, let n, let inp, _) = rows[i] else { return }
        rows[i] = .tool(id: id, name: n, input: inp, state: state)
    }

    /// One line for a read tool's result.
    static func shortResult(name: String, result: JSONValue) -> String {
        switch name {
        case "ui_state": return "Read the screen."
        case "app_status": return "Read the transport."
        case "effect_catalog": return "Read the device catalog."
        case "command_examples": return "Read the command examples."
        case "track_list": return "Read the tracks."
        case "track_get": return "Read a track."
        case "project_info": return "Read the project summary."
        case "transport": return "Transport: \(result["playing"]?.boolValue == true ? "playing" : "stopped") at \(result["position"]?.stringValue ?? "")."
        case "launch": return "Launched."
        case "undo": return result["changed"]?.boolValue == true ? "Undone." : "Nothing to undo."
        case "redo": return result["changed"]?.boolValue == true ? "Redone." : "Nothing to redo."
        default:
            let text = result.text
            return text.count > 160 ? String(text.prefix(157)) + "…" : text
        }
    }

    /// A short label of the arguments for a card: `Drums › Delay · feedback 0.4`.
    static func inputLabel(_ input: JSONValue) -> String {
        guard let o = input.objectValue else { return "" }
        let order = ["track", "device", "clip", "param", "name", "kind", "value", "db", "bpm", "index", "slot", "length", "start", "end", "target", "bypassed", "loop", "volumeDb", "pan", "mute", "solo", "action"]
        var parts: [String] = []
        for key in order {
            guard let v = o[key] else { continue }
            let text = v.stringValue ?? (v.doubleValue.map { $0 == $0.rounded() ? String(Int($0)) : String(format: "%.2f", $0) }) ?? v.boolValue.map { $0 ? "on" : "off" } ?? ""
            parts.append(["track", "device", "clip", "name", "action"].contains(key) ? text : "\(key) \(text)")
        }
        if parts.isEmpty, let c = o["command"]?.objectValue?.keys.first { parts.append(c) }
        return parts.joined(separator: " · ")
    }
}

/// The API key in the login Keychain. Never in a file, never in a log.
enum Keychain {
    static let service = "LoopStudio Assistant"
    static let account = "anthropic-api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { SecItemDelete(query as CFDictionary); return }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            SecItemAdd(q as CFDictionary, nil)
        }
    }
}
