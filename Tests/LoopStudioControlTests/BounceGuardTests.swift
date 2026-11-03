import Foundation
import Testing
@testable import LoopStudioControl
@testable import LoopStudioCore

/// Sends one JSON-RPC request to a fresh server and returns the decoded response.
private func rpc(_ server: MCPServer, _ method: String, _ params: JSONValue, id: Int) async throws -> JSONValue {
    let message = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params])
    let data = try #require(await server.handle(Data(message.text.utf8)))
    return try JSONDecoder().decode(JSONValue.self, from: data)
}

/// A valid JSON number like 1e300 seconds must come back as a tool error, not trap in the frame count.
@Test func anAbsurdBounceTailIsRefusedNotFatal() async throws {
    let server = LoopStudioServer.make(session: ProjectSession())
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bounce-\(UUID().uuidString)")
    let project = folder.appendingPathComponent("B.loopstudio").path
    _ = try await rpc(server, "tools/call", .object(["name": .string("project_new"),
                                                      "arguments": .object(["path": .string(project), "name": .string("B")])]), id: 1)
    let response = try await rpc(server, "tools/call", .object([
        "name": .string("render_bounce"),
        "arguments": .object(["path": .string(folder.appendingPathComponent("out.wav").path), "tailSeconds": .number(1e300)]),
    ]), id: 2)
    let result = try #require(response["result"], "protocol error: \(response.text)")
    #expect(result["isError"]?.boolValue == true)
    let text = result["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
    #expect(text.contains("tailSeconds"), "\(text)")
}
