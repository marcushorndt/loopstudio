import Foundation
import Testing
@testable import LoopStudioCore

private func channels(_ n: Int, _ prefix: String) -> [DeviceChannel] {
    (0..<n).map { DeviceChannel(index: $0, name: "\(prefix) \($0 + 1)") }
}

private let builtIn = AudioDeviceInfo(uid: "builtin", name: "MacBook Speakers", transport: "built-in",
                                      outputs: channels(2, "Out"), sampleRates: [44_100, 48_000], bufferMin: 32, bufferMax: 1024)
private let mic = AudioDeviceInfo(uid: "mic", name: "MacBook Microphone", transport: "built-in",
                                  inputs: channels(1, "In"), sampleRates: [48_000], bufferMin: 32, bufferMax: 1024)
private let interface = AudioDeviceInfo(uid: "usb18", name: "Studio 18", transport: "usb",
                                        inputs: channels(8, "In"), outputs: channels(18, "Out"),
                                        sampleRates: [44_100, 48_000, 96_000], bufferMin: 16, bufferMax: 2048)

private let main = IOPort(name: "Main", direction: .output, channels: 2)
private let cue = IOPort(name: "Cue", direction: .output, channels: 2)
private let mono = IOPort(name: "Out 5", direction: .output, channels: 1)
private let stereoIn = IOPort(name: "In 1-2", direction: .input, channels: 2)

private func resolve(_ profile: AudioIOProfile, ports: [IOPort] = [main, cue, stereoIn], used: [IOPort]? = nil,
                     devices: [AudioDeviceInfo] = [builtIn, mic, interface]) -> ResolvedIO {
    IOResolver.resolve(profile: profile, ports: ports, used: Set((used ?? ports).map(\.id)), devices: devices,
                       defaultOutputUID: "builtin", defaultInputUID: "mic")
}

@Test func explicitMappingIsKept() {
    let profile = AudioIOProfile(outputDeviceUID: "usb18", inputDeviceUID: "usb18",
                                 outputs: [PortMapping(port: main.id, channels: [4, 5]), PortMapping(port: cue.id, channels: [10, 11])],
                                 inputs: [PortMapping(port: stereoIn.id, channels: [2, 3])])
    let r = resolve(profile)
    #expect(r.outputs[main.id] == [4, 5])
    #expect(r.outputs[cue.id] == [10, 11])
    #expect(r.inputs[stereoIn.id] == [2, 3])
    #expect(r.issues.isEmpty)
    #expect(r.outputDevice?.uid == "usb18")
}

@Test func withoutMappingPortsGetFreeChannelsInOrder() {
    let r = resolve(AudioIOProfile(outputDeviceUID: "usb18"))
    #expect(r.outputs[main.id] == [0, 1])
    #expect(r.outputs[cue.id] == [2, 3])
    #expect(r.issues.filter { if case .autoMapped = $0 { true } else { false } }.isEmpty, "no saved mapping, so nothing to report")
}

@Test func missingDeviceFallsBackToTheDefault() {
    let r = resolve(AudioIOProfile(outputDeviceUID: "gone", inputDeviceUID: "mic"))
    #expect(r.outputDevice?.uid == "builtin")
    #expect(r.issues.contains(.deviceMissing(uid: "gone")))
    #expect(r.outputs[main.id] == [0, 1])
}

@Test func usedPortWithoutChannelsIsReportedButUnusedIsNot() {
    // The built-in speakers have two channels: Main takes both, Cue has none left.
    let used = resolve(AudioIOProfile(outputDeviceUID: "builtin"), used: [main, cue])
    #expect(used.issues.contains(.unmapped(port: cue.id)))
    #expect(used.outputs[cue.id] == nil)
    let unused = resolve(AudioIOProfile(outputDeviceUID: "builtin"), used: [main])
    #expect(!unused.issues.contains(.unmapped(port: cue.id)))
}

@Test func badSavedMappingFallsBackAndSaysSo() {
    let profile = AudioIOProfile(outputDeviceUID: "builtin", outputs: [
        PortMapping(port: main.id, channels: [6, 7]), // the device has only 2 channels
    ])
    let r = resolve(profile, ports: [main])
    #expect(r.issues.contains(.channelOutOfRange(port: main.id, channel: 6, available: 2)))
    #expect(r.issues.contains(.autoMapped(port: main.id)))
    #expect(r.outputs[main.id] == [0, 1])

    let wide = resolve(AudioIOProfile(outputDeviceUID: "usb18", outputs: [PortMapping(port: main.id, channels: [3])]), ports: [main])
    #expect(wide.issues.contains(.widthMismatch(port: main.id, expected: 2, got: 1)))
    #expect(wide.outputs[main.id] == [0, 1])
}

@Test func negativeChannelsAreRejected() {
    let r = resolve(AudioIOProfile(outputDeviceUID: "usb18", outputs: [PortMapping(port: mono.id, channels: [-1])]), ports: [mono])
    #expect(r.issues.contains(.channelOutOfRange(port: mono.id, channel: -1, available: 18)))
}

@Test func stereoPortFoldsOntoAMonoDevice() {
    let monoOut = AudioDeviceInfo(uid: "m", name: "Mono", outputs: channels(1, "Out"), sampleRates: [48_000])
    let r = resolve(AudioIOProfile(outputDeviceUID: "m"), ports: [main], devices: [monoOut])
    #expect(r.outputs[main.id] == [0, 0])
    #expect(r.issues.contains(.foldedToMono(port: main.id)))
}

@Test func sharedChannelsAreReported() {
    let profile = AudioIOProfile(outputDeviceUID: "usb18", outputs: [
        PortMapping(port: main.id, channels: [0, 1]), PortMapping(port: cue.id, channels: [1, 2]),
    ])
    let r = resolve(profile, ports: [main, cue])
    #expect(r.issues.contains(.sharedChannel(channel: 1, ports: [main.id, cue.id])))
}

@Test func sampleRateAndBufferFollowTheDevice() {
    let r = resolve(AudioIOProfile(outputDeviceUID: "builtin", sampleRate: 96_000, bufferFrames: 8), ports: [main])
    #expect(r.sampleRate == 48_000)
    #expect(r.bufferFrames == 32)
    #expect(r.issues.contains(.sampleRateChanged(requested: 96_000, using: 48_000)))
    #expect(r.issues.contains(.bufferChanged(requested: 8, using: 32)))
}

@Test func separateInputDeviceAtAnotherRateNeedsAnAggregate() {
    let r = resolve(AudioIOProfile(outputDeviceUID: "usb18", inputDeviceUID: "mic", sampleRate: 96_000))
    #expect(r.issues.contains(.inputRateMismatch(uid: "mic", rate: 96_000)))
}

@Test func noDeviceAtAll() {
    let r = resolve(AudioIOProfile(), ports: [main], devices: [])
    #expect(r.outputDevice == nil)
    #expect(r.issues.contains(.noDevice(.output)))
}

@Test func resolverIsDeterministic() {
    let profile = AudioIOProfile(outputDeviceUID: "usb18", inputDeviceUID: "usb18")
    #expect(resolve(profile) == resolve(profile))
}

// MARK: MIDI

private let keys = MIDIEndpointInfo(uniqueID: 100, name: "Keys", manufacturer: "Acme")
private let pads = MIDIEndpointInfo(uniqueID: 200, name: "Pads")
private let asleep = MIDIEndpointInfo(uniqueID: 300, name: "Old Synth", isOffline: true)

@Test func omniListensToOnlineSources() {
    let r = MIDIResolver.resolve(MIDIInputSelection(), available: [pads, keys, asleep])
    #expect(r.sources == [100, 200])
    #expect(r.issue == nil)
}

@Test func chosenSourceIsUsedAlone() {
    let r = MIDIResolver.resolve(MIDIInputSelection(sourceUID: 200, channel: 3), available: [keys, pads])
    #expect(r.sources == [200] && r.channel == 3)
}

@Test func missingSourceGivesSilenceNotOmni() {
    let r = MIDIResolver.resolve(MIDIInputSelection(sourceUID: 999, sourceName: "Lost"), available: [keys, pads])
    #expect(r.sources.isEmpty)
    #expect(r.issue == .sourceMissing(uniqueID: 999, name: "Lost"))
    let off = MIDIResolver.resolve(MIDIInputSelection(sourceUID: 300), available: [asleep])
    #expect(off.sources.isEmpty)
    #expect(off.issue == .sourceOffline(uniqueID: 300, name: nil))
}

@Test func channelIsClampedTo15() {
    #expect(MIDIInputSelection(channel: 99).channel == 15)
}

// MARK: Port commands

@Test func newProjectsHaveDefaultPorts() {
    let p = Project(name: "P")
    #expect(p.ports.map(\.name) == ["Main", "Cue", "Input 1-2"])
    #expect(p.master.hardwareOutput == p.ports[0].id)
    #expect(p.validate().isEmpty)
}

@Test func portCommandsUndoExactly() throws {
    var p = Fixture.baseProject()
    let audio = Track(name: "A", kind: .audio), midi = Track(name: "M", kind: .midi)
    try Command.insertTrack(track: audio, index: 0).apply(to: &p)
    try Command.insertTrack(track: midi, index: 1).apply(to: &p)
    let extra = IOPort(name: "Out 5", direction: .output, channels: 1)
    let commands: [Command] = [
        .addPort(port: extra, index: 1),
        .setHardwareOutput(id: audio.id, port: extra.id),
        .setAudioInput(id: audio.id, port: p.ports[2].id),
        .setMIDIInput(id: midi.id, selection: MIDIInputSelection(sourceUID: 5, sourceName: "Keys", channel: 2)),
    ]
    for command in commands {
        let before = p
        let inverse = try command.apply(to: &p)
        #expect(p != before)
        try inverse.apply(to: &p)
        #expect(p == before)
        try command.apply(to: &p)
    }
    #expect(p.validate().isEmpty)
    #expect(p.ports[1].id == extra.id)
}

@Test func portRulesAreEnforced() throws {
    var p = Fixture.baseProject()
    let audio = Track(name: "A", kind: .audio), midi = Track(name: "M", kind: .midi), group = Track(name: "G", kind: .group)
    for (i, t) in [audio, midi, group].enumerated() { try Command.insertTrack(track: t, index: i).apply(to: &p) }
    let out = p.ports[0], input = p.ports[2]

    #expect(throws: CommandError.self) { try Command.setHardwareOutput(id: audio.id, port: input.id).apply(to: &p) } // input port as output
    #expect(throws: CommandError.self) { try Command.setAudioInput(id: audio.id, port: out.id).apply(to: &p) }
    #expect(throws: CommandError.self) { try Command.setAudioInput(id: midi.id, port: input.id).apply(to: &p) }
    #expect(throws: CommandError.self) { try Command.setMIDIInput(id: audio.id, selection: MIDIInputSelection()).apply(to: &p) }
    #expect(throws: CommandError.self) { try Command.setHardwareOutput(id: audio.id, port: PortID()).apply(to: &p) }

    // A track cannot have both a track output and a hardware output.
    try Command.setOutput(id: audio.id, target: group.id).apply(to: &p)
    #expect(throws: CommandError.self) { try Command.setHardwareOutput(id: audio.id, port: out.id).apply(to: &p) }
    try Command.setOutput(id: audio.id, target: nil).apply(to: &p)
    try Command.setHardwareOutput(id: audio.id, port: out.id).apply(to: &p)
    #expect(throws: CommandError.self) { try Command.setOutput(id: audio.id, target: group.id).apply(to: &p) }

    // A port in use cannot be removed.
    #expect(throws: CommandError.portInUse(out.id)) { try Command.removePort(id: out.id).apply(to: &p) }
    try Command.removePort(id: p.ports[1].id).apply(to: &p) // Cue is unused
    #expect(p.validate().isEmpty)
}
