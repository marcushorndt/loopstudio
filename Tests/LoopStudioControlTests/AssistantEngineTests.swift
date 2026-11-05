import Foundation
import Testing
@testable import LoopStudioControl
@testable import LoopStudioCore

/// Plays recorded answers, one per model call, and keeps every request body it was sent.
private final class ScriptedTransport: ModelTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [[ClaudeEvent]]
    private(set) var requests: [JSONValue] = []

    init(_ answers: [[ClaudeEvent]]) { self.answers = answers }

    func stream(_ request: JSONValue) -> AsyncThrowingStream<ClaudeEvent, any Error> {
        lock.lock()
        requests.append(request)
        let events = answers.isEmpty ? [] : answers.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { c in
            for e in events { c.yield(e) }
            c.finish()
        }
    }
}

/// A streamed answer with text, or with one tool call.
private func textAnswer(_ text: String, stop: String = "end_turn") -> [ClaudeEvent] {
    [.messageStart(model: "claude-opus-5-5", usage: { var u = TokenUsage(); u.input = 100; return u }()),
     .blockStart(index: 0, block: .object(["type": .string("thinking"), "thinking": .string("")])),
     .signatureDelta(index: 0, signature: "sig"), .blockStop(index: 0),
     .blockStart(index: 1, block: .object(["type": .string("text"), "text": .string("")])),
     .textDelta(index: 1, text: text), .blockStop(index: 1),
     .messageDelta(stopReason: stop, usage: { var u = TokenUsage(); u.output = 20; return u }()), .messageStop]
}

private func toolAnswer(id: String, name: String, input: JSONValue) -> [ClaudeEvent] {
    [.messageStart(model: "claude-opus-5-5", usage: TokenUsage()),
     .blockStart(index: 0, block: .object(["type": .string("tool_use"), "id": .string(id), "name": .string(name), "input": .object([:])])),
     .inputJSONDelta(index: 0, partial: input.text), .blockStop(index: 0),
     .messageDelta(stopReason: "tool_use", usage: TokenUsage()), .messageStop]
}

private func makeEngine(_ transport: ScriptedTransport) async throws -> (AssistantEngine, ProjectSession) {
    let session = ProjectSession()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("engine-\(UUID().uuidString)")
    try await session.create(at: folder.appendingPathComponent("E.loopstudio"), name: "E", sampleRate: 48_000)
    try await session.apply(.insertTrack(track: Track(name: "Drums", kind: .audio), index: 0))
    var registry = StandardTools.registry(session: session)
    for tool in StandardTools.namedTools(session: session) { registry.add(tool) }
    return (AssistantEngine(transport: transport, registry: registry, config: AssistantConfig(model: "claude-opus-5-5", effort: "low")), session)
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AssistantEvent] = []
    func add(_ e: AssistantEvent) { lock.lock(); items.append(e); lock.unlock() }
    var all: [AssistantEvent] { lock.lock(); defer { lock.unlock() }; return items }
}

@Test func aToolCallRunsAndItsReceiptReachesTheTranscript() async throws {
    let transport = ScriptedTransport([
        toolAnswer(id: "t1", name: "track_rename", input: .object(["track": .string("Drums"), "name": .string("Kit")])),
        textAnswer("Renamed."),
    ])
    let (engine, session) = try await makeEngine(transport)
    let events = Collected()
    await engine.run(user: "rename the drums to Kit", context: "[Screen now: view session]") { events.add($0) }

    #expect(try await session.project().tracks[0].name == "Kit")
    let receipts = events.all.compactMap { if case .toolResult(_, _, _, _, let r?) = $0 { r } else { nil } }
    #expect(receipts.count == 1)
    #expect(receipts.first?.changes.first?.line == "Drums › name: Drums to Kit")
    let notices = events.all.compactMap { if case .notice(let t) = $0 { t } else { nil } }
    #expect(notices.isEmpty, "\(notices)")

    // The transcript is append-only: user, assistant (tool_use), user (tool_result), assistant (text).
    let roles = await engine.messages.map { $0["role"]?.stringValue ?? "" }
    #expect(roles == ["user", "assistant", "user", "assistant"])
    let first = await engine.messages[0]["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue } ?? []
    #expect(first == ["[Screen now: view session]", "rename the drums to Kit"])
    let result = await engine.messages[2]["content"]?.arrayValue?.first
    #expect(result?["tool_use_id"]?.stringValue == "t1")
    #expect(result?["content"]?.stringValue?.contains("\"receipt\"") == true)
    // The thinking block of the last answer went into the transcript with its signature.
    let lastBlocks = await engine.messages[3]["content"]?.arrayValue ?? []
    #expect(lastBlocks.first?["type"]?.stringValue == "thinking")
    #expect(lastBlocks.first?["signature"]?.stringValue == "sig")

    // The request body carries the pieces the API needs.
    let body = transport.requests[0]
    #expect(body["model"]?.stringValue == "claude-opus-5-5")
    #expect(body["fallbacks"]?.stringValue == "default")
    #expect(body["tool_choice"]?["type"]?.stringValue == "auto")
    #expect(body["output_config"]?["effort"]?.stringValue == "low")
    #expect(body["tools"]?.arrayValue?.contains { $0["name"]?.stringValue == "track_rename" } == true)
    #expect(body["thinking"] == nil)
    let usage = events.all.compactMap { if case .usage(let u, _) = $0 { u } else { nil } }
    #expect(usage.map(\.output).reduce(0, +) == 20)
}

@Test func aClaimWithoutAReceiptGetsANotice() async throws {
    let transport = ScriptedTransport([textAnswer("I renamed the track to Kit.")])
    let (engine, session) = try await makeEngine(transport)
    let events = Collected()
    await engine.run(user: "rename the drums") { events.add($0) }
    #expect(try await session.project().tracks[0].name == "Drums")
    let notices = events.all.compactMap { if case .notice(let t) = $0 { t } else { nil } }
    #expect(notices == ["No change was made in this turn."])
}

@Test func planModeWaitsForTheGateAndASkipChangesNothing() async throws {
    let transport = ScriptedTransport([
        toolAnswer(id: "t1", name: "track_rename", input: .object(["track": .string("Drums"), "name": .string("Kit")])),
        textAnswer("Skipped, then."),
    ])
    let (engine, session) = try await makeEngine(transport)
    let events = Collected()
    let asked = Collected()
    await engine.run(user: "rename", askBeforeChanges: true, gate: { name, _, destructive in
        asked.add(.toolCall(id: "", name: name, input: .bool(destructive)))
        return false
    }) { events.add($0) }
    #expect(try await session.project().tracks[0].name == "Drums")
    #expect(asked.all.count == 1)
    let skipped = events.all.compactMap { if case .toolSkipped(_, let n) = $0 { n } else { nil } }
    #expect(skipped == ["track_rename"])
    let result = await engine.messages[2]["content"]?.arrayValue?.first?["content"]?.stringValue ?? ""
    #expect(result.contains("skipped"))
}

@Test func aRemovalAlwaysAsksEvenWithoutPlanMode() async throws {
    let transport = ScriptedTransport([
        toolAnswer(id: "t1", name: "command_apply", input: .object(["command": .object(["removeTrack": .object(["id": .string(UUID().uuidString)])])])),
        textAnswer("Ok."),
    ])
    let (engine, _) = try await makeEngine(transport)
    let asked = Collected()
    await engine.run(user: "remove", askBeforeChanges: false, gate: { _, _, destructive in
        asked.add(.notice(destructive ? "destructive" : "plain")); return false
    }) { _ in }
    let flags = asked.all.compactMap { if case .notice(let t) = $0 { t } else { nil } }
    #expect(flags == ["destructive"])
    #expect(AssistantEngine.commandIsDestructive(name: "command_apply", input: .object(["command": .object(["setVolume": .object(["id": .string(UUID().uuidString), "db": .number(0)])])])) == false)
}

@Test func theSSEParserAndTheEventDecoderReadTheWireFormat() throws {
    var parser = SSEParser()
    let lines = [
        "event: message_start",
        "data: {\"type\":\"message_start\",\"message\":{\"model\":\"claude-opus-5-5\",\"usage\":{\"input_tokens\":12,\"cache_read_input_tokens\":3}}}",
        "",
        ": keep-alive",
        "event: content_block_delta",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"a\\\":\"}}",
        "",
        "event: message_delta",
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":7}}",
        "",
    ]
    var events: [ClaudeEvent] = []
    for line in lines {
        guard let (_, data) = parser.feed(line: line) else { continue }
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(data.utf8))
        if let e = ClaudeEvent.parse(json) { events.append(e) }
    }
    var u = TokenUsage(); u.input = 12; u.cacheRead = 3
    var o = TokenUsage(); o.output = 7
    #expect(events == [.messageStart(model: "claude-opus-5-5", usage: u),
                       .inputJSONDelta(index: 0, partial: "{\"a\":"),
                       .messageDelta(stopReason: "tool_use", usage: o)])
    #expect(u.cost(model: "claude-opus-5-5") > 0)
    #expect(AssistantEngine.claimsAnEdit("I added a delay to the bass."))
    #expect(!AssistantEngine.claimsAnEdit("Which track do you mean: Synth (2) or Synth (3)?"))
}
