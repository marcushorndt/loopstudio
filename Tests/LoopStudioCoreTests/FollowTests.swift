import Foundation
import Testing
@testable import LoopStudioCore

/// Slots 0...3 form one block, slot 4 is empty, slot 5 is a second block.
/// Only slot `current` has follow actions.
private func slots(current: Int, follow: FollowActions) -> [SessionSlot?] {
    (0...5).map { i in
        i == 4 ? nil : Fixture.dummySlot(follow: i == current ? follow : nil)
    }
}

private func random(_ launch: Int = 0, clip: ClipID = ClipID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)) -> FollowRandom {
    FollowRandom(seed: 1, clip: clip, launchCount: launch)
}

@Test func blockStopsAtGaps() {
    let s = slots(current: 0, follow: Fixture.follow(.next))
    #expect(FollowResolver.block(containing: 2, in: s) == 0...3)
    #expect(FollowResolver.block(containing: 5, in: s) == 5...5)
    #expect(FollowResolver.block(containing: 4, in: s) == nil)
    #expect(FollowResolver.block(containing: 99, in: s) == nil)
}

@Test func weightsDecideTheChance() {
    let follow = Fixture.follow(.next, .replay, wa: 3, wb: 1)
    var a = 0
    let n = 20_000
    for launch in 0..<n where FollowResolver.chooseAction(follow, random: random(launch))?.kind == .next { a += 1 }
    let share = Double(a) / Double(n)
    #expect(share > 0.72 && share < 0.78)
}

@Test func zeroWeightNeverHappens() {
    let follow = Fixture.follow(.next, .replay, wa: 0, wb: 2)
    for launch in 0..<2_000 {
        #expect(FollowResolver.chooseAction(follow, random: random(launch))?.kind == .replay)
    }
    let none = Fixture.follow(.next, .replay, wa: 0, wb: 0)
    #expect(FollowResolver.chooseAction(none, random: random()) == nil)
}

@Test func badWeightsCountAsZero() {
    let follow = FollowActions(a: FollowAction(.next, weight: .nan), b: FollowAction(.replay, weight: -5), time: .loops(1))
    #expect(FollowResolver.chooseAction(follow, random: random()) == nil)
    let huge = FollowActions(a: FollowAction(.next, weight: .infinity), b: FollowAction(.replay, weight: 1), time: .loops(1))
    #expect(FollowResolver.chooseAction(huge, random: random(3))?.kind == .next)
}

@Test func choicesAreReproducible() {
    let s = slots(current: 1, follow: Fixture.follow(.any, .other, wa: 1, wb: 1))
    let first = (0..<500).map { FollowResolver.resolve(current: 1, slots: s, random: random($0)) }
    let second = (0..<500).map { FollowResolver.resolve(current: 1, slots: s, random: random($0)) }
    #expect(first == second)
    #expect(Set(first).count > 1)
}

@Test func differentSeedsGiveDifferentSequences() {
    let id = ClipID()
    let a = (0..<200).map { FollowRandom(seed: 1, clip: id, launchCount: $0).unit(draw: 0) }
    let b = (0..<200).map { FollowRandom(seed: 2, clip: id, launchCount: $0).unit(draw: 0) }
    #expect(a != b)
    #expect(a.allSatisfy { $0 >= 0 && $0 < 1 })
}

@Test func blockEdgeActions() {
    let top = slots(current: 2, follow: Fixture.follow(.topOfBlock))
    #expect(FollowResolver.resolve(current: 2, slots: top, random: random()) == .play(slot: 0))
    let end = slots(current: 1, follow: Fixture.follow(.endOfBlock))
    #expect(FollowResolver.resolve(current: 1, slots: end, random: random()) == .play(slot: 3))
}

@Test func nextAndPreviousAtTheEdge() {
    let next = slots(current: 3, follow: Fixture.follow(.next))
    #expect(FollowResolver.resolve(current: 3, slots: next, random: random()) == .play(slot: 0))
    let nextStop = slots(current: 3, follow: Fixture.follow(.next, edge: .stop))
    #expect(FollowResolver.resolve(current: 3, slots: nextStop, random: random()) == .stop)
    let prev = slots(current: 0, follow: Fixture.follow(.previous))
    #expect(FollowResolver.resolve(current: 0, slots: prev, random: random()) == .play(slot: 3))
    let middle = slots(current: 2, follow: Fixture.follow(.next))
    #expect(FollowResolver.resolve(current: 2, slots: middle, random: random()) == .play(slot: 3))
}

@Test func otherNeverPicksTheCurrentSlot() {
    let s = slots(current: 2, follow: Fixture.follow(.other))
    var seen = Set<Int>()
    for launch in 0..<2_000 {
        guard case .play(let slot) = FollowResolver.resolve(current: 2, slots: s, random: random(launch)) else {
            Issue.record("other must always play a slot")
            return
        }
        #expect(slot != 2)
        #expect((0...3).contains(slot))
        seen.insert(slot)
    }
    #expect(seen == [0, 1, 3])
}

@Test func anyStaysInsideTheBlockAndCanRepeat() {
    let s = slots(current: 2, follow: Fixture.follow(.any))
    var seen = Set<Int>()
    for launch in 0..<2_000 {
        if case .play(let slot) = FollowResolver.resolve(current: 2, slots: s, random: random(launch)) { seen.insert(slot) }
    }
    #expect(seen == [0, 1, 2, 3])
}

@Test func singleSlotBlockFallsBackToReplay() {
    let s = slots(current: 5, follow: Fixture.follow(.other))
    #expect(FollowResolver.resolve(current: 5, slots: s, random: random()) == .play(slot: 5))
}

@Test func jumpNeedsAnOccupiedTarget() {
    let ok = FollowActions(a: FollowAction(.jump, jumpIndex: 5), b: FollowAction(.stop, weight: 0), time: .loops(1))
    #expect(FollowResolver.resolve(current: 0, slots: slots(current: 0, follow: ok), random: random()) == .play(slot: 5))
    let gap = FollowActions(a: FollowAction(.jump, jumpIndex: 4), b: FollowAction(.stop, weight: 0), time: .loops(1))
    #expect(FollowResolver.resolve(current: 0, slots: slots(current: 0, follow: gap), random: random()) == .none)
}

@Test func noFollowActionsMeansStopForAnEmptySlot() {
    let s = slots(current: 0, follow: Fixture.follow(.next))
    #expect(FollowResolver.resolve(current: 4, slots: s, random: random()) == .stop)
}
