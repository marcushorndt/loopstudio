import Foundation

/// The modular patch (`docs/patcher.md`): modules with typed ports, cables between them, and which modules
/// show on the device's panel. Stored as JSON in `DeviceSlot.source`; a stage 1 text (`patch "…"`) loads as a
/// document with one Script module (`PatchDocument(text:)`). Edits go through `PatchEdit`, shared by the
/// editor and the MCP tool.
public struct PatchDocument: Codable, Hashable, Sendable {
    public static let currentVersion = 2

    public var version: Int = PatchDocument.currentVersion
    public var name: String
    public var modules: [PatchModule]
    public var cables: [PatchCable]
    /// The patch inside a Sub module: Inlets and Outlets are its ports, in place of Audio In and Audio Out.
    public var isSub: Bool?

    public init(name: String = "Patch", modules: [PatchModule] = [], cables: [PatchCable] = [], isSub: Bool? = nil) {
        self.name = name
        self.modules = modules
        self.cables = cables
        self.isSub = isSub
    }

    public var isSubPatch: Bool { isSub == true }

    /// A stage 1 text as a document: Audio In, one Script, Audio Out, wired through. The Script is on the panel,
    /// so the knobs of the text stay the knobs of the device.
    public init(text: String) {
        let shape = try? PatchCompiler.shape(of: text)
        name = shape?.name ?? "Patch"
        modules = [
            PatchModule(id: "in", kind: "in", x: 40, y: 120),
            PatchModule(id: "script", kind: "script", x: 220, y: 100, source: text, panel: PatchPanelItem(column: 0)),
            PatchModule(id: "out", kind: "out", x: 460, y: 120),
        ]
        // A text that does not parse keeps the kind's ports (in, out) until it is fixed.
        cables = [PatchCable(from: "in", fromPort: "out", to: "script", toPort: shape?.input ?? "in"),
                  PatchCable(from: "script", fromPort: shape?.output ?? "out", to: "out", toPort: "in")]
    }

    /// The starter of a new device: in, one Script with the starter text, out.
    public static var starter: PatchDocument { PatchDocument(text: PatchExamples.starter) }

    /// A source string is a document when it starts with `{`. Else it is a stage 1 text.
    public static func isDocument(_ source: String) -> Bool {
        source.first { !$0.isWhitespace } == "{"
    }

    /// The document of a source string: parsed, or a stage 1 text wrapped. `nil` for a document that does not parse.
    public static func parse(_ source: String) -> PatchDocument? {
        guard isDocument(source) else { return PatchDocument(text: source) }
        guard let data = source.data(using: .utf8), var doc = try? JSONDecoder().decode(PatchDocument.self, from: data) else { return nil }
        if doc.version > currentVersion { return nil }
        doc.version = currentVersion
        return doc
    }

    /// The document as the string the slot stores. Keys are sorted, so the same document gives the same text
    /// (the compiler caches by text).
    public var source: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    public func module(_ id: String) -> PatchModule? { modules.first { $0.id == id } }

    /// The cables into one port of one module, in the order they were made.
    public func cables(into module: String, port: String) -> [PatchCable] {
        cables.filter { $0.to == module && $0.toPort == port }
    }

    /// A free module id for a kind: the kind name with the first free number (`osc1`, `osc2`).
    public func freeID(for kind: String) -> String {
        let base = kind.filter { $0.isLetter || $0.isNumber }
        var n = 1
        while modules.contains(where: { $0.id == "\(base)\(n)" }) { n += 1 }
        return "\(base)\(n)"
    }
}

public struct PatchModule: Codable, Hashable, Sendable, Identifiable {
    /// Short and unique in the document. It is also the key of the module's knobs (`id.port`).
    public var id: String
    /// A `ModuleSpec` id: `osc`, `lp`, `knob`, `script`, `in`, `out`, …
    public var kind: String
    /// The name shown. `nil`: the kind's name.
    public var label: String?
    /// Position on the canvas.
    public var x: Double
    public var y: Double
    /// Values of the control inputs that have no cable, and numeric settings (a knob's `min`, `max`, `def`,
    /// `log`; a delay's `length`). A note value port stores the index into `NoteDivision.all`.
    public var values: [String: Double]
    /// Text settings: `shape`, `unit`, a note value name.
    public var settings: [String: String]
    /// A Script module's text.
    public var source: String?
    /// On the device's panel (the card), with its place there. `nil`: only in the editor.
    public var panel: PatchPanelItem?
    /// A Sub module's patch: its Inlets and Outlets are the module's ports.
    public var sub: PatchDocument?

    public init(id: String, kind: String, label: String? = nil, x: Double, y: Double, values: [String: Double] = [:],
                settings: [String: String] = [:], source: String? = nil, panel: PatchPanelItem? = nil, sub: PatchDocument? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
        self.x = x
        self.y = y
        self.values = values
        self.settings = settings
        self.source = source
        self.panel = panel
        self.sub = sub
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        values = try c.decodeIfPresent([String: Double].self, forKey: .values) ?? [:]
        settings = try c.decodeIfPresent([String: String].self, forKey: .settings) ?? [:]
        source = try c.decodeIfPresent(String.self, forKey: .source)
        panel = try c.decodeIfPresent(PatchPanelItem.self, forKey: .panel)
        sub = try c.decodeIfPresent(PatchDocument.self, forKey: .sub)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        if !values.isEmpty { try c.encode(values, forKey: .values) }
        if !settings.isEmpty { try c.encode(settings, forKey: .settings) }
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(panel, forKey: .panel)
        try c.encodeIfPresent(sub, forKey: .sub)
    }

    enum CodingKeys: String, CodingKey { case id, kind, label, x, y, values, settings, source, panel, sub }

    public var isOnPanel: Bool { panel != nil }
}

/// Where a module's knobs sit on the panel: the column from 0, left to right. Rows come in stage 3 with the displays.
public struct PatchPanelItem: Codable, Hashable, Sendable {
    public var column: Int
    public init(column: Int) { self.column = column }
}

public struct PatchCable: Codable, Hashable, Sendable {
    public var from: String
    public var fromPort: String
    public var to: String
    public var toPort: String

    public init(from: String, fromPort: String, to: String, toPort: String) {
        self.from = from
        self.fromPort = fromPort
        self.to = to
        self.toPort = toPort
    }
}

// MARK: Edits

/// One step of editing a document. The editor and the MCP `patch_edit` tool apply the same steps, so what an
/// agent can do, the pointer can do, and the other way round.
public indirect enum PatchEdit: Hashable, Sendable {
    case rename(String)
    case add(kind: String, id: String?, x: Double, y: Double)
    case remove(id: String)
    case move(id: String, x: Double, y: Double)
    case connect(from: String, fromPort: String, to: String, toPort: String)
    case disconnect(from: String, fromPort: String, to: String, toPort: String)
    case setValue(id: String, key: String, value: Double)
    case setSetting(id: String, key: String, value: String)
    case setSource(id: String, source: String)
    case setLabel(id: String, label: String?)
    case expose(id: String, on: Bool)
    /// The modules become one Sub module at their place. Cables that cross its edge become its Inlets and
    /// Outlets, named after the inner ports they reach.
    case group(ids: [String], id: String?)
    /// The modules of a Sub come back to the canvas; its Inlets and Outlets splice into cables.
    case ungroup(id: String)
    /// A step inside a Sub module's patch. A renamed Inlet or Outlet keeps its cables outside.
    case inside(id: String, edit: PatchEdit)
    /// The whole patch inside a Sub module (from the library).
    case setSub(id: String, document: PatchDocument)
}

public struct PatchEditError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ d: String) { description = d }
}

public extension PatchDocument {
    /// Applies one step. Throws with a plain sentence when the step cannot be done; the document is then unchanged.
    mutating func apply(_ edit: PatchEdit) throws {
        switch edit {
        case .rename(let n):
            name = n.trimmingCharacters(in: .whitespaces).isEmpty ? "Patch" : n
        case .add(let kind, let id, let x, let y):
            guard let spec = PatchModules.spec(kind) else { throw PatchEditError("no module kind '\(kind)'; patch_modules lists them") }
            let newID = id ?? freeID(for: kind == "subpatch" ? "sub" : kind)
            guard !newID.isEmpty, newID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { throw PatchEditError("an id has letters, digits and _ only") }
            guard module(newID) == nil else { throw PatchEditError("there is a module '\(newID)' already") }
            if spec.single, modules.contains(where: { $0.kind == kind }) { throw PatchEditError("a patch has one \(spec.name) module") }
            if isSubPatch, kind == "in" || kind == "out" { throw PatchEditError("inside a Sub, an Inlet stands for Audio In and an Outlet for Audio Out") }
            if !isSubPatch, kind == "inlet" || kind == "outlet" { throw PatchEditError("an Inlet or an Outlet belongs inside a Sub; the device has Audio In and Audio Out") }
            var m = PatchModule(id: newID, kind: kind, x: x, y: y)
            if kind == "subpatch" { m.sub = PatchDocument(name: "Sub", isSub: true) }
            if kind == "script" { m.source = PatchExamples.scriptStarter; m.panel = PatchPanelItem(column: nextColumn) }
            if kind == "knob" { m.panel = PatchPanelItem(column: nextColumn) }
            if kind == "meter" { m.panel = PatchPanelItem(column: nextColumn) }
            for s in spec.settings { m.settings[s.key] = s.def }
            for (k, v) in spec.numbers { m.values[k] = v }
            modules.append(m)
        case .remove(let id):
            guard let i = modules.firstIndex(where: { $0.id == id }) else { throw PatchEditError("no module '\(id)'") }
            modules.remove(at: i)
            cables.removeAll { $0.from == id || $0.to == id }
        case .move(let id, let x, let y):
            guard let i = modules.firstIndex(where: { $0.id == id }) else { throw PatchEditError("no module '\(id)'") }
            modules[i].x = x; modules[i].y = y
        case .connect(let from, let fromPort, let to, let toPort):
            guard let a = module(from) else { throw PatchEditError("no module '\(from)'") }
            guard let b = module(to) else { throw PatchEditError("no module '\(to)'") }
            guard let out = PatchModules.ports(of: a).outputs.first(where: { $0.name == fromPort }) else {
                throw PatchEditError("'\(from)' has no output '\(fromPort)'; its outputs: \(PatchModules.ports(of: a).outputs.map(\.name).joined(separator: ", "))")
            }
            guard let inp = PatchModules.ports(of: b).inputs.first(where: { $0.name == toPort }) else {
                throw PatchEditError("'\(to)' has no input '\(toPort)'; its inputs: \(PatchModules.ports(of: b).inputs.map(\.name).joined(separator: ", "))")
            }
            guard PortType.connects(out.type, to: inp.type) else { throw PatchEditError("\(out.type.rawValue) does not go into \(inp.type.rawValue) (\(from).\(fromPort) to \(to).\(toPort)); put a follow or sah module between") }
            guard from != to else { throw PatchEditError("a module does not connect to itself") }
            let cable = PatchCable(from: from, fromPort: fromPort, to: to, toPort: toPort)
            guard !cables.contains(cable) else { return }
            cables.append(cable)
        case .disconnect(let from, let fromPort, let to, let toPort):
            let cable = PatchCable(from: from, fromPort: fromPort, to: to, toPort: toPort)
            guard let i = cables.firstIndex(of: cable) else { throw PatchEditError("no cable \(from).\(fromPort) to \(to).\(toPort)") }
            cables.remove(at: i)
        case .setValue(let id, let key, let value):
            guard let i = modules.firstIndex(where: { $0.id == id }) else { throw PatchEditError("no module '\(id)'") }
            guard value.isFinite else { throw PatchEditError("a value is a finite number") }
            modules[i].values[key] = value
        case .setSetting(let id, let key, let value):
            guard let i = modules.firstIndex(where: { $0.id == id }) else { throw PatchEditError("no module '\(id)'") }
            if let s = PatchModules.spec(modules[i].kind)?.settings.first(where: { $0.key == key }), !s.choices.isEmpty, !s.choices.contains(value) {
                throw PatchEditError("\(key) is one of \(s.choices.joined(separator: ", "))")
            }
            modules[i].settings[key] = value
        case .setSource(let id, let source):
            guard let i = modules.firstIndex(where: { $0.id == id }) else { throw PatchEditError("no module '\(id)'") }
            guard modules[i].kind == "script" else { throw PatchEditError("'\(id)' is not a Script module") }
            modules[i].source = source
            // Ports that are gone take their cables with them.
            let ports = PatchModules.ports(of: modules[i])
            let inputs = Set(ports.inputs.map(\.name)), outputs = Set(ports.outputs.map(\.name))
            cables.removeAll { ($0.to == id && !inputs.contains($0.toPort)) || ($0.from == id && !outputs.contains($0.fromPort)) }
        case .setLabel(let id, let label):
            guard let i = modules.firstIndex(where: { $0.id == id }) else { throw PatchEditError("no module '\(id)'") }
            modules[i].label = label?.trimmingCharacters(in: .whitespaces).isEmpty == false ? label : nil
        case .expose(let id, let on):
            guard let i = modules.firstIndex(where: { $0.id == id }) else { throw PatchEditError("no module '\(id)'") }
            if on { if modules[i].panel == nil { modules[i].panel = PatchPanelItem(column: nextColumn) } } else { modules[i].panel = nil }
        case .group(let ids, let id):
            try group(ids, as: id)
        case .ungroup(let id):
            try ungroup(id)
        case .inside(let id, let edit):
            guard let i = modules.firstIndex(where: { $0.id == id }), var inner = modules[i].sub else { throw PatchEditError("'\(id)' is not a Sub module") }
            let before = PatchModules.subPortNames(inner)
            try inner.apply(edit)
            modules[i].sub = inner
            reconcileCables(of: id, before: before, after: PatchModules.subPortNames(inner))
        case .setSub(let id, let document):
            guard let i = modules.firstIndex(where: { $0.id == id }), modules[i].kind == "subpatch" else { throw PatchEditError("'\(id)' is not a Sub module") }
            let before = PatchModules.subPortNames(modules[i].sub ?? PatchDocument())
            var inner = document
            inner.isSub = true
            modules[i].sub = inner
            reconcileCables(of: id, before: before, after: PatchModules.subPortNames(inner))
        }
    }

    /// Marked modules into one Sub. Every cable from outside into a member becomes an Inlet (one per inner
    /// port reached), every cable from a member to the outside an Outlet (one per inner port). Cables
    /// among the members move inside. The Sub sits where the top left member was.
    private mutating func group(_ ids: [String], as id: String?) throws {
        let set = Set(ids)
        let members = modules.filter { set.contains($0.id) }
        guard !members.isEmpty else { throw PatchEditError("mark the modules to group") }
        guard members.count == set.count else { throw PatchEditError("a module to group is not in the patch") }
        if let fixed = members.first(where: { ["in", "out", "inlet", "outlet"].contains($0.kind) }) {
            throw PatchEditError("\(PatchModules.label(fixed)) is a port of this patch; it does not go into a Sub")
        }
        let newID = id ?? freeID(for: "sub")
        guard !newID.isEmpty, newID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { throw PatchEditError("an id has letters, digits and _ only") }
        guard module(newID) == nil else { throw PatchEditError("there is a module '\(newID)' already") }
        let minX = members.map(\.x).min()!, minY = members.map(\.y).min()!
        var inner = PatchDocument(name: "Sub", isSub: true)
        inner.modules = members.map { m in var c = m; c.x = m.x - minX + 200; c.y = m.y - minY + 40; return c }
        inner.cables = cables.filter { set.contains($0.from) && set.contains($0.to) }
        var outer = cables.filter { !set.contains($0.from) && !set.contains($0.to) }
        var taken = Set<String>()
        func portName(_ wanted: String, _ module: String) -> String {
            let base = taken.contains(wanted) ? "\(module)_\(wanted)" : wanted
            var name = base, n = 2
            while taken.contains(name) { name = "\(base)\(n)"; n += 1 }
            taken.insert(name)
            return name
        }
        var inlets: [String: String] = [:]
        for cable in cables where !set.contains(cable.from) && set.contains(cable.to) {
            let key = "\(cable.to).\(cable.toPort)"
            if inlets[key] == nil {
                let name = portName(cable.toPort, cable.to)
                let inletID = inner.freeID(for: "inlet")
                var inlet = PatchModule(id: inletID, kind: "inlet", label: name, x: 20, y: 40 + Double(inlets.count) * 44)
                // The inner port's range and value become the Inlet's: the knob when the Sub is on the panel.
                if let target = module(cable.to), let port = PatchModules.ports(of: target).inputs.first(where: { $0.name == cable.toPort }) {
                    inlet.values = ["min": port.min, "max": port.max, "def": target.values[port.name] ?? port.def]
                    if port.log { inlet.values["log"] = 1 }
                    if !port.unit.isEmpty { inlet.settings["unit"] = port.unit }
                }
                inner.modules.append(inlet)
                inner.cables.append(PatchCable(from: inletID, fromPort: "out", to: cable.to, toPort: cable.toPort))
                inlets[key] = name
            }
            let c = PatchCable(from: cable.from, fromPort: cable.fromPort, to: newID, toPort: inlets[key]!)
            if !outer.contains(c) { outer.append(c) }
        }
        taken = []
        var outlets: [String: String] = [:]
        let outletX = (inner.modules.map(\.x).max() ?? 200) + 200
        for cable in cables where set.contains(cable.from) && !set.contains(cable.to) {
            let key = "\(cable.from).\(cable.fromPort)"
            if outlets[key] == nil {
                let name = portName(cable.fromPort, cable.from)
                let outletID = inner.freeID(for: "outlet")
                inner.modules.append(PatchModule(id: outletID, kind: "outlet", label: name, x: outletX, y: 40 + Double(outlets.count) * 44))
                inner.cables.append(PatchCable(from: cable.from, fromPort: cable.fromPort, to: outletID, toPort: "in"))
                outlets[key] = name
            }
            let c = PatchCable(from: newID, fromPort: outlets[key]!, to: cable.to, toPort: cable.toPort)
            if !outer.contains(c) { outer.append(c) }
        }
        modules.removeAll { set.contains($0.id) }
        modules.append(PatchModule(id: newID, kind: "subpatch", x: minX, y: minY, sub: inner))
        cables = outer
    }

    /// The inverse of `group`: the inner modules come out at the Sub's place (renamed where an id is taken),
    /// the Inlets and Outlets splice the cables outside to the cables inside.
    private mutating func ungroup(_ id: String) throws {
        guard let i = modules.firstIndex(where: { $0.id == id }), let inner = modules[i].sub else { throw PatchEditError("'\(id)' is not a Sub module") }
        let sub = modules[i]
        let names = PatchModules.subPortNames(inner)
        var outerIDs = Set(modules.map(\.id))
        outerIDs.remove(id)
        let plain = inner.modules.filter { $0.kind != "inlet" && $0.kind != "outlet" }
        var rename: [String: String] = [:]
        for m in plain {
            var newID = m.id, n = 2
            while outerIDs.contains(newID) { newID = "\(m.id)\(n)"; n += 1 }
            outerIDs.insert(newID)
            rename[m.id] = newID
        }
        let minX = plain.map(\.x).min() ?? 0, minY = plain.map(\.y).min() ?? 0
        let added = plain.map { m in var c = m; c.id = rename[m.id]!; c.x = sub.x + m.x - minX; c.y = sub.y + m.y - minY; return c }
        var spliced: [PatchCable] = inner.cables.compactMap { c in
            guard let f = rename[c.from], let t = rename[c.to] else { return nil }
            return PatchCable(from: f, fromPort: c.fromPort, to: t, toPort: c.toPort)
        }
        func outerTargets(ofOutlet outlet: String) -> [PatchCable] {
            guard let name = names.outlets[outlet] else { return [] }
            return cables.filter { $0.from == id && $0.fromPort == name }
        }
        for inlet in inner.modules where inlet.kind == "inlet" {
            guard let name = names.inlets[inlet.id] else { continue }
            let sources = cables.filter { $0.to == id && $0.toPort == name }
            for t in inner.cables where t.from == inlet.id {
                for s in sources {
                    if let tt = rename[t.to] {
                        spliced.append(PatchCable(from: s.from, fromPort: s.fromPort, to: tt, toPort: t.toPort))
                    } else {
                        // Straight through an Outlet: the sources outside meet the targets outside.
                        for o in outerTargets(ofOutlet: t.to) { spliced.append(PatchCable(from: s.from, fromPort: s.fromPort, to: o.to, toPort: o.toPort)) }
                    }
                }
            }
        }
        for outlet in inner.modules where outlet.kind == "outlet" {
            let targets = outerTargets(ofOutlet: outlet.id)
            for s in inner.cables where s.to == outlet.id {
                guard let ss = rename[s.from] else { continue }
                for t in targets { spliced.append(PatchCable(from: ss, fromPort: s.fromPort, to: t.to, toPort: t.toPort)) }
            }
        }
        modules.remove(at: i)
        modules += added
        cables.removeAll { $0.from == id || $0.to == id }
        for c in spliced where !cables.contains(c) && c.from != c.to { cables.append(c) }
    }

    /// After a change inside a Sub: a renamed port keeps its cables outside, a port that is gone takes them.
    private mutating func reconcileCables(of id: String, before: PatchModules.SubPortNames, after: PatchModules.SubPortNames) {
        cables = cables.compactMap { cable in
            var c = cable
            if c.to == id {
                guard let inlet = before.inlets.first(where: { $0.value == c.toPort })?.key, let name = after.inlets[inlet] else { return nil }
                c.toPort = name
            }
            if c.from == id {
                guard let outlet = before.outlets.first(where: { $0.value == c.fromPort })?.key, let name = after.outlets[outlet] else { return nil }
                c.fromPort = name
            }
            return c
        }
    }

    /// The patch at a path of Sub ids, from this document down. Empty: this document.
    func document(at path: [String]) -> PatchDocument? {
        guard let first = path.first else { return self }
        return module(first)?.sub?.document(at: Array(path.dropFirst()))
    }

    /// An edit wrapped for a path of Sub ids: the innermost first.
    static func edit(_ edit: PatchEdit, at path: [String]) -> PatchEdit {
        path.reversed().reduce(edit) { .inside(id: $1, edit: $0) }
    }

    /// The next free panel column: after the last used one.
    var nextColumn: Int { (modules.compactMap { $0.panel?.column }.max() ?? -1) + 1 }

    /// The modules on the panel, left to right.
    var panelModules: [PatchModule] {
        modules.filter(\.isOnPanel).sorted { ($0.panel!.column, $0.id) < ($1.panel!.column, $1.id) }
    }
}
