import AppKit
import CoreTransferable
import LoopStudioCore
import SwiftUI

/// What a track takes from a drag: an audio file (a clip) or a device from the sidebar (an effect or an
/// instrument or a preset, as the "fx:", "au:" and "preset:" strings the sidebar drags). One drop target takes both, so an effect
/// dropped on a clip slot or a lane lands on that track, not only on the inspector's drop field.
enum DropItem: Transferable {
    case file(URL)
    case device(String)

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { (url: URL) in DropItem.file(url) }
        ProxyRepresentation { (text: String) in DropItem.device(text) }
    }
}

/// What the running drag carries, read from the drag pasteboard while the pointer moves.
enum DragPasteboard {
    /// True while a device from the sidebar or a device card is dragged.
    static var carriesDevices: Bool {
        guard let s = NSPasteboard(name: .drag).string(forType: .string) else { return false }
        return ["fx:", "au:", "preset:", "device:", "devicecopy:"].contains { s.hasPrefix($0) }
    }
}

extension Array where Element == DropItem {
    var files: [URL] { compactMap { if case .file(let url) = $0 { url } else { nil } } }
    /// The strings the sidebar drags, and a device card dragged by its title ("device:<id>", or
    /// "devicecopy:<id>" for a copy). Any other text is ignored.
    var devices: [String] {
        compactMap {
            if case .device(let s) = $0, ["fx:", "au:", "preset:", "device:", "devicecopy:"].contains(where: { s.hasPrefix($0) }) { s } else { nil }
        }
    }
    /// Tracks dragged by their header: "track:<id>".
    var tracks: [TrackID] { compactMap { if case .device(let s) = $0 { AppModel.draggedTrack(s) } else { nil } } }
    /// Session slots dragged by their name: "slot:<track>:<row>".
    var slots: [(track: TrackID, row: Int)] {
        compactMap {
            guard case .device(let s) = $0, s.hasPrefix("slot:") else { return nil }
            let parts = s.dropFirst(5).split(separator: ":")
            guard parts.count == 2, let uuid = UUID(uuidString: String(parts[0])), let row = Int(parts[1]) else { return nil }
            return (TrackID(uuid), row)
        }
    }
}

extension AppModel {
    /// The string a track header drags.
    nonisolated static func trackDrag(_ id: TrackID) -> String { "track:\(id.rawValue.uuidString)" }

    nonisolated static func draggedTrack(_ s: String) -> TrackID? {
        guard s.hasPrefix("track:"), let uuid = UUID(uuidString: String(s.dropFirst(6))) else { return nil }
        return TrackID(uuid)
    }

    /// A track header took a drop: a dragged track lands in front of it, a device lands on it.
    @discardableResult
    func dropOnTrackHeader(_ items: [String], track: TrackID) -> Bool {
        let moved = items.compactMap(Self.draggedTrack)
        if !moved.isEmpty {
            for id in moved { moveTrack(id, before: track) }
            return true
        }
        return dropDevices(items, on: track)
    }

    /// Moves a track in front of `target`, or to the end with `nil`. The master never moves.
    func moveTrack(_ id: TrackID, before target: TrackID?) {
        guard id != target, let from = project.tracks.firstIndex(where: { $0.id == id }) else { return }
        let to = target.flatMap { t in project.tracks.firstIndex { $0.id == t } } ?? project.tracks.count
        let index = from < to ? to - 1 : to
        guard index != from else { return }
        apply(.moveTrack(id: id, index: index))
        selectedTrack = id
    }

    /// Files make clips in the slot, devices go on the track.
    @discardableResult
    func dropOnSlot(_ items: [DropItem], track: TrackID, row: Int) -> Bool {
        var used = false
        if !items.files.isEmpty { used = dropOnSlot(items.files, track: track, row: row) || used }
        if !items.devices.isEmpty { used = dropDevices(items.devices, on: track) || used }
        // Option held at the drop: the clips are copied, not moved.
        let copy = NSEvent.modifierFlags.contains(.option)
        for s in items.slots { moveSlots(from: s, to: (track, row), copy: copy); used = true }
        return used
    }

    /// Files make clips at the drop position, devices go on the track.
    @discardableResult
    func dropOnTimeline(_ items: [DropItem], track: TrackID, at tick: Tick) -> Bool {
        var used = false
        if !items.files.isEmpty { used = dropOnTimeline(items.files, track: track, at: tick) || used }
        if !items.devices.isEmpty { used = dropDevices(items.devices, on: track) || used }
        return used
    }

    /// On empty space: a file makes a new audio track, an instrument a new MIDI track, an effect a new audio track.
    @discardableResult
    func dropOnNewTrack(_ items: [DropItem]) -> Bool {
        var used = false
        if !items.files.isEmpty { used = dropOnNewTrack(items.files) || used }
        if !items.devices.isEmpty { used = dropDevicesOnNewTrack(items.devices) || used }
        for id in items.tracks { moveTrack(id, before: nil); used = true }
        return used
    }

    /// Every dragged device gets a track of its own: a MIDI track named after an instrument, an audio track
    /// for an effect, a preset or a moved device card.
    @discardableResult
    func dropDevicesOnNewTrack(_ items: [String]) -> Bool {
        var used = false
        for item in items {
            if item.hasPrefix("au:") {
                let parts = item.dropFirst(3).split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                if parts[0].hasPrefix("aumu") {
                    placeInstrument(DeviceSlot(format: "audiounit", identifier: parts[0], name: parts[1]), on: nil)
                    used = true
                    continue
                }
            } else if item.hasPrefix("fx:"), let spec = BuiltInEffects.spec(String(item.dropFirst(3))), spec.isInstrument,
                      let slot = BuiltInEffects.makeSlot(spec.id) {
                placeInstrument(slot, on: nil)
                used = true
                continue
            }
            addTrack(kind: .audio)
            guard let track = project.tracks.last?.id else { continue }
            used = dropDevices([item], on: track) || used
        }
        return used
    }
}
