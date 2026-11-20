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

    /// Silence: `channels` channels of `frames` frames, to be filled through `mutableChannel`.
    public init(channels: Int, frames: Int, sampleRate: Double) {
        precondition(channels > 0 && frames > 0)
        self.channels = channels
        self.frames = frames
        self.sampleRate = sampleRate
        storage = .allocate(capacity: channels * frames)
        storage.initialize(repeating: 0, count: channels * frames)
    }

    deinit { storage.deallocate() }

    public func channel(_ index: Int) -> UnsafePointer<Float> {
        UnsafePointer(storage + min(index, channels - 1) * frames)
    }

    /// For the code that fills a new buffer. A buffer that is shared must not change.
    func mutableChannel(_ index: Int) -> UnsafeMutablePointer<Float> {
        storage + min(index, channels - 1) * frames
    }

    private let transientLock = NSLock()
    private var transientFrames: [Int]?

    /// The frames where a transient (an attack) starts, found once per buffer. Beats cuts the audio there.
    public var transients: [Int] {
        transientLock.lock(); defer { transientLock.unlock() }
        if let t = transientFrames { return t }
        let t = Onsets.detect(self)
        transientFrames = t
        return t
    }
}

/// All audio a project uses, loaded and converted to the project's sample rate.
public final class AudioBank: @unchecked Sendable {
    private var buffers: [AssetID: PCMBuffer] = [:]
    private let warpLock = NSLock()
    private var warped: [String: PCMBuffer] = [:]
    /// When each warp was last asked for, so the eviction drops the oldest.
    private var used: [String: UInt64] = [:]
    private var clock: UInt64 = 0
    /// The clock at the last two `takePendingWarps()` calls. Warps used since `previousTake` belong to the
    /// latest plan, and the eviction keeps them.
    private var lastTake: UInt64 = 0, previousTake: UInt64 = 0
    /// The last warped buffer each clip played. It stands in while the new one is made.
    private var lastWarp: [ClipID: PCMBuffer] = [:]
    private var pending: [String: WarpJob] = [:]
    private let bufferLock = NSLock()

    /// A warp that a worker makes later. Unchecked: `make` only reads its captured buffers.
    public struct WarpJob: @unchecked Sendable {
        public let key: String
        let make: () -> PCMBuffer
    }

    /// When true (the live app), a missing warp does not stop the caller: the clip keeps its last
    /// warped audio, and the job waits in `takePendingWarps()` for a worker.
    public var defersWarps = false

    public init() {}

    /// A bank for the live app: warps are made by a worker, never inside a rebuild.
    public static func live() -> AudioBank { let bank = AudioBank(); bank.defersWarps = true; return bank }

    public func insert(_ buffer: PCMBuffer, for id: AssetID) { bufferLock.lock(); buffers[id] = buffer; bufferLock.unlock() }
    public func buffer(for id: AssetID) -> PCMBuffer? { bufferLock.lock(); defer { bufferLock.unlock() }; return buffers[id] }

    /// A warp for `clip`, or a stand-in while it is made (see `defersWarps`): the clip's last warp.
    /// `nil` when the clip has none yet. The clip then stays silent, since the raw audio would play off tempo.
    func warped(key: String, clip: ClipID, make: @escaping () -> PCMBuffer) -> PCMBuffer? {
        guard defersWarps else {
            let made = warped(key: key, make: make)
            warpLock.lock(); lastWarp[clip] = made; warpLock.unlock()
            return made
        }
        warpLock.lock(); defer { warpLock.unlock() }
        if let hit = warped[key] { touch(key); lastWarp[clip] = hit; return hit }
        if pending[key] == nil { pending[key] = WarpJob(key: key, make: make) }
        return lastWarp[clip]
    }

    /// A bank for one export: the same audio and the warps made so far, with its own list of missing warps,
    /// so the live app and the export do not take each other's jobs.
    public func exportCopy() -> AudioBank {
        let copy = AudioBank()
        copy.defersWarps = true
        bufferLock.lock(); copy.buffers = buffers; bufferLock.unlock()
        warpLock.lock(); copy.warped = warped; copy.used = used; copy.clock = clock; copy.lastWarp = lastWarp; warpLock.unlock()
        return copy
    }

    /// The warps the last plans asked for and did not find. Taking them clears the list.
    public func takePendingWarps() -> [WarpJob] {
        warpLock.lock(); defer { warpLock.unlock() }
        let jobs = Array(pending.values)
        pending = [:]
        previousTake = lastTake; lastTake = clock
        return jobs
    }

    /// Makes one deferred warp. Slow; call it on a worker.
    public func run(_ job: WarpJob) { _ = warped(key: job.key, make: job.make) }

    /// A stretched copy of a clip's audio. Stretching is slow, so each result is made once per key.
    public func warped(key: String, make: () -> PCMBuffer) -> PCMBuffer {
        warpLock.lock()
        if let hit = warped[key] { touch(key); warpLock.unlock(); return hit }
        warpLock.unlock()
        let made = make()
        warpLock.lock()
        warped[key] = made
        touch(key)
        // Edits make old keys useless. The oldest half goes, so the warps the latest plans use stay.
        if warped.count > 256 {
            let old = used.filter { $0.value < previousTake }.sorted { $0.value < $1.value }.prefix(128).map(\.key)
            for key in old { warped[key] = nil; used[key] = nil }
        }
        if lastWarp.count > 1_024 { lastWarp = [:] }
        warpLock.unlock()
        return made
    }

    /// Call with `warpLock` held.
    private func touch(_ key: String) { clock += 1; used[key] = clock }

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
