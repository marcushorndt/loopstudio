import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

private func sine(_ hz: Double, seconds: Double, amp: Double = 0.5) -> PCMBuffer {
    let n = Int(seconds * rate)
    let s = (0..<n).map { Float(amp * sin(2 * Double.pi * hz * Double($0) / rate)) }
    return PCMBuffer(samples: [s, s], sampleRate: rate)
}

/// A click every `every` seconds over quiet noise: a sharp attack and a short decay.
private func clicks(every: Double, seconds: Double, first: Double = 0.05) -> (PCMBuffer, [Int]) {
    let n = Int(seconds * rate)
    var s = [Float](repeating: 0, count: n)
    var rng = SplitMix(seed: 7)
    for i in 0..<n { s[i] = Float(rng.unit() * 2 - 1) * 0.002 }
    var at: [Int] = []
    var t = first
    while t < seconds - 0.05 {
        let p = Int(t * rate)
        at.append(p)
        for k in 0..<Int(0.03 * rate) where p + k < n {
            s[p + k] += Float(0.8 * exp(-Double(k) / (0.004 * rate)) * sin(2 * .pi * 1_000 * Double(k) / rate))
        }
        t += every
    }
    return (PCMBuffer(samples: [s, s], sampleRate: rate), at)
}

private func frequency(_ x: UnsafePointer<Float>, from: Int, count: Int) -> Double {
    var crossings = 0
    for i in from + 1..<from + count where x[i - 1] < 0 && x[i] >= 0 { crossings += 1 }
    return Double(crossings) / (Double(count) / rate)
}

/// The strongest frequency between 100 and 2000 Hz, by a Goertzel scan in 1 Hz steps.
private func dominant(_ x: UnsafePointer<Float>, from: Int, count: Int) -> Double {
    var best = 0.0, bestPower = -1.0
    var hz = 100.0
    while hz <= 2_000 {
        let w = 2 * Double.pi * hz / rate, k = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for i in from..<from + count { let s0 = Double(x[i]) + k * s1 - s2; s2 = s1; s1 = s0 }
        let power = s1 * s1 + s2 * s2 - k * s1 * s2
        if power > bestPower { bestPower = power; best = hz }
        hz += 1
    }
    return best
}

private func rms(_ x: UnsafePointer<Float>, from: Int, count: Int) -> Double {
    var s = 0.0
    for i in from..<from + count { s += Double(x[i] * x[i]) }
    return (s / Double(max(1, count))).squareRoot()
}

/// A mapping for audio at `source` BPM played at `project` BPM.
private func mapping(frames: Int, source: Double, project: Double) -> WarpMapping {
    WarpMapping.make(sourceFrames: frames, sourceTempo: source, markers: [], assetRate: rate,
                     tempoMap: TempoMap(bpm: project), startTick: 0, sampleRate: rate)!
}

/// The frame of the loudest sample within `reach` frames of `near`.
private func peak(_ x: UnsafePointer<Float>, near: Int, reach: Int, count: Int) -> Int {
    var best = near, value: Float = -1
    for i in max(0, near - reach)..<min(count, near + reach) where abs(x[i]) > value { value = abs(x[i]); best = i }
    return best
}

@Test func onsetsFindEveryClick() {
    let (pcm, at) = clicks(every: 0.25, seconds: 4)
    let found = Onsets.detect(pcm)
    #expect(found.count == at.count, "found \(found.count) of \(at.count)")
    for (a, f) in zip(at, found) { #expect(abs(a - f) < 96, "click at \(a), found \(f)") }
}

@Test func beatsAtRatioOneIsTheInput() {
    let (pcm, _) = clicks(every: 0.5, seconds: 3)
    var settings = WarpSettings()
    settings.transientLoop = .forward
    let out = TimeStretch.render(pcm, mode: .beats, settings: settings, mapping: mapping(frames: pcm.frames, source: 120, project: 120))
    #expect(abs(out.frames - pcm.frames) < 3)
    var worst: Float = 0
    for i in 0..<(min(out.frames, pcm.frames) - 10) { worst = max(worst, abs(out.channel(0)[i] - pcm.channel(0)[i])) }
    #expect(worst < 1e-4, "worst difference \(worst)")
}

@Test func beatsPutsEveryAttackOnItsBeat() {
    // 120 BPM eighths (0.25 s), played at 100 BPM (slower) and at 150 BPM (faster).
    let (pcm, at) = clicks(every: 0.25, seconds: 4)
    for project in [100.0, 150.0] {
        let m = mapping(frames: pcm.frames, source: 120, project: project)
        let out = TimeStretch.render(pcm, mode: .beats, settings: WarpSettings(), mapping: m)
        let ratio = 120 / project
        for a in at.dropFirst().dropLast() {
            let expected = Int(Double(a) * ratio)
            let p = peak(out.channel(0), near: expected + 24, reach: 480, count: out.frames)
            #expect(abs(p - (expected + 24)) < 96, "at \(project) BPM: click from \(a) expected near \(expected), peak \(p)")
            let original = peak(pcm.channel(0), near: a + 24, reach: 480, count: pcm.frames)
            #expect(abs(out.channel(0)[p]) > 0.9 * abs(pcm.channel(0)[original]), "the attack keeps its level")
        }
    }
}

@Test func beatsLoopModesFillTheGap() {
    // A held tone that starts every 0.5 s (120 BPM quarters), played at half speed: every piece leaves a gap.
    let n = Int(3 * rate)
    var s = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let t = Double(i % 24_000)
        s[i] = Float((t < 48 ? t / 48 : 1) * 0.4 * sin(2 * .pi * 300 * Double(i) / rate))
    }
    let pcm = PCMBuffer(samples: [s, s], sampleRate: rate)
    let m = mapping(frames: pcm.frames, source: 120, project: 60)
    func gapLevel(_ loop: WarpSettings.TransientLoop, envelope: Double = 100) -> Double {
        var settings = WarpSettings(); settings.transientLoop = loop; settings.transientEnvelope = envelope
        settings.preserve = .quarter
        let out = TimeStretch.render(pcm, mode: .beats, settings: settings, mapping: m)
        // Slot 2 runs from 2.0 s to 3.0 s out; its second half is the gap.
        return rms(out.channel(0), from: Int(2.6 * rate), count: Int(0.3 * rate))
    }
    #expect(gapLevel(.off) < 0.01)
    #expect(gapLevel(.forward) > 0.2)
    #expect(gapLevel(.backAndForth) > 0.2)
    #expect(gapLevel(.forward, envelope: 30) < 0.05, "a short envelope fades every piece out")
}

@Test func beatsOnAGridCutsOnTheGrid() {
    let (pcm, _) = clicks(every: 0.25, seconds: 2)
    var settings = WarpSettings(); settings.preserve = .sixteenth
    let curve = WarpCurve(mapping(frames: pcm.frames, source: 120, project: 90))
    let pieces = BeatsStretch.cuts(pcm, curve: curve, settings: settings, minGap: 100)
    // Two seconds at 120 BPM are four beats: sixteen sixteenths.
    #expect(pieces.count == 16, "\(pieces.count) pieces")
    for (k, p) in pieces.enumerated() { #expect(abs(p.source - Double(k) * 6_000) < 2) }
}

@Test func rePitchMovesThePitchWithTheSpeed() {
    let src = sine(440, seconds: 2)
    let out = TimeStretch.render(src, mode: .repitch, settings: WarpSettings(), mapping: mapping(frames: src.frames, source: 120, project: 96))
    #expect(abs(Double(out.frames) - Double(src.frames) * 1.25) < 3)
    let f = frequency(out.channel(0), from: 10_000, count: 48_000)
    #expect(abs(f - 352) < 3, "\(f) Hz")
}

@Test func tonesAndTextureKeepThePitch() {
    let src = sine(440, seconds: 2)
    let m = mapping(frames: src.frames, source: 120, project: 80)
    for mode in [WarpMode.tones, .texture] {
        let out = TimeStretch.render(src, mode: mode, settings: WarpSettings(), mapping: m)
        #expect(abs(Double(out.frames) - Double(src.frames) * 1.5) < 3)
        // Tones aligns its grains, so the pitch is exact. Texture does not: grains whose phases step by the
        // same amount every hop make a comb of partials one hop rate apart (100 ms grains, 25 ms hop: 40 Hz),
        // and the strongest lies within one step of the pitch. That grain is Texture's sound.
        let f = dominant(out.channel(0), from: 12_000, count: 24_000)
        let tolerance = mode == .texture ? 1 / (0.1 / 4) : 4
        #expect(abs(f - 440) < tolerance, "\(mode): \(f) Hz")
    }
}

@Test func transposeMovesThePitchAndKeepsTheLength() {
    let src = sine(440, seconds: 2)
    let m = mapping(frames: src.frames, source: 120, project: 100)
    var settings = WarpSettings(); settings.transpose = 12
    for mode in [WarpMode.tones, .beats, .complex, .complexPro] {
        let out = TimeStretch.render(src, mode: mode, settings: settings, mapping: m)
        #expect(abs(Double(out.frames) - Double(src.frames) * 1.2) < 3, "\(mode) length \(out.frames)")
        let f = frequency(out.channel(0), from: 12_000, count: 48_000)
        #expect(abs(f - 880) < 18, "\(mode): \(f) Hz")
    }
}

@Test func complexModesStretchWithRubberBand() {
    let src = sine(440, seconds: 2)
    let m = mapping(frames: src.frames, source: 120, project: 92)
    for mode in [WarpMode.complex, .complexPro] {
        let curve = WarpCurve(m)
        let out = ComplexStretch.render(src, curve: curve, finer: mode == .complexPro, pitch: 1, formants: 100)
        #expect(out != nil, "\(mode) rendered")
        guard let out else { continue }
        #expect(out.frames == curve.outFrames)
        let f = frequency(out.channel(0), from: 12_000, count: 48_000)
        #expect(abs(f - 440) < 6, "\(mode): \(f) Hz")
        let level = rms(out.channel(0), from: 12_000, count: 48_000)
        #expect(abs(level - 0.3536) < 0.06, "\(mode): level \(level)")
        #expect((0..<out.frames).allSatisfy { out.channel(0)[$0].isFinite })
    }
}

@Test func complexFollowsWarpMarkers() {
    // A click at 1.0 s of a 3 s file. Markers: source 0 s at beat 0, 1.0 s at beat 3 (1.5 s at 120 BPM),
    // 3.0 s at beat 6 (3.0 s). The click must sound 1.5 s out.
    let (pcm, _) = clicks(every: 10, seconds: 3, first: 1.0)
    let markers = [WarpMarker(sourceFrame: 0, tick: 0), WarpMarker(sourceFrame: 48_000, tick: Tick(3 * 960)),
                   WarpMarker(sourceFrame: 144_000, tick: Tick(6 * 960))]
    let m = WarpMapping.make(sourceFrames: pcm.frames, sourceTempo: nil, markers: markers, assetRate: rate,
                             tempoMap: TempoMap(bpm: 120), startTick: 0, sampleRate: rate)!
    // Tones (WSOLA) places each grain where it best continues the last, up to a quarter grain away, and a
    // slower part can repeat an attack; its tolerance is one grain (40 ms). That is why drums want Beats.
    for (mode, tolerance) in [(WarpMode.complex, 480), (.complexPro, 480), (.beats, 240), (.tones, 1_920)] {
        let out = TimeStretch.render(pcm, mode: mode, settings: WarpSettings(), mapping: m)
        let p = peak(out.channel(0), near: 72_000, reach: 4_800, count: out.frames)
        #expect(abs(p - 72_000) < tolerance, "\(mode): click at \(p), expected near 72000")
    }
}

@Test func textureIsDeterministicWithFlux() {
    let src = sine(330, seconds: 1)
    var settings = WarpSettings(); settings.flux = 60
    let m = mapping(frames: src.frames, source: 120, project: 100)
    let a = TimeStretch.render(src, mode: .texture, settings: settings, mapping: m)
    let b = TimeStretch.render(src, mode: .texture, settings: settings, mapping: m)
    #expect(a.frames == b.frames)
    #expect((0..<a.frames).allSatisfy { a.channel(0)[$0] == b.channel(0)[$0] })
}

@Test func tempoFromTheFileName() {
    #expect(TempoDetect.fromName("Funk Loop 96 BPM") == 96)
    #expect(TempoDetect.fromName("drums_128bpm_Am") == 128)
    #expect(TempoDetect.fromName("BPM_174 break") == 174)
    #expect(TempoDetect.fromName("pad 92.5bpm") == 92.5)
    #expect(TempoDetect.fromName("Kick 808") == nil)
    #expect(TempoDetect.fromName("take 1200bpm") == nil)
}

@Test func loopLengthGivesWholeBars() {
    #expect(abs(TempoDetect.loopFit(seconds: 2.0, hint: nil) - 120) < 1e-9)
    #expect(abs(TempoDetect.loopFit(seconds: 8.0, hint: nil) - 120) < 1e-9)
    // 2.5 s: one bar at 96 BPM.
    #expect(abs(TempoDetect.loopFit(seconds: 2.5, hint: nil) - 96) < 1e-9)
    // 6 s: three bars at 120 is closer to a heard 121 than two bars at 80.
    #expect(abs(TempoDetect.loopFit(seconds: 6.0, hint: 121) - 120) < 1e-9)
}

@Test func onsetsGiveTheTempoOfAClickTrack() {
    let (pcm, _) = clicks(every: 60 / 123.4, seconds: 60)
    let e = TempoDetect.estimate(pcm, name: "song", loop: false)
    #expect(e != nil)
    if let e {
        #expect(abs(e.bpm - 123.4) < 0.03, "\(e.bpm) BPM")
        #expect(e.method == .onsets)
    }
}

@Test func noiseHasNoTempo() {
    let n = Int(30 * rate)
    var rng = SplitMix(seed: 3)
    let s = (0..<n).map { _ in Float(rng.unit() * 2 - 1) * 0.3 }
    let e = TempoDetect.estimate(PCMBuffer(samples: [s], sampleRate: rate), name: "rain", loop: false)
    #expect(e == nil, "noise read as \(e?.bpm ?? 0) BPM, confidence \(e?.confidence ?? 0)")
}

@Test func warpSettingsReadOldProjects() throws {
    let empty = try JSONDecoder().decode(WarpSettings.self, from: Data("{}".utf8))
    #expect(empty == WarpSettings())
    let partial = try JSONDecoder().decode(WarpSettings.self, from: Data(#"{"flux": 40, "transpose": -3}"#.utf8))
    #expect(partial.flux == 40 && partial.transpose == -3 && partial.tonesGrainMs == 40)
    let clip = AudioClip(asset: AssetID(), length: 1920)
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(clip)) as! [String: Any]
    json["warpSettings"] = nil
    json["warpMode"] = "tones"
    let back = try JSONDecoder().decode(AudioClip.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(back.warpSettings == nil && back.warp == WarpSettings() && back.warpMode == .tones)
}

@Test func warpSettingsCommandClampsAndUndoes() throws {
    var project = Project(name: "S", sampleRate: rate)
    let asset = Asset(sha256: "s", name: "s", frames: 48_000, sampleRate: rate, channels: 2, sourceTempo: 120)
    try Command.addAsset(asset: asset).apply(to: &project)
    let t = Track(name: "T", kind: .audio)
    try Command.insertTrack(track: t, index: 0).apply(to: &project)
    let clip = project.makeAudioClip(asset: asset.id, length: 1920)
    try Command.insertClip(track: t.id, clip: .audio(clip)).apply(to: &project)
    var s = WarpSettings(); s.flux = 300; s.transpose = 60; s.preserve = .eighth
    let undo = try Command.setClipWarpSettings(clip: clip.id, settings: s).apply(to: &project)
    guard case .audio(let c)? = project.findClip(clip.id)?.clip else { Issue.record("no clip"); return }
    #expect(c.warp.flux == 100 && c.warp.transpose == 48 && c.warp.preserve == .eighth)
    _ = try undo.apply(to: &project)
    guard case .audio(let d)? = project.findClip(clip.id)?.clip else { Issue.record("no clip"); return }
    #expect(d.warpSettings == nil)
}

@Test func autoWarpPicksTheModeByLength() throws {
    var project = Project(name: "A", sampleRate: rate)
    let loop = Asset(sha256: "l", name: "l", frames: Int64(2 * rate), sampleRate: rate, channels: 2, sourceTempo: 120)
    let song = Asset(sha256: "g", name: "g", frames: Int64(180 * rate), sampleRate: rate, channels: 2, sourceTempo: 100)
    let free = Asset(sha256: "f", name: "f", frames: Int64(180 * rate), sampleRate: rate, channels: 2)
    for a in [loop, song, free] { try Command.addAsset(asset: a).apply(to: &project) }
    #expect(project.autoWarp(for: loop) == .beats)
    #expect(project.autoWarp(for: song) == .complex)
    #expect(project.autoWarp(for: free) == .off)
    // A warped song keeps its beats: 180 s at 100 BPM are 300 beats.
    #expect(project.naturalLength(of: song) == Tick.quarters(300))
}

@Test func settingsKeyChangesOnlyWithTheModesOwnSettings() {
    var a = WarpSettings(), b = WarpSettings()
    b.flux = 50
    #expect(a.key(for: .beats) == b.key(for: .beats))
    #expect(a.key(for: .texture) != b.key(for: .texture))
    a.transpose = 2
    #expect(a.key(for: .repitch) == b.key(for: .repitch))
    #expect(a.key(for: .complexPro) != b.key(for: .complexPro))
}

@Test func aHitGetsNoTempo() {
    // A crash: a noise burst that decays over three seconds.
    let n = Int(3 * rate)
    var rng = SplitMix(seed: 11)
    let s = (0..<n).map { i in Float((rng.unit() * 2 - 1) * 0.8 * exp(-Double(i) / (0.4 * rate))) }
    let crash = PCMBuffer(samples: [s, s], sampleRate: rate)
    #expect(TempoDetect.isOneShot(crash))
    #expect(TempoDetect.estimate(crash, name: "Crash", loop: true) == nil)
    let (loop, _) = clicks(every: 0.25, seconds: 2)
    #expect(!TempoDetect.isOneShot(loop))
    #expect(TempoDetect.estimate(loop, name: "Drums", loop: true)?.bpm == 120)
}

@Test func aSteadyToneHasNoOnsetsAndNoTempo() {
    let src = sine(440, seconds: 25)
    #expect(Onsets.detect(src).isEmpty)
    #expect(TempoDetect.onsetTempo(src) == nil)
    #expect(TempoDetect.estimate(src, name: "tone", loop: false) == nil)
}

@Test func fluxFloorSitsBetweenLeakageAndAttacks() {
    func peak(_ p: PCMBuffer) -> Float { Onsets.rawFlux(p).values.max() ?? 0 }
    let (c, _) = clicks(every: 0.25, seconds: 4)
    var quiet = [Float](repeating: 0, count: 96_000)
    for i in 48_000..<50_000 { quiet[i] = Float(0.01 * sin(2 * .pi * 200 * Double(i) / rate)) }
    for hz in [30.0, 55, 110, 440, 3_000] { #expect(peak(sine(hz, seconds: 5)) < Onsets.minimumFlux / 2, "\(hz) Hz") }
    #expect(peak(PCMBuffer(samples: [quiet], sampleRate: rate)) > Onsets.minimumFlux * 2, "an attack at -40 dB")
    #expect(peak(c) > Onsets.minimumFlux * 10)
}


@Test func silenceHasNoTempo() {
    let silent = PCMBuffer(samples: [[Float](repeating: 0, count: 96_000)], sampleRate: rate)
    #expect(TempoDetect.estimate(silent, name: "render", loop: true) == nil)
    #expect(TempoDetect.estimate(silent, name: "render 96 bpm", loop: true)?.bpm == 96, "the name still counts")
}
