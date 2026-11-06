import Foundation

/// Compiles a `PatchDocument` to the same `PatchProgram` a text compiles to (`docs/patcher.md` §6). Every
/// module becomes ops in one list; a Script module compiles with the text compiler into that list, its names
/// bound to the cables and knobs around it. Feedback cables get one frame of delay (a latch, like `prev`).
public enum PatchGraphCompiler {
    typealias Value = PatchCompiler.Value

    static func compile(_ doc: PatchDocument, source: String) throws -> PatchProgram {
        var g = Graph(doc: doc, source: source)
        return try g.build()
    }

    struct Graph {
        let doc: PatchDocument
        let source: String
        var c: PatchCompiler.Context
        var ports: [String: (inputs: [ModulePort], outputs: [ModulePort])] = [:]
        /// The slot of every output, by "module.port".
        var outputs: [String: Int] = [:]
        var feedback = Set<PatchCable>()
        /// Latches to make once every output slot is known: the source output, the state the `prev` op reads.
        var pendingLatches: [(key: String, state: Int)] = []
        var params: [EffectParam] = []
        var paramSlots: [PatchParamSlot] = []
        var groups: [EffectGroup] = []
        var meters: [(slot: Int, index: Int)] = []
        var meterNames: [String] = []

        init(doc: PatchDocument, source: String) {
            self.doc = doc
            self.source = source
            c = PatchCompiler.Context(source: source)
        }

        func fail(_ module: String?, _ m: String) -> PatchError { PatchError(line: 0, m, module: module) }

        mutating func build() throws -> PatchProgram {
            try check()
            let order = try ordered()
            for id in order { try emit(doc.module(id)!) }
            guard let out = doc.modules.first(where: { $0.kind == "out" }) else { throw fail(nil, "the patch needs an Audio Out module") }
            let outSlot = try input(out, PatchModules.audioIn).slot
            c.ops.append(PatchOp(.output, a: outSlot))
            for p in pendingLatches {
                guard let slot = outputs[p.key] else { throw fail(nil, "feedback from '\(p.key)' has no source") }
                c.latches.append(PatchLatch(slot: slot, state: p.state))
            }
            var spec = EffectSpec(id: "patch", name: doc.name, params: params, view: "patch")
            spec.groups = groups
            spec.meterNames = meterNames
            return PatchProgram(name: doc.name, spec: spec, ops: c.ops, slotCount: c.slots, stateCount: c.states, buffers: c.buffers,
                                params: paramSlots, latches: c.latches, meters: meters, source: source)
        }

        // MARK: Check

        mutating func check() throws {
            var ids = Set<String>()
            for m in doc.modules {
                guard ids.insert(m.id).inserted else { throw fail(m.id, "two modules have the id '\(m.id)'") }
                guard let spec = PatchModules.spec(m.kind) else { throw fail(m.id, "unknown module kind '\(m.kind)'") }
                if spec.single, doc.modules.filter({ $0.kind == m.kind }).count > 1 { throw fail(m.id, "a patch has one \(spec.name) module") }
                if m.kind == "script" {
                    do { _ = try PatchCompiler.shape(of: m.source ?? "") } catch let e as PatchError { throw PatchError(line: e.line, e.message, module: m.id) }
                }
                ports[m.id] = PatchModules.ports(of: m)
            }
            for cable in doc.cables {
                guard let from = ports[cable.from] else { throw fail(nil, "a cable comes from '\(cable.from)', which is not in the patch") }
                guard let to = ports[cable.to] else { throw fail(nil, "a cable goes to '\(cable.to)', which is not in the patch") }
                guard let o = from.outputs.first(where: { $0.name == cable.fromPort }) else { throw fail(cable.from, "no output '\(cable.fromPort)'") }
                guard let i = to.inputs.first(where: { $0.name == cable.toPort }) else { throw fail(cable.to, "no input '\(cable.toPort)'") }
                guard PortType.connects(o.type, to: i.type) else { throw fail(cable.to, "\(o.type.rawValue) from \(cable.from) does not go into the \(i.type.rawValue) input '\(cable.toPort)'") }
                guard cable.from != cable.to else { throw fail(cable.from, "a module does not feed itself; put a delay between") }
            }
        }

        // MARK: Order

        /// Modules as the canvas reads: left to right, top to bottom. The base order of ties and of searches.
        var baseOrder: [String] {
            doc.modules.sorted { ($0.x, $0.y, $0.id) < ($1.x, $1.y, $1.id) }.map(\.id)
        }

        /// Sources before targets. A cable that closes a loop is marked as feedback and left out of the order;
        /// the search runs in the base order, so the same cable is the feedback one every time.
        mutating func ordered() throws -> [String] {
            let base = baseOrder
            let rank = Dictionary(uniqueKeysWithValues: base.enumerated().map { ($1, $0) })
            var edges: [String: [PatchCable]] = [:]
            for cable in doc.cables { edges[cable.from, default: []].append(cable) }
            for k in edges.keys { edges[k]!.sort { (rank[$0.to] ?? 0, $0.toPort) < (rank[$1.to] ?? 0, $1.toPort) } }
            // Depth-first with three colours; a cable into a module on the stack closes a loop.
            enum Mark { case visiting, done }
            var marks: [String: Mark] = [:]
            func visit(_ id: String, _ feedback: inout Set<PatchCable>) {
                marks[id] = .visiting
                for cable in edges[id] ?? [] {
                    switch marks[cable.to] {
                    case .visiting: feedback.insert(cable)
                    case .done: break
                    case nil: visit(cable.to, &feedback)
                    }
                }
                marks[id] = .done
            }
            for id in base where marks[id] == nil { visit(id, &feedback) }
            // Kahn over the rest; ties by the base order.
            var incoming = Dictionary(uniqueKeysWithValues: base.map { ($0, 0) })
            for cable in doc.cables where !feedback.contains(cable) { incoming[cable.to]! += 1 }
            var ready = base.filter { incoming[$0] == 0 }
            var order: [String] = []
            while !ready.isEmpty {
                let id = ready.removeFirst()
                order.append(id)
                for cable in edges[id] ?? [] where !feedback.contains(cable) {
                    incoming[cable.to]! -= 1
                    if incoming[cable.to] == 0 {
                        ready.append(cable.to)
                        ready.sort { rank[$0]! < rank[$1]! }
                    }
                }
            }
            guard order.count == base.count else { throw fail(nil, "the cables form a loop that cannot be ordered") }
            return order
        }

        // MARK: Inputs

        static func unit(_ port: ModulePort) -> PatchUnit {
            switch port.unit {
            case "Hz": return .hz
            case "s", "ms": return .seconds
            case "dB": return .db
            case "note": return .note
            default: return .plain
            }
        }

        /// The value at an input: the sum of its cables, or the module's knob on the panel, or its fixed value.
        mutating func input(_ m: PatchModule, _ port: ModulePort) throws -> Value {
            let unit = Self.unit(port)
            let cables = doc.cables(into: m.id, port: port.name)
            if cables.isEmpty {
                if m.isOnPanel {
                    var p = PatchModules.param(m, port)
                    // Two Scripts with a param of one name: the second carries its module id.
                    if params.contains(where: { $0.key == p.key }) { p.key = "\(m.id).\(port.name)" }
                    params.append(p)
                    let s = c.slot()
                    paramSlots.append(PatchParamSlot(key: p.key, slot: s, isNote: port.isNote))
                    return scaled(Value(slot: s, unit: unit), port)
                }
                var v = m.values[port.name] ?? port.def
                if port.isNote { v = NoteDivision.at(v).quarters }
                if port.unit == "ms" { v *= 0.001 }
                return Value(slot: c.constant(v), unit: unit)
            }
            var slot = -1
            for cable in cables {
                let key = "\(cable.from).\(cable.fromPort)"
                let s: Int
                if feedback.contains(cable) {
                    let st = c.state(2)
                    pendingLatches.append((key, st))
                    s = c.emit(.prev, -1, state: st)
                } else {
                    guard let found = outputs[key] else { throw fail(m.id, "'\(key)' is not compiled before '\(m.id)'") }
                    s = found
                }
                slot = slot < 0 ? s : c.emit(.add, slot, s)
            }
            return scaled(Value(slot: slot, unit: unit), port)
        }

        /// A knob in ms gives seconds to the program; the other units pass as they are.
        mutating func scaled(_ v: Value, _ port: ModulePort) -> Value {
            port.unit == "ms" ? Value(slot: c.emit(.mul, v.slot, c.constant(0.001)), unit: .seconds) : v
        }

        mutating func inputs(_ m: PatchModule) throws -> [Value] {
            try (ports[m.id]?.inputs ?? []).map { try input(m, $0) }
        }

        func shape(_ m: PatchModule) -> Float {
            PatchCompiler.shapes[m.settings["shape"] ?? "sine"] ?? 0
        }

        mutating func set(_ m: PatchModule, _ slot: Int) { set(m, port: "out", slot) }
        mutating func set(_ m: PatchModule, port: String, _ slot: Int) { outputs["\(m.id).\(port)"] = slot }

        /// The knobs of a module on the panel, as one group, in the order the panel reads.
        mutating func group(_ m: PatchModule, keys: [String]) {
            guard m.isOnPanel, !keys.isEmpty else { return }
            groups.append(EffectGroup(PatchModules.label(m), keys))
        }

        // MARK: Emit

        mutating func emit(_ m: PatchModule) throws {
            let before = params.count
            switch m.kind {
            case "in":
                set(m, PatchProgram.inSlot)
            case "out":
                break // read at the end, after every source is in place
            case "clock":
                set(m, port: "beat", PatchProgram.beatSlot); set(m, port: "bar", PatchProgram.barSlot); set(m, port: "tempo", PatchProgram.tempoSlot)
            case "knob", "toggle":
                guard let p = PatchModules.ownParam(m) else { throw fail(m.id, "not a knob") }
                params.append(p)
                let s = c.slot()
                let isNote = m.kind == "knob" && m.settings["unit"] == "note"
                paramSlots.append(PatchParamSlot(key: p.key, slot: s, isNote: isNote))
                set(m, s)
                group(m, keys: [p.key])
                return
            case "meter":
                let v = try input(m, PatchModules.audioIn)
                guard meters.count < DSPMeterCount else { throw fail(m.id, "a patch shows at most \(DSPMeterCount) meters") }
                meters.append((v.slot, meters.count))
                meterNames.append(PatchModules.label(m))
            case "const":
                set(m, c.constant(m.values["value"] ?? 1))
            case "osc":
                let v = try inputs(m)
                set(m, c.emit(.osc, try c.convert(v[0], to: .hz, what: "osc"), k: shape(m), state: c.state(2)))
            case "lfo":
                let v = try inputs(m)
                set(m, c.emit(.lfo, try c.convert(v[0], to: .hz, what: "lfo"), k: shape(m), state: c.state(2)))
            case "lfosync":
                let v = try inputs(m)
                set(m, c.emit(.lfoSync, v[0].slot, k: shape(m)))
            case "phase":
                let v = try inputs(m)
                set(m, c.emit(.phase, v[0].slot))
            case "noise":
                set(m, c.emit(.noise, -1, state: c.state(1)))
            case "lp", "hp", "bp":
                let v = try inputs(m)
                let k: Float = m.kind == "lp" ? 0 : (m.kind == "hp" ? 1 : 2)
                set(m, c.emit(.svf, v[0].slot, try c.convert(v[1], to: .hz, what: m.kind), v[2].slot, k: k, state: c.state(6)))
            case "slew", "follow":
                let v = try inputs(m)
                set(m, c.emit(m.kind == "slew" ? .slew : .follow, v[0].slot, v[1].slot, v[2].slot, state: c.state(m.kind == "slew" ? 2 : 6)))
            case "sah":
                let v = try inputs(m)
                set(m, c.emit(.sah, v[0].slot, v[1].slot, state: c.state(4)))
            case "tanh", "neg", "abs", "sqrt", "sin", "exp", "log", "floor":
                let v = try inputs(m)
                let code: PatchOpCode = [.tanh, .neg, .abs, .sqrt, .sin, .exp, .log, .floor][["tanh", "neg", "abs", "sqrt", "sin", "exp", "log", "floor"].firstIndex(of: m.kind)!]
                set(m, c.emit(code, v[0].slot))
            case "clip":
                let v = try inputs(m)
                set(m, c.emit(.clip, v[0].slot, v[1].slot, v[2].slot))
            case "delay", "delaysync":
                let v = try inputs(m)
                let seconds = m.kind == "delay" ? v[1].slot : c.emit(.mul, v[1].slot, PatchProgram.quarterSecondsSlot)
                let length = Swift.max(0.01, Swift.min(60, m.values["length"] ?? (m.kind == "delay" ? 2 : 8)))
                let b = c.buffers.count
                c.buffers.append(PatchBuffer(name: m.id, seconds: length))
                let read = c.emit(.delayRead, seconds, buffer: b)
                c.ops.append(PatchOp(.delayWrite, a: c.emit(.add, v[0].slot, c.emit(.mul, read, v[2].slot)), buffer: b))
                set(m, read)
            case "add", "sub", "mul", "div", "min", "max", "pow", "gt", "lt":
                let v = try inputs(m)
                let codes: [String: PatchOpCode] = ["add": .add, "sub": .sub, "mul": .mul, "div": .div, "min": .min, "max": .max, "pow": .pow, "gt": .gt, "lt": .lt]
                set(m, c.emit(codes[m.kind]!, v[0].slot, v[1].slot))
            case "mix":
                let v = try inputs(m)
                set(m, c.emit(.mix, v[0].slot, v[1].slot, v[2].slot))
            case "gain":
                let v = try inputs(m)
                set(m, c.emit(.mul, v[0].slot, c.emit(.dbToGain, v[1].slot)))
            case "scale":
                // out = lo + (in - from) / (to - from) * (hi - lo)
                let v = try inputs(m)
                let span = c.emit(.sub, v[2].slot, v[1].slot)
                let t = c.emit(.div, c.emit(.sub, v[0].slot, v[1].slot), span)
                set(m, c.emit(.add, v[3].slot, c.emit(.mul, t, c.emit(.sub, v[4].slot, v[3].slot))))
            case "script":
                try emitScript(m)
            default:
                throw fail(m.id, "unknown module kind '\(m.kind)'")
            }
            group(m, keys: params[before...].map(\.key))
        }

        /// A Script compiles into the same op list: its input and params bound to the cables and knobs here.
        mutating func emitScript(_ m: PatchModule) throws {
            let text = m.source ?? ""
            let shape: PatchCompiler.Shape
            let lines: [(PatchLine, Int)]
            do {
                shape = try PatchCompiler.shape(of: text)
                var parser = try PatchParser(text)
                lines = try parser.parse()
            } catch let e as PatchError { throw PatchError(line: e.line, e.message, module: m.id) }
            var bindings: [String: Value] = [:]
            for port in ports[m.id]?.inputs ?? [] {
                let v = try input(m, port)
                // The text compiler applies the ms factor itself; it gets the raw slot and the unit it expects.
                bindings[port.name] = port.unit == "ms" ? Value(slot: c.emit(.mul, v.slot, c.constant(1000)), unit: .plain) : v
            }
            var inner = PatchCompiler.Context(source: text)
            inner.embedded = true
            inner.prefix = m.id + "/"
            inner.bindings = bindings
            inner.ops = c.ops; inner.slots = c.slots; inner.states = c.states; inner.buffers = c.buffers; inner.latches = c.latches
            let out: Int
            do { out = try inner.assemble(lines) } catch let e as PatchError { throw PatchError(line: e.line, e.message, module: m.id) }
            c.ops = inner.ops; c.slots = inner.slots; c.states = inner.states; c.buffers = inner.buffers; c.latches = inner.latches
            set(m, port: shape.output ?? "out", out)
            for (name, slot) in inner.meterSlots {
                guard meters.count < DSPMeterCount else { throw fail(m.id, "a patch shows at most \(DSPMeterCount) meters") }
                meters.append((slot, meters.count))
                meterNames.append(name)
            }
        }
    }
}

public extension PatchGraphCompiler {
    /// The cables that close a loop in a document: the ones that get one frame of delay. The canvas marks them.
    static func feedback(in doc: PatchDocument) -> Set<PatchCable> {
        var g = Graph(doc: doc, source: "")
        for m in doc.modules { g.ports[m.id] = PatchModules.ports(of: m) }
        _ = try? g.ordered()
        return g.feedback
    }
}
