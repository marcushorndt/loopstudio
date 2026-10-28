import Foundation

/// Owns the project, the undo stack and the redo stack.
///
/// Every state change goes through `apply`, `undo` or `redo`. Each one:
/// 1. tries the change on a copy (a bad command leaves everything as it was),
/// 2. writes the change to the journal sink (write-ahead: if that fails, nothing changes),
/// 3. then commits the copy.
/// The journal therefore holds exactly the commands that changed the project, in order.
/// Undo and redo are journaled as the commands they apply, so replaying the journal always
/// gives the current state.
public actor ProjectStore {
    public typealias JournalSink = @Sendable (Command) throws -> Void

    private struct Entry {
        var forward: Command
        var inverse: Command
        var key: String?
    }

    public private(set) var project: Project
    /// Grows by one for every committed change. Background jobs use it to drop stale results.
    public private(set) var revision = 0

    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    private let journal: JournalSink?
    private let maxUndo: Int

    public init(project: Project, maxUndo: Int = 1_000, journal: JournalSink? = nil) {
        self.project = project
        self.maxUndo = maxUndo
        self.journal = journal
    }

    /// Runs `body` with the current project and revision in one actor step. No command can apply in
    /// between, so a save can write the project and clear the journal as one unit.
    @discardableResult
    public func checkpoint(_ body: (Project, Int) throws -> Void) rethrows -> Int {
        try body(project, revision)
        return revision
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Applies a command. With the same `key` as the previous change, both become one undo step
    /// (for example, 200 small moves while dragging a fader).
    public func apply(_ command: Command, coalescingKey key: String? = nil) throws {
        var next = project
        let inverse = try command.apply(to: &next)
        try journal?(command)
        project = next
        revision += 1
        redoStack.removeAll()

        if let key, let last = undoStack.last, last.key == key {
            undoStack[undoStack.count - 1] = Entry(
                forward: .combined(last.forward, command),
                inverse: .combined(inverse, last.inverse),
                key: key)
        } else {
            undoStack.append(Entry(forward: command, inverse: inverse, key: key))
            if undoStack.count > maxUndo { undoStack.removeFirst(undoStack.count - maxUndo) }
        }
    }

    /// Returns false when there is nothing to undo.
    @discardableResult
    public func undo() throws -> Bool {
        guard let entry = undoStack.last else { return false }
        var next = project
        try entry.inverse.apply(to: &next)
        try journal?(entry.inverse)
        project = next
        revision += 1
        undoStack.removeLast()
        redoStack.append(entry)
        return true
    }

    /// Returns false when there is nothing to redo.
    @discardableResult
    public func redo() throws -> Bool {
        guard let entry = redoStack.last else { return false }
        var next = project
        try entry.forward.apply(to: &next)
        try journal?(entry.forward)
        project = next
        revision += 1
        redoStack.removeLast()
        undoStack.append(entry)
        return true
    }
}
