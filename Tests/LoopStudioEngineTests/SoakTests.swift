import AVFoundation
import Darwin
import Foundation
import Synchronization
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

/// Counts heap allocations on one thread through libmalloc's logger hook. Every malloc, calloc and realloc
/// on any thread calls the hook; only those on the audited thread count.
private enum AllocationAudit {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
    nonisolated(unsafe) static var thread: pthread_t?
    static let count = Atomic<Int>(0)
    static let allocate: UInt32 = 2 // MALLOC_LOG_TYPE_ALLOCATE
    /// The call stacks of the first allocations, in memory set aside up front (the hook must not allocate).
    static let sampleCount = 64, sampleDepth = 24
    nonisolated(unsafe) static let samples = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: sampleCount * sampleDepth)
    static let sampled = Atomic<Int>(0)
    nonisolated(unsafe) static var inHook = false

    /// Runs `body` with the hook installed, and returns how many allocations it made on this thread.
    static func allocations(_ body: () -> Void) -> Int {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return -1 }
        let slot = symbol.assumingMemoryBound(to: Logger?.self)
        let previous = slot.pointee
        thread = pthread_self()
        count.store(0, ordering: .relaxed)
        sampled.store(0, ordering: .relaxed)
        samples.initialize(repeating: nil, count: sampleCount * sampleDepth)
        slot.pointee = { type, _, _, _, _, _ in
            guard type & AllocationAudit.allocate != 0, let t = AllocationAudit.thread, pthread_equal(t, pthread_self()) != 0,
                  !AllocationAudit.inHook else { return }
            AllocationAudit.inHook = true
            AllocationAudit.count.add(1, ordering: .relaxed)
            let k = AllocationAudit.sampled.load(ordering: .relaxed)
            if k < AllocationAudit.sampleCount {
                _ = backtrace(AllocationAudit.samples + k * AllocationAudit.sampleDepth, Int32(AllocationAudit.sampleDepth))
                AllocationAudit.sampled.store(k + 1, ordering: .relaxed)
            }
            AllocationAudit.inHook = false
        }
        body()
        slot.pointee = previous
        thread = nil
        return count.load(ordering: .relaxed)
    }

    /// The sampled call stacks as symbol names, for a failure message.
    static func report() -> String {
        var lines: [String] = []
        for k in 0..<min(sampled.load(ordering: .relaxed), 6) {
            var names: [String] = []
            for d in 0..<sampleDepth {
                guard let p = samples[k * sampleDepth + d] else { break }
                var info = Dl_info()
                if dladdr(p, &info) != 0, let s = info.dli_sname { names.append(String(cString: s)) } else { names.append("?") }
            }
            lines.append(names.joined(separator: " < "))
        }
        return lines.joined(separator: "\n")
    }
}

/// A busy project: eight audio tracks with looping clips and fades, every built-in effect, a synced LFO,
/// sends to a return with a reverb, a group, automation on faders and knobs, and a session clip that plays.
private func busyProject() -> (Project, AudioBank, SessionSimulation) {
    var project = Project(name: "Soak", sampleRate: rate)
    let bank = AudioBank()
    let n = Int(2 * rate)
    let asset = Asset(sha256: "soak", name: "tone", frames: Int64(n), sampleRate: rate, channels: 2)
    try! Command.addAsset(asset: asset).apply(to: &project)
    let tone = (0..<n).map { Float(sin(Double($0) * 2 * .pi * 220 / rate)) * 0.3 }
    bank.insert(PCMBuffer(samples: [tone, tone], sampleRate: rate), for: asset.id)

    let ret = Track(name: "Reverb", kind: .returnTrack)
    try! Command.insertTrack(track: ret, index: 0).apply(to: &project)
    var reverb = BuiltInEffects.makeSlot("reverb")!
    reverb.params["mix"] = 1
    try! Command.insertDevice(track: ret.id, device: reverb, index: nil).apply(to: &project)
    let group = Track(name: "Group", kind: .group)
    try! Command.insertTrack(track: group, index: 0).apply(to: &project)
    try! Command.insertDevice(track: group.id, device: BuiltInEffects.makeSlot("compressor")!, index: nil).apply(to: &project)

    let effects = ["filter", "delay", "eq3", "utility", "limiter", "compressor", "filter", "delay"]
    for i in 0..<8 {
        var t = Track(name: "T\(i)", kind: .audio, volumeDb: -3, pan: Double(i - 4) / 4)
        t.output = i % 2 == 0 ? group.id : nil
        t.sends = [Send(target: ret.id, levelDb: -12)]
        try! Command.insertTrack(track: t, index: project.tracks.count).apply(to: &project)
        var fx = BuiltInEffects.makeSlot(effects[i])!
        if effects[i] == "filter" { fx.params = ["cutoff": 900, "lfoAmount": 0.7, "lfoRateSync": 1, "lfoRateDivision": 4] }
        if effects[i] == "delay" { fx.params = ["timeMsSync": 1, "timeMsDivision": 6, "feedback": 0.4, "mix": 0.3] }
        try! Command.insertDevice(track: t.id, device: fx, index: nil).apply(to: &project)
        // Looping clips of odd lengths, so passes end on every block boundary at some point.
        var c = project.makeAudioClip(asset: asset.id, start: Tick(Int64(i) * 480), length: Tick(3840 * 64))
        c.loop = true; c.fadeInMs = 5; c.fadeOutMs = 5
        try! Command.insertClip(track: t.id, clip: .audio(c)).apply(to: &project)
        let volume = ParameterAddress(node: t.id.rawValue, parameter: "volume")
        try! Command.setAutomation(track: t.id, target: volume,
                                   points: [AutomationPoint(tick: 0, value: -12), AutomationPoint(tick: Tick(3840 * 8), value: 0), AutomationPoint(tick: Tick(3840 * 16), value: -12)]).apply(to: &project)
        let knob = ParameterAddress(node: fx.id.rawValue, parameter: effects[i] == "filter" ? "cutoff" : "mix")
        try! Command.setAutomation(track: t.id, target: knob,
                                   points: [AutomationPoint(tick: 0, value: 0.2), AutomationPoint(tick: Tick(3840 * 4), value: 0.8)]).apply(to: &project)
        // A session clip in slot 0; the first track launches it.
        var s = project.makeAudioClip(asset: asset.id, start: 0, length: Tick(3840 * 2))
        s.loop = true
        try! Command.setSlot(track: t.id, index: 0, slot: SessionSlot(clip: .audio(s))).apply(to: &project)
    }
    let first = project.tracks.first { $0.name == "T0" }!.id
    project.launches = [Launch(track: first, slot: 0, tick: 0)]
    let session = SessionSimulator.run(project, horizon: Tick(3840 * 2_000))
    return (project, bank, session)
}

/// Renders `seconds` of the busy project through the live engine, as the sound card would call it, with the
/// metronome on and the loop set, and counts the allocations on the audio thread after a short warm-up.
private func soak(seconds: Double, block: Int = 512) -> (allocations: Int, peak: Float) {
    let (project, bank, session) = busyProject()
    let plan = RenderPlan.compile(project, bank: bank, session: session)
    let engine = LiveEngine(sampleRate: rate)
    engine.setRenderer(Renderer(plan: plan))
    engine.setMetronome(enabled: true, beatFrames: 24_000, beatsPerBar: 4)
    engine.setClickGrid(frames: (0..<4_000).map { Int64($0) * 24_000 }, accents: (0..<4_000).map { $0 % 4 == 0 })
    engine.setLoop(0..<Int64(rate * 30))
    let list = AudioBufferList.allocate(maximumBuffers: 2)
    let channels = (0..<2).map { _ -> UnsafeMutablePointer<Float> in .allocate(capacity: block) }
    defer { channels.forEach { $0.deallocate() }; list.unsafeMutablePointer.deallocate() }
    for (i, c) in channels.enumerated() { list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(block * 4), mData: c) }
    engine.play()
    var peak: Float = 0
    let left = channels[0], pointer = list.unsafeMutablePointer
    // Plain loops: a `for` over a range goes through generic code that allocates in a debug build,
    // and that would be charged to the engine.
    func callback() {
        engine.render(frameCount: block, bufferList: pointer, host: mach_absolute_time())
        var i = 0
        while i < block { peak = max(peak, abs(left[i])); i += 1 }
    }
    // Warm-up: the first blocks take over notes and settle effects; they may touch the heap once.
    var warm = 0
    while warm < 8 { callback(); warm += 1 }
    let blocks = Int(seconds * rate) / block
    let allocations = AllocationAudit.allocations {
        var k = 0
        while k < blocks { callback(); k += 1 }
    }
    return (allocations, peak)
}

/// The hook is one global: these tests run one after the other, never beside each other.
@Suite(.serialized) struct SoakTests {
    /// The realtime rule, measured: no heap allocation in the audio callback. Twenty seconds here; with
    /// `LOOPSTUDIO_SOAK=1` the ten-minute soak of the architecture plan.
    @Test func theAudioCallbackAllocatesNothing() {
        let long = ProcessInfo.processInfo.environment["LOOPSTUDIO_SOAK"] == "1"
        let result = soak(seconds: long ? 600 : 20)
        #expect(result.peak > 0.01, "the project makes sound")
        if result.allocations != 0 { print("SOAK allocation sites:\n" + AllocationAudit.report()) }
        #expect(result.allocations == 0, "\(result.allocations) allocations on the audio thread")
    }

    @Test func theAllocationHookSeesAllocations() {
        let seen = AllocationAudit.allocations {
            var a: [[Int]] = []
            for i in 0..<100 { a.append([Int](repeating: i, count: 1_000)) }
            withExtendedLifetime(a) {}
        }
        #expect(seen >= 100)
    }
}
