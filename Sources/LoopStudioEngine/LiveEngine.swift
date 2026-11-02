import AVFoundation
import CoreAudio
import AudioToolbox
import Foundation
import LoopStudioCore
import os

/// Plays a `Renderer` through the default output device.
///
/// The audio thread holds the lock twice per callback, each time for a few plain copies: at the start it
/// takes the control state, at the end it writes back the clocks. It renders without the lock, so a
/// control thread never waits for a render, and the audio thread never waits for more than a few copies.
/// Objects the audio thread may still use (an old renderer, old click arrays) are freed on the control
/// thread only after the audio thread started a later callback.
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
    /// Resampling: the tracks whose sound is recorded, each with the ring of the writer that records it.
    private var captures: CaptureSet?
    /// The sound card input, for tracks that monitor it.
    private var inputMonitor: InputMonitor?
    /// The renderer that played last, until the audio thread takes over its held notes.
    private var handover: Renderer?
    /// A live note. `host` is when it is due (a host time stamp), 0 for "at the top of the next block".
    private struct LiveMIDI { var track: TrackID; var status: UInt8; var data1: UInt8; var data2: UInt8; var host: UInt64 = 0 }
    private let liveCapacity = 512
    /// Live notes from other threads, and the audio thread's own copy of them.
    private let live: UnsafeMutablePointer<LiveMIDI>
    private let liveTaken: UnsafeMutablePointer<LiveMIDI>
    private var liveCount = 0
    /// Live notes due in a later block. Owned by the audio thread.
    private let livePending: UnsafeMutablePointer<LiveMIDI>
    private var livePendingCount = 0
    /// Metronome and count-in.
    private struct Click {
        var enabled = false
        /// While the transport plays, the click sits on these frames (sorted), from the tempo and time
        /// signature maps. Empty: a steady click of `beatFrames`.
        var frames: [Int64] = []
        var accents: [Bool] = []
        /// After the last grid beat the click goes on at the last beat length, in the last bar's meter.
        var tailBeat: Int64 = 0
        var tailBar = 4
        /// Beats from the last accent to the last grid beat.
        var tailPhase = 0
        var beatFrames: Int64 = 24_000
        var beatsPerBar = 4
    }
    private var click = Click()
    /// Where the master and the direct ports go among the output channels.
    private struct Routes {
        var multi = false
        var masterLeft = 0, masterRight = 1
        var ports: [PortID: (Int, Int)] = [:]
    }
    private var routes = Routes()
    /// Channels of the source node: 2, or every channel of the card when direct ports are in use.
    private var graphChannels = 2
    private var countInRemaining: Int64 = 0
    private var countInDone: Int64 = 0
    /// A count-in clicks; a timed start (Link) waits in silence.
    private var countInClick = true
    /// A start asked for at a host time: the audio thread turns it into a silent wait when it sees it.
    private var startAtHost: UInt64 = 0
    private var stampPending = false
    private var startHost: UInt64 = 0
    /// The session frame that sounds at host time `anchorHost`. Updated every block, for MIDI timestamps.
    private var anchorHost: UInt64 = 0
    private var anchorFrame: Int64 = 0
    /// The stamp of the last buffer, smoothed. Bluetooth and other devices without a hardware clock stamp
    /// their buffers unevenly: one lands tens of milliseconds early or late and the next makes up for it.
    /// The smoothed time expects each buffer one buffer after the last and lets a stamp pull it only a
    /// little; a stamp far off (a stall, a new device) re-anchors at once. Audio thread only.
    private var smoothedHost: UInt64 = 0
    private var lastBlockFrames = 0
    /// Frames between the render of a buffer and its sound at the output: the device's latency plus its
    /// safety offset, at the engine rate (160 ms over Bluetooth). Part of the anchor, so "the frame that
    /// sounds at this host time" is true for MIDI stamps and for Link.
    private var outputLatency: Int64 = 0
    /// Count up when a control thread moves the clocks (a seek) or the transport state (play, pause,
    /// count-in). The audio thread writes back only what nobody changed while it rendered.
    private var clockGeneration: UInt64 = 0
    private var stateGeneration: UInt64 = 0
    /// Callbacks started. An object retired at count `n` is free to go once the count is above `n`.
    private var callbacks: UInt64 = 0
    /// Meter peaks per node, handed over at the end of each callback.
    private let meterCapacity = 1024
    private let meters: UnsafeMutablePointer<Float>
    /// Notes for hardware MIDI destinations. The renderer pushes, a sender thread puts them on the wire.
    public let midiOut = MIDIOutQueue()
    /// The rate the plans render at. It follows the open project; the output converts to the device rate.
    public private(set) var sampleRate: Double

    // Control threads only, guarded by `graveLock`.
    private let graveLock = NSLock()
    private var graveyard: [(object: Any, callback: UInt64)] = []

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        live = .allocate(capacity: liveCapacity)
        liveTaken = .allocate(capacity: liveCapacity)
        livePending = .allocate(capacity: liveCapacity)
        meters = .allocate(capacity: meterCapacity)
        meters.initialize(repeating: 0, count: meterCapacity)
        midiOut.hostTime = { [weak self] frame in self?.hostTime(forSessionFrame: frame) ?? 0 }
        midiOut.ticksPerFrame = Double(HostClock.ticks(fromSeconds: 1)) / sampleRate
    }

    deinit {
        engine.stop()
        lock.deallocate()
        live.deallocate()
        liveTaken.deallocate()
        livePending.deallocate()
        meters.deallocate()
    }

    public func start() throws {
        guard sourceNode == nil else { return }
        let node: AVAudioSourceNode
        let render: AVAudioSourceNodeRenderBlock = { [unowned self] _, timestamp, frameCount, bufferList in
            self.render(frameCount: Int(frameCount), bufferList: bufferList, host: timestamp.pointee.mHostTime)
            return noErr
        }
        if graphChannels > 2 {
            // Direct outputs: the engine renders every channel of the sound card itself, straight to the output.
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(graphChannels))!
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
            node = AVAudioSourceNode(format: format, renderBlock: render)
            engine.attach(node)
            engine.connect(node, to: engine.outputNode, format: format)
        } else {
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
            node = AVAudioSourceNode(format: format, renderBlock: render)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        sourceNode = node
        try engine.start()
        refreshOutputLatency()
        // A sound card that changes its format or goes away stops the engine. It starts again on the new setup.
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                guard let self, !self.engine.isRunning else { return }
                try? self.engine.start()
                self.refreshOutputLatency()
                self.onConfigurationChange?()
            }
        }
    }

    /// Reads how late the output device plays what the engine renders, for the clock anchor.
    private func refreshOutputLatency() {
        guard let unit = engine.outputNode.audioUnit else { return }
        var device: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size) == noErr,
              device != 0 else { return }
        let scope = kAudioObjectPropertyScopeOutput
        let latency = HAL.value(device, kAudioDevicePropertyLatency, scope: scope, as: UInt32.self, zero: 0) ?? 0
        let safety = HAL.value(device, kAudioDevicePropertySafetyOffset, scope: scope, as: UInt32.self, zero: 0) ?? 0
        let deviceRate = HAL.value(device, kAudioDevicePropertyNominalSampleRate, as: Double.self, zero: 0) ?? 0
        let atEngineRate = deviceRate > 0 ? Double(latency + safety) * sampleRate / deviceRate : Double(latency + safety)
        locked { outputLatency = Int64(atEngineRate.rounded()) }
    }

    /// See `smoothedHost`. Audio thread only.
    private func smoothHost(_ stamp: UInt64, frames: Int) -> UInt64 {
        defer { lastBlockFrames = frames }
        guard smoothedHost != 0, lastBlockFrames > 0 else { smoothedHost = stamp; return stamp }
        let expected = smoothedHost &+ HostClock.ticks(fromSeconds: Double(lastBlockFrames) / sampleRate)
        let delta = Int64(bitPattern: stamp &- expected)
        // A quarter second: more than any jitter, less than a stall worth a new anchor.
        if abs(delta) > Int64(HostClock.ticks(fromSeconds: 0.25)) { smoothedHost = stamp; return stamp }
        smoothedHost = expected &+ UInt64(bitPattern: delta / 32)
        return smoothedHost
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
        locked {
            position = 0; sessionPosition = 0; playing = false; countInRemaining = 0; anchorHost = 0; smoothedHost = 0; sampleRate = rate
            clockGeneration &+= 1; stateGeneration &+= 1
        }
        midiOut.ticksPerFrame = Double(HostClock.ticks(fromSeconds: 1)) / rate
        if wasRunning { try start() }
    }

    public enum OutputError: Error { case deviceNotFound, noAudioUnit, status(OSStatus) }

    /// Plays through another device, and sends the stereo master to two of its channels.
    /// `uid` nil means the system default. Channels count from 0. The engine restarts if it was running.
    /// Plays through another device. The master goes to channels `left` and `right` (from 0). `ports` maps
    /// each direct hardware port to a channel pair of the device. With direct ports on a card of more than two
    /// channels, the engine renders every channel itself; otherwise the ports play on the master pair.
    /// `uid` nil means the system default. The engine restarts if it was running.
    public func setOutput(uid: String?, left: Int = 0, right: Int = 1, bufferFrames: Int? = nil,
                          ports: [PortID: (Int, Int)] = [:]) throws {
        let wasRunning = engine.isRunning
        engine.stop()
        defer {
            // A changed channel count dropped the source node: build the graph again.
            if sourceNode == nil { try? start(); if !wasRunning { engine.stop() } }
            else if wasRunning { try? engine.start() }
        }

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
        let multi = !ports.isEmpty && channels > 2
        if multi != (graphChannels > 2) || (multi && channels != graphChannels) {
            if let node = sourceNode { engine.detach(node); sourceNode = nil }
            graphChannels = multi ? channels : 2
        }
        setRoutes(channels: multi ? channels : 2, left: left, right: right, ports: ports)
        defer { refreshOutputLatency() }
        if multi {
            // Channel n of the engine is channel n of the card.
            let map = (0..<Int32(channels)).map { $0 }
            status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 0,
                                          map, UInt32(map.count * MemoryLayout<Int32>.size))
            guard status == noErr else { throw OutputError.status(status) }
        } else if channels > 2 || left != 0 || right != 1 {
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

    /// Where the master and the ports go when the engine renders `channels` channels. More than two
    /// channels turns direct outputs on; with two, the ports play on the master pair.
    func setRoutes(channels: Int, left: Int, right: Int, ports: [PortID: (Int, Int)]) {
        let multi = channels > 2
        let routes = Routes(multi: multi, masterLeft: multi ? min(left, channels - 1) : 0, masterRight: multi ? min(right, channels - 1) : 1,
                            ports: multi ? ports.filter { $0.value.0 < channels && $0.value.1 < channels } : [:])
        let old: Routes = locked { let old = self.routes; self.routes = routes; return old }
        retire(old.ports)
    }

    // MARK: Control thread

    /// Keeps `object` alive until the audio thread can no longer use it, and frees what is old enough.
    private func retire(_ object: Any?) {
        let now = locked { callbacks }
        let running = engine.isRunning
        graveLock.lock()
        if let object { graveyard.append((object, now)) }
        // A callback that started at `now` may still use objects retired at `now`, and the next one still
        // reads the handover renderer's held notes. Only a callback two later cannot touch them.
        let free = graveyard.filter { !running || $0.callback + 1 < now }
        graveyard.removeAll { !running || $0.callback + 1 < now }
        graveLock.unlock()
        withExtendedLifetime(free) {}
    }

    public func setRenderer(_ new: Renderer?) {
        let old: Renderer? = locked {
            let old = renderer
            renderer = new
            // A renderer that never played holds no notes; keep the one that did.
            if handover == nil { handover = old }
            return old
        }
        retire(old)
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

    /// The host time at which session frame `frame` plays, from the last block's anchor. Before the first
    /// block, now.
    public func hostTime(forSessionFrame frame: Int64) -> UInt64 {
        locked {
            guard anchorHost != 0 else { return mach_absolute_time() }
            let seconds = Double(frame - anchorFrame) / sampleRate
            return seconds >= 0 ? anchorHost &+ HostClock.ticks(fromSeconds: seconds) : anchorHost &- HostClock.ticks(fromSeconds: -seconds)
        }
    }

    public func play() {
        // The session clock is not reset here: a resume after a pause continues it. A jump while stopped syncs it.
        locked { playing = true; countInRemaining = 0; startAtHost = 0; stampPending = true; stateGeneration &+= 1 }
    }

    /// Starts the transport at host time `host` (Link's grid), sample exact. A time already past starts now.
    public func play(atHost host: UInt64) {
        locked { playing = false; countInRemaining = 0; startAtHost = max(1, host); stateGeneration &+= 1 }
    }

    /// Host time at which the transport last began to play. For lining up a recording with the timeline.
    public var playStartHostTime: UInt64 { locked { startHost } }

    /// Sets the click. `beatFrames` is the length of one beat in frames at the current tempo.
    public func setMetronome(enabled: Bool, beatFrames: Int64, beatsPerBar: Int) {
        locked { click.enabled = enabled; click.beatFrames = max(1, beatFrames); click.beatsPerBar = max(1, beatsPerBar) }
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
            swap(&click.frames, &oldFrames); swap(&click.accents, &oldAccents)
            click.tailBeat = tailBeat; click.tailBar = max(1, tailBar); click.tailPhase = tailPhase
        }
        retire((oldFrames, oldAccents))
    }

    /// Plays only the click for `beats` beats, then starts the transport. Instruments keep running meanwhile.
    public func playAfterCountIn(beats: Int) {
        locked {
            stateGeneration &+= 1
            startAtHost = 0
            guard beats > 0 else { playing = true; stampPending = true; return }
            countInRemaining = Int64(beats) * click.beatFrames
            countInDone = 0
            countInClick = true
        }
    }

    /// True during a count-in and during the wait for a timed start.
    public var isCountingIn: Bool { locked { countInRemaining > 0 || startAtHost != 0 } }
    public func pause() { locked { playing = false; countInRemaining = 0; startAtHost = 0; silencePending = true; stateGeneration &+= 1 } }
    /// A jump moves the timeline. While playing, the session clock runs on, so session clips keep their place.
    public func seek(to frame: Int64) {
        locked {
            position = max(0, frame)
            if !playing { sessionPosition = position }
            // Notes end; the delays and reverbs ring on, as in Live. A full reset is for a new sample rate.
            silencePending = true
            clockGeneration &+= 1
        }
    }

    /// Queues a live MIDI message for the instrument of `track`. The track, not a node index, is the
    /// address, so a message sent while the graph changes still reaches the right instrument. Safe from any thread.
    /// A live note for `track`. With `atHost` it sounds at that host time, to the sample, also when that
    /// is a few blocks away; a time already past sounds at once. Without it, at the top of the next block.
    public func sendLiveMIDI(track: TrackID, _ status: UInt8, _ data1: UInt8, _ data2: UInt8, atHost host: UInt64 = 0) {
        locked {
            guard liveCount < liveCapacity else { return }
            live[liveCount] = LiveMIDI(track: track, status: status, data1: data1, data2: data2, host: host)
            liveCount += 1
        }
    }

    /// Plays a live note in this block, or keeps it for a later one. Audio thread only.
    private func placeLive(_ e: LiveMIDI, renderer: Renderer, host: UInt64, frameCount: Int, sessionPosition: Int64, keep: inout Int) {
        var offset = 0
        if e.host != 0 {
            let frames = HostClock.frames(from: host, to: e.host, rate: sampleRate)
            if frames >= Int64(frameCount) {
                if keep < liveCapacity { livePending[keep] = e; keep += 1 }
                return
            }
            offset = Int(max(0, frames))
        }
        renderer.sendLive(track: e.track, e.status, e.data1, e.data2, sampleOffset: offset, host: offset > 0 ? e.host : 0)
    }
    public func setLoop(_ range: Range<Int64>?) { locked { loop = range } }

    /// Records the sound of `track` (after its fader) while the transport plays. The first recorded frame
    /// is in `CaptureWriter.Result.firstFrame`, on the timeline.
    public func startCapture(track: TrackID, into writer: CaptureWriter) {
        startCapture(CaptureSet([(track, writer)]))
    }

    /// Records several tracks at once, each after its fader. `nil` as the track is the master.
    public func startCapture(_ set: CaptureSet) {
        let old: CaptureSet? = locked { let old = captures; captures = set; return old }
        retire(old)
    }

    /// After this returns, the audio thread writes nothing more into the rings: it waits for the callback
    /// that may still hold them to end (one buffer at most).
    public func stopCapture() {
        let (old, started): (CaptureSet?, UInt64) = locked {
            let c = captures; captures = nil; return (c, callbacks)
        }
        var waited = 0
        // Two callbacks later, the renderer has also dropped its own reference to the rings.
        while engine.isRunning, locked({ callbacks }) <= started &+ 1, waited < 200 { usleep(1_000); waited += 1 }
        withExtendedLifetime(old) {}
    }

    /// The input that monitoring tracks play. `nil` when no track monitors the sound card.
    public func setInputMonitor(_ monitor: InputMonitor?) {
        let old: InputMonitor? = locked { let old = inputMonitor; inputMonitor = monitor; return old }
        if old !== monitor { retire(old) }
    }

    /// The built-in instrument that runs for a device, for its display (pad lights, the filter position).
    /// `nil` while no plan holds it.
    public func builtInInstrument(_ device: DeviceID) -> DSPInstrument? {
        locked { renderer?.instance(device) as? DSPInstrument }
    }

    /// The built-in effect that runs for a device, for its meters. `nil` while no plan holds it.
    public func builtInEffect(_ device: DeviceID) -> DSPEffect? {
        locked { renderer?.instance(device) }
    }

    /// The keys a track holds now (see `Renderer.heldMask`). For the key lights.
    public func heldNotes(track: TrackID) -> (low: UInt64, high: UInt64) {
        locked { renderer?.heldMask(track: track) ?? (0, 0) }
    }

    /// The peak of a node since the last call, left and right. For meters.
    public func takePeaks(node: Int) -> (left: Float, right: Float) {
        locked {
            guard node >= 0, 2 * node + 1 < meterCapacity else { return (0, 0) }
            let p = (meters[2 * node], meters[2 * node + 1])
            meters[2 * node] = 0; meters[2 * node + 1] = 0
            return p
        }
    }

    public func takePeak(node: Int) -> Float {
        let p = takePeaks(node: node)
        return max(p.left, p.right)
    }

    private func locked<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body()
    }

    // MARK: Audio thread

    func render(frameCount: Int, bufferList: UnsafeMutablePointer<AudioBufferList>, host: UInt64) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard buffers.count >= 2 else { return }

        // 1. Take the control state. Plain copies and reference counts only; nothing is allocated or freed.
        os_unfair_lock_lock(lock)
        callbacks &+= 1
        let host = smoothHost(host, frames: frameCount)
        // When the first frame of this buffer comes out of the speaker.
        let sounds = host &+ HostClock.ticks(fromSeconds: Double(outputLatency) / sampleRate)
        // A timed start: wait in silence for the frames up to that host time, then play. `sounds` is when
        // this buffer is heard, so the wait is exact to the frame.
        if startAtHost != 0 {
            let wait = HostClock.frames(from: sounds, to: startAtHost, rate: sampleRate)
            if wait > 0 { countInRemaining = wait; countInDone = 0; countInClick = false }
            else { playing = true; stampPending = true }
            startAtHost = 0
        }
        let renderer = self.renderer
        // No renderer yet (a sample-rate change): the handover waits, so its held notes get their note-offs.
        let previous = renderer == nil ? nil : handover
        if renderer != nil { handover = nil }
        let reset = resetPending, silence = silencePending
        resetPending = false; silencePending = false
        let captures = self.captures
        let monitor = inputMonitor
        let liveTakenCount = liveCount
        liveTaken.update(from: live, count: liveCount)
        liveCount = 0
        var playing = self.playing
        var position = self.position
        var sessionPosition = self.sessionPosition
        let loop = self.loop
        let click = self.click
        var countInRemaining = self.countInRemaining
        var countInDone = self.countInDone
        let countInClick = self.countInClick
        var stampPending = self.stampPending
        var startHost = self.startHost
        let clockGeneration = self.clockGeneration
        let stateGeneration = self.stateGeneration
        let sampleRate = self.sampleRate
        let routes = self.routes
        os_unfair_lock_unlock(lock)

        // Every channel starts silent. The master goes to its pair; with direct ports on, to the pair it is routed to.
        for b in 0..<buffers.count { buffers[b].mData?.assumingMemoryBound(to: Float.self).update(repeating: 0, count: frameCount) }
        let masterL = routes.multi && routes.masterLeft < buffers.count ? routes.masterLeft : 0
        let masterR = routes.multi && routes.masterRight < buffers.count ? routes.masterRight : 1
        guard let left = buffers[masterL].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[masterR].mData?.assumingMemoryBound(to: Float.self) else { return }
        /// Adds the direct ports of the last block to their channels. Without a route they play on the master pair.
        func addPorts(_ renderer: Renderer, offset: Int, frames n: Int) {
            guard renderer.portCount > 0 else { return }
            let ports = renderer.outputPorts
            for i in 0..<renderer.portCount {
                var pair = (masterL, masterR)
                if routes.multi, let route = routes.ports[ports[i]], route.0 < buffers.count, route.1 < buffers.count { pair = route }
                guard let l = buffers[pair.0].mData?.assumingMemoryBound(to: Float.self),
                      let r = buffers[pair.1].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let pl = renderer.portLeft(i), pr = renderer.portRight(i)
                for k in 0..<n { l[offset + k] += pl[k]; r[offset + k] += pr[k] }
            }
        }

        guard let renderer else { return }

        // 2. Render, with no lock held.
        renderer.midiOut = midiOut
        defer { midiOut.flush() }
        if let previous, previous !== renderer { previous.midiOut = midiOut; renderer.takeOverNotes(from: previous, at: position, sessionFrame: sessionPosition) }
        if reset { renderer.reset() } else if silence { renderer.silenceNotes() }
        renderer.captures = captures
        renderer.inputMonitor = monitor
        // Live notes: the ones that waited first, then the new ones, each at its sample. `keep` compacts
        // the waiting ones in place; it never passes the read index.
        var keep = 0
        let waiting = livePendingCount
        for i in 0..<waiting { placeLive(livePending[i], renderer: renderer, host: host, frameCount: frameCount, sessionPosition: sessionPosition, keep: &keep) }
        for i in 0..<liveTakenCount { placeLive(liveTaken[i], renderer: renderer, host: host, frameCount: frameCount, sessionPosition: sessionPosition, keep: &keep) }
        livePendingCount = keep

        // Stopped: no clips, but instruments and effects keep running, so live notes sound and tails ring out.
        // A count-in is the same, with a click, and it starts the transport when it ends.
        var done = 0
        while !playing && done < frameCount {
            var n = min(frameCount - done, renderer.maxBlock)
            if countInRemaining > 0 { n = Int(min(Int64(n), countInRemaining)) }
            renderer.process(startFrame: position, frames: n, transport: false, outLeft: left + done, outRight: right + done)
            addPorts(renderer, offset: done, frames: n)
            if countInRemaining > 0 {
                if countInClick { Self.addClick(left + done, right + done, n, clock: countInDone, click, sampleRate) }
                countInDone += Int64(n)
                countInRemaining -= Int64(n)
                if countInRemaining <= 0 {
                    countInRemaining = 0; playing = true
                    startHost = sounds &+ HostClock.ticks(fromSeconds: Double(done + n) / sampleRate)
                }
            }
            done += n
        }

        if stampPending && playing { startHost = sounds; stampPending = false }
        let anchorHost = sounds &+ HostClock.ticks(fromSeconds: Double(done) / sampleRate)
        let anchorFrame = sessionPosition
        while done < frameCount {
            var n = min(frameCount - done, renderer.maxBlock)
            if let loop, position < loop.upperBound {
                n = min(n, Int(loop.upperBound - position))
            }
            renderer.process(startFrame: position, sessionFrame: sessionPosition, frames: n, outLeft: left + done, outRight: right + done)
            addPorts(renderer, offset: done, frames: n)
            if click.enabled {
                if click.frames.isEmpty { Self.addClick(left + done, right + done, n, clock: position, click, sampleRate) }
                else { Self.addGridClick(left + done, right + done, n, clock: position, click, sampleRate) }
            }
            position += Int64(n)
            sessionPosition += Int64(n)
            done += n
            if let loop, position >= loop.upperBound { position = loop.lowerBound; renderer.releaseArrangementNotes() }
        }

        // 3. Write back what nobody changed meanwhile, and hand over the meter peaks.
        os_unfair_lock_lock(lock)
        if self.clockGeneration == clockGeneration {
            self.position = position
            self.sessionPosition = sessionPosition
            self.anchorHost = anchorHost
            self.anchorFrame = anchorFrame
        }
        if self.stateGeneration == stateGeneration {
            self.playing = playing
            self.countInRemaining = countInRemaining
            self.countInDone = countInDone
            self.stampPending = stampPending
            self.startHost = startHost
        }
        renderer.movePeaks(into: meters, capacity: meterCapacity)
        os_unfair_lock_unlock(lock)
    }

    /// Adds the click for `count` frames. `clock` is the frame count since a beat grid that starts at 0.
    /// The click on the beat grid: each sample sounds the latest beat at or before it.
    private static func addGridClick(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ count: Int,
                                     clock: Int64, _ c: Click, _ sampleRate: Double) {
        let length = Int64(sampleRate * 0.04)
        var lo = 0, hi = c.frames.count
        while lo < hi { let mid = (lo + hi) / 2; if c.frames[mid] <= clock { lo = mid + 1 } else { hi = mid } }
        var beat = lo - 1 // the latest beat at or before `clock`, or -1
        for i in 0..<count {
            let t = clock + Int64(i)
            while beat + 1 < c.frames.count && c.frames[beat + 1] <= t { beat += 1 }
            guard beat >= 0 else { continue }
            var offset = t - c.frames[beat]
            var accent = beat < c.accents.count && c.accents[beat]
            if beat == c.frames.count - 1, c.tailBeat > 0 {
                let k = offset / c.tailBeat
                offset -= k * c.tailBeat
                accent = (Int64(c.tailPhase) + k) % Int64(c.tailBar) == 0
            }
            guard offset < length else { continue }
            let phase = 2 * Double.pi * (accent ? 1_500 : 1_000) * Double(offset) / sampleRate
            let v = Float(sin(phase) * exp(-Double(offset) / (sampleRate * 0.008)) * 0.4)
            left[i] += v
            right[i] += v
        }
    }

    private static func addClick(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ count: Int,
                                 clock: Int64, _ c: Click, _ sampleRate: Double) {
        let length = Int64(sampleRate * 0.04)
        for i in 0..<count {
            let t = clock + Int64(i)
            let offset = t % c.beatFrames
            guard offset < length else { continue }
            let accent = (t / c.beatFrames) % Int64(c.beatsPerBar) == 0
            let phase = 2 * Double.pi * (accent ? 1_500 : 1_000) * Double(offset) / sampleRate
            let v = Float(sin(phase) * exp(-Double(offset) / (sampleRate * 0.008)) * 0.4)
            left[i] += v
            right[i] += v
        }
    }
}
