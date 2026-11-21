import Foundation

/// The note edits of an audio clip, after Melodyne's polyphonic mode: the analysis finds the notes in the
/// file, also the notes of a chord, and each one can change on its own. The clip then plays a file rendered
/// from `source` with these changes; `source` stays in the project, so every edit starts from the original
/// and an undo goes back to the clip before it.
public struct NoteEdit: Codable, Hashable, Sendable {
    /// The unedited file.
    public var source: AssetID
    /// The changed notes. A note that is not listed plays as recorded.
    public var changes: [NoteChange]
    /// A moved note keeps the tone colour of the original pitch (its formants); off, the tone colour moves
    /// with the pitch.
    public var keepFormants: Bool

    public init(source: AssetID, changes: [NoteChange] = [], keepFormants: Bool = true) {
        self.source = source
        self.changes = changes
        self.keepFormants = keepFormants
    }

    public func change(_ key: String) -> NoteChange? { changes.first { $0.key == key } }

    /// The edit with `change` in place of the note's old one. A change that changes nothing is dropped.
    public func with(_ change: NoteChange) -> NoteEdit {
        var next = self
        next.changes.removeAll { $0.key == change.key }
        if !change.isIdentity { next.changes.append(change) }
        next.changes.sort { $0.key < $1.key }
        return next
    }
}

/// One note's change. `key` names the note the analysis found ("<first frame>-<MIDI note>"); the same file
/// gives the same keys.
public struct NoteChange: Codable, Hashable, Sendable {
    public var key: String
    /// Semitones up or down; a fraction is cents.
    public var pitch: Double
    /// Seconds later (negative: earlier).
    public var shift: Double
    /// The note's length as a share of the original: 2 is twice as long.
    public var stretch: Double
    public var gainDb: Double
    public var muted: Bool

    public init(key: String, pitch: Double = 0, shift: Double = 0, stretch: Double = 1, gainDb: Double = 0, muted: Bool = false) {
        self.key = key
        self.pitch = pitch
        self.shift = shift
        self.stretch = stretch
        self.gainDb = gainDb
        self.muted = muted
    }

    public var isIdentity: Bool { pitch == 0 && shift == 0 && stretch == 1 && gainDb == 0 && !muted }
}
