import Foundation

/// The user's library of Subs: one JSON file per saved Sub patch in `~/Library/Application Support/LoopStudio/Patches`.
/// A file holds a `PatchDocument` with `isSub` set, so it drops onto any canvas as a Sub module.
public enum PatchLibrary {
    public static let fileExtension = "lspatch"

    public static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("LoopStudio/Patches", isDirectory: true)
    }

    /// The saved Subs, by name, A to Z.
    public static func entries(in folder: URL = folder) -> [(name: String, url: URL)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == fileExtension }
            .map { (name: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Writes a Sub's patch under a name. A name that is a file already is overwritten: that is how a Sub is updated.
    @discardableResult
    public static func save(_ doc: PatchDocument, as name: String, in folder: URL = folder) throws -> URL {
        var copy = doc
        copy.isSub = true
        copy.name = name
        let safe = name.map { "/:\\".contains($0) ? "-" : $0 }.map(String.init).joined().trimmingCharacters(in: .whitespaces)
        guard !safe.isEmpty else { throw PatchEditError("a Sub in the library needs a name") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(safe).appendingPathExtension(fileExtension)
        try copy.source.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Reads a saved Sub. `nil` for a file that is not a Sub patch.
    public static func load(_ url: URL) -> PatchDocument? {
        guard let text = try? String(contentsOf: url, encoding: .utf8), var doc = PatchDocument.parse(text) else { return nil }
        doc.isSub = true
        return doc
    }
}
