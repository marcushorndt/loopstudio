import LoopStudioCore
import SwiftUI

/// Macro map mode: one rack, one macro, waiting for a click on a knob inside the rack.
struct MacroMapSession: Equatable {
    var track: TrackID
    var rack: DeviceID
    var macro: Int
}

/// Which zones the chain list draws: the chain selector, or (MIDI racks) the key or velocity zones.
enum ZoneView: String, CaseIterable { case chain, key, velocity }

extension AppModel {
    // MARK: Looking up

    /// The chain of a rack whose devices the panel shows: the last one clicked, else the first.
    func shownChain(of rack: DeviceSlot) -> RackChain? {
        guard let chains = rack.rack?.chains, !chains.isEmpty else { return nil }
        if let id = shownChains[rack.id], let chain = chains.first(where: { $0.id == id }) { return chain }
        return chains[0]
    }

    func showChain(_ chain: ChainID, of rack: DeviceID) {
        shownChains[rack] = chain
    }

    /// The device list that holds a device: the track's, or its chain's.
    func siblings(of device: DeviceID, on track: Track) -> [DeviceSlot] {
        track.chainHolding(device)?.devices ?? track.devices
    }

    /// A macro drives this parameter: the rack, the mapping and the value it gives now.
    func macroDriving(_ address: ParameterAddress, on track: Track) -> (rack: DeviceSlot, mapping: MacroMapping, value: Double)? {
        project.macroDriving(address, on: track)
    }

    // MARK: Macro map mode

    /// Enters macro map mode for one macro, or leaves it when that macro is already waiting.
    func toggleMacroMap(track: TrackID, rack: DeviceID, macro: Int) {
        let session = MacroMapSession(track: track, rack: rack, macro: macro)
        if macroMap == session { endMacroMap(); return }
        macroMap = session
        if midiLearn { toggleMIDILearn() }
        let name = project.track(track)?.device(rack).map { ($0.rack?.macroName(macro) ?? "Macro \(macro + 1)") + " of \($0.name)" } ?? "the macro"
        status = "Map mode: click a knob inside the rack to hang it on \(name). Click a macro knob to pick another macro. Esc ends it."
    }

    func endMacroMap() {
        macroMap = nil
        status = "Map mode off"
    }

    /// The knob clicked in map mode: it hangs on the waiting macro, over its whole range.
    func mapToMacro(_ address: ParameterAddress) {
        guard let session = macroMap, let track = project.track(session.track) else { return }
        if let existing = macroDriving(address, on: track) {
            apply(.removeMacroMapping(track: track.id, rack: existing.rack.id, mapping: existing.mapping.id))
        }
        let mapping = MacroMapping(macro: session.macro, target: address)
        do {
            try tryApply(.setMacroMapping(track: track.id, rack: session.rack, mapping: mapping))
            let rack = track.device(session.rack)
            let target = project.automationTarget(address, on: track)?.name ?? address.parameter
            status = "\(target) now follows \(rack?.rack?.macroName(session.macro) ?? "Macro \(session.macro + 1)"). Click another knob, or Esc."
        } catch {
            status = "Cannot map: \(error)"
        }
    }

    func unmap(_ address: ParameterAddress, on track: Track) {
        guard let driving = macroDriving(address, on: track) else { return }
        apply(.removeMacroMapping(track: track.id, rack: driving.rack.id, mapping: driving.mapping.id))
    }

    func setMacroMapping(_ mapping: MacroMapping, rack: DeviceID, on track: TrackID) {
        apply(.setMacroMapping(track: track, rack: rack, mapping: mapping), key: "map\(mapping.id)")
    }

    func renameMacro(_ index: Int, to name: String, rack: DeviceID, on track: TrackID) {
        apply(.setMacroName(track: track, rack: rack, index: index, name: name))
    }

    // MARK: Chains

    func addChain(to rack: DeviceID, on track: TrackID) {
        guard let t = project.track(track), let r = t.device(rack), let count = r.rack?.chains.count else { return }
        let chain = RackChain(name: "Chain \(count + 1)", colorIndex: count % 8)
        apply(.addChain(track: track, rack: rack, chain: chain, index: nil))
        shownChains[rack] = chain.id
    }

    func removeChain(_ chain: ChainID, from rack: DeviceID, on track: TrackID) {
        apply(.removeChain(track: track, rack: rack, chain: chain))
    }

    /// Changes one chain's settings (not its devices). `key` coalesces a drag into one undo step.
    func setChain(_ chain: RackChain, rack: DeviceID, on track: TrackID, key: String? = nil) {
        apply(.setChain(track: track, rack: rack, chain: chain), key: key)
    }

    /// Splits the selector strip evenly among the chains, with `fade` positions of overlap between neighbours.
    func distributeZones(rack: DeviceID, on track: TrackID, fade: Int) {
        guard let t = project.track(track), let chains = t.device(rack)?.rack?.chains, !chains.isEmpty else { return }
        let zones = Rack.distributedZones(count: chains.count, fade: fade)
        apply(.batch(commands: zip(chains, zones).map { chain, zone in
            var c = chain; c.zone = zone
            return .setChain(track: track, rack: rack, chain: c)
        }))
        status = fade > 0 ? "The chains share the selector strip, with crossfades between them." : "The chains share the selector strip."
    }

    /// MIDI racks: every chain gets the whole keyboard and every velocity again.
    func clearNoteZones(rack: DeviceID, on track: TrackID) {
        guard let t = project.track(track), let chains = t.device(rack)?.rack?.chains else { return }
        apply(.batch(commands: chains.map { chain in
            var c = chain; c.keyZone = nil; c.velocityZone = nil
            return .setChain(track: track, rack: rack, chain: c)
        }))
    }

    /// The macro and chain panels of a rack card. View state, saved with the project like a folded card.
    func toggleRackPanel(_ rack: DeviceID, macros: Bool) {
        let key = "\(rack):\(macros ? "macros" : "chains")"
        if hiddenRackPanels.contains(key) { hiddenRackPanels.remove(key) } else { hiddenRackPanels.insert(key) }
        scheduleSave()
    }

    func rackPanelShown(_ rack: DeviceID, macros: Bool) -> Bool {
        !hiddenRackPanels.contains("\(rack):\(macros ? "macros" : "chains")")
    }

    // MARK: Grouping

    /// Wraps a device in a new rack at its place, like Live's Group (⌘G). An instrument gets a MIDI rack,
    /// an effect an audio effect rack. The device keeps its ID, so its automation and mappings stay.
    func groupDevice(_ id: DeviceID, on trackID: TrackID) {
        guard let track = project.track(trackID), let device = track.device(id) else { return }
        let isInstrument = self.isInstrument(device)
        guard var rack = BuiltInEffects.makeSlot(isInstrument ? "midirack" : "audiorack") else { return }
        rack.rack?.chains[0].devices = [device]
        rack.rack?.chains[0].name = device.name
        let chain = track.chainHolding(id)
        var list = siblings(of: id, on: track)
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i] = rack
        apply(.setDevices(track: trackID, chain: chain?.id, devices: list))
        selectedDevice = rack.id
        status = "\(device.name) sits in a new \(rack.name). Add chains, then map its knobs to the macros."
    }

    /// Puts the devices of every chain back at the rack's place, in chain order. The rack and its macros go.
    func ungroupRack(_ id: DeviceID, on trackID: TrackID) {
        guard let track = project.track(trackID), let rack = track.device(id), let chains = rack.rack?.chains else { return }
        let chain = track.chainHolding(id)
        var list = siblings(of: id, on: track)
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list.replaceSubrange(i...i, with: chains.flatMap(\.devices))
        apply(.setDevices(track: trackID, chain: chain?.id, devices: list))
        if selectedDevice == id { selectedDevice = nil }
        status = "\(rack.name) is gone; its devices stay in a row."
    }

    // MARK: Devices into chains

    /// Adds a built-in effect or instrument to a chain of a rack. An instrument goes to a MIDI rack's chain
    /// in front of its effects; a chain holds one instrument.
    func addEffect(_ id: String, toChain chain: ChainID, on trackID: TrackID) {
        guard let spec = BuiltInEffects.spec(id), var slot = BuiltInEffects.makeSlot(id), let track = project.track(trackID),
              let holder = track.chain(chain), let rack = track.rackHolding(chain: chain) else { return }
        if spec.isInstrument {
            guard rack.isMIDIRack else { status = "An instrument goes into a MIDI Rack, not an effect rack"; return }
            if let old = holder.devices.first(where: isInstrument) {
                apply(.batch(commands: [.removeDevice(track: trackID, device: old.id),
                                        .insertDeviceInChain(track: trackID, chain: chain, device: slot, index: 0)]))
                status = "\(slot.name) took the place of \(old.name) in \(holder.name)"
                return
            }
            apply(.insertDeviceInChain(track: trackID, chain: chain, device: slot, index: 0))
            return
        }
        if id == "delay" { slot.params["timeMsSync"] = 1 }
        apply(.insertDeviceInChain(track: trackID, chain: chain, device: slot, index: nil))
    }

    func addAudioUnit(identifier: String, name: String, toChain chain: ChainID, on trackID: TrackID) {
        let slot = DeviceSlot(format: "audiounit", identifier: identifier, name: name)
        guard let track = project.track(trackID), let holder = track.chain(chain), let rack = track.rackHolding(chain: chain) else { return }
        if identifier.hasPrefix("aumu") {
            guard rack.isMIDIRack else { status = "An instrument goes into a MIDI Rack, not an effect rack"; return }
            if let old = holder.devices.first(where: isInstrument) {
                apply(.batch(commands: [.removeDevice(track: trackID, device: old.id),
                                        .insertDeviceInChain(track: trackID, chain: chain, device: slot, index: 0)]))
                return
            }
            apply(.insertDeviceInChain(track: trackID, chain: chain, device: slot, index: 0))
            return
        }
        apply(.insertDeviceInChain(track: trackID, chain: chain, device: slot, index: nil))
    }

    /// Dropped browser items on a chain of a rack.
    func dropDevices(_ items: [String], on track: TrackID, chain: ChainID) -> Bool {
        var used = false
        for item in items {
            if item.hasPrefix("fx:") { addEffect(String(item.dropFirst(3)), toChain: chain, on: track); used = true }
            else if item.hasPrefix("au:") {
                let parts = item.dropFirst(3).split(separator: "|", maxSplits: 1).map(String.init)
                if parts.count == 2 { addAudioUnit(identifier: parts[0], name: parts[1], toChain: chain, on: track); used = true }
            }
        }
        if used { detailTab = .devices; detailOpen = true }
        return used
    }

    /// Moves a device into another chain (or onto the track, `nil`) at the end. Automation and mappings stay.
    func moveDevice(_ id: DeviceID, on trackID: TrackID, toChain chain: ChainID?) {
        guard let track = project.track(trackID), let device = track.device(id) else { return }
        let from = track.chainHolding(id)
        guard from?.id != chain else { return }
        // A rack cannot move into its own chain.
        if let chain, device.nestedChainIDs.contains(chain.rawValue) { status = "A rack cannot move into one of its own chains"; return }
        var source = siblings(of: id, on: track)
        source.removeAll { $0.id == id }
        var destination = chain.flatMap { track.chain($0)?.devices } ?? track.devices
        destination.append(device)
        apply(.batch(commands: [.setDevices(track: trackID, chain: from?.id, devices: source),
                                .setDevices(track: trackID, chain: chain, devices: destination)]))
    }
}
