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
      loopstudio tempo <file>... [--loop] [--render BPM]   the tempo, the transients, and (with --render) the time per warp mode
      loopstudio info <project.loopstudio>
      loopstudio units
      loopstudio devices
      loopstudio midi
      loopstudio mcp [--project <project.loopstudio>] [--files | --live]
      loopstudio assistant-check [--model <id>] [<question>]   key from OPENAI_API_KEY or ANTHROPIC_API_KEY
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
case "assistant-check":
    // One turn against the real provider, with the same engine and tools as the app, on an empty project.
    // Shows what the app would show: text, tool calls, notices, and the stop reason.
    let model: String = {
        if let i = args.firstIndex(of: "--model"), i + 1 < args.count { return args[i + 1] }
        return ModelProvider.openai.defaultModel
    }()
    let provider = ModelProvider.of(model: model)
    let env = ProcessInfo.processInfo.environment
    guard let key = env[provider == .openai ? "OPENAI_API_KEY" : "ANTHROPIC_API_KEY"], !key.isEmpty else {
        FileHandle.standardError.write(Data("set \(provider == .openai ? "OPENAI_API_KEY" : "ANTHROPIC_API_KEY") for model \(model)\n".utf8))
        exit(1)
    }
    let question = args.dropFirst().filter { !$0.hasPrefix("--") && $0 != model }.joined(separator: " ")
    let text = question.isEmpty ? "How many tracks does the project have? Answer in one sentence." : question
    let trace = env["LOOPSTUDIO_TRACE"] != nil
    func note(_ s: String) { if trace { FileHandle.standardError.write(Data("[trace] \(s)\n".utf8)) } }
    note("tools")
    let registry = StandardTools.registry(session: ProjectSession())
    note("\(registry.tools.count) tools, engine")
    let engine = AssistantEngine(transport: provider.transport(apiKey: key), registry: registry, config: AssistantConfig(model: model))
    print("\(provider.name) \(model): \"\(text)\"")
    fflush(stdout)
    note("run")
    await engine.run(user: text) { event in
        switch event {
        case .text(let t): print(t, terminator: ""); fflush(stdout)
        case .progress(let t): FileHandle.standardError.write(Data(t.utf8))
        case .toolCall(_, let name, let input): print("\n[tool \(name) \(input.text)]")
        case .toolResult(_, let name, let result, let isError, _): print("[\(name) \(isError ? "error" : "ok"): \(result.text.prefix(200))]")
        case .toolSkipped(_, let name): print("[\(name) skipped]")
        case .notice(let n): print("\n[notice] \(n)")
        case .usage(let u, _): print("\n[usage] in \(u.input) cached \(u.cacheRead) out \(u.output)")
        case .finished(let reason): print("\n[finished: \(reason)]")
        }
    }
case "tempo":
    // The detection a drop runs, on files outside a project. --render stretches each file to a tempo in
    // every warp mode and prints how long each took.
    let files = args.dropFirst().filter { !$0.hasPrefix("--") && Double($0) == nil }
    let target = option("--render")
    for path in files {
        let url = URL(fileURLWithPath: path)
        do {
            let pcm = try AudioBank.decode(url, targetRate: 48_000)
            let seconds = Double(pcm.frames) / pcm.sampleRate
            let loop = args.contains("--loop") || AutoLoopRule().shouldLoop(seconds: seconds)
            let name = url.deletingPathExtension().lastPathComponent
            let started = Date()
            let estimate = TempoDetect.estimate(pcm, name: name, loop: loop)
            let heard = TempoDetect.onsetTempo(pcm)
            let transients = pcm.transients
            let took = Date().timeIntervalSince(started)
            let tempo = estimate.map { String(format: "%.3f BPM (%@, confidence %.2f)", $0.bpm, $0.method.rawValue, $0.confidence) } ?? "no tempo"
            let onsets = heard.map { String(format: "onsets say %.3f BPM, confidence %.2f", $0.bpm, $0.confidence) } ?? "no onset tempo"
            print("\(url.lastPathComponent): \(String(format: "%.1f", seconds)) s, \(loop ? "loop" : "long"): \(tempo); \(onsets); \(transients.count) transients; \(String(format: "%.2f", took)) s")
            if let target, let bpm = estimate?.bpm,
               let m = WarpMapping.make(sourceFrames: pcm.frames, sourceTempo: bpm, markers: [], assetRate: pcm.sampleRate,
                                        tempoMap: TempoMap(bpm: target), startTick: 0, sampleRate: pcm.sampleRate) {
                for mode in WarpMode.stretching {
                    let t0 = Date()
                    let out = TimeStretch.render(pcm, mode: mode, settings: WarpSettings(), mapping: m)
                    let t = Date().timeIntervalSince(t0)
                    print("  " + mode.title.padding(toLength: 12, withPad: " ", startingAt: 0) + String(format: "%6.2f s for %.1f s of audio (%.0fx real time)", t,
                                 Double(out.frames) / out.sampleRate, Double(out.frames) / out.sampleRate / max(t, 1e-6)))
                }
            }
        } catch {
            print("\(path): \(error.localizedDescription)")
        }
    }
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
