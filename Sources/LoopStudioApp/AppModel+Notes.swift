import Foundation
import LoopStudioCore
import LoopStudioEngine

/// Note editing in audio, after Melodyne's polyphonic mode: the analysis finds the notes of a file (also the
/// notes of a chord), and each one can move, stretch, change its level or go silent. An edit renders the
/// original with all its changes into a new file of the project, and the clip switches to that file in one
/// undo step. The clip keeps the original and the list of changes (`AudioClip.noteEdit`), so the next edit
/// starts from the original again, and an undo gives the clip before.
extension AppModel {
    /// Opens the clip's Notes page in the clip panel: "Edit Notes" in the clip menu.
    func openNotes(_ id: ClipID) {
        guard let (trackID, clip) = project.findClip(id), case .audio(let a) = clip else { return }
        selectedClip = id
        selectedTrack = trackID
        detailTab = .clip
        detailOpen = true
        clipPage = .notes
        analyzeNotes(a)
    }

    /// The file whose notes a clip edits: its original.
    func noteSource(_ a: AudioClip) -> AssetID { a.noteEdit?.source ?? a.asset }

    /// The clip's edit as the Notes page shows it: a render that is still running first.
    func noteEdit(_ a: AudioClip) -> NoteEdit {
        pendingNoteEdits[a.id] ?? a.noteEdit ?? NoteEdit(source: a.asset)
    }

    /// Finds the notes of the clip's original, once per file, on a worker.
    func analyzeNotes(_ a: AudioClip) {
        let id = noteSource(a)
        guard noteAnalyses[id] == nil, !notesInProgress.contains(id), let pcm = bank.buffer(for: id) else { return }
        notesInProgress.insert(id)
        let name = project.asset(id)?.name ?? "the file"
        let file = project.asset(id).map { noteFile(sha256: $0.sha256) }
        status = "Finding the notes in \(name)…"
        Task {
            let (analysis, stored) = await Task.detached(priority: .userInitiated) { () -> (NoteAnalysis, Bool) in
                // The notes found earlier, in the package: no new search.
                if let file, let data = try? Data(contentsOf: file), let known = NoteAnalysis.read(data), known.sampleRate == pcm.sampleRate {
                    return (known, true)
                }
                let found = NoteAnalysis.analyze(pcm)
                if let file {
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? found.fileData().write(to: file, options: .atomic)
                }
                return (found, false)
            }.value
            notesInProgress.remove(id)
            noteAnalyses[id] = analysis
            if !stored { status = "\(name): \(analysis.notes.count) note\(analysis.notes.count == 1 ? "" : "s") found" }
        }
    }

    /// Where the package keeps the notes found in a file: `analysis/<hash>.notes`, beside `audio/`. The audio
    /// folder itself would not do: an asset is found there by the prefix of its hash.
    func noteFile(sha256: String) -> URL {
        packageURL.appendingPathComponent("analysis", isDirectory: true).appendingPathComponent("\(sha256).notes")
    }

    /// Puts one note's change into the clip's edit and renders it.
    func changeNote(_ a: AudioClip, _ change: NoteChange) {
        applyNoteEdit(a.id, noteEdit(a).with(change))
    }

    /// Puts several notes' changes into the clip's edit and renders once.
    func changeNotes(_ a: AudioClip, _ changes: [NoteChange]) {
        guard !changes.isEmpty else { return }
        applyNoteEdit(a.id, changes.reduce(noteEdit(a)) { $0.with($1) })
    }

    /// Delete on the Notes page: the marked notes go silent; when all of them are silent, they sound again.
    func toggleNoteMute(_ a: AudioClip, keys: Set<String>) {
        let edit = noteEdit(a)
        let mute = keys.contains { !(edit.change($0)?.muted ?? false) }
        changeNotes(a, keys.sorted().map { key in
            var c = edit.change(key) ?? NoteChange(key: key)
            c.muted = mute
            return c
        })
    }

    /// Marks notes on the Notes page; `primary` is the one the strip edits.
    func markAudioNotes(_ keys: Set<String>, primary: String?) {
        selectedAudioNotes = keys
        selectedAudioNote = primary.flatMap { keys.contains($0) ? $0 : nil } ?? (keys.count == 1 ? keys.first : nil)
    }

    /// Renders the original with `edit` into a new file and switches the clip to it, in one undo step. An edit
    /// without changes switches the clip back to its original.
    func applyNoteEdit(_ clipID: ClipID, _ edit: NoteEdit) {
        guard case .audio(var a)? = project.findClip(clipID)?.clip else { return }
        let render = (noteRenders[clipID] ?? 0) + 1
        noteRenders[clipID] = render
        if edit.changes.isEmpty {
            pendingNoteEdits[clipID] = nil
            guard a.noteEdit != nil else { return }
            a.asset = edit.source
            a.noteEdit = nil
            apply(.setClip(clip: .audio(a)))
            status = "The clip plays its original again"
            return
        }
        guard let analysis = noteAnalyses[edit.source], let pcm = bank.buffer(for: edit.source),
              let source = project.asset(edit.source) else { return }
        pendingNoteEdits[clipID] = edit
        status = "Rendering the notes…"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoopStudio Notes", isDirectory: true)
            .appendingPathComponent("\(source.name) notes \(UUID().uuidString.prefix(8)).caf")
        Task {
            let written = await Task.detached(priority: .userInitiated) { () -> Bool in
                guard let out = analysis.render(pcm, edit: edit) else { return false }
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try out.write(to: url)
                    return true
                } catch { return false }
            }.value
            // A newer edit of the same clip replaces this one.
            guard noteRenders[clipID] == render else { try? FileManager.default.removeItem(at: url); return }
            guard written else { pendingNoteEdits[clipID] = nil; status = "Cannot render the notes"; return }
            let asset = await importAudio(url, name: "\(source.name) (notes)")
            try? FileManager.default.removeItem(at: url)
            guard noteRenders[clipID] == render else { return }
            pendingNoteEdits[clipID] = nil
            guard let asset, case .audio(var now)? = project.findClip(clipID)?.clip else { return }
            now.noteEdit = edit
            // The new file keeps the tempo of the file the clip plays now (set in the warp panel, perhaps), so
            // the clip plays at the same speed.
            let tempo = project.asset(now.asset) ?? source
            now.asset = asset.id
            var commands: [Command] = []
            if asset.sourceTempo != tempo.sourceTempo { commands.append(.setAssetTempo(id: asset.id, bpm: tempo.sourceTempo)) }
            if asset.detectedTempo != tempo.detectedTempo { commands.append(.setAssetDetectedTempo(id: asset.id, bpm: tempo.detectedTempo)) }
            commands.append(.setClip(clip: .audio(now)))
            apply(commands.count == 1 ? commands[0] : .batch(commands: commands))
            status = "\(edit.changes.count) note\(edit.changes.count == 1 ? "" : "s") changed"
        }
    }
}
