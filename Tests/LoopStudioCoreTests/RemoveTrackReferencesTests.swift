import Testing
import LoopStudioCore

@Test func removingATrackClearsInputsAndLaunchesAndUndoes() throws {
    var p = Project(name: "P")
    let source = Track(name: "Source", kind: .audio)
    var listener = Track(name: "Listener", kind: .audio)
    listener.inputTrack = source.id
    try Command.insertTrack(track: source, index: 0).apply(to: &p)
    try Command.insertTrack(track: listener, index: 1).apply(to: &p)
    try Command.setLaunches(launches: [Launch(track: source.id, slot: 0, tick: 0), Launch(track: listener.id, slot: 0, tick: 0)]).apply(to: &p)
    let before = p
    let inverse = try Command.removeTrack(id: source.id).apply(to: &p)
    #expect(p.tracks[0].inputTrack == nil, "no input from a track that is gone")
    #expect(p.launches.map(\.track) == [listener.id])
    #expect(p.validate().isEmpty)
    try inverse.apply(to: &p)
    #expect(p.tracks == before.tracks)
    #expect(p.launches == before.launches)
    #expect(p == before)
}

@Test func removingADeviceOrATrackTakesItsAutomationAlongAndUndoes() throws {
    var p = Project(name: "P")
    var a = Track(name: "A", kind: .audio)
    let ret = Track(name: "Return", kind: .returnTrack)
    a.sends = [Send(target: ret.id, levelDb: -6)]
    try Command.insertTrack(track: ret, index: 0).apply(to: &p)
    try Command.insertTrack(track: a, index: 0).apply(to: &p)
    let delay = BuiltInEffects.makeSlot("delay")!
    try Command.insertDevice(track: a.id, device: delay, index: nil).apply(to: &p)
    let points = [AutomationPoint(tick: 0, value: 0.2), AutomationPoint(tick: 960, value: 0.8)]
    let mix = ParameterAddress(node: delay.id.rawValue, parameter: "mix")
    let send = ParameterAddress(node: a.id.rawValue, parameter: "send.\(ret.id.rawValue.uuidString)")
    try Command.setAutomation(track: a.id, target: mix, points: points).apply(to: &p)
    try Command.setAutomation(track: a.id, target: send, points: points).apply(to: &p)

    // A device: its lane goes, undo brings it back.
    let undoDevice = try Command.removeDevice(track: a.id, device: delay.id).apply(to: &p)
    #expect(p.tracks[0].automation.map(\.target) == [send])
    try undoDevice.apply(to: &p)
    #expect(p.tracks[0].devices.map(\.id) == [delay.id])
    #expect(p.tracks[0].automation.first { $0.target == mix }?.points == points)

    // A return track: the send lanes that pointed at it go too.
    let undoTrack = try Command.removeTrack(id: ret.id).apply(to: &p)
    #expect(p.tracks[0].automation.map(\.target) == [mix])
    #expect(p.validate().isEmpty)
    try undoTrack.apply(to: &p)
    #expect(p.tracks[0].automation.first { $0.target == send }?.points == points)
    #expect(p.tracks[0].sends.map(\.target) == [ret.id])
}
