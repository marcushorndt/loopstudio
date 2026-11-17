import AVFoundation
import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

/// The gate and the phase of the fake effect's tone. The render block reads and writes it on the audio thread.
private final class ToneState: @unchecked Sendable {
    var gate: Float = 0
    var phase: Float = 0
}

/// A v3 music effect (`aumf`) with one input and one output, like a MIDI-controlled reverb: it passes its
/// input through and adds a 440 Hz tone while a note is held.
private final class ToneEffect: AUAudioUnit {
    private let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    private var inputArray: AUAudioUnitBusArray!
    private var outputArray: AUAudioUnitBusArray!
    private let state = ToneState()

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
        return { flags, timestamp, frames, _, output, events, pull in
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
            // The input goes straight into the output buffers; without an input the output starts silent.
            if let pull {
                _ = pull(flags, timestamp, frames, 0, output)
            } else {
                for b in buffers { b.mData?.assumingMemoryBound(to: Float.self).update(repeating: 0, count: Int(frames)) }
            }
            var phase = state.phase
            for i in 0..<Int(frames) {
                let v = state.gate * 0.5 * sinf(phase)
                phase += step
                if phase > 2 * .pi { phase -= 2 * .pi }
                for b in buffers { b.mData?.assumingMemoryBound(to: Float.self)[i] += v }
            }
            state.phase = phase
            return noErr
        }
    }

    static let description = AudioComponentDescription(
        componentType: kAudioUnitType_MusicEffect, componentSubType: 0x7466_7820 /* tfx */,
        componentManufacturer: 0x6c73_7473 /* lsts */, componentFlags: 0, componentFlagsMask: 0)

    nonisolated(unsafe) static var registered = false
    static func register() {
        guard !registered else { return }
        registered = true
        AUAudioUnit.registerSubclass(ToneEffect.self, as: description, name: "LoopStudio Tests: Tone Effect", version: 1)
    }
}

private func peak(_ audio: RenderedAudio, from: Double, to: Double) -> Float {
    let a = Int(from * rate), b = min(audio.frames, Int(to * rate))
    guard b > a else { return 0 }
    return max(audio.left[a..<b].reduce(0) { max($0, abs($1)) }, audio.right[a..<b].reduce(0) { max($0, abs($1)) })
}

/// Lemus handover P3-3: a music effect on a MIDI track gets the track's notes like an instrument would, in the
/// renderer and in the offline bounce. The clip holds one note in its second beat at 120 BPM: the first
/// second is silent, the second carries the tone, the third is silent again after the note-off.
@MainActor
@Test func aMusicEffectGetsTheNotesOfItsTrack() async throws {
    ToneEffect.register()
    let unit = try await AudioUnitEffect.instantiate(type: "aumf", subtype: "tfx ", manufacturer: "lsts", sampleRate: rate)
    #expect(!unit.isInstrument)
    #expect(unit.acceptsMIDI)

    var project = Project(name: "F", sampleRate: rate)
    let slot = DeviceSlot(format: "audiounit", identifier: "aumf/tfx /lsts", name: "Tone Effect")
    var track = Track(name: "Verb", kind: .midi, devices: [slot])
    track.clips = [.midi(MIDIClip(start: 0, length: 5760, notes: [MIDINote(tick: 1920, length: 1920, pitch: 60)]))]
    try Command.insertTrack(track: track, index: 0).apply(to: &project)

    let host = PluginHost()
    host.outOfProcess = false  // a subclass registered in this process lives only here
    #expect(await host.sync(project: project))
    #expect(host.failures.isEmpty, "\(host.failures)")
    let plan = RenderPlan.compile(project, bank: AudioBank(), units: host.units)
    #expect(plan.warnings.isEmpty, "a music effect counts as a note target: \(plan.warnings)")
    #expect(plan.nodes[0].midi.count == 2, "note-on and note-off are planned")
    // The fake effect gates at the start of the block that holds the event (a block is 85 ms), so the
    // edges get a margin of a tenth of a second.
    let audio = Bounce.render(plan, startFrame: 0, endFrame: Int64(3 * rate))
    #expect(peak(audio, from: 0, to: 0.9) < 0.001, "silent before the note")
    #expect(peak(audio, from: 1.1, to: 1.9) > 0.3, "the tone sounds while the note is held")
    #expect(peak(audio, from: 2.1, to: 3) < 0.001, "silent after the note-off")

    // The export path: its own plugin instances, the same notes.
    let prepared = await OfflineRender.prepare(project, bank: AudioBank())
    #expect(prepared.warnings.isEmpty, "\(prepared.warnings)")
    let bounced = Bounce.render(prepared.plan, startFrame: 0, endFrame: Int64(3 * rate))
    #expect(peak(bounced, from: 1.1, to: 1.9) > 0.3, "the bounce carries the tone")
    #expect(peak(bounced, from: 0, to: 0.9) < 0.001)
}

/// A live note reaches the effect while the transport is stopped, and its note-off ends the tone.
@MainActor
@Test func aMusicEffectTakesLiveNotesWhileStopped() async throws {
    ToneEffect.register()
    var project = Project(name: "F", sampleRate: rate)
    let track = Track(name: "Verb", kind: .midi, devices: [DeviceSlot(format: "audiounit", identifier: "aumf/tfx /lsts", name: "Tone Effect")])
    try Command.insertTrack(track: track, index: 0).apply(to: &project)
    let host = PluginHost()
    host.outOfProcess = false
    _ = await host.sync(project: project)
    let plan = RenderPlan.compile(project, bank: AudioBank(), units: host.units)
    let renderer = Renderer(plan: plan, maxBlock: 512)
    var l = [Float](repeating: 0, count: 512), r = [Float](repeating: 0, count: 512)
    func block(_ frame: Int64) -> Float {
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            renderer.process(startFrame: frame, frames: 512, transport: false, outLeft: lp.baseAddress!, outRight: rp.baseAddress!)
        } }
        return max(l.reduce(0) { max($0, abs($1)) }, r.reduce(0) { max($0, abs($1)) })
    }
    #expect(block(0) < 0.001, "quiet without a note")
    renderer.sendLive(track: track.id, 0x90, 60, 100)
    #expect(block(0) > 0.3, "a live note reaches the effect")
    renderer.sendLive(track: track.id, 0x80, 60, 0)
    #expect(block(0) < 0.001, "the live note-off ends the tone")
}
