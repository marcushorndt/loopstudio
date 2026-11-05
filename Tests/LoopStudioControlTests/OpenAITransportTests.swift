import Foundation
import Testing
@testable import LoopStudioControl
@testable import LoopStudioCore

@Test func theMessagesBodyBecomesAChatCompletionsBody() throws {
    let body = JSONValue.object([
        "model": .string("gpt-5"), "max_tokens": .number(16000), "stream": .bool(true),
        "output_config": .object(["effort": .string("xhigh")]), "fallbacks": .string("default"),
        "system": .array([.object(["type": .string("text"), "text": .string("Rules."), "cache_control": .object(["type": .string("ephemeral")])])]),
        "tools": .array([.object(["name": .string("track_rename"), "description": .string("Rename"), "input_schema": Schema.object(["track": Schema.string("t")], required: ["track"])])]),
        "messages": .array([
            .object(["role": .string("user"), "content": .array([.object(["type": .string("text"), "text": .string("[Screen]")]), .object(["type": .string("text"), "text": .string("rename it")])])]),
            .object(["role": .string("assistant"), "content": .array([
                .object(["type": .string("thinking"), "thinking": .string(""), "signature": .string("x")]),
                .object(["type": .string("tool_use"), "id": .string("call_1"), "name": .string("track_rename"), "input": .object(["track": .string("Drums"), "name": .string("Kit")])]),
            ])]),
            .object(["role": .string("user"), "content": .array([.object(["type": .string("tool_result"), "tool_use_id": .string("call_1"), "content": .string("{\"receipt\":1}"), "is_error": .bool(false)])])]),
            .object(["role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string("Renamed.")])])]),
        ]),
    ])
    let out = OpenAITransport.translate(body)
    #expect(out["model"]?.stringValue == "gpt-5")
    #expect(out["max_completion_tokens"]?.intValue == 16000)
    #expect(out["reasoning_effort"]?.stringValue == "high")
    #expect(out["stream_options"]?["include_usage"]?.boolValue == true)
    #expect(out["fallbacks"] == nil)
    let messages = try #require(out["messages"]?.arrayValue)
    #expect(messages.map { $0["role"]?.stringValue } == ["system", "user", "assistant", "tool", "assistant"])
    #expect(messages[0]["content"]?.stringValue == "Rules.")
    #expect(messages[1]["content"]?.stringValue == "[Screen]\n\nrename it")
    let call = try #require(messages[2]["tool_calls"]?.arrayValue?.first)
    #expect(call["id"]?.stringValue == "call_1")
    #expect(call["function"]?["name"]?.stringValue == "track_rename")
    let args = try JSONDecoder().decode(JSONValue.self, from: Data((call["function"]?["arguments"]?.stringValue ?? "").utf8))
    #expect(args["name"]?.stringValue == "Kit")
    #expect(messages[2]["content"] == .null)
    #expect(messages[3]["tool_call_id"]?.stringValue == "call_1")
    #expect(messages[3]["content"]?.stringValue == "{\"receipt\":1}")
    let tool = try #require(out["tools"]?.arrayValue?.first)
    #expect(tool["type"]?.stringValue == "function")
    #expect(tool["function"]?["parameters"]?["required"]?.arrayValue?.first?.stringValue == "track")
    #expect(out["tool_choice"]?.stringValue == "auto")

    // A model without reasoning gets no reasoning_effort.
    var plain = body.objectValue!; plain["model"] = .string("gpt-4.1")
    #expect(OpenAITransport.translate(.object(plain))["reasoning_effort"] == nil)
    #expect(OpenAITransport.isReasoningModel("o4-mini") && !OpenAITransport.isReasoningModel("gpt-4o"))
}

@Test func chatCompletionChunksBecomeEngineEvents() throws {
    func chunk(_ json: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) }
    var mapper = OpenAITransport.StreamMapper()
    var events: [ClaudeEvent] = []
    events += mapper.map(try chunk(#"{"model":"gpt-5","choices":[{"index":0,"delta":{"role":"assistant","content":"Let me "},"finish_reason":null}]}"#))
    events += mapper.map(try chunk(#"{"model":"gpt-5","choices":[{"index":0,"delta":{"content":"check."},"finish_reason":null}]}"#))
    events += mapper.map(try chunk(#"{"model":"gpt-5","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_9","type":"function","function":{"name":"ui_state","arguments":""}}]},"finish_reason":null}]}"#))
    events += mapper.map(try chunk(#"{"model":"gpt-5","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{}"}}]},"finish_reason":null}]}"#))
    events += mapper.map(try chunk(#"{"model":"gpt-5","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#))
    events += mapper.map(try chunk(#"{"model":"gpt-5","choices":[],"usage":{"prompt_tokens":120,"completion_tokens":9,"prompt_tokens_details":{"cached_tokens":100}}}"#))

    var usage = TokenUsage(); usage.input = 20; usage.cacheRead = 100; usage.output = 9
    #expect(events == [
        .messageStart(model: "gpt-5", usage: TokenUsage()),
        .blockStart(index: 0, block: .object(["type": .string("text"), "text": .string("")])),
        .textDelta(index: 0, text: "Let me "),
        .textDelta(index: 0, text: "check."),
        .blockStart(index: 1, block: .object(["type": .string("tool_use"), "id": .string("call_9"), "name": .string("ui_state"), "input": .object([:])])),
        .inputJSONDelta(index: 1, partial: "{}"),
        .messageDelta(stopReason: "tool_use", usage: TokenUsage()),
        .messageDelta(stopReason: nil, usage: usage),
    ])
    #expect(usage.cost(model: "gpt-5") > 0)
    #expect(ModelProvider.of(model: "gpt-5") == .openai && ModelProvider.of(model: "claude-opus-5-5") == .anthropic)
}

/// The engine runs a whole turn over an OpenAI-shaped stream: the tool call reaches the registry, the
/// receipt comes back, and the next request carries the tool message.
@Test func theEngineRunsATurnOverTheOpenAIShape() async throws {
    final class Fake: ModelTransport, @unchecked Sendable {
        let lock = NSLock()
        var bodies: [JSONValue] = []
        var answers: [[String]]
        init(_ answers: [[String]]) { self.answers = answers }
        func stream(_ request: JSONValue) -> AsyncThrowingStream<ClaudeEvent, any Error> {
            lock.lock()
            bodies.append(OpenAITransport.translate(request))
            let chunks = answers.isEmpty ? [] : answers.removeFirst()
            lock.unlock()
            return AsyncThrowingStream { c in
                var mapper = OpenAITransport.StreamMapper()
                for text in chunks {
                    if text == "[DONE]" { c.yield(.messageStop); continue }
                    let json = try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
                    for e in mapper.map(json) { c.yield(e) }
                }
                c.finish()
            }
        }
    }
    let fake = Fake([
        [#"{"model":"gpt-5","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"track_rename","arguments":"{\"track\":\"Drums\",\"name\":\"Kit\"}"}}]},"finish_reason":null}]}"#,
         #"{"model":"gpt-5","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#, "[DONE]"],
        [#"{"model":"gpt-5","choices":[{"index":0,"delta":{"content":"Renamed."},"finish_reason":"stop"}]}"#, "[DONE]"],
    ])
    let session = ProjectSession()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("openai-\(UUID().uuidString)")
    try await session.create(at: folder.appendingPathComponent("O.loopstudio"), name: "O", sampleRate: 48_000)
    try await session.apply(.insertTrack(track: Track(name: "Drums", kind: .audio), index: 0))
    var registry = StandardTools.registry(session: session)
    for tool in StandardTools.namedTools(session: session) { registry.add(tool) }
    let engine = AssistantEngine(transport: fake, registry: registry, config: AssistantConfig(model: "gpt-5", effort: "low"))
    final class Box: @unchecked Sendable { var receipts = 0; var notices: [String] = []; let lock = NSLock() }
    let box = Box()
    await engine.run(user: "rename the drums to Kit") { e in
        box.lock.lock(); defer { box.lock.unlock() }
        if case .toolResult(_, _, _, _, let r?) = e { box.receipts += 1; _ = r }
        if case .notice(let t) = e { box.notices.append(t) }
    }
    #expect(try await session.project().tracks[0].name == "Kit")
    #expect(box.receipts == 1)
    #expect(box.notices.isEmpty)
    let second = fake.bodies[1]["messages"]?.arrayValue ?? []
    #expect(second.map { $0["role"]?.stringValue } == ["system", "user", "assistant", "tool"])
    #expect(second[3]["tool_call_id"]?.stringValue == "call_a")
    #expect(second[1]["content"]?.stringValue == "rename the drums to Kit")
    #expect(fake.bodies[0]["reasoning_effort"]?.stringValue == "low")
}
