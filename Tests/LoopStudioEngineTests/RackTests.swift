import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

private func peak(_ x: ArraySlice<Float>) -> Float { x.reduce(0) { max($0, abs($1)) } }
private func frame(_ seconds: Double) -> Int { Int(seconds * rate) }

/// One audio track with a 0.5 peak tone for 2 seconds, and a way to put racks in front of it.
private struct ToneRig {
    var project = Project(name: "R", sampleRate: rate)
    let bank = AudioBank()
    var track: Track

    init() {
        let n = Int(2 * rate)
        let samples = (0..<n).map { 0.5 * Float(sin(2 * .pi * 440 * Double($0) / rate)) }
        let asset = Asset(sha256: "r", name: "tone", frames: Int64(n), sampleRate: rate, channels: 2)
        try! Command.addAsset(asset: asset).apply(to: &project)
        bank.insert(PCMBuffer(samples: [samples, samples], sampleRate: rate), for: asset.id)
        var clip = project.makeAudioClip(asset: asset.id, start: 0, length: 3_840)
        clip.fadeInMs = 0; clip.fadeOutMs = 0
        track = Track(name: "T", kind: .audio, clips: [.audio(clip)])
        try! Command.insertTrack(track: track, index: 0).apply(to: &project)
    }

    /// Inserts an audio effect rack with one chain per gain value (a Utility set to that gain).
    mutating func rack(gains: [Double]) -> (DeviceSlot, [DeviceSlot]) {
        var rack = BuiltInEffects.makeSlot("audiorack")!
        var utilities: [DeviceSlot] = []
        rack.rack?.chains = gains.enumerated().map { i, g in
            var u = BuiltInEffects.makeSlot("utility")!
            u.params = ["gain": g]
            utilities.append(u)
            return RackChain(name: "Chain \(i + 1)", colorIndex: i, devices: [u])
        }
        try! Command.insertDevice(track: track.id, device: rack, index: nil).apply(to: &project)
        return (rack, utilities)
    }

    func render() -> RenderedAudio {
        let plan = RenderPlan.compile(project, bank: bank)
        #expect(plan.warnings.isEmpty, "\(plan.warnings)")
        return Bounce.render(plan, endFrame: Int64(1 * rate))
    }

    func steady(_ audio: RenderedAudio) -> Float { peak(audio.left[frame(0.3)..<frame(0.9)]) }
}

@Test func anAudioRackPassesItsChainThrough() {
    var rig = ToneRig()
    _ = rig.rack(gains: [-6.0206])
    #expect(abs(rig.steady(rig.render()) - 0.25) < 0.01, "one chain at -6 dB halves the tone")
}

@Test func chainZonesFollowTheSelector() {
    var rig = ToneRig()
    let (rack, _) = rig.rack(gains: [0, -6.0206])
    var chains = rack.rack!.chains
    chains[0].zone = ChainZone(low: 0, high: 63)
    chains[1].zone = ChainZone(low: 64, high: 127)
    for c in chains { try! Command.setChain(track: rig.track.id, rack: rack.id, chain: c).apply(to: &rig.project) }
    // Selector at 0: only the unity chain sounds.
    #expect(abs(rig.steady(rig.render()) - 0.5) < 0.01)
    // Selector at 127: only the -6 dB chain sounds.
    try! Command.setDeviceParam(track: rig.track.id, device: rack.id, key: "selector", value: 127).apply(to: &rig.project)
    #expect(abs(rig.steady(rig.render()) - 0.25) < 0.01)
    // A crossfade between the zones: both chains at reduced gain, the sum sits between them.
    chains[0].zone = ChainZone(low: 0, high: 127, fadeLow: 0, fadeHigh: 127)
    chains[1].zone = ChainZone(low: 0, high: 127, fadeLow: 127, fadeHigh: 0)
    for c in chains { try! Command.setChain(track: rig.track.id, rack: rack.id, chain: c).apply(to: &rig.project) }
    try! Command.setDeviceParam(track: rig.track.id, device: rack.id, key: "selector", value: 64).apply(to: &rig.project)
    let mid = rig.steady(rig.render())
    #expect(mid > 0.25 && mid < 0.5, "crossfade sum \(mid)")
}

@Test func aMutedChainIsSilentAndSoloHidesTheOthers() {
    var rig = ToneRig()
    let (rack, _) = rig.rack(gains: [0, 0])
    var chains = rack.rack!.chains
    chains[0].mute = true
    try! Command.setChain(track: rig.track.id, rack: rack.id, chain: chains[0]).apply(to: &rig.project)
    #expect(abs(rig.steady(rig.render()) - 0.5) < 0.01, "one of two unity chains muted: the other alone")
    chains[0].mute = false; chains[0].volumeDb = -60; chains[0].solo = true
    try! Command.setChain(track: rig.track.id, rack: rack.id, chain: chains[0]).apply(to: &rig.project)
    #expect(rig.steady(rig.render()) < 0.01, "solo on the quiet chain hides the loud one")
}

@Test func aMacroDrivesAParameterInsideTheRack() {
    var rig = ToneRig()
    let (rack, utilities) = rig.rack(gains: [0])
    let gain = BuiltInEffects.spec("utility")!.param("gain")!
    // Macro 1 maps the Utility gain from unity down to -6 dB over its range (inverted: max below min).
    let mapping = MacroMapping(macro: 0, target: ParameterAddress(node: utilities[0].id.rawValue, parameter: "gain"),
                               min: gain.position(0), max: gain.position(-6.0206))
    try! Command.setMacroMapping(track: rig.track.id, rack: rack.id, mapping: mapping).apply(to: &rig.project)
    #expect(abs(rig.steady(rig.render()) - 0.5) < 0.01, "macro at 0: unity")
    try! Command.setDeviceParam(track: rig.track.id, device: rack.id, key: "macro1", value: 127).apply(to: &rig.project)
    #expect(abs(rig.steady(rig.render()) - 0.25) < 0.01, "macro at 127: -6 dB")
    // The model agrees on what the macro gives.
    let track = rig.project.track(rig.track.id)!
    let driven = rig.project.macroDriving(mapping.target, on: track)
    let drivenValue = driven?.value ?? .nan
    #expect(abs(drivenValue + 6.0206) < 0.05, "\(drivenValue)")
    // One macro per parameter: a second mapping of the same target is refused.
    let again = MacroMapping(macro: 1, target: mapping.target)
    #expect(throws: CommandError.self) {
        try Command.setMacroMapping(track: rig.track.id, rack: rack.id, mapping: again).apply(to: &rig.project)
    }
}

@Test func aRackInsideARackStillSounds() {
    var rig = ToneRig()
    let (outer, _) = rig.rack(gains: [0])
    let chain = outer.rack!.chains[0].id
    var inner = BuiltInEffects.makeSlot("audiorack")!
    var u = BuiltInEffects.makeSlot("utility")!
    u.params = ["gain": -6.0206]
    inner.rack?.chains = [RackChain(name: "Inner", devices: [u])]
    try! Command.insertDeviceInChain(track: rig.track.id, chain: chain, device: inner, index: nil).apply(to: &rig.project)
    #expect(abs(rig.steady(rig.render()) - 0.25) < 0.01)
    // Removing the outer rack takes the inner one and its devices with it.
    try! Command.removeDevice(track: rig.track.id, device: outer.id).apply(to: &rig.project)
    #expect(rig.project.track(rig.track.id)!.allDevices.isEmpty)
}

@Test func aMIDIRackRoutesNotesByKeyZone() {
    var project = Project(name: "M", sampleRate: rate)
    let t = Track(name: "Synth", kind: .midi)
    try! Command.insertTrack(track: t, index: 0).apply(to: &project)
    var rack = BuiltInEffects.makeSlot("midirack")!
    var low = BuiltInEffects.makeSlot("acid")!, high = BuiltInEffects.makeSlot("acid")!
    low.params = ["drive": 0]; high.params = ["drive": 0]
    rack.rack?.chains = [
        RackChain(name: "Low", devices: [low], keyZone: ChainZone(low: 0, high: 47)),
        RackChain(name: "High", devices: [high], volumeDb: -60, keyZone: ChainZone(low: 48, high: 127)),
    ]
    try! Command.insertDevice(track: t.id, device: rack, index: 0).apply(to: &project)
    func play(_ pitch: UInt8) -> Float {
        var p = project
        let clip = MIDIClip(start: 0, length: Tick(3840), notes: [MIDINote(tick: Tick(0), length: Tick(1920), pitch: pitch, velocity: 100)])
        try! Command.insertClip(track: t.id, clip: .midi(clip)).apply(to: &p)
        let plan = RenderPlan.compile(p, bank: AudioBank())
        #expect(plan.warnings.isEmpty, "\(plan.warnings)")
        let out = Bounce.render(plan, endFrame: Int64(1 * rate))
        return peak(out.left[frame(0.1)..<frame(0.5)])
    }
    #expect(play(40) > 0.02, "a low note plays the loud chain")
    #expect(play(60) < 0.002, "a high note reaches only the quiet chain")
}
