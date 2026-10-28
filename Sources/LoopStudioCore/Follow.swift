import Foundation

/// Reproducible randomness for follow actions.
///
/// The value depends only on (project seed, clip ID, how often the clip has been launched, draw number).
/// There is no stored state, so:
/// - an offline bounce and live playback make the same choices,
/// - the next choice can be made when a clip starts, which gives the engine time to prepare audio,
/// - skipping or replaying a section cannot shift later choices.
/// The clip ID is hashed with FNV-1a, because Swift's `Hasher` changes on every launch of the process.
public struct FollowRandom: Sendable {
    public let seed: UInt32
    public let clip: ClipID
    public let launchCount: Int

    public init(seed: UInt32, clip: ClipID, launchCount: Int) {
        self.seed = seed
        self.clip = clip
        self.launchCount = launchCount
    }

    /// A number in [0, 1). `draw` selects an independent value for the same launch.
    public func unit(draw: Int) -> Double {
        var x = Self.fnv1a(clip.rawValue)
        x &+= UInt64(seed) &* 0x9E37_79B9_7F4A_7C15
        x &+= UInt64(bitPattern: Int64(launchCount)) &* 0xBF58_476D_1CE4_E5B9
        x &+= UInt64(bitPattern: Int64(draw)) &* 0x94D0_49BB_1331_11EB
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x >> 11) / Double(1 << 53)
    }

    private static func fnv1a(_ uuid: UUID) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        withUnsafeBytes(of: uuid.uuid) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
        }
        return hash
    }
}

public enum FollowOutcome: Hashable, Sendable {
    /// No follow action happens. The clip goes on as it is (it loops, or ends).
    case none
    /// Stop the track.
    case stop
    /// Start this slot of the same track.
    case play(slot: Int)
}

public enum FollowResolver {
    /// The block that contains `index`: the longest run of occupied slots around it.
    public static func block(containing index: Int, in slots: [SessionSlot?]) -> ClosedRange<Int>? {
        guard slots.indices.contains(index), slots[index] != nil else { return nil }
        var lo = index
        while lo > 0, slots[lo - 1] != nil { lo -= 1 }
        var hi = index
        while hi + 1 < slots.count, slots[hi + 1] != nil { hi += 1 }
        return lo...hi
    }

    /// Picks A or B by weight. Returns nil when both weights are zero (no follow action).
    public static func chooseAction(_ follow: FollowActions, random: FollowRandom) -> FollowAction? {
        let wa = sanitize(follow.a.weight)
        let wb = sanitize(follow.b.weight)
        let total = wa + wb
        guard total > 0 else { return nil }
        return random.unit(draw: 0) * total < wa ? follow.a : follow.b
    }

    /// Decides what happens when the follow time of the slot at `current` is over.
    public static func resolve(current: Int, slots: [SessionSlot?], random: FollowRandom) -> FollowOutcome {
        guard let block = block(containing: current, in: slots), let follow = slots[current]?.follow else { return .stop }
        guard let action = chooseAction(follow, random: random) else { return .none }
        let count = block.count
        switch action.kind {
        case .stop:
            return .stop
        case .replay:
            return .play(slot: current)
        case .next:
            if current < block.upperBound { return .play(slot: current + 1) }
            return follow.edge == .wrap ? .play(slot: block.lowerBound) : .stop
        case .previous:
            if current > block.lowerBound { return .play(slot: current - 1) }
            return follow.edge == .wrap ? .play(slot: block.upperBound) : .stop
        case .topOfBlock:
            return .play(slot: block.lowerBound)
        case .endOfBlock:
            return .play(slot: block.upperBound)
        case .any:
            let k = min(count - 1, Int(random.unit(draw: 1) * Double(count)))
            return .play(slot: block.lowerBound + k)
        case .other:
            guard count > 1 else { return .play(slot: current) }
            let k = min(count - 2, Int(random.unit(draw: 1) * Double(count - 1)))
            var index = block.lowerBound + k
            if index >= current { index += 1 }
            return .play(slot: index)
        case .jump:
            guard let target = action.jumpIndex, slots.indices.contains(target), slots[target] != nil else { return .none }
            return .play(slot: target)
        }
    }

    /// NaN and negative weights count as 0. Huge weights are capped, so the sum cannot overflow.
    static func sanitize(_ weight: Double) -> Double {
        weight.isNaN || weight < 0 ? 0 : min(weight, 1e9)
    }
}
