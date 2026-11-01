import CoreTransferable
import LoopStudioCore
import SwiftUI

/// What a track takes from a drag: an audio file (a clip) or a device from the sidebar (an effect or an
/// instrument, as the "fx:" and "au:" strings the sidebar drags). One drop target takes both, so an effect
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
    /// Only the strings the sidebar drags. Any other text is ignored.
    var devices: [String] { compactMap { if case .device(let s) = $0, s.hasPrefix("fx:") || s.hasPrefix("au:") { s } else { nil } } }
}

extension AppModel {
    /// Files make clips in the slot, devices go on the track.
    @discardableResult
    func dropOnSlot(_ items: [DropItem], track: TrackID, row: Int) -> Bool {
        var used = false
        if !items.files.isEmpty { used = dropOnSlot(items.files, track: track, row: row) || used }
        if !items.devices.isEmpty { used = dropDevices(items.devices, on: track) || used }
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
