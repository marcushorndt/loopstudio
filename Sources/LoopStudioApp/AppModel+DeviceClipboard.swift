import AppKit
import LoopStudioCore

/// Devices on the clipboard and devices between tracks: ⌘C/⌘X/⌘V on a marked device card, ⌘D for a copy
/// next to it, a drag to another track, and Option while dropping for a copy instead of a move. A copy
/// keeps every parameter: the knobs, a plugin's current state, a rack with everything inside.
extension AppModel {
    /// The track that holds a device, at any depth, and the device as it is now.
    func deviceLocation(_ id: DeviceID) -> (track: Track, device: DeviceSlot)? {
        for t in project.allTracks { if let d = t.device(id) { return (t, d) } }
        return nil
    }

    /// The device with its plugin state as it is in the plugin right now, not as it was last saved. Nested
    /// plugins in a rack get theirs too.
    func snapshot(_ device: DeviceSlot) -> DeviceSlot {
        var copy = device
        if copy.format == "audiounit", let data = host.units[copy.id]?.savedState() { copy.state = data }
        if var rack = copy.rack {
            rack.chains = rack.chains.map { chain in
                var c = chain
                c.devices = chain.devices.map(snapshot)
                return c
            }
            copy.rack = rack
        }
        return copy
    }

    // MARK: Copy, cut, paste

    /// True when a device card has the focus: ⌘C, ⌘X and ⌘D act on it, not on clips.
    var deviceFocused: Bool { selectedDevice != nil && selectedNotes.isEmpty }

    func copyDevice() {
        guard let id = selectedDevice, let (_, device) = deviceLocation(id) else { return }
        deviceClipboard = snapshot(device)
        clipboard = []
        noteClipboard = []
        status = "Copied \(device.name)"
    }

    func cutDevice() {
        guard let id = selectedDevice, let (track, _) = deviceLocation(id) else { return }
        copyDevice()
        apply(.removeDevice(track: track.id, device: id))
        selectedDevice = nil
    }

    /// The copied device on the selected track: an effect after the marked device there, or at the end of the
    /// chain; an instrument in the instrument's place of a MIDI track.
    func pasteDevice() {
        guard let source = deviceClipboard else { return }
        guard let target = selectedTrack.flatMap({ project.track($0) }) ?? project.tracks.first else { status = "Add a track first"; return }
        var map: [UUID: UUID] = [:]
        let copy = source.withFreshIDs(map: &map)
        if isInstrument(copy) {
            guard target.kind == .midi else { status = "\(copy.name) is an instrument: select a MIDI track to paste it"; return }
            placeInstrument(copy, on: target)
        } else {
            var chain: ChainID?, index: Int?
            if let marked = selectedDevice, target.device(marked) != nil {
                chain = target.chainHolding(marked)?.id
                let list = siblings(of: marked, on: target)
                index = (list.firstIndex { $0.id == marked }).map { $0 + 1 }
            }
            if let chain {
                apply(.insertDeviceInChain(track: target.id, chain: chain, device: copy, index: index))
            } else {
                apply(.insertDevice(track: target.id, device: copy, index: index))
            }
            selectedTrack = target.id
        }
        selectedDevice = copy.id
        detailTab = .devices
        detailOpen = true
        status = "Pasted \(copy.name) on \(target.name)"
    }

    // MARK: Between tracks

    /// Puts a copy of a device on another track or another chain, at `index` or at the end. An instrument
    /// needs a MIDI track and takes the place of the one there.
    func copyDevice(_ id: DeviceID, to trackID: TrackID, chain: ChainID?, at index: Int? = nil) {
        guard let (_, device) = deviceLocation(id), let target = project.track(trackID) else { return }
        var map: [UUID: UUID] = [:]
        let copy = snapshot(device).withFreshIDs(map: &map)
        if isInstrument(copy), chain == nil {
            guard target.kind == .midi else { status = "\(copy.name) is an instrument: it needs a MIDI track"; return }
            placeInstrument(copy, on: target)
        } else if let chain {
            apply(.insertDeviceInChain(track: trackID, chain: chain, device: copy, index: index))
        } else {
            apply(.insertDevice(track: trackID, device: copy, index: index))
        }
        selectedTrack = trackID
        selectedDevice = copy.id
        status = "Copied \(device.name) to \(target.name)"
    }

    /// Moves a device from the track it is on to another track or another chain, with its parameters. The
    /// automation of the old track does not follow: its lanes belong to that track.
    func transferDevice(_ id: DeviceID, to trackID: TrackID, chain: ChainID?, at index: Int? = nil) {
        guard let (source, device) = deviceLocation(id), source.id != trackID, let target = project.track(trackID) else { return }
        let moved = snapshot(device)
        var commands: [Command] = [.removeDevice(track: source.id, device: id)]
        if isInstrument(moved), chain == nil {
            guard target.kind == .midi else { status = "\(moved.name) is an instrument: it needs a MIDI track"; return }
            if let old = target.devices.first(where: isInstrument) { commands.append(.removeDevice(track: trackID, device: old.id)) }
            commands.append(.insertDevice(track: trackID, device: moved, index: 0))
        } else if let chain {
            commands.append(.insertDeviceInChain(track: trackID, chain: chain, device: moved, index: index))
        } else {
            commands.append(.insertDevice(track: trackID, device: moved, index: index))
        }
        apply(.batch(commands: commands))
        selectedTrack = trackID
        selectedDevice = id
        status = "Moved \(moved.name) to \(target.name)"
    }

    /// A card dropped on a track or a chain: a move, or a copy when it came from another track with Option
    /// held, or from anywhere with Option held. `copy` is what the drop read from the keyboard.
    func dropDevice(_ id: DeviceID, copy: Bool, on trackID: TrackID, chain: ChainID?, at index: Int?) {
        guard let (source, _) = deviceLocation(id) else { return }
        if copy { copyDevice(id, to: trackID, chain: chain, at: index) }
        else if source.id == trackID { moveDevice(id, on: trackID, toChain: chain, at: index) }
        else { transferDevice(id, to: trackID, chain: chain, at: index) }
    }

    /// The device behind a "device:<uuid>" drag string, and whether the drop asked for a copy: the string
    /// says so ("devicecopy:") or Option is down at the drop.
    static func draggedDevice(_ item: String) -> (id: DeviceID, copy: Bool)? {
        let copy: Bool
        let rest: Substring
        if item.hasPrefix("device:") { copy = false; rest = item.dropFirst(7) }
        else if item.hasPrefix("devicecopy:") { copy = true; rest = item.dropFirst(11) }
        else { return nil }
        guard let uuid = UUID(uuidString: String(rest)) else { return nil }
        return (DeviceID(uuid), copy || NSEvent.modifierFlags.contains(.option))
    }
}
