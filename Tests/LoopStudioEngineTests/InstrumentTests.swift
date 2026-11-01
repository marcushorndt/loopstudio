import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

/// A note script for an instrument: (frame, status, data1, data2).
private typealias Script = [(Int, UInt8, UInt8, UInt8)]

/// Renders `seconds` of an instrument with the messages of `script`, in blocks of `block` frames. Returns the left channel.
private func play(_ id: String, _ params: [String: Double] = [:], _ script: Script, seconds: Double, block: Int = 256) -> [Float] {
    let synth = DSPEffect.make(id, sampleRate: rate) as! DSPInstrument
    synth.configure(params)
    let n = Int(seconds * rate)
    var l = [Float](repeating: 0, count: n), r = l
    var done = 0
    while done < n {
        let count = min(block, n - done)
        for e in script where e.0 >= done && e.0 < done + count { synth.sendMIDI(e.1, e.2, e.3, sampleOffset: e.0 - done) }
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            synth.render(lp.baseAddress! + done, rp.baseAddress! + done, frames: count)
        } }
        done += count
    }
    return l
}

private func rms(_ x: ArraySlice<Float>) -> Float {
    guard !x.isEmpty else { return 0 }
    return (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
}

private func peak(_ x: ArraySlice<Float>) -> Float { x.reduce(0) { max($0, abs($1)) } }

/// The frequency of a periodic signal from its upward zero crossings.
private func frequency(_ x: ArraySlice<Float>) -> Double {
    var crossings = 0
    var last = x.first ?? 0
    for v in x.dropFirst() {
        if last <= 0, v > 0 { crossings += 1 }
        last = v
    }
    return Double(crossings) / (Double(x.count) / rate)
}

/// How much of the signal is high-frequency: the level of its first difference against its own level.
private func brightness(_ x: ArraySlice<Float>) -> Float {
    let diff = zip(x.dropFirst(), x).map { $0 - $1 }
    return rms(diff[...]) / max(rms(x), 1e-9)
}

private func frame(_ seconds: Double) -> Int { Int(seconds * rate) }

@Test func everyInstrumentHasDSPAndDefaultsInRange() {
    for spec in BuiltInInstruments.all {
        let dsp = DSPEffect.make(spec.id, sampleRate: rate)
        #expect(dsp is DSPInstrument, "\(spec.id)")
        #expect(spec.isInstrument)
        for p in spec.params { #expect(p.min <= p.def && p.def <= p.max, "\(spec.id).\(p.key) default in range") }
    }
    #expect(BuiltInEffects.spec("acid")?.isInstrument == true, "the shared lookup finds instruments")
    #expect(BuiltInEffects.makeSlot("drum808")?.name == "808 Drums")
}

// MARK: Acid Bass

@Test func acidPlaysThePitchOfTheNote() {
    // A2 is 110 Hz. The filter wide open and no resonance, so the saw keeps one crossing per period.
    let out = play("acid", ["cutoff": 18_000, "resonance": 0, "envMod": 0, "drive": 0, "accent": 0],
                   [(0, 0x90, 45, 90)], seconds: 1)
    let hz = frequency(out[frame(0.5)...])
    #expect(abs(hz - 110) < 3, "\(hz) Hz")
    #expect(peak(out[frame(0.1)...]) > 0.05)
}

@Test func acidTuneMovesThePitch() {
    let out = play("acid", ["cutoff": 18_000, "resonance": 0, "envMod": 0, "drive": 0, "tune": 12],
                   [(0, 0x90, 45, 90)], seconds: 1)
    let hz = frequency(out[frame(0.5)...])
    #expect(abs(hz - 220) < 5, "\(hz) Hz")
}

@Test func acidFilterEnvelopeClosesOverTheDecay() {
    let out = play("acid", ["cutoff": 150, "resonance": 0.2, "envMod": 1, "decay": 200, "drive": 0, "accent": 0],
                   [(0, 0x90, 36, 90)], seconds: 1.5)
    let early = brightness(out[frame(0.01)..<frame(0.04)])
    let late = brightness(out[frame(0.9)..<frame(1.0)])
    #expect(early > late * 1.5, "early \(early) late \(late)")
    #expect(peak(out[frame(0.9)...]) > 0.01, "the note still sounds while held")
}

@Test func acidNoteOffReleasesTheSound() {
    let out = play("acid", ["cutoff": 2_000, "drive": 0], [(0, 0x90, 40, 90), (frame(0.5), 0x80, 40, 0)], seconds: 1)
    #expect(peak(out[frame(0.4)..<frame(0.5)]) > 0.02)
    #expect(peak(out[frame(0.6)...]) < 0.002, "silent 100 ms after the release")
}

@Test func acidAccentIsLouderAndFixedInDecay() {
    let soft = play("acid", ["cutoff": 1_000, "drive": 0, "accent": 1], [(0, 0x90, 40, 80)], seconds: 0.4)
    let hard = play("acid", ["cutoff": 1_000, "drive": 0, "accent": 1], [(0, 0x90, 40, 127)], seconds: 0.4)
    #expect(peak(hard[frame(0.02)..<frame(0.2)]) > peak(soft[frame(0.02)..<frame(0.2)]) * 1.2)
    let off = play("acid", ["cutoff": 1_000, "drive": 0, "accent": 0], [(0, 0x90, 40, 127)], seconds: 0.4)
    #expect(abs(peak(off[frame(0.1)...]) - peak(soft[frame(0.1)...])) < 0.05, "with the accent knob at zero, velocity does nothing")
}

@Test func acidOverlappingNotesSlideWithoutARetrigger() {
    // The second note starts before the first ends: the pitch glides, the sound never stops.
    let script: Script = [(0, 0x90, 36, 90), (frame(0.5), 0x90, 48, 90), (frame(0.55), 0x80, 36, 0)]
    let out = play("acid", ["cutoff": 18_000, "resonance": 0, "envMod": 0, "drive": 0, "slide": 60], script, seconds: 1.4)
    let before = frequency(out[frame(0.3)..<frame(0.5)])
    let after = frequency(out[frame(1.0)..<frame(1.4)])
    #expect(abs(before - 65.4) < 3, "\(before) Hz")
    #expect(abs(after - 130.8) < 4, "\(after) Hz")
    // No dip: every 10 ms window across the change keeps its level.
    var k = frame(0.45)
    while k < frame(0.7) {
        #expect(rms(out[k..<(k + 480)]) > 0.02, "level at \(Double(k) / rate) s")
        k += 480
    }
    // Separate notes retrigger: the second starts from the attack, so there is a short dip in between.
    let apart = play("acid", ["cutoff": 18_000, "resonance": 0, "envMod": 0, "drive": 0],
                     [(0, 0x90, 36, 90), (frame(0.5), 0x80, 36, 0), (frame(0.56), 0x90, 48, 90)], seconds: 1)
    #expect(rms(apart[frame(0.535)..<frame(0.56)]) < 0.005)
}

@Test func acidReleasingTheTopNoteReturnsToTheHeldOne() {
    let script: Script = [(0, 0x90, 36, 90), (frame(0.3), 0x90, 48, 90), (frame(0.6), 0x80, 48, 0)]
    let out = play("acid", ["cutoff": 18_000, "resonance": 0, "envMod": 0, "drive": 0, "slide": 20], script, seconds: 1.2)
    #expect(abs(frequency(out[frame(0.45)..<frame(0.6)]) - 130.8) < 4)
    #expect(abs(frequency(out[frame(0.9)..<frame(1.2)]) - 65.4) < 3, "back to C2 after the C3 is released")
}

@Test func acidSilenceNotesEndsEverything() {
    let synth = DSPEffect.make("acid", sampleRate: rate) as! DSPInstrument
    synth.sendMIDI(0x90, 40, 100)
    var l = [Float](repeating: 0, count: 4800), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in synth.render(lp.baseAddress!, rp.baseAddress!, frames: 4800) } }
    #expect(peak(l[...]) > 0.02)
    synth.silenceNotes()
    var l2 = [Float](repeating: 0, count: 9600), r2 = l2
    l2.withUnsafeMutableBufferPointer { lp in r2.withUnsafeMutableBufferPointer { rp in synth.render(lp.baseAddress!, rp.baseAddress!, frames: 9600) } }
    #expect(peak(l2[4800...]) < 0.001)
}

@Test func instrumentMessagesLandOnTheirFrame() {
    // Block size must not matter: the same script in 64-frame and 4096-frame blocks gives the same sound.
    let script: Script = [(1_000, 0x90, 40, 100), (frame(0.3), 0x80, 40, 0), (frame(0.31), 0x90, 43, 100)]
    let a = play("acid", ["drive": 0], script, seconds: 0.6, block: 64)
    let b = play("acid", ["drive": 0], script, seconds: 0.6, block: 4096)
    #expect(peak(a[..<999]) == 0, "silent before the note")
    var maxDiff: Float = 0
    for i in 0..<a.count { maxDiff = max(maxDiff, abs(a[i] - b[i])) }
    #expect(maxDiff < 1e-4, "difference \(maxDiff)")
}

// MARK: 808 Drums

@Test func everyDrumPadMakesSoundOnItsNotes() {
    for pad in BuiltInInstruments.drumPads {
        for note in pad.notes {
            let out = play("drum808", [:], [(0, 0x90, note, 110)], seconds: 0.25)
            #expect(peak(out[...]) > 0.03, "\(pad.name) on note \(note)")
        }
    }
    let silent = play("drum808", [:], [(0, 0x90, 20, 110), (0, 0x90, 100, 110)], seconds: 0.1)
    #expect(peak(silent[...]) == 0, "a note the kit does not use stays silent")
}

@Test func drumPadsAreDistinct() {
    let notes = BuiltInInstruments.drumPads.flatMap(\.notes)
    #expect(Set(notes).count == notes.count, "no note plays two pads")
    for pad in BuiltInInstruments.drumPads {
        for key in pad.params + pad.random { #expect(BuiltInInstruments.drums.param(key) != nil, "\(pad.key) uses \(key)") }
        #expect(pad.params.last?.hasSuffix(".level") == true, "the last knob of \(pad.name) is its level")
    }
    for key in BuiltInInstruments.drumKitParams { #expect(BuiltInInstruments.drums.param(key) != nil) }
}

@Test func moreClapsMakeALongerBurst() {
    let one = play("drum808", ["cp.count": 1, "cp.tail": 0, "cp.random": 0], [(0, 0x90, 39, 110)], seconds: 0.3)
    let many = play("drum808", ["cp.count": 10, "cp.space": 15, "cp.tail": 0, "cp.random": 0], [(0, 0x90, 39, 110)], seconds: 0.3)
    // Ten claps 15 ms apart still sound between 60 and 150 ms; one clap is long gone.
    #expect(rms(one[frame(0.06)..<frame(0.15)]) < rms(many[frame(0.06)..<frame(0.15)]) * 0.2)
    #expect(peak(one[..<frame(0.02)]) > 0.05, "the single clap itself is as loud")
}

@Test func theClapTailIsAudibleAndItsDecaySetsTheLength() {
    let dry = play("drum808", ["cp.tail": 0, "cp.random": 0], [(0, 0x90, 39, 110)], seconds: 0.5)
    let wet = play("drum808", ["cp.tail": 1, "cp.decay": 1_000, "cp.random": 0], [(0, 0x90, 39, 110)], seconds: 0.5)
    let short = play("drum808", ["cp.tail": 1, "cp.decay": 80, "cp.random": 0], [(0, 0x90, 39, 110)], seconds: 0.5)
    #expect(rms(wet[frame(0.15)..<frame(0.4)]) > rms(dry[frame(0.15)..<frame(0.4)]) * 10)
    #expect(rms(short[frame(0.15)..<frame(0.4)]) < rms(wet[frame(0.15)..<frame(0.4)]) * 0.2)
}

@Test func kickDecayKnobSetsTheLength() {
    let short = play("drum808", ["bd.decay": 100], [(0, 0x90, 36, 110)], seconds: 0.6)
    let long = play("drum808", ["bd.decay": 1_500], [(0, 0x90, 36, 110)], seconds: 0.6)
    #expect(rms(short[frame(0.3)..<frame(0.4)]) < rms(long[frame(0.3)..<frame(0.4)]) * 0.2)
    #expect(peak(short[..<frame(0.05)]) > 0.2, "the hit itself is as loud")
}

@Test func kickTuneMovesThePitch() {
    // After the pitch sweep the body sits on its tuned frequency.
    let low = play("drum808", ["bd.tone": 0, "bd.decay": 2_000, "bd.tune": -12], [(0, 0x90, 36, 110)], seconds: 1)
    let high = play("drum808", ["bd.tone": 0, "bd.decay": 2_000, "bd.tune": 12], [(0, 0x90, 36, 110)], seconds: 1)
    let a = frequency(low[frame(0.4)..<frame(0.9)]), b = frequency(high[frame(0.4)..<frame(0.9)])
    #expect(abs(a - 27.5) < 2, "\(a) Hz")
    #expect(abs(b - 110) < 4, "\(b) Hz")
}

@Test func snareSnappyAddsNoise() {
    let dull = play("drum808", ["sd.snappy": 0], [(0, 0x90, 38, 110)], seconds: 0.3)
    let snappy = play("drum808", ["sd.snappy": 1], [(0, 0x90, 38, 110)], seconds: 0.3)
    #expect(brightness(snappy[frame(0.02)..<frame(0.1)]) > brightness(dull[frame(0.02)..<frame(0.1)]) * 1.5)
}

@Test func closedHatChokesTheOpenHat() {
    let free = play("drum808", ["oh.decay": 1_000], [(0, 0x90, 46, 110)], seconds: 0.5)
    let choked = play("drum808", ["oh.decay": 1_000], [(0, 0x90, 46, 110), (frame(0.1), 0x90, 42, 110)], seconds: 0.5)
    #expect(rms(choked[frame(0.3)..<frame(0.4)]) < rms(free[frame(0.3)..<frame(0.4)]) * 0.2)
}

@Test func drumVelocityFollowsTheVelocityKnob() {
    let soft = play("drum808", ["accent": 1], [(0, 0x90, 36, 40)], seconds: 0.1)
    let hard = play("drum808", ["accent": 1], [(0, 0x90, 36, 127)], seconds: 0.1)
    #expect(peak(hard[...]) > peak(soft[...]) * 2)
    let flatSoft = play("drum808", ["accent": 0], [(0, 0x90, 36, 40)], seconds: 0.1)
    let flatHard = play("drum808", ["accent": 0], [(0, 0x90, 36, 127)], seconds: 0.1)
    #expect(abs(peak(flatHard[...]) - peak(flatSoft[...])) < 0.01)
}

@Test func drumSpreadPansThePads() {
    let synth = DSPEffect.make("drum808", sampleRate: rate) as! DSPInstrument
    synth.configure(["spread": 1])
    synth.sendMIDI(0x90, 48, 110) // the high tom sits right
    var l = [Float](repeating: 0, count: 4800), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in synth.render(lp.baseAddress!, rp.baseAddress!, frames: 4800) } }
    #expect(peak(r[...]) > peak(l[...]) * 1.5)
}

@Test func drumTelemetryShowsTheHit() {
    let synth = DSPEffect.make("drum808", sampleRate: rate) as! DSPInstrument
    synth.sendMIDI(0x90, 36, 127)
    var l = [Float](repeating: 0, count: 512), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in synth.render(lp.baseAddress!, rp.baseAddress!, frames: 512) } }
    #expect(synth.telemetryValue(0) > 0.5, "the kick pad lights")
    #expect(synth.telemetryValue(1) == 0, "the snare pad does not")
}

// MARK: In the graph

private func midiProject(_ instrument: String, params: [String: Double] = [:], notes: [MIDINote]) -> (Project, TrackID, DeviceID) {
    var project = Project(name: "I", sampleRate: rate)
    let t = Track(name: "Synth", kind: .midi)
    try! Command.insertTrack(track: t, index: 0).apply(to: &project)
    var slot = BuiltInEffects.makeSlot(instrument)!
    slot.params = params
    try! Command.insertDevice(track: t.id, device: slot, index: 0).apply(to: &project)
    let clip = MIDIClip(start: 0, length: Tick(3840), notes: notes)
    try! Command.insertClip(track: t.id, clip: .midi(clip)).apply(to: &project)
    return (project, t.id, slot.id)
}

@Test func aMIDIClipPlaysTheBuiltInInstrumentInABounce() {
    // One beat at 120 BPM is 0.5 s. A note on beat 2 with a length of one beat.
    let (project, _, _) = midiProject("acid", params: ["cutoff": 2_000, "drive": 0],
                                      notes: [MIDINote(tick: Tick(960), length: Tick(960), pitch: 40, velocity: 100)])
    let plan = RenderPlan.compile(project, bank: AudioBank())
    #expect(plan.warnings.isEmpty, "\(plan.warnings)")
    let out = Bounce.render(plan, startFrame: 0, endFrame: Int64(2 * rate))
    #expect(peak(out.left[..<frame(0.49)]) == 0, "silent before the note")
    #expect(peak(out.left[frame(0.55)..<frame(0.95)]) > 0.02)
    #expect(peak(out.left[frame(1.2)...]) < 0.002, "silent after the note-off")
}

@Test func aBuiltInInstrumentFollowsItsAutomation() {
    let made = midiProject("acid", params: ["cutoff": 150, "resonance": 0.2, "envMod": 0, "drive": 0],
                           notes: [MIDINote(tick: Tick(0), length: Tick(3840), pitch: 36, velocity: 90)])
    var project = made.0
    let track = made.1, device = made.2
    let target = ParameterAddress(node: device.rawValue, parameter: "cutoff")
    // The cutoff opens from 150 Hz at the start to 8 kHz at beat 3.
    try! Command.setAutomation(track: track, target: target, points: [
        AutomationPoint(tick: Tick(0), value: 150), AutomationPoint(tick: Tick(2880), value: 8_000),
    ]).apply(to: &project)
    let plan = RenderPlan.compile(project, bank: AudioBank())
    let out = Bounce.render(plan, startFrame: 0, endFrame: Int64(2 * rate))
    let early = brightness(out.left[frame(0.05)..<frame(0.2)]), late = brightness(out.left[frame(1.6)..<frame(1.9)])
    #expect(late > early * 2, "early \(early) late \(late)")
}

@Test func theInstrumentKeepsItsInstanceAcrossAPlanSwap() {
    let (project, track, device) = midiProject("acid", notes: [])
    let plan = RenderPlan.compile(project, bank: AudioBank())
    let first = Renderer(plan: plan)
    let kept = first.instance(device) as? DSPInstrument
    #expect(kept != nil)
    // A knob turned: the plan is new, the instrument (its notes, its tails) is the same object.
    var changed = project
    try! Command.setDeviceParam(track: track, device: device, key: "cutoff", value: 3_000).apply(to: &changed)
    let second = Renderer(plan: RenderPlan.compile(changed, bank: AudioBank()), reusing: first)
    #expect(second.instance(device) === kept)
}

@Test func aLiveNoteReachesTheBuiltInInstrument() {
    let (project, track, _) = midiProject("drum808", notes: [])
    let renderer = Renderer(plan: RenderPlan.compile(project, bank: AudioBank()))
    renderer.sendLive(track: track, 0x90, 36, 110, sampleOffset: 100)
    var l = [Float](repeating: 0, count: 2048), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        renderer.process(startFrame: 0, frames: 2048, transport: false, outLeft: lp.baseAddress!, outRight: rp.baseAddress!)
    } }
    #expect(peak(l[..<99]) == 0)
    #expect(peak(l[100...]) > 0.05, "the kick plays with the transport stopped")
}

@Test func automationTargetsListTheInstrumentKnobs() {
    let (project, track, device) = midiProject("drum808", notes: [])
    let targets = project.automationTargets(of: project.track(track)!)
    #expect(targets.contains { $0.address == ParameterAddress(node: device.rawValue, parameter: "bd.tune") })
    #expect(targets.first { $0.address.parameter == "cutoff" } == nil)
}
