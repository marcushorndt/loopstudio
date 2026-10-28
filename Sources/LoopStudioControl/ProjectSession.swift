import Foundation
import LoopStudioCore
import LoopStudioProject

/// The one open project: its store, its folder, its journal.
/// Every tool goes through here, so a script, an agent and the UI cannot disagree about the state.
public actor ProjectSession {
    public struct Opened: Sendable {
        public var path: String
        /// Commands replayed from the journal after a crash.
        public var recoveredCommands: Int
        public var recoveryFailed: Bool
        public var journalTailDropped: Bool
        public var issues: [ProjectIssue]
        public var migratedFrom: Int?
    }

    private var store: ProjectStore?
    private var url: URL?
    private var journal: Journal?
    private var savedRevision = 0

    public init() {}

    public var isOpen: Bool { store != nil }
    public var path: String? { url?.path }
    public var packageURL: URL? { url }

    // MARK: Open, create, save

    public func create(at url: URL, name: String, sampleRate: Double) async throws {
        try Self.checkPath(url)
        guard !FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path) else {
            throw ToolFailure("a project already exists at \(url.path)")
        }
        let project = Project(name: name, sampleRate: sampleRate)
        try ProjectPackage.write(project, to: url)
        try attach(project, at: url, savedRevision: 0)
    }

    @discardableResult
    public func open(at url: URL) async throws -> Opened {
        try Self.checkPath(url)
        let loaded: LoadedProject
        do { loaded = try ProjectPackage.read(from: url) } catch { throw ToolFailure("cannot open project: \(error)") }

        let journalURL = url.appendingPathComponent("journal.jsonl")
        let contents = try Journal.read(url: journalURL)
        var project = loaded.project
        var failed = false
        if !contents.commands.isEmpty {
            let replay = Journal.replay(contents.commands, onto: project)
            project = replay.project
            failed = replay.failure != nil
        }
        // After a recovery the disk is older than memory, so the project counts as unsaved.
        try attach(project, at: url, savedRevision: contents.commands.isEmpty ? 0 : -1)
        return Opened(path: url.path, recoveredCommands: contents.commands.count, recoveryFailed: failed,
                      journalTailDropped: contents.stoppedEarly, issues: loaded.issues, migratedFrom: loaded.migratedFrom)
    }

    public func save() async throws {
        let (store, url) = try require()
        try ProjectPackage.write(await store.project, to: url)
        try journal?.reset()
        savedRevision = await store.revision
    }

    // MARK: Reading and editing

    public func project() async throws -> Project { try await require().store.project }

    public func isDirty() async -> Bool {
        guard let store else { return false }
        return await store.revision != savedRevision
    }

    public func revision() async -> Int { await store?.revision ?? 0 }

    public func apply(_ command: Command, coalescingKey: String? = nil) async throws {
        let (store, _) = try require()
        do { try await store.apply(command, coalescingKey: coalescingKey) }
        catch let e as CommandError { throw ToolFailure("command rejected: \(e)") }
    }

    public func undo() async throws -> Bool { try await require().store.undo() }
    public func redo() async throws -> Bool { try await require().store.redo() }

    // MARK: Internals

    private func attach(_ project: Project, at url: URL, savedRevision: Int) throws {
        let journal = try Journal(url: url.appendingPathComponent("journal.jsonl"))
        self.journal = journal
        self.store = ProjectStore(project: project, journal: { try journal.append($0) })
        self.url = url
        self.savedRevision = savedRevision
    }

    private func require() throws -> (store: ProjectStore, url: URL) {
        guard let store, let url else { throw ToolFailure("no project is open; call project_new or project_open first") }
        return (store, url)
    }

    /// Only `.loopstudio` folders at absolute paths. A tool cannot be used to write elsewhere.
    static func checkPath(_ url: URL) throws {
        guard url.path.hasPrefix("/"), url.pathExtension == "loopstudio" else {
            throw ToolFailure("path must be absolute and end with .loopstudio")
        }
    }
}
