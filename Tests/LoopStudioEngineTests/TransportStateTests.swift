import AudioToolbox
import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

/// What a hosted plugin reads through its transport state block now.
private func transport(_ unit: AudioUnitEffect) -> (flags: AUHostTransportStateFlags, position: Double, start: Double, end: Double) {
    var flags = AUHostTransportStateFlags(), position = 0.0, start = 0.0, end = 0.0
    _ = unit.unit.transportStateBlock!(&flags, &position, &start, &end)
    return (flags, position, start, end)
}

/// Lemus handover P2-1, host side: the arrangement loop reaches a plugin as its cycle, in beats, and the
/// `changed` flag marks a start, a stop, a locate, a loop wrap and a tempo change, each once. The plugin is
/// Apple's delay on an audio track at 120 BPM, where a second is two beats.
@MainActor
@Test func theTransportBlockCarriesTheLoopAndMarksTheJumps() async throws {
    var project = Project(name: "T", sampleRate: rate)
    let slot = DeviceSlot(format: "audiounit", identifier: "aufx/dely/appl", name: "Delay")
    try Command.insertTrack(track: Track(name: "A", kind: .audio, devices: [slot]), index: 0).apply(to: &project)
    let host = PluginHost()
    host.outOfProcess = false
    #expect(await host.sync(project: project))
    #expect(host.failures.isEmpty, "\(host.failures)")
    let unit = try #require(host.units[slot.id])
    let plan = RenderPlan.compile(project, bank: AudioBank(), units: host.units)
    let renderer = Renderer(plan: plan, maxBlock: 512)
    var l = [Float](repeating: 0, count: 512), r = [Float](repeating: 0, count: 512)
    func render(_ frame: Int64, playing: Bool = true, loop: Range<Int64>? = nil) {
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            renderer.process(startFrame: frame, frames: 512, transport: playing, loop: loop, outLeft: lp.baseAddress!, outRight: rp.baseAddress!)
        } }
    }

    // Stopped at the top, no loop: nothing moves, no cycle.
    render(0, playing: false)
    var t = transport(unit)
    #expect(!t.flags.contains(.moving) && !t.flags.contains(.cycling) && t.start == 0 && t.end == 0)

    // Play inside a four-second loop: the cycle runs from beat 0 to beat 8, and the start is a change.
    let loop: Range<Int64> = 0..<Int64(4 * rate)
    render(0, loop: loop)
    t = transport(unit)
    #expect(t.flags.contains(.moving) && t.flags.contains(.cycling) && t.flags.contains(.changed))
    #expect(t.position == 0 && t.start == 0 && t.end == 8, "\(t)")

    // The next block follows the last one: no change.
    render(512, loop: loop)
    t = transport(unit)
    #expect(!t.flags.contains(.changed) && t.position == 512)

    // A locate to the second bar is a jump; the block after it is none.
    render(96_000, loop: loop)
    #expect(transport(unit).flags.contains(.changed))
    render(96_512, loop: loop)
    #expect(!transport(unit).flags.contains(.changed))

    // The loop wraps to its start: a jump back.
    render(0, loop: loop)
    t = transport(unit)
    #expect(t.flags.contains(.changed) && t.position == 0)

    // A loop that starts later, in beats: one second to three seconds is beat 2 to beat 6.
    render(512, loop: Int64(rate)..<Int64(3 * rate))
    t = transport(unit)
    #expect(t.flags.contains(.cycling) && t.start == 2 && t.end == 6, "\(t)")

    // The loop off: no cycle.
    render(1024)
    t = transport(unit)
    #expect(!t.flags.contains(.cycling) && t.start == 0 && t.end == 0)

    // A stop is a change; standing still is none; a locate while stopped is one.
    render(1536, playing: false)
    t = transport(unit)
    #expect(t.flags.contains(.changed) && !t.flags.contains(.moving))
    render(1536, playing: false)
    #expect(!transport(unit).flags.contains(.changed))
    render(48_000, playing: false)
    #expect(transport(unit).flags.contains(.changed))

    // A tempo change is a change, once. The plan carries the tempo, so this goes to the unit directly.
    unit.setSongPosition(frame: 48_512, beat: 2, bpm: 100, numerator: 4, denominator: 4, downbeat: 0, playing: false, toNextBeat: 0)
    #expect(transport(unit).flags.contains(.changed))
    unit.setSongPosition(frame: 49_024, beat: 2, bpm: 100, numerator: 4, denominator: 4, downbeat: 0, playing: false, toNextBeat: 0)
    #expect(!transport(unit).flags.contains(.changed))
}
