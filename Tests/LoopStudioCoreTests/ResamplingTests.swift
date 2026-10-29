import Foundation
import Testing
@testable import LoopStudioCore

@Test func aTrackCanTakeTheMasterAsItsInput() throws {
    var p = Fixture.baseProject()
    let t = Track(name: "Resample", kind: .audio)
    try Command.insertTrack(track: t, index: 0).apply(to: &p)
    let inverse = try Command.setInputTrack(id: t.id, source: p.master.id).apply(to: &p)
    #expect(p.track(t.id)?.inputTrack == p.master.id)
    #expect(p.validate().isEmpty, "the master as a source is not a routing cycle")
    try inverse.apply(to: &p)
    #expect(p.track(t.id)?.inputTrack == nil)
}

@Test func theMasterItselfTakesNoInput() {
    var p = Fixture.baseProject()
    #expect(throws: CommandError.self) { try Command.setInputTrack(id: p.master.id, source: nil).apply(to: &p) }
}

@Test func theArmStateTravelsWithTheProjectFile() throws {
    var p = Fixture.baseProject()
    var t = Track(name: "Mic", kind: .audio)
    t.armed = true
    try Command.insertTrack(track: t, index: 0).apply(to: &p)
    let data = try JSONEncoder().encode(p)
    let back = try JSONDecoder().decode(Project.self, from: data)
    #expect(back.track(t.id)?.armed == true)
    // An older file without the field: not armed.
    var plain = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var tracks = plain["tracks"] as! [[String: Any]]
    tracks[0]["armed"] = nil
    plain["tracks"] = tracks
    let old = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: plain))
    #expect(old.track(t.id)?.armed == nil)
}
