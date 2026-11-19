import LoopStudioCore
import SwiftUI

/// What a right-click sent to the assistant: one line for the person, and the ids and positions for the model.
/// "Send to Assistant" puts it under the input; the next request refers to it.
struct AssistantAttachment: Equatable {
    var label: String
    var detail: String
}

/// The menu item. The sidebar shows the assistant, the chip appears, the field takes the keyboard.
struct SendToAssistant: View {
    @Environment(AssistantModel.self) private var assistant
    var title = "Send to Assistant"
    let make: () -> AssistantAttachment

    var body: some View {
        Button(title) { assistant.attach(make()) }
    }
}

extension AppModel {
    private func position(of track: Track) -> String {
        track.kind == .master ? "master" : (project.tracks.firstIndex { $0.id == track.id }.map { "track \($0 + 1)" } ?? "track")
    }

    private func bars(_ t: Tick) -> String { String(format: "%.2f bars", Double(t.rawValue) / Double(barTicks)) }

    func attachment(track: Track) -> AssistantAttachment {
        let clips = track.clips.count + track.slots.compactMap { $0 }.count
        return AssistantAttachment(
            label: "Track \"\(track.name)\"",
            detail: "\(position(of: track)) \"\(track.name)\" (id \(track.id.rawValue.uuidString), kind \(track.kind), "
                + "\(track.devices.count) devices, \(clips) clips, volume \(String(format: "%.1f", track.volumeDb)) dB"
                + (track.mute ? ", muted" : "") + (track.solo ? ", solo" : "") + ")")
    }

    /// A clip in the arrangement, or in a session slot when `slot` is given (0-based row).
    func attachment(clip: Clip, track: Track, slot: Int? = nil) -> AssistantAttachment {
        let name = clipName(clip)
        let place = slot.map { "\(position(of: track)) \"\(track.name)\", slot \($0 + 1)" }
            ?? "\(position(of: track)) \"\(track.name)\", bar \(clip.start.rawValue / barTicks + 1), start tick \(clip.start.rawValue)"
        var detail = "clip \"\(name)\" (id \(clip.id.rawValue.uuidString)) on \(place), length \(clip.length.rawValue) ticks (\(bars(clip.length)))"
        switch clip {
        case .midi(let m):
            detail += ", MIDI, \(m.notes.count) notes" + (m.loop ? ", loops" : "")
            if !m.notes.isEmpty, m.notes.count <= 160 {
                let list = m.notes.sorted { ($0.tick, $0.pitch) < ($1.tick, $1.pitch) }
                    .map { "\($0.tick.rawValue)/\($0.length.rawValue)/\($0.pitch)/\($0.velocity)" + ($0.muted ? "m" : "") }
                detail += ". Notes as tick/length/pitch/velocity (m = muted): " + list.joined(separator: " ")
            }
        case .audio(let a):
            let asset = project.assets.first { $0.id == a.asset }
            detail += ", audio from \"\(asset?.name ?? "?")\", offset \(a.offset.rawValue) ticks, gain \(String(format: "%.1f", a.gainDb)) dB" + (a.loop ? ", loops" : "")
        case .dummy:
            detail += ", automation clip"
        }
        return AssistantAttachment(label: "Clip \"\(name)\" · \(slot.map { "slot \($0 + 1)" } ?? "arrangement")", detail: detail)
    }

    /// Notes of a MIDI clip: the marked ones, or the one under the pointer.
    func attachment(notes: [MIDINote], clip: MIDIClip) -> AssistantAttachment {
        let track = project.findClip(clip.id).flatMap { project.track($0.track) }
        let list = notes.sorted { ($0.tick, $0.pitch) < ($1.tick, $1.pitch) }
            .map { "\($0.tick.rawValue)/\($0.length.rawValue)/\($0.pitch)/\($0.velocity)" + ($0.muted ? "m" : "") }
        let where_ = track.map { " on \(position(of: $0)) \"\($0.name)\"" } ?? ""
        let names = notes.count == 1 ? MIDIControl.noteName(notes[0].pitch) : "\(notes.count) notes"
        return AssistantAttachment(
            label: "\(names) in clip \"\(clipName(.midi(clip)))\"",
            detail: "\(notes.count) of the \(clip.notes.count) notes of clip \"\(clipName(.midi(clip)))\" (id \(clip.id.rawValue.uuidString))\(where_), "
                + "as tick/length/pitch/velocity (m = muted): " + list.joined(separator: " ")
                + ". A change to these notes keeps the other notes of the clip (notes_set with replace: true and the full list).")
    }

    func attachment(scene row: Int) -> AssistantAttachment {
        let names = project.tracks.compactMap { t -> String? in
            guard row < t.slots.count, let s = t.slots[row] else { return nil }
            return "\"\(clipName(s.clip))\" on \"\(t.name)\""
        }
        return AssistantAttachment(
            label: "Scene \(row + 1)",
            detail: "scene \(row + 1) (session row \(row + 1) of \(project.tracks.first?.slots.count ?? 0)): "
                + (names.isEmpty ? "no clips" : names.joined(separator: ", ")))
    }

    func attachment(device: DeviceSlot, track: Track) -> AssistantAttachment {
        let list = siblings(of: device.id, on: track)
        let index = list.firstIndex { $0.id == device.id }.map { "position \($0 + 1) of \(list.count)" } ?? "in a chain"
        let spec = BuiltInEffects.spec(device.identifier)
        var detail = "device \"\(device.name)\" (id \(device.id.rawValue.uuidString), \(device.format) \(device.identifier)) on \(position(of: track)) \"\(track.name)\", \(index)"
            + (device.bypassed ? ", bypassed" : "")
        if let spec, !spec.params.isEmpty, spec.params.count <= 48 {
            let values = spec.params.map { p in "\(p.key)=\(p.format(device.params[p.key] ?? p.def))" }
            detail += ". Parameters: " + values.joined(separator: ", ")
        }
        return AssistantAttachment(label: "Device \"\(device.name)\" · \(track.name)", detail: detail)
    }

    func attachment(param: EffectParam, value: Double, device: DeviceSlot, track: Track) -> AssistantAttachment {
        AssistantAttachment(
            label: "\(param.name) of \"\(device.name)\"",
            detail: "parameter \"\(param.name)\" (key \(param.key)) of device \"\(device.name)\" (id \(device.id.rawValue.uuidString)) "
                + "on \(position(of: track)) \"\(track.name)\": value \(param.format(value)) (raw \(value)), range \(param.min) to \(param.max)"
                + (param.choices.isEmpty ? "" : ", choices " + param.choices.joined(separator: " | ")))
    }

    func attachment(file url: URL) -> AssistantAttachment {
        AssistantAttachment(label: "File \"\(url.lastPathComponent)\"", detail: "audio file \"\(url.lastPathComponent)\" at \(url.path), not in the project yet (sample_drop or asset_import adds it)")
    }
}
