import Foundation
import Testing
@testable import LoopStudioControl
@testable import LoopStudioCore
import LoopStudioEngine

/// A minimal MCP client for this file, like the one in `SoundTests.swift`.
private struct Client {
    let server = LoopStudioServer.make()
    var id = 0
    struct Result { var isError: Bool; var text: String; var data: JSONValue }

    mutating func call(_ name: String, _ arguments: [String: JSONValue] = [:]) async throws -> Result {
        id += 1
        let message = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string("tools/call"),
                                        "params": .object(["name": .string(name), "arguments": .object(arguments)])])
        let data = try #require(await server.handle(Data(message.text.utf8)))
        let response = try JSONDecoder().decode(JSONValue.self, from: data)
        let result = try #require(response["result"], "protocol error: \(response.text)")
        return Result(isError: result["isError"]?.boolValue ?? false,
                      text: result["content"]?.arrayValue?.first?["text"]?.stringValue ?? "",
                      data: result["structuredContent"] ?? .null)
    }
}

/// Lemus handover P3-4. An assistant builds a 303 line through the named tools: `track_add`, the Audio Unit
/// through `command_apply` with `insertDevice` (`device_add` takes built-in devices only, as its description
/// says), `clip_create`, `notes_set`, then `render_bounce`. The bounce loads the 303 in its own offline instance
/// (`OfflineRender.prepare`, out of process) and must not be silent. Runs only with `LOOPSTUDIO_LEMUS=1`.
@Test func anAssistantCanBounceA303Line() async throws {
    guard ProcessInfo.processInfo.environment["LOOPSTUDIO_LEMUS"] == "1" else { return }
    guard AudioUnitCatalog.list().contains(where: { $0.identifier == "aumu/R303/Lmus" }) else { return }
    var client = Client()
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("lemus-\(UUID().uuidString).loopstudio").path
    _ = try await client.call("project_new", ["path": .string(path)])

    let added = try await client.call("track_add", ["name": .string("Acid"), "kind": .string("midi")])
    #expect(!added.isError, Comment(rawValue: added.text))
    let trackText = try #require(added.data["track"]?.stringValue)
    let track = TrackID(try #require(UUID(uuidString: trackText)))

    let slot = DeviceSlot(format: "audiounit", identifier: "aumu/R303/Lmus", name: "TB-303")
    let insert = Command.insertDevice(track: track, device: slot, index: 0)
    let device = try await client.call("command_apply", ["command": try JSONValue(encoding: insert)])
    #expect(!device.isError, Comment(rawValue: device.text))

    let clip = try await client.call("clip_create", ["track": .string("Acid"), "kind": .string("midi"), "length": .number(3840)])
    #expect(!clip.isError, Comment(rawValue: clip.text))
    let clipID = try #require(clip.data["clip"]?.stringValue)
    // Four eighth notes with an accent and a rest between them: the 303 slides when notes overlap, so keep them short.
    let notes: [JSONValue] = [0, 960, 1920, 2880].enumerated().map { i, tick in
        .object(["tick": .number(Double(tick)), "length": .number(480), "pitch": .number(i == 2 ? 60 : 48), "velocity": .number(i == 0 ? 110 : 90)])
    }
    let written = try await client.call("notes_set", ["clip": .string(clipID), "notes": .array(notes)])
    #expect(!written.isError, Comment(rawValue: written.text))

    let out = FileManager.default.temporaryDirectory.appendingPathComponent("lemus-\(UUID().uuidString).wav").path
    let bounce = try await client.call("render_bounce", ["path": .string(out), "tailSeconds": .number(0.5)])
    #expect(!bounce.isError, Comment(rawValue: bounce.text))
    let peak = try #require(bounce.data["peakDb"]?.doubleValue)
    let warnings = bounce.data["warnings"]?.arrayValue ?? []
    print("303 bounce: \(bounce.data["seconds"]?.doubleValue ?? 0) s, peak \(peak) dBFS, rms \(bounce.data["rmsDb"]?.doubleValue ?? 0) dBFS, warnings \(warnings)")
    #expect(warnings.isEmpty, "the 303 loaded for the bounce: \(warnings)")
    #expect(peak > -40, "the bounce is not silent (peak \(peak) dBFS)")
    #expect(FileManager.default.fileExists(atPath: out))
}
