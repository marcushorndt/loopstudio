import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0
/// Apple's own General MIDI synth: an instrument that ships with macOS.
private let dls = "aumu/dls /appl"

/// A plugin inside a rack chain is hosted like one on the track: grouping a synth into a rack must not unload it.
@MainActor
@Test func anAudioUnitInsideARackLoadsAndSounds() async throws {
    var project = Project(name: "R", sampleRate: rate)
    let synth = DeviceSlot(format: "audiounit", identifier: dls, name: "DLS")
    var rack = BuiltInEffects.makeSlot("midirack")!
    rack.rack?.chains = [RackChain(name: "Keys", devices: [synth])]
    var track = Track(name: "Keys", kind: .midi, devices: [rack])
    track.clips = [.midi(MIDIClip(start: 0, length: 3840, notes: [MIDINote(tick: 0, length: 1920, pitch: 60, velocity: 100)]))]
    try Command.insertTrack(track: track, index: 0).apply(to: &project)

    let host = PluginHost()
    #expect(await host.sync(project: project), "the host found a plugin to load")
    #expect(host.failures.isEmpty, "\(host.failures)")
    #expect(host.units[synth.id] != nil, "the synth inside the rack is loaded")

    let plan = RenderPlan.compile(project, bank: AudioBank(), units: host.units)
    #expect(plan.warnings.isEmpty, "\(plan.warnings)")
    let audio = Bounce.render(plan, startFrame: 0, endFrame: Int64(rate))
    #expect(audio.peak > 0.01, "the synth in the rack made sound")

    // Its state is saved from inside the rack too.
    let states = host.states()
    #expect(states[synth.id] != nil)
}
