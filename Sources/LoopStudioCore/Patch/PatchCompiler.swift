import Foundation

/// A problem in a patch: the line it is on (from 1) and what is wrong.
public struct PatchError: Error, Hashable, Sendable, CustomStringConvertible {
    public var line: Int
    public var message: String
    /// The module of a graph document the problem is in. `nil` for a text, or the document as a whole.
    public var module: String?
    public init(line: Int, _ message: String, module: String? = nil) { self.line = line; self.message = message; self.module = module }
    public var description: String {
        let where_ = line > 0 ? "line \(line): " : ""
        return (module.map { "\($0): " } ?? "") + where_ + message
    }
}

/// The unit a value carries at compile time. The compiler converts between seconds, hertz and note values
/// where a function asks for one of them; everything else is a plain number.
enum PatchUnit: Equatable { case plain, seconds, hz, db, note }

// MARK: Lexer

enum PatchToken: Equatable {
    case number(Double)
    case note(Double) // quarter notes
    case ident(String)
    case string(String)
    case sym(String)
    case newline
    case end
}

struct PatchLexer {
    static func tokens(_ source: String) throws -> [(PatchToken, Int)] {
        var out: [(PatchToken, Int)] = []
        let chars = Array(source.unicodeScalars)
        var i = 0, line = 1
        func peek(_ o: Int = 0) -> Character? { i + o < chars.count ? Character(chars[i + o]) : nil }
        while i < chars.count {
            let c = Character(chars[i])
            if c == "\n" { out.append((.newline, line)); line += 1; i += 1; continue }
            if c == " " || c == "\t" || c == "\r" { i += 1; continue }
            if c == "/" && peek(1) == "/" { while i < chars.count, Character(chars[i]) != "\n" { i += 1 }; continue }
            if c.isNumber || (c == "." && (peek(1)?.isNumber ?? false)) {
                var text = ""
                while let p = peek(), p.isNumber || p == "." && !(peek(1) == ".") { text.append(p); i += 1 }
                // A note value: 1/16, 1/8., 1/4T (digits, a slash, digits, then a dot or a T, with no spaces).
                if peek() == "/", let d = peek(1), d.isNumber, !text.contains(".") {
                    var j = i + 1, den = ""
                    while j < chars.count, Character(chars[j]).isNumber { den.append(Character(chars[j])); j += 1 }
                    var factor = 1.0
                    if j < chars.count, Character(chars[j]) == "." { factor = 1.5; j += 1 }
                    else if j < chars.count, Character(chars[j]) == "T" { factor = 2.0 / 3.0; j += 1 }
                    if let n = Double(text), let dv = Double(den), dv > 0 {
                        out.append((.note(4 * n / dv * factor), line)); i = j; continue
                    }
                }
                guard let v = Double(text) else { throw PatchError(line: line, "bad number '\(text)'") }
                out.append((.number(v), line)); continue
            }
            if c.isLetter || c == "_" {
                var text = ""
                while let p = peek(), p.isLetter || p.isNumber || p == "_" { text.append(p); i += 1 }
                out.append((.ident(text), line)); continue
            }
            if c == "\"" {
                i += 1
                var text = ""
                while let p = peek(), p != "\"" { if p == "\n" { throw PatchError(line: line, "a string must end on its line") }; text.append(p); i += 1 }
                guard peek() == "\"" else { throw PatchError(line: line, "a string needs a closing quote") }
                i += 1
                out.append((.string(text), line)); continue
            }
            let two = String([c, peek(1) ?? " "])
            if ["..", ">=", "<=", "=="].contains(two) { out.append((.sym(two), line)); i += 2; continue }
            if "()=.,+-*/^><:{}|".contains(c) { out.append((.sym(String(c)), line)); i += 1; continue }
            throw PatchError(line: line, "unexpected character '\(c)'")
        }
        out.append((.newline, line))
        out.append((.end, line))
        return out
    }
}

// MARK: AST

indirect enum PatchExpr {
    case number(Double, PatchUnit)
    case note(Double)
    case name(String, Int)
    case call(String, [PatchExpr], Int)
    /// `buffer.read(t)`
    case member(String, String, [PatchExpr], Int)
    case binary(String, PatchExpr, PatchExpr, Int)
    case neg(PatchExpr)
}

struct PatchParamDecl {
    var key: String
    var min: Double, max: Double, def: Double
    var unit: String
    var log: Bool
    var isNote: Bool
    var choices: [String]
}

enum PatchLine {
    case patchName(String)
    case param(PatchParamDecl)
    case input(String)
    case output(String)
    case delay(String, Double)
    case meter(String)
    case write(String, PatchExpr)
    case assign(String, PatchExpr)
}

// MARK: Parser

struct PatchParser {
    private var tokens: [(PatchToken, Int)]
    private var pos = 0

    init(_ source: String) throws { tokens = try PatchLexer.tokens(source) }

    private var tok: PatchToken { tokens[pos].0 }
    private var line: Int { tokens[pos].1 }
    private mutating func advance() { if pos < tokens.count - 1 { pos += 1 } }
    private func fail(_ m: String) -> PatchError { PatchError(line: line, m) }

    private mutating func expectSym(_ s: String) throws {
        guard tok == .sym(s) else { throw fail("expected '\(s)'") }
        advance()
    }
    private mutating func ident() throws -> String {
        guard case .ident(let s) = tok else { throw fail("expected a name") }
        advance()
        return s
    }
    private mutating func number() throws -> Double {
        var sign = 1.0
        if tok == .sym("-") { sign = -1; advance() }
        guard case .number(let v) = tok else { throw fail("expected a number") }
        advance()
        return sign * v
    }

    mutating func parse() throws -> [(PatchLine, Int)] {
        var lines: [(PatchLine, Int)] = []
        while tok != .end {
            if tok == .newline { advance(); continue }
            let at = line
            lines.append((try statement(), at))
            guard tok == .newline || tok == .end else { throw fail("unexpected '\(describe(tok))' at the end of the line") }
        }
        return lines
    }

    private func describe(_ t: PatchToken) -> String {
        switch t {
        case .number(let v): String(v)
        case .note(let q): "note \(q)"
        case .ident(let s), .string(let s), .sym(let s): s
        case .newline: "end of line"
        case .end: "end"
        }
    }

    private mutating func statement() throws -> PatchLine {
        guard case .ident(let word) = tok else { throw fail("a line starts with a name or a keyword") }
        switch word {
        case "patch":
            advance()
            guard case .string(let name) = tok else { throw fail("patch needs its name in quotes") }
            advance()
            return .patchName(name)
        case "param":
            advance()
            return .param(try paramDecl())
        case "in":
            advance()
            let n = try ident()
            try skipType()
            return .input(n)
        case "out":
            advance()
            let n = try ident()
            try skipType()
            return .output(n)
        case "delay", "buffer":
            advance()
            let n = try ident()
            try expectSym("=")
            let v = try number()
            let u = try unitSuffix()
            guard u == .seconds else { throw fail("a delay length is a time: 2 s, 500 ms") }
            return .delay(n, v * (lastUnitWord == "ms" ? 0.001 : 1))
        case "meter":
            advance()
            return .meter(try ident())
        default:
            let n = try ident()
            if tok == .sym(".") {
                advance()
                let fn = try ident()
                guard fn == "write" else { throw fail("only '\(n).write(…)' stands on its own") }
                try expectSym("(")
                let e = try expr()
                try expectSym(")")
                return .write(n, e)
            }
            try expectSym("=")
            return .assign(n, try expr())
        }
    }

    private mutating func skipType() throws {
        if tok == .sym(":") { advance(); _ = try ident() }
    }

    private var lastUnitWord = ""

    /// A unit after a number: ms, s, Hz, kHz, dB. Returns the unit and sets `lastUnitWord`.
    private mutating func unitSuffix() throws -> PatchUnit {
        lastUnitWord = ""
        guard case .ident(let u) = tok else { return .plain }
        switch u {
        case "ms", "s": lastUnitWord = u; advance(); return .seconds
        case "Hz", "hz", "kHz": lastUnitWord = u; advance(); return .hz
        case "dB", "db": lastUnitWord = u; advance(); return .db
        default: return .plain
        }
    }

    private mutating func paramDecl() throws -> PatchParamDecl {
        let key = try ident()
        var decl = PatchParamDecl(key: key, min: 0, max: 1, def: 0, unit: "", log: false, isNote: false, choices: [])
        if tok == .ident("note") {
            advance()
            decl.isNote = true
            decl.choices = NoteDivision.all.map(\.name)
            decl.min = 0; decl.max = Double(NoteDivision.all.count - 1)
            try expectSym("=")
            guard case .note(let q) = tok else { throw fail("a note param starts at a note value, such as 1/16") }
            advance()
            decl.def = Double(nearestDivision(q))
            return decl
        }
        if case .number = tok, true { // a range: min..max
            decl.min = try number()
            try expectSym("..")
            decl.max = try number()
        } else if tok == .sym("-") {
            decl.min = try number()
            try expectSym("..")
            decl.max = try number()
        }
        try expectSym("=")
        decl.def = try number()
        while true {
            if tok == .ident("log") { decl.log = true; advance(); continue }
            if case .string(let u) = tok { decl.unit = u; advance(); continue }
            break
        }
        guard decl.max > decl.min else { throw fail("param \(key): max must be above min") }
        guard decl.def >= decl.min, decl.def <= decl.max else { throw fail("param \(key): the default is outside its range") }
        if decl.log, decl.min <= 0 { throw fail("param \(key): a log range starts above 0") }
        return decl
    }

    private func nearestDivision(_ quarters: Double) -> Int {
        var best = 0, bestDiff = Double.infinity
        for (i, d) in NoteDivision.all.enumerated() where abs(d.quarters - quarters) < bestDiff { best = i; bestDiff = abs(d.quarters - quarters) }
        return best
    }

    // Precedence: comparison < additive < multiplicative < power < unary < postfix.
    private mutating func expr() throws -> PatchExpr { try comparison() }

    private mutating func comparison() throws -> PatchExpr {
        var left = try additive()
        while case .sym(let s) = tok, [">", "<", ">=", "<=", "=="].contains(s) {
            let at = line; advance()
            left = .binary(s, left, try additive(), at)
        }
        return left
    }

    private mutating func additive() throws -> PatchExpr {
        var left = try multiplicative()
        while case .sym(let s) = tok, s == "+" || s == "-" {
            let at = line; advance()
            left = .binary(s, left, try multiplicative(), at)
        }
        return left
    }

    private mutating func multiplicative() throws -> PatchExpr {
        var left = try power()
        while case .sym(let s) = tok, s == "*" || s == "/" {
            let at = line; advance()
            left = .binary(s, left, try power(), at)
        }
        return left
    }

    private mutating func power() throws -> PatchExpr {
        let base = try unary()
        if tok == .sym("^") {
            let at = line; advance()
            return .binary("^", base, try power(), at)
        }
        return base
    }

    private mutating func unary() throws -> PatchExpr {
        if tok == .sym("-") { advance(); return .neg(try unary()) }
        return try primary()
    }

    private mutating func primary() throws -> PatchExpr {
        let at = line
        switch tok {
        case .number(let v):
            advance()
            let u = try unitSuffix()
            var value = v
            if lastUnitWord == "ms" { value /= 1000 }
            if lastUnitWord == "kHz" { value *= 1000 }
            return .number(value, u)
        case .note(let q):
            advance()
            return .note(q)
        case .string:
            throw fail("a string cannot be part of an expression")
        case .sym("("):
            advance()
            let e = try expr()
            try expectSym(")")
            return e
        case .ident(let name):
            advance()
            if tok == .sym("(") {
                advance()
                let args = try arguments()
                return .call(name, args, at)
            }
            if tok == .sym(".") {
                advance()
                let fn = try ident()
                try expectSym("(")
                let args = try arguments()
                return .member(name, fn, args, at)
            }
            return .name(name, at)
        default:
            throw fail("unexpected '\(describe(tok))'")
        }
    }

    /// After '(': the arguments up to and including ')'.
    private mutating func arguments() throws -> [PatchExpr] {
        var args: [PatchExpr] = []
        if tok == .sym(")") { advance(); return args }
        while true {
            args.append(try expr())
            if tok == .sym(",") { advance(); continue }
            try expectSym(")")
            return args
        }
    }
}

// MARK: Compiler

public enum PatchCompiler {
    /// The names the song gives every patch.
    static let builtinNames: [String: (slot: Int, unit: PatchUnit)] = [
        "beat": (PatchProgram.beatSlot, .plain), "bar": (PatchProgram.barSlot, .plain), "tempo": (PatchProgram.tempoSlot, .plain),
        "sr": (PatchProgram.sampleRateSlot, .hz),
    ]
    static let shapes: [String: Float] = ["sine": 0, "saw": 1, "square": 2, "tri": 3, "triangle": 3]

    /// A text, or a graph document (`PatchDocument`, when the source starts with `{`).
    public static func compile(_ source: String) throws -> PatchProgram {
        if PatchDocument.isDocument(source) {
            guard let doc = PatchDocument.parse(source) else { throw PatchError(line: 0, "the patch document does not parse") }
            return try PatchGraphCompiler.compile(doc, source: source)
        }
        var parser = try PatchParser(source)
        let lines = try parser.parse()
        var c = Context(source: source)
        return try c.build(lines)
    }

    /// The outside of a text: its name, input, output, params and meters. What a Script module's ports are.
    struct Shape {
        var name = "Patch"
        var input = "x"
        var output: String?
        var params: [PatchParamDecl] = []
        var meters: [String] = []
    }

    static func shape(of source: String) throws -> Shape {
        var parser = try PatchParser(source)
        var s = Shape()
        for (l, _) in try parser.parse() {
            switch l {
            case .patchName(let n): s.name = n
            case .input(let n): s.input = n
            case .output(let n): s.output = n
            case .param(let d): s.params.append(d)
            case .meter(let n): s.meters.append(n)
            default: break
            }
        }
        return s
    }

    /// Compiles once per source text. The renderer and the views ask for the same text many times.
    public static func cached(_ source: String) -> Result<PatchProgram, PatchError> {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let hit = cache[source] { return hit }
        let result: Result<PatchProgram, PatchError>
        do { result = .success(try compile(source)) } catch let e as PatchError { result = .failure(e) } catch { result = .failure(PatchError(line: 0, "\(error)")) }
        if cache.count > 64 { cache.removeAll() }
        cache[source] = result
        return result
    }
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Result<PatchProgram, PatchError>] = [:]

    /// The knobs a source gives, or the bare device when it does not compile.
    public static func spec(for source: String?) -> EffectSpec {
        guard let source, case .success(let p) = cached(source) else { return BuiltInEffects.patch }
        return p.spec
    }

    struct Value { var slot: Int; var unit: PatchUnit }

    struct Context {
        let source: String
        var name = "Patch"
        var ops: [PatchOp] = []
        var slots = PatchProgram.reservedSlots
        var states = 0
        var names: [String: Value] = [:]
        var buffers: [PatchBuffer] = []
        var bufferIndex: [String: Int] = [:]
        var params: [EffectParam] = []
        var paramSlots: [PatchParamSlot] = []
        var latches: [PatchLatch] = []
        var pendingPrev: [(name: String, state: Int, line: Int)] = []
        var meters: [(slot: Int, index: Int)] = []
        var meterNames: [(String, Int)] = []
        var inputName = "x"
        var outputName: String?
        var line = 0
        // A Script module inside a graph: its names are bound from outside (the cables, the knobs), its
        // delay lines get a prefix, and its output is a slot the graph reads, not an `output` op.
        var embedded = false
        var prefix = ""
        var bindings: [String: Value] = [:]
        var meterSlots: [(name: String, slot: Int)] = []

        init(source: String) { self.source = source }

        mutating func slot() -> Int { defer { slots += 1 }; return slots }
        mutating func state(_ n: Int) -> Int { defer { states += n }; return states }
        func fail(_ m: String) -> PatchError { PatchError(line: line, m) }

        mutating func build(_ lines: [(PatchLine, Int)]) throws -> PatchProgram {
            let out = try assemble(lines)
            ops.append(PatchOp(.output, a: out))
            for (n, index) in meterNames {
                guard let v = names[n] else { throw fail("meter \(n): '\(n)' is never set") }
                guard index < DSPMeterCount else { throw fail("a patch shows at most \(DSPMeterCount) meters") }
                meters.append((v.slot, index))
            }
            var spec = EffectSpec(id: "patch", name: name, params: params, view: "patch")
            spec.groups = params.isEmpty ? [] : [EffectGroup(name, params.map(\.key))]
            spec.meterNames = meterNames.map(\.0)
            return PatchProgram(name: name, spec: spec, ops: ops, slotCount: slots, stateCount: states, buffers: buffers,
                                params: paramSlots, latches: latches, meters: meters, source: source)
        }

        /// Compiles the lines into `ops` and returns the slot of the output.
        mutating func assemble(_ lines: [(PatchLine, Int)]) throws -> Int {
            // Declarations first, in any order, so a knob or a delay can be named before or after its use.
            for (l, at) in lines {
                line = at
                switch l {
                case .patchName(let n): name = n
                case .input(let n): inputName = n
                case .output(let n): outputName = n
                case .param(let d): try declare(d)
                case .delay(let n, let seconds):
                    guard bufferIndex[n] == nil, names[n] == nil else { throw fail("'\(n)' is declared twice") }
                    guard seconds > 0, seconds <= 60 else { throw fail("a delay is between 1 ms and 60 s") }
                    bufferIndex[n] = buffers.count
                    buffers.append(PatchBuffer(name: prefix + n, seconds: seconds))
                case .meter(let n): meterNames.append((n, meterNames.count))
                case .write, .assign: break
                }
            }
            guard names[inputName] == nil else { throw fail("the input '\(inputName)' clashes with a knob") }
            names[inputName] = embedded ? (bindings[inputName] ?? Value(slot: PatchProgram.zeroSlot, unit: .plain)) : Value(slot: PatchProgram.inSlot, unit: .plain)
            for (l, at) in lines {
                line = at
                switch l {
                case .assign(let n, let e):
                    guard bufferIndex[n] == nil else { throw fail("'\(n)' is a delay; write into it with \(n).write(…)") }
                    if let existing = names[n], paramSlots.contains(where: { $0.slot == existing.slot }) { throw fail("'\(n)' is a knob and cannot be set") }
                    if n == inputName { throw fail("the input '\(n)' cannot be set") }
                    if PatchCompiler.builtinNames[n] != nil { throw fail("'\(n)' belongs to the song") }
                    let v = try compile(e)
                    names[n] = v
                case .write(let n, let e):
                    guard let b = bufferIndex[n] else { throw fail("'\(n)' is not a delay") }
                    let v = try compile(e)
                    ops.append(PatchOp(.delayWrite, a: v.slot, buffer: b))
                default: break
                }
            }
            guard let outputName else { throw fail("the patch needs an output: out y, then y = …") }
            guard let out = names[outputName] else { throw fail("the output '\(outputName)' is never set") }
            for p in pendingPrev {
                guard let v = names[p.name] else { throw PatchError(line: p.line, "prev(\(p.name)): '\(p.name)' is never set") }
                latches.append(PatchLatch(slot: v.slot, state: p.state))
            }
            for (n, _) in meterNames {
                guard let v = names[n] else { throw fail("meter \(n): '\(n)' is never set") }
                meterSlots.append((n, v.slot))
            }
            return out.slot
        }

        mutating func declare(_ d: PatchParamDecl) throws {
            guard names[d.key] == nil else { throw fail("'\(d.key)' is declared twice") }
            guard PatchCompiler.builtinNames[d.key] == nil else { throw fail("'\(d.key)' belongs to the song") }
            let unit: PatchUnit = d.isNote ? .note : (d.unit == "ms" || d.unit == "s" ? .seconds : (d.unit == "Hz" ? .hz : (d.unit == "dB" ? .db : .plain)))
            let s: Int
            if embedded {
                // The graph decides what the param is: a cable, a knob of the device, or a fixed value.
                guard let bound = bindings[d.key] else { throw fail("param '\(d.key)' is not bound") }
                s = bound.slot
            } else {
                let label = d.key.prefix(1).uppercased() + d.key.dropFirst()
                var p = EffectParam(d.key, label, d.min, d.max, d.def, unit: d.unit, choices: d.choices, log: d.log)
                if d.isNote { p.rotary = true }
                params.append(p)
                s = slot()
                paramSlots.append(PatchParamSlot(key: d.key, slot: s, isNote: d.isNote))
            }
            names[d.key] = Value(slot: s, unit: unit)
            if d.unit == "ms" {
                // The knob shows milliseconds; the program works in seconds.
                let seconds = slot()
                ops.append(PatchOp(.mul, out: seconds, a: s, b: constant(0.001)))
                names[d.key] = Value(slot: seconds, unit: .seconds)
            }
        }

        mutating func constant(_ v: Double) -> Int {
            let s = slot()
            ops.append(PatchOp(.const, out: s, k: Float(v)))
            return s
        }

        mutating func emit(_ code: PatchOpCode, _ a: Int, _ b: Int = -1, _ c: Int = -1, k: Float = 0, state: Int = -1, buffer: Int = -1) -> Int {
            let s = slot()
            ops.append(PatchOp(code, out: s, a: a, b: b, c: c, k: k, state: state, buffer: buffer))
            return s
        }

        /// A value as the unit a function asks for.
        mutating func convert(_ v: Value, to unit: PatchUnit, what: String) throws -> Int {
            switch (v.unit, unit) {
            case (let a, let b) where a == b: return v.slot
            case (.note, .seconds): return emit(.mul, v.slot, PatchProgram.quarterSecondsSlot)
            case (.note, .hz): return emit(.recip, emit(.mul, v.slot, PatchProgram.quarterSecondsSlot))
            case (.seconds, .hz), (.hz, .seconds): return emit(.recip, v.slot)
            case (.plain, _), (_, .plain), (.db, _): return v.slot
            default: throw fail("\(what) takes \(unit), not \(v.unit)")
            }
        }

        mutating func compile(_ e: PatchExpr) throws -> Value {
            switch e {
            case .number(let v, let u):
                return Value(slot: constant(v), unit: u)
            case .note(let q):
                return Value(slot: constant(q), unit: .note)
            case .name(let n, let at):
                line = at
                if let v = names[n] { return v }
                if let b = PatchCompiler.builtinNames[n] { return Value(slot: b.slot, unit: b.unit) }
                if n == "pi" { return Value(slot: constant(Double.pi), unit: .plain) }
                if bufferIndex[n] != nil { throw fail("'\(n)' is a delay: read it with \(n).read(time)") }
                throw fail("'\(n)' is not defined above this line")
            case .neg(let inner):
                let v = try compile(inner)
                return Value(slot: emit(.neg, v.slot), unit: v.unit)
            case .binary(let op, let l, let r, let at):
                let a = try compile(l), b = try compile(r)
                line = at
                let code: PatchOpCode
                switch op {
                case "+": code = .add
                case "-": code = .sub
                case "*": code = .mul
                case "/": code = .div
                case "^": code = .pow
                case ">": code = .gt
                case "<": code = .lt
                case ">=": code = .ge
                case "<=": code = .le
                case "==": code = .eq
                default: throw fail("unknown operator \(op)")
                }
                let unit: PatchUnit = a.unit == .plain ? b.unit : (b.unit == .plain || a.unit == b.unit ? a.unit : .plain)
                return Value(slot: emit(code, a.slot, b.slot), unit: [.gt, .lt, .ge, .le, .eq].contains(code) ? .plain : unit)
            case .member(let obj, let fn, let args, let at):
                line = at
                guard let b = bufferIndex[obj] else { throw fail("'\(obj)' is not a delay") }
                guard fn == "read" else { throw fail("a delay has read(time) and write(value)") }
                guard args.count == 1 else { throw fail("\(obj).read takes one argument: the time") }
                let t = try compile(args[0])
                let seconds = try convert(t, to: .seconds, what: "\(obj).read")
                return Value(slot: emit(.delayRead, seconds, buffer: b), unit: .plain)
            case .call(let fn, let args, let at):
                line = at
                return try call(fn, args)
            }
        }

        mutating func shape(_ e: PatchExpr?) throws -> Float {
            guard let e else { return 0 }
            guard case .name(let n, _) = e, let s = PatchCompiler.shapes[n] else { throw fail("the shape is sine, saw, square or tri") }
            return s
        }

        mutating func args(_ fn: String, _ args: [PatchExpr], _ count: ClosedRange<Int>) throws -> [Value] {
            guard count.contains(args.count) else {
                throw fail("\(fn) takes \(count.lowerBound == count.upperBound ? "\(count.lowerBound)" : "\(count.lowerBound) to \(count.upperBound)") argument\(count.upperBound == 1 ? "" : "s")")
            }
            return try args.map { try compile($0) }
        }

        mutating func call(_ fn: String, _ a: [PatchExpr]) throws -> Value {
            let unary: [String: PatchOpCode] = ["abs": .abs, "sqrt": .sqrt, "sin": .sin, "cos": .cos, "exp": .exp, "log": .log,
                                                "floor": .floor, "tanh": .tanh]
            if let code = unary[fn] {
                let v = try args(fn, a, 1...1)
                return Value(slot: emit(code, v[0].slot), unit: v[0].unit)
            }
            switch fn {
            case "gain":
                let v = try args(fn, a, 1...1)
                return Value(slot: emit(.dbToGain, v[0].slot), unit: .plain)
            case "min", "max", "pow":
                let v = try args(fn, a, 2...2)
                return Value(slot: emit(fn == "min" ? .min : (fn == "max" ? .max : .pow), v[0].slot, v[1].slot), unit: v[0].unit)
            case "clip":
                let v = try args(fn, a, 3...3)
                return Value(slot: emit(.clip, v[0].slot, v[1].slot, v[2].slot), unit: v[0].unit)
            case "mix":
                let v = try args(fn, a, 3...3)
                return Value(slot: emit(.mix, v[0].slot, v[1].slot, v[2].slot), unit: .plain)
            case "osc":
                guard (1...2).contains(a.count) else { throw fail("osc takes a frequency and an optional shape") }
                let f = try compile(a[0])
                let hz = try convert(f, to: .hz, what: "osc")
                return Value(slot: emit(.osc, hz, k: try shape(a.count > 1 ? a[1] : nil), state: state(2)), unit: .plain)
            case "lfo":
                guard (1...2).contains(a.count) else { throw fail("lfo takes a rate and an optional shape") }
                let f = try compile(a[0])
                let k = try shape(a.count > 1 ? a[1] : nil)
                if f.unit == .note { return Value(slot: emit(.lfoSync, f.slot, k: k), unit: .plain) }
                let hz = try convert(f, to: .hz, what: "lfo")
                return Value(slot: emit(.lfo, hz, k: k, state: state(2)), unit: .plain)
            case "phase":
                let v = try args(fn, a, 1...1)
                guard v[0].unit == .note else { throw fail("phase takes a note value, such as 1/16") }
                return Value(slot: emit(.phase, v[0].slot), unit: .plain)
            case "lp", "hp", "bp":
                let v = try args(fn, a, 2...3)
                let cut = try convert(v[1], to: .hz, what: fn)
                let q = v.count > 2 ? v[2].slot : constant(0.2)
                let k: Float = fn == "lp" ? 0 : (fn == "hp" ? 1 : 2)
                return Value(slot: emit(.svf, v[0].slot, cut, q, k: k, state: state(6)), unit: .plain)
            case "slew", "follow":
                let v = try args(fn, a, 3...3)
                let up = try convert(v[1], to: .seconds, what: fn), down = try convert(v[2], to: .seconds, what: fn)
                return Value(slot: emit(fn == "slew" ? .slew : .follow, v[0].slot, up, down, state: state(fn == "slew" ? 2 : 6)), unit: .plain)
            case "sah":
                let v = try args(fn, a, 2...2)
                return Value(slot: emit(.sah, v[0].slot, v[1].slot, state: state(4)), unit: v[0].unit)
            case "noise":
                _ = try args(fn, a, 0...0)
                return Value(slot: emit(.noise, -1, state: state(1)), unit: .plain)
            case "prev":
                guard a.count == 1, case .name(let n, _) = a[0] else { throw fail("prev takes a name: prev(y)") }
                let st = state(2)
                pendingPrev.append((n, st, line))
                return Value(slot: emit(.prev, -1, state: st), unit: names[n]?.unit ?? .plain)
            default:
                throw fail("unknown function '\(fn)'")
            }
        }
    }
}

/// `DSPEffect.meterCount` lives in the engine; the compiler checks against the same number.
let DSPMeterCount = 4

// MARK: The device

public extension BuiltInEffects {
    /// The programmable device. Its knobs come from the patch text on the slot, see `DeviceSlot.spec`.
    static let patch = EffectSpec(id: "patch", name: "Patch", params: [], view: "patch")
}

public extension DeviceSlot {
    /// The spec of a built-in device, for a patch the one its text gives. `nil` for a plugin.
    var spec: EffectSpec? {
        guard format == "builtin" else { return nil }
        if identifier == "patch" { return PatchCompiler.spec(for: source) }
        return BuiltInEffects.spec(identifier)
    }
    /// The error of a patch whose text does not compile, else `nil`.
    var patchError: PatchError? {
        guard format == "builtin", identifier == "patch", let source else { return nil }
        if case .failure(let e) = PatchCompiler.cached(source) { return e }
        return nil
    }
}
