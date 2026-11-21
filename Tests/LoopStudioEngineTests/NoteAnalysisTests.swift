import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

/// Harmonic tones (six partials, falling by 1/h) at MIDI notes, together for `seconds`, then 0.3 s of silence.
private func chord(_ notes: [Double], seconds: Double = 1.2) -> PCMBuffer {
    let n = Int(rate * (seconds + 0.3))
    var x = [Float](repeating: 0, count: n)
    for note in notes {
        let f = 440 * pow(2, (note - 69) / 12)
        for i in 0..<Int(rate * seconds) {
            // A 10 ms fade at both ends.
            let fade = Float(min(1, Double(i) / 480, Double(Int(rate * seconds) - i) / 480))
            var v: Float = 0
            for h in 1...6 { v += Float(sin(2 * .pi * f * Double(h) * Double(i) / rate)) / Float(h) }
            x[i] += 0.12 * v * fade
        }
    }
    return PCMBuffer(samples: [x], sampleRate: rate)
}

private func pitches(_ a: NoteAnalysis) -> [Int] { a.notes.map { Int($0.pitch.rounded()) }.sorted() }

/// The three notes of a chord, each found on its own, in tune.
@Test func theAnalysisFindsTheNotesOfAChord() {
    let a = NoteAnalysis.analyze(chord([60, 64, 67]))
    #expect(pitches(a) == [60, 64, 67])
    for note in a.notes { #expect(abs(note.pitch - note.pitch.rounded()) < 0.2) }
    // About as long as the chord: 1.2 s.
    for note in a.notes {
        let length = a.seconds(frame: Double(note.endFrame)) - a.seconds(frame: Double(note.startFrame))
        #expect(length > 1.0 && length < 1.4)
    }
}

/// Moving the third of the chord up a semitone: the file then holds C, F and G, and no E.
@Test func aNoteOfAChordMovesOnItsOwn() throws {
    let source = chord([60, 64, 67])
    let a = NoteAnalysis.analyze(source)
    let e = try #require(a.notes.first { Int($0.pitch.rounded()) == 64 })
    let edit = NoteEdit(source: AssetID(), changes: [NoteChange(key: e.key, pitch: 1)])
    let out = try #require(a.render(source, edit: edit))
    #expect(pitches(NoteAnalysis.analyze(out)) == [60, 65, 67])
}

/// A muted note is gone; the others stay.
@Test func aMutedNoteIsGone() throws {
    let source = chord([60, 64, 67])
    let a = NoteAnalysis.analyze(source)
    let e = try #require(a.notes.first { Int($0.pitch.rounded()) == 64 })
    let out = try #require(a.render(source, edit: NoteEdit(source: AssetID(), changes: [NoteChange(key: e.key, muted: true)])))
    let after = NoteAnalysis.analyze(out)
    #expect(pitches(after) == [60, 67], "\(after.notes.map { "\($0.key) \($0.pitch) \($0.frames)" })")
}

/// Without a change the render gives nothing: the clip keeps its file.
@Test func noChangeRendersNothing() {
    let source = chord([60, 64, 67], seconds: 0.4)
    let a = NoteAnalysis.analyze(source)
    #expect(a.render(source, edit: NoteEdit(source: AssetID())) == nil)
}

/// A shifted note starts later by the shift.
@Test func aShiftedNoteStartsLater() throws {
    let source = chord([60], seconds: 0.6)
    let a = NoteAnalysis.analyze(source)
    let c = try #require(a.notes.first)
    let out = try #require(a.render(source, edit: NoteEdit(source: AssetID(), changes: [NoteChange(key: c.key, shift: 0.25)])))
    let b = NoteAnalysis.analyze(out)
    let moved = try #require(b.notes.max { $0.level.reduce(0, +) < $1.level.reduce(0, +) })
    let delta = b.seconds(frame: Double(moved.startFrame)) - a.seconds(frame: Double(c.startFrame))
    #expect(abs(delta - 0.25) < 0.06)
}

/// A melody: C, C again after a short gap, then D. Three notes, the repeat on its own.
@Test func aRepeatedNoteIsANoteOfItsOwn() {
    var x = [Float](repeating: 0, count: Int(rate * 1.6))
    func tone(_ note: Double, from: Double, seconds: Double) {
        let f = 440 * pow(2, (note - 69) / 12), start = Int(rate * from), n = Int(rate * seconds)
        for i in 0..<n {
            let fade = Float(min(1, Double(i) / 240, Double(n - i) / 240))
            var v: Float = 0
            for h in 1...6 { v += Float(sin(2 * .pi * f * Double(h) * Double(i) / rate)) / Float(h) }
            x[start + i] += 0.15 * v * fade
        }
    }
    tone(60, from: 0, seconds: 0.4)
    tone(60, from: 0.48, seconds: 0.4)
    tone(62, from: 0.96, seconds: 0.4)
    let a = NoteAnalysis.analyze(PCMBuffer(samples: [x], sampleRate: rate))
    #expect(pitches(a) == [60, 60, 62])
}

/// Noise holds no notes, or nearly none.
@Test func noiseHoldsNoNotes() {
    var seed: UInt64 = 7
    let x: [Float] = (0..<Int(rate)).map { _ in
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: seed >> 11) % 2_000_000) / 2_000_000 * 0.3
    }
    let a = NoteAnalysis.analyze(PCMBuffer(samples: [x], sampleRate: rate))
    #expect(a.notes.count <= 2)
}

/// The level of frequency `f` in `b`, over half a second from `at`.
private func level(_ b: PCMBuffer, _ f: Double, at: Int) -> Double {
    var re = 0.0, im = 0.0
    for i in at..<(at + 24_000) {
        let v = Double(b.channel(0)[i])
        re += v * cos(2 * .pi * f * Double(i) / rate); im += v * sin(2 * .pi * f * Double(i) / rate)
    }
    return 2 * sqrt(re * re + im * im) / 24_000
}

/// Pure tones a minor third apart (A2, C3, E3, like a soft pad): the middle one moves up a tone at its own
/// level, and the two others stay as they were.
@Test func aLowNoteMovesWithoutTakingItsNeighbours() throws {
    let n = Int(rate * 2.5)
    var x = [Float](repeating: 0, count: n)
    for f in [110.0, 130.81, 164.81] {
        for i in 0..<Int(rate * 2.2) {
            let fade = Float(min(1, Double(i) / 2_400, Double(Int(rate * 2.2) - i) / 2_400))
            x[i] += 0.1 * Float(sin(2 * .pi * f * Double(i) / rate)) * fade
        }
    }
    let source = PCMBuffer(samples: [x], sampleRate: rate)
    let a = NoteAnalysis.analyze(source)
    #expect(pitches(a) == [45, 48, 52], "\(a.notes.map { "\($0.key) \($0.frames)" })")
    let c = try #require(a.notes.first { Int($0.pitch.rounded()) == 48 })
    let out = try #require(a.render(source, edit: NoteEdit(source: AssetID(), changes: [NoteChange(key: c.key, pitch: 2)])))
    for at in [24_000, 60_000] {
        #expect(level(out, 130.81, at: at) < 0.005)
        #expect(abs(level(out, 146.83, at: at) - 0.1) < 0.015)
        #expect(abs(level(out, 110, at: at) - 0.1) < 0.012)
        #expect(abs(level(out, 164.81, at: at) - 0.1) < 0.005)
    }
}

/// A note that only changes its level keeps every detail: at 0 dB the file comes back as it was.
@Test func aLevelChangeKeepsTheRecording() throws {
    let source = chord([60, 64, 67])
    let a = NoteAnalysis.analyze(source)
    let e = try #require(a.notes.first { Int($0.pitch.rounded()) == 64 })
    let out = try #require(a.render(source, edit: NoteEdit(source: AssetID(), changes: [NoteChange(key: e.key, gainDb: 0.0001)])))
    var error = 0.0, signal = 0.0
    for i in 0..<source.frames {
        let s = Double(source.channel(0)[i]), d = Double(out.channel(0)[i]) - s
        error += d * d; signal += s * s
    }
    #expect(sqrt(error / signal) < 0.005)
}

/// The analysis as a file: read back, it holds the same notes and renders the same sound. Another version or a
/// cut file reads as nothing, so the notes are found again.
@Test func theAnalysisFileGivesTheSameNotesBack() throws {
    let pcm = chord([60, 64, 67])
    let a = NoteAnalysis.analyze(pcm)
    let data = a.fileData()
    let b = try #require(NoteAnalysis.read(data))
    #expect(b.notes == a.notes && b.frames == a.frames && b.hop == a.hop && b.channels == a.channels)
    let e3 = try #require(a.notes.first { Int($0.pitch.rounded()) == 64 })
    let edit = NoteEdit(source: AssetID(), changes: [NoteChange(key: e3.key, pitch: 1)])
    let x = try #require(a.render(pcm, edit: edit)), y = try #require(b.render(pcm, edit: edit))
    #expect(x.frames == y.frames && (0..<x.frames).allSatisfy { x.channel(0)[$0] == y.channel(0)[$0] })
    #expect(NoteAnalysis.read(data.prefix(data.count - 3)) == nil)
    var other = data
    other[4] = 99 // the version
    #expect(NoteAnalysis.read(other) == nil)
}

/// A copy of the third, a fourth up: the file then holds C, E, G and the copy's A, and the third stays.
/// Removed again, the edit is empty and renders nothing.
@Test func aCopySoundsItsNoteOnceMore() throws {
    let source = chord([60, 64, 67])
    let a = NoteAnalysis.analyze(source)
    let e = try #require(a.notes.first { Int($0.pitch.rounded()) == 64 })
    var edit = NoteEdit(source: AssetID()).adding(copyOf: e.key, shift: 0, newKey: "copy-a")
    var moved = edit.current("copy-a")
    moved.pitch = 5
    edit = edit.with(moved)
    #expect(a.items(edit).map(\.key).last == "copy-a")
    let out = try #require(a.render(source, edit: edit))
    #expect(pitches(NoteAnalysis.analyze(out)) == [60, 64, 67, 69])
    // Reset puts the copy back where it was made: on the third, no pitch change.
    #expect(edit.reset("copy-a").current("copy-a").pitch == 0)
    #expect(edit.removing(copy: "copy-a").isEmpty)
    #expect(a.render(source, edit: edit.removing(copy: "copy-a")) == nil)
}
