import Foundation
import LoopStudioCore

/// Runs a `PatchProgram`: the op list once per frame over stereo slots, with the state and the delay
/// lines allocated here, once, at the sample rate. `process` allocates nothing. A changed program gets a
/// new instance (the renderer keeps an instance only while the program is the same object); the new one
/// takes the delay lines of the old by name, so an edit does not cut an echo.
public final class PatchDSP: DSPEffect, @unchecked Sendable {
    public let program: PatchProgram
    private let ops: UnsafeMutablePointer<PatchOp>
    private let opCount: Int
    private let slots: UnsafeMutablePointer<Float>
    private let state: UnsafeMutablePointer<Float>
    private let stateCount: Int
    private let latches: [PatchLatch]
    private let meterSlots: [(slot: Int, index: Int)]
    private let outSlot: Int
    private var noiseWord: UInt32 = 0x2545_F491
    private var beatPerFrame: Float = 0

    /// One delay line: `length` frames of stereo, interleaved, and the record head.
    final class Line: @unchecked Sendable {
        let name: String
        let length: Int
        let data: UnsafeMutablePointer<Float>
        var head = 0
        init(name: String, length: Int) {
            self.name = name
            self.length = length
            data = .allocate(capacity: length * 2)
            data.initialize(repeating: 0, count: length * 2)
        }
        deinit { data.deallocate() }
    }
    private let lines: [Line]
    private let divisions: [Float] = NoteDivision.all.map { Float($0.quarters) }

    public init(program: PatchProgram, sampleRate: Double, carryingOver old: PatchDSP? = nil) {
        self.program = program
        opCount = program.ops.count
        ops = .allocate(capacity: max(1, opCount))
        for (i, op) in program.ops.enumerated() { (ops + i).initialize(to: op) }
        slots = .allocate(capacity: program.slotCount * 2)
        slots.initialize(repeating: 0, count: program.slotCount * 2)
        stateCount = max(1, program.stateCount)
        state = .allocate(capacity: stateCount)
        state.initialize(repeating: 0, count: stateCount)
        latches = program.latches
        meterSlots = program.meters
        outSlot = program.outSlot
        lines = program.buffers.map { b in
            let line = Line(name: b.name, length: max(4, Int(b.seconds * sampleRate) + 2))
            // The same delay in the old program: its sound carries over, so the edit does not cut an echo.
            if let twin = old?.lines.first(where: { $0.name == b.name && $0.length == line.length }) {
                line.data.update(from: twin.data, count: line.length * 2)
                line.head = twin.head
            }
            return line
        }
        super.init(spec: program.spec, sampleRate: sampleRate)
        slots[PatchProgram.sampleRateSlot * 2] = Float(sampleRate)
        slots[PatchProgram.sampleRateSlot * 2 + 1] = Float(sampleRate)
        slots[PatchProgram.tempoSlot * 2] = 120; slots[PatchProgram.tempoSlot * 2 + 1] = 120
        slots[PatchProgram.quarterSecondsSlot * 2] = 0.5; slots[PatchProgram.quarterSecondsSlot * 2 + 1] = 0.5
        beatPerFrame = Float(1 / (0.5 * sampleRate))
        followsTempo = true
        configure([:])
    }

    deinit {
        ops.deallocate()
        slots.deallocate()
        state.deallocate()
    }

    /// The sound a delay line holds now, for tests and the display: channel 0 or 1, oldest first.
    public func lineContents(_ name: String, channel: Int = 0) -> [Float] {
        guard let line = lines.first(where: { $0.name == name }) else { return [] }
        return (0..<line.length).map { line.data[((line.head + $0) % line.length) * 2 + channel] }
    }

    public override func configure(_ p: [String: Double]) {
        for ps in program.params {
            guard let param = spec.param(ps.key) else { continue }
            var v = Float(param.clamp(p[ps.key] ?? param.def))
            if ps.isNote { v = divisions[min(max(0, Int(v.rounded())), divisions.count - 1)] }
            slots[ps.slot * 2] = v
            slots[ps.slot * 2 + 1] = v
        }
    }

    public override func reset() {
        state.update(repeating: 0, count: stateCount)
        for line in lines { line.data.update(repeating: 0, count: line.length * 2); line.head = 0 }
    }

    override func tempoChanged() {
        let q = Float(quarterSeconds)
        slots[PatchProgram.quarterSecondsSlot * 2] = q
        slots[PatchProgram.quarterSecondsSlot * 2 + 1] = q
        let bpm = Float(60 / quarterSeconds)
        slots[PatchProgram.tempoSlot * 2] = bpm
        slots[PatchProgram.tempoSlot * 2 + 1] = bpm
        beatPerFrame = Float(1 / (quarterSeconds * sampleRate))
    }

    override func step(frame: Int64, beat: Double) {
        let b = Float(beat)
        slots[PatchProgram.beatSlot * 2] = b
        slots[PatchProgram.beatSlot * 2 + 1] = b
        let bar = Float((beat - barStart) / max(barBeats, 0.001))
        slots[PatchProgram.barSlot * 2] = bar
        slots[PatchProgram.barSlot * 2 + 1] = bar
    }

    public override func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        let slots = slots, state = state, ops = ops, opCount = opCount
        let sr = Float(sampleRate)
        var peaks = (Float(0), Float(0), Float(0), Float(0))
        for f in 0..<frames {
            slots[0] = l[f]
            slots[1] = r[f]
            for i in 0..<opCount {
                let op = ops[i]
                let o = Int(op.out) * 2, a = Int(op.a) * 2, b = Int(op.b) * 2, c = Int(op.c) * 2
                switch op.code {
                case .const: slots[o] = op.k; slots[o + 1] = op.k
                case .add: slots[o] = slots[a] + slots[b]; slots[o + 1] = slots[a + 1] + slots[b + 1]
                case .sub: slots[o] = slots[a] - slots[b]; slots[o + 1] = slots[a + 1] - slots[b + 1]
                case .mul: slots[o] = slots[a] * slots[b]; slots[o + 1] = slots[a + 1] * slots[b + 1]
                case .div: slots[o] = safeDiv(slots[a], slots[b]); slots[o + 1] = safeDiv(slots[a + 1], slots[b + 1])
                case .pow: slots[o] = powf(slots[a], slots[b]); slots[o + 1] = powf(slots[a + 1], slots[b + 1])
                case .min: slots[o] = min(slots[a], slots[b]); slots[o + 1] = min(slots[a + 1], slots[b + 1])
                case .max: slots[o] = max(slots[a], slots[b]); slots[o + 1] = max(slots[a + 1], slots[b + 1])
                case .gt: slots[o] = slots[a] > slots[b] ? 1 : 0; slots[o + 1] = slots[a + 1] > slots[b + 1] ? 1 : 0
                case .lt: slots[o] = slots[a] < slots[b] ? 1 : 0; slots[o + 1] = slots[a + 1] < slots[b + 1] ? 1 : 0
                case .ge: slots[o] = slots[a] >= slots[b] ? 1 : 0; slots[o + 1] = slots[a + 1] >= slots[b + 1] ? 1 : 0
                case .le: slots[o] = slots[a] <= slots[b] ? 1 : 0; slots[o + 1] = slots[a + 1] <= slots[b + 1] ? 1 : 0
                case .eq: slots[o] = slots[a] == slots[b] ? 1 : 0; slots[o + 1] = slots[a + 1] == slots[b + 1] ? 1 : 0
                case .neg: slots[o] = -slots[a]; slots[o + 1] = -slots[a + 1]
                case .abs: slots[o] = abs(slots[a]); slots[o + 1] = abs(slots[a + 1])
                case .sqrt: slots[o] = sqrtf(max(0, slots[a])); slots[o + 1] = sqrtf(max(0, slots[a + 1]))
                case .sin: slots[o] = sinf(slots[a]); slots[o + 1] = sinf(slots[a + 1])
                case .cos: slots[o] = cosf(slots[a]); slots[o + 1] = cosf(slots[a + 1])
                case .exp: slots[o] = expf(min(slots[a], 80)); slots[o + 1] = expf(min(slots[a + 1], 80))
                case .log: slots[o] = logf(max(slots[a], 1e-20)); slots[o + 1] = logf(max(slots[a + 1], 1e-20))
                case .floor: slots[o] = floorf(slots[a]); slots[o + 1] = floorf(slots[a + 1])
                case .tanh: slots[o] = tanhf(slots[a]); slots[o + 1] = tanhf(slots[a + 1])
                case .dbToGain: slots[o] = powf(10, slots[a] / 20); slots[o + 1] = powf(10, slots[a + 1] / 20)
                case .clip:
                    slots[o] = min(max(slots[a], slots[b]), slots[c]); slots[o + 1] = min(max(slots[a + 1], slots[b + 1]), slots[c + 1])
                case .mix:
                    slots[o] = slots[a] + (slots[b] - slots[a]) * slots[c]
                    slots[o + 1] = slots[a + 1] + (slots[b + 1] - slots[a + 1]) * slots[c + 1]
                case .recip: slots[o] = safeDiv(1, slots[a]); slots[o + 1] = safeDiv(1, slots[a + 1])
                case .noteAt:
                    let i = min(max(0, Int(slots[a].rounded())), divisions.count - 1)
                    slots[o] = divisions[i]; slots[o + 1] = divisions[i]
                case .osc, .lfo:
                    // b (optional): the offset of the cycle, 0…1. The phase itself keeps running unshifted,
                    // so an offset that moves does not change the rate.
                    let s = Int(op.state)
                    let unipolar = op.code == .lfo
                    for ch in 0..<2 {
                        var phase = state[s + ch] + slots[a + ch] / sr
                        phase -= floorf(phase)
                        state[s + ch] = phase
                        if b >= 0 { phase += slots[b + ch]; phase -= floorf(phase) }
                        slots[o + ch] = wave(phase, op.k, unipolar: unipolar)
                    }
                case .lfoSync:
                    for ch in 0..<2 {
                        let q = max(slots[a + ch], 1e-6)
                        var phase = slots[PatchProgram.beatSlot * 2 + ch] / q
                        if b >= 0 { phase += slots[b + ch] }
                        phase -= floorf(phase)
                        slots[o + ch] = wave(phase, op.k, unipolar: true)
                    }
                case .phase:
                    for ch in 0..<2 {
                        let q = max(slots[a + ch], 1e-6)
                        var phase = slots[PatchProgram.beatSlot * 2 + ch] / q
                        if b >= 0 { phase += slots[b + ch] }
                        phase -= floorf(phase)
                        slots[o + ch] = phase
                    }
                case .svf:
                    // Andrew Simper's trapezoidal SVF. The coefficient is kept until the cutoff moves.
                    let s = Int(op.state)
                    let cut = min(max(slots[b], 5), sr * 0.49)
                    if cut != state[s + 4] { state[s + 4] = cut; state[s + 5] = tanf(Float.pi * cut / sr) }
                    let g = state[s + 5]
                    let k = 2 - 1.95 * min(max(slots[c], 0), 1)
                    let a1 = 1 / (1 + g * (g + k)), a2 = g * a1, a3 = g * a2
                    for ch in 0..<2 {
                        let v0 = slots[a + ch]
                        let ic1 = state[s + ch * 2], ic2 = state[s + ch * 2 + 1]
                        let v3 = v0 - ic2
                        let v1 = a1 * ic1 + a2 * v3
                        let v2 = ic2 + a2 * ic1 + a3 * v3
                        state[s + ch * 2] = 2 * v1 - ic1
                        state[s + ch * 2 + 1] = 2 * v2 - ic2
                        slots[o + ch] = op.k == 0 ? v2 : (op.k == 1 ? v0 - k * v1 - v2 : v1)
                    }
                case .slew:
                    let s = Int(op.state)
                    for ch in 0..<2 {
                        let target = slots[a + ch], cur = state[s + ch]
                        let up = max(slots[b + ch], 0) * sr, down = max(slots[c + ch], 0) * sr
                        let maxUp: Float = up < 1 ? .infinity : 1 / up
                        let maxDown: Float = down < 1 ? .infinity : 1 / down
                        let next = target > cur ? min(target, cur + maxUp) : max(target, cur - maxDown)
                        state[s + ch] = next
                        slots[o + ch] = next
                    }
                case .follow:
                    let s = Int(op.state)
                    let at = max(slots[b], 0), rt = max(slots[c], 0)
                    if at != state[s + 2] { state[s + 2] = at; state[s + 3] = at * sr < 1 ? 0 : expf(-1 / (at * sr)) }
                    if rt != state[s + 4] { state[s + 4] = rt; state[s + 5] = rt * sr < 1 ? 0 : expf(-1 / (rt * sr)) }
                    for ch in 0..<2 {
                        let x = abs(slots[a + ch]), env = state[s + ch]
                        let coef = x > env ? state[s + 3] : state[s + 5]
                        let next = x + (env - x) * coef
                        state[s + ch] = next
                        slots[o + ch] = next
                    }
                case .prev:
                    let s = Int(op.state)
                    slots[o] = state[s]; slots[o + 1] = state[s + 1]
                case .noise:
                    var w = noiseWord
                    w ^= w << 13; w ^= w >> 17; w ^= w << 5
                    noiseWord = w
                    let v = Float(w) / Float(UInt32.max) * 2 - 1
                    slots[o] = v; slots[o + 1] = v
                case .sah:
                    let s = Int(op.state)
                    for ch in 0..<2 {
                        let trig = slots[b + ch]
                        if trig > 0.5, state[s + 2 + ch] <= 0.5 { state[s + ch] = slots[a + ch] }
                        state[s + 2 + ch] = trig
                        slots[o + ch] = state[s + ch]
                    }
                case .count:
                    // state: the count per channel, then the last trigger per channel
                    let s = Int(op.state)
                    for ch in 0..<2 {
                        let trig = slots[a + ch]
                        let steps = max(1, floorf(slots[b + ch] + 0.5))
                        if slots[c + ch] > 0.5 {
                            state[s + ch] = 0
                        } else if trig > 0.5, state[s + 2 + ch] <= 0.5 {
                            state[s + ch] += 1
                        }
                        if state[s + ch] >= steps { state[s + ch] = 0 }
                        state[s + 2 + ch] = trig
                        slots[o + ch] = state[s + ch]
                    }
                case .delayRead:
                    let line = lines[Int(op.buffer)]
                    let len = line.length
                    for ch in 0..<2 {
                        let back = min(max(slots[a + ch] * sr, 1), Float(len - 2))
                        let whole = Int(back)
                        let frac = back - Float(whole)
                        let i0 = (line.head - whole + len * 2) % len
                        let i1 = (i0 - 1 + len) % len
                        let s0 = line.data[i0 * 2 + ch], s1 = line.data[i1 * 2 + ch]
                        slots[o + ch] = s0 + (s1 - s0) * frac
                    }
                case .delayWrite:
                    let line = lines[Int(op.buffer)]
                    line.data[line.head * 2] = slots[a]
                    line.data[line.head * 2 + 1] = slots[a + 1]
                case .output:
                    break
                }
            }
            for latch in latches {
                state[latch.state] = slots[latch.slot * 2]
                state[latch.state + 1] = slots[latch.slot * 2 + 1]
            }
            for line in lines { line.head = (line.head + 1) % line.length }
            slots[PatchProgram.beatSlot * 2] += beatPerFrame
            slots[PatchProgram.beatSlot * 2 + 1] += beatPerFrame
            l[f] = slots[outSlot * 2]
            r[f] = slots[outSlot * 2 + 1]
            for (n, m) in meterSlots.enumerated() where n < 4 {
                let v = max(abs(slots[m.slot * 2]), abs(slots[m.slot * 2 + 1]))
                switch n {
                case 0: peaks.0 = max(peaks.0, v)
                case 1: peaks.1 = max(peaks.1, v)
                case 2: peaks.2 = max(peaks.2, v)
                default: peaks.3 = max(peaks.3, v)
                }
            }
        }
        for (n, m) in meterSlots.enumerated() where n < 4 {
            meters[m.index] = n == 0 ? peaks.0 : (n == 1 ? peaks.1 : (n == 2 ? peaks.2 : peaks.3))
        }
    }

    @inline(__always) private func safeDiv(_ a: Float, _ b: Float) -> Float { abs(b) < 1e-20 ? 0 : a / b }

    @inline(__always) private func wave(_ phase: Float, _ shape: Float, unipolar: Bool) -> Float {
        let v: Float
        switch shape {
        case 1: v = 2 * phase - 1
        case 2: v = phase < 0.5 ? 1 : -1
        case 3: v = phase < 0.5 ? 4 * phase - 1 : 3 - 4 * phase
        default: v = sinf(2 * .pi * phase)
        }
        return unipolar ? (v + 1) * 0.5 : v
    }
}
