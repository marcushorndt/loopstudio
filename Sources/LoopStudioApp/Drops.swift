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

extension Array where Element == DropItem {
    var files: [URL] { compactMap { if case .file(let url) = $0 { url } else { nil } } }
    /// The strings the sidebar drags, and a device card dragged by its title ("device:<id>", or
    /// "devicecopy:<id>" for a copy). Any other text is ignored.
    var devices: [String] {
        compactMap {
            if case .device(let s) = $0, ["fx:", "au:", "preset:", "device:", "devicecopy:"].contains(where: { s.hasPrefix($0) }) { s } else { nil }
        }
    }
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
    /// Files make clips in the slot, devices go on the track.
    @discardableResult
    func dropOnSlot(_ items: [DropItem], track: TrackID, row: Int) -> Bool {
        var used = false
        if !items.files.isEmpty { used = dropOnSlot(items.files, track: track, row: row) || used }
        if !items.devices.isEmpty { used = dropDevices(items.devices, on: track) || used }
        for s in items.slots { moveSlots(from: s, to: (track, row)); used = true }
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

    /// On empty space: a file makes a new audio track, an instrument a new MIDI track, an effect goes on the selected track.
    @discardableResult
    func dropOnNewTrack(_ items: [DropItem]) -> Bool {
        var used = false
        if !items.files.isEmpty { used = dropOnNewTrack(items.files) || used }
        if !items.devices.isEmpty { used = dropDevices(items.devices, on: nil) || used }
        return used
    }
}
