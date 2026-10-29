import AppKit
import Foundation
import LoopStudioCore
import LoopStudioEngine

/// What Export Audio renders.
struct ExportOptions: Equatable {
    enum Range: String, CaseIterable { case whole, loop, selection }
    var range: Range = .whole
    /// Off: one file with the master mix. On: one file per track, the returns and the master, in a folder.
    var stems = false
    /// Seconds after the end, for reverb and delay tails.
    var tailSeconds = 2.0
}

extension AppModel {
    /// Renders the arrangement and the saved Session launches, with hosted plugins, to 24-bit WAV files.
    /// The master mix goes to one file; stems go to a folder, one file per track, return and master.
    /// The render runs off the main thread.
    func runExport(_ options: ExportOptions) {
        guard !exporting else { status = "An export is running"; return }
        exportOptions = options
        // Where to.
        let name = project.name.isEmpty ? "LoopStudio" : project.name
        let target: URL
        if options.stems {
            let panel = NSOpenPanel()
            panel.title = "Export Stems"
            panel.message = "Choose the folder for the stems. One WAV per track, return and master."
            panel.prompt = "Export Here"
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            target = url
        } else {
            let panel = NSSavePanel()
            panel.title = "Export Audio"
            panel.nameFieldStringValue = "\(name).wav"
            panel.allowedContentTypes = [.wav]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            target = url
        }
        // The range, in frames of the timeline. `nil` end: the end of the last clip or launch.
        let startFrame: Int64
        let endTick: Tick?
        switch options.range {
        case .whole:
            startFrame = 0; endTick = nil
        case .loop:
            guard let loop = project.loop, loop.end > loop.start else { status = "No loop to export"; return }
            startFrame = project.tempoMap.frame(at: loop.start, sampleRate: project.sampleRate).rawValue
            endTick = loop.end
        case .selection:
            guard let r = rangeSelection, r.end > r.start else { status = "No selection to export"; return }
            startFrame = project.tempoMap.frame(at: r.start, sampleRate: project.sampleRate).rawValue
            endTick = r.end
        }
        let tail = Int64((max(0, options.tailSeconds) * project.sampleRate).rounded())
        let endFixed = endTick.map { project.tempoMap.frame(at: $0, sampleRate: project.sampleRate).rawValue + tail }

        captureStatesForExport()
        exporting = true
        status = "Exporting \(target.lastPathComponent)…"
        // Like Live, an export renders the arrangement. An empty arrangement renders what was played in the
        // Session instead, so a jam does not export as silence. Capture puts a jam into the arrangement.
        var snapshot = project
        let arrangementEmpty = !project.tracks.contains { !$0.clips.isEmpty }
        let jam = arrangementEmpty && !session.isEmpty
        if jam { snapshot.launches = session.launches }
        let skipped = !arrangementEmpty && !session.isEmpty
        let bank = self.bank
        // The stems, in the order of the mixer, then the master.
        let stemTracks: [TrackID?] = snapshot.tracks.map { Optional($0.id) } + [nil]
        let stemNames = snapshot.tracks.map(\.name) + ["Master"]
        Task { [weak self] in
            // Own plugin instances: the live ones belong to the audio thread.
            let prepared = await OfflineRender.prepare(snapshot, bank: bank)
            guard prepared.endFrame > 0 || endFixed != nil else {
                self?.exporting = false
                self?.status = "Nothing to export: the arrangement and the Session launches are empty"
                return
            }
            let note = prepared.warnings.isEmpty ? "" : " (\(prepared.warnings.count) warning\(prepared.warnings.count == 1 ? "" : "s"): \(prepared.warnings[0]))"
            nonisolated(unsafe) let job = prepared
            let end = endFixed ?? (prepared.endFrame + tail)
            let result: Result<(Double, [String]), Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    if options.stems {
                        let stems = withExtendedLifetime(job.host) { Bounce.renderStems(job.plan, tracks: stemTracks, startFrame: startFrame, endFrame: end) }
                        var written: [String] = []
                        var used: Set<String> = []
                        for (k, audio) in stems.enumerated() {
                            var base = Self.fileSafe(stemNames[k])
                            if base.isEmpty { base = "Track \(k + 1)" }
                            var file = "\(name) - \(base)"
                            var n = 2
                            while used.contains(file.lowercased()) { file = "\(name) - \(base) \(n)"; n += 1 }
                            used.insert(file.lowercased())
                            try Bounce.writeWAV(audio, to: target.appendingPathComponent("\(file).wav"))
                            written.append(file)
                        }
                        return (Double(stems.first?.frames ?? 0) / job.plan.sampleRate, written)
                    } else {
                        let audio = withExtendedLifetime(job.host) { Bounce.render(job.plan, startFrame: startFrame, endFrame: end) }
                        try Bounce.writeWAV(audio, to: target)
                        return (Double(audio.frames) / audio.sampleRate, [target.lastPathComponent])
                    }
                }
            }.value
            guard let self else { return }
            self.exporting = false
            switch result {
            case .success(let (seconds, files)):
                let what = options.stems ? "\(files.count) stems to \(target.lastPathComponent)" : target.lastPathComponent
                self.status = "Exported \(what), \(Int(seconds.rounded())) s\(note)"
                if jam { self.status += ". It holds the Session performance, because the arrangement is empty" }
                if skipped { self.status += ". The Session performance is not in it: Capture (⇧⌘C) puts it into the arrangement" }
            case .failure(let error): self.status = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    /// A track name as a file name: no slashes or colons, trimmed.
    nonisolated static func fileSafe(_ name: String) -> String {
        String(name.map { ($0 == "/" || $0 == ":" || $0 == "\\") ? "-" : $0 }).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
