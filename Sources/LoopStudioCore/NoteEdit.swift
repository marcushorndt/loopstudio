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
    /// Copies of found notes (⌘D on the Notes page). A copy sounds the partials of its source note once more;
    /// its place is the change under its own key, measured from the source note as recorded.
    public var copies: [NoteCopy]

    public init(source: AssetID, changes: [NoteChange] = [], keepFormants: Bool = true, copies: [NoteCopy] = []) {
        self.source = source
        self.changes = changes
        self.keepFormants = keepFormants
        self.copies = copies
    }

    private enum CodingKeys: String, CodingKey { case source, changes, keepFormants, copies }

    /// Edits from before copies existed have no `copies` key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(AssetID.self, forKey: .source)
        changes = try c.decodeIfPresent([NoteChange].self, forKey: .changes) ?? []
        keepFormants = try c.decodeIfPresent(Bool.self, forKey: .keepFormants) ?? true
        copies = try c.decodeIfPresent([NoteCopy].self, forKey: .copies) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        try c.encode(changes, forKey: .changes)
        try c.encode(keepFormants, forKey: .keepFormants)
        if !copies.isEmpty { try c.encode(copies, forKey: .copies) }
    }

    /// Nothing changed and nothing copied: the clip plays its original.
    public var isEmpty: Bool { changes.isEmpty && copies.isEmpty }

    public func copy(_ key: String) -> NoteCopy? { copies.first { $0.key == key } }

    /// The change of a note or a copy; without one, the note sounds where the found note was recorded.
    public func current(_ key: String) -> NoteChange {
        change(key) ?? NoteChange(key: key)
    }

    /// The edit with a copy of `key` (a found note or a copy) under `newKey`: the copy starts where its model
    /// is now, `shift` seconds later.
    public func adding(copyOf key: String, shift: Double, newKey: String) -> NoteEdit {
        var next = self
        let source = copy(key)?.source ?? key
        var place = current(key)
        place.key = newKey
        place.shift += shift
        next.copies.append(NoteCopy(key: newKey, source: source, origin: place))
        return next.with(place)
    }

    /// The edit without a copy and its change.
    public func removing(copy key: String) -> NoteEdit {
        var next = self
        next.copies.removeAll { $0.key == key }
        next.changes.removeAll { $0.key == key }
        return next
    }

    /// Reset of one note: a found note sounds as recorded, a copy goes back to where it was made.
    public func reset(_ key: String) -> NoteEdit {
        if let c = copy(key) { return with(c.origin) }
        return with(NoteChange(key: key))
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

/// A copy of a found note. `source` is the key of the found note whose partials it sounds, `origin` the place
/// it was made at (Reset goes back there). The key starts with "copy-", so it never names a found note.
public struct NoteCopy: Codable, Hashable, Sendable {
    public var key: String
    public var source: String
    public var origin: NoteChange

    public init(key: String, source: String, origin: NoteChange) {
        self.key = key
        self.source = source
        self.origin = origin
    }

    public static func newKey() -> String { "copy-" + UUID().uuidString.prefix(8).lowercased() }
}
