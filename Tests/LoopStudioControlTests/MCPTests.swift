import Foundation
import Testing
@testable import LoopStudioControl
@testable import LoopStudioCore

// MARK: Helpers

private func tempProject() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString).loopstudio").path
}

private struct Client {
    let server: MCPServer
    var nextID = 1

    init(session: ProjectSession = ProjectSession()) { server = LoopStudioServer.make(session: session) }

    /// Sends a request and returns the parsed response.
    mutating func rpc(_ method: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        let message = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(Double(nextID)), "method": .string(method), "params": params])
        nextID += 1
        let data = try #require(await server.handle(Data(message.text.utf8)))
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    struct Result {
        var isError: Bool
        var text: String
        var data: JSONValue
    }

    /// Calls a tool and unpacks the result. A protocol error fails the test.
    mutating func call(_ name: String, _ arguments: JSONValue = .object([:])) async throws -> Result {
        let response = try await rpc("tools/call", .object(["name": .string(name), "arguments": arguments]))
        let result = try #require(response["result"], "protocol error: \(response.text)")
        let text = result["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        return Result(isError: result["isError"]?.boolValue ?? false, text: text, data: result["structuredContent"] ?? .null)
    }
}

private func trackIDs(_ r: Client.Result) -> [String] {
    r.data["tracks"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
}

// MARK: Protocol

@Test func initializeNegotiatesTheVersion() async throws {
    var client = Client()
    let ok = try await client.rpc("initialize", .object(["protocolVersion": .string("2025-03-26")]))
    #expect(ok["result"]?["protocolVersion"]?.stringValue == "2025-03-26")
    #expect(ok["result"]?["serverInfo"]?["name"]?.stringValue == "loopstudio")
    #expect(ok["result"]?["capabilities"]?["tools"] != nil)
    #expect(ok["result"]?["instructions"]?.stringValue?.contains("project_new") == true)

    let unknown = try await client.rpc("initialize", .object(["protocolVersion": .string("1999-01-01")]))
    #expect(unknown["result"]?["protocolVersion"]?.stringValue == MCPServer.supportedVersions[0])
}

@Test func notificationsGetNoResponse() async {
    let server = LoopStudioServer.make()
    let note = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
    #expect(await server.handle(Data(note.utf8)) == nil)
}

@Test func brokenInputGivesProtocolErrors() async throws {
    let server = LoopStudioServer.make()
    func code(_ text: String) async throws -> Int? {
        let data = try #require(await server.handle(Data(text.utf8)))
        return try JSONDecoder().decode(JSONValue.self, from: data)["error"]?["code"]?.intValue
    }
    #expect(try await code("{not json") == -32700)
    #expect(try await code(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#) == -32600)
    #expect(try await code(#"{"jsonrpc":"2.0","id":1}"#) == -32600)
    #expect(try await code(#"{"jsonrpc":"2.0","id":1,"method":"nope"}"#) == -32601)
    #expect(try await code(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nope"}}"#) == -32602)
    #expect(try await code(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#) == -32602)
}

@Test func stringIDsAreEchoed() async throws {
    let server = LoopStudioServer.make()
    let data = try #require(await server.handle(Data(#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#.utf8)))
    let response = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(response["id"]?.stringValue == "abc")
    #expect(response["result"] != nil)
}

@Test func toolListIsCompleteAndDescribed() async throws {
    var client = Client()
    let list = try await client.rpc("tools/list")
    let tools = try #require(list["result"]?["tools"]?.arrayValue)
    let names = Set(tools.compactMap { $0["name"]?.stringValue })
    for expected in ["project_new", "project_open", "project_save", "project_info", "track_list", "track_get",
                     "command_apply", "command_examples", "undo", "redo", "audio_devices", "midi_endpoints",
                     "io_resolve", "follow_simulate", "tempo_convert"] {
        #expect(names.contains(expected), "missing tool \(expected)")
    }
    for tool in tools {
        #expect(tool["description"]?.stringValue?.isEmpty == false)
        #expect(tool["inputSchema"]?["type"]?.stringValue == "object")
        #expect(tool["annotations"]?["readOnlyHint"]?.boolValue != nil)
    }
    let readOnly = tools.filter { $0["annotations"]?["readOnlyHint"]?.boolValue == true }.compactMap { $0["name"]?.stringValue }
    #expect(readOnly.contains("track_list") && !readOnly.contains("command_apply"))
}

// MARK: Working with a project

@Test func fullEditSaveReopenFlow() async throws {
    let path = tempProject()
    var client = Client()
    #expect(try await client.call("track_list").isError, "no project is open yet")

    let created = try await client.call("project_new", .object(["path": .string(path), "name": .string("Demo")]))
    #expect(!created.isError)
    #expect(created.data["name"]?.stringValue == "Demo")
    #expect(created.data["issues"]?.arrayValue?.isEmpty == true)

    // Use the real example as the starting point for the insert.
    let examples = try await client.call("command_examples").data
    let trackJSON = try #require(examples["insertTrack"])
    let added = try await client.call("command_apply", .object(["command": trackJSON]))
    #expect(!added.isError, Comment(rawValue: added.text))
    #expect(try await client.call("track_list").data["tracks"]?.arrayValue?.count == 2) // Drums + master

    #expect(try await client.call("project_info").data["unsavedChanges"]?.boolValue == true)
    _ = try await client.call("project_save")
    #expect(try await client.call("project_info").data["unsavedChanges"]?.boolValue == false)

    // A new session reads the same project from disk.
    var other = Client()
    let reopened = try await other.call("project_open", .object(["path": .string(path)]))
    #expect(reopened.data["recoveredCommands"]?.intValue == 0)
    #expect(trackIDs(try await other.call("track_list")).count == 2)

    // Undo and redo.
    #expect(try await other.call("undo").data["changed"]?.boolValue == false, "a fresh session has no history")
    #expect(try await client.call("undo").data["changed"]?.boolValue == true)
    #expect(try await client.call("track_list").data["tracks"]?.arrayValue?.count == 1)
    #expect(try await client.call("redo").data["changed"]?.boolValue == true)
    #expect(try await client.call("track_list").data["tracks"]?.arrayValue?.count == 2)
}

@Test func rejectedCommandIsAnErrorResultAndChangesNothing() async throws {
    var client = Client()
    _ = try await client.call("project_new", .object(["path": .string(tempProject())]))
    let before = try await client.call("project_info").data["revision"]?.intValue
    let bad = JSONValue.object(["setVolume": .object(["id": .string(UUID().uuidString), "db": .number(-6)])])
    let result = try await client.call("command_apply", .object(["command": bad]))
    #expect(result.isError)
    #expect(result.text.contains("rejected"))
    #expect(try await client.call("project_info").data["revision"]?.intValue == before)

    let garbage = try await client.call("command_apply", .object(["command": .object(["flyToMoon": .object([:])])]))
    #expect(garbage.isError)
    #expect(try await client.call("command_apply", .object([:])).isError)
}

@Test func pathsOutsideLoopstudioFoldersAreRefused() async throws {
    var client = Client()
    for bad in ["/tmp/evil", "relative.loopstudio", "/etc/passwd", "/tmp/x.txt"] {
        let r = try await client.call("project_new", .object(["path": .string(bad)]))
        #expect(r.isError, "\(bad) must be refused")
    }
    let path = tempProject()
    _ = try await client.call("project_new", .object(["path": .string(path)]))
    #expect(try await client.call("project_new", .object(["path": .string(path)])).isError, "never overwrite a project")
    #expect(try await client.call("project_new", .object(["path": .string(tempProject()), "sampleRate": .number(12345)])).isError)
}

@Test func unsavedChangesSurviveACrash() async throws {
    let path = tempProject()
    var first = Client()
    _ = try await first.call("project_new", .object(["path": .string(path)]))
    let examples = try await first.call("command_examples").data
    _ = try await first.call("command_apply", .object(["command": try #require(examples["insertTrack"])]))
    // No save. The session is dropped, as in a crash.

    var second = Client()
    let reopened = try await second.call("project_open", .object(["path": .string(path)]))
    #expect(reopened.data["recoveredCommands"]?.intValue == 1)
    #expect(reopened.data["recoveryFailed"]?.boolValue == false)
    #expect(reopened.data["unsavedChanges"]?.boolValue == true)
    #expect(try await second.call("track_list").data["tracks"]?.arrayValue?.count == 2)
}

@Test func everyExampleIsAValidCommand() async throws {
    var client = Client()
    let examples = try #require(try await client.call("command_examples").data.objectValue)
    #expect(examples.count >= 20)
    for (name, json) in examples {
        #expect(throws: Never.self, "example \(name) does not decode") { try json.decode(Command.self) }
    }
}

@Test func batchIsOneUndoStep() async throws {
    var client = Client()
    _ = try await client.call("project_new", .object(["path": .string(tempProject())]))
    let master = try #require(try await client.call("project_info").data["masterId"]?.stringValue)
    let batch = JSONValue.object(["batch": .object(["commands": .array([
        .object(["setVolume": .object(["id": .string(master), "db": .number(-6)])]),
        .object(["setPan": .object(["id": .string(master), "pan": .number(0.5)])]),
    ])])])
    _ = try await client.call("command_apply", .object(["command": batch]))
    func masterTrack() async throws -> JSONValue? {
        try await client.call("track_list").data["tracks"]?.arrayValue?.last
    }
    #expect(try await masterTrack()?["volumeDb"]?.doubleValue == -6)
    _ = try await client.call("undo")
    #expect(try await masterTrack()?["volumeDb"]?.doubleValue == 0)
    #expect(try await masterTrack()?["pan"]?.doubleValue == 0)
}

// MARK: Other tools

@Test func followSimulationMatchesTheWeights() async throws {
    var client = Client()
    _ = try await client.call("project_new", .object(["path": .string(tempProject())]))
    let id = UUID().uuidString
    let track = JSONValue.object(["insertTrack": .object([
        "index": .number(0),
        "track": try JSONValue(encoding: Track(id: TrackID(UUID(uuidString: id)!), name: "T", kind: .audio)),
    ])])
    _ = try await client.call("command_apply", .object(["command": track]))
    let follow = FollowActions(a: FollowAction(.replay, weight: 3), b: FollowAction(.stop, weight: 1), time: .loops(1))
    let slot = SessionSlot(clip: .dummy(DummyClip(length: 3840)), follow: follow)
    let setSlot = Command.setSlot(track: TrackID(UUID(uuidString: id)!), index: 0, slot: slot)
    let applied = try await client.call("command_apply", .object(["command": try JSONValue(encoding: setSlot)]))
    #expect(!applied.isError, Comment(rawValue: applied.text))

    let sim = try await client.call("follow_simulate", .object(["track": .string(id), "slot": .number(0), "launches": .number(8000)]))
    #expect(!sim.isError, Comment(rawValue: sim.text))
    let rows = try #require(sim.data["results"]?.arrayValue)
    let replay = try #require(rows.first { $0["outcome"]?.stringValue == "play slot 0" }?["percent"]?.doubleValue)
    #expect(replay > 72 && replay < 78)

    let empty = try await client.call("follow_simulate", .object(["track": .string(id), "slot": .number(3)]))
    #expect(empty.isError)
}

@Test func tempoConversion() async throws {
    var client = Client()
    _ = try await client.call("project_new", .object(["path": .string(tempProject()), "sampleRate": .number(48_000)]))
    let r = try await client.call("tempo_convert", .object(["ticks": .number(960)]))
    #expect(r.data["seconds"]?.doubleValue == 0.5)
    #expect(r.data["frames"]?.intValue == 24_000)
    #expect(r.data["bpm"]?.doubleValue == 120)
    let back = try await client.call("tempo_convert", .object(["seconds": .number(2)]))
    #expect(back.data["ticks"]?.intValue == 3840)
    #expect(try await client.call("tempo_convert").isError)
}

@Test func deviceToolsAnswerOnThisMachine() async throws {
    var client = Client()
    let devices = try await client.call("audio_devices")
    #expect(devices.data["devices"]?.arrayValue != nil)
    #expect(try await client.call("midi_endpoints").data["sources"]?.arrayValue != nil)

    _ = try await client.call("project_new", .object(["path": .string(tempProject())]))
    let io = try await client.call("io_resolve")
    #expect(!io.isError, Comment(rawValue: io.text))
    #expect(io.data["issues"]?.arrayValue != nil)
    #expect(io.data["sampleRate"]?.doubleValue != nil)
    // A device that does not exist is reported, not fatal.
    let profile = JSONValue.object(["outputDeviceUID": .string("no-such-device"), "sampleRate": .number(48_000), "bufferFrames": .number(256),
                                    "outputs": .array([]), "inputs": .array([])])
    let missing = try await client.call("io_resolve", .object(["profile": profile]))
    #expect(missing.data["issues"]?.arrayValue?.contains { $0.stringValue?.contains("deviceMissing") == true } == true)
}

@Test func resourcesAppearWhenAProjectIsOpen() async throws {
    var client = Client()
    // Without a project only the UI glossary is there; the project resources come with the project.
    let before = try await client.rpc("resources/list")["result"]?["resources"]?.arrayValue
    #expect(before?.map { $0["uri"]?.stringValue } == ["loopstudio://help/ui"])
    _ = try await client.call("project_new", .object(["path": .string(tempProject())]))
    let list = try await client.rpc("resources/list")["result"]?["resources"]?.arrayValue
    #expect(list?.count == 3)
    let read = try await client.rpc("resources/read", .object(["uri": .string("loopstudio://project/summary")]))
    let text = try #require(read["result"]?["contents"]?.arrayValue?.first?["text"]?.stringValue)
    #expect(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))["tracks"]?.intValue == 0)
    let missing = try await client.rpc("resources/read", .object(["uri": .string("loopstudio://nope")]))
    #expect(missing["error"]?["code"]?.intValue == -32002)
}

@Test func effectCatalogListsEveryBuiltInEffectWithItsKeys() async throws {
    var client = Client()
    let result = try await client.call("effect_catalog")
    let effects = try #require(result.data["effects"]?.arrayValue)
    #expect(effects.count == BuiltInEffects.all.count)
    let delay = try #require(effects.first { $0["id"]?.stringValue == "delay" })
    let keys = delay["params"]?.arrayValue?.compactMap { $0["key"]?.stringValue } ?? []
    #expect(keys.contains("timeMs") && keys.contains("timeMsSync") && keys.contains("timeMsDivision"))
    #expect(result.data["divisions"]?.arrayValue?.count == NoteDivision.all.count)
    // The instruments, and the pad table of the drum kit.
    let instruments = try #require(result.data["instruments"]?.arrayValue)
    #expect(instruments.map { $0["id"]?.stringValue } == BuiltInInstruments.all.map { Optional($0.id) })
    let pads = try #require(result.data["pads"]?["drum808"]?.arrayValue)
    #expect(pads.count == BuiltInInstruments.drumPads.count)
    #expect(pads.first?["notes"]?.arrayValue?.first?.intValue == 36, "the kick on C1")
}
