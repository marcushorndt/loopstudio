import Foundation

// Session view: clip slots in a column per track, with follow actions.
//
// A BLOCK is a run of occupied slots in one track with no empty slot between them.
// A follow action runs when the clip's follow time is over. Each slot holds two actions,
// A and B. Their weights decide the chance: P(A) = wA / (wA + wB).

public enum FollowActionKind: String, Codable, Sendable, CaseIterable {
    /// Stop playing this track.
    case stop
    /// Play this slot again.
    case replay
    /// The next slot in the block.
    case next
    /// The previous slot in the block.
    case previous
    /// The first slot of the block.
    case topOfBlock
    /// The last slot of the block.
    case endOfBlock
    /// Any slot of the block, this one included.
    case any
    /// Any slot of the block except this one.
    case other
    /// A fixed slot, named by `jumpIndex`.
    case jump
}

public struct FollowAction: Hashable, Codable, Sendable {
    public var kind: FollowActionKind
    /// Zero or more. Only the ratio between A and B matters.
    public var weight: Double
    /// Only for `.jump`.
    public var jumpIndex: Int?

    public init(_ kind: FollowActionKind, weight: Double = 1, jumpIndex: Int? = nil) {
        self.kind = kind
        self.weight = weight
        self.jumpIndex = jumpIndex
    }
}

/// When the follow action runs, counted from the moment the clip starts.
public struct FollowTime: Hashable, Codable, Sendable {
    public enum Unit: String, Codable, Sendable {
        /// After a number of ticks.
        case ticks
        /// After the clip has played its full length this many times.
        case loops
    }

    public var unit: Unit
    public var amount: Int64

    public init(_ unit: Unit, _ amount: Int64) {
        self.unit = unit
        self.amount = amount
    }

    public static func loops(_ n: Int64) -> FollowTime { FollowTime(.loops, n) }
    public static func ticks(_ t: Tick) -> FollowTime { FollowTime(.ticks, t.rawValue) }
}

/// What `next` and `previous` do at the edge of a block.
public enum BlockEdge: String, Codable, Sendable {
    /// Go to the other end of the block.
    case wrap
    /// Stop.
    case stop
}

public struct FollowActions: Hashable, Codable, Sendable {
    public var a: FollowAction
    public var b: FollowAction
    public var time: FollowTime
    public var edge: BlockEdge

    public init(a: FollowAction, b: FollowAction, time: FollowTime, edge: BlockEdge = .wrap) {
        self.a = a
        self.b = b
        self.time = time
        self.edge = edge
    }
}

public enum LaunchQuantize: String, Codable, Sendable { case none, beat, bar }

public struct SessionSlot: Hashable, Codable, Sendable {
    public var clip: Clip
    /// When a manual launch starts. Follow actions always start on the exact frame, never quantized.
    public var quantize: LaunchQuantize
    public var follow: FollowActions?

    public init(clip: Clip, quantize: LaunchQuantize = .bar, follow: FollowActions? = nil) {
        self.clip = clip
        self.quantize = quantize
        self.follow = follow
    }
}
