import Foundation

/// The DX7 voice: six operators, the pitch envelope, the LFO and the algorithm, as Yamaha stored them.
/// The parameter keys follow the voice edit buffer (VCED) names: `o1.r1` is operator 1's envelope rate 1,
/// `o1.ol` its output level, `alg` the algorithm, `pr1` the pitch envelope's rate 1. Every value is an
/// integer in the DX7's own range (mostly 0...99), so a bank reads and writes without loss.
public enum DX7 {
    /// Operator numbers as the panel shows them, 1 to 6. Operator 6 comes first in a voice dump.
    public static let operators = 1...6

    /// The per-operator keys, in the order of the voice edit buffer.
    public static let operatorKeys = ["r1", "r2", "r3", "r4", "l1", "l2", "l3", "l4", "bp", "ld", "rd", "lc", "rc", "rs", "ams", "kvs", "ol", "mode", "coarse", "fine", "det"]
    /// The global keys, in the order of the voice edit buffer after the operators.
    public static let globalKeys = ["pr1", "pr2", "pr3", "pr4", "pl1", "pl2", "pl3", "pl4", "alg", "fb", "oks", "lfs", "lfd", "lpmd", "lamd", "lfks", "lfw", "lpms", "transpose"]

    public static func key(_ op: Int, _ name: String) -> String { "o\(op).\(name)" }

    public static let curveNames = ["-Lin", "-Exp", "+Exp", "+Lin"]
    public static let lfoWaves = ["Triangle", "Saw Down", "Saw Up", "Square", "Sine", "S&H"]

    /// The parameters of one operator. The on switch is ours: the DX7 had operator buttons, not voice data.
    static func operatorParams(_ op: Int) -> [EffectParam] {
        let k = { (n: String) in key(op, n) }
        let p = "Op \(op) "
        let one = op == 1
        return [
            EffectParam(k("r1"), p + "Rate 1", 0, 99, 99), EffectParam(k("r2"), p + "Rate 2", 0, 99, 99),
            EffectParam(k("r3"), p + "Rate 3", 0, 99, 99), EffectParam(k("r4"), p + "Rate 4", 0, 99, 99),
            EffectParam(k("l1"), p + "Level 1", 0, 99, 99), EffectParam(k("l2"), p + "Level 2", 0, 99, 99),
            EffectParam(k("l3"), p + "Level 3", 0, 99, 99), EffectParam(k("l4"), p + "Level 4", 0, 99, 0),
            EffectParam(k("bp"), p + "Break Point", 0, 99, 39), EffectParam(k("ld"), p + "Left Depth", 0, 99, 0),
            EffectParam(k("rd"), p + "Right Depth", 0, 99, 0),
            EffectParam(k("lc"), p + "Left Curve", 0, 3, 0, choices: curveNames),
            EffectParam(k("rc"), p + "Right Curve", 0, 3, 0, choices: curveNames),
            EffectParam(k("rs"), p + "Rate Scaling", 0, 7, 0), EffectParam(k("ams"), p + "Amp Mod Sens", 0, 3, 0),
            EffectParam(k("kvs"), p + "Velocity Sens", 0, 7, 0), EffectParam(k("ol"), p + "Output Level", 0, 99, one ? 99 : 0),
            EffectParam(k("mode"), p + "Mode", 0, 1, 0, choices: ["Ratio", "Fixed"]),
            EffectParam(k("coarse"), p + "Coarse", 0, 31, 1), EffectParam(k("fine"), p + "Fine", 0, 99, 0),
            EffectParam(k("det"), p + "Detune", 0, 14, 7),
            EffectParam(k("on"), p + "On", 0, 1, 1, choices: ["Off", "On"]),
        ]
    }

    static let globalParams: [EffectParam] = [
        EffectParam("pr1", "Pitch Rate 1", 0, 99, 99), EffectParam("pr2", "Pitch Rate 2", 0, 99, 99),
        EffectParam("pr3", "Pitch Rate 3", 0, 99, 99), EffectParam("pr4", "Pitch Rate 4", 0, 99, 99),
        EffectParam("pl1", "Pitch Level 1", 0, 99, 50), EffectParam("pl2", "Pitch Level 2", 0, 99, 50),
        EffectParam("pl3", "Pitch Level 3", 0, 99, 50), EffectParam("pl4", "Pitch Level 4", 0, 99, 50),
        EffectParam("alg", "Algorithm", 0, 31, 0),
        EffectParam("fb", "Feedback", 0, 7, 0),
        EffectParam("oks", "Osc Key Sync", 0, 1, 1, choices: ["Off", "On"]),
        EffectParam("lfs", "LFO Speed", 0, 99, 35), EffectParam("lfd", "LFO Delay", 0, 99, 0),
        EffectParam("lpmd", "Pitch Mod Depth", 0, 99, 0), EffectParam("lamd", "Amp Mod Depth", 0, 99, 0),
        EffectParam("lfks", "LFO Key Sync", 0, 1, 1, choices: ["Off", "On"]),
        EffectParam("lfw", "LFO Wave", 0, 5, 0, choices: lfoWaves),
        EffectParam("lpms", "Pitch Mod Sens", 0, 7, 3),
        EffectParam("transpose", "Transpose", 0, 48, 24),
        EffectParam("volume", "Volume", -24, 12, 0, unit: "dB"),
    ]

    /// The whole instrument: 6 × 22 operator parameters, then the globals and our volume.
    public static let spec: EffectSpec = {
        var params = operators.flatMap(operatorParams) + globalParams
        // The curves, the wave and the mode click through as knobs, like the data slider did.
        for i in params.indices where !params[i].choices.isEmpty && !params[i].isSwitch { params[i].rotary = true }
        var s = EffectSpec(id: "dx7", name: "DX7", params: params)
        s.isInstrument = true
        return s
    }()

    /// The "INIT VOICE" of the DX7: operator 1 alone, a sine.
    public static var initVoice: [String: Double] {
        var p: [String: Double] = [:]
        for param in spec.params where param.key != "volume" { p[param.key] = param.def }
        return p
    }

    // MARK: Algorithms

    /// One of the 32 algorithms: for each operator (index 0 is operator 1) the operators that modulate it,
    /// which operators reach the output, and the feedback path. The feedback goes from `feedbackFrom`'s
    /// output into `feedbackTo`'s phase; in 30 algorithms both are the same operator.
    public struct Algorithm: Sendable, Hashable {
        public var modulators: [[Int]]
        public var carriers: [Int]
        public var feedbackFrom: Int
        public var feedbackTo: Int

        public func isCarrier(_ op: Int) -> Bool { carriers.contains(op) }
        /// The operators that `op` modulates.
        public func targets(of op: Int) -> [Int] { modulators.indices.filter { modulators[$0].contains(op) } }
    }

    /// The 32 algorithms, from the chart on the DX7's panel. `m` lists `modulator → carrier` pairs, `c` the
    /// carriers, `f` the feedback as `from → to`.
    public static let algorithms: [Algorithm] = {
        func a(_ c: [Int], _ m: [(Int, Int)], _ f: (Int, Int)) -> Algorithm {
            var mods = Array(repeating: [Int](), count: 6)
            for (from, to) in m { mods[to - 1].append(from - 1) }
            return Algorithm(modulators: mods, carriers: c.map { $0 - 1 }, feedbackFrom: f.0 - 1, feedbackTo: f.1 - 1)
        }
        return [
            a([1, 3], [(2, 1), (6, 5), (5, 4), (4, 3)], (6, 6)),                       // 1
            a([1, 3], [(2, 1), (6, 5), (5, 4), (4, 3)], (2, 2)),                       // 2
            a([1, 4], [(3, 2), (2, 1), (6, 5), (5, 4)], (6, 6)),                       // 3
            a([1, 4], [(3, 2), (2, 1), (6, 5), (5, 4)], (4, 6)),                       // 4
            a([1, 3, 5], [(2, 1), (4, 3), (6, 5)], (6, 6)),                            // 5
            a([1, 3, 5], [(2, 1), (4, 3), (6, 5)], (5, 6)),                            // 6
            a([1, 3], [(2, 1), (4, 3), (5, 3), (6, 5)], (6, 6)),                       // 7
            a([1, 3], [(2, 1), (4, 3), (5, 3), (6, 5)], (4, 4)),                       // 8
            a([1, 3], [(2, 1), (4, 3), (5, 3), (6, 5)], (2, 2)),                       // 9
            a([1, 4], [(3, 2), (2, 1), (5, 4), (6, 4)], (3, 3)),                       // 10
            a([1, 4], [(3, 2), (2, 1), (5, 4), (6, 4)], (6, 6)),                       // 11
            a([1, 3], [(2, 1), (4, 3), (5, 3), (6, 3)], (2, 2)),                       // 12
            a([1, 3], [(2, 1), (4, 3), (5, 3), (6, 3)], (6, 6)),                       // 13
            a([1, 3], [(2, 1), (4, 3), (5, 4), (6, 4)], (6, 6)),                       // 14
            a([1, 3], [(2, 1), (4, 3), (5, 4), (6, 4)], (2, 2)),                       // 15
            a([1], [(2, 1), (3, 1), (5, 1), (4, 3), (6, 5)], (6, 6)),                  // 16
            a([1], [(2, 1), (3, 1), (5, 1), (4, 3), (6, 5)], (2, 2)),                  // 17
            a([1], [(2, 1), (3, 1), (4, 1), (5, 4), (6, 5)], (3, 3)),                  // 18
            a([1, 4, 5], [(3, 2), (2, 1), (6, 4), (6, 5)], (6, 6)),                    // 19
            a([1, 2, 4], [(3, 1), (3, 2), (5, 4), (6, 4)], (3, 3)),                    // 20
            a([1, 2, 4, 5], [(3, 1), (3, 2), (6, 4), (6, 5)], (3, 3)),                 // 21
            a([1, 3, 4, 5], [(2, 1), (6, 3), (6, 4), (6, 5)], (6, 6)),                 // 22
            a([1, 2, 4, 5], [(3, 2), (6, 4), (6, 5)], (6, 6)),                         // 23
            a([1, 2, 3, 4, 5], [(6, 3), (6, 4), (6, 5)], (6, 6)),                      // 24
            a([1, 2, 3, 4, 5], [(6, 4), (6, 5)], (6, 6)),                              // 25
            a([1, 2, 4], [(3, 2), (5, 4), (6, 4)], (6, 6)),                            // 26
            a([1, 2, 4], [(3, 2), (5, 4), (6, 4)], (3, 3)),                            // 27
            a([1, 3, 6], [(2, 1), (5, 4), (4, 3)], (5, 5)),                            // 28
            a([1, 2, 3, 5], [(4, 3), (6, 5)], (6, 6)),                                 // 29
            a([1, 2, 3, 6], [(5, 4), (4, 3)], (5, 5)),                                 // 30
            a([1, 2, 3, 4, 5], [(6, 5)], (6, 6)),                                      // 31
            a([1, 2, 3, 4, 5, 6], [], (6, 6)),                                         // 32
        ]
    }()

    // MARK: Banks

    /// One voice of a bank: its name and its parameters, ready for a device.
    public struct Voice: Sendable, Hashable {
        public var name: String
        public var params: [String: Double]

        public init(name: String, params: [String: Double]) { self.name = name; self.params = params }

        /// Reads one voice from its 128 packed bytes, the format of a 32-voice bulk dump.
        public init(packed b: [UInt8]) {
            precondition(b.count >= 128)
            var p: [String: Double] = [:]
            for i in 0..<6 {
                let op = 6 - i
                let o = i * 17
                let k = { (n: String) in DX7.key(op, n) }
                for (j, n) in ["r1", "r2", "r3", "r4", "l1", "l2", "l3", "l4", "bp", "ld", "rd"].enumerated() { p[k(n)] = Double(min(99, b[o + j])) }
                p[k("lc")] = Double(b[o + 11] & 3)
                p[k("rc")] = Double((b[o + 11] >> 2) & 3)
                p[k("rs")] = Double(b[o + 12] & 7)
                p[k("det")] = Double(min(14, (b[o + 12] >> 3) & 15))
                p[k("ams")] = Double(b[o + 13] & 3)
                p[k("kvs")] = Double((b[o + 13] >> 2) & 7)
                p[k("ol")] = Double(min(99, b[o + 14]))
                p[k("mode")] = Double(b[o + 15] & 1)
                p[k("coarse")] = Double((b[o + 15] >> 1) & 31)
                p[k("fine")] = Double(min(99, b[o + 16]))
                p[k("on")] = 1
            }
            for (j, n) in ["pr1", "pr2", "pr3", "pr4", "pl1", "pl2", "pl3", "pl4"].enumerated() { p[n] = Double(min(99, b[102 + j])) }
            p["alg"] = Double(b[110] & 31)
            p["fb"] = Double(b[111] & 7)
            p["oks"] = Double((b[111] >> 3) & 1)
            p["lfs"] = Double(min(99, b[112]))
            p["lfd"] = Double(min(99, b[113]))
            p["lpmd"] = Double(min(99, b[114]))
            p["lamd"] = Double(min(99, b[115]))
            p["lfks"] = Double(b[116] & 1)
            p["lfw"] = Double(min(5, (b[116] >> 1) & 7))
            p["lpms"] = Double((b[116] >> 4) & 7)
            p["transpose"] = Double(min(48, b[117]))
            params = p
            name = Voice.name(bytes: b[118..<128])
        }

        /// The ten name bytes as text: ASCII, with the DX7's few own glyphs mapped, trailing spaces gone.
        static func name(bytes: ArraySlice<UInt8>) -> String {
            let s = bytes.map { byte -> Character in
                switch byte {
                case 0x5C: return "¥"
                case 0x7E: return "→"
                case 0x7F: return "←"
                case 0x20...0x7D: return Character(UnicodeScalar(byte))
                default: return " "
                }
            }
            return String(s).trimmingCharacters(in: .whitespaces)
        }

        /// The voice as 128 packed bytes, the inverse of `init(packed:)`. The on switches are not stored.
        public var packed: [UInt8] {
            func v(_ key: String, _ max: Int) -> UInt8 { UInt8(Swift.max(0, Swift.min(max, Int((params[key] ?? DX7.spec.param(key)?.def ?? 0).rounded())))) }
            var b = [UInt8](repeating: 0, count: 128)
            for i in 0..<6 {
                let op = 6 - i
                let o = i * 17
                let k = { (n: String) in DX7.key(op, n) }
                for (j, n) in ["r1", "r2", "r3", "r4", "l1", "l2", "l3", "l4", "bp", "ld", "rd"].enumerated() { b[o + j] = v(k(n), 99) }
                b[o + 11] = v(k("lc"), 3) | v(k("rc"), 3) << 2
                b[o + 12] = v(k("rs"), 7) | v(k("det"), 14) << 3
                b[o + 13] = v(k("ams"), 3) | v(k("kvs"), 7) << 2
                b[o + 14] = v(k("ol"), 99)
                b[o + 15] = v(k("mode"), 1) | v(k("coarse"), 31) << 1
                b[o + 16] = v(k("fine"), 99)
            }
            for (j, n) in ["pr1", "pr2", "pr3", "pr4", "pl1", "pl2", "pl3", "pl4"].enumerated() { b[102 + j] = v(n, 99) }
            b[110] = v("alg", 31)
            b[111] = v("fb", 7) | v("oks", 1) << 3
            b[112] = v("lfs", 99); b[113] = v("lfd", 99); b[114] = v("lpmd", 99); b[115] = v("lamd", 99)
            b[116] = v("lfks", 1) | v("lfw", 5) << 1 | v("lpms", 7) << 4
            b[117] = v("transpose", 48)
            let ascii = Array(name.unicodeScalars.map { $0.value < 128 ? UInt8($0.value) : 0x20 }.prefix(10))
            for j in 0..<10 { b[118 + j] = j < ascii.count ? ascii[j] : 0x20 }
            return b
        }
    }

    /// A 32-voice bank, the DX7's bulk dump: `F0 43 0n 09 20 00`, 4096 bytes, a checksum, `F7`. A file of
    /// the bare 4096 bytes reads too.
    public struct Bank: Sendable, Hashable {
        public var voices: [Voice]

        public static let voiceCount = 32
        public static let size = 4104

        public init(voices: [Voice]) { self.voices = voices }

        /// The 4096 voice bytes of a dump, or `nil` when the bytes are not a 32-voice dump.
        public static func body(of data: Data) -> [UInt8]? {
            let bytes = [UInt8](data)
            if bytes.count >= 4104, bytes[0] == 0xF0, bytes[1] == 0x43, bytes[3] == 0x09, bytes[4] == 0x20, bytes[5] == 0x00 {
                return Array(bytes[6..<4102])
            }
            if bytes.count == 4096 { return bytes }
            return nil
        }

        /// The 32 names of a dump, without reading the voices.
        public static func names(of data: Data) -> [String]? {
            guard let body = body(of: data) else { return nil }
            return (0..<32).map { Voice.name(bytes: body[($0 * 128 + 118)..<($0 * 128 + 128)]) }
        }

        /// One voice of a dump.
        public static func voice(_ i: Int, of data: Data) -> Voice? {
            guard let body = body(of: data), (0..<32).contains(i) else { return nil }
            return Voice(packed: Array(body[(i * 128)..<(i * 128 + 128)]))
        }

        /// Reads a bank. `nil` when the bytes are not a 32-voice dump. A wrong checksum is tolerated: many
        /// banks on the web have one, and the voices still play.
        public init?(data: Data) {
            guard let body = Bank.body(of: data) else { return nil }
            voices = (0..<32).map { Voice(packed: Array(body[($0 * 128)..<($0 * 128 + 128)])) }
        }

        /// The bank as a bulk dump, with the checksum.
        public var data: Data {
            var out: [UInt8] = [0xF0, 0x43, 0x00, 0x09, 0x20, 0x00]
            var list = voices
            while list.count < 32 { list.append(Voice(name: "INIT VOICE", params: DX7.initVoice)) }
            var sum = 0
            for voice in list.prefix(32) {
                let b = voice.packed
                out += b
                sum += b.reduce(0) { $0 + Int($1) }
            }
            out.append(UInt8((128 - (sum & 127)) & 127))
            out.append(0xF7)
            return Data(out)
        }
    }
}
