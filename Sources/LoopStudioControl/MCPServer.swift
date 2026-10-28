import Foundation

/// A Model Context Protocol server over JSON-RPC 2.0. One JSON message per line (the stdio transport).
/// `handle` is a pure function from request bytes to response bytes, so tests need no process or pipe.
///
/// Rules:
/// - stdout carries protocol messages only. Logs go to stderr.
/// - A failed tool call returns a normal result with `isError: true`, so the agent can read it and retry.
///   Only an unknown tool or a broken request is a protocol error.
public final class MCPServer: Sendable {
    public struct Resource: Sendable {
        public var uri: String
        public var name: String
        public var description: String
        public var mimeType: String

        public init(uri: String, name: String, description: String, mimeType: String = "application/json") {
            self.uri = uri
            self.name = name
            self.description = description
            self.mimeType = mimeType
        }
    }

    public struct Resources: Sendable {
        public var list: @Sendable () async -> [Resource]
        public var read: @Sendable (String) async throws -> String?

        public init(list: @escaping @Sendable () async -> [Resource], read: @escaping @Sendable (String) async throws -> String?) {
            self.list = list
            self.read = read
        }
    }

    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private let name: String
    private let version: String
    private let instructions: String
    private let registry: ToolRegistry
    private let resources: Resources?

    public init(name: String = "loopstudio", version: String = "0.1.0", instructions: String = "",
                registry: ToolRegistry, resources: Resources? = nil) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.registry = registry
        self.resources = resources
    }

    // MARK: Entry points

    /// Reads lines from stdin until it closes. Blocks the calling task between lines.
    public func serveStandardIO() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let response = await handle(Data(line.utf8)) {
                print(String(decoding: response, as: UTF8.self))
                fflush(stdout)
            }
        }
    }

    /// Handles one message. Returns nil for notifications, which get no response.
    public func handle(_ message: Data) async -> Data? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: message) else {
            return encode(error: -32700, "parse error", id: .null)
        }
        guard case .object(let object) = value, let method = object["method"]?.stringValue else {
            return encode(error: -32600, "invalid request (batches are not supported)", id: value["id"] ?? .null)
        }
        let params = object["params"] ?? .object([:])
        guard let id = object["id"] else { return nil } // notification

        do {
            return encode(result: try await dispatch(method, params), id: id)
        } catch let e as RPCError {
            return encode(error: e.code, e.message, id: id)
        } catch {
            return encode(error: -32603, "internal error: \(error)", id: id)
        }
    }

    // MARK: Methods

    struct RPCError: Error {
        let code: Int
        let message: String
    }

    private func dispatch(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? ""
            let chosen = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            var capabilities: [String: JSONValue] = ["tools": .object(["listChanged": .bool(false)])]
            if resources != nil { capabilities["resources"] = .object(["subscribe": .bool(false), "listChanged": .bool(false)]) }
            var result: [String: JSONValue] = [
                "protocolVersion": .string(chosen),
                "capabilities": .object(capabilities),
                "serverInfo": .object(["name": .string(name), "version": .string(version)]),
            ]
            if !instructions.isEmpty { result["instructions"] = .string(instructions) }
            return .object(result)

        case "ping":
            return .object([:])

        case "tools/list":
            return .object(["tools": .array(registry.tools.map(describe))])

        case "tools/call":
            guard let toolName = params["name"]?.stringValue else { throw RPCError(code: -32602, message: "missing tool name") }
            guard let tool = registry.tool(named: toolName) else { throw RPCError(code: -32602, message: "unknown tool: \(toolName)") }
            return await call(tool, arguments: params["arguments"] ?? .object([:]))

        case "resources/list":
            guard let resources else { throw RPCError(code: -32601, message: "method not found") }
            let list = await resources.list()
            return .object(["resources": .array(list.map {
                .object(["uri": .string($0.uri), "name": .string($0.name), "description": .string($0.description),
                         "mimeType": .string($0.mimeType)])
            })])

        case "resources/read":
            guard let resources else { throw RPCError(code: -32601, message: "method not found") }
            guard let uri = params["uri"]?.stringValue else { throw RPCError(code: -32602, message: "missing uri") }
            do {
                guard let text = try await resources.read(uri) else { throw RPCError(code: -32002, message: "resource not found: \(uri)") }
                return .object(["contents": .array([.object(["uri": .string(uri), "mimeType": .string("application/json"), "text": .string(text)])])])
            } catch let e as RPCError {
                throw e
            } catch {
                throw RPCError(code: -32002, message: "\(error)")
            }

        default:
            throw RPCError(code: -32601, message: "method not found: \(method)")
        }
    }

    private func describe(_ tool: Tool) -> JSONValue {
        .object([
            "name": .string(tool.name),
            "title": .string(tool.title),
            "description": .string(tool.description),
            "inputSchema": tool.inputSchema,
            "annotations": .object([
                "readOnlyHint": .bool(tool.annotations.readOnly),
                "destructiveHint": .bool(tool.annotations.destructive),
                "idempotentHint": .bool(tool.annotations.idempotent),
            ]),
        ])
    }

    private func call(_ tool: Tool, arguments: JSONValue) async -> JSONValue {
        func result(_ text: String, structured: JSONValue?, isError: Bool) -> JSONValue {
            var o: [String: JSONValue] = ["content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                                          "isError": .bool(isError)]
            if let structured { o["structuredContent"] = structured }
            return .object(o)
        }
        do {
            let value = try await tool.handler(ToolArguments(arguments))
            // structuredContent must be an object.
            let structured: JSONValue = value.objectValue != nil ? value : .object(["result": value])
            return result(value.text, structured: structured, isError: false)
        } catch let failure as ToolFailure {
            return result(failure.message, structured: nil, isError: true)
        } catch {
            return result("\(error)", structured: nil, isError: true)
        }
    }

    // MARK: Encoding

    private func encode(result: JSONValue, id: JSONValue) -> Data {
        wire(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    private func encode(error code: Int, _ message: String, id: JSONValue) -> Data {
        wire(.object(["jsonrpc": .string("2.0"), "id": id,
                      "error": .object(["code": .number(Double(code)), "message": .string(message)])]))
    }

    private func wire(_ value: JSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }
}
