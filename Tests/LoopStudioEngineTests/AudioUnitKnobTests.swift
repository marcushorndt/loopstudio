import AudioToolbox
import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

/// Lemus handover P3-2: the knobs of a hosted plugin. The knob list follows the plugin's parameter tree and
/// hides what is no knob: an unnamed slot, a read-only parameter, a meter.

private func parameter(_ id: String, _ name: String, _ address: AUParameterAddress, _ min: AUValue, _ max: AUValue,
                       unit: AudioUnitParameterUnit = .generic, unitName: String? = nil,
                       flags: AudioUnitParameterOptions = [.flag_IsReadable, .flag_IsWritable], strings: [String]? = nil) -> AUParameter {
    AUParameterTree.createParameter(withIdentifier: id, name: name, address: address, min: min, max: max, unit: unit,
                                    unitName: unitName, flags: flags, valueStrings: strings, dependentParameters: nil)
}

@Test func hiddenAndGroupedParametersMakeTheRightKnobs() {
    let cutoff = parameter("cutoff", "Cutoff", 1, 20, 20_000, unit: .hertz, unitName: "Hz",
                           flags: [.flag_IsReadable, .flag_IsWritable, .flag_DisplayLogarithmic])
    let unnamed = parameter("p020", "", 2, 0, 1)
    let meter = parameter("level", "Level", 3, 0, 1, flags: [.flag_IsReadable, .flag_MeterReadOnly])
    let readOnly = parameter("version", "Version", 4, 0, 100, flags: [.flag_IsReadable])
    let mode = parameter("mode", "Mode", 5, 0, 2, unit: .indexed, strings: ["A", "B", "C"])
    let on = parameter("on", "On", 6, 0, 1, unit: .boolean)
    let empty = parameter("fixed", "Fixed", 7, 1, 1)
    let resonance = parameter("res", "Res", 8, 0, 1)
    let decay = parameter("decay", "Decay", 9, 0, 10, unitName: "s")
    let envelope = AUParameterTree.createGroup(withIdentifier: "env", name: "Env", children: [decay])
    let filter = AUParameterTree.createGroup(withIdentifier: "filter", name: "Filter", children: [resonance, envelope])
    let silent = AUParameterTree.createGroup(withIdentifier: "silent", name: "Silent", children: [parameter("p099", "", 10, 0, 1)])
    let tree = AUParameterTree.createTree(withChildren: [cutoff, unnamed, meter, readOnly, mode, on, empty, filter, silent])

    let groups = AudioUnitEffect.knobGroups(of: tree)
    #expect(groups.map(\.name) == ["", "Filter", "Filter / Env"], "\(groups.map(\.name))")
    let top = groups[0].knobs
    #expect(top.map(\.name) == ["Cutoff", "Mode", "On"], "hidden: no name, a meter, read only, an empty range")
    #expect(top[0].min == 20 && top[0].max == 20_000 && top[0].unit == "Hz" && top[0].logarithmic)
    #expect(top[0].key == "au.1")
    #expect(top[1].choices == ["A", "B", "C"] && top[1].unit.isEmpty)
    #expect(top[2].choices == ["Off", "On"])
    #expect(groups[1].knobs.map(\.name) == ["Res"])
    #expect(groups[2].knobs.map(\.name) == ["Decay"] && groups[2].knobs[0].unit == "s")
}

/// The Gaze AU (`aumu/Gaze/Mrhd`): the PLAY switch and 128 knob slots named after the knobs of the room it
/// holds (the first program is THE ROOM: the knobs of its guitar come first). Runs only where the component is installed.
@MainActor
@Test func theGazeAUGivesItsKnobs() async throws {
    let identifier = "aumu/Gaze/Mrhd"
    guard AudioUnitCatalog.list().contains(where: { $0.identifier == identifier }) else { return }
    let unit = try await AudioUnitEffect.instantiate(identifier: identifier, sampleRate: 48_000, outOfProcess: false)
    let groups = unit.knobGroups()
    let knobs = groups.flatMap(\.knobs)
    #expect(knobs.count == 129, "\(knobs.count) knobs")
    let play = try #require(knobs.first { $0.name == "Play" })
    #expect(play.choices == ["Off", "On"], "\(play.choices)")
    let named = knobs.filter { $0.name.hasPrefix("g1 ") }
    #expect(!named.isEmpty, "the lead guitar's knobs carry its id: \(knobs.prefix(8).map(\.name))")
    for k in knobs where k.choices.isEmpty { #expect(k.min == 0 && k.max == 1, "\(k.name) runs 0 to 1") }
    // The keys are the automation keys of the same parameters.
    let automated = Set(unit.automatableParameters().map(\.key))
    for k in knobs { #expect(automated.contains(k.key), "\(k.name) is an automation target") }

    // A knob write reaches the parameter.
    let tone = try #require(knobs.first { $0.name == "g1 TONE" })
    unit.setParameter(tone.address, 0.25)
    #expect(unit.parameterValue(tone.address) == 0.25)
    unit.setParameter(key: tone.key, 2)
    #expect(unit.parameterValue(tone.address) == 1, "clamped to the range")
}
