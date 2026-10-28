import AVFoundation
import CoreAudio
import Foundation

/// Records one or two channels of a sound card input into a file.
///
/// It runs its own `AVAudioEngine`, so playback is not touched. The first buffer's host time is kept,
/// so the take can be lined up with the transport afterwards.
///
/// The capture callback only copies into a `CaptureRing`. A writer queue empties the ring into the file
/// every 20 ms, so slow storage cannot hold up capture. Lost frames and write errors come back in the `Take`.
public final class AudioInputRecorder: @unchecked Sendable {
    public struct Take: Sendable {
        public var url: URL
        public var sampleRate: Double
        public var frames: Int64
        /// Host time of the first recorded frame.
        public var firstHostTime: UInt64
        /// Latency of the input device, in frames.
        public var inputLatencyFrames: Int
        /// Frames the writer could not keep up with. They are missing from the file.
        public var droppedFrames: Int64 = 0
        /// The first error from writing the file, if any.
        public var writeError: String? = nil
    }

    public enum RecordError: Error, CustomStringConvertible {
        case noInput, deviceNotFound, noPermission
        public var description: String {
            switch self {
            case .noInput: "no audio input is available"
            case .deviceNotFound: "the input device was not found"
            case .noPermission: "microphone access is off. Turn it on in System Settings > Privacy & Security > Microphone."
            }
        }
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var url: URL?
    private var rate = 48_000.0
    private var written: Int64 = 0
    private var inputLatency = 0
    private var recording = false
    private var ring: CaptureRing?
    private var writer: DispatchSourceTimer?
    private let writeQueue = DispatchQueue(label: "loopstudio.capture.writer", qos: .userInitiated)
    private var chunk: AVAudioPCMBuffer?
    private var writeError: String?

    public init() {}

    public var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return recording }

    /// `left` and `right` are channel indexes (from 0) of the device. `right` nil records mono.
    public func start(deviceUID: String?, left: Int, right: Int?, to url: URL) throws {
        guard !isRecording else { return }
        let input = engine.inputNode
        var deviceLatency = 0
        if let uid = deviceUID {
            let system = AudioObjectID(kAudioObjectSystemObject)
            guard var device = HAL.array(system, kAudioHardwarePropertyDevices, as: AudioObjectID.self, zero: 0)
                .first(where: { HAL.string($0, kAudioDevicePropertyDeviceUID) == uid }),
                  let unit = input.audioUnit else { throw RecordError.deviceNotFound }
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &device, UInt32(MemoryLayout<AudioObjectID>.size))
            guard status == noErr else { throw RecordError.deviceNotFound }
            deviceLatency = Self.latency(of: device)
        } else if let device = HAL.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
                                         as: AudioObjectID.self, zero: 0), device != 0 {
            deviceLatency = Self.latency(of: device)
        }

        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw RecordError.noPermission }
        let channels = Int(format.channelCount)
        let l = min(max(0, left), channels - 1)
        let r = right.map { min(max(0, $0), channels - 1) }
        let outChannels = r == nil ? 1 : 2

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: outChannels, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        ]
        let out = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                            channels: AVAudioChannelCount(outChannels), interleaved: false) else { throw RecordError.noInput }

        // Ten seconds of buffer: far more than a slow disk needs to catch up.
        let ring = CaptureRing(channels: outChannels, capacity: Int(format.sampleRate * 10))
        guard let chunk = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 8192) else { throw RecordError.noInput }

        lock.lock()
        file = out; self.url = url; rate = format.sampleRate; written = 0; inputLatency = deviceLatency; recording = true
        self.ring = ring; self.chunk = chunk; writeError = nil
        lock.unlock()
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, time in
            guard let src = buffer.floatChannelData else { return }
            ring.noteStart(hostTime: time.hostTime)
            ring.write(src[l], r.map { UnsafePointer(src[$0]) }, frames: Int(buffer.frameLength))
        }
        let timer = DispatchSource.makeTimerSource(queue: writeQueue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.drain() }
        writer = timer
        timer.resume()
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            timer.cancel(); writer = nil
            lock.lock(); recording = false; file = nil; self.ring = nil; lock.unlock()
            throw error
        }
    }

    /// Stops and closes the file.
    public func stop() -> Take? {
        guard isRecording else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer?.cancel(); writer = nil
        writeQueue.sync { drain() } // what is still in the ring
        lock.lock(); defer { lock.unlock() }
        recording = false
        file = nil   // closes the file
        let dropped = Int64(ring?.dropped ?? 0), host = ring?.startHostTime ?? 0
        ring = nil; chunk = nil
        guard let url, written > 0 else { return nil }
        return Take(url: url, sampleRate: rate, frames: written, firstHostTime: host, inputLatencyFrames: inputLatency,
                    droppedFrames: dropped, writeError: writeError)
    }

    /// Writer queue: moves what the ring holds into the file.
    /// The disk write runs outside the lock, so `isRecording` never waits for storage.
    private func drain() {
        lock.lock()
        let ring = ring, chunk = chunk, file = file
        lock.unlock()
        guard let ring, let chunk, let file, let dst = chunk.floatChannelData else { return }
        while true {
            let n = ring.read(into: dst[0], ring.channels == 2 ? dst[1] : nil, max: Int(chunk.frameCapacity))
            guard n > 0 else { return }
            chunk.frameLength = AVAudioFrameCount(n)
            var failure: String?
            do { try file.write(from: chunk) } catch { failure = error.localizedDescription }
            lock.lock()
            if let failure { if writeError == nil { writeError = failure } } else { written += Int64(n) }
            lock.unlock()
        }
    }

    private static func latency(of device: AudioObjectID) -> Int {
        let l = HAL.value(device, kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeInput, as: UInt32.self, zero: 0) ?? 0
        let s = HAL.value(device, kAudioDevicePropertySafetyOffset, scope: kAudioObjectPropertyScopeInput, as: UInt32.self, zero: 0) ?? 0
        return Int(l + s)
    }
}

/// Conversion between the host clock and frames.
public enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t
    }()

    public static func seconds(fromTicks ticks: Int64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    public static func ticks(fromSeconds s: Double) -> UInt64 {
        UInt64(max(0, s * 1e9 * Double(timebase.denom) / Double(timebase.numer)))
    }

    /// How many frames after the take began the transport began. Negative when the transport began first.
    public static func frames(from take: UInt64, to transport: UInt64, rate: Double) -> Int64 {
        let delta = Int64(bitPattern: transport) &- Int64(bitPattern: take)
        return Int64((seconds(fromTicks: delta) * rate).rounded())
    }
}
