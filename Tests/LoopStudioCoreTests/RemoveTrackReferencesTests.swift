import Testing
import LoopStudioCore

@Test func removingATrackClearsInputsAndLaunchesAndUndoes() throws {
    var p = Project(name: "P")
    let source = Track(name: "Source", kind: .audio)
    var listener = Track(name: "Listener", kind: .audio)
    listener.inputTrack = source.id
    try Command.insertTrack(track: source, index: 0).apply(to: &p)
    try Command.insertTrack(track: listener, index: 1).apply(to: &p)
    try Command.setLaunches(launches: [Launch(track: source.id, slot: 0, tick: 0), Launch(track: listener.id, slot: 0, tick: 0)]).apply(to: &p)
    let before = p
    let inverse = try Command.removeTrack(id: source.id).apply(to: &p)
    #expect(p.tracks[0].inputTrack == nil, "no input from a track that is gone")
    #expect(p.launches.map(\.track) == [listener.id])
    #expect(p.validate().isEmpty)
    try inverse.apply(to: &p)
    #expect(p.tracks == before.tracks)
    #expect(p.launches == before.launches)
    #expect(p == before)
}
