import Foundation
import Testing
@testable import LoopStudioCore

private func temporaryLibrary() -> PresetLibrary {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("loopstudio-presets-\(UUID().uuidString)", isDirectory: true)
    return PresetLibrary(root: url)
}

/// A built-in effect's preset keeps its parameters and loses what belongs to the project.
@Test func aPresetRoundTripsThroughTheLibrary() throws {
    let library = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }
    var slot = BuiltInEffects.makeSlot("tapeEcho")!
    slot.params["feedback"] = 0.77
    slot.params["mix"] = 0.4
    slot.sidechain = TrackID()
    slot.folded = true
    slot.bypassed = true
    let saved = try library.save(DevicePreset(name: "Long Tail", device: slot))
    #expect(saved.pathExtension == "lspreset")
    #expect(saved.deletingLastPathComponent().lastPathComponent == "tapeEcho")

    let entries = library.list()
    #expect(entries.count == 1)
    #expect(entries[0].name == "Long Tail")
    #expect(entries[0].identifier == "tapeEcho")

    let preset = try DevicePreset.read(saved)
    #expect(preset.device.params["feedback"] == 0.77)
    #expect(preset.device.sidechain == nil, "a sidechain source is a track of one project")
    #expect(preset.device.folded == nil)
    #expect(preset.device.bypassed == false)

    // Into a project: a fresh ID, the preset's name.
    let fresh = preset.makeSlot()
    #expect(fresh.id != slot.id)
    #expect(fresh.name == "Long Tail")
    #expect(fresh.params["mix"] == 0.4)

    // Onto the existing device: the ID and the bypass stay.
    let applied = preset.applied(to: slot)
    #expect(applied.id == slot.id)
    #expect(applied.bypassed == true)
    #expect(applied.params["feedback"] == 0.77)
}

/// A rack preset carries its chains and macros; loading it renews every ID inside.
@Test func aRackPresetRenewsEveryIDInside() throws {
    let library = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }
    var rack = BuiltInEffects.makeSlot("audiorack")!
    var chain = RackChain(name: "A")
    chain.devices = [BuiltInEffects.makeSlot("delay")!, BuiltInEffects.makeSlot("compressor")!]
    rack.rack?.chains = [chain]
    let inner = chain.devices.map(\.id)
    try library.save(DevicePreset(name: "Dub Rack", device: rack))

    let preset = try DevicePreset.read(library.url(for: "Dub Rack", identifier: "audiorack"))
    let fresh = preset.makeSlot()
    #expect(fresh.rack?.chains.count == 1)
    #expect(fresh.rack?.chains[0].id != chain.id)
    let freshInner = fresh.rack!.chains[0].devices.map(\.id)
    #expect(freshInner.count == 2)
    #expect(Set(freshInner).isDisjoint(with: inner))
    #expect(fresh.rack!.chains[0].devices.map(\.identifier) == ["delay", "compressor"])
}

/// A plugin preset keeps the state blob and the parameter list; its folder name has no slashes.
@Test func aPluginPresetKeepsItsStateAndASafeFolder() throws {
    let library = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }
    var slot = DeviceSlot(format: "audiounit", identifier: "aufx/dely/appl", name: "AUDelay")
    slot.state = Data([1, 2, 3, 4])
    let url = try library.save(DevicePreset(name: "Slap: back/forth", device: slot))
    #expect(url.deletingLastPathComponent().lastPathComponent == "aufx-dely-appl")
    #expect(url.lastPathComponent == "Slap- back-forth.lspreset")
    let preset = try DevicePreset.read(url)
    #expect(preset.device.state == Data([1, 2, 3, 4]))
    #expect(preset.device.identifier == "aufx/dely/appl")
}

/// A file imported from elsewhere lands in the library under its own name; a bad file is skipped in the list.
@Test func importCopiesIntoTheLibraryAndBadFilesAreSkipped() throws {
    let library = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }
    let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).lspreset")
    defer { try? FileManager.default.removeItem(at: elsewhere) }
    try DevicePreset(name: "Bright", device: BuiltInEffects.makeSlot("eq3")!).write(to: elsewhere)
    let (entry, preset) = try library.importFile(elsewhere)
    #expect(entry.url.deletingLastPathComponent().lastPathComponent == "eq3")
    #expect(preset.name == "Bright")

    try Data("not json".utf8).write(to: library.folder(for: "eq3").appendingPathComponent("broken.lspreset"))
    #expect(library.list().map(\.name) == ["Bright"])

    var newer = preset
    newer.version = DevicePreset.currentVersion + 1
    let future = library.folder(for: "eq3").appendingPathComponent("future.lspreset")
    try newer.write(to: future)
    #expect(throws: PresetError.newerVersion(DevicePreset.currentVersion + 1)) { try DevicePreset.read(future) }
}
