import Foundation
@testable import LoopStudioCore

/// Small deterministic generator, so a failing random test can be repeated.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ upperBound: Int) -> Int { Int(next() % UInt64(max(upperBound, 1))) }
}

enum Fixture {
    static let loopAsset = Asset(sha256: "aa", name: "loop.wav", frames: 4 * 48_000, sampleRate: 48_000, channels: 2)
    static let songAsset = Asset(sha256: "bb", name: "song.wav", frames: 60 * 48_000, sampleRate: 48_000, channels: 2)

    /// A project with two assets and no tracks.
    static func baseProject() -> Project {
        var p = Project(name: "Test")
        for asset in [loopAsset, songAsset] { try! Command.addAsset(asset: asset).apply(to: &p) }
        return p
    }

    static func dummySlot(follow: FollowActions? = nil) -> SessionSlot {
        SessionSlot(clip: .dummy(DummyClip(length: 3840)), follow: follow)
    }

    static func follow(_ a: FollowActionKind, _ b: FollowActionKind = .stop, wa: Double = 1, wb: Double = 0,
                       edge: BlockEdge = .wrap) -> FollowActions {
        FollowActions(a: FollowAction(a, weight: wa), b: FollowAction(b, weight: wb), time: .loops(1), edge: edge)
    }
}
