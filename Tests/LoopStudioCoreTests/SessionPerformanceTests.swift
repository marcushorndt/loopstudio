import Foundation
import Testing
@testable import LoopStudioCore

private let bar = Tick(3840)
private func bars(_ n: Int64) -> Tick { Tick(3840 * n) }

/// One track with dummy clips in slots 0 and 1, and a second track with a clip in slot 0.
private func project() -> (Project, Track, Track) {
    var p = Fixture.baseProject()
    let a = Track(name: "Bass", kind: .audio, slots: [Fixture.dummySlot(), Fixture.dummySlot()])
    let b = Track(name: "Drums", kind: .audio, slots: [Fixture.dummySlot()])
    try! Command.insertTrack(track: a, index: 0).apply(to: &p)
    try! Command.insertTrack(track: b, index: 1).apply(to: &p)
    return (p, p.tracks[0], p.tracks[1])
}

private func horizon() -> Tick { bars(40) }

/// The bug: a launch from the last run lay after the new start and waited to play again.
@Test func playAfterStopStartsOnlyWhatPlayed() {
    let (p, a, _) = project()
    var s = SessionPerformance()
    s.add(Launch(track: a.id, slot: 0, tick: 0), in: p)
    s.add(Launch(track: a.id, slot: 1, tick: bars(4)), in: p)
    s.simulate(p, horizon: horizon())
    // A dummy clip plays one bar. Stop while slot 1 plays; Space returns to the start.
    s.stop(at: bars(4) + Tick(100), timeline: bars(4) + Tick(100), trackOrder: p.tracks.map(\.id))
    #expect(s.isEmpty)
    #expect(s.readySlot(of: a.id) == 1)
    #expect(s.slotState(of: a, row: 1, at: 0, playing: false) == .ready)
    #expect(s.slotState(of: a, row: 0, at: 0, playing: false) == .stopped)

    s.resume(at: 0, in: p)
    s.simulate(p, horizon: horizon())
    #expect(s.launches == [Launch(track: a.id, slot: 1, tick: 0)])
    #expect(s.slotState(of: a, row: 1, at: 0, playing: true).progress != nil)
    // Nothing waits: slot 0 does not come back at bar 1 or ever.
    for t in stride(from: Int64(0), to: bar.rawValue * 10, by: 960) {
        #expect(s.slotState(of: a, row: 0, at: Tick(t), playing: true) == .stopped)
    }
}

@Test func resumeFromTheSamePlaceStartsTheClipAgain() {
    let (p, a, _) = project()
    var s = SessionPerformance()
    s.add(Launch(track: a.id, slot: 0, tick: bars(2)), in: p)
    s.simulate(p, horizon: horizon())
    // Paused mid-bar with Shift+Space; the session clock ran ahead of the timeline by 2 bars (loop jumps).
    let session = bars(2) + Tick(1000), timeline = Tick(1000)
    s.stop(at: session, timeline: timeline, trackOrder: [a.id])
    s.resume(at: timeline, in: p)
    // A session clip never goes on from the middle: it starts from its beginning at the play position.
    #expect(s.launches == [Launch(track: a.id, slot: 0, tick: timeline)])
}

@Test func resumeElsewhereStartsTheClipAtThePlayPosition() {
    let (p, a, _) = project()
    var s = SessionPerformance()
    s.add(Launch(track: a.id, slot: 0, tick: 0), in: p)
    s.simulate(p, horizon: horizon())
    s.stop(at: Tick(500), timeline: Tick(500), trackOrder: [a.id])
    // The bug: the launch sat on the bar before, so the clip began 500 ticks in, the same 500 each time.
    s.resume(at: bars(5) + Tick(500), in: p)
    #expect(s.launches == [Launch(track: a.id, slot: 0, tick: bars(5) + Tick(500))])
}

@Test func aStoppedTrackStaysSilentAfterPlay() {
    let (p, a, b) = project()
    var s = SessionPerformance()
    s.add(Launch(track: a.id, slot: 0, tick: 0), in: p)
    s.add(Launch(track: b.id, slot: 0, tick: 0), in: p)
    s.add(Launch(track: b.id, slot: nil, tick: Tick(100)), in: p)
    s.simulate(p, horizon: horizon())
    s.stop(at: Tick(500), timeline: Tick(500), trackOrder: p.tracks.map(\.id))
    #expect(s.readySlot(of: b.id) == nil)
    s.resume(at: 0, in: p)
    #expect(s.launches.contains(Launch(track: b.id, slot: nil, tick: 0)))
    #expect(s.launches.contains(Launch(track: a.id, slot: 0, tick: 0)))
}

@Test func aReadyClipFollowsItsSlot() {
    var (p, a, _) = project()
    var s = SessionPerformance()
    s.add(Launch(track: a.id, slot: 1, tick: 0), in: p)
    s.simulate(p, horizon: horizon())
    s.stop(at: Tick(500), timeline: Tick(500), trackOrder: [a.id])
    // A scene inserted above moves the clip one row down.
    p.tracks[0].slots.insert(nil, at: 0)
    s.followMovedSlots(in: p)
    #expect(s.readySlot(of: a.id) == 2)
}

@Test func aStopWaitsUntilItsBar() {
    let (p, a, _) = project()
    var s = SessionPerformance()
    s.add(Launch(track: a.id, slot: 0, tick: 0), in: p)
    s.add(Launch(track: a.id, slot: nil, tick: Tick(3000)), in: p)
    s.simulate(p, horizon: horizon())
    #expect(s.stopPending(a.id, at: Tick(2000)))
    #expect(s.slotState(of: a, row: 0, at: Tick(2000), playing: true).isStopping)
    #expect(!s.stopPending(a.id, at: Tick(3000)))
    #expect(s.slotState(of: a, row: 0, at: Tick(3000), playing: true) == .stopped)
}

@Test func clearForgetsWhatAStopKept() {
    let (p, a, _) = project()
    var s = SessionPerformance()
    s.add(Launch(track: a.id, slot: 0, tick: 0), in: p)
    s.simulate(p, horizon: horizon())
    s.stop(at: Tick(500), timeline: Tick(500), trackOrder: [a.id])
    s.clear()
    let resumed = s.resume(at: 0, in: p)
    #expect(!resumed)
    #expect(s.isEmpty)
}

@Test func barBeforeATick() {
    var p = Fixture.baseProject()
    #expect(p.barBoundary(atOrBefore: bars(2)) == bars(2))
    #expect(p.barBoundary(atOrBefore: bars(2) + Tick(1)) == bars(2))
    #expect(p.barBoundary(atOrBefore: bar - Tick(1)) == 0)
    // From bar 3 on, 3/4: bars of 2880 ticks.
    p.timeSignatures.append(TimeSignatureChange(tick: bars(2), signature: TimeSignature(3, 4)))
    #expect(p.barBoundary(atOrBefore: bars(2) + Tick(2880 + 10)) == bars(2) + Tick(2880))
}

/// Saved with the project: what plays comes back as ready, and Play starts it from the first bar.
@Test func aSnapshotComesBackAsReadyAndPlaysAgain() {
    let (p, a, b) = project()
    var s = SessionPerformance()
    s.add(Launch(track: a.id, slot: 1, tick: 0), in: p)
    s.add(Launch(track: b.id, slot: 0, tick: 0), in: p)
    s.add(Launch(track: b.id, slot: nil, tick: 500), in: p)
    s.simulate(p, horizon: horizon())
    // While the transport runs (the dummy clips last one bar): track a plays slot 1, track b was stopped.
    let snap = s.snapshot(at: 1000)
    #expect(snap.count == 2)
    #expect(snap.first { $0.track == a.id }?.slot == 1)
    #expect(snap.first { $0.track == b.id }?.slot == nil)
    // After a stop, the snapshot is what the stop kept.
    s.stop(at: 1000, timeline: 1000, trackOrder: [a.id, b.id])
    #expect(s.snapshot(at: 5000).map(\.slot) == s.kept.map(\.slot))

    // A fresh performance (a reopened project) takes the entries as ready.
    var fresh = SessionPerformance()
    fresh.restore(snap)
    #expect(fresh.readySlot(of: a.id) == 1)
    #expect(fresh.readySlot(of: b.id) == nil)
    #expect(fresh.isEmpty, "nothing plays until Play")
    let resumed = fresh.resume(at: 0, in: p)
    #expect(resumed)
    fresh.simulate(p, horizon: horizon())
    #expect(fresh.plays(of: a.id, at: 0).now?.slot == 1)
    #expect(fresh.plays(of: b.id, at: 0).now == nil, "the stopped track stays silent")
    // Nothing saved: nothing changes.
    var empty = SessionPerformance()
    empty.restore([])
    let resumedEmpty = empty.resume(at: 0, in: p)
    #expect(empty.kept.isEmpty && !resumedEmpty)
}
