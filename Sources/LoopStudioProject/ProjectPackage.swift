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
/// Saving is one atomic step. It stages a full new `tracks.new/` and `project.json.new` (unchanged track
/// files are hard links), writes the `save.commit` marker, then swaps them in. A crash before the marker
/// leaves the old save; a crash after it is finished on the next save or read. Edits after the last save
/// are repaired by replaying the journal.
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
        var launches: [Launch]
        var assets: [Asset]
        var trackOrder: [TrackID]
        var master: TrackID
    }

    public static func write(_ project: Project, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try recover(url)
        let paths = Paths(url)
        try fm.createDirectory(at: paths.tracks, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.staged, withIntermediateDirectories: true)
        let encoder = Coding.fileEncoder()

        // Stage the complete new state. A track file with the same bytes is linked, not written again.
        for track in project.allTracks {
            let name = "\(track.id.rawValue.uuidString).json"
            let data = try encoder.encode(track)
            let current = paths.tracks.appendingPathComponent(name), next = paths.staged.appendingPathComponent(name)
            if let existing = try? Data(contentsOf: current), existing == data, (try? fm.linkItem(at: current, to: next)) != nil { continue }
            try data.write(to: next, options: .atomic)
        }
        let header = Header(
            schemaVersion: schemaVersion, name: project.name, sampleRate: project.sampleRate,
            tempoMap: project.tempoMap, timeSignatures: project.timeSignatures, markers: project.markers,
            loop: project.loop, randomSeed: project.randomSeed, defaultFadeMs: project.defaultFadeMs,
            autoLoop: project.autoLoop, ports: project.ports, launches: project.launches, assets: project.assets,
            trackOrder: project.tracks.map(\.id), master: project.master.id)
        let headerData = try encoder.encode(header)
        if (try? Data(contentsOf: paths.header)) != headerData { try headerData.write(to: paths.stagedHeader, options: .atomic) }

        // The commit point. From here on, the new state wins.
        try Data("commit\n".utf8).write(to: paths.marker, options: .atomic)
        try finishCommit(paths)
    }

    private struct Paths {
        let tracks, staged, old, header, stagedHeader, marker: URL
        init(_ url: URL) {
            tracks = url.appendingPathComponent("tracks", isDirectory: true)
            staged = url.appendingPathComponent("tracks.new", isDirectory: true)
            old = url.appendingPathComponent("tracks.old", isDirectory: true)
            header = url.appendingPathComponent("project.json")
            stagedHeader = url.appendingPathComponent("project.json.new")
            marker = url.appendingPathComponent("save.commit")
        }
    }

    /// Finishes a save that reached its commit marker, or throws away one that did not.
    static func recover(_ url: URL) throws {
        let paths = Paths(url), fm = FileManager.default
        if fm.fileExists(atPath: paths.marker.path) { try finishCommit(paths); return }
        for leftover in [paths.staged, paths.stagedHeader] where fm.fileExists(atPath: leftover.path) { try fm.removeItem(at: leftover) }
        if fm.fileExists(atPath: paths.old.path) && fm.fileExists(atPath: paths.tracks.path) { try fm.removeItem(at: paths.old) }
    }

    /// Swaps the staged state in. Every step can run again after a crash.
    private static func finishCommit(_ paths: Paths) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.staged.path) {
            if fm.fileExists(atPath: paths.tracks.path) {
                if fm.fileExists(atPath: paths.old.path) { try fm.removeItem(at: paths.old) }
                try fm.moveItem(at: paths.tracks, to: paths.old)
            }
            try fm.moveItem(at: paths.staged, to: paths.tracks)
        }
        if fm.fileExists(atPath: paths.stagedHeader.path) {
            // rename(2) replaces the old header in one step.
            guard rename(paths.stagedHeader.path, paths.header.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: paths.header.path])
            }
        }
        try fm.removeItem(at: paths.marker)
        if fm.fileExists(atPath: paths.old.path) { try fm.removeItem(at: paths.old) }
    }

    public static func read(from url: URL, migrator: Migrator = .standard) throws -> LoadedProject {
        try? recover(url)
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
        project.launches = decodedHeader.launches
        project.assets = decodedHeader.assets
        // A track listed twice would be two tracks with one id; keep the first.
        var listed = Set<TrackID>()
        project.tracks = try decodedHeader.trackOrder.filter { listed.insert($0).inserted && $0 != decodedHeader.master }.map(track)
        project.master = try track(decodedHeader.master)
        return LoadedProject(project: project, issues: project.validate(), migratedFrom: migrated ? version : nil)
    }

}
