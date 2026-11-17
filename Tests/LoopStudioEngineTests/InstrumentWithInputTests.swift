import AVFoundation
import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

/// The notes and the phase of the fake synth. The render block reads and writes it on the audio thread.
private final class SynthState: @unchecked Sendable {
    var gate: Float = 0
    var phase: Float = 0
}

/// A v3 instrument with one audio input bus, like a synth with an external-in jack: on a note-on it plays a
/// tone, on a note-off it stops. It never reads its input.
private final class SynthWithInput: AUAudioUnit {
    private let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    private var inputArray: AUAudioUnitBusArray!
    private var outputArray: AUAudioUnitBusArray!
    private let state = SynthState()

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        inputArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [try AUAudioUnitBus(format: format)])
        outputArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [try AUAudioUnitBus(format: format)])
    }

    override var inputBusses: AUAudioUnitBusArray { inputArray }
    override var outputBusses: AUAudioUnitBusArray { outputArray }

    override var internalRenderBlock: AUInternalRenderBlock {
        let state = self.state
        let step = Float(2 * Double.pi * 440 / rate)
        return { _, _, frames, _, output, events, _ in
            var event = events
            while let e = event {
                if e.pointee.head.eventType == .MIDI {
                    let m = e.pointee.MIDI
                    if m.data.0 & 0xF0 == 0x90, m.data.2 > 0 { state.gate = 1 }
                    else if m.data.0 & 0xF0 == 0x80 || m.data.0 & 0xF0 == 0x90 { state.gate = 0 }
                }
                event = UnsafePointer(e.pointee.head.next)
            }
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            var phase = state.phase
            for i in 0..<Int(frames) {
                let v = state.gate * 0.5 * sinf(phase)
                phase += step
                if phase > 2 * .pi { phase -= 2 * .pi }
                for b in buffers { b.mData?.assumingMemoryBound(to: Float.self)[i] = v }
            }
            state.phase = phase
            return noErr
        }
    }

    static let description = AudioComponentDescription(
        componentType: kAudioUnitType_MusicDevice, componentSubType: 0x7473_796E /* tsyn */,
        componentManufacturer: 0x6c73_7473 /* lsts */, componentFlags: 0, componentFlagsMask: 0)

    nonisolated(unsafe) static var registered = false
    static func register() {
        guard !registered else { return }
        registered = true
        AUAudioUnit.registerSubclass(SynthWithInput.self, as: description, name: "LoopStudio Tests: Synth With Input", version: 1)
    }
}

/// Lemus handover P1-1: a synth with an audio input bus (the Virus C and its EXT IN) is an instrument. The
/// engine must take it from the component type, not from the bus count, or the track plays nothing.
@MainActor
@Test func aSynthWithAnInputBusIsAnInstrumentAndGetsTheNotes() async throws {
    SynthWithInput.register()
    let unit = try await AudioUnitEffect.instantiate(type: "aumu", subtype: "tsyn", manufacturer: "lsts", sampleRate: rate)
    #expect(unit.unit.inputBusses.count == 1)
    #expect(unit.isInstrument)

    var project = Project(name: "V", sampleRate: rate)
    let slot = DeviceSlot(format: "audiounit", identifier: "aumu/tsyn/lsts", name: "Synth With Input")
    var track = Track(name: "Keys", kind: .midi, devices: [slot])
    track.clips = [.midi(MIDIClip(start: 0, length: 3840, notes: [MIDINote(tick: 0, length: 1920, pitch: 60)]))]
    try Command.insertTrack(track: track, index: 0).apply(to: &project)

    let host = PluginHost()
    host.outOfProcess = false  // a subclass registered in this process lives only here
    #expect(await host.sync(project: project))
    #expect(host.failures.isEmpty, "\(host.failures)")
    let plan = RenderPlan.compile(project, bank: AudioBank(), units: host.units)
    #expect(plan.warnings.isEmpty, "\(plan.warnings)")
    let audio = Bounce.render(plan, startFrame: 0, endFrame: Int64(rate))
    #expect(audio.peak > 0.1, "the synth played the clip's note")
}

/// Lemus handover P1-2: the machines read their ROMs from `~/Library/Application Support/Lemus/ROMs`. This
/// loads the 303 and the Virus C the way the app does, out of process, and plays notes at real-time pace
/// for twelve seconds each. The Virus C runs only with its ROM, so sound proves the hosting process may
/// read the folder. It boots its firmware on a thread of its own, so a faster-than-real-time render gives
/// silence until the boot is done: that is why this test keeps wall-clock time. It takes half a minute,
/// so it runs only with `LOOPSTUDIO_LEMUS=1`.
@MainActor
@Test func theLemusMachinesPlayOutOfProcess() async throws {
    guard ProcessInfo.processInfo.environment["LOOPSTUDIO_LEMUS"] == "1" else { return }
    for identifier in ["aumu/R303/Lmus", "aumu/Avrc/Lmus"] {
        guard AudioUnitCatalog.list().contains(where: { $0.identifier == identifier }) else { continue }
        let unit = try await AudioUnitEffect.instantiate(identifier: identifier, sampleRate: rate, outOfProcess: true)
        #expect(unit.isOutOfProcess)
        #expect(unit.isInstrument)
        let frames = 512
        let zero = [Float](repeating: 0, count: frames)
        let o0 = UnsafeMutablePointer<Float>.allocate(capacity: frames), o1 = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { o0.deallocate(); o1.deallocate() }
        let blockSeconds = Double(frames) / rate
        var peakBefore: Float = 0, peakWithNotes: Float = 0, blocks = 0
        let wall = Date()
        while Date().timeIntervalSince(wall) < 12 {
            let t = Double(blocks) * blockSeconds
            if blocks == Int(4 / blockSeconds) { unit.sendMIDI(0x90, 48, 100) }
            _ = zero.withUnsafeBufferPointer { z in
                let ins: [UnsafePointer<Float>] = [z.baseAddress!, z.baseAddress!]
                let outs: [UnsafeMutablePointer<Float>] = [o0, o1]
                return ins.withUnsafeBufferPointer { i in outs.withUnsafeBufferPointer { o in unit.process(frames: frames, input: i.baseAddress!, output: o.baseAddress!) } }
            }
            var peak: Float = 0
            for k in 0..<frames { peak = max(peak, abs(o0[k]), abs(o1[k])) }
            if t < 4 { peakBefore = max(peakBefore, peak) } else if t > 6 { peakWithNotes = max(peakWithNotes, peak) }
            blocks += 1
            let wait = wall.addingTimeInterval(Double(blocks) * blockSeconds).timeIntervalSinceNow
            if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
        }
        unit.sendMIDI(0xB0, 123, 0)
        #expect(peakBefore < 0.001, "\(identifier) is quiet before the note")
        #expect(peakWithNotes > 0.001, "\(identifier) plays the note out of process")
    }
}
