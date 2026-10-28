import AVFoundation
import LoopStudioCore

/// Decoded audio, planar float, immutable after creation. Safe to read from the audio thread.
public final class PCMBuffer: @unchecked Sendable {
    public let channels: Int
    public let frames: Int
    public let sampleRate: Double
    private let storage: UnsafeMutablePointer<Float>

    /// `samples[channel][frame]`. All channels must have the same length.
    public init(samples: [[Float]], sampleRate: Double) {
        precondition(!samples.isEmpty && samples.allSatisfy { $0.count == samples[0].count })
        channels = samples.count
        frames = samples[0].count
        self.sampleRate = sampleRate
        storage = .allocate(capacity: max(1, channels * frames))
        for (c, channel) in samples.enumerated() {
            channel.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                (storage + c * frames).update(from: base, count: frames)
            }
        }
    }

    deinit { storage.deallocate() }

    public func channel(_ index: Int) -> UnsafePointer<Float> {
        UnsafePointer(storage + min(index, channels - 1) * frames)
    }
}

/// All audio a project uses, loaded and converted to the project's sample rate.
public final class AudioBank: @unchecked Sendable {
    private var buffers: [AssetID: PCMBuffer] = [:]

    public init() {}

    public func insert(_ buffer: PCMBuffer, for id: AssetID) { buffers[id] = buffer }
    public func buffer(for id: AssetID) -> PCMBuffer? { buffers[id] }

    public struct LoadResult {
        public var bank: AudioBank
        /// Assets whose file is missing or cannot be decoded. Their clips play silence.
        public var failed: [AssetID: String]
    }

    /// Loads every asset of the project. `resolve` maps an asset to its file.
    /// A file at another sample rate is converted once, here, with the system converter.
    public static func load(project: Project, resolve: (Asset) -> URL?) -> LoadResult {
        let bank = AudioBank()
        var failed: [AssetID: String] = [:]
        for asset in project.assets {
            guard let url = resolve(asset) else { failed[asset.id] = "file not found"; continue }
            do { bank.insert(try decode(url, targetRate: project.sampleRate), for: asset.id) }
            catch { failed[asset.id] = "\(error)" }
        }
        return LoadResult(bank: bank, failed: failed)
    }

    /// Reads a file as float, at most two channels, at `targetRate`.
    public static func decode(_ url: URL, targetRate: Double) throws -> PCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let channelCount = min(Int(file.processingFormat.channelCount), 2)
        guard file.length > 0, channelCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.processingFormat.sampleRate,
                                           channels: AVAudioChannelCount(channelCount), interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw CocoaError(.fileReadUnknown) }
        try file.read(into: input)

        var source = input
        if inFormat.channelCount != file.processingFormat.channelCount {
            // More than two channels: keep the first two.
            guard let trimmed = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: input.frameLength) else { throw CocoaError(.fileReadUnknown) }
            trimmed.frameLength = input.frameLength
            for c in 0..<channelCount { trimmed.floatChannelData![c].update(from: input.floatChannelData![c], count: Int(input.frameLength)) }
            source = trimmed
        }

        if abs(inFormat.sampleRate - targetRate) < 0.5 { return pcm(from: source, rate: targetRate) }

        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                                            channels: AVAudioChannelCount(channelCount), interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else { throw CocoaError(.fileReadUnknown) }
        converter.sampleRateConverterQuality = .max
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        let capacity = AVAudioFrameCount((Double(source.frameLength) * targetRate / inFormat.sampleRate).rounded(.up)) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { throw CocoaError(.fileReadUnknown) }
        var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if delivered { inputStatus.pointee = .endOfStream; return nil }
            delivered = true
            inputStatus.pointee = .haveData
            return source
        }
        if status == .error { throw error ?? CocoaError(.fileReadUnknown) }
        return pcm(from: output, rate: targetRate)
    }

    private static func pcm(from buffer: AVAudioPCMBuffer, rate: Double) -> PCMBuffer {
        let n = Int(buffer.frameLength)
        let channels = (0..<Int(buffer.format.channelCount)).map { c in
            Array(UnsafeBufferPointer(start: buffer.floatChannelData![c], count: n))
        }
        return PCMBuffer(samples: channels, sampleRate: rate)
    }
}
