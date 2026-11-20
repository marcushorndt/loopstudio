import AVFoundation
import Foundation
import Testing
@testable import LoopStudioControl
@testable import LoopStudioCore

private func tone(seconds: Double, amplitude: Float = 0.5) throws -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID().uuidString).wav")
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    let n = AVAudioFrameCount(seconds * 48_000)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
    buffer.frameLength = n
    for c in 0..<2 { for i in 0..<Int(n) { buffer.floatChannelData![c][i] = amplitude * Float(sin(2 * .pi * 440 * Double(i) / 48_000)) } }
    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                                                          AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24])
    try file.write(from: buffer)
    return url.path
}

private func wavPath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString).wav").path
}

private struct Studio {
    var client = ClientHelper()
    var track = ""

    static func make() async throws -> Studio {
        var s = Studio()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("s-\(UUID().uuidString).loopstudio").path
        _ = try await s.client.call("project_new", ["path": .string(path)])
        let id = UUID()
        let insert = Command.insertTrack(track: Track(id: TrackID(id), name: "Audio", kind: .audio), index: 0)
        _ = try await s.client.call("command_apply", ["command": try JSONValue(encoding: insert)])
        s.track = id.uuidString
        return s
    }
}

/// Minimal client for these tests.
private struct ClientHelper {
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

@Test func importDropBounceMeasure() async throws {
    var studio = try await Studio.make()
    let imported = try await studio.client.call("asset_import", ["path": .string(try tone(seconds: 2))])
    #expect(!imported.isError, Comment(rawValue: imported.text))
    #expect(imported.data["seconds"]?.doubleValue == 2)
    #expect(imported.data["wouldLoop"]?.boolValue == true, "a 2 s sample is short, so it loops by default")
    let asset = try #require(imported.data["asset"]?.stringValue)

    // Drop at beat 2, exactly one second long (1920 ticks at 120 BPM).
    let dropped = try await studio.client.call("sample_drop", ["track": .string(studio.track), "asset": .string(asset),
                                                              "startTick": .number(960), "lengthTicks": .number(1920)])
    #expect(!dropped.isError, Comment(rawValue: dropped.text))
    #expect(dropped.data["loop"]?.boolValue == true && dropped.data["fadeMs"]?.doubleValue == 2)

    let out = wavPath()
    let bounce = try await studio.client.call("render_bounce", ["path": .string(out)])
    #expect(!bounce.isError, Comment(rawValue: bounce.text))
    #expect(bounce.data["seconds"]?.doubleValue == 1.5, "starts at 0.5 s and lasts 1 s")
    let peak = try #require(bounce.data["peakDb"]?.doubleValue)
    #expect(abs(peak - (-6.0)) < 0.2, "0.5 amplitude is -6 dBFS (peak \(peak))")
    #expect(bounce.data["clipping"]?.boolValue == false)
    #expect(bounce.data["rmsDbPerSecond"]?.arrayValue?.count == 2)
    #expect(FileManager.default.fileExists(atPath: out))

    // The first half second is silent, so the loudness curve starts below the second value.
    let entries = bounce.data["rmsDbPerSecond"]?.arrayValue ?? []
    let curve: [Double] = entries.compactMap { $0.doubleValue }
    #expect(curve.count == 2 && curve[0] < curve[1])
}

@Test func theSameFileImportedTwiceIsOneAsset() async throws {
    var studio = try await Studio.make()
    let file = try tone(seconds: 1)
    let first = try await studio.client.call("asset_import", ["path": .string(file)])
    let second = try await studio.client.call("asset_import", ["path": .string(file)])
    #expect(first.data["asset"]?.stringValue == second.data["asset"]?.stringValue)
    #expect(first.data["alreadyInProject"]?.boolValue == false && second.data["alreadyInProject"]?.boolValue == true)
    #expect(try await studio.client.call("project_info").data["assets"]?.intValue == 1)
}

@Test func longSamplesPlayOnceAndTheRuleCanBeOverridden() async throws {
    var studio = try await Studio.make()
    let long = try await studio.client.call("asset_import", ["path": .string(try tone(seconds: 25))])
    #expect(long.data["wouldLoop"]?.boolValue == false, "25 s is above the 20 s limit")
    let asset = try #require(long.data["asset"]?.stringValue)
    let once = try await studio.client.call("sample_drop", ["track": .string(studio.track), "asset": .string(asset)])
    #expect(once.data["loop"]?.boolValue == false)
    let forced = try await studio.client.call("sample_drop", ["track": .string(studio.track), "asset": .string(asset),
                                                             "startTick": .number(100_000), "loop": .bool(true)])
    #expect(forced.data["loop"]?.boolValue == true)
    // 25 s at 120 BPM is 50 beats = 48000 ticks.
    #expect(once.data["lengthTicks"]?.intValue == 48_000)
}

@Test func samplesCanGoIntoSessionSlots() async throws {
    var studio = try await Studio.make()
    let asset = try #require(try await studio.client.call("asset_import", ["path": .string(try tone(seconds: 1))]).data["asset"]?.stringValue)
    let r = try await studio.client.call("sample_drop", ["track": .string(studio.track), "asset": .string(asset), "slot": .number(2)])
    #expect(!r.isError, Comment(rawValue: r.text))
    let track = try await studio.client.call("track_get", ["id": .string(studio.track)])
    let slots = try #require(track.data["slots"]?.arrayValue)
    #expect(slots.count == 3 && slots[0] == .null && slots[2] != .null)
    #expect(slots[2]["clip"]?["fadeInMs"]?.doubleValue == 2)
}

@Test func badImportsAndDropsAreErrorsWithReasons() async throws {
    var studio = try await Studio.make()
    #expect(try await studio.client.call("asset_import", ["path": .string("/nonexistent/x.wav")]).isError)
    #expect(try await studio.client.call("asset_import", ["path": .string("relative.wav")]).isError)
    let notAudio = FileManager.default.temporaryDirectory.appendingPathComponent("a-\(UUID().uuidString).wav")
    try Data("nope".utf8).write(to: notAudio)
    #expect(try await studio.client.call("asset_import", ["path": .string(notAudio.path)]).isError)
    #expect(try await studio.client.call("sample_drop", ["track": .string(studio.track), "asset": .string(UUID().uuidString)]).isError)
    #expect(try await studio.client.call("sample_drop", ["track": .string("nope"), "asset": .string(UUID().uuidString)]).isError)
}

@Test func bounceGuardsItsOutput() async throws {
    var studio = try await Studio.make()
    let out = wavPath()
    #expect(try await studio.client.call("render_bounce", ["path": .string(out)]).isError, "nothing to render yet")
    let asset = try #require(try await studio.client.call("asset_import", ["path": .string(try tone(seconds: 1))]).data["asset"]?.stringValue)
    _ = try await studio.client.call("sample_drop", ["track": .string(studio.track), "asset": .string(asset)])

    #expect(try await studio.client.call("render_bounce", ["path": .string("/tmp/x.txt")]).isError, "only .wav")
    #expect(try await studio.client.call("render_bounce", ["path": .string("out.wav")]).isError, "only absolute paths")
    #expect(!(try await studio.client.call("render_bounce", ["path": .string(out)])).isError)
    let again = try await studio.client.call("render_bounce", ["path": .string(out)])
    #expect(again.isError && again.text.contains("overwrite"))
    #expect(!(try await studio.client.call("render_bounce", ["path": .string(out), "overwrite": .bool(true)])).isError)
}

@Test func bounceRangeAndTail() async throws {
    var studio = try await Studio.make()
    let asset = try #require(try await studio.client.call("asset_import", ["path": .string(try tone(seconds: 2))]).data["asset"]?.stringValue)
    _ = try await studio.client.call("sample_drop", ["track": .string(studio.track), "asset": .string(asset), "lengthTicks": .number(3840)])
    let partial = try await studio.client.call("render_bounce", ["path": .string(wavPath()), "startTick": .number(960), "endTick": .number(1920)])
    #expect(partial.data["seconds"]?.doubleValue == 0.5)
    let tail = try await studio.client.call("render_bounce", ["path": .string(wavPath()), "tailSeconds": .number(1.5)])
    #expect(tail.data["seconds"]?.doubleValue == 3.5, "2 s of clip (3840 ticks) plus 1.5 s tail")
}

@Test func sessionPersistsAssetsAcrossReopen() async throws {
    var studio = try await Studio.make()
    let path = try #require(try await studio.client.call("project_info").data["path"]?.stringValue)
    let asset = try #require(try await studio.client.call("asset_import", ["path": .string(try tone(seconds: 1))]).data["asset"]?.stringValue)
    _ = try await studio.client.call("sample_drop", ["track": .string(studio.track), "asset": .string(asset)])
    _ = try await studio.client.call("project_save")

    var other = ClientHelper()
    _ = try await other.call("project_open", ["path": .string(path)])
    let bounce = try await other.call("render_bounce", ["path": .string(wavPath())])
    #expect(!bounce.isError, Comment(rawValue: bounce.text))
    #expect(bounce.data["peakDb"]?.doubleValue ?? -200 > -7, "the audio file came back from the package")
    #expect(bounce.data["warnings"]?.arrayValue?.isEmpty == true)
}

@Test func bounceIncludesSavedSessionLaunches() async throws {
    var studio = try await Studio.make()
    let imported = try await studio.client.call("asset_import", ["path": .string(try tone(seconds: 1))])
    let asset = try #require(imported.data["asset"]?.stringValue)
    let track = TrackID(UUID(uuidString: studio.track)!)
    // A one-shot session clip of one bar (2 s at 120 BPM), launched at bar 2, and no arrangement clip.
    let clip = AudioClip(asset: AssetID(UUID(uuidString: asset)!), start: 0, length: 3840, loop: false, fadeInMs: 2, fadeOutMs: 2)
    for command in [Command.setSlot(track: track, index: 0, slot: SessionSlot(clip: .audio(clip))),
                    Command.setLaunches(launches: [Launch(track: track, slot: 0, tick: 3840)])] {
        let applied = try await studio.client.call("command_apply", ["command": try JSONValue(encoding: command)])
        #expect(!applied.isError, Comment(rawValue: applied.text))
    }
    let bounce = try await studio.client.call("render_bounce", ["path": .string(wavPath())])
    #expect(!bounce.isError, Comment(rawValue: bounce.text))
    #expect(bounce.data["seconds"]?.doubleValue == 4, "the launch at 2 s plays its full bar")
    let values = try #require(bounce.data["rmsDbPerSecond"]?.arrayValue)
    let curve = values.compactMap { $0.doubleValue }
    #expect(curve[0] < -100 && curve[2] > -20, "silent before the launch, the tone after it: \(curve)")
}
