import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

/// Compiles a source (a text or a document) and runs it over a mono signal, in blocks of 256.
private func run(_ source: String, _ params: [String: Double] = [:], _ input: [Float], quarterSeconds: Double = 0.5,
                 dsp existing: PatchDSP? = nil) throws -> (out: [Float], dsp: PatchDSP) {
    let program = try PatchCompiler.compile(source)
    let dsp = existing ?? PatchDSP(program: program, sampleRate: rate)
    dsp.configure(params)
    var l = input, r = input
    var done = 0
    while done < input.count {
        let n = min(256, input.count - done)
        dsp.clock(frame: Int64(done), beat: Double(done) / (quarterSeconds * rate), quarterSeconds: quarterSeconds)
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            dsp.process(lp.baseAddress! + done, rp.baseAddress! + done, frames: n)
        } }
        done += n
    }
    return (l, dsp)
}

private func doc(_ edits: [PatchEdit], name: String = "Test") throws -> PatchDocument {
    var d = PatchDocument(name: name)
    for e in edits { try d.apply(e) }
    return d
}

@Test func aTextLoadsAsADocumentWithOneScriptAndSoundsTheSame() throws {
    let text = PatchExamples.tremolo
    let d = PatchDocument(text: text)
    #expect(d.modules.map(\.kind) == ["in", "script", "out"])
    #expect(PatchDocument.isDocument(d.source))
    let input: [Float] = (0..<4800).map { Float($0 % 13) / 13 }
    let (a, _) = try run(text, [:], input)
    let (b, dspB) = try run(d.source, [:], input)
    for i in stride(from: 0, to: 4800, by: 7) { #expect(abs(a[i] - b[i]) < 1e-6) }
    let textSpec = try PatchCompiler.compile(text).spec, docSpec = dspB.program.spec
    #expect(textSpec.params.map(\.key) == docSpec.params.map(\.key), "the knobs keep their keys: automation on them survives")
    #expect(docSpec.name == textSpec.name)
}

@Test func aGraphOfModulesRendersLikeTheEqualText() throws {
    // in → multiply by (1 - depth * lfo) → out, the tremolo from modules.
    let d = try doc([
        .add(kind: "in", id: "in", x: 0, y: 0), .add(kind: "out", id: "out", x: 400, y: 0),
        .add(kind: "lfosync", id: "lfo", x: 100, y: 100), .add(kind: "mul", id: "depth", x: 200, y: 100),
        .add(kind: "sub", id: "inv", x: 300, y: 100), .add(kind: "mul", id: "vca", x: 350, y: 0),
        .setValue(id: "lfo", key: "rate", value: Double(NoteDivision.index("1/4"))),
        .setSetting(id: "lfo", key: "shape", value: "square"),
        .setValue(id: "depth", key: "b", value: 0.5), .setValue(id: "inv", key: "a", value: 1),
        .connect(from: "lfo", fromPort: "out", to: "depth", toPort: "a"),
        .connect(from: "depth", fromPort: "out", to: "inv", toPort: "b"),
        .connect(from: "in", fromPort: "out", to: "vca", toPort: "a"),
        .connect(from: "inv", fromPort: "out", to: "vca", toPort: "b"),
        .connect(from: "vca", fromPort: "out", to: "out", toPort: "in"),
    ])
    let text = """
    patch "T"
    in x
    out y
    y = x * (1 - 0.5 * lfo(1/4, square))
    """
    let input: [Float] = (0..<48_000).map { _ in 0.5 }
    let (a, _) = try run(text, [:], input)
    let (b, _) = try run(d.source, [:], input)
    for i in stride(from: 0, to: 48_000, by: 97) { #expect(abs(a[i] - b[i]) < 1e-6) }
    #expect(b[1000] == 0.25 && b[15_000] == 0.5, "half in the first half of the quarter note, full in the second")
}

@Test func aKnobOnThePanelIsAParameterOfTheDevice() throws {
    let d = try doc([
        .add(kind: "in", id: "in", x: 0, y: 0), .add(kind: "out", id: "out", x: 400, y: 0),
        .add(kind: "knob", id: "level", x: 100, y: 100), .setValue(id: "level", key: "def", value: 0.25),
        .add(kind: "mul", id: "vca", x: 200, y: 0),
        .connect(from: "in", fromPort: "out", to: "vca", toPort: "a"),
        .connect(from: "level", fromPort: "out", to: "vca", toPort: "b"),
        .connect(from: "vca", fromPort: "out", to: "out", toPort: "in"),
    ])
    let program = try PatchCompiler.compile(d.source)
    #expect(program.spec.params.map(\.key) == ["level"])
    #expect(program.spec.groups.map(\.title) == ["level"], "a knob is a group of its own on the panel")
    let input: [Float] = (0..<256).map { _ in 1 }
    let (quiet, _) = try run(d.source, ["level": 0.25], input)
    #expect(abs(quiet[100] - 0.25) < 1e-6)
    let (loud, _) = try run(d.source, ["level": 1], input)
    #expect(loud[100] == 1)
}

@Test func anExposedModuleShowsItsFreeInputsAsKnobs() throws {
    var d = try doc([
        .add(kind: "in", id: "in", x: 0, y: 0), .add(kind: "out", id: "out", x: 400, y: 0),
        .add(kind: "lp", id: "filter", x: 200, y: 0),
        .connect(from: "in", fromPort: "out", to: "filter", toPort: "in"),
        .connect(from: "filter", fromPort: "out", to: "out", toPort: "in"),
    ])
    #expect(try PatchCompiler.compile(d.source).spec.params.isEmpty, "not on the panel: fixed values, no knobs")
    try d.apply(.expose(id: "filter", on: true))
    let spec = try PatchCompiler.compile(d.source).spec
    #expect(spec.params.map(\.key) == ["filter.cutoff", "filter.q"], "the input with a cable is no knob")
    #expect(spec.groups.first?.title == "Low-pass")
}

@Test func aFeedbackCableGetsOneFrameOfDelay() throws {
    // out = in + 0.5 * out(previous frame): an impulse decays by halves.
    let d = try doc([
        .add(kind: "in", id: "in", x: 0, y: 0), .add(kind: "out", id: "out", x: 400, y: 0),
        .add(kind: "add", id: "sum", x: 100, y: 0), .add(kind: "mul", id: "fb", x: 200, y: 100),
        .setValue(id: "fb", key: "b", value: 0.5),
        .connect(from: "in", fromPort: "out", to: "sum", toPort: "a"),
        .connect(from: "sum", fromPort: "out", to: "fb", toPort: "a"),
        .connect(from: "fb", fromPort: "out", to: "sum", toPort: "b"),
        .connect(from: "sum", fromPort: "out", to: "out", toPort: "in"),
    ])
    var input = [Float](repeating: 0, count: 64); input[0] = 1
    let (out, dsp) = try run(d.source, [:], input)
    #expect(dsp.program.latches.count == 1, "one feedback cable, one latch")
    #expect(out[0] == 1 && out[1] == 0.5 && out[2] == 0.25 && abs(out[3] - 0.125) < 1e-6)
}

@Test func aMovedModuleKeepsItsDelayLine() throws {
    var d = try doc([
        .add(kind: "in", id: "in", x: 0, y: 0), .add(kind: "out", id: "out", x: 400, y: 0),
        .add(kind: "delay", id: "echo", x: 200, y: 0), .setValue(id: "echo", key: "time", value: 10), .setValue(id: "echo", key: "feedback", value: 0),
        .connect(from: "in", fromPort: "out", to: "echo", toPort: "in"),
        .connect(from: "echo", fromPort: "out", to: "out", toPort: "in"),
    ])
    var input = [Float](repeating: 0, count: 1024); input[0] = 1
    let (first, old) = try run(d.source, [:], input)
    #expect(first[480] == 1, "10 ms is 480 frames")
    try d.apply(.move(id: "echo", x: 250, y: 40))
    let program = try PatchCompiler.compile(d.source)
    let moved = PatchDSP(program: program, sampleRate: rate, carryingOver: old)
    let (second, _) = try run(d.source, [:], [Float](repeating: 0, count: 1024), dsp: moved)
    #expect(second.allSatisfy { $0 == 0 }, "the line was fully read in the first second: no new echo")
    #expect(moved.lineContents("echo", channel: 0).count == old.lineContents("echo", channel: 0).count)
}

@Test func theGraphRefusesWhatCannotRun() throws {
    var d = try doc([.add(kind: "in", id: "in", x: 0, y: 0), .add(kind: "knob", id: "k", x: 0, y: 0), .add(kind: "meter", id: "m", x: 0, y: 0)])
    #expect(throws: PatchEditError.self, "audio does not go into a control input") {
        try d.apply(.connect(from: "in", fromPort: "out", to: "k", toPort: "out"))
    }
    #expect(throws: PatchEditError.self, "no such port") {
        try d.apply(.connect(from: "in", fromPort: "out", to: "m", toPort: "level"))
    }
    #expect(throws: PatchEditError.self, "one Audio In per patch") {
        try d.apply(.add(kind: "in", id: "in2", x: 0, y: 0))
    }
    #expect(throws: PatchError.self, "no output module") {
        try PatchCompiler.compile(d.source)
    }
    try d.apply(.add(kind: "script", id: "s", x: 0, y: 0))
    try d.apply(.setSource(id: "s", source: "patch \"Bad\"\nin x\nout y\ny = nothing"))
    try d.apply(.add(kind: "out", id: "out", x: 0, y: 0))
    #expect {
        try PatchCompiler.compile(d.source)
    } throws: { error in
        let e = error as? PatchError
        return e?.module == "s" && e?.line == 4
    }
}

@Test func aScriptModuleTakesItsParamsFromCablesOrKnobs() throws {
    var d = try doc([
        .add(kind: "in", id: "in", x: 0, y: 0), .add(kind: "out", id: "out", x: 400, y: 0),
        .add(kind: "script", id: "s", x: 200, y: 0),
        .setSource(id: "s", source: "patch \"Gain\"\nparam level 0..2 = 1\nin x\nout y\ny = x * level"),
        .add(kind: "const", id: "two", x: 100, y: 100), .setValue(id: "two", key: "value", value: 2),
        .connect(from: "in", fromPort: "out", to: "s", toPort: "x"),
        .connect(from: "s", fromPort: "y", to: "out", toPort: "in"),
    ])
    let input: [Float] = (0..<256).map { _ in 0.5 }
    let knob = try PatchCompiler.compile(d.source)
    #expect(knob.spec.params.map(\.key) == ["level"], "the script is on the panel: its param is a knob, with its own name")
    let (byKnob, _) = try run(d.source, ["level": 2], input)
    #expect(byKnob[10] == 1)
    try d.apply(.connect(from: "two", fromPort: "out", to: "s", toPort: "level"))
    let wired = try PatchCompiler.compile(d.source)
    #expect(wired.spec.params.isEmpty, "a cable into the param: no knob")
    let (byCable, _) = try run(d.source, [:], input)
    #expect(byCable[10] == 1)
}

@Test func aCounterStepsARouterAndASelectorPicksAnInput() throws {
    // A square LFO (1/4) triggers a Counter of 4 steps that picks the Router's output.
    // Output c (step 2) goes to Audio Out: silence, silence, the input, silence, in each quarter note.
    let d = try doc([
        .add(kind: "in", id: "in", x: 0, y: 0), .add(kind: "out", id: "out", x: 500, y: 0),
        .add(kind: "lfosync", id: "clock", x: 100, y: 100), .setSetting(id: "clock", key: "shape", value: "square"),
        .setValue(id: "clock", key: "rate", value: Double(NoteDivision.index("1/4"))),
        .add(kind: "counter", id: "step", x: 200, y: 100),
        .add(kind: "router", id: "route", x: 300, y: 0),
        .connect(from: "clock", fromPort: "out", to: "step", toPort: "trigger"),
        .connect(from: "step", fromPort: "out", to: "route", toPort: "to"),
        .connect(from: "in", fromPort: "out", to: "route", toPort: "in"),
        .connect(from: "route", fromPort: "c", to: "out", toPort: "in"),
    ])
    let quarter = 24_000 // frames at 0.5 s per quarter note
    let input = [Float](repeating: 1, count: quarter * 6)
    let (out, _) = try run(d.source, [:], input)
    // The square is high from the start of each quarter note: the count goes 1, 2, 3, 0, 1, 2 over the
    // six quarters. Output c is open while the count is 2: the second and the sixth quarter.
    let open = (0..<6).map { q in out[q * quarter + quarter / 4] }
    #expect(open == [0, 1, 0, 0, 0, 1], "every fourth quarter note from the second passes")

    // A Selector with a constant pick of 1 takes input b.
    let s = try doc([
        .add(kind: "in", id: "in", x: 0, y: 0), .add(kind: "out", id: "out", x: 500, y: 0),
        .add(kind: "const", id: "two", x: 0, y: 100), .setValue(id: "two", key: "value", value: 2),
        .add(kind: "selector", id: "pick", x: 300, y: 0), .setValue(id: "pick", key: "from", value: 1),
        .connect(from: "in", fromPort: "out", to: "pick", toPort: "a"),
        .connect(from: "two", fromPort: "out", to: "pick", toPort: "b"),
        .connect(from: "pick", fromPort: "out", to: "out", toPort: "in"),
    ])
    let (picked, _) = try run(s.source, [:], [Float](repeating: 1, count: 256))
    #expect(picked[10] == 2, "b is the constant 2")
    let (text, _) = try run("patch \"C\"\nin x\nout y\ny = count(lfo(1/4, square), 3)", [:], input)
    #expect(text[quarter / 2] == 1 && text[quarter + quarter / 2] == 2 && text[3 * quarter + quarter / 2] == 1, "the text has count() too")
}
