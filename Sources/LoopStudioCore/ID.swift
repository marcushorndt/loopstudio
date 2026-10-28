import Foundation

/// A typed UUID. The phantom `Tag` stops a `TrackID` from being used where a `ClipID` is expected.
public struct ID<Tag>: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }

    public static func == (a: Self, b: Self) -> Bool { a.rawValue == b.rawValue }
    public func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue.uuidString }
}

public enum TrackTag {}
public enum ClipTag {}
public enum AssetTag {}
public enum DeviceTag {}
public enum LaneTag {}
public enum MarkerTag {}
public enum PortTag {}

public typealias TrackID = ID<TrackTag>
public typealias ClipID = ID<ClipTag>
public typealias AssetID = ID<AssetTag>
public typealias DeviceID = ID<DeviceTag>
public typealias LaneID = ID<LaneTag>
public typealias MarkerID = ID<MarkerTag>
public typealias PortID = ID<PortTag>
