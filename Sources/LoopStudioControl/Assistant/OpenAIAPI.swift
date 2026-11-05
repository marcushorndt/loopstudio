import Foundation

/// Who serves the model. The engine speaks one shape (the Messages API); a provider that speaks another gets
/// a transport that translates both ways.
public enum ModelProvider: String, CaseIterable, Sendable, Codable {
    case openai, anthropic

    public var name: String {
        switch self {
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        }
    }

    /// Known models, newest first. Any other id can be typed in.
    public var models: [(id: String, name: String)] {
        switch self {
        case .openai: [("gpt-5.1", "GPT-5.1"), ("gpt-5", "GPT-5"), ("gpt-5-mini", "GPT-5 mini"), ("gpt-4.1", "GPT-4.1"), ("o4-mini", "o4-mini")]
        case .anthropic: [("claude-opus-5-5", "Claude Opus 5.5"), ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
                          ("claude-haiku-5-5", "Claude Haiku 5.5"), ("claude-fable-5-1", "Claude Fable 5.1")]
        }
    }

    public var defaultModel: String { models[0].id }

    /// The Keychain account that holds the key.
    public var keychainAccount: String {
        switch self {
        case .openai: "openai-api-key"
        case .anthropic: "anthropic-api-key"
        }
    }

    public var keyHint: String {
        switch self {
        case .openai: "sk-…  (platform.openai.com)"
        case .anthropic: "sk-ant-…  (console.anthropic.com)"
        }
    }

    public func transport(apiKey: String) -> any ModelTransport {
        switch self {
        case .openai: OpenAITransport(apiKey: apiKey)
        case .anthropic: URLSessionTransport(apiKey: apiKey)
        }
    }

    /// The provider a model id belongs to.
    public static func of(model: String) -> ModelProvider { model.hasPrefix("claude") ? .anthropic : .openai }
}

/// OpenAI's Chat Completions API, streamed. The request comes in the Messages API shape the engine builds and
/// goes out as chat messages, function tools and `stream_options`; the chunks come back as `ClaudeEvent`s.
public struct OpenAITransport: ModelTransport {
    public static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    let apiKey: String

    public init(apiKey: String) { self.apiKey = apiKey }

    // MARK: Request

    /// A reasoning model takes `reasoning_effort`; the others reject it.
    static func isReasoningModel(_ model: String) -> Bool {
        model.hasPrefix("gpt-5") || model.range(of: #"^o\d"#, options: .regularExpression) != nil
    }

    /// Messages API body in, Chat Completions body out.
    public static func translate(_ body: JSONValue) -> JSONValue {
        var out: [String: JSONValue] = [:]
        let model = body["model"]?.stringValue ?? ""
        out["model"] = .string(model)
        out["stream"] = .bool(true)
        out["stream_options"] = .object(["include_usage": .bool(true)])
        if let max = body["max_tokens"]?.intValue { out["max_completion_tokens"] = .number(Double(max)) }
        if isReasoningModel(model), let effort = body["output_config"]?["effort"]?.stringValue {
            out["reasoning_effort"] = .string(["low": "low", "medium": "medium", "high": "high", "xhigh": "high", "max": "high"][effort] ?? "medium")
        }

        var messages: [JSONValue] = []
        let system = (body["system"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n\n")
        if !system.isEmpty { messages.append(.object(["role": .string("system"), "content": .string(system)])) }

        for message in body["messages"]?.arrayValue ?? [] {
            let role = message["role"]?.stringValue ?? "user"
            let blocks: [JSONValue] = message["content"]?.arrayValue ?? message["content"]?.stringValue.map { [.object(["type": .string("text"), "text": .string($0)])] } ?? []
            if role == "assistant" {
                var text: [String] = []
                var calls: [JSONValue] = []
                for b in blocks {
                    switch b["type"]?.stringValue {
                    case "text": if let t = b["text"]?.stringValue, !t.isEmpty { text.append(t) }
                    case "tool_use":
                        calls.append(.object(["id": .string(b["id"]?.stringValue ?? ""), "type": .string("function"),
                                              "function": .object(["name": .string(b["name"]?.stringValue ?? ""),
                                                                   "arguments": .string((b["input"] ?? .object([:])).text)])]))
                    default: break // thinking and fallback blocks belong to the other provider
                    }
                }
                guard !text.isEmpty || !calls.isEmpty else { continue }
                var m: [String: JSONValue] = ["role": .string("assistant"), "content": text.isEmpty ? .null : .string(text.joined(separator: "\n\n"))]
                if !calls.isEmpty { m["tool_calls"] = .array(calls) }
                messages.append(.object(m))
            } else {
                var text: [String] = []
                func flush() {
                    if !text.isEmpty { messages.append(.object(["role": .string("user"), "content": .string(text.joined(separator: "\n\n"))])); text = [] }
                }
                for b in blocks {
                    switch b["type"]?.stringValue {
                    case "text": if let t = b["text"]?.stringValue { text.append(t) }
                    case "tool_result":
                        flush()
                        let content = b["content"]?.stringValue ?? (b["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined()
                        messages.append(.object(["role": .string("tool"), "tool_call_id": .string(b["tool_use_id"]?.stringValue ?? ""), "content": .string(content)]))
                    default: break
                    }
                }
                flush()
            }
        }
        out["messages"] = .array(messages)

        if let tools = body["tools"]?.arrayValue, !tools.isEmpty {
            out["tools"] = .array(tools.map { t in
                .object(["type": .string("function"),
                         "function": .object(["name": t["name"] ?? .string(""), "description": t["description"] ?? .string(""),
                                              "parameters": t["input_schema"] ?? .object(["type": .string("object")])])])
            })
            out["tool_choice"] = .string("auto")
        }
        return .object(out)
    }

    // MARK: Stream

    /// Turns Chat Completions chunks into the events the engine reads. Text is block 0; tool call `index` n
    /// is block n + 1.
    public struct StreamMapper: Sendable {
        private var started = false
        private var textOpen = false
        private var calls: Set<Int> = []

        public init() {}

        public mutating func map(_ chunk: JSONValue) -> [ClaudeEvent] {
            var events: [ClaudeEvent] = []
            if !started {
                started = true
                events.append(.messageStart(model: chunk["model"]?.stringValue ?? "", usage: TokenUsage()))
            }
            if let error = chunk["error"] {
                events.append(.error(error["message"]?.stringValue ?? error.text))
                return events
            }
            if let choice = chunk["choices"]?.arrayValue?.first {
                let delta = choice["delta"]
                if let text = delta?["content"]?.stringValue, !text.isEmpty {
                    if !textOpen { textOpen = true; events.append(.blockStart(index: 0, block: .object(["type": .string("text"), "text": .string("")]))) }
                    events.append(.textDelta(index: 0, text: text))
                }
                for call in delta?["tool_calls"]?.arrayValue ?? [] {
                    let i = (call["index"]?.intValue ?? 0) + 1
                    if !calls.contains(i) {
                        calls.insert(i)
                        events.append(.blockStart(index: i, block: .object([
                            "type": .string("tool_use"), "id": .string(call["id"]?.stringValue ?? "call_\(i)"),
                            "name": .string(call["function"]?["name"]?.stringValue ?? ""), "input": .object([:]),
                        ])))
                    }
                    if let args = call["function"]?["arguments"]?.stringValue, !args.isEmpty { events.append(.inputJSONDelta(index: i, partial: args)) }
                }
                if let finish = choice["finish_reason"]?.stringValue {
                    let stop: String = switch finish {
                    case "tool_calls", "function_call": "tool_use"
                    case "length": "max_tokens"
                    case "content_filter": "refusal"
                    default: "end_turn"
                    }
                    events.append(.messageDelta(stopReason: stop, usage: TokenUsage()))
                }
            }
            if let usage = chunk["usage"], usage != .null {
                var t = TokenUsage()
                let cached = usage["prompt_tokens_details"]?["cached_tokens"]?.intValue ?? 0
                t.input = max(0, (usage["prompt_tokens"]?.intValue ?? 0) - cached)
                t.cacheRead = cached
                t.output = usage["completion_tokens"]?.intValue ?? 0
                events.append(.messageDelta(stopReason: nil, usage: t))
            }
            return events
        }
    }

    public func stream(_ request: JSONValue) -> AsyncThrowingStream<ClaudeEvent, any Error> {
        let apiKey = apiKey
        let body = Self.translate(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: Self.endpoint)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    req.httpBody = Data(body.text.utf8)
                    req.timeoutInterval = 600
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var text = ""
                        for try await line in bytes.lines { text += line }
                        let message = (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))?["error"]?["message"]?.stringValue ?? text
                        throw ClaudeAPIError(status: status, message: "OpenAI: \(message)")
                    }
                    var parser = SSEParser()
                    var mapper = StreamMapper()
                    for try await line in bytes.lines {
                        guard let (_, data) = parser.feed(line: line) else { continue }
                        if data.trimmingCharacters(in: .whitespaces) == "[DONE]" { continuation.yield(.messageStop); break }
                        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(data.utf8)) else { continue }
                        for event in mapper.map(json) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
