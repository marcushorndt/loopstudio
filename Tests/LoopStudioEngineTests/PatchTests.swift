import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioEngine

private let rate = 48_000.0

/// Compiles a patch and runs it over a mono signal (both channels the same), in blocks of 256.
private func run(_ source: String, _ params: [String: Double] = [:], _ input: [Float], block: Int = 256,
                 quarterSeconds: Double = 0.5, dsp existing: PatchDSP? = nil) throws -> (out: [Float], dsp: PatchDSP) {
    let program = try PatchCompiler.compile(source)
    let dsp = existing ?? PatchDSP(program: program, sampleRate: rate)
    dsp.configure(params)
    var l = input, r = input
    var done = 0
    while done < input.count {
        let n = min(block, input.count - done)
        dsp.clock(frame: Int64(done), beat: Double(done) / (quarterSeconds * rate), quarterSeconds: quarterSeconds)
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            dsp.process(lp.baseAddress! + done, rp.baseAddress! + done, frames: n)
        } }
        done += n
    }
    return (l, dsp)
}

@Test func aPatchIsArithmeticOnTheInput() throws {
    let src = """
    patch "Half"
    param level 0..1 = 0.5
    in x
    out y
    y = x * level + 0.25 * 0
    """
    let input: [Float] = (0..<1000).map { Float($0 % 7) / 7 }
    let (out, _) = try run(src, [:], input)
    for i in 0..<1000 { #expect(abs(out[i] - input[i] * 0.5) < 1e-6) }
    let (loud, _) = try run(src, ["level": 1], input)
    #expect(loud[500] == input[500])
}

@Test func theKnobsComeFromTheParamLines() throws {
    let program = try PatchCompiler.compile(PatchExamples.stutterFilter)
    #expect(program.name == "Stutter Filter")
    #expect(program.spec.params.map(\.key) == ["cutoff", "res", "rate", "depth", "feedback"])
    let cutoff = program.spec.param("cutoff")!
    #expect(cutoff.min == 20 && cutoff.max == 20000 && cutoff.def == 1200 && cutoff.logarithmic && cutoff.unit == "Hz")
    let rateParam = program.spec.param("rate")!
    #expect(rateParam.choices == NoteDivision.all.map(\.name))
    #expect(NoteDivision.at(rateParam.def).name == "1/16")
    #expect(program.buffers.map(\.name) == ["line"])
    #expect(program.spec.view == "patch")
}

@Test func everyExampleCompilesAndRendersFiniteSound() throws {
    let input: [Float] = (0..<24_000).map { Float(sin(Double($0) * 2 * .pi * 220 / rate)) * 0.5 }
    for example in PatchExamples.all {
        let (out, _) = try run(example.source, [:], input)
        #expect(out.allSatisfy { $0.isFinite }, "\(example.name)")
        #expect(out.map(abs).max()! > 0.001, "\(example.name) is silent")
        #expect(out.map(abs).max()! < 4, "\(example.name) is too loud")
    }
}

@Test func aDelayReadsBackWhatWasWrittenThatManySamplesAgo() throws {
    let src = """
    patch "Echo"
    in x
    out y
    delay line = 100 ms
    line.write(x)
    y = line.read(10 ms)
    """
    var input = [Float](repeating: 0, count: 2000)
    input[100] = 1
    let (out, _) = try run(src, [:], input)
    let hit = out.enumerated().max { abs($0.element) < abs($1.element) }!
    #expect(hit.offset == 100 + 480, "echo at \(hit.offset)")
    #expect(abs(hit.element - 1) < 1e-4)
}

@Test func aNewProgramKeepsTheDelayLineOfTheOldOne() throws {
    let a = """
    patch "A"
    in x
    out y
    delay line = 100 ms
    line.write(x)
    y = line.read(50 ms)
    """
    let b = """
    patch "B"
    in x
    out y
    delay line = 100 ms
    line.write(x * 0)
    y = line.read(50 ms) * 2
    """
    var input = [Float](repeating: 0, count: 1000)
    input[10] = 1
    let (_, old) = try run(a, [:], input)
    // The impulse sits in the line, 990 frames old. The new program reads it 2400 frames back: not yet.
    let fresh = PatchDSP(program: try PatchCompiler.compile(b), sampleRate: rate, carryingOver: old)
    let (out, _) = try run(b, [:], [Float](repeating: 0, count: 3000), dsp: fresh)
    let hit = out.enumerated().max { abs($0.element) < abs($1.element) }!
    #expect(hit.offset == 2400 - 990, "echo at \(hit.offset)")
    #expect(abs(hit.element - 2) < 1e-4)
}

@Test func prevGivesTheValueOfTheLastFrame() throws {
    let src = """
    patch "Integrator"
    in x
    out y
    y = x + prev(y) * 0.5
    """
    let (out, _) = try run(src, [:], [1, 0, 0, 0])
    #expect(out == [1, 0.5, 0.25, 0.125])
}

@Test func aNoteValueFollowsTheTempo() throws {
    // A square LFO over a 1/4 note: at 120 BPM a quarter is 24000 frames, high for the first half.
    let src = """
    patch "Gate"
    param rate note = 1/4
    in x
    out y
    y = lfo(rate, square)
    """
    let (out, _) = try run(src, [:], [Float](repeating: 0, count: 48_000))
    #expect(out[100] == 1 && out[11_000] == 1 && out[25_000] == 1)
    #expect(out[13_000] == 0 && out[23_000] == 0 && out[47_000] == 0)
    // At 60 BPM the same note is twice as long.
    let (slow, _) = try run(src, [:], [Float](repeating: 0, count: 96_000), quarterSeconds: 1)
    #expect(slow[23_000] == 1 && slow[25_000] == 0 && slow[49_000] == 1)
}

@Test func aLowPassLetsBassThroughAndStopsTreble() throws {
    let src = """
    patch "LP"
    param cutoff 20..20000 = 500 log "Hz"
    in x
    out y
    y = lp(x, cutoff, 0.2)
    """
    func level(_ hz: Double) throws -> Float {
        let input = (0..<48_000).map { Float(sin(Double($0) * 2 * .pi * hz / rate)) }
        let (out, _) = try run(src, [:], input)
        return out[24_000...].map(abs).max()!
    }
    #expect(try level(50) > 0.95)
    #expect(try level(8000) < 0.01)
}

@Test func theCompilerRejectsWhatCannotRun() {
    func error(_ src: String) -> String {
        do { _ = try PatchCompiler.compile(src); return "" } catch let e as PatchError { return "\(e)" } catch { return "\(error)" }
    }
    #expect(error("in x\nout y\ny = z * 2").contains("'z' is not defined"))
    #expect(error("in x\ny = x").contains("needs an output"))
    #expect(error("in x\nout y\nz = x").contains("'y' is never set"))
    #expect(error("param a 0..1 = 0.5\nin x\nout y\na = x\ny = x").contains("knob"))
    #expect(error("in x\nout y\ny = lp(x)").contains("2 to 3"))
    #expect(error("in x\nout y\ny = phase(0.25)").contains("note value"))
    #expect(error("in x\nout y\ny = x +").hasPrefix("line 3"))
    #expect(error("delay d = 2\nin x\nout y\ny = x").contains("time"))
}

@Test func aPatchRunsFastEnough() throws {
    // Fifty-odd ops per frame, one second of sound, in well under a tenth of real time.
    var lines = ["patch \"Busy\"", "param a 0..1 = 0.5", "in x", "out y", "delay line = 1 s", "v0 = x"]
    for i in 1...12 { lines.append("v\(i) = tanh(lp(v\(i - 1) * (1 + a), 2000 + \(i) * 100, 0.3)) + line.read(\(i) ms) * 0.1") }
    lines.append("line.write(v12)")
    lines.append("y = v12")
    let src = lines.joined(separator: "\n")
    let program = try PatchCompiler.compile(src)
    #expect(program.ops.count > 50)
    let input = (0..<48_000).map { Float(sin(Double($0) * 0.01)) }
    let start = Date()
    _ = try run(src, [:], input)
    let seconds = Date().timeIntervalSince(start)
    #expect(seconds < 0.1, "\(program.ops.count) ops per frame took \(seconds) s for one second of sound")
}

@Test func aPatchKnobIsSetThroughTheCommandLikeAnyKnob() throws {
    var project = Project(name: "P", sampleRate: 48_000)
    let track = Track(name: "A", kind: .audio)
    _ = try Command.insertTrack(track: track, index: 0).apply(to: &project)
    var slot = BuiltInEffects.makeSlot("patch")!
    slot.source = PatchExamples.tremolo
    _ = try Command.insertDevice(track: track.id, device: slot, index: nil).apply(to: &project)
    // The knob the text declares takes a value (clamped to its range); one the text does not declare is refused.
    _ = try Command.setDeviceParam(track: track.id, device: slot.id, key: "depth", value: 2).apply(to: &project)
    #expect(project.track(track.id)?.device(slot.id)?.params["depth"] == 1)
    #expect(throws: CommandError.self) { _ = try Command.setDeviceParam(track: track.id, device: slot.id, key: "cutoff", value: 1).apply(to: &project) }
    // The automation lanes of the track list the patch's knobs.
    let targets = project.automationTargets(of: project.track(track.id)!)
    #expect(targets.contains { $0.address.parameter == "rate" && $0.address.node == slot.id.rawValue })
}
