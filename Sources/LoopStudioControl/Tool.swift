import Foundation

public struct ToolAnnotations: Sendable {
    /// The tool changes nothing.
    public var readOnly: Bool
    /// The tool can lose data that undo cannot bring back.
    public var destructive: Bool
    /// Calling it twice with the same arguments has the same effect as once.
    public var idempotent: Bool

    public init(readOnly: Bool = false, destructive: Bool = false, idempotent: Bool = false) {
        self.readOnly = readOnly
        self.destructive = destructive
        self.idempotent = idempotent
    }

    public static let read = ToolAnnotations(readOnly: true, idempotent: true)
}

/// A problem the caller can fix (a bad argument, a rejected command). It reaches the agent as a
/// tool result with `isError: true`, so the agent can read the message and try again.
public struct ToolFailure: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Arguments of a tool call, with typed access and clear error messages.
public struct ToolArguments: Sendable {
    public let raw: JSONValue

    public init(_ raw: JSONValue) { self.raw = raw }

    public func string(_ key: String) throws -> String {
        guard let v = raw[key]?.stringValue else { throw ToolFailure("missing or invalid argument '\(key)' (string expected)") }
        return v
    }

    public func optionalString(_ key: String) -> String? { raw[key]?.stringValue }
    public func optionalInt(_ key: String) -> Int? { raw[key]?.intValue }
    public func optionalDouble(_ key: String) -> Double? { raw[key]?.doubleValue }

    public func int(_ key: String) throws -> Int {
        guard let v = raw[key]?.intValue else { throw ToolFailure("missing or invalid argument '\(key)' (integer expected)") }
        return v
    }

    public func decode<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T {
        guard let v = raw[key] else { throw ToolFailure("missing argument '\(key)'") }
        do { return try v.decode(type) } catch { throw ToolFailure("argument '\(key)' is not valid: \(error)") }
    }

    public func decodeOptional<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T? {
        guard let v = raw[key], v != .null else { return nil }
        do { return try v.decode(type) } catch { throw ToolFailure("argument '\(key)' is not valid: \(error)") }
    }
}

public struct Tool: Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    public var annotations: ToolAnnotations
    public var handler: @Sendable (ToolArguments) async throws -> JSONValue

    public init(name: String, title: String, description: String, inputSchema: JSONValue,
                annotations: ToolAnnotations = ToolAnnotations(), handler: @escaping @Sendable (ToolArguments) async throws -> JSONValue) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.handler = handler
    }
}

public struct ToolRegistry: Sendable {
    public private(set) var tools: [Tool] = []

    public init(_ tools: [Tool] = []) { self.tools = tools }

    public mutating func add(_ tool: Tool) {
        precondition(!tools.contains { $0.name == tool.name }, "duplicate tool \(tool.name)")
        tools.append(tool)
    }

    public func tool(named name: String) -> Tool? { tools.first { $0.name == name } }
}

/// Small helpers to write JSON Schemas for tool inputs.
public enum Schema {
    public static func object(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("object"), "properties": .object(properties),
                                      "additionalProperties": .bool(false)]
        if !required.isEmpty { o["required"] = .array(required.map { .string($0) }) }
        return .object(o)
    }

    public static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    public static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("integer"), "description": .string(description)]
        if let minimum { o["minimum"] = .number(Double(minimum)) }
        if let maximum { o["maximum"] = .number(Double(maximum)) }
        return .object(o)
    }

    public static func number(_ description: String) -> JSONValue {
        .object(["type": .string("number"), "description": .string(description)])
    }

    public static func anyObject(_ description: String) -> JSONValue {
        .object(["type": .string("object"), "description": .string(description)])
    }
}
