import Foundation
import LoopStudioCore
import LoopStudioEngine
import LoopStudioProject

/// The note analyses made already, per file and sample rate: a second call on the same file is quick.
private final class NoteAnalysisCache: @unchecked Sendable {
    static let shared = NoteAnalysisCache()
    private let lock = NSLock()
    private var items: [String: NoteAnalysis] = [:]
    func get(_ key: String) -> NoteAnalysis? { lock.lock(); defer { lock.unlock() }; return items[key] }
    func set(_ key: String, _ value: NoteAnalysis) { lock.lock(); items[key] = value; lock.unlock() }
}

/// Note editing in audio for an agent: the same analysis and render as the clip's Notes page.
public extension StandardTools {
    static let noteToolsNote = """
    Notes in audio (after Melodyne): audio_notes lists the notes found in an audio clip's file, also the notes of a chord, \
    each with a key. audio_notes_edit changes notes by key (pitch in semitones, shift in seconds, stretch, gainDb, muted); \
    it renders a new file from the original and switches the clip to it in one undo step.
    """

    static func noteTools(session: any EditSession) -> [Tool] {
        func bool(_ description: String) -> JSONValue { .object(["type": .string("boolean"), "description": .string(description)]) }
        let clipArg = Schema.string("The audio clip: id, name or \"<track>/slot N\"")

        struct Loaded {
            var project: Project
            var clip: AudioClip
            var source: Asset
            var pcm: PCMBuffer
            var analysis: NoteAnalysis
            var package: URL
        }

        @Sendable func load(_ args: ToolArguments) async throws -> Loaded {
            guard let package = await session.packageURL else { throw ToolFailure("no project is open; call project_new or project_open first") }
            let project = try await session.project()
            let (_, clip) = try Resolve.clip(try args.string("clip"), in: project)
            guard case .audio(let a) = clip else { throw ToolFailure("the clip is no audio clip; MIDI notes are edited with notes_set") }
            let sourceID = a.noteEdit?.source ?? a.asset
            guard let source = project.asset(sourceID), let file = AssetStore.fileURL(for: source, in: package) else {
                throw ToolFailure("the clip's file is missing from the project")
            }
            let pcm: PCMBuffer
            do { pcm = try AudioBank.decode(file, targetRate: project.sampleRate) } catch { throw ToolFailure("cannot read the clip's file: \(error)") }
            let key = "\(source.sha256)@\(project.sampleRate)"
            let analysis: NoteAnalysis
            if let cached = NoteAnalysisCache.shared.get(key) { analysis = cached } else {
                analysis = NoteAnalysis.analyze(pcm)
                NoteAnalysisCache.shared.set(key, analysis)
            }
            return Loaded(project: project, clip: a, source: source, pcm: pcm, analysis: analysis, package: package)
        }

        @Sendable func describe(_ n: DetectedNote, _ analysis: NoteAnalysis, _ change: NoteChange?) -> JSONValue {
            let now = n.pitch + (change?.pitch ?? 0)
            let loud = n.level.max() ?? 0
            var o: [String: JSONValue] = [
                "key": .string(n.key),
                "note": .string(BuiltInEffects.noteNames.indices.contains(Int(now.rounded())) ? BuiltInEffects.noteNames[Int(now.rounded())] : "?"),
                "pitch": .number((n.pitch * 100).rounded() / 100),
                "start": .number((analysis.seconds(frame: Double(n.startFrame)) * 1000).rounded() / 1000),
                "end": .number((analysis.seconds(frame: Double(n.endFrame)) * 1000).rounded() / 1000),
                "peakDb": .number((20 * log10(Double(max(loud, 1e-6))) * 10).rounded() / 10),
            ]
            if let c = change {
                o["change"] = .object(["pitch": .number(c.pitch), "shift": .number(c.shift), "stretch": .number(c.stretch),
                                       "gainDb": .number(c.gainDb), "muted": .bool(c.muted)])
            }
            return .object(o)
        }

        var tools: [Tool] = []

        tools.append(Tool(
            name: "audio_notes", title: "List the notes in an audio clip",
            description: """
            Find the notes in an audio clip's file, the way the clip's Notes page shows them: also the notes of a chord, each one on its own. \
            Each note has a key (use it in audio_notes_edit), its name and pitch (MIDI number with cents), its start and end in seconds of \
            the file, its peak level and its change, when it has one. Drums, noise and speech give few or no notes. The first call on a \
            long file takes a few seconds (about 10 s for 2 minutes of a full mix).
            """,
            inputSchema: Schema.object([
                "clip": clipArg,
                "from": Schema.number("Only notes that sound after this time, in seconds of the file."),
                "to": Schema.number("Only notes that start before this time, in seconds of the file."),
            ], required: ["clip"]),
            annotations: ToolAnnotations(readOnly: true, idempotent: true)
        ) { args in
            let l = try await load(args)
            let edit = l.clip.noteEdit ?? NoteEdit(source: l.source.id)
            let from = args.optionalDouble("from") ?? -.infinity, to = args.optionalDouble("to") ?? .infinity
            let notes = l.analysis.notes.filter {
                l.analysis.seconds(frame: Double($0.endFrame)) >= from && l.analysis.seconds(frame: Double($0.startFrame)) <= to
            }
            let shown = notes.prefix(400)
            return .object([
                "clip": .string(l.clip.id.description),
                "file": .string(l.source.name),
                "keepFormants": .bool(edit.keepFormants),
                "count": .number(Double(notes.count)),
                "changed": .number(Double(edit.changes.count)),
                "notes": .array(shown.map { describe($0, l.analysis, edit.change($0.key)) }),
                "truncated": .bool(notes.count > shown.count),
            ])
        })

        tools.append(Tool(
            name: "audio_notes_edit", title: "Change notes in an audio clip",
            description: """
            Change notes of an audio clip by their keys from audio_notes. A change gives the note's state against the recording: pitch \
            (semitones up or down; a fraction is cents), shift (seconds later, negative earlier), stretch (length factor, 2 is twice as \
            long), gainDb, muted. Fields left out keep the note's current change. 'tune' puts notes on the nearest semitone ("all", or a \
            list of keys). 'reset' clears every change first. A note that keeps its pitch and time keeps every detail of the recording; \
            a moved note is built again from its partials. The tool renders a new file from the original and switches the clip to it \
            in one undo step; without any change left the clip plays its original again.
            """,
            inputSchema: Schema.object([
                "clip": clipArg,
                "changes": .object(["type": .string("array"), "description": .string("Note changes: {key, pitch?, shift?, stretch?, gainDb?, muted?}."),
                                    "items": .object(["type": .string("object")])]),
                "tune": .object(["description": .string("\"all\", or an array of note keys, to put on the nearest semitone.")]),
                "keepFormants": bool("A moved note keeps the tone colour of its old pitch. Default: as before (true for a new edit)."),
                "reset": bool("Clear every change before the new ones."),
            ], required: ["clip"]),
            annotations: ToolAnnotations(destructive: false)
        ) { args in
            let l = try await load(args)
            var edit = l.clip.noteEdit ?? NoteEdit(source: l.source.id)
            if args.raw["reset"]?.boolValue == true { edit.changes = [] }
            if let keep = args.raw["keepFormants"]?.boolValue { edit.keepFormants = keep }
            let byKey = Dictionary(l.analysis.notes.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            for item in args.raw["changes"]?.arrayValue ?? [] {
                guard let o = item.objectValue, let key = o["key"]?.stringValue else { throw ToolFailure("each change needs a 'key' from audio_notes") }
                guard byKey[key] != nil else { throw ToolFailure("no note with key '\(key)'; audio_notes lists the keys") }
                var c = edit.change(key) ?? NoteChange(key: key)
                if let v = o["pitch"]?.doubleValue { guard abs(v) <= 48 else { throw ToolFailure("pitch must be within ±48 semitones") }; c.pitch = v }
                if let v = o["shift"]?.doubleValue { c.shift = v }
                if let v = o["stretch"]?.doubleValue { guard v >= 0.1, v <= 10 else { throw ToolFailure("stretch must be from 0.1 to 10") }; c.stretch = v }
                if let v = o["gainDb"]?.doubleValue { c.gainDb = min(24, max(-60, v)) }
                if let v = o["muted"]?.boolValue { c.muted = v }
                edit = edit.with(c)
            }
            var tuneKeys: [String] = []
            if args.raw["tune"]?.stringValue == "all" { tuneKeys = l.analysis.notes.map(\.key) }
            else if let list = args.raw["tune"]?.arrayValue { tuneKeys = list.compactMap(\.stringValue) }
            for key in tuneKeys {
                guard let n = byKey[key] else { throw ToolFailure("no note with key '\(key)'") }
                var c = edit.change(key) ?? NoteChange(key: key)
                let to = (n.pitch + c.pitch).rounded() - n.pitch
                c.pitch = abs(to) < 0.005 ? 0 : to
                edit = edit.with(c)
            }

            var clip = l.clip
            if edit.changes.isEmpty {
                guard clip.noteEdit != nil else { return .object(["clip": .string(clip.id.description), "changed": .number(0), "asset": .string(clip.asset.description)]) }
                clip.asset = l.source.id
                clip.noteEdit = nil
                try await session.apply(.setClip(clip: .audio(clip)))
                return .object(["clip": .string(clip.id.description), "changed": .number(0), "asset": .string(clip.asset.description),
                                "note": .string("the clip plays its original again")])
            }
            guard let out = l.analysis.render(l.pcm, edit: edit) else { throw ToolFailure("nothing to render") }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LoopStudio Notes", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("\(l.source.name) notes \(UUID().uuidString.prefix(8)).caf")
            defer { try? FileManager.default.removeItem(at: url) }
            do { try out.write(to: url) } catch { throw ToolFailure("cannot write the render: \(error)") }
            var asset: Asset
            do { asset = try AssetStore.importFile(url, into: l.package) } catch { throw ToolFailure("cannot import the render: \(error)") }
            var commands: [Command] = []
            if let existing = l.project.assets.first(where: { $0.sha256 == asset.sha256 }) {
                asset = existing
            } else {
                asset.name = "\(l.source.name) (notes)"
                // The tempo of the file the clip plays now, so the clip keeps its speed.
                let tempo = l.project.asset(clip.asset) ?? l.source
                asset.sourceTempo = tempo.sourceTempo
                asset.detectedTempo = tempo.detectedTempo
                commands.append(.addAsset(asset: asset))
            }
            clip.asset = asset.id
            clip.noteEdit = edit
            commands.append(.setClip(clip: .audio(clip)))
            try await session.apply(commands.count == 1 ? commands[0] : .batch(commands: commands))
            var peak: Float = 0
            for c in 0..<out.channels { let ch = out.channel(c); for i in 0..<out.frames { peak = max(peak, abs(ch[i])) } }
            return .object([
                "clip": .string(clip.id.description),
                "asset": .string(asset.id.description),
                "changed": .number(Double(edit.changes.count)),
                "keepFormants": .bool(edit.keepFormants),
                "peakDb": .number((20 * log10(Double(max(peak, 1e-6))) * 10).rounded() / 10),
                "changes": .array(edit.changes.compactMap { c in byKey[c.key].map { describe($0, l.analysis, c) } }),
            ])
        })
        return tools
    }
}
