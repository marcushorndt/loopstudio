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

    func startAudioRecording() async {
        guard let id = selectedTrack else { return }
        // "Audio From" another track: record its sound after the fader, with no sound card involved.
        if let source = project.track(id)?.inputTrack {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LoopStudio-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let writer = try CaptureWriter(url: folder.appendingPathComponent("\(nextTakeName()).caf"), sampleRate: sampleRate, channels: 2)
                resampleWriter = writer
                resampleLatency = plan?.arrival(of: source) ?? 0
                engine.startCapture(track: source, into: writer)
            } catch {
                status = "Cannot record: \(error.localizedDescription)"
                recordArmed = false
                return
            }
            beginRecording(on: id, status: "Recording \(project.track(source)?.name ?? "the input track")")
            return
        }
        guard await microphoneAllowed() else {
            status = "Microphone access is off. Turn it on in System Settings > Privacy & Security > Microphone."
            recordArmed = false
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LoopStudio-take-\(UUID().uuidString).caf")
        do {
            try audioRecorder.start(deviceUID: inputUID, left: inputLeft, right: inputStereo ? inputLeft + 1 : nil, to: url)
        } catch {
            status = "Cannot record: \(error)"
            recordArmed = false
            return
        }
        beginRecording(on: id, status: "Recording audio")
    }

    private func beginRecording(on id: TrackID, status text: String) {
        recordStartTick = currentTick
        recordTrackID = id
        recordSlot = sessionRecordSlot(id)
        recordFrameOffset = engine.clockOffset
        recording = true
        recordingAudio = true
        updateMetronome()
        if !recordPunch { engine.playAfterCountIn(beats: countInBars * meter.beats) }
        transportPlaying = true
        status = recordSlot.map { "\(text) into slot \($0 + 1)" } ?? text
    }

    /// Ends a recording of another track's sound. It starts exactly where the renderer wrote its first frame.
    private func finishResampling(_ writer: CaptureWriter) {
        engine.stopCapture()
        resampleWriter = nil
        let result = writer.finish()
        let url = writer.url
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        guard let id = recordTrackID, result.frames > 0, let first = result.firstFrame else { recordTrackID = nil; status = "Nothing recorded"; return }
        recordTrackID = nil
        guard let asset = importAudio(url) else { status = "Could not import the recording"; return }
        let sr = sampleRate
        // The source's plugins made its sound late; the take moves back by as much. Before the song start,
        // the late head is skipped instead.
        let at = first - Int64(resampleLatency)
        let skip = max(0, -at)
        let start = project.tempoMap.tick(atFrame: Frame(max(0, at)), sampleRate: sr)
        let end = project.tempoMap.tick(atFrame: Frame(at + result.frames), sampleRate: sr)
        guard end > start else { status = "Nothing recorded"; return }
        var clip = project.makeAudioClip(asset: asset.id, start: start, length: Tick(max(1, end.rawValue - start.rawValue)))
        clip.offset = project.tempoMap.tick(atFrame: Frame(skip), sampleRate: sr)
        clip.loop = false
        clip.warpMode = .off
        placeTake(.audio(clip), on: id)
        status = String(format: "Recorded %.1f s", Double(result.frames) / sr)
        if result.droppedFrames > 0 {
            status += String(format: ". Warning: %.2f s were lost (the disk was too slow)", Double(result.droppedFrames) / sr)
        }
        if let error = result.writeError { status += ". Warning: writing the take failed: \(error)" }
    }

    /// Cuts the take so it starts where the transport started, makes it an asset, and puts a clip on the track.
    func finishAudioRecording() {
        recordingAudio = false
        if let writer = resampleWriter { finishResampling(writer); return }
        guard let take = audioRecorder.stop(), let id = recordTrackID else { status = "Nothing recorded"; return }
        recordTrackID = nil

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

        // The original take stays on disk until the trimmed copy is part of the project.
        guard let trimmed = trim(take.url, skipping: skip, name: nextTakeName()) else {
            status = "Could not process the recording. The take is kept at \(take.url.path)"
            return
        }
        guard trimmed.frames > 0 else {
            try? FileManager.default.removeItem(at: take.url); try? FileManager.default.removeItem(at: trimmed.url)
            status = "Nothing recorded"
            return
        }
        guard let asset = importAudio(trimmed.url) else {
            try? FileManager.default.removeItem(at: trimmed.url)
            status = "Could not import the recording. The take is kept at \(take.url.path)"
            return
        }
        try? FileManager.default.removeItem(at: take.url)
        try? FileManager.default.removeItem(at: trimmed.url)

        let sr = sampleRate
        let startFrame = project.tempoMap.frame(at: recordStartTick, sampleRate: sr).rawValue
        let projectFrames = Int64(Double(trimmed.frames) * sr / take.sampleRate)
        let endTick = project.tempoMap.tick(atFrame: Frame(startFrame + projectFrames), sampleRate: sr)
        var clip = project.makeAudioClip(asset: asset.id, start: recordStartTick, length: Tick(max(1, endTick.rawValue - recordStartTick.rawValue)))
        clip.loop = false
        clip.warpMode = .off
        placeTake(.audio(clip), on: id)
        status = String(format: "Recorded %.1f s", Double(trimmed.frames) / take.sampleRate)
        if take.droppedFrames > 0 {
            status += String(format: ". Warning: %.2f s of input were lost (the disk was too slow)", Double(take.droppedFrames) / take.sampleRate)
        }
        if let error = take.writeError { status += ". Warning: writing the take failed: \(error)" }
    }

    /// In the Session view, with the cursor on an empty slot of the track, the take goes into that slot.
    func sessionRecordSlot(_ id: TrackID) -> Int? {
        guard viewMode == .session, let row = selectedSceneRow, let track = project.track(id) else { return nil }
        return row < track.slots.count && track.slots[row] != nil ? nil : row
    }

    /// Puts a finished take where the recording was aimed: a Session slot (it loops and starts to play,
    /// like Live), or the arrangement at the place it was played.
    func placeTake(_ take: Clip, on id: TrackID) {
        defer { recordSlot = nil }
        guard let row = recordSlot else {
            apply(.insertClip(track: id, clip: take))
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
        launch(track: id, row: row)
    }

    private func nextTakeName() -> String {
        let n = project.assets.filter { $0.name.hasPrefix("Take ") }.count + 1
        return "Take \(n)"
    }

    /// Copies a recording without its first `skip` frames. A negative `skip` puts silence in front.
    /// `nil` when reading or writing fails: the copy is then incomplete and must not replace the take.
    private func trim(_ url: URL, skipping skip: Int64, name: String) -> (url: URL, frames: Int64)? {
        do { return try trimOrThrow(url, skipping: skip, name: name) } catch { return nil }
    }

    private func trimOrThrow(_ url: URL, skipping skip: Int64, name: String) throws -> (url: URL, frames: Int64)? {
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
