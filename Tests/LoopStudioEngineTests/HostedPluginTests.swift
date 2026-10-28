import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

/// Apple's own General MIDI synth: an instrument that ships with macOS.
private let dls = "aumu/dls /appl"
private let delayUnit = "aufx/dely/appl"

private func audioUnitSlot(_ id: String, _ name: String) -> DeviceSlot {
    DeviceSlot(format: "audiounit", identifier: id, name: name)
}

@MainActor
@Test func instrumentPlaysNotesFromAMIDIClip() async throws {
    var project = Project(name: "M", sampleRate: rate)
    let slot = audioUnitSlot(dls, "DLS")
    var track = Track(name: "Keys", kind: .midi, devices: [slot])
    let notes = [MIDINote(tick: 0, length: 960, pitch: 60), MIDINote(tick: 960, length: 960, pitch: 64)]
    track.clips = [.midi(MIDIClip(start: 0, length: 3840, notes: notes))]
    try Command.insertTrack(track: track, index: 0).apply(to: &project)

    let host = PluginHost()
    #expect(await host.sync(project: project))
    #expect(host.failures.isEmpty, "\(host.failures)")
    let plan = RenderPlan.compile(project, bank: AudioBank(), units: host.units)
    let audio = Bounce.render(plan, startFrame: 0, endFrame: Int64(2 * rate))
    #expect(audio.peak > 0.01, "the synth made sound")
    #expect(!audio.left.contains { $0.isNaN })
}

@MainActor
@Test func silentWithoutNotes() async throws {
    var project = Project(name: "M", sampleRate: rate)
    let track = Track(name: "Keys", kind: .midi, clips: [.midi(MIDIClip(start: 0, length: 3840))], devices: [audioUnitSlot(dls, "DLS")])
    try Command.insertTrack(track: track, index: 0).apply(to: &project)
    let host = PluginHost()
    _ = await host.sync(project: project)
    let audio = Bounce.render(RenderPlan.compile(project, bank: AudioBank(), units: host.units), endFrame: Int64(rate))
    #expect(audio.peak < 0.001)
}

@MainActor
@Test func hostedEffectChangesAnAudioTrack() async throws {
    var project = Project(name: "E", sampleRate: rate)
    let bank = AudioBank()
    let samples = (0..<Int(rate)).map { 0.4 * Float(sin(2 * .pi * 440 * Double($0) / rate)) }
    let asset = Asset(sha256: "x", name: "tone", frames: Int64(samples.count), sampleRate: rate, channels: 2)
    try Command.addAsset(asset: asset).apply(to: &project)
    bank.insert(PCMBuffer(samples: [samples, samples], sampleRate: rate), for: asset.id)
    var clip = project.makeAudioClip(asset: asset.id, start: 0, length: 1920)
    clip.fadeInMs = 0; clip.fadeOutMs = 0
    let track = Track(name: "A", kind: .audio, clips: [.audio(clip)])
    try Command.insertTrack(track: track, index: 0).apply(to: &project)
    let dry = Bounce.render(RenderPlan.compile(project, bank: bank), endFrame: Int64(1.5 * rate))

    try Command.insertDevice(track: track.id, device: audioUnitSlot(delayUnit, "Delay"), index: nil).apply(to: &project)
    let host = PluginHost()
    _ = await host.sync(project: project)
    #expect(host.failures.isEmpty, "\(host.failures)")
    let wet = Bounce.render(RenderPlan.compile(project, bank: bank, units: host.units), endFrame: Int64(1.5 * rate))
    // The AU delay repeats the tone after the clip ends, so the tail is louder than in the dry render.
    let tail = Int(1.1 * rate)..<Int(1.5 * rate)
    #expect(wet.left[tail].reduce(0) { max($0, abs($1)) } > dry.left[tail].reduce(0) { max($0, abs($1)) } + 0.01)
}

@MainActor
@Test func missingPluginIsReportedNotFatal() async {
    var project = Project(name: "X", sampleRate: rate)
    let track = Track(name: "A", kind: .audio, devices: [audioUnitSlot("aufx/nope/none", "Ghost")])
    try! Command.insertTrack(track: track, index: 0).apply(to: &project)
    let host = PluginHost()
    _ = await host.sync(project: project)
    #expect(host.units.isEmpty && host.failures.count == 1)
    let plan = RenderPlan.compile(project, bank: AudioBank(), units: host.units)
    #expect(plan.warnings.contains { $0.contains("Ghost") })
}

@Test func stateRoundTrips() async throws {
    let unit = try await AudioUnitEffect.instantiate(identifier: delayUnit, sampleRate: rate)
    let data = try #require(unit.savedState())
    unit.restore(state: data)
    #expect(unit.savedState() != nil)
}

@MainActor
@Test func liveNotesSoundWhileTheTransportIsStopped() async throws {
    var project = Project(name: "L", sampleRate: rate)
    let track = Track(name: "Keys", kind: .midi, devices: [audioUnitSlot(dls, "DLS")])
    try Command.insertTrack(track: track, index: 0).apply(to: &project)
    let host = PluginHost()
    _ = await host.sync(project: project)
    let renderer = Renderer(plan: RenderPlan.compile(project, bank: AudioBank(), units: host.units), maxBlock: 512)

    var l = [Float](repeating: 0, count: 512), r = l
    renderer.sendLive(node: 0, 0x90, 60, 100)
    var peak: Float = 0
    for _ in 0..<20 {
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            renderer.process(startFrame: 0, frames: 512, transport: false, outLeft: lp.baseAddress!, outRight: rp.baseAddress!)
        } }
        peak = max(peak, l.reduce(0) { max($0, abs($1)) })
    }
    #expect(peak > 0.005, "a live note makes sound with the transport stopped")
}

@MainActor
@Test func automationMovesAHostedPluginParameter() async throws {
    var project = Project(name: "P", sampleRate: rate)
    let bank = AudioBank()
    let samples = (0..<Int(rate)).map { 0.4 * Float(sin(2 * .pi * 440 * Double($0) / rate)) }
    let asset = Asset(sha256: "y", name: "tone", frames: Int64(samples.count), sampleRate: rate, channels: 2)
    try Command.addAsset(asset: asset).apply(to: &project)
    bank.insert(PCMBuffer(samples: [samples, samples], sampleRate: rate), for: asset.id)
    var clip = project.makeAudioClip(asset: asset.id, start: 0, length: 1920)
    clip.fadeInMs = 0; clip.fadeOutMs = 0
    let track = Track(name: "A", kind: .audio, clips: [.audio(clip)])
    try Command.insertTrack(track: track, index: 0).apply(to: &project)
    let slot = audioUnitSlot(delayUnit, "Delay")
    try Command.insertDevice(track: track.id, device: slot, index: nil).apply(to: &project)

    let host = PluginHost()
    _ = await host.sync(project: project)
    let unit = try #require(host.units[slot.id])
    let params = unit.automatableParameters()
    let mix = try #require(params.first { $0.name.localizedCaseInsensitiveContains("dry") || $0.name.localizedCaseInsensitiveContains("mix") })
    try Command.setPluginParams(track: track.id, device: slot.id, params: params).apply(to: &project)
    #expect(project.automationTargets(of: project.track(track.id)!).contains { $0.address.parameter == mix.key })

    // Wet/dry held at fully dry: the delay leaves no tail after the clip ends.
    try Command.setAutomation(track: track.id, target: ParameterAddress(node: slot.id.rawValue, parameter: mix.key),
                              points: [AutomationPoint(tick: 0, value: mix.min)]).apply(to: &project)
    let audio = Bounce.render(RenderPlan.compile(project, bank: bank, units: host.units), endFrame: Int64(1.5 * rate))
    let tail = Int(1.1 * rate)..<Int(1.5 * rate)
    #expect(audio.left[tail].reduce(0) { max($0, abs($1)) } < 0.01)
}
