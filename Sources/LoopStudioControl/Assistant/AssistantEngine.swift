import Foundation
import LoopStudioCore

/// How the assistant is set up for one conversation.
public struct AssistantConfig: Sendable {
    public var model: String
    /// low, medium, high, xhigh or max.
    public var effort: String
    public var maxTokens: Int
    public var system: String
    /// The maximum number of model calls in one turn, so a loop cannot run away.
    public var maxRounds: Int

    public init(model: String = "claude-opus-5-5", effort: String = "medium", maxTokens: Int = 16_000, system: String = AssistantPrompt.system, maxRounds: Int = 40) {
        self.model = model
        self.effort = effort
        self.maxTokens = maxTokens
        self.system = system
        self.maxRounds = maxRounds
    }
}

/// What the engine reports while a turn runs. The transcript shows these; the model's words carry no
/// authority over what happened, the receipts do.
public enum AssistantEvent: Sendable {
    /// Streamed text of the model's answer.
    case text(String)
    /// A progress note the model wrote between tool calls.
    case progress(String)
    /// A tool call started.
    case toolCall(id: String, name: String, input: JSONValue)
    /// A tool call ended. `receipt` is set when the tool changed the project.
    case toolResult(id: String, name: String, result: JSONValue, isError: Bool, receipt: Receipt?)
    /// The user skipped a tool call in plan mode.
    case toolSkipped(id: String, name: String)
    /// Something the host wants the person to know (a refusal, a claim without a receipt).
    case notice(String)
    /// Tokens of one model call and the model that served it.
    case usage(TokenUsage, model: String)
    /// The turn ended. `reason` is the last stop reason ("end_turn", "max_tokens", "refusal", "stopped").
    case finished(reason: String)
}

/// Decides whether a changing tool call runs. The app shows a card with Apply and Skip.
public typealias ToolGate = @Sendable (_ name: String, _ input: JSONValue, _ destructive: Bool) async -> Bool

/// The turn loop: send the transcript, stream the answer, run the tool calls, send the results, repeat
/// until the model stops. The transcript is append-only (thinking blocks go back unchanged), so the
/// prompt cache and the thinking signatures stay valid.
public actor AssistantEngine {
    public private(set) var messages: [JSONValue] = []
    public var config: AssistantConfig
    private let transport: any ModelTransport
    private let registry: ToolRegistry
    private var stopped = false

    public init(transport: any ModelTransport, registry: ToolRegistry, config: AssistantConfig = AssistantConfig()) {
        self.transport = transport
        self.registry = registry
        self.config = config
    }

    public func stop() { stopped = true }
    public func reset() { messages = [] }

    /// The tool definitions as the API takes them.
    public var toolDefinitions: [JSONValue] {
        registry.tools.map { .object(["name": .string($0.name), "description": .string($0.description), "input_schema": $0.inputSchema]) }
    }

    /// The request body for the current transcript.
    public func request() -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(config.model),
            "max_tokens": .number(Double(config.maxTokens)),
            "stream": .bool(true),
            "system": .array([.object(["type": .string("text"), "text": .string(config.system), "cache_control": .object(["type": .string("ephemeral")])])]),
            "tools": .array(toolDefinitions),
            "tool_choice": .object(["type": .string("auto")]),
            "output_config": .object(["effort": .string(config.effort)]),
            "messages": .array(messages),
        ]
        // Anthropic: a refusal routes to a sibling model instead of ending the turn. Haiku has no such route.
        if config.model.hasPrefix("claude"), !config.model.hasPrefix("claude-haiku") { body["fallbacks"] = .string("default") }
        return .object(body)
    }

    /// One user turn. `gate` decides about changing tools; `events` get the progress.
    public func run(user text: String, context: String? = nil, askBeforeChanges: Bool = false, gate: ToolGate? = nil,
                    events: @escaping @Sendable (AssistantEvent) -> Void) async {
        stopped = false
        var content: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)])]
        if let context, !context.isEmpty { content.insert(.object(["type": .string("text"), "text": .string(context)]), at: 0) }
        messages.append(.object(["role": .string("user"), "content": .array(content)]))

        var receipts = 0
        var finalText = ""
        var reason = "end_turn"
        rounds: for _ in 0..<config.maxRounds {
            if stopped { reason = "stopped"; break }
            let answer: Answer
            do { answer = try await call(events: events) } catch {
                events(.notice("The model call failed: \(error)"))
                reason = "error"
                break
            }
            if answer.blocks.isEmpty, answer.stopReason == nil {
                events(.notice("The model sent an empty answer (model \(config.model)). Check the model id in Settings › Assistant."))
                reason = "error"
                break
            }
            messages.append(.object(["role": .string("assistant"), "content": .array(answer.blocks)]))
            finalText = answer.text
            reason = answer.stopReason ?? "end_turn"
            switch reason {
            case "tool_use":
                var results: [JSONValue] = []
                for block in answer.blocks where block["type"]?.stringValue == "tool_use" {
                    let id = block["id"]?.stringValue ?? "", name = block["name"]?.stringValue ?? ""
                    let input = block["input"] ?? .object([:])
                    if stopped {
                        results.append(toolResult(id, "Stopped by the user before this call ran.", isError: true))
                        continue
                    }
                    events(.toolCall(id: id, name: name, input: input))
                    let outcome = await runTool(name: name, input: input, askBeforeChanges: askBeforeChanges, gate: gate)
                    switch outcome {
                    case .skipped:
                        events(.toolSkipped(id: id, name: name))
                        results.append(toolResult(id, "The user skipped this change. Do not retry it; ask what to do instead.", isError: false))
                    case .ran(let value, let isError):
                        let receipt = value["receipt"].flatMap { try? $0.decode(Receipt.self) }
                        if receipt != nil { receipts += 1 }
                        events(.toolResult(id: id, name: name, result: value, isError: isError, receipt: receipt))
                        results.append(toolResult(id, value.text, isError: isError))
                    }
                }
                messages.append(.object(["role": .string("user"), "content": .array(results)]))
                if stopped { reason = "stopped"; break rounds }
            case "refusal":
                events(.notice("The model declined this request."))
                break rounds
            case "max_tokens":
                events(.notice("The answer was cut off at the token limit."))
                break rounds
            default:
                break rounds
            }
        }
        if reason == "end_turn", receipts == 0, Self.claimsAnEdit(finalText) {
            events(.notice("No change was made in this turn."))
        }
        events(.finished(reason: reason))
    }

    // MARK: One model call

    struct Answer {
        var blocks: [JSONValue] = []
        var text = ""
        var stopReason: String?
    }

    /// Streams one answer and assembles its content blocks for the transcript.
    private func call(events: @escaping @Sendable (AssistantEvent) -> Void) async throws -> Answer {
        struct Block { var raw: JSONValue; var text = ""; var thinking = ""; var signature = ""; var partial = "" }
        var blocks: [Int: Block] = [:]
        var order: [Int] = []
        var answer = Answer()
        var usage = TokenUsage()
        var model = config.model

        for try await event in transport.stream(request()) {
            if stopped { break }
            switch event {
            case .messageStart(let m, let u):
                if !m.isEmpty { model = m }
                usage.add(u)
            case .blockStart(let i, let block):
                blocks[i] = Block(raw: block)
                order.append(i)
                if block["type"]?.stringValue == "text", let t = block["text"]?.stringValue, !t.isEmpty {
                    blocks[i]?.text = t; events(.text(t))
                }
            case .textDelta(let i, let t):
                blocks[i]?.text += t
                events(.text(t))
            case .thinkingDelta(let i, let t):
                blocks[i]?.thinking += t
                if !t.isEmpty { events(.progress(t)) }
            case .signatureDelta(let i, let s):
                blocks[i]?.signature += s
            case .inputJSONDelta(let i, let p):
                blocks[i]?.partial += p
            case .blockStop:
                break
            case .messageDelta(let stop, let u):
                answer.stopReason = stop ?? answer.stopReason
                usage.add(u)
            case .messageStop:
                break
            case .error(let message):
                throw ClaudeAPIError(status: 0, message: message)
            }
        }

        for i in order {
            guard let b = blocks[i] else { continue }
            var raw = b.raw.objectValue ?? [:]
            switch raw["type"]?.stringValue {
            case "text":
                raw["text"] = .string(b.text)
                answer.text += b.text
            case "thinking":
                raw["thinking"] = .string(b.thinking)
                if !b.signature.isEmpty { raw["signature"] = .string(b.signature) }
            case "tool_use":
                let input = (try? JSONDecoder().decode(JSONValue.self, from: Data(b.partial.utf8))) ?? (raw["input"] ?? .object([:]))
                raw["input"] = input.objectValue != nil ? input : .object([:])
            default:
                break // a fallback block and others go back as they came
            }
            answer.blocks.append(.object(raw))
        }
        events(.usage(usage, model: model))
        return answer
    }

    // MARK: Tools

    enum Outcome { case ran(JSONValue, isError: Bool), skipped }

    private func runTool(name: String, input: JSONValue, askBeforeChanges: Bool, gate: ToolGate?) async -> Outcome {
        guard let tool = registry.tool(named: name) else {
            return .ran(.object(["error": .string("unknown tool \(name)")]), isError: true)
        }
        if !tool.annotations.readOnly, let gate {
            let destructive = tool.annotations.destructive || Self.commandIsDestructive(name: name, input: input)
            if askBeforeChanges || destructive {
                guard await gate(name, input, destructive) else { return .skipped }
            }
        }
        do {
            let value = try await tool.handler(ToolArguments(input))
            return .ran(value.objectValue != nil ? value : .object(["result": value]), isError: false)
        } catch let failure as ToolFailure {
            return .ran(.object(["error": .string(failure.message)]), isError: true)
        } catch {
            return .ran(.object(["error": .string("\(error)")]), isError: true)
        }
    }

    /// `command_apply` carries any command; look inside for a removal.
    static func commandIsDestructive(name: String, input: JSONValue) -> Bool {
        guard name == "command_apply", let c = input["command"], let command = try? c.decode(Command.self) else { return false }
        return command.isDestructive
    }

    private func toolResult(_ id: String, _ text: String, isError: Bool) -> JSONValue {
        .object(["type": .string("tool_result"), "tool_use_id": .string(id), "content": .string(text), "is_error": .bool(isError)])
    }

    /// The model says it changed something. With no receipt in the turn, the host adds a notice.
    static let editVerbs = ["i set ", "i've set ", "i have set ", "i added ", "i've added ", "i have added ", "i moved ", "i've moved ",
                            "i removed ", "i've removed ", "i renamed ", "i've renamed ", "i changed ", "i've changed ", "i created ",
                            "i've created ", "i deleted ", "i've deleted ", "i turned ", "i've turned ", "i lowered ", "i raised ",
                            "i bypassed ", "i've bypassed ", "done.", "done!", "is now set", "has been set", "has been added", "has been removed"]

    static func claimsAnEdit(_ text: String) -> Bool {
        let t = text.lowercased()
        return editVerbs.contains { t.contains($0) }
    }
}
