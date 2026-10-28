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
    private var url: URL?
    private var rate = 48_000.0
    private var inputLatency = 0
    private var writer: CaptureWriter?

    public init() {}

    public var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return writer != nil }

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

        let writer = try CaptureWriter(url: url, sampleRate: format.sampleRate, channels: outChannels)
        let ring = writer.ring
        lock.lock()
        self.writer = writer; self.url = url; rate = format.sampleRate; inputLatency = deviceLatency
        lock.unlock()
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, time in
            guard let src = buffer.floatChannelData else { return }
            ring.noteStart(hostTime: time.hostTime)
            ring.write(src[l], r.map { UnsafePointer(src[$0]) }, frames: Int(buffer.frameLength))
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            _ = writer.finish()
            lock.lock(); self.writer = nil; lock.unlock()
            throw error
        }
    }

    /// Stops and closes the file.
    public func stop() -> Take? {
        guard isRecording else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        let writer = writer
        self.writer = nil
        lock.unlock()
        guard let result = writer?.finish(), let url, result.frames > 0 else { return nil }
        return Take(url: url, sampleRate: rate, frames: result.frames, firstHostTime: result.firstHostTime,
                    inputLatencyFrames: inputLatency, droppedFrames: result.droppedFrames, writeError: result.writeError)
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
