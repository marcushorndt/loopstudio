import Foundation
import LoopStudioCore

enum Coding {
    /// Sorted keys and fixed formatting: the same project always gives the same bytes, so git diffs stay small.
    static func fileEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// One line per command, for the journal.
    static func lineEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

/// A write-ahead log of commands: one JSON object per line.
/// `ProjectStore` writes to it before it commits a change. After a crash, replay it over the last save.
public final class Journal: @unchecked Sendable {
    public struct Contents {
        public var commands: [Command]
        /// True if reading stopped at a line that did not decode (usually a write cut off by a crash).
        public var stoppedEarly: Bool
    }

    public let url: URL
    private let durable: Bool
    private let lock = NSLock()
    private var handle: FileHandle
    private let encoder = Coding.lineEncoder()

    /// `durable` makes every append wait for the disk (fsync). Turn it off only in tests.
    public init(url: URL, durable: Bool = true) throws {
        self.url = url
        self.durable = durable
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    public func append(_ command: Command) throws {
        var data = try encoder.encode(command)
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        try handle.write(contentsOf: data)
        if durable { try handle.synchronize() }
    }

    /// Empties the journal. Call it right after a successful save.
    /// The save's commit removes the journal file (`ProjectPackage.finishCommit`), so this starts a new file:
    /// a truncate of the removed one would write into an unlinked inode and lose every later edit.
    public func reset() throws {
        lock.lock()
        defer { lock.unlock() }
        try? handle.close()
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
        if durable { try handle.synchronize() }
    }

    public static func read(url: URL) throws -> Contents {
        guard FileManager.default.fileExists(atPath: url.path) else { return Contents(commands: [], stoppedEarly: false) }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        var commands: [Command] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let command = try? decoder.decode(Command.self, from: Data(line)) else {
                return Contents(commands: commands, stoppedEarly: true)
            }
            commands.append(command)
        }
        return Contents(commands: commands, stoppedEarly: false)
    }

    public struct Replay {
        public var project: Project
        public var applied: Int
        /// The first command that could not be applied, if any. Replay stops there.
        public var failure: Error?
    }

    /// Applies journal commands over `project`. Stops at the first command that fails.
    public static func replay(_ commands: [Command], onto project: Project) -> Replay {
        var current = project
        var applied = 0
        for command in commands {
            do {
                try command.apply(to: &current)
                applied += 1
            } catch {
                return Replay(project: current, applied: applied, failure: error)
            }
        }
        return Replay(project: current, applied: applied, failure: nil)
    }
}
