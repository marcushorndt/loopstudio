import AVFoundation
import CryptoKit
import Foundation
import LoopStudioCore

/// Audio files inside a project package: `audio/<sha256>.<extension>`.
/// The name is the content hash, so the same file imported twice is stored once, and a project
/// moved between machines (or file systems with different name rules) keeps working.
public enum AssetStore {
    public enum StoreError: Error, Equatable {
        case notAudio(String)
        case emptyFile(String)
    }

    /// SHA-256 of a file's bytes as lowercase hex, read in chunks (no whole-file load).
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Copies `source` into the package (unless it is already there) and describes it.
    /// The returned asset has a new ID; the caller checks `sha256` against existing assets to avoid duplicates.
    public static func importFile(_ source: URL, into package: URL) throws -> Asset {
        let hash = try sha256(of: source)
        let ext = source.pathExtension.lowercased()
        let folder = package.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(ext.isEmpty ? hash : "\(hash).\(ext)")
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: destination) }
        catch { throw StoreError.notAudio(source.lastPathComponent) }
        guard file.length > 0 else { throw StoreError.emptyFile(source.lastPathComponent) }
        return Asset(sha256: hash, name: source.lastPathComponent, frames: file.length,
                     sampleRate: file.fileFormat.sampleRate, channels: Int(file.fileFormat.channelCount))
    }

    /// The stored file for an asset, whatever its extension.
    public static func fileURL(for asset: Asset, in package: URL) -> URL? {
        let folder = package.appendingPathComponent("audio", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        // The hash is a 64-character hex string; match it exactly so a name like "<hash>x" is not taken.
        guard let name = names.sorted().first(where: { $0 == asset.sha256 || $0.hasPrefix(asset.sha256 + ".") }) else { return nil }
        return folder.appendingPathComponent(name)
    }
}
