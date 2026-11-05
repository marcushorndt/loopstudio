import Foundation
import LoopStudioCore
import SwiftUI

/// One control on a MIDI device: a controller number or a note, on one channel. Any device counts, so a
/// mapping survives a controller that comes back with another unique ID.
struct MIDIControl: Hashable, Codable, Sendable {
    var channel: UInt8
    var number: UInt8
    var isNote: Bool

    var label: String {
        isNote ? "Note \(MIDIControl.noteName(number)) ch \(channel + 1)" : "CC \(number) ch \(channel + 1)"
    }

    static func noteName(_ n: UInt8) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[Int(n) % 12])\(Int(n) / 12 - 2)"
    }
}

/// What a mapped control drives. Knobs take the value; buttons act on a press.
enum MIDIMapTarget: Hashable, Codable, Sendable {
    case volume(TrackID)
    case pan(TrackID)
    case send(TrackID, TrackID)
    case deviceParam(TrackID, DeviceID, String)
    case deviceOn(TrackID, DeviceID)
    case mute(TrackID)
    case solo(TrackID)
    case arm(TrackID)
    case stopTrack(TrackID)
    case play, stop, record, metronome
    case scene(Int)
    case slot(TrackID, Int)

    /// A button: a press acts, the value does not matter.
    var isButton: Bool {
        switch self {
        case .volume, .pan, .send, .deviceParam: false
        default: true
        }
    }

    /// A button that a key range can step through: each key of the range reaches the next row.
    var steps: Bool {
        switch self {
        case .scene, .slot: true
        default: false
        }
    }
}

/// A control bound to a target. A note control with `noteHigh` is a key range from the control's note up to
/// `noteHigh`: on a knob the key's place in the range sets the value, on a scene or slot each key reaches the
/// next row. `min` and `max` (0...1) narrow the range a knob moves through; `max` below `min` inverts it.
struct MIDIMapping: Codable, Sendable, Hashable {
    var control: MIDIControl
    var target: MIDIMapTarget
    var noteHigh: UInt8?
    var min: Double = 0
    var max: Double = 1

    init(control: MIDIControl, target: MIDIMapTarget, noteHigh: UInt8? = nil, min: Double = 0, max: Double = 1) {
        self.control = control
        self.target = target
        self.noteHigh = noteHigh
        self.min = min
        self.max = max
    }

    enum CodingKeys: String, CodingKey { case control, target, noteHigh, min, max }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        control = try c.decode(MIDIControl.self, forKey: .control)
        target = try c.decode(MIDIMapTarget.self, forKey: .target)
        noteHigh = try c.decodeIfPresent(UInt8.self, forKey: .noteHigh)
        min = try c.decodeIfPresent(Double.self, forKey: .min) ?? 0
        max = try c.decodeIfPresent(Double.self, forKey: .max) ?? 1
    }

    /// True when the control is a note and the mapping spans more than that note.
    var isRange: Bool { control.isNote && (noteHigh ?? control.number) > control.number }

    /// The keys of a range, for the label.
    var controlLabel: String {
        guard isRange, let high = noteHigh else { return control.label }
        return "Keys \(MIDIControl.noteName(control.number))–\(MIDIControl.noteName(high)) ch \(control.channel + 1)"
    }

    /// Does this mapping take a message from `control`? Returns the key's offset in a range, 0 otherwise.
    func offset(for incoming: MIDIControl) -> Int? {
        if incoming == control { return 0 }
        guard control.isNote, incoming.isNote, incoming.channel == control.channel, let high = noteHigh,
              incoming.number > control.number, incoming.number <= high else { return nil }
        return Int(incoming.number) - Int(control.number)
    }
}

/// What the MIDI thread sees: the mappings, and the control that is being learned. Plain copies under a lock.
final class MIDILearnBox: @unchecked Sendable {
    enum Outcome { case none, learned(MIDIControl), mapped(MIDIMapping, UInt8, Int) }
    private let lock = NSLock()
    private var mappings: [MIDIMapping] = []
    private var learning = false

    func set(_ list: [MIDIMapping], learning: Bool) {
        lock.lock(); defer { lock.unlock() }
        mappings = list
        self.learning = learning
    }

    /// Looks at one channel message. A controller change or a note-on either binds the pending target or
    /// drives its mapping. Other messages, and unmapped controls, go on to the instruments.
    func handle(status: UInt8, _ a: UInt8, _ b: UInt8) -> Outcome {
        let kind = status & 0xF0
        let control: MIDIControl
        switch kind {
        case 0xB0: control = MIDIControl(channel: status & 0x0F, number: a, isNote: false)
        case 0x90 where b > 0: control = MIDIControl(channel: status & 0x0F, number: a, isNote: true)
        default: return .none
        }
        lock.lock(); defer { lock.unlock() }
        if learning { return .learned(control) }
        // An exact match first, then a key range that holds the note.
        if let m = mappings.first(where: { $0.control == control }) { return .mapped(m, control.isNote ? 127 : b, 0) }
        for m in mappings { if let offset = m.offset(for: control) { return .mapped(m, 127, offset) } }
        return .none
    }
}

extension AppModel {
    private var midiMapURL: URL { packageURL.appendingPathComponent("midi-map.json") }

    /// Reads the mappings saved with the project.
    func loadMIDIMappings() {
        midiMappings = (try? JSONDecoder().decode([MIDIMapping].self, from: Data(contentsOf: midiMapURL))) ?? []
        midiLearnBox.set(midiMappings, learning: false)
    }

    private func saveMIDIMappings() {
        midiLearnBox.set(midiMappings, learning: learnTarget != nil)
        if midiMappings.isEmpty { try? FileManager.default.removeItem(at: midiMapURL); return }
        do { try JSONEncoder().encode(midiMappings).write(to: midiMapURL, options: .atomic) }
        catch { status = "The MIDI mapping works now but could not be saved: \(error.localizedDescription)" }
    }

    func mapping(for target: MIDIMapTarget) -> MIDIMapping? {
        midiMappings.first { $0.target == target }
    }

    /// MIDI map mode (Live: ⌘M): every mappable control lights up blue. Click one, then move a control on
    /// the MIDI device. For a key range press the lowest key, then the highest. Esc or the key again ends it;
    /// the mappings stay with the project.
    func toggleMIDILearn() {
        midiLearn.toggle()
        learnTarget = nil
        midiLearnBox.set(midiMappings, learning: false)
        if midiLearn { macroMap = nil }
        status = midiLearn ? "MIDI Map: click a blue control, then move a knob or press a key on your MIDI device. Two keys make a key range. Esc ends it."
            : (midiMappings.isEmpty ? "" : "\(midiMappings.count) MIDI mapping\(midiMappings.count == 1 ? "" : "s") active")
    }

    /// The control clicked in map mode: the next controller change or note binds it.
    func beginLearning(_ target: MIDIMapTarget) {
        learnTarget = target
        midiLearnBox.set(midiMappings, learning: true)
        status = "Move a knob or press a key on your MIDI device for \(describe(target))."
    }

    func forgetMapping(_ target: MIDIMapTarget) {
        midiMappings.removeAll { $0.target == target }
        if learnTarget == target { learnTarget = nil; midiLearnBox.set(midiMappings, learning: false) }
        saveMIDIMappings()
        status = "Forgot the MIDI mapping of \(describe(target))."
    }

    /// Edits the range of a mapping (0...1 positions, or 0...127 as Live shows them).
    func setMappingRange(_ target: MIDIMapTarget, min: Double, max: Double) {
        guard let i = midiMappings.firstIndex(where: { $0.target == target }) else { return }
        midiMappings[i].min = Swift.min(Swift.max(min, 0), 1)
        midiMappings[i].max = Swift.min(Swift.max(max, 0), 1)
        saveMIDIMappings()
    }

    /// A control moved while a target waited: one control drives one target, and one target has one control.
    /// A second key for the same target, while it still waits, turns the mapping into a key range.
    func bind(_ control: MIDIControl, to target: MIDIMapTarget) {
        if control.isNote, let i = midiMappings.firstIndex(where: { $0.target == target }), midiMappings[i].control.isNote,
           midiMappings[i].control.channel == control.channel, midiMappings[i].control.number != control.number,
           lastLearned == target {
            // Lowest key, then highest: the order does not matter.
            var m = midiMappings[i]
            let low = Swift.min(m.control.number, control.number), high = Swift.max(m.noteHigh ?? m.control.number, control.number)
            m.control.number = low
            m.noteHigh = high
            midiMappings.removeAll { $0.target != target && $0.offset(for: control) != nil }
            midiMappings[i] = m
            saveMIDIMappings()
            status = "\(m.controlLabel) now drive \(describe(target)). Click another control to map it, or leave MIDI Map."
            return
        }
        midiMappings.removeAll { $0.target == target || $0.control == control || $0.offset(for: control) != nil }
        midiMappings.append(MIDIMapping(control: control, target: target))
        lastLearned = target
        // The target keeps waiting: a second key widens the mapping to a range, another control replaces it.
        saveMIDIMappings()
        status = "\(control.label) now drives \(describe(target))." + (control.isNote ? " Press a second key for a key range, or click another control." : " Click another control to map it, or leave MIDI Map.")
    }

    /// The MIDI thread saw a mapped control or learned one.
    func midiLearnEvent(_ outcome: MIDILearnBox.Outcome) {
        switch outcome {
        case .none: break
        case .learned(let control): if let target = learnTarget { bind(control, to: target) }
        case .mapped(let mapping, let value, let offset): perform(mapping, value: value, offset: offset)
        }
    }

    /// Drives a target with a controller value (0...127), or with a key's place in a key range.
    func perform(_ mapping: MIDIMapping, value: UInt8, offset: Int) {
        let target = mapping.target
        var q = Double(value) / 127
        if mapping.isRange, let high = mapping.noteHigh {
            q = Double(offset) / Double(max(1, Int(high) - Int(mapping.control.number)))
        }
        q = mapping.min + (mapping.max - mapping.min) * q
        if target.isButton {
            // A press is the rising edge: a controller in toggle mode (127, then 0) still acts once per press,
            // and a knob mapped to a button by mistake acts only when it crosses the middle upwards.
            let was = midiButtonValues[target] ?? 0
            midiButtonValues[target] = value
            guard value >= 64, was < 64 || mapping.isRange else { return }
        }
        switch target {
        case .volume(let id): apply(.setVolume(id: id, db: Fader.db(position: q)), key: "vol\(id)")
        case .pan(let id): apply(.setPan(id: id, pan: q * 2 - 1), key: "pan\(id)")
        case .send(let id, let ret):
            guard let t = project.track(id) else { return }
            setSend(from: t, to: ret, db: q <= 0.01 ? -96 : -48 + 48 * q)
        case .deviceParam(let id, let device, let key):
            guard let t = project.track(id), let d = t.device(device) else { return }
            if let param = d.spec?.params.first(where: { $0.key == key }) {
                setDeviceParam(id, device, key, param.isSwitch ? (q >= 0.5 ? 1 : 0) : param.value(atPosition: q))
            } else if let p = d.pluginParams?.first(where: { $0.key == key }) {
                setDeviceParam(id, device, key, p.min + (p.max - p.min) * q)
            }
        case .deviceOn(let id, let device):
            guard let d = project.track(id)?.device(device) else { return }
            apply(.setDeviceBypass(track: id, device: device, bypassed: !d.bypassed))
        case .mute(let id): if let t = project.track(id) { apply(.setMute(id: id, mute: !t.mute)) }
        case .solo(let id): if let t = project.track(id) { toggleSolo(t, additive: true) }
        case .arm(let id): toggleArm(id, additive: true)
        case .stopTrack(let id): if let t = project.track(id) { stopClips(of: t) }
        case .play: togglePlay()
        case .stop: stop()
        case .record: toggleRecordArm()
        case .metronome: toggleMetronome()
        case .scene(let row): launchScene(row + offset)
        case .slot(let id, let row):
            guard let t = project.track(id) else { return }
            let r = row + offset
            if r < t.slots.count, t.slots[r] != nil { launch(track: id, row: r) } else { stopClips(of: t) }
        }
    }

    func describe(_ target: MIDIMapTarget) -> String {
        func name(_ id: TrackID) -> String { project.track(id)?.name ?? "a track" }
        switch target {
        case .volume(let id): return "\(name(id)) volume"
        case .pan(let id): return "\(name(id)) pan"
        case .send(let id, let ret): return "\(name(id)) send to \(name(ret))"
        case .deviceParam(let id, let device, let key):
            let d = project.track(id)?.device(device)
            var p = d.flatMap { $0.spec?.params.first { $0.key == key }?.name } ?? key
            if let rack = d?.rack, key.hasPrefix("macro"), let n = Int(key.dropFirst(5)) { p = rack.macroName(n - 1) }
            return "\(d?.name ?? "device") \(p) on \(name(id))"
        case .deviceOn(let id, let device): return "\(project.track(id)?.device(device)?.name ?? "device") on/off on \(name(id))"
        case .mute(let id): return "\(name(id)) mute"
        case .solo(let id): return "\(name(id)) solo"
        case .arm(let id): return "\(name(id)) arm"
        case .stopTrack(let id): return "\(name(id)) stop"
        case .play: return "play"
        case .stop: return "stop"
        case .record: return "record"
        case .metronome: return "the metronome"
        case .scene(let row): return "scene \(row + 1)"
        case .slot(let id, let row): return "\(name(id)) slot \(row + 1)"
        }
    }
}

/// In MIDI map mode a control gets a blue cover: a click chooses it, a right-click forgets its mapping.
/// Outside map mode a mapped control shows a small blue dot.
private struct MIDILearnable: ViewModifier {
    @Environment(AppModel.self) private var model
    let target: MIDIMapTarget

    func body(content: Content) -> some View {
        let mapped = model.mapping(for: target)
        content
            .overlay(alignment: .bottomTrailing) {
                if !model.midiLearn, mapped != nil {
                    Circle().fill(Theme.midiMap).frame(width: 5, height: 5).padding(2).allowsHitTesting(false)
                }
            }
            .overlay {
                if model.midiLearn {
                    let chosen = model.learnTarget == target
                    ZStack {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.midiMap.opacity(chosen ? 0.6 : (mapped == nil ? 0.25 : 0.42)))
                        RoundedRectangle(cornerRadius: 3).stroke(chosen ? Color.white : Theme.midiMap, lineWidth: chosen ? 1.5 : 1)
                        if let mapped {
                            Text(mapped.isRange ? "\(MIDIControl.noteName(mapped.control.number))–\(MIDIControl.noteName(mapped.noteHigh ?? 0))" : mapped.control.label)
                                .font(.system(size: 8, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                .padding(.horizontal, 2).background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 2))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.beginLearning(target) }
                    .contextMenu {
                        Button("Learn This Control") { model.beginLearning(target) }
                        Button("Forget MIDI Mapping") { model.forgetMapping(target) }.disabled(mapped == nil)
                    }
                    .hint(mapped.map { "\(model.describe(target)): \($0.controlLabel). Click to map another control." }
                          ?? "\(model.describe(target)): not mapped. Click, then move a control on your MIDI device.")
                }
            }
    }
}

extension View {
    /// A knob, fader or button that MIDI map mode can map.
    func midiLearnable(_ target: MIDIMapTarget) -> some View { modifier(MIDILearnable(target: target)) }
}

/// Live's mapping browser: every MIDI mapping of the project with its control, its range (Min/Max as 0...127)
/// and a way to forget it. Shown in the sidebar while map mode is on.
struct MIDIMappingList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("MIDI Mappings").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(model.midiMappings.count)").font(.caption).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            if model.midiMappings.isEmpty {
                Text("Click a blue control in the app, then move a knob or press a key on your MIDI device. Press a second key for a key range.")
                    .font(.caption).foregroundStyle(Theme.dim).padding(10)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.midiMappings, id: \.target) { m in
                        row(m)
                        Divider()
                    }
                }
            }
        }
    }

    private func row(_ m: MIDIMapping) -> some View {
        let chosen = model.learnTarget == m.target
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(m.controlLabel).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.midiMap)
                Spacer()
                Button { model.forgetMapping(m.target) } label: {
                    Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(Theme.dim).frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain).hint("Forget this mapping")
            }
            Text(model.describe(m.target)).font(.system(size: 11)).lineLimit(2)
            if !m.target.isButton {
                HStack(spacing: 6) {
                    rangeField("Min", value: m.min) { model.setMappingRange(m.target, min: $0, max: m.max) }
                    rangeField("Max", value: m.max) { model.setMappingRange(m.target, min: m.min, max: $0) }
                    if m.max < m.min { Text("inverted").font(.system(size: 9)).foregroundStyle(Theme.dim) }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(chosen ? Theme.midiMap.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.beginLearning(m.target) }
        .hint("Click to map another control to \(model.describe(m.target)).")
    }

    /// Min or Max as Live shows them: 0 to 127.
    private func rangeField(_ title: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 3) {
            Text(title).font(.system(size: 9)).foregroundStyle(Theme.dim)
            TextField(title, value: Binding(get: { Int((value * 127).rounded()) }, set: { set(Double(min(max($0, 0), 127)) / 127) }), format: .number)
                .textFieldStyle(.roundedBorder).font(.system(size: 10, design: .monospaced)).frame(width: 44)
        }
    }
}
