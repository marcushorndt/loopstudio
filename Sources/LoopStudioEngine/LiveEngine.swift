import AVFoundation
import CoreAudio
import AudioToolbox
import Foundation
import LoopStudioCore
import os

/// Plays a `Renderer` through the default output device.
///
/// The audio thread reads state under a lock. Every other thread holds that lock for a few plain writes
/// only (no allocation, no release of the last reference), so the audio thread never waits long.
public final class LiveEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    // Guarded by `lock`.
    private var renderer: Renderer?
    private var playing = false
    private var position: Int64 = 0
    /// The session clock: like `position`, but it does not jump back at the loop end.
    private var sessionPosition: Int64 = 0
    private var loop: Range<Int64>?
    private var resetPending = false
    private var silencePending = false
    /// Resampling: the track whose sound is recorded, and the ring of the writer that records it.
    private var captureTrack: TrackID?
    private var captureRing: CaptureRing?
    /// The renderer that played last, until the audio thread takes over its held notes.
    private var handover: Renderer?
    /// Keeps the handover renderer alive on the control thread, so the audio thread never frees it.
    private var retired: Renderer?
    private struct LiveMIDI { var track: TrackID; var status: UInt8; var data1: UInt8; var data2: UInt8 }
    private let liveCapacity = 512
    private let live: UnsafeMutablePointer<LiveMIDI>
    private var liveCount = 0
    // Metronome and count-in, guarded by `lock`.
    private var metronome = false
    /// While the transport plays, the click sits on these frames (sorted), from the tempo and time
    /// signature maps. Empty: a steady click of `beatFrames`.
    private var clickFrames: [Int64] = []
    private var clickAccents: [Bool] = []
    /// After the last grid beat the click goes on at the last beat length, in the last bar's meter.
    private var clickTailBeat: Int64 = 0
    private var clickTailBar = 4
    /// Beats from the last accent to the last grid beat.
    private var clickTailPhase = 0
    private var beatFrames: Int64 = 24_000
    private var beatsPerBar = 4
    private var countInRemaining: Int64 = 0
    private var countInDone: Int64 = 0
    private var stampPending = false
    private var startHost: UInt64 = 0
    /// The session frame that sounds at host time `anchorHost`. Updated every block, for MIDI timestamps.
    private var anchorHost: UInt64 = 0
    private var anchorFrame: Int64 = 0
    /// The rate the plans render at. It follows the open project; the output converts to the device rate.
    public private(set) var sampleRate: Double

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        live = .allocate(capacity: liveCapacity)
    }

    deinit {
        engine.stop()
        lock.deallocate()
        live.deallocate()
    }

    public func start() throws {
        guard sourceNode == nil else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let node = AVAudioSourceNode(format: format) { [unowned self] _, timestamp, frameCount, bufferList in
            self.render(frameCount: Int(frameCount), bufferList: bufferList, host: timestamp.pointee.mHostTime)
            return noErr
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
        // A sound card that changes its format or goes away stops the engine. It starts again on the new setup.
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                guard let self, !self.engine.isRunning else { return }
                try? self.engine.start()
                self.onConfigurationChange?()
            }
        }
    }

    /// Called on the main queue after the sound card setup changed and the engine started again.
    public var onConfigurationChange: (@Sendable () -> Void)?
    private var configObserver: NSObjectProtocol?

    public func shutdown() { engine.stop() }

    /// Renders at another rate from now on (a project with another sample rate was opened). The old plan is
    /// dropped, because its frames count at the old rate; the caller installs a new one.
    public func setSampleRate(_ rate: Double) throws {
        guard rate > 0, rate != sampleRate else { return }
        let wasRunning = engine.isRunning
        engine.stop()
        setRenderer(nil)
        if let node = sourceNode { engine.detach(node); sourceNode = nil }
        // Readers on other threads (MIDI time stamps) take the lock, so the rate changes under it too.
        locked { position = 0; sessionPosition = 0; playing = false; countInRemaining = 0; anchorHost = 0; sampleRate = rate }
        if wasRunning { try start() }
    }

    public enum OutputError: Error { case deviceNotFound, noAudioUnit, status(OSStatus) }

    /// Plays through another device, and sends the stereo master to two of its channels.
    /// `uid` nil means the system default. Channels count from 0. The engine restarts if it was running.
    public func setOutput(uid: String?, left: Int = 0, right: Int = 1, bufferFrames: Int? = nil) throws {
        let wasRunning = engine.isRunning
        engine.stop()
        defer { if wasRunning { try? engine.start() } }

        let system = AudioObjectID(kAudioObjectSystemObject)
        var deviceID: AudioObjectID?
        if let uid {
            deviceID = HAL.array(system, kAudioHardwarePropertyDevices, as: AudioObjectID.self, zero: 0)
                .first { HAL.string($0, kAudioDevicePropertyDeviceUID) == uid }
        } else {
            deviceID = HAL.value(system, kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self, zero: 0)
        }
        guard var device = deviceID, device != 0 else { throw OutputError.deviceNotFound }
        guard let unit = engine.outputNode.audioUnit else { throw OutputError.noAudioUnit }

        var status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &device, UInt32(MemoryLayout<AudioObjectID>.size))
        guard status == noErr else { throw OutputError.status(status) }

        let channels = HAL.channelCount(device, scope: kAudioObjectPropertyScopeOutput)
        if channels > 2 || left != 0 || right != 1 {
            var map = [Int32](repeating: -1, count: max(channels, 2))
            if left < map.count { map[left] = 0 }
            if right < map.count { map[right] = 1 }
            status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 0,
                                          map, UInt32(map.count * MemoryLayout<Int32>.size))
            guard status == noErr else { throw OutputError.status(status) }
        }
        if var frames = bufferFrames.map({ UInt32($0) }) {
            var address = HAL.address(kAudioDevicePropertyBufferFrameSize)
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        }
    }

    // MARK: Control thread

    public func setRenderer(_ new: Renderer?) {
        os_unfair_lock_lock(lock)
        let old = renderer
        renderer = new
        // A renderer that never played holds no notes; keep the one that did.
        if handover == nil { handover = old }
        let keep = handover
        os_unfair_lock_unlock(lock)
        retired = keep
        withExtendedLifetime(old) {}
    }

    public var isPlaying: Bool { locked { playing } }
    /// The next frame to play.
    public var positionFrame: Int64 { locked { position } }
    /// The session clock. Session launches count on it.
    public var sessionFrame: Int64 { locked { sessionPosition } }
    /// Timeline frame minus session frame, both read at one instant.
    public var clockOffset: Int64 { locked { position - sessionPosition } }

    /// The session frame that sounded at `hostTime` (a MIDI packet time stamp). 0 means "now".
    /// Several notes in one MIDI burst keep their own times, instead of all landing on the next block.
    public func sessionFrame(atHost hostTime: UInt64) -> Int64 {
        locked {
            guard hostTime != 0, anchorHost != 0 else { return sessionPosition }
            return anchorFrame + HostClock.frames(from: anchorHost, to: hostTime, rate: sampleRate)
        }
    }

    public func play() {
        // The session clock is not reset here: a resume after a pause continues it. A jump while stopped syncs it.
        locked { playing = true; countInRemaining = 0; stampPending = true }
    }

    /// Host time at which the transport last began to play. For lining up a recording with the timeline.
    public var playStartHostTime: UInt64 { locked { startHost } }

    /// Sets the click. `beatFrames` is the length of one beat in frames at the current tempo.
    public func setMetronome(enabled: Bool, beatFrames: Int64, beatsPerBar: Int) {
        locked { metronome = enabled; self.beatFrames = max(1, beatFrames); self.beatsPerBar = max(1, beatsPerBar) }
    }

    /// The beats of the song, in frames, with the bar accents. The old arrays are freed here, not on the audio thread.
    public func setClickGrid(frames: [Int64], accents: [Bool]) {
        var oldFrames = frames, oldAccents = accents
        let n = min(frames.count, accents.count)
        let accentIndexes = (0..<n).filter { accents[$0] }
        let tailBeat = n >= 2 ? max(1, frames[n - 1] - frames[n - 2]) : 0
        let tailBar = accentIndexes.count >= 2 ? accentIndexes[accentIndexes.count - 1] - accentIndexes[accentIndexes.count - 2] : 4
        let tailPhase = accentIndexes.last.map { n - 1 - $0 } ?? 0
        locked {
            swap(&clickFrames, &oldFrames); swap(&clickAccents, &oldAccents)
            clickTailBeat = tailBeat; clickTailBar = max(1, tailBar); clickTailPhase = tailPhase
        }
        withExtendedLifetime((oldFrames, oldAccents)) {}
    }

    /// Plays only the click for `beats` beats, then starts the transport. Instruments keep running meanwhile.
    public func playAfterCountIn(beats: Int) {
        locked {
            guard beats > 0 else { playing = true; stampPending = true; return }
            countInRemaining = Int64(beats) * beatFrames
            countInDone = 0
        }
    }

    public var isCountingIn: Bool { locked { countInRemaining > 0 } }
    public func pause() { locked { playing = false; countInRemaining = 0; silencePending = true } }
    /// A jump moves the timeline. While playing, the session clock runs on, so session clips keep their place.
    public func seek(to frame: Int64) {
        locked {
            position = max(0, frame)
            if !playing { sessionPosition = position }
            resetPending = true
        }
    }

    /// Queues a live MIDI message for the instrument of `track`. The track, not a node index, is the
    /// address, so a message sent while the graph changes still reaches the right instrument. Safe from any thread.
    public func sendLiveMIDI(track: TrackID, _ status: UInt8, _ data1: UInt8, _ data2: UInt8) {
        locked {
            guard liveCount < liveCapacity else { return }
            live[liveCount] = LiveMIDI(track: track, status: status, data1: data1, data2: data2)
            liveCount += 1
        }
    }
    public func setLoop(_ range: Range<Int64>?) { locked { loop = range } }

    /// Records the sound of `track` (after its fader) while the transport plays. The first recorded frame
    /// is in `CaptureWriter.Result.firstFrame`, on the timeline.
    public func startCapture(track: TrackID, into writer: CaptureWriter) {
        locked { captureTrack = track; captureRing = writer.ring }
    }

    /// After this returns, the audio thread writes nothing more into the ring.
    public func stopCapture() {
        let old: CaptureRing? = locked { let r = captureRing; captureRing = nil; captureTrack = nil; return r }
        withExtendedLifetime(old) {}
    }

    public func takePeak(node: Int) -> Float { locked { renderer?.takePeak(node: node) ?? 0 } }

    private func locked<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body()
    }

    // MARK: Audio thread

    private func render(frameCount: Int, bufferList: UnsafeMutablePointer<AudioBufferList>, host: UInt64) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard buffers.count >= 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }

        // Every holder of the lock does a few plain writes and never allocates or frees under it, and
        // os_unfair_lock lends this thread's priority to the holder. A short wait is better than a silent
        // block that also stops both clocks.
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        guard let renderer else {
            left.update(repeating: 0, count: frameCount); right.update(repeating: 0, count: frameCount)
            liveCount = 0
            return
        }

        if let old = handover {
            if old !== renderer { renderer.takeOverNotes(from: old, at: position) }
            handover = nil
        }
        if resetPending { renderer.reset(); resetPending = false; silencePending = false }
        if silencePending { renderer.silenceNotes(); silencePending = false }
        renderer.captureTrack = captureTrack
        renderer.captureRing = captureRing
        for i in 0..<liveCount { renderer.sendLive(track: live[i].track, live[i].status, live[i].data1, live[i].data2) }
        liveCount = 0

        // Stopped: no clips, but instruments and effects keep running, so live notes sound and tails ring out.
        // A count-in is the same, with a click, and it starts the transport when it ends.
        var done = 0
        while !playing && done < frameCount {
            var n = min(frameCount - done, renderer.maxBlock)
            if countInRemaining > 0 { n = Int(min(Int64(n), countInRemaining)) }
            renderer.process(startFrame: position, frames: n, transport: false, outLeft: left + done, outRight: right + done)
            if countInRemaining > 0 {
                addClick(left + done, right + done, n, clock: countInDone)
                countInDone += Int64(n)
                countInRemaining -= Int64(n)
                if countInRemaining <= 0 {
                    countInRemaining = 0; playing = true
                    startHost = host &+ HostClock.ticks(fromSeconds: Double(done + n) / sampleRate)
                }
            }
            done += n
        }

        if stampPending && playing { startHost = host; stampPending = false }
        anchorHost = host &+ HostClock.ticks(fromSeconds: Double(done) / sampleRate)
        anchorFrame = sessionPosition
        while done < frameCount {
            var n = min(frameCount - done, renderer.maxBlock)
            if let loop, position < loop.upperBound {
                n = min(n, Int(loop.upperBound - position))
            }
            renderer.process(startFrame: position, sessionFrame: sessionPosition, frames: n, outLeft: left + done, outRight: right + done)
            if metronome {
                if clickFrames.isEmpty { addClick(left + done, right + done, n, clock: position) }
                else { addGridClick(left + done, right + done, n, clock: position) }
            }
            position += Int64(n)
            sessionPosition += Int64(n)
            done += n
            if let loop, position >= loop.upperBound { position = loop.lowerBound; renderer.releaseArrangementNotes() }
        }
    }

    /// Adds the click for `count` frames. `clock` is the frame count since a beat grid that starts at 0.
    /// The click on the beat grid: each sample sounds the latest beat at or before it.
    private func addGridClick(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ count: Int, clock: Int64) {
        let length = Int64(sampleRate * 0.04)
        var lo = 0, hi = clickFrames.count
        while lo < hi { let mid = (lo + hi) / 2; if clickFrames[mid] <= clock { lo = mid + 1 } else { hi = mid } }
        var beat = lo - 1 // the latest beat at or before `clock`, or -1
        for i in 0..<count {
            let t = clock + Int64(i)
            while beat + 1 < clickFrames.count && clickFrames[beat + 1] <= t { beat += 1 }
            guard beat >= 0 else { continue }
            var offset = t - clickFrames[beat]
            var accent = clickAccents[beat]
            if beat == clickFrames.count - 1, clickTailBeat > 0 {
                let k = offset / clickTailBeat
                offset -= k * clickTailBeat
                accent = (Int64(clickTailPhase) + k) % Int64(clickTailBar) == 0
            }
            guard offset < length else { continue }
            let phase = 2 * Double.pi * (accent ? 1_500 : 1_000) * Double(offset) / sampleRate
            let v = Float(sin(phase) * exp(-Double(offset) / (sampleRate * 0.008)) * 0.4)
            left[i] += v
            right[i] += v
        }
    }

    private func addClick(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ count: Int, clock: Int64) {
        let length = Int64(sampleRate * 0.04)
        for i in 0..<count {
            let t = clock + Int64(i)
            let offset = t % beatFrames
            guard offset < length else { continue }
            let accent = (t / beatFrames) % Int64(beatsPerBar) == 0
            let phase = 2 * Double.pi * (accent ? 1_500 : 1_000) * Double(offset) / sampleRate
            let v = Float(sin(phase) * exp(-Double(offset) / (sampleRate * 0.008)) * 0.4)
            left[i] += v
            right[i] += v
        }
    }
}
