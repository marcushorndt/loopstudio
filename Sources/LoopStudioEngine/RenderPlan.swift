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
    /// The node whose output the effect listens to (a sidechain). It renders before this node.
    var sidechain: Int? = nil
    /// Where on that node the sidechain taps: before its effects, after them, or after its fader.
    var sidechainTap: SidechainTap = .postMixer
    /// Frames the sidechain signal waits so it lines up with this effect's input, from delay compensation.
    var sidechainDelay = 0
    /// How late the sound at this effect's input is against the song clock: the node's `inputShift` plus the
    /// devices in front of it (inside a rack: the chain's devices in front of it). Its automation is read
    /// that much earlier, so a curve moves the sound it was drawn on.
    var shift = 0
    /// An audio effect rack: its chains. The slot of this plan holds the macros and the selector.
    var rack: RackPlan? = nil
    /// Keys a macro of an enclosing rack drives. Their automation is ignored; the macro sets them.
    var mappedKeys: Set<String> = []
    /// The compiled program of a patch device. The same text gives the same object, so the renderer keeps
    /// the running instance while the text is unchanged.
    var program: PatchProgram? = nil
}

/// One chain of a rack, compiled: its devices, its instrument (MIDI racks), its mixer and its zones.
struct ChainPlan {
    var id: ChainID
    var effects: [EffectPlan] = []
    var instrument: AudioUnitEffect? = nil
    var synth: SynthPlan? = nil
    /// A nested MIDI rack that plays the chain's notes.
    var rackSynth: RackPlan? = nil
    var instrumentDevice: DeviceID? = nil
    var instrumentAuto: [String: AutoLane] = [:]
    var gain: Float = 1
    var panLeft: Float = 1
    var panRight: Float = 1
    var volumeAuto: AutoLane? = nil
    var panAuto: AutoLane? = nil
    var mute = false
    var solo = false
    var zone = ChainZone.full
    var keyZone: ChainZone? = nil
    var velocityZone: ChainZone? = nil
    /// The frames this chain's own devices delay the sound by.
    var latency = 0
    /// Frames added at the chain's end so every chain of the rack arrives together.
    var delay = 0
}

/// A rack, compiled. `latency` is the slowest chain's; the others get `delay` to match it.
struct RackPlan {
    var device: DeviceID
    var isMIDI: Bool
    var chains: [ChainPlan]
    var mappings: [MacroMapping]
    var latency = 0
    /// Keys of this rack (macros, selector) an outer rack's macro drives.
    var mappedKeys: Set<String> = []
}

struct MIDIEvent {
    var frame: Int64
    var status: UInt8
    var data1: UInt8
    var data2: UInt8
}

/// Where each key (channel << 7 | pitch) of a node's notes goes on and off, as sorted frames. The plan swap
/// asks "is this key inside a note at frame f" for every held key: two binary searches here, where a scan of
/// the event list took as long as the song is.
struct NoteIndex {
    private var ons: [Int: [Int64]] = [:]
    private var offs: [Int: [Int64]] = [:]

    init() {}

    /// `events` sorted by frame, note-off before note-on on the same frame.
    init(_ events: [MIDIEvent]) {
        for e in events {
            let kind = e.status & 0xF0
            guard kind == 0x80 || kind == 0x90 else { continue }
            let key = Int(e.status & 0x0F) << 7 | Int(e.data1 & 127)
            if kind == 0x90 && e.data2 > 0 { ons[key, default: []].append(e.frame) } else { offs[key, default: []].append(e.frame) }
        }
    }

    /// True when the next event of `key` at or after `frame` is a note-off: the key is inside a note there.
    /// No allocation: two lookups and two binary searches.
    func heldAt(_ key: Int, frame: Int64) -> Bool {
        guard let off = offs[key].flatMap({ Self.first($0, atOrAfter: frame) }) else { return false }
        guard let on = ons[key].flatMap({ Self.first($0, atOrAfter: frame) }) else { return true }
        return off <= on
    }

    private static func first(_ frames: [Int64], atOrAfter frame: Int64) -> Int64? {
        var lo = 0, hi = frames.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[mid] < frame { lo = mid + 1 } else { hi = mid }
        }
        return lo < frames.count ? frames[lo] : nil
    }
}

/// A built-in instrument on a MIDI track. The renderer makes (or keeps) its `DSPInstrument`.
struct SynthPlan {
    var device: DeviceID
    var kind: String
    var params: [String: Double]
    /// Keys a macro of an enclosing rack drives. See `EffectPlan.mappedKeys`.
    var mappedKeys: Set<String> = []
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
    /// A sidechain somewhere taps this node before its effects, or after them: the renderer keeps that copy.
    var tapPreFX = false, tapPostFX = false
    var volumeAuto: AutoLane? = nil
    var panAuto: AutoLane? = nil
    /// A hosted instrument and the notes it plays, sorted by frame (note-off before note-on on the same frame).
    var instrument: AudioUnitEffect? = nil
    /// Automated parameters of the instrument, keyed like an effect's ("au.<address>", or a built-in key).
    var instrumentAuto: [String: AutoLane] = [:]
    /// A built-in instrument instead of a hosted one. A track has one or the other.
    var synth: SynthPlan? = nil
    /// A MIDI rack as the track's instrument: notes go to its chains. The renderer makes its runtime.
    var rackSynth: RackPlan? = nil
    /// The device that plays the track's notes, whatever its kind. Two plans with the same one keep the notes.
    var instrumentDevice: DeviceID? = nil
    /// The running built-in instrument. The renderer sets it on its own copy of the node; the plan has none.
    var synthUnit: DSPInstrument? = nil
    var midi: [MIDIEvent] = []
    /// Notes of the session clips, in session frames.
    var sessionMidi: [MIDIEvent] = []
    /// `midi` and `sessionMidi` by key, for the note takeover at a plan swap.
    var noteIndex = NoteIndex()
    var sessionNoteIndex = NoteIndex()
    /// The channels (bit n = channel n) whose clips hold a sustain pedal or a pitch bend. A stop releases
    /// the pedal and centres the bend on these, and only these.
    var controlChannels: UInt16 = 0
    /// A hardware destination that gets the notes too (or instead of an instrument). Live: "MIDI To".
    var midiOut: MIDIOutTarget? = nil
    /// Session frame from which this track's arrangement clips and notes are silent, because a session clip
    /// took the track over (or a session stop). `nil`: the arrangement plays.
    var arrangementEnd: Int64? = nil
    /// Nodes that take this node's sound as input, after the fader.
    var taps: [Int] = []
    /// Sound card channels this node monitors ("Ext. In"), before its effects. `right` nil: one channel to both sides.
    var input: (left: Int, right: Int?)? = nil
    /// Latency of the plugins on this node, in frames.
    var latency = 0
    /// Delay on the output connection and on each tap, from plugin delay compensation.
    var outputDelay = 0
    /// A direct hardware output: index into `RenderPlan.outputPorts`. The node then does not feed the master.
    var port: Int? = nil
    var tapDelays: [Int] = []
    /// How late this node's sound is after its fader, from the plugins on its way there.
    var arrival = 0
    /// Frames this node's own clips and notes play late, so they line up with the sound it takes from other
    /// nodes (its inputs arrive this late). The fader and the sends read their automation `outputShift` late.
    var inputShift = 0
    var outputShift = 0
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
    /// The song tempo and meter, for effects and plugins that follow the tempo.
    public internal(set) var tempoMap = TempoMap()
    /// The hardware ports that tracks play to directly, past the master. The renderer has one stereo bus each.
    public internal(set) var outputPorts: [PortID] = []
    var timeSignatures: [TimeSignatureChange] = [TimeSignatureChange(tick: 0, signature: TimeSignature(4, 4))]
    /// The knob values (macros, selector) of every MIDI rack, by device. An effect rack carries its own in its plan.
    var rackParams: [DeviceID: [String: Double]] = [:]

    /// Gain for a level in dB. Silent at and below -96 dB; capped at +60 dB, so an absurd automation value
    /// (a finite 1000 dB passes the command check) cannot turn into an infinite gain.
    public static func dB(_ db: Double) -> Float { db <= -96 ? 0 : Float(pow(10.0, min(db, 60) / 20.0)) }

    /// Balance pan law: unity in the centre, the far side fades to silence at the extreme.
    static func balance(_ pan: Double) -> (Float, Float) {
        let p = min(max(pan, -1), 1)
        if p == 0 { return (1, 1) }
        // Exact zero at the extremes; cos(pi/2) is only almost zero.
        let left = p <= 0 ? 1.0 : (p >= 1 ? 0.0 : cos(p * .pi / 2))
        let right = p >= 0 ? 1.0 : (p <= -1 ? 0.0 : cos(-p * .pi / 2))
        return (Float(left), Float(right))
    }

    /// A track that monitors the sound card: which channels, and whether its clips stay silent meanwhile
    /// (Live's Monitor In plays the input in place of the clips).
    public struct MonitorInput: Hashable, Sendable {
        public var channels: InputChannels
        public var mutesClips: Bool
        public init(channels: InputChannels, mutesClips: Bool) { self.channels = channels; self.mutesClips = mutesClips }
    }

    /// `arrangementEnds`: per track, the session frame from which its arrangement stays silent (see `NodePlan`).
    /// `inputs`: the tracks that monitor the sound card now (armed, or Monitor In), with their channels.
    public static func compile(_ project: Project, bank: AudioBank, session: SessionSimulation? = nil,
                               units: [DeviceID: AudioUnitEffect] = [:], arrangementEnds: [TrackID: Int64] = [:],
                               inputs: [TrackID: MonitorInput] = [:], midiOutputs: [TrackID: MIDIOutTarget] = [:]) -> RenderPlan {
        var warnings: [String] = []
        var outputPorts: [PortID] = []
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

        // A sidechain listens to another track: that track renders first, like a source of a send.
        var listeners: [TrackID: [TrackID]] = [:]
        for t in tracks {
            for d in t.allDevices { // a compressor inside a rack listens too
                guard let source = d.sidechain, source != t.id, project.track(source) != nil, !d.bypassed else { continue }
                listeners[source, default: []].append(t.id)
            }
        }
        // Order: sources before targets (Kahn). Ties keep project order, so the plan is deterministic.
        func ordered(sidechains: Bool) -> [TrackID] {
            func targets(of t: Track) -> [TrackID] { Routing.feeds(of: t, in: project) + (sidechains ? listeners[t.id] ?? [] : []) }
            var incoming = Dictionary(tracks.map { ($0.id, 0) }, uniquingKeysWith: { a, _ in a })
            for t in tracks { for target in targets(of: t) where incoming[target] != nil { incoming[target]! += 1 } }
            var ready = tracks.filter { incoming[$0.id] == 0 }.map(\.id)
            var order: [TrackID] = []
            while !ready.isEmpty {
                let id = ready.removeFirst()
                order.append(id)
                guard let t = project.track(id) else { continue }
                for target in targets(of: t) where incoming[target] != nil {
                    incoming[target]! -= 1
                    if incoming[target] == 0 { ready.append(target) }
                }
            }
            return order
        }
        var order = ordered(sidechains: true)
        var sidechainsOrdered = true
        if order.count != tracks.count, !listeners.isEmpty {
            // The sidechains close a loop (A listens to B, B sends to A): render without them.
            order = ordered(sidechains: false)
            sidechainsOrdered = false
            warnings.append("a sidechain and a send form a loop; the sidechains listen to their own tracks")
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
            guard let d = track.device(device) else { return result }
            if let spec = d.spec {
                // A fixed parameter (a look-ahead) sets the latency this plan compensates: a curve cannot move it.
                for p in spec.params where !p.fixed { if let l = lane(device.rawValue, p.key) { result[p.key] = l } }
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
            // Solo wins over mute: a muted track that is soloed plays. The mute button keeps its state.
            let silent = (t.mute && !t.solo) || !audible.contains(id)
            // A sidechain source still feeds its listeners while muted or not soloed, as in Live: it renders
            // in full, and only its output and its sends are cut. So a kick ducks a soloed bass.
            let tapped = silent && sidechainsOrdered && listeners[id] != nil
            let renders = !silent || tapped
            var clips: [ClipPlan] = []
            // Monitor In: the input takes the place of the clips (a muted track monitors nothing).
            let input = t.kind == .audio && renders && t.audioSource == .external ? inputs[id] : nil
            let clipsSilent = input?.mutesClips ?? false

            if t.kind == .audio && renders && !clipsSilent {
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
                    guard let pcm = warpedAudio(c, raw: raw, startTick: c.start, project: project, bank: bank, trackName: t.name, warnings: &warnings) else { continue }
                    clips.append(ClipPlan(pcm: pcm, start: start, end: end, sourceOffset: offsetFrames, loop: c.loop,
                                          gain: dB(c.gainDb), fadeIn: max(0, fadeIn), fadeOut: max(0, fadeOut),
                                          envelope: envelope(c, from: c.start, start: start, end: end)))
                    endFrame = max(endFrame, end)
                }
            }
            if t.kind == .audio && renders && !clipsSilent, let session {
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
                    guard let pcm = warpedAudio(c, raw: raw, startTick: e.startTick, project: project, bank: bank, trackName: t.name, warnings: &warnings) else { continue }
                    let offsetFrames = max(0, map.frame(at: e.startTick + c.offset, sampleRate: rate).rawValue - start)
                    let passFrames = max(0, map.frame(at: e.startTick + c.length, sampleRate: rate).rawValue - start)
                    clips.append(ClipPlan(pcm: pcm, start: start, end: end, sourceOffset: offsetFrames, loop: c.loop,
                                          gain: dB(c.gainDb), fadeIn: max(0, fadeIn), fadeOut: max(0, fadeOut),
                                          envelope: envelope(c, from: e.startTick, start: start, end: end), session: true,
                                          loopLength: c.loop ? passFrames : 0))
                }
            }
            if t.kind == .midi || t.kind == .group || t.kind == .returnTrack { /* summing nodes or not rendered yet */ }

            var compiled = compile(t.devices, track: t, units: units, rate: rate, auto: { autoParams($0, of: t) },
                                   lane: { lane($0, $1) }, allowInstrument: t.kind == .midi, warnings: &warnings)
            var chain = compiled.effects
            let instrument = compiled.instrument, instrumentDevice = compiled.instrumentDevice
            var synth = compiled.synth
            if sidechainsOrdered { chain = sidechained(chain, of: t, index: index, before: index[t.id] ?? masterIndex) }
            let instrumentAuto = instrumentDevice.map { autoParams($0, of: t) } ?? [:]
            if t.kind != .midi { synth = nil; compiled.rackSynth = nil } // an instrument on an audio track stays silent
            var midi: [MIDIEvent] = [], sessionMidi: [MIDIEvent] = []
            let midiOut = t.kind == .midi ? midiOutputs[t.id] : nil
            // A music effect (`aumf`) in the chain takes the notes too, with or without an instrument in front.
            let plays = instrument != nil || synth != nil || compiled.rackSynth != nil || takesMIDI(chain)
            if t.kind == .midi && renders && (plays || midiOut != nil) {
                midi = midiEvents(of: t, session: nil, map: map, rate: rate, endFrame: &endFrame)
                var ignored: Int64 = 0
                sessionMidi = midiEvents(of: t, session: session, map: map, rate: rate, endFrame: &ignored, arrangement: false)
            } else if t.kind == .midi && !t.clips.isEmpty && !plays && midiOut == nil {
                if let out = t.midiOutput {
                    warnings.append("MIDI track \"\(t.name)\" sends to \(out.destinationName ?? "a MIDI device") that is not connected")
                } else {
                    warnings.append("MIDI track \"\(t.name)\" has no instrument")
                }
            }

            let (pl, pr) = balance(t.pan)
            // Into an audio track the sound enters at its input: Monitor Off closes that input, like a tap's.
            let outputTarget = t.output ?? project.master.id
            let outputHeard = project.track(outputTarget).map { $0.kind != .audio || $0.monitorMode != .off } ?? true
            nodes.append(NodePlan(
                isMaster: false, clips: clips, gain: silent && !tapped ? 0 : dB(t.volumeDb), panLeft: pl, panRight: pr,
                output: tapped || t.isSendsOnly || !outputHeard || !keeps(t.id, outputTarget) ? nil : (t.output.flatMap { index[$0] } ?? masterIndex),
                sends: t.sends.filter { !tapped && keeps(t.id, $0.target) }.compactMap { s in index[s.target].map {
                    SendPlan(target: $0, gain: dB(s.levelDb), preFader: s.preFader,
                             auto: lane(t.id.rawValue, "send.\(s.target.rawValue.uuidString)")) } },
                effects: chain, silenced: silent && !tapped, volumeAuto: lane(t.id.rawValue, "volume"), panAuto: lane(t.id.rawValue, "pan"), instrument: instrument, instrumentAuto: instrumentAuto, synth: synth,
                rackSynth: compiled.rackSynth, instrumentDevice: instrumentDevice, midi: midi, sessionMidi: sessionMidi,
                midiOut: midiOut, arrangementEnd: arrangementEnds[t.id]))
            nodes[nodes.count - 1].noteIndex = NoteIndex(midi)
            nodes[nodes.count - 1].sessionNoteIndex = NoteIndex(sessionMidi)
            var channels: UInt16 = 0
            for e in midi + sessionMidi where e.status & 0xF0 == 0xE0 || (e.status & 0xF0 == 0xB0 && e.data1 == 64) { channels |= 1 << UInt16(e.status & 0x0F) }
            nodes[nodes.count - 1].controlChannels = channels
            if let input {
                nodes[nodes.count - 1].input = (input.channels.first, input.channels.stereo ? input.channels.first + 1 : nil)
            }
            // A direct output: the track plays to its hardware port, not into the master.
            if let port = t.hardwareOutput {
                if !outputPorts.contains(port) { outputPorts.append(port) }
                nodes[nodes.count - 1].output = nil
                nodes[nodes.count - 1].port = outputPorts.firstIndex(of: port)
            }
        }

        var masterEffects = compile(project.master.devices, track: project.master, units: units, rate: rate,
                                    auto: { autoParams($0, of: project.master) }, lane: { lane($0, $1) },
                                    allowInstrument: false, warnings: &warnings).effects
        masterEffects = sidechained(masterEffects, of: project.master, index: index, before: masterIndex)
        let (ml, mr) = balance(project.master.pan)
        nodes.append(NodePlan(isMaster: true, clips: [], gain: project.master.mute ? 0 : dB(project.master.volumeDb),
                              panLeft: ml, panRight: mr, output: nil, sends: [],
                              effects: masterEffects, silenced: project.master.mute,
                              volumeAuto: lane(project.master.id.rawValue, "volume"), panAuto: lane(project.master.id.rawValue, "pan")))
        // A sidechain that taps a node before or after its effects: the renderer keeps that copy of the node.
        func markTaps(_ chain: [EffectPlan]) {
            for e in chain {
                if let s = e.sidechain {
                    if e.sidechainTap == .preFX { nodes[s].tapPreFX = true }
                    if e.sidechainTap == .postFX { nodes[s].tapPostFX = true }
                }
                if let rack = e.rack { for c in rack.chains { markTaps(c.effects) } }
            }
        }
        for n in nodes { markTaps(n.effects) }
        // Input taps: a track that takes another track as input gets that track's sound, unless its monitor is off.
        for t in tracks {
            guard case .track(let source) = t.audioSource, t.monitorMode != .off, keeps(source, t.id),
                  let from = index[source], let to = index[t.id], from < to else { continue }
            nodes[from].taps.append(to)
        }
        for i in nodes.indices {
            nodes[i].latency = Self.latency(of: nodes[i].effects, rate: rate)
                + (nodes[i].instrument?.latencySamples ?? nodes[i].rackSynth?.latency ?? 0)
        }
        var plan = RenderPlan(nodes: nodes, sampleRate: rate, endFrame: endFrame, warnings: warnings,
                              trackOrder: order.map { Optional($0) } + [nil])
        plan.tempoMap = map
        plan.outputPorts = outputPorts
        for t in project.allTracks { for d in t.allDevices where d.isMIDIRack { plan.rackParams[d.id] = d.params } }
        plan.timeSignatures = project.timeSignatures.sorted { $0.tick < $1.tick }
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
            guard let pcm = warpedAudio(c, raw: raw, startTick: passStart, span: pass, project: project, bank: bank,
                                        trackName: trackName, warnings: &warnings) else { continue }
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
                                    trackName: String, warnings: inout [String]) -> PCMBuffer? {
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
        return bank.warped(key: key, clip: c.id) {
            TimeStretch.stretch(raw, mode: c.warpMode, outFrames: mapping.outFrames, source: mapping.source)
        }
    }

    struct Compiled {
        var effects: [EffectPlan] = []
        var instrument: AudioUnitEffect? = nil
        var synth: SynthPlan? = nil
        var rackSynth: RackPlan? = nil
        var instrumentDevice: DeviceID? = nil
    }

    /// True when an effect of the chain (racks included) is a hosted music effect, which takes the track's
    /// MIDI like an instrument. A bypassed one does not run, so it takes none.
    static func takesMIDI(_ effects: [EffectPlan]) -> Bool {
        effects.contains { e in
            guard !e.bypassed else { return false }
            if let unit = e.unit { return unit.acceptsMIDI && !unit.isInstrument }
            return e.rack?.chains.contains { takesMIDI($0.effects) } ?? false
        }
    }

    /// The frames a chain of effects delays the sound by: plugins by their reported latency, built-in devices
    /// by their look-ahead, a rack by its slowest chain.
    static func latency(of effects: [EffectPlan], rate: Double) -> Int {
        effects.filter { !$0.bypassed }.reduce(0) {
            $0 + ($1.unit?.latencySamples ?? $1.rack?.latency ?? DSPEffect.latency(kind: $1.kind, params: $1.params, sampleRate: rate))
        }
    }

    /// Compiles a device list: the effects in order, and the instrument (the first one that is not bypassed,
    /// hosted, built in, or a MIDI rack) when `allowInstrument`. A rack compiles its chains the same way.
    private static func compile(_ devices: [DeviceSlot], track: Track, units: [DeviceID: AudioUnitEffect], rate: Double,
                                auto: (DeviceID) -> [String: AutoLane], lane: (UUID, String) -> AutoLane?,
                                allowInstrument: Bool, warnings: inout [String]) -> Compiled {
        var out = Compiled()
        for d in devices {
            if d.format == "builtin" {
                guard let spec = d.spec else { continue }
                if d.identifier == "patch" {
                    // A patch that does not compile passes the sound through, and the warning says why.
                    switch PatchCompiler.cached(d.source ?? "") {
                    case .success(let program):
                        var plan = EffectPlan(device: d.id, kind: "patch", params: d.params, bypassed: d.bypassed, auto: auto(d.id))
                        plan.program = program
                        out.effects.append(plan)
                    case .failure(let error):
                        warnings.append("\(d.name) on \"\(track.name)\" does not compile: \(error)")
                    }
                    continue
                }
                if spec.isRack {
                    let rack = compileRack(d, track: track, units: units, rate: rate, auto: auto, lane: lane, warnings: &warnings)
                    if d.identifier == "midirack" {
                        if allowInstrument, out.instrumentDevice == nil, !d.bypassed { out.rackSynth = rack; out.instrumentDevice = d.id }
                        else if !allowInstrument { warnings.append("\(d.name) on \"\(track.name)\" plays notes only on a MIDI track") }
                        continue
                    }
                    out.effects.append(EffectPlan(device: d.id, kind: d.identifier, params: d.params, bypassed: d.bypassed, auto: auto(d.id), rack: rack))
                    continue
                }
                if spec.isInstrument {
                    if allowInstrument, out.instrumentDevice == nil, !d.bypassed {
                        out.synth = SynthPlan(device: d.id, kind: d.identifier, params: d.params); out.instrumentDevice = d.id
                    }
                    continue
                }
                out.effects.append(EffectPlan(device: d.id, kind: d.identifier, params: d.params, bypassed: d.bypassed, auto: auto(d.id)))
            } else if d.format == "audiounit" {
                guard let unit = units[d.id] else { warnings.append("\(d.name) on \"\(track.name)\" is not loaded"); continue }
                if unit.isInstrument {
                    if allowInstrument, out.instrumentDevice == nil, !d.bypassed { out.instrument = unit; out.instrumentDevice = d.id }
                } else {
                    out.effects.append(EffectPlan(device: d.id, kind: "audiounit", params: [:], bypassed: d.bypassed, auto: auto(d.id), unit: unit))
                }
            } else {
                warnings.append("\(d.name) on \"\(track.name)\" uses an unsupported plugin format")
            }
        }
        return out
    }

    /// A rack: every chain compiled, the slowest chain's latency as the rack's, the others delayed to match,
    /// and the keys its macros drive marked on the plans inside.
    private static func compileRack(_ d: DeviceSlot, track: Track, units: [DeviceID: AudioUnitEffect], rate: Double,
                                    auto: (DeviceID) -> [String: AutoLane], lane: (UUID, String) -> AutoLane?,
                                    warnings: inout [String]) -> RackPlan {
        let isMIDI = d.identifier == "midirack"
        var chains: [ChainPlan] = []
        for c in d.rack?.chains ?? [] {
            let sub = compile(c.devices, track: track, units: units, rate: rate, auto: auto, lane: lane, allowInstrument: isMIDI, warnings: &warnings)
            var chain = ChainPlan(id: c.id, effects: sub.effects, instrument: sub.instrument, synth: sub.synth, rackSynth: sub.rackSynth,
                                  instrumentDevice: sub.instrumentDevice, instrumentAuto: sub.instrumentDevice.map(auto) ?? [:])
            chain.gain = c.mute && !c.solo ? 0 : dB(c.volumeDb)
            (chain.panLeft, chain.panRight) = balance(c.pan)
            chain.volumeAuto = lane(c.id.rawValue, "volume")
            chain.panAuto = lane(c.id.rawValue, "pan")
            chain.mute = c.mute; chain.solo = c.solo
            chain.zone = c.zone.normalized; chain.keyZone = c.keyZone?.normalized; chain.velocityZone = c.velocityZone?.normalized
            chain.latency = latency(of: chain.effects, rate: rate) + (chain.instrument?.latencySamples ?? chain.rackSynth?.latency ?? 0)
            chains.append(chain)
        }
        let slowest = chains.map(\.latency).max() ?? 0
        for i in chains.indices { chains[i].delay = slowest - chains[i].latency }
        var rack = RackPlan(device: d.id, isMIDI: isMIDI, chains: chains, mappings: d.rack?.mappings ?? [], latency: slowest)
        for m in rack.mappings { markMapped(&rack, node: m.target.node, key: m.target.parameter) }
        return rack
    }

    /// Marks a key as macro-driven on the device plan inside `rack` that has that node, at any depth.
    private static func markMapped(_ rack: inout RackPlan, node: UUID, key: String) {
        for c in rack.chains.indices {
            for e in rack.chains[c].effects.indices {
                if rack.chains[c].effects[e].device.rawValue == node { rack.chains[c].effects[e].mappedKeys.insert(key) }
                if rack.chains[c].effects[e].rack != nil { markMapped(&rack.chains[c].effects[e].rack!, node: node, key: key) }
            }
            if rack.chains[c].synth?.device.rawValue == node { rack.chains[c].synth!.mappedKeys.insert(key) }
            if rack.chains[c].rackSynth != nil {
                if rack.chains[c].rackSynth!.device.rawValue == node { rack.chains[c].rackSynth!.mappedKeys.insert(key) }
                markMapped(&rack.chains[c].rackSynth!, node: node, key: key)
            }
        }
    }

    /// Resolves the sidechain of each effect (racks included) to the node it listens to. Only a node that
    /// renders before `before` (this node's index) can be listened to; any other sidechain falls back to the own input.
    private static func sidechained(_ chain: [EffectPlan], of track: Track, index: [TrackID: Int], before: Int) -> [EffectPlan] {
        chain.map { e in
            var e = e
            if var rack = e.rack {
                for c in rack.chains.indices { rack.chains[c].effects = sidechained(rack.chains[c].effects, of: track, index: index, before: before) }
                e.rack = rack
            }
            guard let device = track.device(e.device), let source = device.sidechain, let i = index[source], i < before else { return e }
            e.sidechain = i
            e.sidechainTap = device.tap
            return e
        }
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
                // The groove of the clip moves the notes here; the clip keeps them straight.
                for n in c.playedNotes where n.tick.rawValue < length {
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
                // Sustain, mod wheel, pitch bend: at their ticks, looping with the clip like the notes. A ramp
                // sends the steps between it and the next event of its kind, one per 1/128 note where the value changes.
                let controls = c.controls.filter { $0.tick.rawValue < length && MIDIControlEvent.isControl(status: $0.status) }.sorted { $0.tick < $1.tick }
                for (i, k) in controls.enumerated() {
                    let at = base + k.tick.rawValue
                    if at >= limit.rawValue { continue }
                    events.append(MIDIEvent(frame: map.frame(at: Tick(at), sampleRate: rate).rawValue, status: k.status, data1: k.data1, data2: k.data2))
                    guard k.ramp, let next = controls[(i + 1)...].first(where: { k.sameKind(as: $0) }), next.tick > k.tick else { continue }
                    let step = Tick.perQuarter / 32
                    let from = k.wideValue, to = next.wideValue
                    var last = from
                    var t = k.tick.rawValue + step
                    while t < next.tick.rawValue && base + t < limit.rawValue {
                        let value = from + Int((Double(to - from) * Double(t - k.tick.rawValue) / Double(next.tick.rawValue - k.tick.rawValue)).rounded())
                        if value != last {
                            let e = k.with(wideValue: value)
                            events.append(MIDIEvent(frame: map.frame(at: Tick(base + t), sampleRate: rate).rawValue, status: e.status, data1: e.data1, data2: e.data2))
                            last = value
                        }
                        t += step
                    }
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
        // Note-off before note-on on the same frame, so repeated notes retrigger; a control (a bend, the
        // sustain pedal) before the note-on it belongs to.
        func rank(_ status: UInt8) -> Int { status & 0xF0 == 0x80 ? 0 : (status & 0xF0 == 0x90 ? 2 : 1) }
        events.sort { ($0.frame, rank($0.status)) < ($1.frame, rank($1.status)) }
        return events
    }
}
