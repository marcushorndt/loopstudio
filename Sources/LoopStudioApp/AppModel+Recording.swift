import AVFoundation
import Foundation
import LoopStudioCore
import LoopStudioEngine

extension AppModel {
    // MARK: Audio recording

    /// Asks for microphone access once. The answer is remembered by macOS.
    private func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: Input monitoring

    /// Opens the sound card input while a track monitors it, and closes it when none does. `inputs` is what
    /// the plan was built with. `force`: open again even if the set did not change (another input device).
    func updateInputMonitoring(_ inputs: [TrackID: RenderPlan.MonitorInput], force: Bool = false) {
        let changed = inputs != appliedInputs
        appliedInputs = inputs
        guard changed || force else { return }
        if inputs.isEmpty {
            engine.setInputMonitor(nil)
            try? audioRecorder.setMonitoring(false, deviceUID: inputUID)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined where !inputAccessAsked:
            inputAccessAsked = true
            Task { @MainActor in
                if await microphoneAllowed() { updateInputMonitoring(appliedInputs, force: true) }
                else { status = "Monitoring needs microphone access. Turn it on in System Settings > Privacy & Security > Microphone." }
            }
            return
        default:
            status = "Monitoring needs microphone access. Turn it on in System Settings > Privacy & Security > Microphone."
            return
        }
        do {
            try audioRecorder.setMonitoring(true, deviceUID: inputUID, bufferFrames: bufferFrames > 0 ? bufferFrames : nil)
            engine.setInputMonitor(audioRecorder.monitor)
        } catch {
            engine.setInputMonitor(nil)
            status = "Cannot monitor the input: \(error)"
        }
    }

    /// Opens the audio input for the armed audio tracks, then starts the transport. Tracks that take another
    /// track's sound ("Audio From" a track, or the master) record it from the renderer, in the same take.
    func startAudioRecording() async {
        guard !recordAudioTracks.isEmpty else { return }
        // "Audio From" another track: its sound after the fader, with no sound card involved. Tracks with
        // the same source share one file.
        var sources: [TrackID] = [], sourceTracks: [[TrackID]] = []
        for id in recordAudioTracks {
            guard let source = project.track(id)?.inputTrack else { continue }
            if let i = sources.firstIndex(of: source) { sourceTracks[i].append(id) } else { sources.append(source); sourceTracks.append([id]) }
        }
        if !sources.isEmpty {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LoopStudio-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                resamples = try zip(sources, sourceTracks).map { source, tracks in
                    let writer = try CaptureWriter(url: folder.appendingPathComponent("\(UUID().uuidString).caf"), sampleRate: sampleRate, channels: 2)
                    let latency = source == project.master.id ? (plan?.latencyFrames ?? 0) : (plan?.arrival(of: source) ?? 0)
                    return (writer, latency, tracks)
                }
                engine.startCapture(CaptureSet(zip(sources, resamples).map { ($0 == project.master.id ? nil : $0, $1.writer) }))
            } catch {
                resamples = []
                audioStartFailed("Cannot record: \(error.localizedDescription)")
                return
            }
        }
        // Each armed audio track on the sound card records its own input channels. Tracks on the same
        // channels share one file.
        let external = recordAudioTracks.filter { project.track($0)?.inputTrack == nil }
        if external.isEmpty {
            beginRecording(status: "Recording \(sources.map { project.track($0)?.name ?? "?" }.joined(separator: ", "))")
            return
        }
        guard await microphoneAllowed() else {
            audioStartFailed("Microphone access is off. Turn it on in System Settings > Privacy & Security > Microphone.")
            return
        }
        var lanes: [AudioInputRecorder.Lane] = []
        var groups: [[TrackID]] = []
        for id in external {
            let ch = inputChannels(of: id)
            let lane = AudioInputRecorder.Lane(left: ch.first, right: ch.stereo ? ch.first + 1 : nil)
            if let i = lanes.firstIndex(of: lane) { groups[i].append(id) } else { lanes.append(lane); groups.append([id]) }
        }
        recordLaneTracks = groups
        let urls = lanes.map { _ in FileManager.default.temporaryDirectory.appendingPathComponent("LoopStudio-take-\(UUID().uuidString).caf") }
        do {
            try audioRecorder.start(deviceUID: inputUID, lanes: lanes, to: urls, bufferFrames: bufferFrames > 0 ? bufferFrames : nil)
            // The take opened the input: monitoring tracks hear it from now on too.
            if !appliedInputs.isEmpty { engine.setInputMonitor(audioRecorder.monitor) }
        } catch {
            audioStartFailed("Cannot record: \(error)")
            return
        }
        beginRecording(status: "Recording audio")
    }

    /// The sound card channels a track records: its own choice, else the channels of the audio settings.
    func inputChannels(of id: TrackID) -> InputChannels {
        project.track(id)?.inputChannels ?? InputChannels(first: inputLeft, stereo: inputStereo)
    }

    /// The audio input did not open. Resampling tracks and armed MIDI tracks still record; with none, recording ends.
    private func audioStartFailed(_ message: String) {
        recordLaneTracks = []
        if !resamples.isEmpty {
            recordAudioTracks = resamples.flatMap(\.tracks)
            beginRecording(status: message + ". The other tracks record.")
            return
        }
        recordAudioTracks = []
        if recordMIDITracks.isEmpty {
            recording = false
            recordArmed = false
            status = message
            return
        }
        updateMetronome()
        if !recordPunch { engine.playAfterCountIn(beats: countInBars * meter.beats); startClockAfterCountIn() }
        transportPlaying = true
        status = message + ". The MIDI tracks record."
    }

    private func beginRecording(status text: String) {
        // A Session take keeps the start it was given, on the session clock (see `startRecording`).
        if recordSlots.isEmpty { recordStartTick = currentTick; recordFrameOffset = engine.clockOffset } else { recordFrameOffset = 0 }
        recording = true
        recordingAudio = true
        updateMetronome()
        if !recordPunch { engine.playAfterCountIn(beats: countInBars * meter.beats); startClockAfterCountIn() }
        transportPlaying = true
        status = recordStatus(text)
    }

    /// Puts an audio take on every track it was recorded for: the first gets the clip, the others a copy.
    private func placeAudioTake(_ clip: AudioClip, on tracks: [TrackID], placement: TakePlacement) {
        for (k, id) in tracks.filter({ project.track($0)?.kind == .audio }).enumerated() {
            placeTake(k == 0 ? .audio(clip) : Clip.audio(clip).withNewID(), on: id,
                      slot: placement.slots[id], launch: placement.launch, launchAt: placement.launchAt)
        }
    }

    /// Where the takes of a recording go, read before the recording fields reset: the Session slot per
    /// track (none: the arrangement), and whether and when a slot take launches.
    struct TakePlacement: Sendable {
        var slots: [TrackID: Int]
        var launch: Bool
        var launchAt: Tick?
    }

    /// The file work of one take, done off the main thread: an optional cut, then the import into the package.
    struct TakeFile: Sendable {
        var url: URL
        /// Cut this many frames off the front first (negative: silence in front). `nil`: import as it is.
        var skip: Int64?
        var name: String
        /// Removed once the import is done or the take turned out empty.
        var cleanup: [URL]
        /// Removed on any outcome, after the import (the folder of a resampling, in the last take that uses it).
        var cleanupAlways: [URL]
        /// The message when the file could not be processed.
        var failure: String
    }

    enum TakeOutcome: Sendable {
        case ready(Imported, frames: Int64)
        case empty
        case failed(String)
    }

    /// One take between its file work and its clips: what to do with the imported asset on the main actor.
    private struct PendingTake {
        var file: TakeFile
        var seconds: Double
        var notes: [String]
        var place: @MainActor (AppModel, Asset, Int64, TakePlacement) -> Void
    }

    /// The cut and the import of one take. No project state: it runs on any thread.
    nonisolated static func processTake(_ file: TakeFile, package: URL, rate: Double) -> TakeOutcome {
        defer { for u in file.cleanupAlways { try? FileManager.default.removeItem(at: u) } }
        var url = file.url, frames: Int64 = 0, trimmed: URL?
        if let skip = file.skip {
            // The original take stays on disk until the trimmed copy is part of the project.
            guard let cut = trim(file.url, skipping: skip, name: file.name) else { return .failed(file.failure) }
            guard cut.frames > 0 else {
                for u in file.cleanup + [cut.url] { try? FileManager.default.removeItem(at: u) }
                return .empty
            }
            url = cut.url; frames = cut.frames; trimmed = cut.url
        }
        do {
            let imported = try importWork(url, package: package, rate: rate)
            for u in file.cleanup + (trimmed.map { [$0] } ?? []) { try? FileManager.default.removeItem(at: u) }
            return .ready(imported, frames: frames)
        } catch {
            if let trimmed { try? FileManager.default.removeItem(at: trimmed) }
            return .failed(file.failure)
        }
    }

    /// Ends a recording of another track's sound, aimed at `tracks`. The clip starts exactly where the renderer
    /// wrote its first frame. `nil` when nothing was recorded.
    private func prepareResample(_ writer: CaptureWriter, latency: Int, tracks: [TrackID], name: String, cleanupAlways: [URL]) -> PendingTake? {
        let result = writer.finish()
        let url = writer.url
        var notes: [String] = []
        let fail = TakeFile(url: url, skip: nil, name: name, cleanup: [], cleanupAlways: cleanupAlways, failure: "Could not import the recording")
        guard !tracks.isEmpty, result.frames > 0, let first = result.firstFrame else {
            for u in cleanupAlways { try? FileManager.default.removeItem(at: u) }
            return nil
        }
        let sr = sampleRate
        // The source's plugins made its sound late; the take moves back by as much. Before the song start,
        // the late head is skipped instead.
        let at = first - Int64(latency)
        let skip = max(0, -at)
        let start = project.tempoMap.tick(atFrame: Frame(max(0, at)), sampleRate: sr)
        let end = project.tempoMap.tick(atFrame: Frame(at + result.frames), sampleRate: sr)
        guard end > start else {
            for u in cleanupAlways { try? FileManager.default.removeItem(at: u) }
            return nil
        }
        let offset = project.tempoMap.tick(atFrame: Frame(skip), sampleRate: sr)
        let length = Tick(max(1, end.rawValue - start.rawValue))
        if result.droppedFrames > 0 {
            notes.append(String(format: "Warning: %.2f s were lost (the disk was too slow)", Double(result.droppedFrames) / sr))
        }
        if let error = result.writeError { notes.append("Warning: writing the take failed: \(error)") }
        return PendingTake(file: fail, seconds: Double(result.frames) / sr, notes: notes) { model, asset, _, placement in
            var clip = model.project.makeAudioClip(asset: asset.id, start: start, length: length)
            clip.offset = offset
            clip.loop = false
            clip.warpMode = .off
            model.placeAudioTake(clip, on: tracks, placement: placement)
        }
    }

    /// Lines one sound card take up with the timeline, for `tracks`: how much to cut off its front, and the
    /// clip it becomes once its frames are known.
    private func prepareInputTake(_ take: AudioInputRecorder.Take, on tracks: [TrackID], name: String) -> PendingTake {
        // The sound that belongs at the start of the timeline reached the file this many frames after it began.
        // No start stamp, or an offset of more than 10 s: the clocks do not match, so do not shift the take.
        let start = engine.playStartHostTime
        var lead = start == 0 ? 0 : HostClock.frames(from: take.firstHostTime, to: start, rate: take.sampleRate)
        if recordPunch {
            // A punch-in: the take began while the song played. Where the song stood when the file began,
            // against where the take goes.
            let fileBegan = engine.sessionFrame(atHost: take.firstHostTime) + recordFrameOffset
            let target = project.tempoMap.frame(at: recordStartTick, sampleRate: sampleRate).rawValue
            lead = Int64(Double(target - fileBegan) * take.sampleRate / sampleRate)
        }
        if abs(lead) > Int64(take.sampleRate * 10) { lead = 0 }
        let outputLatency = AudioDeviceCatalog.devices()
            .first { $0.uid == (outputUID ?? AudioDeviceCatalog.defaultOutputUID()) }?.outputLatencyFrames ?? 0
        let skip = lead + Int64(take.inputLatencyFrames + outputLatency)
        var notes: [String] = []
        if take.droppedFrames > 0 {
            notes.append(String(format: "Warning: %.2f s of input were lost (the disk was too slow)", Double(take.droppedFrames) / take.sampleRate))
        }
        if let error = take.writeError { notes.append("Warning: writing the take failed: \(error)") }
        let file = TakeFile(url: take.url, skip: skip, name: name, cleanup: [take.url], cleanupAlways: [],
                            failure: "Could not process the recording. The take is kept at \(take.url.path)")
        let startTick = recordStartTick, takeRate = take.sampleRate
        return PendingTake(file: file, seconds: Double(take.frames) / take.sampleRate, notes: notes) { model, asset, frames, placement in
            let sr = model.sampleRate
            let startFrame = model.project.tempoMap.frame(at: startTick, sampleRate: sr).rawValue
            let projectFrames = Int64(Double(frames) * sr / takeRate)
            let endTick = model.project.tempoMap.tick(atFrame: Frame(startFrame + projectFrames), sampleRate: sr)
            var clip = model.project.makeAudioClip(asset: asset.id, start: startTick, length: Tick(max(1, endTick.rawValue - startTick.rawValue)))
            clip.loop = false
            clip.warpMode = .off
            model.placeAudioTake(clip, on: tracks, placement: placement)
        }
    }

    /// Ends the audio takes: each is cut so it starts where the transport started, becomes an asset, and puts
    /// clips on its tracks. The cut and the import run on a worker, so a long take does not freeze the window;
    /// `now` does them here (a quit or a project switch cannot wait). `prefix` goes in front of the status.
    func finishAudioRecording(now: Bool = false, prefix: String? = nil) {
        recordingAudio = false
        var pending: [PendingTake] = []
        var names = project.assets.filter { $0.name.hasPrefix("Take ") }.count
        func nextName() -> String { names += 1; return "Take \(names)" }
        if !resamples.isEmpty {
            engine.stopCapture()
            let done = resamples
            resamples = []
            let folder = done.first?.writer.url.deletingLastPathComponent()
            for (k, r) in done.enumerated() {
                let last = k == done.count - 1
                if let p = prepareResample(r.writer, latency: r.latency, tracks: r.tracks, name: nextName(), cleanupAlways: last ? folder.map { [$0] } ?? [] : []) {
                    pending.append(p)
                }
            }
        }
        let takes = audioRecorder.isRecording ? audioRecorder.stopAll() : []
        // The take may have closed the input (nothing monitors it): the engine must not read it any more.
        engine.setInputMonitor(audioRecorder.monitor)
        let groups = recordLaneTracks
        recordLaneTracks = []
        recordAudioTracks = []
        for (take, tracks) in zip(takes, groups) {
            guard let take else { continue }
            pending.append(prepareInputTake(take, on: tracks, name: nextName()))
        }
        let placement = TakePlacement(slots: recordSlots, launch: recordLaunchTake, launchAt: recordLaunchAt)
        let files = pending.map(\.file)
        let package = packageURL, rate = sampleRate
        let finish: @MainActor (AppModel, [TakeOutcome]) -> Void = { model, outcomes in
            var seconds = 0.0, notes: [String] = []
            for (p, outcome) in zip(pending, outcomes) {
                switch outcome {
                case .failed(let message): notes.append(message)
                case .empty: notes.append("Nothing recorded")
                case .ready(let imported, let frames):
                    guard model.packageURL == package, let asset = model.register(imported, from: p.file.url, name: p.file.name) else {
                        notes.append("Could not import the recording"); continue
                    }
                    p.place(model, asset, frames, placement)
                    seconds = max(seconds, p.seconds)
                    notes += p.notes
                }
            }
            let head = seconds > 0 ? String(format: "Recorded %.1f s", seconds) : "Nothing recorded"
            model.status = ((prefix.map { [$0] } ?? []) + [head] + notes).joined(separator: ". ")
        }
        if now || pending.isEmpty {
            finish(self, files.map { Self.processTake($0, package: package, rate: rate) })
            return
        }
        status = ((prefix.map { [$0] } ?? []) + ["Processing the take…"]).joined(separator: ". ")
        Task { @MainActor [weak self] in
            let outcomes = await Task.detached(priority: .userInitiated) {
                files.map { Self.processTake($0, package: package, rate: rate) }
            }.value
            guard let self else { return }
            finish(self, outcomes)
        }
    }

    /// Puts a finished take where the recording was aimed: a Session slot (it loops and starts to play,
    /// like Live), or the arrangement at the place it was played. The slot read from the current recording.
    func placeTake(_ take: Clip, on id: TrackID) {
        defer { recordSlots[id] = nil }
        placeTake(take, on: id, slot: recordSlots[id], launch: recordLaunchTake, launchAt: recordLaunchAt)
    }

    /// `slot`: the Session slot the recording was aimed at; `nil` puts the take in the arrangement. `launch`:
    /// a slot take starts to play when the transport runs, `launchAt` is the bar it was stopped on.
    func placeTake(_ take: Clip, on id: TrackID, slot: Int?, launch: Bool, launchAt: Tick?) {
        guard let row = slot else {
            // The take replaces what was under it, like Live: clips there are cut or removed, in one undo step.
            apply(.batch(commands: project.clearing(track: id, from: take.start, to: take.start + take.length)
                         + [.insertClip(track: id, clip: take)]))
            selectedClips = [take.id]
            return
        }
        var clip = project.barAligned(take)
        switch clip {
        case .audio(var c): c.start = 0; c.loop = true; clip = .audio(c)
        case .midi(var c): c.start = 0; c.loop = true; clip = .midi(c)
        case .dummy: break
        }
        apply(.setSlot(track: id, index: row, slot: SessionSlot(clip: clip)))
        selectedClip = clip.id
        guard launch, transportPlaying else { return }
        // A press one tick before the stop bar launches on that bar, so the loop goes on with no gap.
        self.launch(track: id, row: row, at: launchAt.map { $0 - Tick(1) })
    }

    /// Copies a recording without its first `skip` frames. A negative `skip` puts silence in front.
    /// `nil` when reading or writing fails: the copy is then incomplete and must not replace the take.
    nonisolated static func trim(_ url: URL, skipping skip: Int64, name: String) -> (url: URL, frames: Int64)? {
        do { return try trimOrThrow(url, skipping: skip, name: name) } catch { return nil }
    }

    nonisolated static func trimOrThrow(_ url: URL, skipping skip: Int64, name: String) throws -> (url: URL, frames: Int64)? {
        guard let input = try? AVAudioFile(forReading: url) else { return nil }
        let format = input.processingFormat
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LoopStudio-trim-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("\(name).caf")
        guard let output = try? AVAudioFile(forWriting: out, settings: input.fileFormat.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved) else { return nil }
        var written: Int64 = 0
        if skip < 0, let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) {
            silence.frameLength = 4096
            for c in 0..<Int(format.channelCount) { silence.floatChannelData?[c].update(repeating: 0, count: 4096) }
            var left = -skip
            while left > 0 {
                silence.frameLength = AVAudioFrameCount(min(4096, left))
                try output.write(from: silence)
                left -= Int64(silence.frameLength); written += Int64(silence.frameLength)
            }
        } else if skip > 0 {
            guard skip < input.length else { return (out, 0) }
            input.framePosition = skip
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { return nil }
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: 8192)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
            written += Int64(buffer.frameLength)
        }
        return (out, written)
    }
}
