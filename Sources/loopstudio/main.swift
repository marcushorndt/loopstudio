import Foundation
import LoopStudioControl
import LoopStudioCore
import LoopStudioEngine
import LoopStudioProject

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    usage:
      loopstudio play <file> --source-bpm N [--bpm N] [--seconds N]
      loopstudio info <project.loopstudio>
      loopstudio units
      loopstudio devices
      loopstudio midi
      loopstudio mcp [--project <project.loopstudio>] [--files | --live]
    """)
    exit(2)
}

func option(_ name: String) -> Double? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return Double(args[i + 1])
}

switch args.first {
case "units":
    for u in AudioUnitCatalog.list() { print("\(u.kind)\t\(u.manufacturer)\t\(u.name)") }
case "devices":
    let defaultOut = AudioDeviceCatalog.defaultOutputUID(), defaultIn = AudioDeviceCatalog.defaultInputUID()
    for d in AudioDeviceCatalog.devices() {
        var tags: [String] = []
        if d.uid == defaultOut { tags.append("default out") }
        if d.uid == defaultIn { tags.append("default in") }
        print("\(d.name) [\(d.transport)] \(tags.joined(separator: ", "))")
        print("  uid: \(d.uid)")
        print("  \(d.inputs.count) in, \(d.outputs.count) out, rates \(d.sampleRates.map { Int($0) }), buffer \(d.bufferMin)-\(d.bufferMax), latency in/out \(d.inputLatencyFrames)/\(d.outputLatencyFrames) frames")
        for c in d.outputs.prefix(8) { print("  out \(c.index + 1): \(c.name)") }
    }
case "midi":
    for (title, list) in [("sources", MIDIEndpointCatalog.sources()), ("destinations", MIDIEndpointCatalog.destinations())] {
        print("MIDI \(title): \(list.isEmpty ? "none" : "")")
        for e in list { print("  \(e.uniqueID)\t\(e.name)\(e.isOffline ? " (offline)" : "")\t\(e.manufacturer) \(e.model)") }
    }
case "mcp":
    // MCP server on stdin and stdout. Logs go to stderr only.
    // With the app running, its socket takes the messages: the agent then edits the project on screen.
    // --files works on project files on its own; --live insists on the app.
    let wantFiles = args.contains("--files"), wantLive = args.contains("--live")
    if !wantFiles, let client = SocketClient() {
        FileHandle.standardError.write(Data("forwarding to the running LoopStudio app at \(SocketTransport.defaultPath)\n".utf8))
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let response = client.send(line) { print(response); fflush(stdout) }
            else if SocketClient.isRequest(line) { FileHandle.standardError.write(Data("the app closed the connection\n".utf8)); exit(1) }
        }
        exit(0)
    }
    if wantLive {
        FileHandle.standardError.write(Data("LoopStudio is not running: nothing listens at \(SocketTransport.defaultPath)\n".utf8))
        exit(1)
    }
    let session = ProjectSession()
    if let i = args.firstIndex(of: "--project"), i + 1 < args.count {
        do { try await session.open(at: URL(fileURLWithPath: args[i + 1])) }
        catch { FileHandle.standardError.write(Data("cannot open project: \(error)\n".utf8)); exit(1) }
    }
    await LoopStudioServer.make(session: session).serveStandardIO()
case "info":
    guard args.count > 1 else { usage() }
    do {
        let loaded = try ProjectPackage.read(from: URL(fileURLWithPath: args[1]))
        let p = loaded.project
        print("\(p.name): \(p.tracks.count) tracks, \(p.assets.count) assets, \(p.sampleRate) Hz")
        if let from = loaded.migratedFrom { print("migrated from schema \(from)") }
        for issue in loaded.issues { print("issue: \(issue)") }
    } catch {
        print("error: \(error)")
        exit(1)
    }
case "play":
    guard args.count > 1, let source = option("--source-bpm") else { usage() }
    let engine = try LoopEngine()
    try engine.load(url: URL(fileURLWithPath: args[1]), sourceTempo: source)
    engine.projectTempo = option("--bpm") ?? source
    try engine.start()
    try await Task.sleep(for: .seconds(option("--seconds") ?? 8))
    engine.stop()
default:
    usage()
}
