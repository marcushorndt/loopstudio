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
}

struct EffectPlan {
    var device: DeviceID
    var kind: String
    var params: [String: Double]
    var bypassed: Bool
}

struct SendPlan {
    var target: Int
    var gain: Float
    var preFader: Bool
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
}

/// Everything the renderer needs, compiled from a project. Immutable; built off the audio thread.
/// Nodes are sorted so that a node always comes before the nodes it feeds, and the master is last.
public struct RenderPlan {
    var nodes: [NodePlan]
    public let sampleRate: Double
    /// First frame after the last sounding clip.
    public let endFrame: Int64
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

    public static func compile(_ project: Project, bank: AudioBank, session: SessionSimulation? = nil) -> RenderPlan {
        var warnings: [String] = []
        let tracks = project.tracks
        let rate = project.sampleRate
        let map = project.tempoMap

        // Which tracks are audible: solo keeps soloed tracks and everything they feed.
        var audible = Set(tracks.map(\.id))
        let soloed = tracks.filter(\.solo).map(\.id)
        if !soloed.isEmpty {
            var reach = Set<TrackID>()
            var stack = soloed
            while let id = stack.popLast() {
                guard reach.insert(id).inserted, let t = project.track(id) else { continue }
                stack.append(contentsOf: Routing.edges(of: t))
            }
            audible = reach
        }

        // Order: sources before targets (Kahn). Ties keep project order, so the plan is deterministic.
        var incoming = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, 0) })
        for t in tracks { for target in Routing.edges(of: t) where incoming[target] != nil { incoming[target]! += 1 } }
        var ready = tracks.filter { incoming[$0.id] == 0 }.map(\.id)
        var order: [TrackID] = []
        while !ready.isEmpty {
            let id = ready.removeFirst()
            order.append(id)
            guard let t = project.track(id) else { continue }
            for target in Routing.edges(of: t) where incoming[target] != nil {
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

        for id in order {
            let t = project.track(id)!
            if t.hardwareOutput != nil { warnings.append("track \"\(t.name)\" goes straight to a hardware port and is not in the master mix") }
            let silent = t.mute || !audible.contains(id) || t.hardwareOutput != nil
            var clips: [ClipPlan] = []

            if t.kind == .audio && !silent {
                for case .audio(let c) in t.clips where !c.muted {
                    guard let pcm = bank.buffer(for: c.asset), pcm.frames > 0 else {
                        warnings.append("clip on \"\(t.name)\" has no audio (missing or unreadable file)")
                        continue
                    }
                    if c.warpMode != .off { warnings.append("clip on \"\(t.name)\" uses warping, which is not rendered yet; it plays unwarped") }
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
                    clips.append(ClipPlan(pcm: pcm, start: start, end: end, sourceOffset: offsetFrames, loop: c.loop,
                                          gain: dB(c.gainDb), fadeIn: max(0, fadeIn), fadeOut: max(0, fadeOut)))
                    endFrame = max(endFrame, end)
                }
            }
            if t.kind == .audio && !silent, let session {
                for e in session.events where e.track == id {
                    guard case .audio(let c)? = project.findClip(e.clip)?.clip, !c.muted,
                          let pcm = bank.buffer(for: c.asset), pcm.frames > 0 else { continue }
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
                    clips.append(ClipPlan(pcm: pcm, start: start, end: end, sourceOffset: 0, loop: c.loop,
                                          gain: dB(c.gainDb), fadeIn: max(0, fadeIn), fadeOut: max(0, fadeOut)))
                }
            }
            if t.kind == .midi || t.kind == .group || t.kind == .returnTrack { /* summing nodes or not rendered yet */ }
            if t.kind == .midi && !t.clips.isEmpty { warnings.append("MIDI track \"\(t.name)\" needs an instrument, which is not rendered yet") }

            let (pl, pr) = balance(t.pan)
            nodes.append(NodePlan(
                isMaster: false, clips: clips, gain: silent ? 0 : dB(t.volumeDb), panLeft: pl, panRight: pr,
                output: t.output.flatMap { index[$0] } ?? masterIndex,
                sends: t.sends.compactMap { s in index[s.target].map { SendPlan(target: $0, gain: dB(s.levelDb), preFader: s.preFader) } },
                effects: effects(of: t, warnings: &warnings)))
        }

        let (ml, mr) = balance(project.master.pan)
        nodes.append(NodePlan(isMaster: true, clips: [], gain: project.master.mute ? 0 : dB(project.master.volumeDb),
                              panLeft: ml, panRight: mr, output: nil, sends: [],
                              effects: effects(of: project.master, warnings: &warnings)))
        return RenderPlan(nodes: nodes, sampleRate: rate, endFrame: endFrame, warnings: warnings,
                          trackOrder: order.map { Optional($0) } + [nil])
    }

    private static func effects(of track: Track, warnings: inout [String]) -> [EffectPlan] {
        track.devices.compactMap { d in
            guard d.format == "builtin", BuiltInEffects.spec(d.identifier) != nil else {
                if d.format != "builtin" { warnings.append("\(d.name) on \"\(track.name)\" is not hosted yet") }
                return nil
            }
            return EffectPlan(device: d.id, kind: d.identifier, params: d.params, bypassed: d.bypassed)
        }
    }
}
