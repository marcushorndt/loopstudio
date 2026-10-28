import Foundation
import LoopStudioCore

public struct LoadedProject {
    public var project: Project
    /// Problems found in the file. Empty for a healthy project.
    public var issues: [ProjectIssue]
    /// The schema version the file had, if it was older than the current one.
    public var migratedFrom: Int?
}

/// A project on disk is a folder:
///
///     MyProject.loopstudio/
///       project.json          settings, tempo, markers, asset list, track order (written last)
///       tracks/<uuid>.json    one file per track (and one for the master)
///       audio/<sha256>.<ext>  sample files (managed by the asset store, not by this type)
///       cache/                waveforms, warps, scan results; safe to delete
///       journal.jsonl         commands since the last save
///
/// Saving writes every file atomically and `project.json` last, so it is the commit point.
/// A crash between two files is repaired by replaying the journal.
public enum ProjectPackage {
    public static let schemaVersion = 1

    struct Header: Codable {
        var schemaVersion: Int
        var name: String
        var sampleRate: Double
        var tempoMap: TempoMap
        var timeSignatures: [TimeSignatureChange]
        var markers: [Marker]
        var loop: LoopRegion?
        var randomSeed: UInt32
        var defaultFadeMs: Double
        var autoLoop: AutoLoopRule
        var ports: [IOPort]
        var assets: [Asset]
        var trackOrder: [TrackID]
        var master: TrackID
    }

    public static func write(_ project: Project, to url: URL) throws {
        let fm = FileManager.default
        let tracksDir = url.appendingPathComponent("tracks", isDirectory: true)
        try fm.createDirectory(at: tracksDir, withIntermediateDirectories: true)
        let encoder = Coding.fileEncoder()

        var wanted = Set<String>()
        for track in project.allTracks {
            let name = "\(track.id.rawValue.uuidString).json"
            wanted.insert(name)
            try writeIfChanged(try encoder.encode(track), to: tracksDir.appendingPathComponent(name))
        }

        let header = Header(
            schemaVersion: schemaVersion, name: project.name, sampleRate: project.sampleRate,
            tempoMap: project.tempoMap, timeSignatures: project.timeSignatures, markers: project.markers,
            loop: project.loop, randomSeed: project.randomSeed, defaultFadeMs: project.defaultFadeMs,
            autoLoop: project.autoLoop, ports: project.ports, assets: project.assets,
            trackOrder: project.tracks.map(\.id), master: project.master.id)
        try writeIfChanged(try encoder.encode(header), to: url.appendingPathComponent("project.json"))

        // Remove track files of deleted tracks, after the new header no longer lists them.
        for name in try fm.contentsOfDirectory(atPath: tracksDir.path) where name.hasSuffix(".json") && !wanted.contains(name) {
            try fm.removeItem(at: tracksDir.appendingPathComponent(name))
        }
    }

    public static func read(from url: URL, migrator: Migrator = .standard) throws -> LoadedProject {
        let headerURL = url.appendingPathComponent("project.json")
        guard let headerData = try? Data(contentsOf: headerURL) else {
            throw PackageError.notAProject("no project.json in \(url.lastPathComponent)")
        }
        guard var header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any] else {
            throw PackageError.invalid("project.json is not a JSON object")
        }
        guard let version = header["schemaVersion"] as? Int, version >= 1 else {
            throw PackageError.invalid("schemaVersion is missing or below 1")
        }
        // Refuse early. A newer file may use fields this version does not know.
        if version > migrator.currentVersion {
            throw PackageError.newerVersion(found: version, supported: migrator.currentVersion)
        }

        // Track IDs become file names, so only real UUIDs are accepted (no "../" in a hand-edited file).
        var fileNames: [String] = []
        for key in ["trackOrder", "master"] {
            let raw: [Any]
            if key == "master" {
                guard let one = header[key] else { throw PackageError.invalid("header has no master") }
                raw = [one]
            } else {
                guard let many = header[key] as? [Any] else { throw PackageError.invalid("header has no trackOrder") }
                raw = many
            }
            for item in raw {
                guard let s = item as? String, let uuid = UUID(uuidString: s) else {
                    throw PackageError.invalid("track ID is not a UUID")
                }
                fileNames.append(uuid.uuidString)
            }
        }

        var tracks: [String: [String: Any]] = [:]
        for name in Set(fileNames) {
            let file = url.appendingPathComponent("tracks/\(name).json")
            guard let data = try? Data(contentsOf: file) else { throw PackageError.missingTrackFile(name) }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw PackageError.invalid("track file \(name) is not a JSON object")
            }
            tracks[name] = object
        }

        var raw = RawPackage(header: header, tracks: tracks)
        let migrated = version < migrator.currentVersion
        if migrated { try migrator.migrate(&raw, from: version) }
        header = raw.header

        let decoder = JSONDecoder()
        let decodedHeader: Header
        do {
            decodedHeader = try decoder.decode(Header.self, from: JSONSerialization.data(withJSONObject: header))
        } catch {
            throw PackageError.invalid("project.json: \(error)")
        }

        func track(_ id: TrackID) throws -> Track {
            guard let object = raw.tracks[id.rawValue.uuidString] else {
                throw PackageError.missingTrackFile(id.rawValue.uuidString)
            }
            do {
                return try decoder.decode(Track.self, from: JSONSerialization.data(withJSONObject: object))
            } catch {
                throw PackageError.invalid("track \(id): \(error)")
            }
        }

        var project = Project(name: decodedHeader.name, sampleRate: decodedHeader.sampleRate)
        project.tempoMap = decodedHeader.tempoMap
        project.timeSignatures = decodedHeader.timeSignatures
        project.markers = decodedHeader.markers
        project.loop = decodedHeader.loop
        project.randomSeed = decodedHeader.randomSeed
        project.defaultFadeMs = decodedHeader.defaultFadeMs
        project.autoLoop = decodedHeader.autoLoop
        project.ports = decodedHeader.ports
        project.assets = decodedHeader.assets
        project.tracks = try decodedHeader.trackOrder.map(track)
        project.master = try track(decodedHeader.master)
        return LoadedProject(project: project, issues: project.validate(), migratedFrom: migrated ? version : nil)
    }

    /// Skips the write when the file already has these exact bytes (keeps timestamps and sync tools quiet).
    private static func writeIfChanged(_ data: Data, to url: URL) throws {
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try data.write(to: url, options: .atomic)
    }
}
