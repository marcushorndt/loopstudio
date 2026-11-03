import Foundation
import Testing
@testable import LoopStudioCore
@testable import LoopStudioProject

/// A save commits the journaled edits, so the same commit removes the journal. A crash between the package
/// write and a separate journal reset would otherwise replay the saved edits a second time on the next open.
@Test func aSaveRemovesTheJournalWithItsCommit() throws {
    let url = Temp.directory().appendingPathComponent("J.loopstudio")
    var project = Project(name: "J")
    try ProjectPackage.write(project, to: url)
    let journal = try Journal(url: url.appendingPathComponent(ProjectPackage.journalName), durable: false)
    try journal.append(.setVolume(id: project.master.id, db: -6))
    #expect(try Journal.read(url: journal.url).commands.count == 1)

    // The edit goes into the package; its commit takes the journal away.
    try Command.setVolume(id: project.master.id, db: -6).apply(to: &project)
    try ProjectPackage.write(project, to: url)
    #expect(!FileManager.default.fileExists(atPath: journal.url.path), "the commit removed the journal")

    // The journal starts a new file after the save, and later edits land in it.
    try journal.reset()
    try journal.append(.setVolume(id: project.master.id, db: -12))
    let after = try Journal.read(url: journal.url)
    #expect(after.commands.count == 1 && !after.stoppedEarly)
}

/// Headers from before `ports` and `launches` existed carry neither key, and the schema stayed at version 1.
@Test func aHeaderWithoutPortsOrLaunchesStillOpens() throws {
    let url = Temp.directory().appendingPathComponent("Old.loopstudio")
    let project = Project(name: "Old")
    try ProjectPackage.write(project, to: url)
    let headerURL = url.appendingPathComponent("project.json")
    var header = try JSONSerialization.jsonObject(with: Data(contentsOf: headerURL)) as! [String: Any]
    for key in ["ports", "launches", "markers", "autoLoop", "randomSeed", "defaultFadeMs"] { header[key] = nil }
    try JSONSerialization.data(withJSONObject: header).write(to: headerURL)

    let loaded = try ProjectPackage.read(from: url)
    #expect(loaded.project.name == "Old")
    #expect(loaded.project.launches.isEmpty && loaded.project.markers.isEmpty)
    #expect(loaded.project.defaultFadeMs == AudioClip.defaultFadeMs)
}
