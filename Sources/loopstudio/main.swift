import Foundation
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
      loopstudio midi
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
case "midi":
    let names = MIDIDevices.inputNames()
    print(names.isEmpty ? "no MIDI inputs" : names.joined(separator: "\n"))
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
    Thread.sleep(forTimeInterval: option("--seconds") ?? 8)
    engine.stop()
default:
    usage()
}
