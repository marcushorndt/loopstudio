import Foundation

/// Tokens of one request, from the message_start and message_delta events.
public struct TokenUsage: Sendable, Hashable, Codable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0

    public init() {}

    public mutating func add(_ other: TokenUsage) {
        input += other.input; output += other.output; cacheRead += other.cacheRead; cacheWrite += other.cacheWrite
    }

    /// Price in US dollars for a model, from the public rates (Anthropic checked 2026-11-05; OpenAI from
    /// memory, an estimate). Unknown model: zero.
    public func cost(model: String) -> Double {
        let (inRate, outRate, cacheRate): (Double, Double, Double)
        switch true {
        case model.hasPrefix("gpt-5-nano"): (inRate, outRate, cacheRate) = (0.05, 0.40, 0.005)
        case model.hasPrefix("gpt-5-mini"): (inRate, outRate, cacheRate) = (0.25, 2, 0.025)
        case model.hasPrefix("gpt-5"): (inRate, outRate, cacheRate) = (1.25, 10, 0.125)
        case model.hasPrefix("gpt-4.1-mini"): (inRate, outRate, cacheRate) = (0.40, 1.60, 0.10)
        case model.hasPrefix("gpt-4.1"): (inRate, outRate, cacheRate) = (2, 8, 0.50)
        case model.hasPrefix("gpt-4o"): (inRate, outRate, cacheRate) = (2.50, 10, 1.25)
        case model.hasPrefix("o4-mini"), model.hasPrefix("o3-mini"): (inRate, outRate, cacheRate) = (1.10, 4.40, 0.275)
        case model.hasPrefix("o3"): (inRate, outRate, cacheRate) = (2, 8, 0.50)
        case model.hasPrefix("claude-fable"): (inRate, outRate, cacheRate) = (10, 50, 0.25)
        case model.hasPrefix("claude-opus-5-5"): (inRate, outRate, cacheRate) = (4, 20, 0.20)
        case model.hasPrefix("claude-opus"): (inRate, outRate, cacheRate) = (5, 25, 0.50)
        case model.hasPrefix("claude-sonnet-5"): (inRate, outRate, cacheRate) = (2, 10, 0.20)
        case model.hasPrefix("claude-sonnet"): (inRate, outRate, cacheRate) = (3, 15, 0.30)
        case model.hasPrefix("claude-haiku-5"): (inRate, outRate, cacheRate) = (0.10, 0.50, 0.01)
        case model.hasPrefix("claude-haiku"): (inRate, outRate, cacheRate) = (1, 5, 0.10)
        default: return 0
        }
        return (Double(input) * inRate + Double(output) * outRate + Double(cacheRead) * cacheRate + Double(cacheWrite) * inRate * 1.25) / 1_000_000
    }
}

/// One event of a streamed Messages API response, reduced to what the engine needs.
public enum ClaudeEvent: Sendable, Equatable {
    case messageStart(model: String, usage: TokenUsage)
    /// A content block opens. `block` is the whole `content_block` object (type, and for tool_use the id and name).
    case blockStart(index: Int, block: JSONValue)
    case textDelta(index: Int, text: String)
    case thinkingDelta(index: Int, text: String)
    case signatureDelta(index: Int, signature: String)
    case inputJSONDelta(index: Int, partial: String)
    case blockStop(index: Int)
    case messageDelta(stopReason: String?, usage: TokenUsage)
    case messageStop
    case error(String)

    /// Decodes the `data:` JSON of one SSE event.
    public static func parse(_ data: JSONValue) -> ClaudeEvent? {
        guard let type = data["type"]?.stringValue else { return nil }
        switch type {
        case "message_start":
            let m = data["message"]
            return .messageStart(model: m?["model"]?.stringValue ?? "", usage: usage(m?["usage"]))
        case "content_block_start":
            return .blockStart(index: data["index"]?.intValue ?? 0, block: data["content_block"] ?? .object([:]))
        case "content_block_delta":
            let i = data["index"]?.intValue ?? 0
            let d = data["delta"]
            switch d?["type"]?.stringValue {
            case "text_delta": return .textDelta(index: i, text: d?["text"]?.stringValue ?? "")
            case "thinking_delta": return .thinkingDelta(index: i, text: d?["thinking"]?.stringValue ?? "")
            case "signature_delta": return .signatureDelta(index: i, signature: d?["signature"]?.stringValue ?? "")
            case "input_json_delta": return .inputJSONDelta(index: i, partial: d?["partial_json"]?.stringValue ?? "")
            default: return nil
            }
        case "content_block_stop":
            return .blockStop(index: data["index"]?.intValue ?? 0)
        case "message_delta":
            return .messageDelta(stopReason: data["delta"]?["stop_reason"]?.stringValue, usage: usage(data["usage"]))
        case "message_stop":
            return .messageStop
        case "error":
            return .error(data["error"]?["message"]?.stringValue ?? data.text)
        case "ping":
            return nil
        default:
            return nil
        }
    }

    static func usage(_ u: JSONValue?) -> TokenUsage {
        var t = TokenUsage()
        t.input = u?["input_tokens"]?.intValue ?? 0
        t.output = u?["output_tokens"]?.intValue ?? 0
        t.cacheRead = u?["cache_read_input_tokens"]?.intValue ?? 0
        t.cacheWrite = u?["cache_creation_input_tokens"]?.intValue ?? 0
        return t
    }
}

/// Splits a Server-Sent Events byte stream into events. Feed it lines; it returns the events that completed.
public struct SSEParser: Sendable {
    private var event = ""
    private var data: [String] = []

    public init() {}

    public mutating func feed(line: String) -> (event: String, data: String)? {
        if line.isEmpty {
            defer { event = ""; data = [] }
            guard !data.isEmpty else { return nil }
            return (event, data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let (field, value): (String, String) = {
            guard let colon = line.firstIndex(of: ":") else { return (line, "") }
            var v = line[line.index(after: colon)...]
            if v.hasPrefix(" ") { v = v.dropFirst() }
            return (String(line[..<colon]), String(v))
        }()
        switch field {
        case "event": event = value
        case "data": data.append(value)
        default: break
        }
        return nil
    }
}

/// The lines of a byte stream, the empty ones included. `AsyncBytes.lines` drops empty lines, and an SSE
/// event ends with one: through `lines` the parser never saw an event end. `body` returns false to stop.
public func sseLines<Bytes: AsyncSequence>(_ bytes: Bytes, _ body: (String) async throws -> Bool) async throws
where Bytes.Element == UInt8 {
    var buffer: [UInt8] = []
    for try await byte in bytes {
        guard byte == 10 else { buffer.append(byte); continue }
        if buffer.last == 13 { buffer.removeLast() }
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        if try await !body(line) { return }
    }
    if !buffer.isEmpty { _ = try await body(String(decoding: buffer, as: UTF8.self)) }
}

/// Sends one request and streams the events back. The engine does not know the network, so a test feeds it
/// recorded events.
public protocol ModelTransport: Sendable {
    func stream(_ request: JSONValue) -> AsyncThrowingStream<ClaudeEvent, any Error>
}

public struct ClaudeAPIError: Error, CustomStringConvertible, Sendable {
    public let status: Int
    public let message: String
    public var description: String { status == 0 ? message : "HTTP \(status): \(message)" }
}

/// The Messages API over HTTPS. The key lives in the caller's hands (the app keeps it in the Keychain).
public struct URLSessionTransport: ModelTransport {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2026-10-21"

    let apiKey: String
    let betas: [String]

    public init(apiKey: String, betas: [String] = ["server-side-fallback-2026-07-01"]) {
        self.apiKey = apiKey
        self.betas = betas
    }

    public func stream(_ request: JSONValue) -> AsyncThrowingStream<ClaudeEvent, any Error> {
        let apiKey = apiKey, betas = betas
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: Self.endpoint)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
                    if !betas.isEmpty { req.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
                    req.httpBody = Data(request.text.utf8)
                    req.timeoutInterval = 600
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        let message = (try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8)))?["error"]?["message"]?.stringValue ?? body
                        throw ClaudeAPIError(status: status, message: message)
                    }
                    var parser = SSEParser()
                    try await sseLines(bytes) { line in
                        guard let (_, data) = parser.feed(line: line) else { return true }
                        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(data.utf8)) else { return true }
                        if let event = ClaudeEvent.parse(json) { continuation.yield(event) }
                        return true
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
