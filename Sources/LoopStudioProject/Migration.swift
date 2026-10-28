import Foundation

public enum PackageError: Error, Equatable {
    case notAProject(String)
    /// The file was saved by a newer version. Open it read-only; never rewrite it.
    case newerVersion(found: Int, supported: Int)
    case missingMigration(from: Int)
    case missingTrackFile(String)
    case invalid(String)
}

/// The package as loose JSON, before decoding. A migration edits this.
public struct RawPackage {
    public var header: [String: Any]
    public var tracks: [String: [String: Any]]

    public init(header: [String: Any], tracks: [String: [String: Any]]) {
        self.header = header
        self.tracks = tracks
    }
}

/// Upgrades old files one version at a time: a step for version N makes a version N+1 file.
/// Every released schema version keeps its step and a test for it, so old files always open.
public struct Migrator {
    public typealias Step = (inout RawPackage) throws -> Void

    public let currentVersion: Int
    private let steps: [Int: Step]

    public init(currentVersion: Int, steps: [Int: Step] = [:]) {
        self.currentVersion = currentVersion
        self.steps = steps
    }

    public static var standard: Migrator {
        Migrator(currentVersion: ProjectPackage.schemaVersion)
    }

    func migrate(_ raw: inout RawPackage, from version: Int) throws {
        guard version <= currentVersion else {
            throw PackageError.newerVersion(found: version, supported: currentVersion)
        }
        var v = version
        while v < currentVersion {
            guard let step = steps[v] else { throw PackageError.missingMigration(from: v) }
            try step(&raw)
            v += 1
            raw.header["schemaVersion"] = v
        }
    }
}
