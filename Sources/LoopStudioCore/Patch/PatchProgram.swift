import Foundation

/// The program a patch compiles to: a list of ops in order, run once per frame by `PatchDSP` in the engine.
/// Every value is a stereo pair; a mono value carries the same number in both channels. The ops read and
/// write numbered slots. Slots persist across frames, so a parameter written once stays until the next
/// `configure`. The design and the language are in `docs/scripting.md`.
public final class PatchProgram: @unchecked Sendable {
    /// The name from the `patch "…"` line, or "Patch".
    public let name: String
    /// The knobs and the view of the device, derived from the `param` lines.
    public let spec: EffectSpec
    public let ops: [PatchOp]
    /// Stereo value slots the ops use (two floats each).
    public let slotCount: Int
    /// Floats of state the ops keep between frames (filter memories, phases, latches).
    public let stateCount: Int
    /// Delay lines and buffers, allocated by the runtime at its sample rate.
    public let buffers: [PatchBuffer]
    /// Where `configure` writes each knob: the slot, and how the stored value becomes the slot's value.
    public let params: [PatchParamSlot]
    /// `prev(name)`: at the end of a frame, the slot's value goes into the state the `prev` op reads.
    public let latches: [PatchLatch]
    /// `meter name`: the slot shown in `DSPEffect.meters[index]`.
    public let meters: [(slot: Int, index: Int)]
    /// The text it was compiled from.
    public let source: String

    public static let inSlot = 0
    public static let beatSlot = 1
    public static let barSlot = 2
    public static let tempoSlot = 3
    public static let quarterSecondsSlot = 4
    public static let sampleRateSlot = 5
    public static let zeroSlot = 6
    public static let reservedSlots = 7

    init(name: String, spec: EffectSpec, ops: [PatchOp], slotCount: Int, stateCount: Int, buffers: [PatchBuffer],
         params: [PatchParamSlot], latches: [PatchLatch], meters: [(slot: Int, index: Int)], source: String) {
        self.name = name
        self.spec = spec
        self.ops = ops
        self.slotCount = slotCount
        self.stateCount = stateCount
        self.buffers = buffers
        self.params = params
        self.latches = latches
        self.meters = meters
        self.source = source
    }

    /// The slot the output is read from: the last op's output of the `out` name.
    public var outSlot: Int { ops.last { $0.code == .output }?.a.int ?? PatchProgram.zeroSlot }
}

public struct PatchBuffer: Sendable, Hashable {
    public var name: String
    /// Length in seconds; the runtime turns it into frames at its sample rate.
    public var seconds: Double
}

public struct PatchParamSlot: Sendable, Hashable {
    public var key: String
    public var slot: Int
    /// The stored value is a note value index; the slot takes its length in quarter notes.
    public var isNote: Bool
}

public struct PatchLatch: Sendable, Hashable {
    public var slot: Int
    public var state: Int
}

/// One instruction. `out`, `a`, `b`, `c` are slots; `k` a constant; `state` an index into the state
/// floats; `buffer` an index into the buffers. Which fields matter depends on the code.
public struct PatchOp: Sendable, Hashable {
    public var code: PatchOpCode
    public var out: Int32 = -1
    public var a: Int32 = -1
    public var b: Int32 = -1
    public var c: Int32 = -1
    public var k: Float = 0
    public var state: Int32 = -1
    public var buffer: Int32 = -1

    public init(_ code: PatchOpCode, out: Int = -1, a: Int = -1, b: Int = -1, c: Int = -1, k: Float = 0, state: Int = -1, buffer: Int = -1) {
        self.code = code
        self.out = Int32(out); self.a = Int32(a); self.b = Int32(b); self.c = Int32(c)
        self.k = k
        self.state = Int32(state); self.buffer = Int32(buffer)
    }
}

public extension Int32 { var int: Int { Int(self) } }

public enum PatchOpCode: UInt8, Sendable {
    /// out = k
    case const
    /// out = a (op) b
    case add, sub, mul, div, pow, min, max, gt, lt, ge, le, eq
    /// out = f(a)
    case neg, abs, sqrt, sin, cos, exp, log, floor, tanh, dbToGain
    /// out = clamp(a, b, c)
    case clip
    /// out = a + (b - a) * c
    case mix
    /// out = 1 / a
    case recip
    /// out = quarters of the note value at index a (a knob with note choices)
    case noteAt
    /// out = oscillator at a Hz, shape k (0 sine, 1 saw, 2 square, 3 triangle), -1…1; state: the phase per channel
    case osc
    /// out = low-frequency oscillator at a Hz, shape k, 0…1; state: the phase per channel
    case lfo
    /// out = lfo locked to the song: a is the period in quarter notes, shape k, 0…1
    case lfoSync
    /// out = position inside the note value a (quarter notes), 0…1
    case phase
    /// out = state-variable filter of a at cutoff b Hz, resonance c (0…1); k: 0 low, 1 high, 2 band; state 6
    case svf
    /// out = a limited to rise over b seconds and fall over c seconds; state 2
    case slew
    /// out = envelope of |a| with attack b and release c seconds; state 6
    case follow
    /// out = latched value in state (the value of a name at the last frame)
    case prev
    /// out = white noise -1…1; state 1 (the generator word)
    case noise
    /// out = a sampled when b rises above 0.5; state 4
    case sah
    /// out = buffer read a seconds back (linear interpolation)
    case delayRead
    /// buffer write of a at the record head
    case delayWrite
    /// marks the output slot (a); the runtime copies it to the block
    case output
}
