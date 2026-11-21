import Foundation
import Testing
@testable import LoopStudioCore

/// A note edit from before copies existed reads with no copies, and one without copies writes no `copies` key.
@Test func aNoteEditWithoutCopiesReadsAndWritesAsBefore() throws {
    let id = AssetID()
    let old = #"{"source":"\#(id.rawValue.uuidString)","changes":[{"key":"3-64","pitch":1,"shift":0,"stretch":1,"gainDb":0,"muted":false}],"keepFormants":true}"#
    let edit = try JSONDecoder().decode(NoteEdit.self, from: Data(old.utf8))
    #expect(edit.copies.isEmpty && edit.change("3-64")?.pitch == 1)
    let written = String(data: try JSONEncoder().encode(edit), encoding: .utf8) ?? ""
    #expect(!written.contains("copies"))
}

/// A copy starts where its model sounds now plus the shift; a copy of a copy sounds the same found note.
@Test func aCopyStartsWhereItsModelIs() {
    var edit = NoteEdit(source: AssetID()).with(NoteChange(key: "3-64", pitch: 2, shift: 0.5))
    edit = edit.adding(copyOf: "3-64", shift: 1, newKey: "copy-1")
    #expect(edit.current("copy-1").pitch == 2 && edit.current("copy-1").shift == 1.5)
    edit = edit.adding(copyOf: "copy-1", shift: 1, newKey: "copy-2")
    #expect(edit.copy("copy-2")?.source == "3-64" && edit.current("copy-2").shift == 2.5)
    var moved = edit.current("copy-2")
    moved.pitch = -3
    edit = edit.with(moved)
    #expect(edit.reset("copy-2").current("copy-2").pitch == 2, "Reset goes back to where the copy was made")
    #expect(edit.reset("3-64").change("3-64") == nil, "a found note sounds as recorded")
}
