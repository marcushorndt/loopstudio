import Foundation

/// Musical position or length in ticks. 960 ticks per quarter note.
/// Integers, so positions never drift. Signed, so pre-roll and count-in work.
public struct Tick: Hashable, Comparable, Codable, Sendable, ExpressibleByIntegerLiteral, CustomStringConvertible {
    public static let perQuarter: Int64 = 960
    public static let zero = Tick(0)

    public var rawValue: Int64

    public init(_ rawValue: Int64) { self.rawValue = rawValue }
    public init(integerLiteral value: Int64) { rawValue = value }

    /// Rounds to the nearest tick.
    public static func quarters(_ quarters: Double) -> Tick {
        Tick(Int64((quarters * Double(perQuarter)).rounded(.toNearestOrEven)))
    }

    public var quarters: Double { Double(rawValue) / Double(Tick.perQuarter) }

    public static func < (a: Tick, b: Tick) -> Bool { a.rawValue < b.rawValue }
    public static func + (a: Tick, b: Tick) -> Tick { Tick(a.rawValue + b.rawValue) }
    public static func - (a: Tick, b: Tick) -> Tick { Tick(a.rawValue - b.rawValue) }
    public static func += (a: inout Tick, b: Tick) { a.rawValue += b.rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { "\(rawValue)t" }
}

/// Audio position in samples at the engine sample rate.
public struct Frame: Hashable, Comparable, Codable, Sendable, ExpressibleByIntegerLiteral, CustomStringConvertible {
    public var rawValue: Int64

    public init(_ rawValue: Int64) { self.rawValue = rawValue }
    public init(integerLiteral value: Int64) { rawValue = value }

    public static func < (a: Frame, b: Frame) -> Bool { a.rawValue < b.rawValue }
    public static func + (a: Frame, b: Frame) -> Frame { Frame(a.rawValue + b.rawValue) }
    public static func - (a: Frame, b: Frame) -> Frame { Frame(a.rawValue - b.rawValue) }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { "\(rawValue)f" }
}

public struct TimeSignature: Hashable, Codable, Sendable {
    public var numerator: Int
    public var denominator: Int

    public init(_ numerator: Int, _ denominator: Int) {
        self.numerator = max(1, numerator)
        // Only powers of two from 1 to 32 are valid. Anything else becomes 4.
        self.denominator = [1, 2, 4, 8, 16, 32].contains(denominator) ? denominator : 4
    }

    public var ticksPerBar: Tick {
        Tick(Int64(numerator) * (4 * Tick.perQuarter) / Int64(denominator))
    }
}

/// A time signature change. It always sits on a bar line; the project enforces that.
public struct TimeSignatureChange: Hashable, Codable, Sendable {
    public var tick: Tick
    public var signature: TimeSignature

    public init(tick: Tick, signature: TimeSignature) {
        self.tick = tick
        self.signature = signature
    }
}
