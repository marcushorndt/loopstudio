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
}

struct MIDIMapping: Codable, Sendable {
    var control: MIDIControl
    var target: MIDIMapTarget
}

/// What the MIDI thread sees: the mappings, and the control that is being learned. Plain copies under a lock.
final class MIDILearnBox: @unchecked Sendable {
    enum Outcome { case none, learned(MIDIControl), mapped(MIDIMapTarget, UInt8) }
    private let lock = NSLock()
    private var mappings: [MIDIControl: MIDIMapTarget] = [:]
    private var learning = false

    func set(_ list: [MIDIMapping], learning: Bool) {
        lock.lock(); defer { lock.unlock() }
        mappings = Dictionary(list.map { ($0.control, $0.target) }, uniquingKeysWith: { _, b in b })
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
        guard let target = mappings[control] else { return .none }
        return .mapped(target, control.isNote ? 127 : b)
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
        if let data = try? JSONEncoder().encode(midiMappings) { try? data.write(to: midiMapURL, options: .atomic) }
    }

    func mapping(for target: MIDIMapTarget) -> MIDIControl? {
        midiMappings.first { $0.target == target }?.control
    }

    /// The MIDI Learn mode: click a knob, fader or button, then move a control on the device.
    func toggleMIDILearn() {
        midiLearn.toggle()
        learnTarget = nil
        midiLearnBox.set(midiMappings, learning: false)
        status = midiLearn ? "MIDI Learn: click a knob, fader or button in the app, then move a control on your MIDI device. Right-click a control to forget its mapping."
            : (midiMappings.isEmpty ? "" : "\(midiMappings.count) MIDI mapping\(midiMappings.count == 1 ? "" : "s") active")
    }

    /// The control clicked in learn mode: the next controller change or note binds it.
    func beginLearning(_ target: MIDIMapTarget) {
        learnTarget = target
        midiLearnBox.set(midiMappings, learning: true)
        status = "Move a knob or press a button on your MIDI device for \(describe(target))."
    }

    func forgetMapping(_ target: MIDIMapTarget) {
        midiMappings.removeAll { $0.target == target }
        if learnTarget == target { learnTarget = nil }
        saveMIDIMappings()
        status = "Forgot the MIDI mapping of \(describe(target))."
    }

    /// A control moved while a target waited: one control drives one target, and one target has one control.
    func bind(_ control: MIDIControl, to target: MIDIMapTarget) {
        midiMappings.removeAll { $0.target == target || $0.control == control }
        midiMappings.append(MIDIMapping(control: control, target: target))
        learnTarget = nil
        saveMIDIMappings()
        status = "\(control.label) now drives \(describe(target)). Click another control to map it, or leave MIDI Learn."
    }

    /// The MIDI thread saw a mapped control or learned one.
    func midiLearnEvent(_ outcome: MIDILearnBox.Outcome) {
        switch outcome {
        case .none: break
        case .learned(let control): if let target = learnTarget { bind(control, to: target) }
        case .mapped(let target, let value): perform(target, value: value)
        }
    }

    /// Drives a target with a controller value (0...127). Buttons act once per press (a value of 64 or more).
    func perform(_ target: MIDIMapTarget, value: UInt8) {
        let q = Double(value) / 127
        if target.isButton, value < 64 { return }
        switch target {
        case .volume(let id): apply(.setVolume(id: id, db: Fader.db(position: q)), key: "vol\(id)")
        case .pan(let id): apply(.setPan(id: id, pan: q * 2 - 1), key: "pan\(id)")
        case .send(let id, let ret):
            guard let t = project.track(id) else { return }
            setSend(from: t, to: ret, db: q <= 0.01 ? -96 : -48 + 48 * q)
        case .deviceParam(let id, let device, let key):
            guard let t = project.track(id), let d = t.devices.first(where: { $0.id == device }) else { return }
            if d.format == "builtin", let param = BuiltInEffects.spec(d.identifier)?.params.first(where: { $0.key == key }) {
                setDeviceParam(id, device, key, param.isSwitch ? (q >= 0.5 ? 1 : 0) : param.value(atPosition: q))
            } else if let p = d.pluginParams?.first(where: { $0.key == key }) {
                setDeviceParam(id, device, key, p.min + (p.max - p.min) * q)
            }
        case .mute(let id): if let t = project.track(id) { apply(.setMute(id: id, mute: !t.mute)) }
        case .solo(let id): if let t = project.track(id) { toggleSolo(t, additive: true) }
        case .arm(let id): toggleArm(id, additive: true)
        case .stopTrack(let id): if let t = project.track(id) { stopClips(of: t) }
        case .play: togglePlay()
        case .stop: stop()
        case .record: toggleRecordArm()
        case .metronome: toggleMetronome()
        case .scene(let row): launchScene(row)
        case .slot(let id, let row):
            guard let t = project.track(id) else { return }
            if row < t.slots.count, t.slots[row] != nil { launch(track: id, row: row) } else { stopClips(of: t) }
        }
    }

    func describe(_ target: MIDIMapTarget) -> String {
        func name(_ id: TrackID) -> String { project.track(id)?.name ?? "a track" }
        switch target {
        case .volume(let id): return "\(name(id)) volume"
        case .pan(let id): return "\(name(id)) pan"
        case .send(let id, let ret): return "\(name(id)) send to \(name(ret))"
        case .deviceParam(let id, let device, let key):
            let d = project.track(id)?.devices.first { $0.id == device }
            let p = d.flatMap { BuiltInEffects.spec($0.identifier)?.params.first { $0.key == key }?.name } ?? key
            return "\(d?.name ?? "device") \(p) on \(name(id))"
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

/// In MIDI Learn mode a control gets a tinted cover: a click chooses it, a right-click forgets its mapping.
/// Outside learn mode a mapped control shows a small dot.
private struct MIDILearnable: ViewModifier {
    @Environment(AppModel.self) private var model
    let target: MIDIMapTarget

    func body(content: Content) -> some View {
        let mapped = model.mapping(for: target)
        content
            .overlay(alignment: .bottomTrailing) {
                if !model.midiLearn, mapped != nil {
                    Circle().fill(Theme.accent).frame(width: 5, height: 5).padding(2).allowsHitTesting(false)
                }
            }
            .overlay {
                if model.midiLearn {
                    let chosen = model.learnTarget == target
                    ZStack {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.accent.opacity(chosen ? 0.55 : (mapped == nil ? 0.22 : 0.38)))
                        RoundedRectangle(cornerRadius: 3).stroke(chosen ? Color.white : Theme.accent, lineWidth: chosen ? 1.5 : 1)
                        if let mapped {
                            Text(mapped.label).font(.system(size: 8, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 2).background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 2))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.beginLearning(target) }
                    .contextMenu {
                        Button("Learn This Control") { model.beginLearning(target) }
                        Button("Forget MIDI Mapping") { model.forgetMapping(target) }.disabled(mapped == nil)
                    }
                    .hint(mapped.map { "\(model.describe(target)): \($0.label). Click to map another control." }
                          ?? "\(model.describe(target)): not mapped. Click, then move a control on your MIDI device.")
                }
            }
    }
}

extension View {
    /// A knob, fader or button that MIDI Learn can map.
    func midiLearnable(_ target: MIDIMapTarget) -> some View { modifier(MIDILearnable(target: target)) }
}
