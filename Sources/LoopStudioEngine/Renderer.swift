import AVFoundation
import Foundation
import LoopStudioCore

/// Turns a `RenderPlan` into audio, block by block.
///
/// Every output sample depends only on its absolute frame position, never on block boundaries.
/// So rendering in 64-frame or 4096-frame blocks, live or offline, gives bit-identical results.
/// `process` uses only memory allocated in `init`: no allocation, no locks, no Swift arrays of references.
public final class Renderer {
    public let plan: RenderPlan
    public let maxBlock: Int
    private let nodes: UnsafeMutablePointer<NodePlan>
    private let nodeCount: Int
    private let buffers: UnsafeMutablePointer<Float> // per node: left block, right block
    /// Per node: its sound before its effects and after them (left, right each), kept for a sidechain that taps there.
    private let tapBuffers: UnsafeMutablePointer<Float>
    private let peaks: UnsafeMutablePointer<Float>   // per node: largest left and right sample since the last `takePeak`
    /// Session clock minus timeline clock for the block being rendered.
    private var sessionOffset: Int64 = 0
    /// The song position of the last grid step asked for, so several effects share one tempo map lookup.
    private var clockFrame = Int64.min, clockBeat = 0.0, clockQuarter = 0.5, clockBarStart = 0.0, clockBarBeats = 4.0
    /// The block being rendered: its first timeline frame, and whether the transport plays.
    private var blockStart: Int64 = 0
    private var blockPlaying = false
    /// The arrangement loop of the block, in frames, and the same in beats for the plugins' transport state.
    /// The beats are worked out again only when the loop changes.
    private var blockLoop: Range<Int64>?
    private var loopBeats: (start: Double, end: Double)?
    /// Effects that run on the clock (a free LFO) go on while the transport is stopped, as in Live. The clock
    /// then counts on from where the song stopped: `idleFrame` is what the effects see as the frame.
    private var idleFrame: Int64 = 0
    private var idleShift: Int64 = 0
    /// Per node, 16 channels x 128 pitches: how many arrangement notes are on. The loop wrap releases them.
    private let held: UnsafeMutablePointer<UInt8>
    /// The same for the session notes and the live notes that went to a hardware destination. A hosted
    /// instrument releases its own notes; hardware gets an explicit note-off for each one on stop.
    private let sessionHeld: UnsafeMutablePointer<UInt8>
    private let liveHeld: UnsafeMutablePointer<UInt8>
    /// The keys each node holds, as two 64-bit masks (see `heldMask`), made once per block from the three
    /// tables above. The engine copies them out under its lock, so the key lights never read a table while it changes.
    private let masks: UnsafeMutablePointer<UInt64>
    /// The session frame at which notes released after this block (a loop wrap) sound on hardware.
    private var releaseFrame = MIDIOutQueue.now
    /// Tracks whose sound after the fader is recorded (resampling), each with the ring it goes to.
    /// The engine sets it before every block, under its lock; it owns the set, so this does not retain it.
    unowned(unsafe) var captures: CaptureSet?
    /// Offline only: gets every node's output after its fader (the master: the mix), per block.
    /// `Bounce.renderStems` sets it. Never set on the live renderer: it runs on the audio thread.
    var stemSink: ((Int, UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void)?
    /// The sound card input, for nodes with `NodePlan.input`. The engine owns it and sets it before every block.
    unowned(unsafe) var inputMonitor: InputMonitor?
    /// Notes for hardware destinations go here. The engine owns it and sets it before every callback.
    /// Offline it stays `nil`: an export has no hardware.
    unowned(unsafe) var midiOut: MIDIOutQueue?

    final class Slot {
        let effect: DSPEffect?
        let unit: AudioUnitEffect?
        let bypassed: Bool
        let auto: [(key: String, lane: AutoLane)]
        /// False for an automated key a macro drives: the macro wins, the curve is ignored.
        let autoActive: [Bool]
        /// The knob value of each automated key without automation. It comes back when no curve covers the frame.
        let base: [Double?]
        var live: [String: Double]
        /// The effect still runs in the old renderer: the audio thread applies `live` on the first block.
        /// A flag, not an optional dictionary, so the audio thread frees nothing.
        var needsConfigure = false
        /// A macro changed a value in `live` since the last `configure`.
        var dirty = false
        /// Automated Audio Unit parameters, keyed by their address.
        let unitAuto: [(address: AUParameterAddress, lane: AutoLane)]
        /// The node this effect listens to (a sidechain), rendered before this one.
        let sidechain: Int?
        let sidechainTap: SidechainTap
        /// Delay compensation for the sidechain: the source's sound waits here until this effect's input, which
        /// went through more latency, catches up. `nil` when both arrive together.
        let sidechainLine: DelayLine?
        /// A rack: `effect` is nil, the chains run here. `live` holds its macros and selector.
        let rack: RackRuntime?
        /// The node whose notes this effect takes (MIDI From); `nil`: the notes of its own node.
        var midiFrom: Int? = nil
        /// Frames the sound at this effect is late against the song (see `EffectPlan.shift`): its automation
        /// and its tempo clock read that much earlier.
        let shift: Int64
        init(effect: DSPEffect?, unit: AudioUnitEffect?, bypassed: Bool, auto: [String: AutoLane], params: [String: Double], sidechain: Int? = nil,
             sidechainTap: SidechainTap = .postMixer, sidechainLine: DelayLine? = nil, rack: RackRuntime? = nil, mapped: Set<String> = [],
             spec: EffectSpec? = nil, shift: Int = 0) {
            self.effect = effect; self.unit = unit; self.bypassed = bypassed; self.sidechain = sidechain; self.rack = rack
            self.sidechainTap = sidechainTap
            self.sidechainLine = sidechainLine; self.shift = Int64(shift)
            let sorted = auto.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
            self.auto = sorted
            self.autoActive = sorted.map { !mapped.contains($0.0) }
            let spec = spec ?? effect?.spec
            self.base = sorted.map { key, _ in params[key] ?? spec?.params.first { $0.key == key }?.def }
            // Every key present and the storage owned by this slot, so the audio thread never grows or copies it.
            var live = Dictionary(uniqueKeysWithValues: params.map { ($0.key, $0.value) })
            for (i, (key, _)) in sorted.enumerated() where live[key] == nil { live[key] = base[i] ?? 0 }
            for key in mapped where live[key] == nil { live[key] = spec?.params.first { $0.key == key }?.def ?? 0 }
            if rack != nil, live["selector"] == nil { live["selector"] = 0 }
            self.live = live
            self.unitAuto = auto.compactMap { key, lane in
                guard key.hasPrefix("au."), let address = AUParameterAddress(key.dropFirst(3)), !mapped.contains(key) else { return nil }
                return (address, lane)
            }.sorted { $0.address < $1.address }
        }
    }
    private let scratchIn: UnsafeMutablePointer<Float>
    private let scratchOut: UnsafeMutablePointer<Float>
    /// One stereo bus per direct hardware port (`RenderPlan.outputPorts`), filled by each `process` call.
    private let portBuffers: UnsafeMutablePointer<Float>
    public let portCount: Int
    private let inPointers: UnsafeMutablePointer<UnsafePointer<Float>>
    private let outPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let chains: [[Slot]]
    private let outputLines: [DelayLine?]
    private let sendLines: [[DelayLine?]]
    private let tapLines: [[DelayLine?]]
    /// Every delay line by connection and delay, for the next renderer to take over.
    private let delayLines: [String: DelayLine]
    private let instances: [DeviceID: DSPEffect]
    /// The instrument of each node as a slot, so its automation runs like a plugin effect's.
    private let instrumentSlots: [Slot?]
    /// The built-in instrument of each node as a slot: its knobs and automation run like a built-in effect's.
    private let synthSlots: [Slot?]
    /// A MIDI rack as the instrument of a node, and its slot (macros, selector).
    private let rackSynths: [RackRuntime?]
    private let rackSynthSlots: [Slot?]
    /// Every rack runtime at any depth, for `reset`.
    private let racks: [RackRuntime]
    /// The music effects (`aumf`) of each node, racks included. They get the node's notes next to its instrument.
    private let midiEffects: [MIDIFanout?]

    /// With `reusing`, effects that exist in both plans keep their memory (reverb tails, filter state),
    /// so changing a knob does not cut the sound.
    public init(plan: RenderPlan, maxBlock: Int = 4096, reusing old: Renderer? = nil) {
        var made: [DeviceID: DSPEffect] = [:]
        var built: [[Slot]] = []
        var instruments: [Slot?] = []
        var synths: [Slot?] = []
        var synthUnits: [DSPInstrument?] = []
        var rackSynthList: [RackRuntime?] = [], rackSynthSlotList: [Slot?] = []
        var allRacks: [RackRuntime] = []
        var fanouts: [MIDIFanout?] = []
        /// The hosted music effects among `slots`, at any depth; a bypassed slot does not run and takes no notes.
        /// Each with the node whose notes it takes: `nil` for its own node, else the node MIDI From names.
        func musicEffects(_ slots: [Slot], into out: inout [(receiver: any MIDIReceiver, from: Int?)]) {
            for s in slots where !s.bypassed {
                if let u = s.unit, u.acceptsMIDI, !u.isInstrument { out.append((u, nil)) }
                // A built-in effect that listens to notes (the Resonator's root).
                if let e = s.effect, !(e is DSPInstrument), let m = e as? any MIDIReceiver { out.append((m, s.midiFrom)) }
                if let r = s.rack { for c in r.chains { musicEffects(c.slots, into: &out) } }
            }
        }
        var listeners: [[any MIDIReceiver]] = []
        /// Every slot by its device, so a rack's macro links find the slot they move (any depth).
        var slotIndex: [UUID: (Slot, EffectSpec?)] = [:]
        // A connection that keeps its ends and its delay keeps its line, so an edit does not insert
        // a stretch of silence into a compensated path. Only one renderer runs at a time, so sharing is safe.
        var kept: [String: DelayLine] = [:]
        func line(_ d: Int, _ key: String) -> DelayLine? {
            guard d > 0 else { return nil }
            var full = "\(key)|\(d)"
            while kept[full] != nil { full += "+" } // two equal connections never share one line
            if let old = old?.delayLines[full], old.maxBlock == maxBlock { kept[full] = old; return old }
            let new = DelayLine(delay: d, maxBlock: maxBlock)
            kept[full] = new
            return new
        }
        /// A built-in device: the one the old renderer runs when it is the same device of the same kind, else a new one.
        func builtIn(_ device: DeviceID, kind: String, params: [String: Double], program: PatchProgram? = nil) -> (DSPEffect, running: Bool)? {
            if let program {
                // A patch: the running instance stays while its text is unchanged. A new text gets a new
                // instance that takes the delay lines of the old one by name.
                let kept = old?.instances[device] as? PatchDSP
                if let kept, kept.program === program, kept.sampleRate == plan.sampleRate { return (kept, true) }
                let new = PatchDSP(program: program, sampleRate: plan.sampleRate, carryingOver: kept)
                new.configure(params)
                return (new, false)
            }
            if let kept = old?.instances[device], kept.spec.id == kind, kept.sampleRate == plan.sampleRate { return (kept, true) }
            guard let new = DSPEffect.make(kind, sampleRate: plan.sampleRate) else { return nil }
            // The audio thread may still run a kept effect, so only that thread may change it.
            new.configure(params)
            return (new, false)
        }
        /// The macro and selector values of a MIDI rack, from the plan.
        func rackParams(_ device: DeviceID) -> [String: Double] { plan.rackParams[device] ?? [:] }
        /// The slots of an effect list. A rack becomes a slot with a runtime, its chains built the same way.
        func slots(for effects: [EffectPlan]) -> [Slot] {
            var chain: [Slot] = []
            for e in effects {
                if let unit = e.unit {
                    let slot = Slot(effect: nil, unit: unit, bypassed: e.bypassed, auto: e.auto, params: [:], mapped: e.mappedKeys, shift: e.shift)
                    slotIndex[e.device.rawValue] = (slot, nil)
                    chain.append(slot); continue
                }
                if let rackPlan = e.rack {
                    let runtime = makeRack(rackPlan)
                    let spec = BuiltInEffects.spec(e.kind)
                    let slot = Slot(effect: nil, unit: nil, bypassed: e.bypassed, auto: e.auto, params: e.params, rack: runtime,
                                    mapped: e.mappedKeys, spec: spec, shift: e.shift)
                    slotIndex[e.device.rawValue] = (slot, spec)
                    runtime.resolveLinks(rackPlan.mappings, slot: slot, lookup: slotIndex)
                    chain.append(slot)
                    continue
                }
                guard let found = builtIn(e.device, kind: e.kind, params: e.params, program: e.program) else { continue }
                made[e.device] = found.0
                let scLine = e.sidechain == nil ? nil : line(e.sidechainDelay, "sc|\(e.device.rawValue.uuidString)")
                let slot = Slot(effect: found.0, unit: nil, bypassed: e.bypassed, auto: e.auto, params: e.params, sidechain: e.sidechain,
                                sidechainTap: e.sidechainTap, sidechainLine: scLine, mapped: e.mappedKeys, shift: e.shift)
                slot.needsConfigure = found.running
                slot.midiFrom = e.midiFrom
                slotIndex[e.device.rawValue] = (slot, found.0.spec)
                chain.append(slot)
            }
            return chain
        }
        /// A built-in instrument's slot. A kept instrument keeps its notes and its tails across the swap.
        func synthSlot(_ s: SynthPlan, auto: [String: AutoLane]) -> (Slot, DSPInstrument)? {
            guard let found = builtIn(s.device, kind: s.kind, params: s.params), let synth = found.0 as? DSPInstrument else { return nil }
            made[s.device] = synth
            let slot = Slot(effect: synth, unit: nil, bypassed: false, auto: auto, params: s.params, mapped: s.mappedKeys)
            slot.needsConfigure = found.running
            slotIndex[s.device.rawValue] = (slot, synth.spec)
            return (slot, synth)
        }
        func makeRack(_ rackPlan: RackPlan) -> RackRuntime {
            let chains = rackPlan.chains.map { c -> ChainRuntime in
                let synth = c.synth.flatMap { synthSlot($0, auto: c.instrumentAuto) }
                var nested: (Slot, RackRuntime)?
                if let r = c.rackSynth, let device = c.instrumentDevice {
                    let runtime = makeRack(r)
                    let slot = Slot(effect: nil, unit: nil, bypassed: false, auto: c.instrumentAuto, params: rackParams(device), rack: runtime,
                                    mapped: r.mappedKeys, spec: BuiltInEffects.midiRack)
                    slotIndex[device.rawValue] = (slot, BuiltInEffects.midiRack)
                    runtime.resolveLinks(r.mappings, slot: slot, lookup: slotIndex)
                    nested = (slot, runtime)
                }
                let instrumentSlot = c.instrument.map { Slot(effect: nil, unit: $0, bypassed: false, auto: c.instrumentAuto, params: [:]) }
                if let instrumentSlot, let device = c.instrumentDevice { slotIndex[device.rawValue] = (instrumentSlot, nil) }
                return ChainRuntime(plan: c, slots: slots(for: c.effects),
                                    instrumentSlot: instrumentSlot,
                                    synthSlot: synth?.0, synth: synth?.1, rackSlot: nested?.0, rack: nested?.1,
                                    line: c.delay > 0 ? DelayLine(delay: c.delay, maxBlock: maxBlock) : nil, maxBlock: maxBlock)
            }
            let runtime = RackRuntime(device: rackPlan.device, isMIDI: rackPlan.isMIDI, chains: chains, maxBlock: maxBlock)
            allRacks.append(runtime)
            return runtime
        }
        for node in plan.nodes {
            built.append(slots(for: node.effects))
            var effects: [(receiver: any MIDIReceiver, from: Int?)] = []
            musicEffects(built[built.count - 1], into: &effects)
            let here = built.count - 1
            while listeners.count <= here { listeners.append([]) }
            for (receiver, from) in effects {
                let target = from ?? here
                while listeners.count <= target { listeners.append([]) }
                listeners[target].append(receiver)
            }
            instruments.append(node.instrument.map { Slot(effect: nil, unit: $0, bypassed: false, auto: node.instrumentAuto, params: [:]) })
            if let s = node.synth, let (slot, synth) = synthSlot(s, auto: node.instrumentAuto) {
                synths.append(slot)
                synthUnits.append(synth)
            } else {
                synths.append(nil)
                synthUnits.append(nil)
            }
            if let r = node.rackSynth {
                let runtime = makeRack(r)
                let slot = Slot(effect: nil, unit: nil, bypassed: false, auto: node.instrumentAuto, params: rackParams(r.device), rack: runtime,
                                mapped: r.mappedKeys, spec: BuiltInEffects.midiRack)
                slotIndex[r.device.rawValue] = (slot, BuiltInEffects.midiRack)
                runtime.resolveLinks(r.mappings, slot: slot, lookup: slotIndex)
                rackSynthList.append(runtime); rackSynthSlotList.append(slot)
            } else {
                rackSynthList.append(nil); rackSynthSlotList.append(nil)
            }
        }
        // A device with MIDI From joins the fanout of the node whose notes it takes, which may come later.
        for i in plan.nodes.indices {
            let list = i < listeners.count ? listeners[i] : []
            fanouts.append(list.isEmpty ? nil : MIDIFanout(list))
        }
        chains = built
        instrumentSlots = instruments
        synthSlots = synths
        rackSynths = rackSynthList
        rackSynthSlots = rackSynthSlotList
        racks = allRacks
        midiEffects = fanouts
        func name(_ node: Int?) -> String { node.flatMap { plan.trackOrder.indices.contains($0) ? plan.trackOrder[$0]?.description : nil } ?? "master" }
        outputLines = plan.nodes.indices.map { i in line(plan.nodes[i].outputDelay, "out|\(name(i))|\(name(plan.nodes[i].output))") }
        sendLines = plan.nodes.indices.map { i in
            plan.nodes[i].sends.map { line($0.delay, "send|\(name(i))|\(name($0.target))|\($0.preFader)") }
        }
        tapLines = plan.nodes.indices.map { i in
            zip(plan.nodes[i].taps, plan.nodes[i].tapDelays).map { line($1, "tap|\(name(i))|\(name($0))") }
        }
        delayLines = kept
        instances = made
        self.plan = plan
        self.maxBlock = maxBlock
        nodeCount = plan.nodes.count
        nodes = .allocate(capacity: nodeCount)
        nodes.initialize(from: plan.nodes, count: nodeCount)
        for i in 0..<nodeCount { nodes[i].synthUnit = synthUnits[i] }
        buffers = .allocate(capacity: nodeCount * 2 * maxBlock)
        buffers.initialize(repeating: 0, count: nodeCount * 2 * maxBlock)
        tapBuffers = .allocate(capacity: nodeCount * 4 * maxBlock)
        tapBuffers.initialize(repeating: 0, count: nodeCount * 4 * maxBlock)
        scratchIn = .allocate(capacity: 2 * maxBlock); scratchIn.initialize(repeating: 0, count: 2 * maxBlock)
        scratchOut = .allocate(capacity: 2 * maxBlock); scratchOut.initialize(repeating: 0, count: 2 * maxBlock)
        inPointers = .allocate(capacity: 2)
        inPointers.initialize(to: UnsafePointer(scratchIn))
        (inPointers + 1).initialize(to: UnsafePointer(scratchIn + maxBlock))
        outPointers = .allocate(capacity: 2)
        outPointers.initialize(to: scratchOut)
        (outPointers + 1).initialize(to: scratchOut + maxBlock)
        peaks = .allocate(capacity: 2 * max(1, nodeCount))
        peaks.initialize(repeating: 0, count: 2 * max(1, nodeCount))
        held = .allocate(capacity: max(1, nodeCount) * 2048)
        held.initialize(repeating: 0, count: max(1, nodeCount) * 2048)
        sessionHeld = .allocate(capacity: max(1, nodeCount) * 2048)
        sessionHeld.initialize(repeating: 0, count: max(1, nodeCount) * 2048)
        liveHeld = .allocate(capacity: max(1, nodeCount) * 2048)
        liveHeld.initialize(repeating: 0, count: max(1, nodeCount) * 2048)
        masks = .allocate(capacity: 2 * max(1, nodeCount))
        masks.initialize(repeating: 0, count: 2 * max(1, nodeCount))
        portCount = plan.outputPorts.count
        portBuffers = .allocate(capacity: max(1, portCount) * 2 * maxBlock)
        portBuffers.initialize(repeating: 0, count: max(1, portCount) * 2 * maxBlock)
    }

    deinit {
        nodes.deinitialize(count: nodeCount)
        nodes.deallocate()
        buffers.deallocate()
        tapBuffers.deallocate()
        peaks.deallocate()
        held.deallocate()
        sessionHeld.deallocate()
        liveHeld.deallocate()
        masks.deallocate()
        portBuffers.deallocate()
        scratchIn.deallocate(); scratchOut.deallocate(); inPointers.deallocate(); outPointers.deallocate()
    }

    var instancesForTesting: [DeviceID: DSPEffect] { instances }

    /// The running built-in device of a slot, for its display. The table never changes after `init`.
    public func instance(_ device: DeviceID) -> DSPEffect? { instances[device] }

    /// What takes the notes of node `i`: its hosted instrument, else its built-in one.
    @inline(__always) private func noteSink(_ i: Int) -> (any MIDIReceiver)? {
        if let unit = nodes[i].instrument { return unit }
        if let synth = nodes[i].synthUnit { return synth }
        return rackSynths[i]
    }

    /// Clears every effect's memory (delay lines, reverb tails). Called after a stop or a jump.
    public func reset() {
        for effect in instances.values { effect.reset() }
        for rack in racks { for chain in rack.chains { chain.line?.reset() } }
        for line in outputLines { line?.reset() }
        for lines in sendLines { for line in lines { line?.reset() } }
        for lines in tapLines { for line in lines { line?.reset() } }
        silenceNotes()
    }

    /// Sends a MIDI message to the instrument and the hardware destination of a track, `sampleOffset`
    /// frames into the block (0: right now). `host` is that moment as a host time stamp, for the
    /// hardware (0: right now). No allocation: a linear search.
    public func sendLive(track: TrackID, _ status: UInt8, _ data1: UInt8, _ data2: UInt8, sampleOffset: Int = 0, host: UInt64 = 0) {
        let order = plan.trackOrder
        for i in 0..<min(order.count, nodeCount) where order[i] == track {
            noteSink(i)?.sendMIDI(status, data1, data2, sampleOffset: sampleOffset)
            midiEffects[i]?.sendMIDI(status, data1, data2, sampleOffset: sampleOffset)
            if let target = nodes[i].midiOut, let out = midiOut {
                if host != 0 { out.push(target, host: host, status, data1, data2) }
                else { out.push(target, frame: MIDIOutQueue.now, status, data1, data2) }
            }
            let kind = status & 0xF0
            if kind == 0x90 || kind == 0x80 {
                let k = Int(status & 0x0F) << 7 | Int(data1 & 127), live = liveHeld + i * 2048
                if kind == 0x90 && data2 > 0 { live[k] &+= 1 } else if live[k] > 0 { live[k] -= 1 }
                updateMask(i)
            }
            return
        }
    }

    /// Releases every note of every hosted instrument and every note sent to hardware. Called on stop and on a jump.
    /// A clip's sustain pedal and pitch bend end here too: a stop inside a held pedal leaves nothing hanging.
    public func silenceNotes() {
        for i in 0..<nodeCount {
            let sink = noteSink(i), fx = midiEffects[i]
            sink?.silenceNotes()
            fx?.silenceNotes()
            if nodes[i].controlChannels != 0, sink != nil || fx != nil || nodes[i].midiOut != nil {
                for channel: UInt8 in 0..<16 where nodes[i].controlChannels & (1 << UInt16(channel)) != 0 {
                    sink?.sendMIDI(0xB0 | channel, 64, 0, sampleOffset: 0)
                    sink?.sendMIDI(0xE0 | channel, 0, 64, sampleOffset: 0)
                    fx?.sendMIDI(0xB0 | channel, 64, 0, sampleOffset: 0)
                    fx?.sendMIDI(0xE0 | channel, 0, 64, sampleOffset: 0)
                    if let target = nodes[i].midiOut, let out = midiOut {
                        out.push(target, frame: MIDIOutQueue.now, 0xB0 | channel, 64, 0)
                        out.push(target, frame: MIDIOutQueue.now, 0xE0 | channel, 0, 64)
                    }
                }
            }
            if let target = nodes[i].midiOut, let out = midiOut {
                releaseAll(held + i * 2048, target, out, frame: MIDIOutQueue.now)
                releaseAll(sessionHeld + i * 2048, target, out, frame: MIDIOutQueue.now)
                releaseAll(liveHeld + i * 2048, target, out, frame: MIDIOutQueue.now)
            }
        }
        held.update(repeating: 0, count: max(1, nodeCount) * 2048)
        sessionHeld.update(repeating: 0, count: max(1, nodeCount) * 2048)
        liveHeld.update(repeating: 0, count: max(1, nodeCount) * 2048)
        masks.update(repeating: 0, count: 2 * max(1, nodeCount))
    }

    /// Note-offs on hardware for every count in `base`, then zero.
    @inline(__always)
    private func releaseAll(_ base: UnsafeMutablePointer<UInt8>, _ target: MIDIOutTarget, _ out: MIDIOutQueue, frame: Int64) {
        for k in 0..<2048 where base[k] > 0 {
            out.push(target, frame: frame, 0x80 | UInt8(k >> 7), UInt8(k & 127), 0)
            base[k] = 0
        }
    }

    /// The keys a track holds now, from its clips and from live playing, as two 64-bit masks (pitches 0...63
    /// and 64...127), all channels together. For the key lights of the piano roll and the pads. From the
    /// snapshot of the last block, so it is coherent even while the audio thread plays.
    public func heldMask(track: TrackID) -> (low: UInt64, high: UInt64) {
        let order = plan.trackOrder
        for i in 0..<min(order.count, nodeCount) where order[i] == track { return (masks[2 * i], masks[2 * i + 1]) }
        return (0, 0)
    }

    /// Makes the masks of every node that plays notes. Eight keys per load: a node with no held notes costs
    /// 768 loads, so the pass is cheap for any number of tracks.
    private func updateMasks() {
        for i in 0..<nodeCount where nodes[i].instrument != nil || nodes[i].synthUnit != nil || rackSynths[i] != nil
            || nodes[i].midiOut != nil || midiEffects[i] != nil {
            updateMask(i)
        }
    }

    private func updateMask(_ i: Int) {
        do {
            var low: UInt64 = 0, high: UInt64 = 0
            let a = UnsafeRawPointer(held + i * 2048), b = UnsafeRawPointer(sessionHeld + i * 2048), c = UnsafeRawPointer(liveHeld + i * 2048)
            var k = 0
            while k < 2048 {
                let word = a.loadUnaligned(fromByteOffset: k, as: UInt64.self) | b.loadUnaligned(fromByteOffset: k, as: UInt64.self)
                    | c.loadUnaligned(fromByteOffset: k, as: UInt64.self)
                if word != 0 {
                    for j in 0..<8 where (word >> (UInt64(j) * 8)) & 0xFF != 0 {
                        let pitch = (k + j) & 127
                        if pitch < 64 { low |= 1 << UInt64(pitch) } else { high |= 1 << UInt64(pitch - 64) }
                    }
                }
                k += 8
            }
            masks[2 * i] = low; masks[2 * i + 1] = high
        }
    }

    /// Copies the held-key masks of the last block into `out`, two per node. Realtime safe; the engine calls
    /// it under its lock at the end of each callback, like `movePeaks`.
    public func copyMasks(into out: UnsafeMutablePointer<UInt64>, capacity: Int) {
        out.update(from: masks, count: min(2 * nodeCount, capacity))
    }

    /// Releases only the arrangement notes that are still on. Called when the loop wraps,
    /// so session clips keep their held notes.
    public func releaseArrangementNotes() {
        for i in 0..<nodeCount { releaseNotes(of: i, frame: releaseFrame) }
    }

    /// Takes over the notes `old` still holds. Audio thread, once, before the first block.
    /// A note whose note-off is still ahead in this plan stays held here; any other note gets its note-off
    /// now, so deleting or moving a playing clip cannot leave a note hanging. A live note on hardware stays
    /// held as long as its track keeps the destination: the player releases it.
    func takeOverNotes(from old: Renderer, at frame: Int64, sessionFrame: Int64 = 0) {
        for i in 0..<old.nodeCount {
            let unit = old.noteSink(i), hw = old.nodes[i].midiOut, fx = old.midiEffects[i]
            guard unit != nil || hw != nil || fx != nil else { continue }
            // The node of the same track in this plan, when it is still there.
            var j = -1
            if i < old.plan.trackOrder.count, let track = old.plan.trackOrder[i] {
                for n in 0..<min(plan.trackOrder.count, nodeCount) where plan.trackOrder[n] == track { j = n; break }
            }
            var unitKept = j >= 0 && unit != nil && noteSink(j) === unit
            // A rack is rebuilt with every plan: the same rack device keeps its notes, and the new runtime
            // learns which chains hold them, so their note-offs find the same instruments.
            if !unitKept, j >= 0, let oldRack = unit as? RackRuntime, let newRack = rackSynths[j], oldRack.device == newRack.device {
                newRack.inheritHeld(from: oldRack)
                unitKept = true
            }
            let hwKept = j >= 0 && hw != nil && nodes[j].midiOut?.endpoint == hw?.endpoint
            // The music effects keep their notes only as the same set: one that left or was bypassed gets its note-offs.
            var fxKept = false
            if j >= 0, let fx, let mine = midiEffects[j] { fxKept = mine.same(as: fx) }
            let out = midiOut
            @inline(__always) func off(_ k: Int, unitToo: Bool, hwToo: Bool, fxToo: Bool) {
                if unitToo, let unit { unit.sendMIDI(0x80 | UInt8(k >> 7), UInt8(k & 127), 0) }
                if hwToo, let hw, let out { out.push(hw, frame: MIDIOutQueue.now, 0x80 | UInt8(k >> 7), UInt8(k & 127), 0) }
                if fxToo, let fx { fx.sendMIDI(0x80 | UInt8(k >> 7), UInt8(k & 127), 0) }
            }
            let anyKept = unitKept || hwKept || fxKept
            let base = old.held + i * 2048
            for k in 0..<2048 where base[k] > 0 {
                let keep = anyKept && nodes[j].noteIndex.heldAt(k, frame: frame - Int64(nodes[j].inputShift))
                if keep { held[j * 2048 + k] &+= base[k] }
                off(k, unitToo: !(keep && unitKept), hwToo: !(keep && hwKept), fxToo: !(keep && fxKept))
                base[k] = 0
            }
            // Session notes: the same rule. A note that was moved or deleted while it sounded ends here.
            let session = old.sessionHeld + i * 2048
            for k in 0..<2048 where session[k] > 0 {
                let ahead = anyKept && nodes[j].sessionNoteIndex.heldAt(k, frame: sessionFrame - Int64(nodes[j].inputShift))
                let keepUnit = unitKept && ahead, keepHw = hwKept && ahead, keepFx = fxKept && ahead
                if keepUnit || keepHw || keepFx { sessionHeld[j * 2048 + k] &+= session[k] }
                off(k, unitToo: !keepUnit, hwToo: !keepHw, fxToo: !keepFx)
                session[k] = 0
            }
            // Live notes: the player releases them, as long as the instrument or the destination stays.
            let live = old.liveHeld + i * 2048
            for k in 0..<2048 where live[k] > 0 {
                if anyKept { liveHeld[j * 2048 + k] &+= live[k] }
                off(k, unitToo: !unitKept, hwToo: !hwKept, fxToo: !fxKept)
                live[k] = 0
            }
        }
    }

    /// True when the next event of `key` (channel << 7 | pitch) at or after `frame` is a note-off.
    static func hasNoteOff(_ events: [MIDIEvent], key: Int, from frame: Int64) -> Bool {
        var lo = 0, hi = events.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if events[mid].frame < frame { lo = mid + 1 } else { hi = mid }
        }
        while lo < events.count {
            let e = events[lo]
            lo += 1
            let kind = e.status & 0xF0
            guard kind == 0x80 || kind == 0x90, Int(e.status & 0x0F) << 7 | Int(e.data1 & 127) == key else { continue }
            return kind == 0x80 || e.data2 == 0
        }
        return false
    }

    /// Ends the arrangement notes that node `i` still holds. `frame`: the session frame of the note-offs on hardware.
    private func releaseNotes(of i: Int, frame: Int64) {
        let base = held + i * 2048
        let unit = noteSink(i), fx = midiEffects[i], target = nodes[i].midiOut
        guard unit != nil || target != nil || fx != nil else { return }
        let out = midiOut
        for k in 0..<2048 where base[k] > 0 {
            unit?.sendMIDI(0x80 | UInt8(k >> 7), UInt8(k & 127), 0)
            fx?.sendMIDI(0x80 | UInt8(k >> 7), UInt8(k & 127), 0)
            if let target, let out { out.push(target, frame: frame, 0x80 | UInt8(k >> 7), UInt8(k & 127), 0) }
            base[k] = 0
        }
    }

    /// Tells a plugin where the song is at the start of this block, for its own tempo sync.
    private func setSong(_ unit: AudioUnitEffect) {
        let (beat, quarter) = songPosition(blockStart)
        var sig = TimeSignature(4, 4), from = 0.0
        for change in plan.timeSignatures where Double(change.tick.rawValue) / Double(Tick.perQuarter) <= beat {
            sig = change.signature; from = Double(change.tick.rawValue) / Double(Tick.perQuarter)
        }
        let bar = Double(sig.ticksPerBar.rawValue) / Double(Tick.perQuarter)
        let downbeat = bar > 0 ? from + ((beat - from) / bar).rounded(.down) * bar : beat
        let next = plan.tempoMap.frame(at: Tick(Int64(beat.rounded(.up)) * Tick.perQuarter), sampleRate: plan.sampleRate).rawValue
        unit.setSongPosition(frame: blockStart, beat: beat, bpm: 60 / quarter, numerator: sig.numerator,
                             denominator: sig.denominator, downbeat: downbeat, playing: blockPlaying,
                             toNextBeat: Int(max(0, next - blockStart)), cycle: loopBeats)
    }

    /// The loop of this block in beats, for `setSong`. Two tempo map lookups, only when the loop changed.
    private func setLoop(_ loop: Range<Int64>?) {
        guard loop != blockLoop else { return }
        blockLoop = loop
        guard let loop else { loopBeats = nil; return }
        let map = plan.tempoMap
        loopBeats = (map.tickAt(seconds: Double(loop.lowerBound) / plan.sampleRate) / Double(Tick.perQuarter),
                     map.tickAt(seconds: Double(loop.upperBound) / plan.sampleRate) / Double(Tick.perQuarter))
    }

    private func run(_ unit: AudioUnitEffect, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        setSong(unit)
        scratchIn.update(from: l, count: frames)
        (scratchIn + maxBlock).update(from: r, count: frames)
        guard unit.process(frames: frames, input: inPointers, output: outPointers) == noErr else { return } // keep the dry signal
        scrub(scratchOut, frames); scrub(scratchOut + maxBlock, frames)
        l.update(from: scratchOut, count: frames)
        r.update(from: scratchOut + maxBlock, count: frames)
    }

    /// A plugin that returns NaN or infinity would poison every delay and detector after it; such a sample becomes 0.
    @inline(__always) private func scrub(_ p: UnsafeMutablePointer<Float>, _ frames: Int) {
        for k in 0..<frames where !p[k].isFinite { p[k] = 0 }
    }

    /// Queues the notes of one block for the instrument, the music effects and the hardware destination.
    /// `startFrame` is in the frames of `events`. Hardware gets each note at its session frame: `sessionShift`
    /// is what to add to an event frame for that (0 for session events).
    private func send(_ unit: (any MIDIReceiver)?, _ fx: MIDIFanout?, _ out: MIDIOutQueue?, _ target: MIDIOutTarget?, _ events: [MIDIEvent],
                      startFrame: Int64, sessionShift: Int64, frames: Int, held: UnsafeMutablePointer<UInt8>? = nil) {
        // First event at or after the block start (events are sorted by frame).
        var lo = 0, hi = events.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if events[mid].frame < startFrame { lo = mid + 1 } else { hi = mid }
        }
        let end = startFrame + Int64(frames)
        while lo < events.count, events[lo].frame < end {
            let e = events[lo]
            unit?.sendMIDI(e.status, e.data1, e.data2, sampleOffset: Int(e.frame - startFrame))
            fx?.sendMIDI(e.status, e.data1, e.data2, sampleOffset: Int(e.frame - startFrame))
            if let out, let target { out.push(target, frame: e.frame + sessionShift, e.status, e.data1, e.data2) }
            if let held {
                let kind = e.status & 0xF0, k = Int(e.status & 0x0F) << 7 | Int(e.data1 & 127)
                if kind == 0x90 && e.data2 > 0 { held[k] &+= 1 }
                else if (kind == 0x80 || kind == 0x90), held[k] > 0 { held[k] -= 1 }
            }
            lo += 1
        }
    }

    private func play(_ unit: AudioUnitEffect, into l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        setSong(unit)
        scratchIn.update(repeating: 0, count: 2 * maxBlock)
        guard unit.process(frames: frames, input: inPointers, output: outPointers) == noErr else { return }
        scrub(scratchOut, frames); scrub(scratchOut + maxBlock, frames)
        for k in 0..<frames { l[k] += scratchOut[k]; r[k] += scratchOut[maxBlock + k] }
    }

    /// Moves the peaks since the last call into `meters` (keeping the larger value) and starts them again.
    /// Realtime safe. The engine calls it at the end of each callback.
    /// Two values per node: left, then right.
    public func movePeaks(into meters: UnsafeMutablePointer<Float>, capacity: Int) {
        for i in 0..<min(2 * nodeCount, capacity) {
            meters[i] = max(meters[i], peaks[i])
            peaks[i] = 0
        }
    }

    /// The largest absolute sample of a node (after its fader) since the last call, left and right. For meters.
    public func takePeaks(node: Int) -> (left: Float, right: Float) {
        guard node >= 0, node < nodeCount else { return (0, 0) }
        let p = (peaks[2 * node], peaks[2 * node + 1])
        peaks[2 * node] = 0; peaks[2 * node + 1] = 0
        return p
    }

    /// The larger of the two channel peaks.
    public func takePeak(node: Int) -> Float {
        guard node >= 0, node < nodeCount else { return 0 }
        let p = max(peaks[2 * node], peaks[2 * node + 1])
        peaks[2 * node] = 0; peaks[2 * node + 1] = 0
        return p
    }

    /// The sound of direct port `i` (an index into `RenderPlan.outputPorts`) from the last `process` call.
    public func portLeft(_ i: Int) -> UnsafePointer<Float> { UnsafePointer(portBuffers + i * 2 * maxBlock) }
    public func portRight(_ i: Int) -> UnsafePointer<Float> { UnsafePointer(portBuffers + (i * 2 + 1) * maxBlock) }
    public var outputPorts: [PortID] { plan.outputPorts }

    @inline(__always) private func left(_ node: Int) -> UnsafeMutablePointer<Float> { buffers + node * 2 * maxBlock }
    @inline(__always) private func right(_ node: Int) -> UnsafeMutablePointer<Float> { buffers + (node * 2 + 1) * maxBlock }
    @inline(__always) private func preLeft(_ node: Int) -> UnsafeMutablePointer<Float> { tapBuffers + node * 4 * maxBlock }
    @inline(__always) private func preRight(_ node: Int) -> UnsafeMutablePointer<Float> { tapBuffers + (node * 4 + 1) * maxBlock }
    @inline(__always) private func postLeft(_ node: Int) -> UnsafeMutablePointer<Float> { tapBuffers + (node * 4 + 2) * maxBlock }
    @inline(__always) private func postRight(_ node: Int) -> UnsafeMutablePointer<Float> { tapBuffers + (node * 4 + 3) * maxBlock }

    /// Renders `frames` frames that start at project frame `startFrame` into `outLeft` and `outRight`.
    /// With `transport` false the arrangement and session clips and the MIDI clips stay silent, but hosted
    /// instruments and effects keep running. That is how a stopped project still plays live notes and rings out.
    /// `sessionFrame` is the session clock at the block start. It runs on when the arrangement loop jumps back,
    /// so session clips and their automation do not restart at the loop end. Offline it equals `startFrame`.
    /// `loop` is the arrangement loop while it is on; hosted plugins read it as their cycle.
    public func process(startFrame: Int64, sessionFrame: Int64? = nil, frames: Int, transport: Bool = true,
                        loop: Range<Int64>? = nil,
                        outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>) {
        precondition(frames <= maxBlock)
        sessionOffset = (sessionFrame ?? startFrame) - startFrame
        setLoop(loop)
        if transport {
            idleShift = 0
        } else {
            // The first stopped block starts the idle clock where the song stands; it then runs on.
            if blockPlaying || idleFrame < startFrame { idleFrame = startFrame }
            idleShift = idleFrame - startFrame
            idleFrame += Int64(frames)
        }
        blockStart = startFrame; blockPlaying = transport
        buffers.update(repeating: 0, count: nodeCount * 2 * maxBlock)
        if portCount > 0 { portBuffers.update(repeating: 0, count: portCount * 2 * maxBlock) }
        // The sound card input sounds with or without the transport, like a live instrument.
        let monitor = inputMonitor
        let inputReady = monitor?.beginBlock(frames: frames, outputRate: plan.sampleRate) ?? false
        defer { monitor?.endBlock() }

        for i in 0..<nodeCount {
            let node = nodes[i]
            let l = left(i), r = right(i)

            // The node's own clips and notes play `inputShift` late, so they line up with the sound it takes from
            // other nodes (delay compensation). `song` is the song frame at the start of this block for them.
            let song = startFrame - Int64(node.inputShift)
            // A take of the track's input: the sum the earlier nodes sent here, before its own clips join.
            if transport, let captures, i < plan.trackOrder.count, let track = plan.trackOrder[i] {
                for k in 0..<captures.count where captures.points[k] == .input(track) {
                    captures.rings[k].noteStart(frame: startFrame)
                    captures.rings[k].write(l, r, frames: frames)
                }
            }
            // How much of this block the arrangement still plays: a session take-over cuts it on the session clock.
            var arrangement = frames
            if let end = node.arrangementEnd { arrangement = Int(max(0, min(Int64(frames), end - (song + sessionOffset)))) }
            if transport {
                for clip in node.clips {
                    if clip.session { mix(clip, into: l, r, blockStart: song + sessionOffset, frames: frames) }
                    else if arrangement > 0 { mix(clip, into: l, r, blockStart: song, frames: arrangement) }
                }
            }
            if inputReady, let monitor, let input = node.input {
                monitor.add(channel: input.left, into: l, frames: frames)
                monitor.add(channel: input.right ?? input.left, into: r, frames: frames)
            }
            let target = node.midiOut
            let out = target != nil ? midiOut : nil
            let sink = noteSink(i), fx = midiEffects[i]
            if transport, sink != nil || out != nil || fx != nil {
                if arrangement > 0 {
                    send(sink, fx, out, target, node.midi, startFrame: song, sessionShift: sessionOffset, frames: arrangement, held: held + i * 2048)
                }
                if arrangement < frames { releaseNotes(of: i, frame: song + sessionOffset + Int64(arrangement)) }
                send(sink, fx, out, target, node.sessionMidi, startFrame: song + sessionOffset, sessionShift: 0, frames: frames,
                     held: sessionHeld + i * 2048)
            }
            if let instrument = node.instrument {
                if let slot = instrumentSlots[i] { scheduleAutomation(slot, startFrame: song, frames: frames) }
                play(instrument, into: l, r, frames: frames)
            } else if let synth = node.synthUnit, let slot = synthSlots[i] {
                runSynth(synth, slot, l, r, startFrame: song, frames: frames)
            } else if let rack = rackSynths[i], let slot = rackSynthSlots[i] {
                runRackSlot(rack, slot, l, r, startFrame: song, frames: frames, instrument: true)
            }
            // Each effect reads its automation as late as the sound reaches it; the fader and the sends, as
            // late as the sound leaves the node.
            // A sidechain elsewhere taps this node before its effects, or after them: keep that copy.
            if node.tapPreFX { preLeft(i).update(from: l, count: frames); preRight(i).update(from: r, count: frames) }
            for slot in chains[i] where !slot.bypassed { runSlot(slot, l, r, startFrame: startFrame - slot.shift, frames: frames) }
            if node.tapPostFX { postLeft(i).update(from: l, count: frames); postRight(i).update(from: r, count: frames) }
            let leaves = startFrame - Int64(node.outputShift)

            for (k, send) in node.sends.enumerated() where send.preFader { sendOut(send, sendLines[i][k], l, r, startFrame: leaves, frames: frames) }

            let peak: (Float, Float)
            if node.isMaster {
                peak = fader(node, l, r, outLeft, outRight, startFrame: leaves, frames: frames)
            } else {
                peak = fader(node, l, r, l, r, startFrame: leaves, frames: frames)
            }
            peaks[2 * i] = max(peaks[2 * i], peak.0)
            peaks[2 * i + 1] = max(peaks[2 * i + 1], peak.1)
            if let stemSink { stemSink(i, node.isMaster ? outLeft : l, node.isMaster ? outRight : r, frames) }
            if transport, let captures, i < plan.trackOrder.count {
                // The master is `nil` in the track order.
                let point: CapturePoint = plan.trackOrder[i].map { .output($0) } ?? .master
                for k in 0..<captures.count where captures.points[k] == point {
                    captures.rings[k].noteStart(frame: startFrame)
                    captures.rings[k].write(node.isMaster ? outLeft : l, node.isMaster ? outRight : r, frames: frames)
                }
            }
            if node.isMaster { continue }
            for (k, send) in node.sends.enumerated() where !send.preFader { sendOut(send, sendLines[i][k], l, r, startFrame: leaves, frames: frames) }
            if let target = node.output { addDelayed(l, r, to: target, line: outputLines[i], frames: frames) }
            if let port = node.port {
                let pl = portBuffers + port * 2 * maxBlock, pr = pl + maxBlock
                for k in 0..<frames { pl[k] += l[k]; pr[k] += r[k] }
            }
            for (k, tap) in node.taps.enumerated() { addDelayed(l, r, to: tap, line: tapLines[i][k], frames: frames) }
        }
        if transport { releaseFrame = startFrame + sessionOffset + Int64(frames) }
        updateMasks()
    }

    // MARK: Automation

    /// Walks a block in pieces that end on multiples of 32 absolute frames.
    /// Automation is evaluated on that grid, so the result does not depend on how the host cuts blocks.
    @inline(__always)
    private func eachGridChunk(startFrame: Int64, frames: Int, _ body: (_ offset: Int, _ count: Int, _ gridStart: Int64, _ position: Float) -> Void) {
        var k = 0
        while k < frames {
            let f = startFrame + Int64(k)
            let gridStart = (f >> 5) << 5
            let count = min(frames - k, Int(gridStart + 32 - f))
            body(k, count, gridStart, Float(f - gridStart) / 32)
            k += count
        }
    }

    private func gains(_ node: NodePlan, at frame: Int64) -> (Float, Float) {
        var volume = node.gain
        if let lane = node.volumeAuto, let v = lane.value(at: frame, sessionOffset: sessionOffset) { volume = node.silenced ? 0 : RenderPlan.dB(Double(v)) }
        var pl = node.panLeft, pr = node.panRight
        if let lane = node.panAuto, let v = lane.value(at: frame, sessionOffset: sessionOffset) { (pl, pr) = RenderPlan.balance(Double(v)) }
        return (volume * pl, volume * pr)
    }

    /// Applies volume and pan from `l`, `r` into `outL`, `outR` (the same memory for a normal track).
    /// Returns the peak of each channel.
    private func fader(_ node: NodePlan, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>,
                       _ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>,
                       startFrame: Int64, frames: Int) -> (Float, Float) {
        var peakL: Float = 0, peakR: Float = 0
        if node.volumeAuto == nil && node.panAuto == nil {
            let gl = node.gain * node.panLeft, gr = node.gain * node.panRight
            for k in 0..<frames {
                let a = l[k] * gl, b = r[k] * gr
                outL[k] = a; outR[k] = b
                peakL = max(peakL, abs(a)); peakR = max(peakR, abs(b))
            }
            return (peakL, peakR)
        }
        eachGridChunk(startFrame: startFrame, frames: frames) { offset, count, grid, t0 in
            let (al, ar) = gains(node, at: grid), (bl, br) = gains(node, at: grid + 32)
            for j in 0..<count {
                let t = t0 + Float(j) / 32
                let a = l[offset + j] * (al + (bl - al) * t), b = r[offset + j] * (ar + (br - ar) * t)
                outL[offset + j] = a; outR[offset + j] = b
                peakL = max(peakL, abs(a)); peakR = max(peakR, abs(b))
            }
        }
        return (peakL, peakR)
    }

    private func addSend(_ send: SendPlan, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>,
                         startFrame: Int64, frames: Int) {
        guard let lane = send.auto else { add(l, r, gain: send.gain, to: send.target, frames: frames); return }
        let tl = left(send.target), tr = right(send.target)
        func gain(_ f: Int64) -> Float {
            guard let v = lane.value(at: f, sessionOffset: sessionOffset) else { return send.gain }
            return v <= -59.9 ? 0 : RenderPlan.dB(Double(v))
        }
        eachGridChunk(startFrame: startFrame, frames: frames) { offset, count, grid, t0 in
            let a = gain(grid), b = gain(grid + 32)
            for j in 0..<count {
                let g = a + (b - a) * (t0 + Float(j) / 32)
                tl[offset + j] += l[offset + j] * g; tr[offset + j] += r[offset + j] * g
            }
        }
    }

    /// Automation reaches a plugin as scheduled parameter events, one ramp per grid step.
    private func scheduleAutomation(_ slot: Slot, startFrame: Int64, frames: Int) {
        guard let unit = slot.unit, !slot.unitAuto.isEmpty else { return }
        eachGridChunk(startFrame: startFrame, frames: frames) { offset, count, grid, _ in
            for (address, lane) in slot.unitAuto {
                if let v = lane.value(at: grid + 32, sessionOffset: sessionOffset) { unit.scheduleParameter(address, v, sampleOffset: offset, ramp: count) }
            }
        }
    }

    /// Runs one effect. A built-in effect with automated knobs gets its values set at every grid step.
    private func runSlot(_ slot: Slot, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>,
                         startFrame: Int64, frames: Int) {
        if let unit = slot.unit {
            scheduleAutomation(slot, startFrame: startFrame, frames: frames)
            run(unit, l, r, frames: frames)
            return
        }
        if let rack = slot.rack { runRackSlot(rack, slot, l, r, startFrame: startFrame, frames: frames, instrument: false); return }
        guard let effect = slot.effect else { return }
        if slot.needsConfigure || slot.dirty { effect.configure(slot.live); slot.needsConfigure = false; slot.dirty = false }
        // A sidechain reads the output of a node that rendered before this one in this block. When this
        // effect's own input went through more latency, the source waits in a line by the difference.
        var scL: UnsafePointer<Float>?, scR: UnsafePointer<Float>?
        if let s = slot.sidechain {
            switch slot.sidechainTap {
            case .preFX: scL = UnsafePointer(preLeft(s)); scR = UnsafePointer(preRight(s))
            case .postFX: scL = UnsafePointer(postLeft(s)); scR = UnsafePointer(postRight(s))
            case .postMixer: scL = UnsafePointer(left(s)); scR = UnsafePointer(right(s))
            }
        }
        if let line = slot.sidechainLine, let sl = scL, let sr = scR {
            line.process(sl, sr, frames: frames)
            scL = UnsafePointer(line.outLeft); scR = UnsafePointer(line.outRight)
        }
        guard !slot.auto.isEmpty || effect.followsTempo else { effect.process(l, r, sidechainL: scL, sidechainR: scR, frames: frames); return }
        eachGridChunk(startFrame: startFrame, frames: frames) { offset, count, grid, _ in
            var changed = false
            for (i, (key, lane)) in slot.auto.enumerated() where slot.autoActive[i] {
                guard let v = lane.value(at: grid, sessionOffset: sessionOffset).map(Double.init) ?? slot.base[i] else { continue }
                if slot.live[key] != v { slot.live[key] = v; changed = true }
            }
            if changed { effect.configure(slot.live) }
            if effect.followsTempo {
                // Stopped, the clock runs on from the song position (`idleShift`), so a free LFO keeps moving.
                let (beat, quarter) = songPosition(grid + idleShift)
                effect.clock(frame: grid + idleShift, beat: beat, quarterSeconds: quarter, barStart: clockBarStart, barBeats: clockBarBeats)
            }
            effect.process(l + offset, r + offset, sidechainL: scL.map { $0 + offset }, sidechainR: scR.map { $0 + offset }, frames: count)
        }
    }

    /// Runs a built-in instrument for one block, like `runSlot` runs a built-in effect: its automated knobs
    /// are set at every grid step, and it adds its sound to the node.
    private func runSynth(_ synth: DSPInstrument, _ slot: Slot, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>,
                          startFrame: Int64, frames: Int) {
        if slot.needsConfigure || slot.dirty { synth.configure(slot.live); slot.needsConfigure = false; slot.dirty = false }
        guard !slot.auto.isEmpty || synth.followsTempo else { synth.render(l, r, frames: frames); return }
        eachGridChunk(startFrame: startFrame, frames: frames) { offset, count, grid, _ in
            var changed = false
            for (i, (key, lane)) in slot.auto.enumerated() where slot.autoActive[i] {
                guard let v = lane.value(at: grid, sessionOffset: sessionOffset).map(Double.init) ?? slot.base[i] else { continue }
                if slot.live[key] != v { slot.live[key] = v; changed = true }
            }
            if changed { synth.configure(slot.live) }
            if synth.followsTempo {
                let (beat, quarter) = songPosition(grid + idleShift)
                synth.clock(frame: grid + idleShift, beat: beat, quarterSeconds: quarter, barStart: clockBarStart, barBeats: clockBarBeats)
            }
            synth.render(l + offset, r + offset, frames: count)
        }
    }

    /// Beat (in quarter notes) and seconds per quarter note at a timeline frame. No allocation. The bar the
    /// frame is in (`clockBarStart`, `clockBarBeats`) is read in the same step.
    private func songPosition(_ frame: Int64) -> (beat: Double, quarter: Double) {
        if frame != clockFrame {
            let map = plan.tempoMap
            let tick = map.tickAt(seconds: Double(frame) / plan.sampleRate)
            clockBeat = tick / Double(Tick.perQuarter)
            clockQuarter = 60 / map.bpm(at: Tick(Int64(tick.rounded(.down))))
            clockFrame = frame
            var sig = TimeSignature(4, 4), from = 0.0
            for change in plan.timeSignatures where Double(change.tick.rawValue) / Double(Tick.perQuarter) <= clockBeat {
                sig = change.signature; from = Double(change.tick.rawValue) / Double(Tick.perQuarter)
            }
            let bar = Double(sig.ticksPerBar.rawValue) / Double(Tick.perQuarter)
            clockBarBeats = bar
            clockBarStart = bar > 0 ? from + ((clockBeat - from) / bar).rounded(.down) * bar : clockBeat
        }
        return (clockBeat, clockQuarter)
    }

    @inline(__always)
    private func addDelayed(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, to target: Int, line: DelayLine?, frames: Int) {
        guard let line else { add(l, r, gain: 1, to: target, frames: frames); return }
        line.process(l, r, frames: frames)
        add(line.outLeft, line.outRight, gain: 1, to: target, frames: frames)
    }

    private func sendOut(_ send: SendPlan, _ line: DelayLine?, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>,
                         startFrame: Int64, frames: Int) {
        guard let line else { addSend(send, l, r, startFrame: startFrame, frames: frames); return }
        line.process(l, r, frames: frames)
        addSend(send, line.outLeft, line.outRight, startFrame: startFrame, frames: frames)
    }

    private func add(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, gain: Float, to target: Int, frames: Int) {
        let tl = left(target), tr = right(target)
        for k in 0..<frames { tl[k] += l[k] * gain; tr[k] += r[k] * gain }
    }

    private func mix(_ clip: ClipPlan, into l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>,
                     blockStart: Int64, frames: Int) {
        let from = max(blockStart, clip.start)
        let to = min(blockStart + Int64(frames), clip.end)
        guard from < to else { return }
        let length = clip.end - clip.start
        let total = Int64(clip.pcm.frames)
        let srcL = clip.pcm.channel(0), srcR = clip.pcm.channel(1)

        // The envelope is read on a fixed 32-frame grid of absolute frames, so the result does not depend on the block size.
        var envGrid = Int64.min, envGain: Float = 1
        var f = from
        while f < to {
            let p = f - clip.start
            // From the start marker; at the loop end, back to the loop start.
            var s = (clip.playStart ?? clip.sourceOffset) + p
            if clip.loop, clip.loopLength > 0, s >= clip.sourceOffset + clip.loopLength {
                s = clip.sourceOffset + (s - clip.sourceOffset) % clip.loopLength
            }
            if clip.loop { s %= total } else if s >= total { break } // a one-shot ends with its audio

            var g = clip.gain
            if p < clip.fadeIn { g *= sinf(.pi / 2 * Float(p) / Float(clip.fadeIn)) }
            let remaining = length - 1 - p
            if remaining < clip.fadeOut { g *= sinf(.pi / 2 * Float(remaining) / Float(clip.fadeOut)) }
            if let env = clip.envelope {
                let grid = f & ~31
                if grid != envGrid { envGrid = grid; envGain = powf(10, env.value(at: grid) / 20) }
                g *= envGain
            }

            let k = Int(f - blockStart)
            l[k] += srcL[Int(s)] * g
            r[k] += srcR[Int(s)] * g
            f += 1
        }
    }
}

// MARK: Racks

/// One macro knob driving one value inside a rack, resolved to the slot or chain it moves.
struct MacroLink {
    enum Target {
        /// A knob of a built-in device: the slot, the key and the parameter that maps a position to a value.
        case param(Renderer.Slot, String, EffectParam?)
        /// A plugin parameter, scheduled on the unit.
        case unit(AudioUnitEffect, AUParameterAddress, Double, Double)
        case chainVolume(Int)
        case chainPan(Int)
        /// A chain of a rack inside this one.
        case nestedChainVolume(RackRuntime, Int)
        case nestedChainPan(RackRuntime, Int)
        case selector
    }
    let macro: Int
    let min: Double
    let max: Double
    let curve: Double
    let target: Target
    /// The last position written, so an unchanged macro writes nothing.
    var last = Double.nan
}

/// The hosted music effects (`aumf`) of one node, at any depth of its chain, and the built-in effects that
/// listen to notes. They get every MIDI message the node's instrument gets: notes, controls and program
/// changes from clips and from live input.
final class MIDIFanout: MIDIReceiver {
    let units: [any MIDIReceiver]

    init(_ units: [any MIDIReceiver]) { self.units = units }

    func sendMIDI(_ status: UInt8, _ data1: UInt8, _ data2: UInt8, sampleOffset: Int) {
        for u in units { u.sendMIDI(status, data1, data2, sampleOffset: sampleOffset) }
    }

    func silenceNotes() {
        for u in units { u.silenceNotes() }
    }

    /// The same plugin instances in the same order. Audio thread, at a plan swap: no allocation.
    func same(as other: MIDIFanout) -> Bool {
        guard units.count == other.units.count else { return false }
        for k in 0..<units.count where units[k] !== other.units[k] { return false }
        return true
    }
}

/// A chain of a rack as it runs: its slots, its instrument, its mixer and its buffers.
final class ChainRuntime {
    let id: ChainID
    let slots: [Renderer.Slot]
    let instrumentSlot: Renderer.Slot?
    let synthSlot: Renderer.Slot?
    let synth: DSPInstrument?
    let unit: AudioUnitEffect?
    let rackSlot: Renderer.Slot?
    let rack: RackRuntime?
    let gain: Float
    let panLeft: Float, panRight: Float
    let volumeAuto: AutoLane?, panAuto: AutoLane?
    let mute: Bool, solo: Bool
    let zone: ChainZone
    let keyZone: ChainZone?, velocityZone: ChainZone?
    /// Lines this chain up with the slowest chain of the rack.
    let line: DelayLine?
    let bufL: UnsafeMutablePointer<Float>, bufR: UnsafeMutablePointer<Float>
    /// How many note-ons per key went down this chain, so the note-offs follow.
    let heldKeys: UnsafeMutablePointer<UInt8>
    /// A macro moved the chain's volume or pan: these win over the knob and the automation.
    var macroVolumeDb = Double.nan
    var macroPan = Double.nan

    init(plan: ChainPlan, slots: [Renderer.Slot], instrumentSlot: Renderer.Slot?, synthSlot: Renderer.Slot?, synth: DSPInstrument?,
         rackSlot: Renderer.Slot?, rack: RackRuntime?, line: DelayLine?, maxBlock: Int) {
        id = plan.id
        self.slots = slots
        self.instrumentSlot = instrumentSlot
        self.synthSlot = synthSlot
        self.synth = synth
        unit = plan.instrument
        self.rackSlot = rackSlot
        self.rack = rack
        gain = plan.gain; panLeft = plan.panLeft; panRight = plan.panRight
        volumeAuto = plan.volumeAuto; panAuto = plan.panAuto
        mute = plan.mute; solo = plan.solo
        zone = plan.zone; keyZone = plan.keyZone; velocityZone = plan.velocityZone
        self.line = line
        bufL = .allocate(capacity: maxBlock); bufL.initialize(repeating: 0, count: maxBlock)
        bufR = .allocate(capacity: maxBlock); bufR.initialize(repeating: 0, count: maxBlock)
        heldKeys = .allocate(capacity: 128); heldKeys.initialize(repeating: 0, count: 128)
    }

    deinit { bufL.deallocate(); bufR.deallocate(); heldKeys.deallocate() }

    /// What plays this chain's notes.
    var sink: (any MIDIReceiver)? { unit ?? synth ?? rack }
}

/// A rack as it runs. For a MIDI rack it is also the note sink of its track or chain: it routes every note
/// to the chains whose zones hold it.
final class RackRuntime: MIDIReceiver {
    let device: DeviceID
    let isMIDI: Bool
    let chains: [ChainRuntime]
    let anySolo: Bool
    var links: [MacroLink] = []
    /// The chain selector as the last grid step set it. The note router reads it.
    var selector = 0.0
    let inL: UnsafeMutablePointer<Float>, inR: UnsafeMutablePointer<Float>

    init(device: DeviceID, isMIDI: Bool, chains: [ChainRuntime], maxBlock: Int) {
        self.device = device
        self.isMIDI = isMIDI
        self.chains = chains
        anySolo = chains.contains(where: \.solo)
        inL = .allocate(capacity: maxBlock); inL.initialize(repeating: 0, count: maxBlock)
        inR = .allocate(capacity: maxBlock); inR.initialize(repeating: 0, count: maxBlock)
    }

    deinit { inL.deallocate(); inR.deallocate() }

    /// Turns the mappings of the plan into links to the slots of this runtime. Once, off the audio thread.
    /// `lookup` holds every slot built so far by its device; a rack's chains are built before the rack itself.
    func resolveLinks(_ mappings: [MacroMapping], slot: Renderer.Slot, lookup: [UUID: (Renderer.Slot, EffectSpec?)]) {
        selector = slot.live["selector"] ?? 0
        links = mappings.compactMap { m in
            let node = m.target.node, key = m.target.parameter
            if node == device.rawValue { return key == "selector" ? MacroLink(macro: m.macro, min: m.min, max: m.max, curve: m.curve, target: .selector) : nil }
            for c in chains.indices where chains[c].id.rawValue == node {
                if key == "volume" { return MacroLink(macro: m.macro, min: m.min, max: m.max, curve: m.curve, target: .chainVolume(c)) }
                if key == "pan" { return MacroLink(macro: m.macro, min: m.min, max: m.max, curve: m.curve, target: .chainPan(c)) }
                return nil
            }
            // A chain of a nested rack: its runtime holds the chain.
            for chain in chains {
                for nested in chain.slots.compactMap(\.rack) + [chain.rack].compactMap({ $0 }) {
                    if let link = nested.chainLink(m, node: node, key: key) { return link }
                }
            }
            guard let (target, spec) = lookup[node] else { return nil }
            if let unit = target.unit {
                guard key.hasPrefix("au."), let address = AUParameterAddress(key.dropFirst(3)), let range = unit.parameterRange(address) else { return nil }
                return MacroLink(macro: m.macro, min: m.min, max: m.max, curve: m.curve, target: .unit(unit, address, range.min, range.max))
            }
            let param = spec?.params.first { $0.key == key }
            // A fixed parameter sets the plan's latency: a macro cannot move it between rebuilds.
            if param?.fixed == true { return nil }
            return MacroLink(macro: m.macro, min: m.min, max: m.max, curve: m.curve, target: .param(target, key, param))
        }
    }

    /// A link to a chain of this rack or of a rack inside it, for an outer rack's macro.
    private func chainLink(_ m: MacroMapping, node: UUID, key: String) -> MacroLink? {
        for c in chains.indices where chains[c].id.rawValue == node {
            if key == "volume" { return MacroLink(macro: m.macro, min: m.min, max: m.max, curve: m.curve, target: .nestedChainVolume(self, c)) }
            if key == "pan" { return MacroLink(macro: m.macro, min: m.min, max: m.max, curve: m.curve, target: .nestedChainPan(self, c)) }
        }
        for chain in chains {
            for nested in chain.slots.compactMap(\.rack) + [chain.rack].compactMap({ $0 }) {
                if let link = nested.chainLink(m, node: node, key: key) { return link }
            }
        }
        return nil
    }

    /// The chain selector value and the macros, applied to the links. Called at every grid step, before the chains run.
    func applyLinks(_ slot: Renderer.Slot) {
        selector = slot.live["selector"] ?? 0
        for i in links.indices {
            let link = links[i]
            let value = slot.live["macro\(link.macro + 1)"] ?? 0
            let q = min(max(value / 127, 0), 1)
            let position = link.min + (link.max - link.min) * MacroMapping.shape(q, curve: link.curve)
            if position == link.last { continue }
            links[i].last = position
            switch link.target {
            case .param(let target, let key, let param):
                let v = param?.value(atPosition: position) ?? position
                if target.live[key] != v { target.live[key] = v; target.dirty = true }
            case .unit(let unit, let address, let lo, let hi):
                unit.scheduleParameter(address, Float(lo + (hi - lo) * min(max(position, 0), 1)), sampleOffset: 0, ramp: 32)
            case .chainVolume(let c):
                chains[c].macroVolumeDb = RackChain.volumeRange.lowerBound + (RackChain.volumeRange.upperBound - RackChain.volumeRange.lowerBound) * min(max(position, 0), 1)
            case .chainPan(let c):
                chains[c].macroPan = -1 + 2 * min(max(position, 0), 1)
            case .nestedChainVolume(let rack, let c):
                rack.chains[c].macroVolumeDb = RackChain.volumeRange.lowerBound + (RackChain.volumeRange.upperBound - RackChain.volumeRange.lowerBound) * min(max(position, 0), 1)
            case .nestedChainPan(let rack, let c):
                rack.chains[c].macroPan = -1 + 2 * min(max(position, 0), 1)
            case .selector:
                let s = 127 * min(max(position, 0), 1)
                slot.live["selector"] = s
                selector = s
            }
        }
    }

    /// The level of a chain at the selector, with mute and solo. 0 for a chain that is silent.
    @inline(__always) func level(_ c: Int) -> Float {
        let chain = chains[c]
        // Solo wins over mute, as on a track.
        if (chain.mute && !chain.solo) || (anySolo && !chain.solo) { return 0 }
        return Float(chain.zone.gain(at: selector))
    }

    // MARK: Notes

    func sendMIDI(_ status: UInt8, _ data1: UInt8, _ data2: UInt8, sampleOffset: Int) {
        let kind = status & 0xF0
        let pitch = Int(data1 & 127)
        if kind == 0x90, data2 > 0 {
            let velocity = Int(data2 & 127)
            for c in 0..<chains.count where level(c) > 0 {
                let chain = chains[c]
                if let kz = chain.keyZone, !kz.contains(pitch) { continue }
                if let vz = chain.velocityZone, !vz.contains(velocity) { continue }
                // The fades of the key and velocity zones scale the velocity, like Live's.
                var v = Double(velocity)
                if let kz = chain.keyZone { v *= kz.gain(at: Double(pitch)) }
                if let vz = chain.velocityZone { v *= vz.gain(at: Double(velocity)) }
                chain.sink?.sendMIDI(status, data1, UInt8(max(1, min(127, v.rounded()))), sampleOffset: sampleOffset)
                chain.heldKeys[pitch] &+= 1
            }
            return
        }
        if kind == 0x80 || kind == 0x90 {
            var routed = false
            for chain in chains where chain.heldKeys[pitch] > 0 {
                chain.sink?.sendMIDI(status, data1, data2, sampleOffset: sampleOffset)
                chain.heldKeys[pitch] -= 1
                routed = true
            }
            // A note-off nobody remembers (after a rebuild that lost the route) ends the note everywhere.
            if !routed { for chain in chains { chain.sink?.sendMIDI(status, data1, data2, sampleOffset: sampleOffset) } }
            return
        }
        for chain in chains { chain.sink?.sendMIDI(status, data1, data2, sampleOffset: sampleOffset) }
    }

    func silenceNotes() {
        for chain in chains {
            chain.sink?.silenceNotes()
            chain.heldKeys.update(repeating: 0, count: 128)
        }
    }

    /// Takes the note routes of the runtime this one replaces. A chain that is gone releases its notes now.
    func inheritHeld(from old: RackRuntime) {
        for oldChain in old.chains {
            if let mine = chains.first(where: { $0.id == oldChain.id }) {
                mine.heldKeys.update(from: oldChain.heldKeys, count: 128)
                if let nestedOld = oldChain.rack, let nestedNew = mine.rack { nestedNew.inheritHeld(from: nestedOld) }
            } else {
                for k in 0..<128 where oldChain.heldKeys[k] > 0 { oldChain.sink?.sendMIDI(0x80, UInt8(k), 0, sampleOffset: 0) }
            }
            oldChain.heldKeys.update(repeating: 0, count: 128)
        }
    }
}

extension Renderer {
    /// Runs a rack: its macros and selector from the slot's automation at every grid step, then every chain in
    /// parallel on the same input (or, for an instrument rack, from its own notes), summed by the chain levels.
    func runRackSlot(_ rack: RackRuntime, _ slot: Slot, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>,
                     startFrame: Int64, frames: Int, instrument: Bool) {
        guard !slot.auto.isEmpty else {
            renderRack(rack, slot, l, r, startFrame: startFrame, frames: frames, instrument: instrument)
            return
        }
        eachGridChunk(startFrame: startFrame, frames: frames) { offset, count, grid, _ in
            for (i, (key, lane)) in slot.auto.enumerated() where slot.autoActive[i] {
                guard let v = lane.value(at: grid, sessionOffset: sessionOffset).map(Double.init) ?? slot.base[i] else { continue }
                if slot.live[key] != v { slot.live[key] = v }
            }
            renderRack(rack, slot, l + offset, r + offset, startFrame: startFrame + Int64(offset), frames: count, instrument: instrument)
        }
    }

    private func renderRack(_ rack: RackRuntime, _ slot: Slot, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>,
                            startFrame: Int64, frames: Int, instrument: Bool) {
        rack.applyLinks(slot)
        if !instrument {
            rack.inL.update(from: l, count: frames)
            rack.inR.update(from: r, count: frames)
        }
        l.update(repeating: 0, count: frames)
        r.update(repeating: 0, count: frames)
        for c in 0..<rack.chains.count {
            let chain = rack.chains[c]
            let level = rack.level(c)
            // Every chain runs, sounding or not: a faded-out chain keeps its tails and its instrument's releases.
            if instrument {
                chain.bufL.update(repeating: 0, count: frames)
                chain.bufR.update(repeating: 0, count: frames)
                if let unit = chain.unit {
                    if let s = chain.instrumentSlot { scheduleAutomation(s, startFrame: startFrame, frames: frames) }
                    play(unit, into: chain.bufL, chain.bufR, frames: frames)
                } else if let synth = chain.synth, let s = chain.synthSlot {
                    runSynth(synth, s, chain.bufL, chain.bufR, startFrame: startFrame, frames: frames)
                } else if let nested = chain.rack, let s = chain.rackSlot {
                    runRackSlot(nested, s, chain.bufL, chain.bufR, startFrame: startFrame, frames: frames, instrument: true)
                }
            } else {
                chain.bufL.update(from: rack.inL, count: frames)
                chain.bufR.update(from: rack.inR, count: frames)
            }
            for s in chain.slots where !s.bypassed { runSlot(s, chain.bufL, chain.bufR, startFrame: startFrame - s.shift, frames: frames) }
            var outL = UnsafePointer(chain.bufL), outR = UnsafePointer(chain.bufR)
            if let line = chain.line {
                line.process(chain.bufL, chain.bufR, frames: frames)
                outL = UnsafePointer(line.outLeft); outR = UnsafePointer(line.outRight)
            }
            guard level > 0 else { continue }
            if chain.volumeAuto == nil, chain.panAuto == nil, chain.macroVolumeDb.isNaN, chain.macroPan.isNaN {
                let gl = chain.gain * chain.panLeft * level, gr = chain.gain * chain.panRight * level
                for k in 0..<frames { l[k] += outL[k] * gl; r[k] += outR[k] * gr }
                continue
            }
            eachGridChunk(startFrame: startFrame, frames: frames) { offset, count, grid, _ in
                let (gl, gr) = chainGains(chain, at: grid)
                for k in offset..<(offset + count) { l[k] += outL[k] * gl * level; r[k] += outR[k] * gr * level }
            }
        }
    }

    /// The chain's volume and pan at a frame: a macro first, then automation, then the knobs.
    private func chainGains(_ chain: ChainRuntime, at frame: Int64) -> (Float, Float) {
        var volume = chain.gain
        if !chain.macroVolumeDb.isNaN { volume = chain.mute ? 0 : RenderPlan.dB(chain.macroVolumeDb) }
        else if let lane = chain.volumeAuto, let v = lane.value(at: frame, sessionOffset: sessionOffset) { volume = chain.mute ? 0 : RenderPlan.dB(Double(v)) }
        var pl = chain.panLeft, pr = chain.panRight
        if !chain.macroPan.isNaN { (pl, pr) = RenderPlan.balance(chain.macroPan) }
        else if let lane = chain.panAuto, let v = lane.value(at: frame, sessionOffset: sessionOffset) { (pl, pr) = RenderPlan.balance(Double(v)) }
        return (volume * pl, volume * pr)
    }
}

// MARK: Offline bounce

public struct RenderedAudio {
    public var left: [Float]
    public var right: [Float]
    public var sampleRate: Double

    public init(left: [Float], right: [Float], sampleRate: Double) {
        self.left = left
        self.right = right
        self.sampleRate = sampleRate
    }

    public var frames: Int { left.count }
    public var peak: Float { max(left.reduce(0) { max($0, abs($1)) }, right.reduce(0) { max($0, abs($1)) }) }

    public var rms: Float {
        guard frames > 0 else { return 0 }
        let sum = zip(left, right).reduce(Double(0)) { $0 + Double($1.0 * $1.0 + $1.1 * $1.1) }
        return Float((sum / Double(frames * 2)).squareRoot())
    }
}

public enum Bounce {
    /// Renders the project's master mix from `startFrame` up to (not including) `endFrame`.
    /// With `endFrame` nil it renders to the end of the last clip plus `tailSeconds`.
    public static func render(_ plan: RenderPlan, startFrame: Int64 = 0, endFrame: Int64? = nil,
                              tailSeconds: Double = 0, block: Int = 4096) -> RenderedAudio {
        let end = endFrame ?? (plan.endFrame + Int64((tailSeconds * plan.sampleRate).rounded()))
        let total = Int(max(0, end - startFrame))
        // Plugin delay compensation makes the master `latency` frames late. Render that much more and
        // drop it from the front, so frame 0 of the file is frame `startFrame` of the timeline.
        let latency = max(0, plan.latencyFrames)
        var left = [Float](repeating: 0, count: total + latency)
        var right = [Float](repeating: 0, count: total + latency)
        let renderer = Renderer(plan: plan, maxBlock: block)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                var done = 0
                while done < total + latency {
                    let n = min(block, total + latency - done)
                    renderer.process(startFrame: startFrame + Int64(done), frames: n,
                                     outLeft: l.baseAddress! + done, outRight: r.baseAddress! + done)
                    done += n
                }
            }
        }
        if latency > 0 { left.removeFirst(latency); right.removeFirst(latency) }
        return RenderedAudio(left: left, right: right, sampleRate: plan.sampleRate)
    }

    /// Renders stems: the output of each listed track after its fader (its clips, effects and automation,
    /// no sends into it) and, for `nil`, the master mix. One pass; every stem is aligned to the timeline,
    /// so the stems sum to the master mix when the returns are among them. A track the plan does not
    /// hold (unknown id) gives silence.
    public static func renderStems(_ plan: RenderPlan, tracks: [TrackID?], startFrame: Int64 = 0, endFrame: Int64? = nil,
                                   tailSeconds: Double = 0, block: Int = 4096) -> [RenderedAudio] {
        let end = endFrame ?? (plan.endFrame + Int64((tailSeconds * plan.sampleRate).rounded()))
        let total = Int(max(0, end - startFrame))
        let latency = max(0, plan.latencyFrames)
        // The node of each stem, and how far its output travels through delay lines to the master.
        let nodeIndex: [Int?] = tracks.map { track in
            track == nil ? plan.nodes.firstIndex { $0.isMaster } : plan.trackOrder.firstIndex { $0 == track }
        }
        func delayToMaster(_ i: Int) -> Int {
            var d = 0, node = i, hops = 0
            while let next = plan.nodes[node].output, hops < plan.nodes.count { d += plan.nodes[node].outputDelay; node = next; hops += 1 }
            return d
        }
        var stems = tracks.map { _ in (left: [Float](repeating: 0, count: total + latency), right: [Float](repeating: 0, count: total + latency)) }
        var slot: [Int: [Int]] = [:]
        for (k, i) in nodeIndex.enumerated() { if let i { slot[i, default: []].append(k) } }
        let renderer = Renderer(plan: plan, maxBlock: block)
        var done = 0
        renderer.stemSink = { i, l, r, n in
            guard let ks = slot[i] else { return }
            for k in ks {
                stems[k].left.withUnsafeMutableBufferPointer { $0.baseAddress!.advanced(by: done).update(from: l, count: n) }
                stems[k].right.withUnsafeMutableBufferPointer { $0.baseAddress!.advanced(by: done).update(from: r, count: n) }
            }
        }
        let scratchL = UnsafeMutablePointer<Float>.allocate(capacity: block), scratchR = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { scratchL.deallocate(); scratchR.deallocate() }
        while done < total + latency {
            let n = min(block, total + latency - done)
            renderer.process(startFrame: startFrame + Int64(done), frames: n, outLeft: scratchL, outRight: scratchR)
            done += n
        }
        renderer.stemSink = nil
        return stems.indices.map { k in
            // The master is `latency` late; a node's output is late by what it still has to travel.
            let drop = nodeIndex[k].map { latency - delayToMaster($0) } ?? latency
            var l = stems[k].left, r = stems[k].right
            if drop > 0 { l.removeFirst(min(drop, l.count)); r.removeFirst(min(drop, r.count)) }
            if l.count > total { l.removeLast(l.count - total); r.removeLast(r.count - total) }
            return RenderedAudio(left: l, right: r, sampleRate: plan.sampleRate)
        }
    }

    /// Writes a 24-bit WAV file.
    public static func writeWAV(_ audio: RenderedAudio, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: audio.sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(audio.frames, 1))) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = AVAudioFrameCount(audio.frames)
        audio.left.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: audio.frames) }
        audio.right.withUnsafeBufferPointer { buffer.floatChannelData![1].update(from: $0.baseAddress!, count: audio.frames) }
        if audio.frames > 0 { try file.write(from: buffer) }
    }
}
