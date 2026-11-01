import Foundation
import LoopStudioCore
import LoopStudioProject

/// What a project open came back with.
public struct SessionOpened: Sendable {
    public var path: String
    /// Commands replayed from the journal after a crash.
    public var recoveredCommands: Int
    public var recoveryFailed: Bool
    public var journalTailDropped: Bool
    public var issues: [ProjectIssue]
    public var migratedFrom: Int?

    public init(path: String, recoveredCommands: Int = 0, recoveryFailed: Bool = false, journalTailDropped: Bool = false,
                issues: [ProjectIssue] = [], migratedFrom: Int? = nil) {
        self.path = path
        self.recoveredCommands = recoveredCommands
        self.recoveryFailed = recoveryFailed
        self.journalTailDropped = journalTailDropped
        self.issues = issues
        self.migratedFrom = migratedFrom
    }
}

/// The project the tools work on. Two kinds exist: `ProjectSession` edits project files on its own, and the
/// app binds its open project, so an agent's edit shows on screen and sounds at once. The tools cannot
/// tell them apart, so a script that works on files works on the running app too.
public protocol EditSession: Sendable {
    var isOpen: Bool { get async }
    var path: String? { get async }
    var packageURL: URL? { get async }

    func create(at url: URL, name: String, sampleRate: Double) async throws
    @discardableResult
    func open(at url: URL) async throws -> SessionOpened
    func save() async throws
    func project() async throws -> Project
    func isDirty() async -> Bool
    func revision() async -> Int
    func apply(_ command: Command, coalescingKey: String?) async throws
    func undo() async throws -> Bool
    func redo() async throws -> Bool
}

public extension EditSession {
    func apply(_ command: Command) async throws { try await apply(command, coalescingKey: nil) }
}

extension ProjectSession: EditSession {}
