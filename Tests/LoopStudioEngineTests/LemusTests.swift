import AVFoundation
import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

/// Lemus handover P2-2 and P2-4. These tests load the real Lemus machines from this Mac, so they run only with
/// `LOOPSTUDIO_LEMUS=1` and only when the component is installed. Each machine is loaded in process: the
/// questions here are about the plugin, not about the hosting process (P1-2 covers that).

private let rate = 48_000.0

private func installed(_ identifier: String) -> Bool {
    AudioUnitCatalog.list().contains { $0.identifier == identifier }
}

private func lemusEnabled() -> Bool {
    ProcessInfo.processInfo.environment["LOOPSTUDIO_LEMUS"] == "1"
}

/// One MIDI message at a time in seconds from the start of a paced render.
private struct Event {
    var at: Double
    var status: UInt8, data1: UInt8, data2: UInt8
}

/// Renders `seconds` of audio at wall-clock pace in 512-frame blocks, sends `events` at their times, and returns
/// the peak before `measureFrom` and the peak from there on. The Lemus machines run their firmware on the audio
/// thread and (the Virus C) on a thread of their own, so a faster-than-real-time render is not what the app does.
private func pacedRender(_ unit: AudioUnitEffect, seconds: Double, events: [Event], measureFrom: Double) -> (before: Float, after: Float) {
    let frames = 512
    let zero = [Float](repeating: 0, count: frames)
    let o0 = UnsafeMutablePointer<Float>.allocate(capacity: frames), o1 = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    defer { o0.deallocate(); o1.deallocate() }
    let blockSeconds = Double(frames) / rate
    var before: Float = 0, after: Float = 0, blocks = 0
    var pending = events.sorted { $0.at < $1.at }
    let wall = Date()
    while Double(blocks) * blockSeconds < seconds {
        let t = Double(blocks) * blockSeconds
        while let e = pending.first, e.at <= t {
            unit.sendMIDI(e.status, e.data1, e.data2)
            pending.removeFirst()
        }
        _ = zero.withUnsafeBufferPointer { z in
            let ins: [UnsafePointer<Float>] = [z.baseAddress!, z.baseAddress!]
            let outs: [UnsafeMutablePointer<Float>] = [o0, o1]
            return ins.withUnsafeBufferPointer { i in outs.withUnsafeBufferPointer { o in unit.process(frames: frames, input: i.baseAddress!, output: o.baseAddress!) } }
        }
        var peak: Float = 0
        for k in 0..<frames { peak = max(peak, abs(o0[k]), abs(o1[k])) }
        if t < measureFrom { before = max(before, peak) } else { after = max(after, peak) }
        blocks += 1
        let wait = wall.addingTimeInterval(Double(blocks) * blockSeconds).timeIntervalSinceNow
        if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
    }
    return (before, after)
}

private func megabytes(_ bytes: Int) -> String { String(format: "%.2f MB", Double(bytes) / 1_048_576) }

// MARK: - P2-2 (a): a 303 parameter survives a state round trip

/// Lemus handover P2-2 (a). Each Lemus plugin gives the host 128 slots `p001` to `p128` with the machine's control
/// names. This moves the 303's CUT OFF (or the first writable slot when the names are missing), reads `fullState`,
/// restores it into a fresh instance and expects the value back. The 303 keeps its patterns in the same state
/// (`machine`, the battery-backed RAM, base64 in the JUCE value tree), so a pattern written on the panel takes
/// the same path; that part needs clicks in the plugin window and stays a manual check.
@MainActor
@Test func the303StateRoundTripKeepsAKnob() async throws {
    guard lemusEnabled(), installed("aumu/R303/Lmus") else { return }
    let unit = try await AudioUnitEffect.instantiate(identifier: "aumu/R303/Lmus", sampleRate: rate)
    let tree = try #require(unit.unit.parameterTree)
    let writable = tree.allParameters.filter { $0.flags.contains(.flag_IsWritable) && $0.maxValue > $0.minValue }
    print("303 parameters (\(tree.allParameters.count), \(writable.count) writable):",
          tree.allParameters.prefix(24).map { "\($0.identifier)=\($0.displayName)" }.joined(separator: ", "))
    let knob = try #require(writable.first { $0.displayName.lowercased().contains("cut") } ?? writable.first)
    let range = knob.maxValue - knob.minValue
    // Move it to the far quarter of its range from where it is.
    let target = knob.value - knob.minValue < range / 2 ? knob.minValue + 0.75 * range : knob.minValue + 0.25 * range
    let sizeBefore = unit.savedState()?.count ?? 0
    knob.setValue(target, originator: nil)
    // Let the plugin see the change on its audio thread before the state is read.
    _ = pacedRender(unit, seconds: 0.1, events: [], measureFrom: 0)
    #expect(abs(knob.value - target) < 0.001 * range, "\(knob.displayName) took the value")
    let state = try #require(unit.savedState())
    print("303 state: \(sizeBefore) bytes before, \(state.count) bytes after moving \(knob.identifier) (\(knob.displayName)) to \(target)")

    let fresh = try await AudioUnitEffect.instantiate(identifier: "aumu/R303/Lmus", sampleRate: rate)
    let same = try #require(fresh.unit.parameterTree?.parameter(withAddress: knob.address))
    #expect(abs(same.value - target) > 0.01 * range, "a new instance starts elsewhere, so the restore is visible")
    fresh.restore(state: state)
    _ = pacedRender(fresh, seconds: 0.1, events: [], measureFrom: 0)
    #expect(abs(same.value - target) < 0.001 * range, "\(knob.displayName) came back from fullState: \(same.value) for \(target)")
}

// MARK: - P2-2 (b): state sizes

/// Lemus handover P2-2 (b). The byte size of each machine's `fullState` as the project stores it (a binary
/// property list, `AudioUnitEffect.savedState`). The Virus C holds flash and RAM, so it is the one to watch: the
/// project writes every plugin state with each save, and autosave runs 1.5 s after an edit. The size is read right
/// after the load and again after six seconds of paced rendering, so the Virus C has booted.
@MainActor
@Test func theLemusStateSizes() async throws {
    guard lemusEnabled() else { return }
    var sizes: [String: Int] = [:]
    for identifier in ["aumu/R303/Lmus", "aumu/R808/Lmus", "aumu/R909/Lmus", "aumu/Avrc/Lmus"] where installed(identifier) {
        let unit = try await AudioUnitEffect.instantiate(identifier: identifier, sampleRate: rate)
        let atLoad = unit.savedState()?.count ?? 0
        let seconds = identifier == "aumu/Avrc/Lmus" ? 6.0 : 1.0
        _ = pacedRender(unit, seconds: seconds, events: [], measureFrom: 0)
        let after = unit.savedState()?.count ?? 0
        print("state size \(identifier): \(atLoad) bytes (\(megabytes(atLoad))) at load, \(after) bytes (\(megabytes(after))) after \(seconds) s")
        sizes[identifier] = after
        #expect(after > 0, "\(identifier) has a state")
    }
    if let virus = sizes["aumu/Avrc/Lmus"] {
        #expect(virus < 2 * 1_048_576, "the Virus C state is below 2 MB: \(virus) bytes")
    }
}

// MARK: - P2-4: MIDI channels

/// Lemus handover P2-4. Clip notes keep their channel in the status byte. This plays one note on channel 1
/// (0x90), channel 10 (0x99) and channel 2 (0x91) into the 303 and the 909 and measures the peak. Each run is
/// three seconds at wall-clock pace: the note at 0.25 s, off at 1.5 s, then two seconds of silence so a tail
/// does not leak into the next channel's run. The 909 firmware is omni at power-on (`docs/firmware.md`: basic
/// channel 10, omni on), and the 303 plays its voice from MIDI without a channel setting, so both should answer
/// on all three. The 909 also gets a snare (note 38) on channel 1, from the drum map in the handover.
@MainActor
@Test func theLemusMachinesAnswerOnTheseMIDIChannels() async throws {
    guard lemusEnabled() else { return }
    let channels: [(name: String, status: UInt8)] = [("1", 0x90), ("10", 0x99), ("2", 0x91)]
    for (identifier, note) in [("aumu/R303/Lmus", UInt8(48)), ("aumu/R909/Lmus", UInt8(36))] where installed(identifier) {
        let unit = try await AudioUnitEffect.instantiate(identifier: identifier, sampleRate: rate)
        // Let the machine settle: the 909 starts switched on, the 303's CPU has booted.
        _ = pacedRender(unit, seconds: 1, events: [], measureFrom: 0)
        var answers: [String: Float] = [:]
        for channel in channels {
            let events = [Event(at: 0.25, status: channel.status, data1: note, data2: 100),
                          Event(at: 1.5, status: channel.status & 0x0F | 0x80, data1: note, data2: 0)]
            let r = pacedRender(unit, seconds: 3, events: events, measureFrom: 0.25)
            #expect(r.before < 0.001, "\(identifier) is quiet before the note on channel \(channel.name): \(r.before)")
            answers[channel.name] = r.after
            unit.silenceNotes()
            _ = pacedRender(unit, seconds: 2, events: [], measureFrom: 0)
        }
        let table = channels.map { "channel \($0.name): peak \(answers[$0.name] ?? 0)" }.joined(separator: ", ")
        print("\(identifier) note \(note): \(table)")
        #expect(answers["1"] ?? 0 > 0.001, "\(identifier) answers on channel 1, where the clips send")
        #expect(answers["10"] ?? 0 > 0.001, "\(identifier) answers on channel 10")
        #expect(answers["2"] ?? 0 > 0.001, "\(identifier) answers on channel 2")

        if identifier == "aumu/R909/Lmus" {
            let snare = pacedRender(unit, seconds: 2, events: [Event(at: 0.25, status: 0x90, data1: 38, data2: 100)], measureFrom: 0.25)
            print("\(identifier) note 38 (SD) on channel 1: peak \(snare.after)")
            #expect(snare.before < 0.001 && snare.after > 0.001, "the 909 plays the snare from note 38")
        }
    }
}
