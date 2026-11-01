import Foundation
import Testing
@testable import LoopStudioControl

/// The Unix socket carries the same protocol as stdio: one JSON message per line, answers in order,
/// notifications without an answer.
@Suite struct SocketTransportTests {
    private func temporarySocketPath() -> String {
        // Unix socket paths are short; the temp folder is, the test bundle's path is not.
        "/tmp/loopstudio-test-\(UUID().uuidString.prefix(8)).sock"
    }

    @Test func theSocketAnswersRequestsInOrderAndSkipsNotifications() throws {
        let path = temporarySocketPath()
        let transport = SocketTransport(server: LoopStudioServer.make(), path: path)
        try transport.start()
        defer { transport.stop() }

        let client = try #require(SocketClient(path: path))
        let hello = try #require(client.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#))
        #expect(hello.contains("\"id\":1"))
        #expect(hello.contains("loopstudio"))
        // A notification has no id and gets no answer; the next request still gets its own.
        #expect(client.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let tools = try #require(client.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        #expect(tools.contains("\"id\":2"))
        #expect(tools.contains("command_apply"))
        let pong = try #require(client.send(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#))
        #expect(pong.contains("\"id\":3"))
    }

    @Test func twoClientsGetTheirOwnAnswers() throws {
        let path = temporarySocketPath()
        let transport = SocketTransport(server: LoopStudioServer.make(), path: path)
        try transport.start()
        defer { transport.stop() }
        let a = try #require(SocketClient(path: path)), b = try #require(SocketClient(path: path))
        let ra = try #require(a.send(#"{"jsonrpc":"2.0","id":"a","method":"ping"}"#))
        let rb = try #require(b.send(#"{"jsonrpc":"2.0","id":"b","method":"ping"}"#))
        #expect(ra.contains("\"id\":\"a\""))
        #expect(rb.contains("\"id\":\"b\""))
    }

    @Test func noListenerMeansNoClient() {
        #expect(SocketClient(path: temporarySocketPath()) == nil)
        #expect(SocketClient.isRequest(#"{"jsonrpc":"2.0","id":5,"method":"ping"}"#))
        #expect(!SocketClient.isRequest(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    }

    @Test func extraToolsJoinTheStandardOnes() async throws {
        let extra = Tool(name: "app_status", title: "Status", description: "test", inputSchema: Schema.object(), annotations: .read) { _ in
            .object(["playing": .bool(false)])
        }
        let server = LoopStudioServer.make(extraTools: [extra], note: "live note")
        let hello = try #require(await server.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8)))
        #expect(String(decoding: hello, as: UTF8.self).contains("live note"))
        let call = try #require(await server.handle(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"app_status","arguments":{}}}"#.utf8)))
        #expect(String(decoding: call, as: UTF8.self).contains("\"playing\":false"))
    }
}
