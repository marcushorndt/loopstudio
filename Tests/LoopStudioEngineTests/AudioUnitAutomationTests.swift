import AudioToolbox
import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

/// A project with one audio track, a noise clip of two seconds (3840 ticks at 120 BPM) and Apple's
/// low-pass filter on the track. The cutoff is the parameter the tests automate.
private struct FilterRig {
    var project = Project(name: "A", sampleRate: rate)
    let bank = AudioBank()
    let track: TrackID
    let device: DeviceSlot
    let unit: AudioUnitEffect
    let cutoff: PluginParam
    let asset: AssetID

    init() async throws {
        unit = try await AudioUnitEffect.instantiate(type: "aufx", subtype: "lpas", manufacturer: "appl", sampleRate: rate)
        let params = unit.automatableParameters()
        cutoff = try #require(params.first { $0.name.lowercased().contains("cutoff") })
        var slot = DeviceSlot(format: "audiounit", identifier: "aufx/lpas/appl", name: "Low-pass")
        slot.pluginParams = params
        device = slot
        var t = Track(name: "T", kind: .audio)
        t.devices = [slot]
        track = t.id
        try Command.insertTrack(track: t, index: 0).apply(to: &project)
        // White noise (a fixed generator): its energy is spread over the whole band, so a low cutoff takes
        // nearly all of it away, and the default cutoff of the filter still takes a good part.
        let n = Int(2 * rate)
        var seed: UInt32 = 12345
        let samples = (0..<n).map { _ -> Float in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.8
        }
        let asset = Asset(sha256: UUID().uuidString, name: "noise", frames: Int64(n), sampleRate: rate, channels: 2)
        try Command.addAsset(asset: asset).apply(to: &project)
        bank.insert(PCMBuffer(samples: [samples, samples], sampleRate: rate), for: asset.id)
        self.asset = asset.id
    }

    var address: ParameterAddress { ParameterAddress(node: device.id.rawValue, parameter: cutoff.key) }

    /// Open at the start, down to 150 Hz by the middle, and held there to the end of the two seconds.
    var sweep: [AutomationPoint] {
        [AutomationPoint(tick: 0, value: cutoff.max), AutomationPoint(tick: 1920, value: 150), AutomationPoint(tick: 3840, value: 150)]
    }

    mutating func arrangementClip() throws {
        var c = project.makeAudioClip(asset: asset, start: 0, length: 3840)
        c.fadeInMs = 0; c.fadeOutMs = 0
        try Command.insertClip(track: track, clip: .audio(c)).apply(to: &project)
    }
}

private func energy(_ out: RenderedAudio, from: Double, to: Double) -> Float {
    let a = Int(from * rate), b = Int(to * rate)
    return (a..<b).reduce(Float(0)) { $0 + out.left[$1] * out.left[$1] } / Float(b - a)
}

/// The filter itself: with no automation at all, its default cutoff already takes energy from the noise.
/// A render that leaves the input untouched would mean the plugin is not in the chain.
@Test func thePluginIsInTheChainWithoutAutomation() async throws {
    var rig = try await FilterRig()
    try rig.arrangementClip()
    let plan = RenderPlan.compile(rig.project, bank: rig.bank, units: [rig.device.id: rig.unit])
    let out = Bounce.render(plan, startFrame: 0, endFrame: 96_000, block: 512)
    let input = Float(0.8 * 0.8 / 12)
    let e = energy(out, from: 0.5, to: 1.5)
    #expect(e < input * 0.8, "the default cutoff of \(rig.cutoff.def) Hz takes energy: \(e) against \(input) in")
    #expect(plan.warnings.isEmpty, "\(plan.warnings)")
}

/// The cutoff moves with a track lane: the renderer schedules the curve into the plugin.
@Test func aTrackLaneMovesAPluginParameter() async throws {
    var rig = try await FilterRig()
    try rig.arrangementClip()
    try Command.setAutomation(track: rig.track, target: rig.address, points: rig.sweep).apply(to: &rig.project)
    let plan = RenderPlan.compile(rig.project, bank: rig.bank, units: [rig.device.id: rig.unit])
    let out = Bounce.render(plan, startFrame: 0, endFrame: 96_000, block: 512)
    let open = energy(out, from: 0.1, to: 0.4), closed = energy(out, from: 1.6, to: 1.9)
    #expect(open > 0.02, "the filter is open at the start: \(open)")
    #expect(closed < open / 4, "the filter has closed at the end: \(closed) against \(open)")
}

/// The cutoff moves with the lane of a session clip: the curve is planned on the session clock and reaches
/// the plugin the same way.
@Test func aSessionClipLaneMovesAPluginParameter() async throws {
    var rig = try await FilterRig()
    var c = rig.project.makeAudioClip(asset: rig.asset, start: 0, length: 3840)
    c.fadeInMs = 0; c.fadeOutMs = 0; c.loop = true
    c.lanes = [AutomationLane(target: rig.address, points: rig.sweep)]
    try Command.setSlot(track: rig.track, index: 0, slot: SessionSlot(clip: .audio(c), quantize: .none)).apply(to: &rig.project)
    try Command.setLaunches(launches: [Launch(track: rig.track, slot: 0, tick: 0)]).apply(to: &rig.project)
    let plan = RenderPlan.compile(rig.project, bank: rig.bank, session: SessionSimulator.run(rig.project, horizon: 3_840),
                                  units: [rig.device.id: rig.unit])
    let out = Bounce.render(plan, startFrame: 0, endFrame: 96_000, block: 512)
    let open = energy(out, from: 0.1, to: 0.4), closed = energy(out, from: 1.6, to: 1.9)
    #expect(open > 0.02, "the filter is open at the start: \(open)")
    #expect(closed < open / 4, "the filter has closed at the end: \(closed) against \(open)")
}

/// A version 2 plugin built with JUCE (the Lemus machines) drops ramped parameter events and takes immediate
/// ones. The renderer sends immediate events. This test needs the Lemus 303 and a saved state of it (the
/// `state` of its device in a project's track file, base64-decoded) in `R303_STATE`; without them it passes
/// and does nothing. A MIDI track with the 303, a session clip with notes and a cutoff lane that jumps from
/// closed to open at the middle: the two halves must differ.
@Test func aSessionClipLaneMovesTheLemus303() async throws {
    guard let path = ProcessInfo.processInfo.environment["R303_STATE"], let state = FileManager.default.contents(atPath: path) else { return }
    let unit = try await AudioUnitEffect.instantiate(type: "aumu", subtype: "R303", manufacturer: "Lmus", sampleRate: rate)
    unit.restore(state: state)
    var project = Project(name: "L", sampleRate: rate)
    var slot = DeviceSlot(format: "audiounit", identifier: "aumu/R303/Lmus", name: "ro-mono-303", state: state)
    slot.pluginParams = unit.automatableParameters()
    var t = Track(name: "303", kind: .midi)
    t.devices = [slot]
    try Command.insertTrack(track: t, index: 0).apply(to: &project)
    var clip = MIDIClip(start: 0, length: 3840, loop: true,
                        notes: (0..<16).map { MIDINote(tick: Tick(Int64($0) * 240), length: 170, pitch: 45, velocity: 110) })
    let cutoff = ParameterAddress(node: slot.id.rawValue, parameter: "au.3384258")
    clip.lanes = [AutomationLane(target: cutoff, points: [AutomationPoint(tick: 0, value: 0), AutomationPoint(tick: 1919, value: 0),
                                                          AutomationPoint(tick: 1920, value: 1), AutomationPoint(tick: 3840, value: 1)])]
    try Command.setSlot(track: t.id, index: 0, slot: SessionSlot(clip: .midi(clip), quantize: .none)).apply(to: &project)
    try Command.setLaunches(launches: [Launch(track: t.id, slot: 0, tick: 0)]).apply(to: &project)
    let plan = RenderPlan.compile(project, bank: AudioBank(), session: SessionSimulator.run(project, horizon: 3_840), units: [slot.id: unit])
    let out = Bounce.render(plan, startFrame: 0, endFrame: 96_000, block: 512)
    let closed = energy(out, from: 0.2, to: 0.9), open = energy(out, from: 1.2, to: 1.9)
    #expect(open > closed * 1.3, "the open half is louder: \(open) against \(closed)")
}
