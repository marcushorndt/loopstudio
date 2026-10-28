import Foundation
import LoopStudioCore

struct ClipPlan {
    var pcm: PCMBuffer
    var start: Int64          // first frame of the clip, in project frames
    var end: Int64            // one past the last frame
    var sourceOffset: Int64   // frame in the source where the clip starts playing
    var loop: Bool
    var gain: Float
    var fadeIn: Int64         // frames
    var fadeOut: Int64
    /// Clip gain envelope in dB, in the same frames as `start`.
    var envelope: AutoSegment? = nil
    /// A session clip: its frames count on the session clock, which never jumps back at the loop end.
    var session = false
    /// Frames of one loop pass, from `sourceOffset`. 0: a looping clip repeats the whole source.
    var loopLength: Int64 = 0
}

/// One envelope, in frames. Active inside [start, end).
struct AutoSegment {
    var start: Int64
    var end: Int64
    var frames: [Int64]
    var values: [Float]
    var curves: [Curve]
    var bends: [Double?]
    /// From a session clip: its frames count on the session clock.
    var session = false
    /// From an arrangement clip on a track the Session took over: the session frame from which it stays silent.
    var cut: Int64? = nil

    func value(at f: Int64) -> Float {
        guard let first = frames.first, let last = frames.last else { return 0 }
        if f <= first { return values[0] }
        if f >= last { return values[values.count - 1] }
        var lo = 0, hi = frames.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if frames[mid] <= f { lo = mid } else { hi = mid }
        }
        let t = Double(f - frames[lo]) / Double(max(1, frames[hi] - frames[lo]))
        let shaped = Float(AutomationMath.shape(curves[lo], bend: bends[lo], t))
        return values[lo] + (values[hi] - values[lo]) * shaped
    }
}

/// All envelopes that move one parameter. The track lane comes first; clips that play
/// override it while they play (the one that started last wins).
struct AutoLane {
    var segments: [AutoSegment]

    /// `f` is a timeline frame; `sessionOffset` turns it into a session frame for the session segments.
    func value(at f: Int64, sessionOffset: Int64 = 0) -> Float? {
        for s in segments.reversed() {
            let g = s.session ? f + sessionOffset : f
            if let cut = s.cut, f + sessionOffset >= cut { continue }
            if g >= s.start && g < s.end { return s.value(at: g) }
        }
        return nil
    }
}

struct EffectPlan {
    var device: DeviceID
    var kind: String
    var params: [String: Double]
    var bypassed: Bool
    /// Automated parameters by key.
    var auto: [String: AutoLane] = [:]
    /// A hosted Audio Unit effect. `nil` for a built-in one.
    var unit: AudioUnitEffect? = nil
}

struct MIDIEvent {
    var frame: Int64
    var status: UInt8
    var data1: UInt8
    var data2: UInt8
}

struct SendPlan {
    var target: Int
    var gain: Float
    var preFader: Bool
    var auto: AutoLane? = nil
    /// Frames of delay that line this send up with the other inputs of its target.
    var delay = 0
}

struct NodePlan {
    var isMaster: Bool
    var clips: [ClipPlan]
    /// Fader as a linear gain. Zero when muted or silenced by solo.
    var gain: Float
    var panLeft: Float
    var panRight: Float
    /// Index of the node this one feeds. The master has none.
    var output: Int?
    var sends: [SendPlan]
    var effects: [EffectPlan] = []
    /// Muted, or silenced by solo. The fader automation does not bring it back.
    var silenced = false
    var volumeAuto: AutoLane? = nil
    var panAuto: AutoLane? = nil
    /// A hosted instrument and the notes it plays, sorted by frame (note-off before note-on on the same frame).
    var instrument: AudioUnitEffect? = nil
    /// Automated parameters of the instrument, keyed like an effect's ("au.<address>").
    var instrumentAuto: [String: AutoLane] = [:]
    var midi: [MIDIEvent] = []
    /// Notes of the session clips, in session frames.
    var sessionMidi: [MIDIEvent] = []
    /// Session frame from which this track's arrangement clips and notes are silent, because a session clip
    /// took the track over (or a session stop). `nil`: the arrangement plays.
    var arrangementEnd: Int64? = nil
    /// Nodes that take this node's sound as input, after the fader.
    var taps: [Int] = []
    /// Latency of the plugins on this node, in frames.
    var latency = 0
    /// Delay on the output connection and on each tap, from plugin delay compensation.
    var outputDelay = 0
    var tapDelays: [Int] = []
}

/// Everything the renderer needs, compiled from a project. Immutable; built off the audio thread.
/// Nodes are sorted so that a node always comes before the nodes it feeds, and the master is last.
public struct RenderPlan {
    var nodes: [NodePlan]
    public let sampleRate: Double
    /// First frame after the last sounding clip.
    public let endFrame: Int64
    /// How late the master mix is, in frames, because of plugin latency. 0 when no plugin has latency.
    public internal(set) var latencyFrames = 0
    /// Things that were not rendered as the project says (missing audio, unsupported features).
    public let warnings: [String]
    /// The track of each node, in node order. The master (last) has `nil`.
    public let trackOrder: [TrackID?]

    public static func dB(_ db: Double) -> Float { db <= -96 ? 0 : Float(pow(10.0, db / 20.0)) }

    /// Balance pan law: unity in the centre, the far side fades to silence at the extreme.
    static func balance(_ pan: Double) -> (Float, Float) {
        let p = min(max(pan, -1), 1)
        if p == 0 { return (1, 1) }
        // Exact zero at the extremes; cos(pi/2) is only almost zero.
        let left = p <= 0 ? 1.0 : (p >= 1 ? 0.0 : cos(p * .pi / 2))
        let right = p >= 0 ? 1.0 : (p <= -1 ? 0.0 : cos(-p * .pi / 2))
        return (Float(left), Float(right))
    }

    /// `arrangementEnds`: per track, the session frame from which its arrangement stays silent (see `NodePlan`).
    public static func compile(_ project: Project, bank: AudioBank, session: SessionSimulation? = nil,
                               units: [DeviceID: AudioUnitEffect] = [:], arrangementEnds: [TrackID: Int64] = [:]) -> RenderPlan {
        var warnings: [String] = []
        let tracks = project.tracks
        let rate = project.sampleRate
        let map = project.tempoMap

        // Which tracks are audible: solo keeps soloed tracks and everything they feed. The tracks that feed a
        // soloed group or return also play, but only into it ("feeders"): their other paths stay silent.
        var audible = Set(tracks.map(\.id))
        var feeders = Set<TrackID>()
        let soloed = tracks.filter(\.solo).map(\.id)
        if !soloed.isEmpty {
            var reach = Set<TrackID>()
            var stack = soloed
            while let id = stack.popLast() {
                guard reach.insert(id).inserted, let t = project.track(id) else { continue }
                stack.append(contentsOf: Routing.feeds(of: t, in: project))
            }
            var upstream = Set(soloed)
            var grew = true
            while grew {
                grew = false
                for t in tracks where !upstream.contains(t.id) && Routing.feeds(of: t, in: project).contains(where: upstream.contains) {
                    upstream.insert(t.id); grew = true
                }
            }
            feeders = upstream.subtracting(reach)
            audible = reach.union(feeders)
        }
        /// A feeder keeps only the connections that lead to a soloed track.
        func keeps(_ source: TrackID, _ target: TrackID) -> Bool {
            !feeders.contains(source) || feeders.contains(target) || soloed.contains(target)
        }

        // Order: sources before targets (Kahn). Ties keep project order, so the plan is deterministic.
        var incoming = Dictionary(tracks.map { ($0.id, 0) }, uniquingKeysWith: { a, _ in a })
        for t in tracks { for target in Routing.feeds(of: t, in: project) where incoming[target] != nil { incoming[target]! += 1 } }
        var ready = tracks.filter { incoming[$0.id] == 0 }.map(\.id)
        var order: [TrackID] = []
        while !ready.isEmpty {
            let id = ready.removeFirst()
            order.append(id)
            guard let t = project.track(id) else { continue }
            for target in Routing.feeds(of: t, in: project) where incoming[target] != nil {
                incoming[target]! -= 1
                if incoming[target] == 0 { ready.append(target) }
            }
        }
        if order.count != tracks.count { warnings.append("routing has a cycle; some tracks are not rendered") }

        var index: [TrackID: Int] = [:]
        for (i, id) in order.enumerated() { index[id] = i }
        let masterIndex = order.count

        var nodes: [NodePlan] = []
        var endFrame: Int64 = 0

        // Envelopes by parameter: the track lanes, then the clips. A later segment wins while it covers the frame.
        var segments: [ParameterAddress: [AutoSegment]] = [:]
        func segment(_ points: [AutomationPoint], origin: Tick, start: Int64, end: Int64) -> AutoSegment? {
            guard !points.isEmpty else { return nil }
            return AutoSegment(start: start, end: end,
                               frames: points.map { map.frame(at: origin + $0.tick, sampleRate: rate).rawValue },
                               values: points.map { Float($0.value) }, curves: points.map(\.curve), bends: points.map(\.bend))
        }
        for t in project.allTracks {
            for lane in t.automation {
                if let seg = segment(lane.points, origin: 0, start: Int64.min, end: Int64.max) { segments[lane.target, default: []].append(seg) }
            }
        }
        // Clip automation: the lanes repeat every automation cycle from the clip start until the clip ends.
        func active(_ clip: Clip) -> Bool { if case .audio(let a) = clip { return !a.muted }; return true }
        func addClipLanes(_ clip: Clip, owner: Track, from start: Tick, to end: Tick, session: Bool) {
            let lanes = project.effectiveLanes(of: clip, owner: owner)
            guard !lanes.isEmpty else { return }
            let period = clip.automationCycle
            var cycle = start, cycles = 0
            while cycle < end && cycles < 4_096 {
                let next = min(cycle + period, end)
                let a = map.frame(at: cycle, sampleRate: rate).rawValue, b = map.frame(at: next, sampleRate: rate).rawValue
                for lane in lanes {
                    if var seg = segment(lane.points, origin: cycle, start: a, end: b) {
                        seg.session = session
                        if !session { seg.cut = arrangementEnds[owner.id] }
                        segments[lane.target, default: []].append(seg)
                    }
                }
                cycle = next; cycles += 1
            }
        }
        // Arrangement clips override the track lane while they cover the frame.
        for t in project.allTracks {
            for clip in t.clips where active(clip) { addClipLanes(clip, owner: t, from: clip.start, to: clip.start + clip.length, session: false) }
        }
        // Session clips that play, on the session clock, override both.
        if let session {
            for e in session.events.sorted(by: { $0.startTick < $1.startTick }) {
                guard let (trackID, clip) = project.findClip(e.clip), let owner = project.track(trackID), active(clip) else { continue }
                addClipLanes(clip, owner: owner, from: e.startTick, to: e.endTick, session: true)
            }
        }
        func lane(_ node: UUID, _ key: String) -> AutoLane? {
            segments[ParameterAddress(node: node, parameter: key)].map { AutoLane(segments: $0) }
        }
        func autoParams(_ device: DeviceID, of track: Track) -> [String: AutoLane] {
            var result: [String: AutoLane] = [:]
            guard let d = track.devices.first(where: { $0.id == device }) else { return result }
            if let spec = BuiltInEffects.spec(d.identifier), d.format == "builtin" {
                for p in spec.params { if let l = lane(device.rawValue, p.key) { result[p.key] = l } }
            } else {
                for p in d.pluginParams ?? [] { if let l = lane(device.rawValue, p.key) { result[p.key] = l } }
            }
            return result
        }

        /// A clip gain envelope placed on the timeline from `startTick`.
        func envelope(_ c: AudioClip, from startTick: Tick, start: Int64, end: Int64) -> AutoSegment? {
            guard let points = c.gainEnvelope, !points.isEmpty else { return nil }
            return AutoSegment(start: start, end: end,
                               frames: points.map { map.frame(at: startTick + $0.tick, sampleRate: rate).rawValue },
                               values: points.map { Float($0.value) }, curves: points.map(\.curve), bends: points.map(\.bend))
        }

        for id in order {
            let t = project.track(id)!
            if t.hardwareOutput != nil { warnings.append("track \"\(t.name)\" goes straight to a hardware port and is not in the master mix") }
            let silent = t.mute || !audible.contains(id) || t.hardwareOutput != nil
            var clips: [ClipPlan] = []

            if t.kind == .audio && !silent {
                for case .audio(let c) in t.clips where !c.muted {
                    guard let raw = bank.buffer(for: c.asset), raw.frames > 0 else {
                        warnings.append("clip on \"\(t.name)\" has no audio (missing or unreadable file)")
                        continue
                    }
                    let start = map.frame(at: c.start, sampleRate: rate).rawValue
                    let end = map.frame(at: c.start + c.length, sampleRate: rate).rawValue
                    guard end > start else { continue }
                    let offsetFrames = max(0, map.frame(at: c.start + c.offset, sampleRate: rate).rawValue - start)

                    var fadeIn = Int64((c.fadeInMs * rate / 1000).rounded())
                    var fadeOut = Int64((c.fadeOutMs * rate / 1000).rounded())
                    let length = end - start
                    if fadeIn + fadeOut > length {
                        // Fades that do not fit share the clip in proportion.
                        let scale = Double(length) / Double(fadeIn + fadeOut)
                        fadeIn = Int64(Double(fadeIn) * scale)
                        fadeOut = Int64(Double(fadeOut) * scale)
                    }
                    if let beats = sourceBeats(c, project: project),
                       let starts = passStarts(c, pass: beats, from: c.start, to: c.start + c.length, project: project) {
                        clips += passPlans(c, raw: raw, starts: starts, pass: beats, end: end, fadeIn: fadeIn, fadeOut: fadeOut,
                                           envelope: envelope(c, from: c.start, start: start, end: end), session: false,
                                           project: project, bank: bank, trackName: t.name, warnings: &warnings)
                        endFrame = max(endFrame, end)
                        continue
                    }
                    let pcm = warpedAudio(c, raw: raw, startTick: c.start, project: project, bank: bank, trackName: t.name, warnings: &warnings)
                    clips.append(ClipPlan(pcm: pcm, start: start, end: end, sourceOffset: offsetFrames, loop: c.loop,
                                          gain: dB(c.gainDb), fadeIn: max(0, fadeIn), fadeOut: max(0, fadeOut),
                                          envelope: envelope(c, from: c.start, start: start, end: end)))
                    endFrame = max(endFrame, end)
                }
            }
            if t.kind == .audio && !silent, let session {
                for e in session.events where e.track == id {
                    guard case .audio(let c)? = project.findClip(e.clip)?.clip, !c.muted,
                          let raw = bank.buffer(for: c.asset), raw.frames > 0 else { continue }
                    let start = map.frame(at: e.startTick, sampleRate: rate).rawValue
                    let end = map.frame(at: e.endTick, sampleRate: rate).rawValue
                    guard end > start else { continue }
                    var fadeIn = Int64((c.fadeInMs * rate / 1000).rounded())
                    var fadeOut = Int64((c.fadeOutMs * rate / 1000).rounded())
                    if fadeIn + fadeOut > end - start {
                        let scale = Double(end - start) / Double(fadeIn + fadeOut)
                        fadeIn = Int64(Double(fadeIn) * scale)
                        fadeOut = Int64(Double(fadeOut) * scale)
                    }
                    if let starts = passStarts(c, pass: c.length, from: e.startTick, to: e.endTick, project: project) {
                        clips += passPlans(c, raw: raw, starts: starts, pass: c.length, end: end, fadeIn: fadeIn, fadeOut: fadeOut,
                                           envelope: envelope(c, from: e.startTick, start: start, end: end), session: true,
                                           project: project, bank: bank, trackName: t.name, warnings: &warnings)
                        continue
                    }
                    // A session clip plays from its start offset and loops its own length, like the clip shows.
                    let pcm = warpedAudio(c, raw: raw, startTick: e.startTick, project: project, bank: bank, trackName: t.name, warnings: &warnings)
                    let offsetFrames = max(0, map.frame(at: e.startTick + c.offset, sampleRate: rate).rawValue - start)
                    let passFrames = max(0, map.frame(at: e.startTick + c.length, sampleRate: rate).rawValue - start)
                    clips.append(ClipPlan(pcm: pcm, start: start, end: end, sourceOffset: offsetFrames, loop: c.loop,
                                          gain: dB(c.gainDb), fadeIn: max(0, fadeIn), fadeOut: max(0, fadeOut),
                                          envelope: envelope(c, from: e.startTick, start: start, end: end), session: true,
                                          loopLength: c.loop ? passFrames : 0))
                }
            }
            if t.kind == .midi || t.kind == .group || t.kind == .returnTrack { /* summing nodes or not rendered yet */ }

            var (chain, instrument, instrumentDevice) = effects(of: t, units: units, warnings: &warnings)
            chain = chain.map { var e = $0; e.auto = autoParams(e.device, of: t); return e }
            let instrumentAuto = instrumentDevice.map { autoParams($0, of: t) } ?? [:]
            var midi: [MIDIEvent] = [], sessionMidi: [MIDIEvent] = []
            if t.kind == .midi && !silent && instrument != nil {
                midi = midiEvents(of: t, session: nil, map: map, rate: rate, endFrame: &endFrame)
                var ignored: Int64 = 0
                sessionMidi = midiEvents(of: t, session: session, map: map, rate: rate, endFrame: &ignored, arrangement: false)
            } else if t.kind == .midi && !t.clips.isEmpty && instrument == nil {
                warnings.append("MIDI track \"\(t.name)\" has no instrument")
            }

            let (pl, pr) = balance(t.pan)
            nodes.append(NodePlan(
                isMaster: false, clips: clips, gain: silent ? 0 : dB(t.volumeDb), panLeft: pl, panRight: pr,
                output: t.isSendsOnly || !keeps(t.id, t.output ?? project.master.id) ? nil : (t.output.flatMap { index[$0] } ?? masterIndex),
                sends: t.sends.filter { keeps(t.id, $0.target) }.compactMap { s in index[s.target].map {
                    SendPlan(target: $0, gain: dB(s.levelDb), preFader: s.preFader,
                             auto: lane(t.id.rawValue, "send.\(s.target.rawValue.uuidString)")) } },
                effects: chain, silenced: silent, volumeAuto: lane(t.id.rawValue, "volume"), panAuto: lane(t.id.rawValue, "pan"), instrument: instrument, instrumentAuto: instrumentAuto, midi: midi, sessionMidi: sessionMidi,
                arrangementEnd: arrangementEnds[t.id]))
        }

        var masterEffects = effects(of: project.master, units: units, warnings: &warnings).0
        masterEffects = masterEffects.map { var e = $0; e.auto = autoParams(e.device, of: project.master); return e }
        let (ml, mr) = balance(project.master.pan)
        nodes.append(NodePlan(isMaster: true, clips: [], gain: project.master.mute ? 0 : dB(project.master.volumeDb),
                              panLeft: ml, panRight: mr, output: nil, sends: [],
                              effects: masterEffects, silenced: project.master.mute,
                              volumeAuto: lane(project.master.id.rawValue, "volume"), panAuto: lane(project.master.id.rawValue, "pan")))
        // Input taps: a track that takes another track as input gets that track's sound, unless its monitor is off.
        for t in tracks {
            guard let source = t.inputTrack, t.monitorMode != .off, keeps(source, t.id), let from = index[source], let to = index[t.id], from < to else { continue }
            nodes[from].taps.append(to)
        }
        for i in nodes.indices {
            let chainLatency = nodes[i].effects.filter { !$0.bypassed }.reduce(0) { $0 + ($1.unit?.latencySamples ?? 0) }
            nodes[i].latency = chainLatency + (nodes[i].instrument?.latencySamples ?? 0)
        }
        var plan = RenderPlan(nodes: nodes, sampleRate: rate, endFrame: endFrame, warnings: warnings,
                              trackOrder: order.map { Optional($0) } + [nil])
        plan.applyDelayCompensation()
        return plan
    }

    /// The clip's audio, stretched to the project tempo when warping is on. Otherwise the audio as it is.
    /// The start of every pass of a looping warped clip whose bars do not all have one tempo.
    /// `nil` when one rendered pass can simply repeat (no warp, no loop, a constant tempo, or too many passes).
    /// `pass` is the musical length of one pass: the clip length for a session clip, the source for an arrangement clip.
    static func passStarts(_ c: AudioClip, pass: Tick, from start: Tick, to end: Tick, project: Project) -> [Tick]? {
        guard c.warpMode != .off, c.loop, pass.rawValue > 0, end > start,
              constantTempo(project.tempoMap, from: start, to: end) == nil else { return nil }
        let count = (end.rawValue - start.rawValue + pass.rawValue - 1) / pass.rawValue
        // Every pass holds a stretched copy of the source, so the count is kept small.
        guard count > 1, count <= 64 else { return nil }
        return (0..<count).map { start + Tick($0 * pass.rawValue) }
    }

    /// The source of a warped clip in beats, from its tempo. `nil` without a tempo (marker warps keep one pass).
    static func sourceBeats(_ c: AudioClip, project: Project) -> Tick? {
        guard let asset = project.asset(c.asset), let bpm = asset.sourceTempo, bpm > 0, asset.sampleRate > 0 else { return nil }
        return Tick.quarters(Double(asset.frames) / asset.sampleRate * bpm / 60)
    }

    /// One plan per pass, each warped at its own start, so every pass follows the tempo of its own bars.
    private static func passPlans(_ c: AudioClip, raw: PCMBuffer, starts: [Tick], pass: Tick, end: Int64, fadeIn: Int64, fadeOut: Int64,
                                  envelope: AutoSegment?, session: Bool, project: Project, bank: AudioBank,
                                  trackName: String, warnings: inout [String]) -> [ClipPlan] {
        let map = project.tempoMap, rate = project.sampleRate
        var plans: [ClipPlan] = []
        for (k, passStart) in starts.enumerated() {
            let pcm = warpedAudio(c, raw: raw, startTick: passStart, span: pass, project: project, bank: bank,
                                  trackName: trackName, warnings: &warnings)
            let a = map.frame(at: passStart, sampleRate: rate).rawValue
            let b = min(end, map.frame(at: passStart + pass, sampleRate: rate).rawValue)
            guard b > a else { continue }
            let offset = max(0, map.frame(at: passStart + c.offset, sampleRate: rate).rawValue - a)
            // Only the ends of the whole clip fade; the passes join like the loop of one buffer.
            plans.append(ClipPlan(pcm: pcm, start: a, end: b, sourceOffset: offset, loop: true, gain: dB(c.gainDb),
                                  fadeIn: k == 0 ? max(0, min(fadeIn, b - a)) : 0,
                                  fadeOut: k == starts.count - 1 ? max(0, min(fadeOut, b - a)) : 0,
                                  envelope: envelope, session: session, loopLength: b - a))
        }
        return plans
    }

    /// The tempo, when it does not change inside [start, end).
    static func constantTempo(_ map: TempoMap, from start: Tick, to end: Tick) -> Double? {
        let points = map.points
        guard let first = points.first else { return nil }
        var active = first
        for p in points where p.tick <= start { active = p }
        if points.contains(where: { $0.tick > start && $0.tick < end }) { return nil }
        if active.ramp, let next = points.first(where: { $0.tick > active.tick }), next.bpm != active.bpm { return nil }
        return active.bpm
    }

    private static func warpedAudio(_ c: AudioClip, raw: PCMBuffer, startTick: Tick, span: Tick? = nil, project: Project, bank: AudioBank,
                                    trackName: String, warnings: inout [String]) -> PCMBuffer {
        guard c.warpMode != .off else { return raw }
        let asset = project.asset(c.asset)
        let rate = project.sampleRate
        guard let mapping = WarpMapping.make(sourceFrames: raw.frames, sourceTempo: asset?.sourceTempo, markers: c.warpMarkers,
                                             assetRate: asset?.sampleRate ?? rate, tempoMap: project.tempoMap,
                                             startTick: startTick, sampleRate: rate) else {
            warnings.append("clip on \"\(trackName)\" is warped but has no source tempo or markers; it plays unwarped")
            return raw
        }
        // A pass that lies in one tempo sounds the same wherever it starts, so such passes share one buffer.
        let timing: String
        if project.tempoMap.points.count <= 1 { timing = "bpm \(project.tempoMap.points.first?.bpm ?? 0)" }
        else if let span, let bpm = constantTempo(project.tempoMap, from: startTick, to: startTick + span) { timing = "bpm \(bpm) span \(span.rawValue)" }
        else { timing = "\(project.tempoMap.points)|\(startTick.rawValue)" }
        let key = "\(c.asset)|\(c.warpMode)|\(asset?.sourceTempo ?? 0)|\(c.warpMarkers)|\(timing)|\(rate)"
        return bank.warped(key: key, clip: c.id, fallback: raw) {
            TimeStretch.stretch(raw, mode: c.warpMode, outFrames: mapping.outFrames, source: mapping.source)
        }
    }

    private static func effects(of track: Track, units: [DeviceID: AudioUnitEffect],
                                warnings: inout [String]) -> ([EffectPlan], AudioUnitEffect?, DeviceID?) {
        var plans: [EffectPlan] = []
        var instrument: AudioUnitEffect?
        var instrumentDevice: DeviceID?
        for d in track.devices {
            if d.format == "builtin" {
                guard BuiltInEffects.spec(d.identifier) != nil else { continue }
                plans.append(EffectPlan(device: d.id, kind: d.identifier, params: d.params, bypassed: d.bypassed))
            } else if d.format == "audiounit" {
                guard let unit = units[d.id] else { warnings.append("\(d.name) on \"\(track.name)\" is not loaded"); continue }
                if unit.isInstrument {
                    if instrument == nil && !d.bypassed { instrument = unit; instrumentDevice = d.id }
                } else {
                    plans.append(EffectPlan(device: d.id, kind: "audiounit", params: [:], bypassed: d.bypassed, unit: unit))
                }
            } else {
                warnings.append("\(d.name) on \"\(track.name)\" uses an unsupported plugin format")
            }
        }
        return (plans, instrument, instrumentDevice)
    }

    /// Note on and off events for a MIDI track: arrangement clips plus the session clips that play.
    private static func midiEvents(of t: Track, session: SessionSimulation?, map: TempoMap, rate: Double,
                                   endFrame: inout Int64, arrangement: Bool = true) -> [MIDIEvent] {
        var events: [MIDIEvent] = []

        func add(_ c: MIDIClip, origin: Tick, limit: Tick, repeating: Bool) {
            let length = max(1, c.length.rawValue)
            var pass: Int64 = 0
            repeat {
                let base = origin.rawValue + length * pass
                for n in c.notes where n.tick.rawValue < length {
                    let on = base + n.tick.rawValue
                    if on >= limit.rawValue { continue }
                    let off = min(base + min(n.tick.rawValue + n.length.rawValue, length), limit.rawValue)
                    guard off > on else { continue }
                    let a = map.frame(at: Tick(on), sampleRate: rate).rawValue
                    let b = map.frame(at: Tick(off), sampleRate: rate).rawValue
                    guard b > a else { continue }
                    events.append(MIDIEvent(frame: a, status: 0x90 | (n.channel & 15), data1: n.pitch, data2: max(1, n.velocity)))
                    events.append(MIDIEvent(frame: b, status: 0x80 | (n.channel & 15), data1: n.pitch, data2: 0))
                    endFrame = max(endFrame, b)
                }
                pass += 1
            } while repeating && origin.rawValue + length * pass < limit.rawValue
        }

        if arrangement { for case .midi(let c) in t.clips { add(c, origin: c.start, limit: c.start + c.length, repeating: false) } }
        if let session {
            for e in session.events where e.track == t.id {
                for case let slot? in t.slots where slot.clip.id == e.clip {
                    if case .midi(let c) = slot.clip { add(c, origin: e.startTick, limit: e.endTick, repeating: c.loop) }
                }
            }
        }
        // Note-off before note-on on the same frame, so repeated notes retrigger.
        events.sort { ($0.frame, $0.status & 0xF0 == 0x90 ? 1 : 0) < ($1.frame, $1.status & 0xF0 == 0x90 ? 1 : 0) }
        return events
    }
}
