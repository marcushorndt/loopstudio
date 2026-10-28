import AVFoundation

/// Plays one audio loop, stretched to the project tempo without a pitch change.
/// Realtime mode drives the speakers; offline mode renders into memory (for tests and export).
public final class LoopEngine {
    public enum Mode: Sendable {
        case realtime
        case offline(sampleRate: Double)
    }

    public enum EngineError: Error {
        case noClip
        case renderFailed(String)
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let mode: Mode
    private var buffer: AVAudioPCMBuffer?
    private var sourceTempo: Double = 120

    /// Project tempo in beats per minute. A change applies at once, also while playing.
    public var projectTempo: Double = 120 {
        didSet { applyRate() }
    }

    /// Stretch factor: how much faster than the source the loop plays.
    public var rate: Double { projectTempo / sourceTempo }

    public init(mode: Mode = .realtime) throws {
        self.mode = mode
        engine.attach(player)
        engine.attach(timePitch)
        if case .offline(let sampleRate) = mode {
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        }
    }

    /// Loads the file into memory. `sourceTempo` is the tempo the loop was recorded at.
    public func load(url: URL, sourceTempo: Double) throws {
        precondition(sourceTempo > 0, "sourceTempo must be positive")
        let file = try AVAudioFile(forReading: url)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(file.length)) else {
            throw EngineError.renderFailed("cannot allocate buffer")
        }
        try file.read(into: pcm)
        buffer = pcm
        self.sourceTempo = sourceTempo
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(timePitch)
        engine.connect(player, to: timePitch, format: pcm.format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: pcm.format)
        applyRate()
    }

    public func start() throws {
        guard let buffer else { throw EngineError.noClip }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        try engine.start()
        player.play()
    }

    public func stop() {
        player.stop()
        engine.stop()
    }

    /// Renders `frames` frames of the output in offline mode.
    public func render(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard case .offline = mode else { throw EngineError.renderFailed("not in offline mode") }
        let format = engine.manualRenderingFormat
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        while out.frameLength < frames {
            let want = min(chunk.frameCapacity, frames - out.frameLength)
            let status = try engine.renderOffline(want, to: chunk)
            guard status == .success else { throw EngineError.renderFailed("status \(status.rawValue)") }
            for channel in 0..<Int(format.channelCount) {
                let src = chunk.floatChannelData![channel]
                let dst = out.floatChannelData![channel] + Int(out.frameLength)
                dst.update(from: src, count: Int(chunk.frameLength))
            }
            out.frameLength += chunk.frameLength
        }
        return out
    }

    private func applyRate() {
        timePitch.rate = Float(min(32, max(1.0 / 32, rate)))
    }
}
