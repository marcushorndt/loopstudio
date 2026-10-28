import LoopStudioCore

/// A small project with two session blocks and follow actions, so the window has something to show.
enum DemoProject {
    static func make() -> Project {
        var project = Project(name: "Demo")
        let bar = Tick(4 * Tick.perQuarter)

        func midiClip(_ bars: Int64, pitches: [UInt8]) -> Clip {
            let notes = pitches.enumerated().map { i, pitch in
                MIDINote(tick: Tick(Int64(i) * Tick.perQuarter), length: Tick(Tick.perQuarter / 2), pitch: pitch)
            }
            return .midi(MIDIClip(length: Tick(bar.rawValue * bars), notes: notes))
        }

        let a = FollowAction(.next, weight: 3), b = FollowAction(.any, weight: 1)
        var drums = Track(name: "Drums", kind: .midi, colorIndex: 0)
        drums.slots = [
            SessionSlot(clip: midiClip(1, pitches: [36, 42, 38, 42]), follow: FollowActions(a: a, b: b, time: .loops(2))),
            SessionSlot(clip: midiClip(1, pitches: [36, 36, 38, 46]), follow: FollowActions(a: FollowAction(.topOfBlock, weight: 1), b: FollowAction(.other, weight: 1), time: .loops(2))),
            SessionSlot(clip: midiClip(1, pitches: [36, 42, 42, 38]), follow: FollowActions(a: FollowAction(.endOfBlock), b: FollowAction(.replay), time: .loops(1))),
            nil,
            SessionSlot(clip: midiClip(2, pitches: [49, 51, 49, 51]), follow: FollowActions(a: FollowAction(.stop), b: FollowAction(.topOfBlock), time: .loops(1))),
        ]

        var bass = Track(name: "Bass", kind: .midi, colorIndex: 3)
        bass.slots = [
            SessionSlot(clip: midiClip(2, pitches: [36, 36, 43, 41]), follow: FollowActions(a: FollowAction(.next), b: FollowAction(.replay), time: .loops(1))),
            SessionSlot(clip: midiClip(2, pitches: [34, 34, 41, 39]), follow: FollowActions(a: FollowAction(.topOfBlock), b: FollowAction(.next, weight: 2), time: .loops(1))),
        ]

        var keys = Track(name: "Keys", kind: .midi, colorIndex: 5)
        keys.clips = [midiClip(4, pitches: [60, 64, 67, 72]), midiClip(4, pitches: [58, 62, 65, 70])]
        if case .midi(var second) = keys.clips[1] { second.start = Tick(bar.rawValue * 4); keys.clips[1] = .midi(second) }

        project.tracks = [drums, bass, keys]
        project.launches = [
            Launch(track: drums.id, slot: 0, tick: 0),
            Launch(track: bass.id, slot: 0, tick: Tick(bar.rawValue * 2)),
        ]
        return project
    }
}
