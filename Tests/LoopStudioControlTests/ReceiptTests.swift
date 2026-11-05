import Foundation
import Testing
@testable import LoopStudioControl
@testable import LoopStudioCore

/// A fresh project in a temporary folder, with the standard and the named tools.
private func freshRegistry() async throws -> (ProjectSession, ToolRegistry) {
    let session = ProjectSession()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-\(UUID().uuidString)")
    try await session.create(at: folder.appendingPathComponent("R.loopstudio"), name: "R", sampleRate: 48_000)
    var registry = StandardTools.registry(session: session)
    for tool in StandardTools.namedTools(session: session) { registry.add(tool) }
    return (session, registry)
}

private func call(_ registry: ToolRegistry, _ name: String, _ args: [String: JSONValue]) async throws -> JSONValue {
    let tool = try #require(registry.tool(named: name))
    return try await tool.handler(ToolArguments(.object(args)))
}

private func receipt(_ value: JSONValue) throws -> Receipt {
    try #require(value["receipt"]).decode(Receipt.self)
}

@Test func aNamedToolReturnsAReceiptReadBackFromTheProject() async throws {
    let (session, registry) = try await freshRegistry()
    let added = try await call(registry, "track_add", ["name": .string("Drums"), "kind": .string("audio")])
    let r1 = try receipt(added)
    #expect(r1.command == "insertTrack")
    #expect(r1.revisionBefore == 0 && r1.revisionAfter == 1)
    #expect(r1.changes.first?.path == "tracks")
    #expect(r1.changes.first?.after == "Drums")

    let renamed = try await call(registry, "track_rename", ["track": .string("drums"), "name": .string("Kit")])
    let r2 = try receipt(renamed)
    #expect(r2.changes == [Receipt.Change(path: "Drums › name", before: "Drums", after: "Kit")])
    #expect(r2.summary == "Drums › name: Drums to Kit")
    #expect(try await session.project().tracks[0].name == "Kit")

    // The track is found by its position too.
    let mixed = try await call(registry, "track_set", ["track": .string("1"), "volumeDb": .number(-6), "mute": .bool(true)])
    let r3 = try receipt(mixed)
    #expect(r3.command == "batch")
    #expect(r3.changes.map(\.line) == ["Kit › volume: 0.0 dB to -6.0 dB", "Kit › mute: off to on"])
}

@Test func aParameterReadsBackWithItsNameAndUnit() async throws {
    let (session, registry) = try await freshRegistry()
    _ = try await call(registry, "track_add", ["name": .string("Bass"), "kind": .string("audio")])
    let added = try await call(registry, "device_add", ["track": .string("Bass"), "device": .string("delay")])
    #expect(try receipt(added).changes.first?.line == "Bass › devices: none to Delay")
    let deviceID = try #require(added["device"]?.stringValue)

    let spec = try #require(BuiltInEffects.spec("delay"))
    let feedback = try #require(spec.params.first { $0.key.lowercased().contains("feedback") })
    let value = (feedback.min + feedback.max) / 2
    // By name, by key, by id: all three find the same parameter and device.
    let set = try await call(registry, "param_set", ["track": .string("Bass"), "device": .string(deviceID), "param": .string(feedback.name), "value": .number(value)])
    let r = try receipt(set)
    #expect(r.command == "setDeviceParam")
    #expect(r.changes.first?.path == "Bass › Delay › \(feedback.name)")
    let after = try #require(r.changes.first?.after)
    #expect(after.hasPrefix(String(format: "%.2f", value)), "\(after)")
    #expect(r.changes.first?.before == String(format: "%.2f", feedback.def))
    let project = try await session.project()
    #expect(project.tracks[0].devices[0].params[feedback.key] == value)

    // Out of range: rejected, nothing changes.
    let revision = await session.revision()
    await #expect(throws: ToolFailure.self) {
        _ = try await call(registry, "param_set", ["track": .string("Bass"), "device": .string("Delay"), "param": .string(feedback.key), "value": .number(feedback.max + 1)])
    }
    #expect(await session.revision() == revision)
}

@Test func ambiguousNamesAreAnErrorThatListsTheCandidates() async throws {
    let (_, registry) = try await freshRegistry()
    _ = try await call(registry, "track_add", ["name": .string("Synth"), "kind": .string("midi")])
    _ = try await call(registry, "track_add", ["name": .string("Synth"), "kind": .string("midi")])
    do {
        _ = try await call(registry, "track_rename", ["track": .string("Synth"), "name": .string("Lead")])
        Issue.record("two tracks named Synth must not resolve")
    } catch let failure as ToolFailure {
        #expect(failure.message.contains("2 tracks are named 'Synth'"))
        #expect(failure.message.contains("Use the id"))
    }
    // A position still works.
    let r = try receipt(try await call(registry, "track_rename", ["track": .string("2"), "name": .string("Lead")]))
    #expect(r.changes.first?.after == "Lead")
}

@Test func aSessionClipGetsNotesAndIsFoundBySlot() async throws {
    let (session, registry) = try await freshRegistry()
    _ = try await call(registry, "track_add", ["name": .string("Keys"), "kind": .string("midi")])
    let created = try await call(registry, "clip_create", ["track": .string("Keys"), "kind": .string("midi"), "length": .number(3840), "slot": .number(2), "name": .string("Chords")])
    let r1 = try receipt(created)
    #expect(r1.changes.first?.line == "Keys › slot 2: empty to Chords")

    let notes = try await call(registry, "notes_set", ["clip": .string("Keys/slot 2"), "notes": .array([
        .object(["tick": .number(0), "length": .number(960), "pitch": .number(60)]),
        .object(["tick": .number(960), "length": .number(960), "pitch": .number(64), "velocity": .number(90)]),
    ])])
    let r2 = try receipt(notes)
    #expect(r2.changes.first?.line == "Keys › slot 2 › Chords › notes: 0 notes to 2 notes")
    let project = try await session.project()
    guard case .midi(let clip)? = project.tracks[0].slots[1]?.clip else { Issue.record("no MIDI clip in slot 2"); return }
    #expect(clip.notes.map(\.pitch) == [60, 64])
    #expect(clip.loop == true)

    // A removal is destructive; the receipt shows the slot empty again.
    let removed = try await call(registry, "clip_remove", ["clip": .string("Chords")])
    #expect(try receipt(removed).changes.first?.line == "Keys › slot 2: Chords to empty")
    #expect(Command.setSlot(track: project.tracks[0].id, index: 1, slot: nil).isDestructive)
    #expect(!Command.setVolume(id: project.tracks[0].id, db: 0).isDestructive)
}

@Test func anInstrumentNeedsAMIDITrackAndReplacesTheOldOne() async throws {
    let (session, registry) = try await freshRegistry()
    _ = try await call(registry, "track_add", ["name": .string("Audio"), "kind": .string("audio")])
    _ = try await call(registry, "track_add", ["name": .string("Bass"), "kind": .string("midi")])
    await #expect(throws: ToolFailure.self) {
        _ = try await call(registry, "device_add", ["track": .string("Audio"), "device": .string("acid")])
    }
    _ = try await call(registry, "device_add", ["track": .string("Bass"), "device": .string("acid")])
    _ = try await call(registry, "device_add", ["track": .string("Bass"), "device": .string("delay")])
    let swapped = try await call(registry, "device_add", ["track": .string("Bass"), "device": .string("drum808")])
    let r = try receipt(swapped)
    #expect(r.command == "batch")
    let devices = try await session.project().tracks[1].devices.map(\.identifier)
    #expect(devices == ["drum808", "delay"])
}

@Test func theMCPServerListsTheNamedToolsAndTheGlossary() async throws {
    let server = LoopStudioServer.make(session: ProjectSession())
    let list = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/list"), "params": .object([:])])
    let data = try #require(await server.handle(Data(list.text.utf8)))
    let response = try JSONDecoder().decode(JSONValue.self, from: data)
    let names = Set(response["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? [])
    #expect(names.isSuperset(of: ["track_add", "param_set", "clip_create", "notes_set", "send_set", "tempo_set", "loop_set", "command_apply"]))

    let read = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(2), "method": .string("resources/read"),
                                 "params": .object(["uri": .string("loopstudio://help/ui")])])
    let help = try JSONDecoder().decode(JSONValue.self, from: try #require(await server.handle(Data(read.text.utf8))))
    let text = help["result"]?["contents"]?.arrayValue?.first?["text"]?.stringValue ?? ""
    #expect(text.contains("Session view"))
}
