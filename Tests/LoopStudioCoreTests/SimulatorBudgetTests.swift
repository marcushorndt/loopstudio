import Testing
@testable import LoopStudioCore

@Test func oneFastChainDoesNotSilenceLaterTracks() {
    var p = Fixture.baseProject()
    var fast = Track(name: "Fast", kind: .midi)
    fast.slots = [SessionSlot(clip: .dummy(DummyClip(length: 3840)),
                              follow: FollowActions(a: FollowAction(.replay, weight: 1), b: FollowAction(.stop, weight: 0),
                                                    time: .ticks(1)))]
    var calm = Track(name: "Calm", kind: .midi)
    calm.slots = [Fixture.dummySlot()]
    p.tracks = [fast, calm]
    p.launches = [Launch(track: fast.id, slot: 0, tick: 0), Launch(track: calm.id, slot: 0, tick: 0)]

    let sim = SessionSimulator.run(p, horizon: Tick(Int64(SessionSimulator.eventLimit) * 10))
    #expect(sim.events.contains { $0.track == calm.id })
    #expect(sim.events.filter { $0.track == fast.id }.count <= SessionSimulator.eventLimit / 2)
    #expect(sim.warnings.contains { $0.contains("Fast") && $0.contains("stops at tick") })
    // The cut track is silent after its last event, not held to the horizon.
    let last = sim.events.filter { $0.track == fast.id }.map(\.endTick).max()!
    #expect(last < Tick(Int64(SessionSimulator.eventLimit)))
}
