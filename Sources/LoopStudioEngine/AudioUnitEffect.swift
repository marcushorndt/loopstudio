import AVFoundation
import AudioToolbox

public func fourCC(_ s: String) -> FourCharCode {
    s.utf8.prefix(4).reduce(0) { ($0 << 8) | FourCharCode($1) }
}

/// Hosts one effect Audio Unit by calling its render block directly.
/// This is what the future mix graph does for every plugin: no `AVAudioEngine` in between.
///
/// `process` is written for the audio thread: it uses only memory allocated in `init`
/// (no Swift arrays, no allocation, no locks).
public final class AudioUnitEffect: @unchecked Sendable {
    public enum HostError: Error {
        case notFound
        case renderFailed(OSStatus)
    }

    public let unit: AUAudioUnit
    public let channels: Int
    public let maxFrames: Int

    private let renderBlock: AURenderBlock
    private let outputList: UnsafeMutableAudioBufferListPointer
    private let inputPointers: UnsafeMutablePointer<UnsafePointer<Float>?>
    private let pullInput: AURenderPullInputBlock
    private var sampleTime: Float64 = 0

    /// Latency the plugin reports, in samples. The graph uses it for delay compensation.
    public var latencySamples: Int { Int((unit.latency * sampleRate).rounded()) }
    public let sampleRate: Double

    public static func instantiate(type: String, subtype: String, manufacturer: String,
                                   sampleRate: Double, channels: Int = 2, maxFrames: Int = 4096) async throws -> AudioUnitEffect {
        var description = AudioComponentDescription(
            componentType: fourCC(type), componentSubType: fourCC(subtype),
            componentManufacturer: fourCC(manufacturer), componentFlags: 0, componentFlagsMask: 0)
        guard AudioComponentFindNext(nil, &description) != nil else { throw HostError.notFound }
        let unit = try await AUAudioUnit.instantiate(with: description, options: [])
        return try AudioUnitEffect(unit: unit, sampleRate: sampleRate, channels: channels, maxFrames: maxFrames)
    }

    init(unit: AUAudioUnit, sampleRate: Double, channels: Int, maxFrames: Int) throws {
        self.unit = unit
        self.sampleRate = sampleRate
        self.channels = channels
        self.maxFrames = maxFrames

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
        // Buses start disabled. A disabled input bus is never pulled, and the render call fails
        // with kAudioUnitErr_NoConnection (-10876).
        unit.inputBusses[0].isEnabled = true
        unit.outputBusses[0].isEnabled = true
        try unit.inputBusses[0].setFormat(format)
        try unit.outputBusses[0].setFormat(format)
        unit.maximumFramesToRender = AUAudioFrameCount(maxFrames)
        try unit.allocateRenderResources()

        renderBlock = unit.renderBlock
        outputList = AudioBufferList.allocate(maximumBuffers: channels)
        inputPointers = .allocate(capacity: channels)
        inputPointers.initialize(repeating: nil, count: channels)

        let pointers = inputPointers
        let count = channels
        pullInput = { _, _, frames, _, list in
            let abl = UnsafeMutableAudioBufferListPointer(list)
            for ch in 0..<min(count, abl.count) {
                guard let source = pointers[ch] else { continue }
                let bytes = Int(frames) * MemoryLayout<Float>.size
                if let destination = abl[ch].mData {
                    destination.copyMemory(from: source, byteCount: bytes)
                } else {
                    abl[ch].mData = UnsafeMutableRawPointer(mutating: source)
                }
                abl[ch].mDataByteSize = UInt32(bytes)
            }
            return noErr
        }
    }

    deinit {
        unit.deallocateRenderResources()
        outputList.unsafeMutablePointer.deallocate()
        inputPointers.deallocate()
    }

    /// Renders `frames` frames. `input` and `output` hold one pointer per channel.
    /// Realtime safe: no allocation, no locks.
    @discardableResult
    public func process(frames: Int,
                        input: UnsafePointer<UnsafePointer<Float>>,
                        output: UnsafePointer<UnsafeMutablePointer<Float>>) -> OSStatus {
        precondition(frames <= maxFrames)
        for ch in 0..<channels {
            inputPointers[ch] = input[ch]
            outputList[ch] = AudioBuffer(mNumberChannels: 1,
                                         mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                                         mData: UnsafeMutableRawPointer(output[ch]))
        }
        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = sampleTime
        timestamp.mFlags = .sampleTimeValid
        sampleTime += Float64(frames)

        let status = renderBlock(&flags, &timestamp, AUAudioFrameCount(frames), 0,
                                 outputList.unsafeMutablePointer, pullInput)
        // An AU may point the output at its own memory. Copy it back into ours.
        for ch in 0..<channels {
            if let data = outputList[ch].mData, data != UnsafeMutableRawPointer(output[ch]) {
                UnsafeMutableRawPointer(output[ch]).copyMemory(from: data, byteCount: frames * MemoryLayout<Float>.size)
            }
        }
        return status
    }
}
