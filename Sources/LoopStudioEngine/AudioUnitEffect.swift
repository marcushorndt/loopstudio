import AVFoundation
import LoopStudioCore
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
    /// True for a synth: no audio input, MIDI in.
    public let isInstrument: Bool
    private let midiBlock: AUScheduleMIDIEventBlock?
    private let parameterBlock: AUScheduleParameterBlock
    /// Parameters that accept a ramp. Others ignore an event with a ramp, so they get a step.
    private let rampable: Set<AUParameterAddress>
    public let channels: Int
    public let maxFrames: Int

    private let renderBlock: AURenderBlock
    private let outputList: UnsafeMutableAudioBufferListPointer
    private let inputPointers: UnsafeMutablePointer<UnsafePointer<Float>?>
    private let pullInput: AURenderPullInputBlock
    private var sampleTime: Float64 = 0
    /// The song position the plugin reads for its own tempo sync. The renderer sets it before each block.
    private let song = SongPosition()

    /// Latency the plugin reports, in samples. The graph uses it for delay compensation.
    public var latencySamples: Int { Int((unit.latency * sampleRate).rounded()) }
    public let sampleRate: Double

    /// `identifier` is "type/subtype/manufacturer", each four characters (as `AudioUnitInfo.identifier`).
    public static func instantiate(identifier: String, sampleRate: Double) async throws -> AudioUnitEffect {
        let parts = identifier.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { throw HostError.notFound }
        return try await instantiate(type: parts[0], subtype: parts[1], manufacturer: parts[2], sampleRate: sampleRate)
    }

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
        self.isInstrument = unit.inputBusses.count == 0
        self.midiBlock = unit.scheduleMIDIEventBlock
        self.sampleRate = sampleRate
        self.channels = channels
        self.maxFrames = maxFrames

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
        // Buses start disabled. A disabled input bus is never pulled, and the render call fails
        // with kAudioUnitErr_NoConnection (-10876).
        if unit.inputBusses.count > 0 {
            unit.inputBusses[0].isEnabled = true
            try unit.inputBusses[0].setFormat(format)
        }
        unit.outputBusses[0].isEnabled = true
        try unit.outputBusses[0].setFormat(format)
        unit.maximumFramesToRender = AUAudioFrameCount(maxFrames)
        // A plugin with its own tempo sync (a delay, an LFO, an arpeggiator) asks the host for the tempo and the beat.
        let song = self.song
        unit.musicalContextBlock = { tempo, numerator, denominator, beat, toNextBeat, downbeat in
            tempo?.pointee = song.bpm
            numerator?.pointee = Double(song.numerator)
            denominator?.pointee = song.denominator
            beat?.pointee = song.beat
            toNextBeat?.pointee = song.toNextBeat
            downbeat?.pointee = song.downbeat
            return true
        }
        unit.transportStateBlock = { flags, position, cycleStart, cycleEnd in
            var state: AUHostTransportStateFlags = song.playing ? [.moving] : []
            if song.changed { state.insert(.changed) }
            flags?.pointee = state
            position?.pointee = song.frame
            cycleStart?.pointee = 0
            cycleEnd?.pointee = 0
            return true
        }
        try unit.allocateRenderResources()

        renderBlock = unit.renderBlock
        // Valid only once render resources exist.
        parameterBlock = unit.scheduleParameterBlock
        rampable = Set(unit.parameterTree?.allParameters.filter { $0.flags.contains(.flag_CanRamp) }.map(\.address) ?? [])
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

    /// Sets the song position the plugin sees in the next `process` call. Realtime safe.
    func setSongPosition(frame: Int64, beat: Double, bpm: Double, numerator: Int, denominator: Int,
                         downbeat: Double, playing: Bool, toNextBeat: Int) {
        // "Changed" only when the transport starts, stops or jumps (a locate or a loop wrap).
        let jumped = frame < song.lastFrame || frame > song.lastFrame + Int64(maxFrames)
        song.changed = playing != song.playing || (playing && jumped)
        song.lastFrame = frame
        song.frame = Double(frame); song.beat = beat; song.bpm = bpm
        song.numerator = numerator; song.denominator = denominator
        song.downbeat = downbeat; song.playing = playing; song.sampleRate = sampleRate
        song.toNextBeat = toNextBeat
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

    /// Sends one MIDI message to start `sampleOffset` frames into the next `process` call.
    /// Realtime safe.
    public func sendMIDI(_ status: UInt8, _ data1: UInt8, _ data2: UInt8, sampleOffset: Int = 0) {
        guard let midiBlock else { return }
        var bytes: (UInt8, UInt8, UInt8) = (status, data1, data2)
        let time = AUEventSampleTime(sampleTime) + AUEventSampleTime(sampleOffset)
        withUnsafePointer(to: &bytes) { raw in
            raw.withMemoryRebound(to: UInt8.self, capacity: 3) { midiBlock(time, 0, 3, $0) }
        }
    }

    /// Moves a parameter to `value`, starting `sampleOffset` frames into the next `process` call,
    /// over `ramp` frames. Realtime safe.
    public func scheduleParameter(_ address: AUParameterAddress, _ value: Float, sampleOffset: Int, ramp: Int) {
        parameterBlock(AUEventSampleTime(sampleTime) + AUEventSampleTime(sampleOffset), AUAudioFrameCount(rampable.contains(address) ? max(0, ramp) : 0), address, value)
    }

    /// The parameters automation can move: writable ones with a usable range.
    public func automatableParameters(limit: Int = 256) -> [PluginParam] {
        guard let tree = unit.parameterTree else { return [] }
        return tree.allParameters
            .filter { $0.flags.contains(.flag_IsWritable) && $0.maxValue > $0.minValue }
            .prefix(limit)
            .map { p in
                PluginParam(key: "au.\(p.address)", name: p.displayName, min: Double(p.minValue), max: Double(p.maxValue),
                            def: Double(p.value), unit: p.unitName ?? "")
            }
    }

    /// All notes off and all sound off on every channel.
    public func silenceNotes() {
        for channel in 0..<16 {
            sendMIDI(0xB0 | UInt8(channel), 123, 0)
            sendMIDI(0xB0 | UInt8(channel), 120, 0)
        }
    }

    /// The plugin state as a property list, to store in the project.
    public func savedState() -> Data? {
        guard let state = unit.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    public func restore(state data: Data) {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = object as? [String: Any] else { return }
        unit.fullState = dictionary
    }
}

/// What a hosted plugin reads through its musical context and transport blocks. The audio thread writes it
/// right before the render call that reads it, so it needs no lock.
private final class SongPosition: @unchecked Sendable {
    var frame = 0.0, beat = 0.0, bpm = 120.0, downbeat = 0.0
    var numerator = 4, denominator = 4
    var playing = false
    var sampleRate = 48_000.0
    var changed = true
    /// Samples to the next beat, through the tempo map, so a tempo ramp is exact.
    var toNextBeat = 0
    var lastFrame = Int64.min / 2
}
