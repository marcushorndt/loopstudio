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
        recordStartTick = currentTick
        recordTrackID = id
        recording = true
        recordingAudio = true
        updateMetronome()
        engine.playAfterCountIn(beats: countInBars * 4)
        transportPlaying = true
        status = "Recording audio"
    }

    /// Cuts the take so it starts where the transport started, makes it an asset, and puts a clip on the track.
    func finishAudioRecording() {
        recordingAudio = false
        guard let take = audioRecorder.stop(), let id = recordTrackID else { status = "Nothing recorded"; return }
        recordTrackID = nil

        // The sound that belongs at the start of the timeline reached the file this many frames after it began.
        let lead = HostClock.frames(from: take.firstHostTime, to: engine.playStartHostTime, rate: take.sampleRate)
        let outputLatency = AudioDeviceCatalog.devices()
            .first { $0.uid == (outputUID ?? AudioDeviceCatalog.defaultOutputUID()) }?.outputLatencyFrames ?? 0
        let skip = lead + Int64(take.inputLatencyFrames + outputLatency)

        guard let trimmed = trim(take.url, skipping: skip, name: nextTakeName()) else { status = "Could not read the recording"; return }
        defer { try? FileManager.default.removeItem(at: take.url); try? FileManager.default.removeItem(at: trimmed.url) }
        guard trimmed.frames > 0, let asset = importAudio(trimmed.url) else { status = "Nothing recorded"; return }

        let sr = sampleRate
        let startFrame = project.tempoMap.frame(at: recordStartTick, sampleRate: sr).rawValue
        let projectFrames = Int64(Double(trimmed.frames) * sr / take.sampleRate)
        let endTick = project.tempoMap.tick(atFrame: Frame(startFrame + projectFrames), sampleRate: sr)
        var clip = project.makeAudioClip(asset: asset.id, start: recordStartTick, length: Tick(max(1, endTick.rawValue - recordStartTick.rawValue)))
        clip.loop = false
        clip.warpMode = .off
        apply(.insertClip(track: id, clip: .audio(clip)))
        selectedClips = [clip.id]
        status = String(format: "Recorded %.1f s", Double(trimmed.frames) / take.sampleRate)
    }

    private func nextTakeName() -> String {
        let n = project.assets.filter { $0.name.hasPrefix("Take ") }.count + 1
        return "Take \(n)"
    }

    /// Copies a recording without its first `skip` frames. A negative `skip` puts silence in front.
    private func trim(_ url: URL, skipping skip: Int64, name: String) -> (url: URL, frames: Int64)? {
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
                try? output.write(from: silence)
                left -= Int64(silence.frameLength); written += Int64(silence.frameLength)
            }
        } else if skip > 0 {
            guard skip < input.length else { return (out, 0) }
            input.framePosition = skip
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { return nil }
        while input.framePosition < input.length {
            do { try input.read(into: buffer, frameCount: 8192) } catch { break }
            if buffer.frameLength == 0 { break }
            try? output.write(from: buffer)
            written += Int64(buffer.frameLength)
        }
        return (out, written)
    }
}
