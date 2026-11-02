import Foundation

// MARK: Racks
//
// A rack is a device that holds parallel chains of devices, like Live's Audio Effect Rack and Instrument
// Rack. The track's signal goes into every chain, the chains' outputs are summed. Eight macro knobs on the
// rack drive parameters inside it through mappings with a range and a curve. A chain selector (0...127)
// picks which chains sound: every chain has a zone on that strip, with fades at its edges. A MIDI rack
// routes notes into its chains by key and velocity zones as well; the first instrument in a chain plays them.
// Racks nest: a chain can hold another rack.
//
// A rack is a `DeviceSlot` with format "builtin", identifier "audiorack" or "midirack", and `rack` set.
// Its macros and the selector are ordinary parameters of that slot ("macro1"..."macro8", "selector"), so
// automation, MIDI mapping, undo and the MCP tools reach them like any knob.

public enum ChainTag {}
public typealias ChainID = ID<ChainTag>

/// A span on a 0...127 strip, with a fade at each edge that lies inside the span. Full level between
/// `low + fadeLow` and `high - fadeHigh`; zero outside `low...high`.
public struct ChainZone: Hashable, Codable, Sendable {
    public var low: Int
    public var high: Int
    public var fadeLow: Int
    public var fadeHigh: Int

    public static let full = ChainZone(low: 0, high: 127)

    public init(low: Int, high: Int, fadeLow: Int = 0, fadeHigh: Int = 0) {
        self.low = low
        self.high = high
        self.fadeLow = fadeLow
        self.fadeHigh = fadeHigh
    }

    /// The zone with every value inside the strip and the fades inside the span.
    public var normalized: ChainZone {
        var z = self
        z.low = min(max(z.low, 0), 127)
        z.high = min(max(z.high, z.low), 127)
        let span = z.high - z.low
        z.fadeLow = min(max(z.fadeLow, 0), span)
        z.fadeHigh = min(max(z.fadeHigh, 0), span - z.fadeLow)
        return z
    }

    /// The level at a position on the strip, 0...1.
    public func gain(at position: Double) -> Double {
        let z = normalized
        let lo = Double(z.low), hi = Double(z.high)
        guard position >= lo, position <= hi else { return 0 }
        var g = 1.0
        if z.fadeLow > 0, position < lo + Double(z.fadeLow) { g = min(g, (position - lo) / Double(z.fadeLow)) }
        if z.fadeHigh > 0, position > hi - Double(z.fadeHigh) { g = min(g, (hi - position) / Double(z.fadeHigh)) }
        return min(max(g, 0), 1)
    }

    public func contains(_ value: Int) -> Bool { value >= normalized.low && value <= normalized.high }
}

/// One parallel path inside a rack. The chain's mixer (volume, pan, mute, solo) sits after its devices.
public struct RackChain: Hashable, Codable, Sendable, Identifiable {
    public var id: ChainID
    public var name: String
    public var colorIndex: Int
    public var devices: [DeviceSlot]
    public var volumeDb: Double
    public var pan: Double
    public var mute: Bool
    public var solo: Bool
    /// Where on the chain selector strip this chain sounds.
    public var zone: ChainZone
    /// MIDI racks: the keys this chain plays. Notes outside it skip the chain. `nil`: every key.
    public var keyZone: ChainZone?
    /// MIDI racks: the velocities this chain plays. `nil`: every velocity.
    public var velocityZone: ChainZone?

    public init(id: ChainID = ChainID(), name: String, colorIndex: Int = 0, devices: [DeviceSlot] = [],
                volumeDb: Double = 0, pan: Double = 0, mute: Bool = false, solo: Bool = false,
                zone: ChainZone = .full, keyZone: ChainZone? = nil, velocityZone: ChainZone? = nil) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.devices = devices
        self.volumeDb = volumeDb
        self.pan = pan
        self.mute = mute
        self.solo = solo
        self.zone = zone
        self.keyZone = keyZone
        self.velocityZone = velocityZone
    }

    enum CodingKeys: String, CodingKey { case id, name, colorIndex, devices, volumeDb, pan, mute, solo, zone, keyZone, velocityZone }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ChainID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Chain"
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        devices = try c.decodeIfPresent([DeviceSlot].self, forKey: .devices) ?? []
        volumeDb = try c.decodeIfPresent(Double.self, forKey: .volumeDb) ?? 0
        pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        mute = try c.decodeIfPresent(Bool.self, forKey: .mute) ?? false
        solo = try c.decodeIfPresent(Bool.self, forKey: .solo) ?? false
        zone = (try c.decodeIfPresent(ChainZone.self, forKey: .zone) ?? .full).normalized
        keyZone = try c.decodeIfPresent(ChainZone.self, forKey: .keyZone)?.normalized
        velocityZone = try c.decodeIfPresent(ChainZone.self, forKey: .velocityZone)?.normalized
    }

    /// The range of this chain's volume, like a track's.
    public static let volumeRange: ClosedRange<Double> = -60...6
}

/// One macro knob driving one parameter inside the rack. `min` and `max` are positions (0...1) on the
/// target's own range, so the mapping is unit free; `max` below `min` inverts it. `curve` bends the response:
/// 0 is straight, towards 1 the knob starts slow, towards -1 it starts fast.
public struct MacroMapping: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var macro: Int
    /// A device parameter (node: the device, any depth), a chain's "volume" or "pan" (node: the chain),
    /// or this rack's "selector" (node: the rack).
    public var target: ParameterAddress
    public var min: Double
    public var max: Double
    public var curve: Double

    public init(id: UUID = UUID(), macro: Int, target: ParameterAddress, min: Double = 0, max: Double = 1, curve: Double = 0) {
        self.id = id
        self.macro = macro
        self.target = target
        self.min = min
        self.max = max
        self.curve = curve
    }

    /// The target position for a macro value (0...127).
    public func position(forMacro value: Double) -> Double {
        let q = Swift.min(Swift.max(value / 127, 0), 1)
        return min + (max - min) * MacroMapping.shape(q, curve: curve)
    }

    /// The response shape: an exponent between 1/4 and 4.
    public static func shape(_ q: Double, curve: Double) -> Double {
        let c = Swift.min(Swift.max(curve, -1), 1)
        if abs(c) < 0.001 { return q }
        let e = c > 0 ? 1 + 3 * c : 1 / (1 + 3 * -c)
        return pow(q, e)
    }
}

public struct Rack: Hashable, Codable, Sendable {
    public static let macroCount = 8

    public var chains: [RackChain]
    /// The name under each macro knob. Empty: "Macro n".
    public var macroNames: [String]
    public var mappings: [MacroMapping]
    /// View state, saved with the project: which panels the rack card shows.
    public var showsMacros: Bool
    public var showsChains: Bool

    public init(chains: [RackChain] = [], macroNames: [String] = [], mappings: [MacroMapping] = [],
                showsMacros: Bool = true, showsChains: Bool = true) {
        self.chains = chains
        self.macroNames = macroNames
        self.mappings = mappings
        self.showsMacros = showsMacros
        self.showsChains = showsChains
    }

    enum CodingKeys: String, CodingKey { case chains, macroNames, mappings, showsMacros, showsChains }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chains = try c.decodeIfPresent([RackChain].self, forKey: .chains) ?? []
        macroNames = try c.decodeIfPresent([String].self, forKey: .macroNames) ?? []
        mappings = try c.decodeIfPresent([MacroMapping].self, forKey: .mappings) ?? []
        showsMacros = try c.decodeIfPresent(Bool.self, forKey: .showsMacros) ?? true
        showsChains = try c.decodeIfPresent(Bool.self, forKey: .showsChains) ?? true
    }

    public func macroName(_ index: Int) -> String {
        index < macroNames.count && !macroNames[index].isEmpty ? macroNames[index] : "Macro \(index + 1)"
    }

    public func chain(_ id: ChainID) -> RackChain? { chains.first { $0.id == id } }

    /// Zones that split the strip evenly among the chains, in order, with `fade` positions of overlap at
    /// each inner edge. The way to set a selector up in one click.
    public static func distributedZones(count: Int, fade: Int = 0) -> [ChainZone] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            let low = i * 128 / count, high = (i + 1) * 128 / count - 1
            let f = min(max(fade, 0), max(0, (high - low) / 2))
            return ChainZone(low: low, high: high, fadeLow: i == 0 ? 0 : f, fadeHigh: i == count - 1 ? 0 : f).normalized
        }
    }
}

// MARK: Devices at every depth

public extension DeviceSlot {
    /// A rack: a device that holds chains.
    var isRack: Bool { rack != nil }
    /// A rack that routes notes to its chains and plays like an instrument.
    var isMIDIRack: Bool { rack != nil && identifier == "midirack" }

    /// This device and, for a rack, every device inside it, depth first, in chain order.
    var selfAndNested: [DeviceSlot] {
        var list = [self]
        for chain in rack?.chains ?? [] { for d in chain.devices { list += d.selfAndNested } }
        return list
    }

    /// A copy with new IDs for itself, its chains and everything inside. `map` records old to new UUIDs of
    /// devices and chains, so automation can follow.
    func withFreshIDs(map: inout [UUID: UUID]) -> DeviceSlot {
        var copy = self
        copy.id = DeviceID()
        map[id.rawValue] = copy.id.rawValue
        if var rack = copy.rack {
            rack.chains = rack.chains.map { chain in
                var c = chain
                c.id = ChainID()
                map[chain.id.rawValue] = c.id.rawValue
                c.devices = chain.devices.map { $0.withFreshIDs(map: &map) }
                return c
            }
            rack.mappings = rack.mappings.map { m in
                var m = m
                m.id = UUID()
                m.target.node = map[m.target.node] ?? m.target.node
                return m
            }
            copy.rack = rack
        }
        return copy
    }

    /// Finds a device inside this one (not this one itself).
    func nestedDevice(_ id: DeviceID) -> DeviceSlot? {
        for chain in rack?.chains ?? [] {
            for d in chain.devices {
                if d.id == id { return d }
                if let found = d.nestedDevice(id) { return found }
            }
        }
        return nil
    }

    /// Changes a device inside this one. Returns false when it is not here.
    mutating func withNestedDevice(_ id: DeviceID, _ body: (inout DeviceSlot) throws -> Void) rethrows -> Bool {
        guard var rack else { return false }
        defer { self.rack = rack }
        for c in rack.chains.indices {
            for d in rack.chains[c].devices.indices {
                if rack.chains[c].devices[d].id == id { try body(&rack.chains[c].devices[d]); return true }
                if try rack.chains[c].devices[d].withNestedDevice(id, body) { return true }
            }
        }
        return false
    }

    /// Changes the device list of a chain inside this one (any depth). Returns false when the chain is not here.
    mutating func withNestedChain(_ id: ChainID, _ body: (inout RackChain) throws -> Void) rethrows -> Bool {
        guard var rack else { return false }
        defer { self.rack = rack }
        for c in rack.chains.indices {
            if rack.chains[c].id == id { try body(&rack.chains[c]); return true }
            for d in rack.chains[c].devices.indices {
                if try rack.chains[c].devices[d].withNestedChain(id, body) { return true }
            }
        }
        return false
    }

    /// Problems in a rack that would make it unplayable: duplicate IDs, unknown devices, bad macros.
    func rackIssues() -> [String] {
        guard let rack else { return [] }
        var issues: [String] = []
        var seen = Set<UUID>([id.rawValue])
        for chain in rack.chains {
            if !seen.insert(chain.id.rawValue).inserted { issues.append("duplicate chain id \(chain.id)") }
            for d in chain.devices {
                for inner in d.selfAndNested where !seen.insert(inner.id.rawValue).inserted { issues.append("duplicate device id \(inner.id)") }
                if d.format == "builtin", BuiltInEffects.spec(d.identifier) == nil { issues.append("unknown built-in device \(d.identifier)") }
                issues += d.rackIssues()
            }
        }
        for m in rack.mappings where m.macro < 0 || m.macro >= Rack.macroCount { issues.append("macro \(m.macro + 1) does not exist") }
        for m in rack.mappings where !(m.min.isFinite && m.max.isFinite && m.curve.isFinite) { issues.append("mapping with a non-finite range") }
        return issues
    }
}

public extension Track {
    /// Every device on the track, racks and their contents included, depth first.
    var allDevices: [DeviceSlot] { devices.flatMap(\.selfAndNested) }

    /// A device at any depth.
    func device(_ id: DeviceID) -> DeviceSlot? {
        for d in devices {
            if d.id == id { return d }
            if let found = d.nestedDevice(id) { return found }
        }
        return nil
    }

    /// The chain (any depth) that holds a device, or `nil` for a device on the track itself.
    func chainHolding(_ id: DeviceID) -> RackChain? {
        func search(_ list: [DeviceSlot]) -> RackChain? {
            for d in list {
                for chain in d.rack?.chains ?? [] {
                    if chain.devices.contains(where: { $0.id == id }) { return chain }
                    if let found = search(chain.devices) { return found }
                }
            }
            return nil
        }
        return search(devices)
    }

    /// The racks around a device, outermost first. Empty for a device on the track itself.
    func racksHolding(_ id: DeviceID) -> [DeviceSlot] {
        func search(_ list: [DeviceSlot], path: [DeviceSlot]) -> [DeviceSlot]? {
            for d in list {
                if d.id == id { return path }
                for chain in d.rack?.chains ?? [] {
                    if let found = search(chain.devices, path: path + [d]) { return found }
                }
            }
            return nil
        }
        return search(devices, path: []) ?? []
    }

    /// The rack (any depth) that holds a chain.
    func rackHolding(chain id: ChainID) -> DeviceSlot? {
        allDevices.first { $0.rack?.chains.contains { $0.id == id } == true }
    }

    /// A chain at any depth.
    func chain(_ id: ChainID) -> RackChain? {
        rackHolding(chain: id)?.rack?.chains.first { $0.id == id }
    }

    /// Changes a device at any depth.
    mutating func withDevice(_ id: DeviceID, _ body: (inout DeviceSlot) throws -> Void) throws {
        for i in devices.indices {
            if devices[i].id == id { try body(&devices[i]); return }
            if try devices[i].withNestedDevice(id, body) { return }
        }
        throw CommandError.deviceNotFound(id)
    }

    /// Changes a chain at any depth.
    mutating func withChain(_ id: ChainID, _ body: (inout RackChain) throws -> Void) throws {
        for i in devices.indices where try devices[i].withNestedChain(id, body) { return }
        throw CommandError.chainNotFound(id)
    }

    /// Changes the device list of the track (`nil`) or of a chain.
    mutating func withDevices(in chain: ChainID?, _ body: (inout [DeviceSlot]) throws -> Void) throws {
        if let chain { try withChain(chain) { try body(&$0.devices) } } else { try body(&devices) }
    }
}

// MARK: Macro resolution

public extension Project {
    /// The macro that drives a parameter, if one does: the rack, the mapping and the value the mapping
    /// gives now. A macro that is itself driven by an outer rack's macro counts with that outer value.
    func macroDriving(_ address: ParameterAddress, on track: Track) -> (rack: DeviceSlot, mapping: MacroMapping, value: Double)? {
        for rack in track.allDevices where rack.rack != nil {
            guard let mapping = rack.rack?.mappings.first(where: { $0.target == address }) else { continue }
            let macroAddress = ParameterAddress(node: rack.id.rawValue, parameter: "macro\(mapping.macro + 1)")
            let macro = macroDriving(macroAddress, on: track)?.value ?? rack.params["macro\(mapping.macro + 1)"] ?? 0
            guard let target = automationTarget(address, on: track) else { continue }
            return (rack, mapping, target.value(atPosition: mapping.position(forMacro: macro)))
        }
        return nil
    }

    /// A target by address on one track, cheaper than the project-wide list.
    func automationTarget(_ address: ParameterAddress, on track: Track) -> AutomationTarget? {
        automationTargets(of: track).first { $0.address == address }
    }
}
