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

/// A length written as bars:beats:sixteenths, like "4:2:0" or "0:1:1". Beats are quarter notes.
public enum MusicalLength {
    /// Parses "bars", "bars:beats" or "bars:beats:sixteenths" (dots work too). `nil` for text that is not
    /// a length, or for zero.
    public static func parse(_ text: String, ticksPerBar: Int64) -> Tick? {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == "." }).map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { Int64($0) }
        guard numbers.count == parts.count, numbers.allSatisfy({ $0 >= 0 && $0 < 100_000 }) else { return nil }
        let values = numbers + Array(repeating: 0, count: 3 - numbers.count)
        let ticks = values[0] * ticksPerBar + values[1] * Tick.perQuarter + values[2] * (Tick.perQuarter / 4)
        return ticks > 0 ? Tick(ticks) : nil
    }

    /// "bars:beats:sixteenths", rounded down to a sixteenth.
    public static func format(_ length: Tick, ticksPerBar: Int64) -> String {
        let t = max(0, length.rawValue)
        let bars = t / max(1, ticksPerBar), rest = t % max(1, ticksPerBar)
        return "\(bars):\(rest / Tick.perQuarter):\((rest % Tick.perQuarter) / (Tick.perQuarter / 4))"
    }
}
