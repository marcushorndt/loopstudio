import AVFoundation
import CoreAudio
import Foundation
import os
import Synchronization

/// The sound card input: it records channels into files (one file per lane, each lane one or two channels)
/// and keeps the last moments of every channel for tracks that monitor "Ext. In".
///
/// It runs its own `AVAudioEngine`, so playback is not touched. The input runs while something monitors it or
/// a take records, and stops otherwise. A take can start and end while monitoring goes on, with no gap in
/// the monitored sound.
///
/// The input callback is a sink node, so it gets the sound card blocks as they come, with no extra buffering.
/// It only copies into rings allocated up front: one `CaptureRing` per lane, read by a writer queue that
/// empties it into its file every 20 ms, and the `InputMonitor`, read by the output callback. The first
/// block's host time is kept, so a take can be lined up with the transport afterwards. All lanes share that
/// block, so their takes start on the same frame.
public final class AudioInputRecorder: @unchecked Sendable {
    /// The channels of one file: `left` alone, or `left` and `right`. Indexes count from 0.
    public struct Lane: Hashable, Sendable {
        public var left: Int
        public var right: Int?
        public init(left: Int, right: Int?) { self.left = left; self.right = right }
    }

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
        case noInput, deviceNotFound, noPermission, busy
        public var description: String {
            switch self {
            case .noInput: "no audio input is available"
            case .deviceNotFound: "the input device was not found"
            case .noPermission: "microphone access is off. Turn it on in System Settings > Privacy & Security > Microphone."
            case .busy: "a take is recording on another input device"
            }
        }
    }

    /// Peaks of a lane while it records: one per `chunk` frames, in memory allocated up front.
    /// The input callback appends; the main thread copies out what is there.
    final class PeakTrack: @unchecked Sendable {
        static let chunk = 2048
        /// About three hours at 48 kHz.
        private let capacity = 1 << 18
        private let values: UnsafeMutablePointer<Float>
        private let count = Atomic<Int>(0)
        private var peak: Float = 0
        private var fill = 0
        init() { values = .allocate(capacity: capacity); values.initialize(repeating: 0, count: capacity) }
        deinit { values.deallocate() }
        func add(_ src: UnsafePointer<Float>, _ right: UnsafePointer<Float>?, frames: Int) {
            var i = 0
            while i < frames {
                let n = min(frames - i, Self.chunk - fill)
                for k in i..<(i + n) {
                    peak = max(peak, abs(src[k]))
                    if let right { peak = max(peak, abs(right[k])) }
                }
                fill += n; i += n
                if fill == Self.chunk {
                    let c = count.load(ordering: .relaxed)
                    if c < capacity { values[c] = peak; count.store(c + 1, ordering: .releasing) }
                    peak = 0; fill = 0
                }
            }
        }
        var all: [Float] { Array(UnsafeBufferPointer(start: values, count: count.load(ordering: .acquiring))) }
    }

    /// What the input callback does with a block, besides the monitor. Swapped whole, under `rt`.
    private final class Session {
        let picks: [(Int, Int?)]
        let rings: [CaptureRing]
        let peaks: [PeakTrack]
        init(picks: [(Int, Int?)], rings: [CaptureRing], peaks: [PeakTrack]) { self.picks = picks; self.rings = rings; self.peaks = peaks }
    }

    private let engine = AVAudioEngine()
    private var sink: AVAudioSinkNode?
    /// Control side state.
    private let lock = NSLock()
    private var writers: [CaptureWriter] = []
    private var urls: [URL] = []
    private var peakTracks: [PeakTrack] = []
    private var rate = 48_000.0
    private var inputLatency = 0
    private var channels = 0
    /// The device the running input is on. `.some(nil)`: the system default.
    private var openDevice: String??
    private var monitoring = false
    /// Scratch for an interleaved input format: planar copies of one block.
    private var scratch: UnsafeMutablePointer<Float>?
    private let scratchFrames = 8192

    /// Shared with the input callback, under `rt`: plain copies only.
    private let rt: UnsafeMutablePointer<os_unfair_lock>
    private var session: Session?
    private var monitorRef: InputMonitor?
    private var callbacks: UInt64 = 0

    /// The monitor of the open input, for the output engine. `nil` while the input is closed.
    public private(set) var monitor: InputMonitor?
    /// Called on the main queue when the input device changed its setup or went away while the input was
    /// open: the engine has stopped, a take gets no more sound. The owner ends the take or opens the input again.
    public var onConfigurationChange: (@Sendable () -> Void)?
    private var configObserver: NSObjectProtocol?

    public init() {
        rt = .allocate(capacity: 1)
        rt.initialize(to: os_unfair_lock())
    }

    deinit {
        engine.stop()
        rt.deallocate()
        scratch?.deallocate()
    }

    public var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return !writers.isEmpty }
    public var isOpen: Bool { engine.isRunning }

    /// The number of input channels of a device, or of the default input with `nil`.
    public static func channelCount(deviceUID: String?) -> Int {
        AudioDeviceCatalog.devices().first { $0.uid == (deviceUID ?? AudioDeviceCatalog.defaultInputUID()) }?.inputs.count ?? 0
    }

    // MARK: Open and close

    /// Keeps the input open (monitoring) or lets it close when no take runs. `bufferFrames`: the sound card
    /// block size to ask for, like the output's, so monitoring is as quick as playback.
    public func setMonitoring(_ on: Bool, deviceUID: String?, bufferFrames: Int? = nil) throws {
        lock.lock(); monitoring = on; lock.unlock()
        if on {
            try open(deviceUID: deviceUID, bufferFrames: bufferFrames)
        } else if !isRecording {
            close()
        }
    }

    /// Starts the input engine on `deviceUID`, or keeps it running if it is on that device already.
    private func open(deviceUID: String?, bufferFrames: Int?) throws {
        if engine.isRunning {
            if openDevice == .some(deviceUID) { return }
            // Another device: a take in progress stays on its device.
            guard !isRecording else { throw RecordError.busy }
            close()
        }
        let input = engine.inputNode
        var deviceLatency = 0
        var deviceID: AudioObjectID?
        if let uid = deviceUID {
            let system = AudioObjectID(kAudioObjectSystemObject)
            guard var device = HAL.array(system, kAudioHardwarePropertyDevices, as: AudioObjectID.self, zero: 0)
                .first(where: { HAL.string($0, kAudioDevicePropertyDeviceUID) == uid }),
                  let unit = input.audioUnit else { throw RecordError.deviceNotFound }
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &device, UInt32(MemoryLayout<AudioObjectID>.size))
            guard status == noErr else { throw RecordError.deviceNotFound }
            deviceID = device
        } else if let device = HAL.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
                                         as: AudioObjectID.self, zero: 0), device != 0 {
            deviceID = device
        }
        if let device = deviceID {
            deviceLatency = Self.latency(of: device)
            if var frames = bufferFrames.map({ UInt32($0) }), frames > 0 {
                var address = HAL.address(kAudioDevicePropertyBufferFrameSize)
                AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
            }
        }

        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw RecordError.noPermission }
        let channels = Int(format.channelCount)
        let interleaved = format.isInterleaved
        if interleaved, scratch == nil { scratch = .allocate(capacity: channels * scratchFrames) }
        let scratch = scratch, scratchFrames = scratchFrames
        let monitor = InputMonitor(channels: channels, sampleRate: format.sampleRate)
        let rt = rt
        let sink = AVAudioSinkNode { [unowned self] timestamp, frameCount, list -> OSStatus in
            let n = Int(frameCount)
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            guard buffers.count > 0 else { return noErr }
            /// The planar samples of channel `c`.
            func plane(_ c: Int) -> UnsafePointer<Float>? {
                if !interleaved { return c < buffers.count ? buffers[c].mData.map { UnsafePointer($0.assumingMemoryBound(to: Float.self)) } : nil }
                guard let scratch, n <= scratchFrames, c < channels else { return nil }
                return UnsafePointer(scratch + c * scratchFrames)
            }
            if interleaved, let scratch, n <= scratchFrames, let base = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                for c in 0..<channels { for i in 0..<n { scratch[c * scratchFrames + i] = base[i * channels + c] } }
            }
            os_unfair_lock_lock(rt)
            self.callbacks &+= 1
            let session = self.session
            let monitor = self.monitorRef
            os_unfair_lock_unlock(rt)
            monitor?.write(frames: n, source: plane)
            guard let session else { return noErr }
            let host = timestamp.pointee.mHostTime
            for (k, pick) in session.picks.enumerated() {
                guard let left = plane(pick.0) else { continue }
                let right = pick.1.flatMap(plane)
                session.rings[k].noteStart(hostTime: host)
                session.rings[k].write(left, right, frames: n)
                session.peaks[k].add(left, right, frames: n)
            }
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        self.sink = sink
        lock.lock()
        rate = format.sampleRate; inputLatency = deviceLatency; self.channels = channels; openDevice = .some(deviceUID)
        lock.unlock()
        os_unfair_lock_lock(rt); monitorRef = monitor; os_unfair_lock_unlock(rt)
        engine.prepare()
        do { try engine.start() } catch {
            closeGraph()
            throw error
        }
        self.monitor = monitor
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                guard let self, !self.engine.isRunning else { return }
                self.onConfigurationChange?()
            }
        }
    }

    /// True while the input engine runs. False after the device went away, until the input is opened again.
    public var isRunning: Bool { engine.isRunning }

    /// Stops the input engine. Only when nothing records.
    private func close() {
        guard !isRecording else { return }
        closeGraph()
    }

    private func closeGraph() {
        engine.stop()
        if let sink { engine.disconnectNodeInput(sink); engine.detach(sink) }
        sink = nil
        os_unfair_lock_lock(rt); monitorRef = nil; os_unfair_lock_unlock(rt)
        monitor = nil
        lock.lock(); openDevice = nil; lock.unlock()
    }

    // MARK: Takes

    /// One lane, `left` alone or with `right`.
    public func start(deviceUID: String?, left: Int, right: Int?, to url: URL) throws {
        try start(deviceUID: deviceUID, lanes: [Lane(left: left, right: right)], to: [url])
    }

    /// Records each lane into the URL at the same index. A channel past the device's last one uses the last one.
    /// The input opens if it is closed, on `deviceUID`; open on another device for monitoring, it moves there.
    public func start(deviceUID: String?, lanes: [Lane], to urls: [URL], bufferFrames: Int? = nil) throws {
        guard !isRecording, !lanes.isEmpty, lanes.count == urls.count else { return }
        try open(deviceUID: deviceUID, bufferFrames: bufferFrames)
        lock.lock()
        let channels = self.channels, rate = self.rate
        lock.unlock()
        let picks = lanes.map { lane in
            (min(max(0, lane.left), channels - 1), lane.right.map { min(max(0, $0), channels - 1) })
        }
        let writers = try zip(picks, urls).map { pick, url in
            try CaptureWriter(url: url, sampleRate: rate, channels: pick.1 == nil ? 1 : 2)
        }
        let peaks = lanes.map { _ in PeakTrack() }
        lock.lock()
        self.writers = writers; self.urls = urls; peakTracks = peaks
        lock.unlock()
        let session = Session(picks: picks, rings: writers.map(\.ring), peaks: peaks)
        os_unfair_lock_lock(rt); self.session = session; os_unfair_lock_unlock(rt)
    }

    /// The waveform of a lane so far: one peak per captured `bufferFrames` frames.
    public func livePeaks(lane: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return lane < peakTracks.count ? peakTracks[lane].all : []
    }

    public var bufferFrames: Int { PeakTrack.chunk }

    /// Stops and closes the file of a single lane.
    public func stop() -> Take? { stopAll().first ?? nil }

    /// Stops and closes every file. One entry per lane, in the order of `start`; `nil` where nothing was recorded.
    /// The input stays open when something monitors it.
    public func stopAll() -> [Take?] {
        guard isRecording else { return [] }
        // After this, the input callback writes nothing more into the rings: wait for the callback that may
        // still hold them to end (one block at most).
        os_unfair_lock_lock(rt)
        let old = session; session = nil
        let started = callbacks
        os_unfair_lock_unlock(rt)
        var waited = 0
        while engine.isRunning, waited < 200 {
            os_unfair_lock_lock(rt); let now = callbacks; os_unfair_lock_unlock(rt)
            if now > started &+ 1 { break }
            usleep(1_000); waited += 1
        }
        withExtendedLifetime(old) {}
        lock.lock()
        let writers = writers, urls = urls, rate = rate, inputLatency = inputLatency, monitoring = monitoring
        self.writers = []; self.urls = []
        lock.unlock()
        if !monitoring { closeGraph() }
        return zip(writers, urls).map { writer, url in
            let result = writer.finish()
            guard result.frames > 0 else { return nil }
            return Take(url: url, sampleRate: rate, frames: result.frames, firstHostTime: result.firstHostTime,
                        inputLatencyFrames: inputLatency, droppedFrames: result.droppedFrames, writeError: result.writeError)
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
