import AppKit
import LoopStudioCore
import UniformTypeIdentifiers

/// "Save Preset…" on a device: the chain shows a prompt for the name.
struct PresetPrompt: Identifiable, Equatable {
    var track: TrackID
    var device: DeviceID
    var name: String
    var id: DeviceID { device }
}

/// Device presets: a device's settings as a file, to load again on any project. Built-in effects save their
/// parameters, plugins their state, racks everything inside. The library is one folder per device kind
/// under Application Support; the sidebar lists it, and a preset drags onto a track like an effect.
extension AppModel {
    /// The file type of a preset: `.lspreset`, JSON inside.
    static let presetType = UTType(filenameExtension: DevicePreset.fileExtension, conformingTo: .json) ?? .json

    func reloadPresets() {
        presets = presetLibrary.list()
    }

    /// Presets for one device kind.
    func presets(for identifier: String) -> [PresetEntry] {
        presets.filter { $0.identifier == identifier }
    }

    /// The preset a device would save now: a plugin's state comes from the running instance.
    func makePreset(_ device: DeviceSlot, name: String) -> DevicePreset {
        var slot = device
        if slot.format == "audiounit", let unit = host.units[slot.id], let data = unit.savedState() { slot.state = data }
        if slot.isRack {
            // Plugins inside a rack: their states too.
            for inner in slot.selfAndNested where inner.format == "audiounit" {
                if let unit = host.units[inner.id], let data = unit.savedState() {
                    _ = try? slot.withNestedDevice(inner.id) { $0.state = data }
                }
            }
        }
        return DevicePreset(name: name, device: slot)
    }

    /// Writes the preset into the library. A preset of that name for the same device kind is replaced.
    func savePreset(track trackID: TrackID, device id: DeviceID, name: String) {
        guard let track = project.track(trackID), let device = track.device(id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { status = "A preset needs a name"; return }
        let preset = makePreset(device, name: trimmed)
        do {
            let url = try presetLibrary.save(preset)
            reloadPresets()
            status = "Saved the preset \"\(trimmed)\" (\(url.deletingLastPathComponent().lastPathComponent))"
        } catch {
            status = "Could not save the preset: \(error.localizedDescription)"
        }
    }

    /// Loads a preset's settings onto a device of the same kind. The device keeps its ID, so automation,
    /// macro mappings and MIDI mappings stay.
    func loadPreset(_ preset: DevicePreset, onto id: DeviceID, on trackID: TrackID) {
        guard let track = project.track(trackID), let device = track.device(id) else { return }
        guard preset.device.identifier == device.identifier, preset.device.format == device.format else {
            status = PresetError.wrongDevice(expected: device.name, found: preset.device.name).description
            return
        }
        let slot = preset.applied(to: device)
        let chain = track.chainHolding(id)
        var list = siblings(of: id, on: track)
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i] = slot
        apply(.setDevices(track: trackID, chain: chain?.id, devices: list))
        // A running plugin takes the state now; one that loads later takes it from the slot.
        if slot.format == "audiounit", let data = slot.state { host.units[id]?.restore(state: data) }
        status = "Loaded the preset \"\(preset.name)\" onto \(slot.name)"
    }

    func loadPreset(_ entry: PresetEntry, onto id: DeviceID, on track: TrackID) {
        do { loadPreset(try DevicePreset.read(entry.url), onto: id, on: track) }
        catch { status = "Could not read the preset: \(error)" }
    }

    /// Puts a preset's device on a track (the selected one when `track` is nil) or into a chain, at
    /// `index` or at the end. An instrument goes where an instrument goes.
    func insertPreset(_ preset: DevicePreset, on trackID: TrackID?, chain: ChainID?, at index: Int?) {
        let slot = preset.makeSlot()
        if let chain, let trackID {
            guard let track = project.track(trackID), let holder = track.chain(chain), let rack = track.rackHolding(chain: chain) else { return }
            if isInstrument(slot) {
                guard rack.isMIDIRack else { status = "An instrument goes into a MIDI Rack, not an effect rack"; return }
                if let old = holder.devices.first(where: isInstrument) {
                    apply(.batch(commands: [.removeDevice(track: trackID, device: old.id),
                                            .insertDeviceInChain(track: trackID, chain: chain, device: slot, index: 0)]))
                } else {
                    apply(.insertDeviceInChain(track: trackID, chain: chain, device: slot, index: 0))
                }
            } else {
                apply(.insertDeviceInChain(track: trackID, chain: chain, device: slot, index: index))
            }
        } else {
            let target = (trackID ?? selectedTrack).flatMap { project.track($0) }
            if isInstrument(slot) {
                placeInstrument(slot, on: target)
                return
            }
            guard let target = target ?? project.tracks.first else { status = "Add a track first"; return }
            apply(.insertDevice(track: target.id, device: slot, index: index))
            selectedTrack = target.id
        }
        detailTab = .devices
        detailOpen = true
    }

    func insertPreset(at url: URL, on track: TrackID?, chain: ChainID?, at index: Int?) {
        do { insertPreset(try DevicePreset.read(url), on: track, chain: chain, at: index) }
        catch { status = "Could not read the preset: \(error)" }
    }

    /// "Import Preset…": copies one or more preset files into the library. With a device given, a matching
    /// preset also loads onto it.
    func importPresets(onto device: DeviceID? = nil, on track: TrackID? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Import Presets"
        panel.message = "Choose LoopStudio preset files (.\(DevicePreset.fileExtension))."
        panel.allowedContentTypes = [Self.presetType, .json]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        var imported = 0
        var loaded: String?
        for url in panel.urls {
            do {
                let (_, preset) = try presetLibrary.importFile(url)
                imported += 1
                if let device, let track, loaded == nil, let slot = project.track(track)?.device(device),
                   slot.identifier == preset.device.identifier {
                    loadPreset(preset, onto: device, on: track)
                    loaded = preset.name
                }
            } catch {
                status = "Could not import \(url.lastPathComponent): \(error)"
            }
        }
        reloadPresets()
        if imported > 0 {
            status = "Imported \(imported) preset\(imported == 1 ? "" : "s")" + (loaded.map { ", loaded \"\($0)\"" } ?? "")
            if device == nil { sidebarTab = .effects }
        }
    }

    /// "Export Preset…": the device's settings as a file wherever the user wants it.
    func exportPreset(track trackID: TrackID, device id: DeviceID) {
        guard let track = project.track(trackID), let device = track.device(id) else { return }
        let panel = NSSavePanel()
        panel.title = "Export Preset"
        panel.nameFieldStringValue = PresetLibrary.safe(device.name) + "." + DevicePreset.fileExtension
        panel.allowedContentTypes = [Self.presetType]
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension != DevicePreset.fileExtension { url.appendPathExtension(DevicePreset.fileExtension) }
        let name = url.deletingPathExtension().lastPathComponent
        do {
            try makePreset(device, name: name).write(to: url)
            status = "Exported the preset \"\(name)\""
        } catch {
            status = "Could not export the preset: \(error.localizedDescription)"
        }
    }

    func deletePreset(_ entry: PresetEntry) {
        do {
            try presetLibrary.delete(entry)
            reloadPresets()
            status = "Deleted the preset \"\(entry.name)\""
        } catch {
            status = "Could not delete the preset: \(error.localizedDescription)"
        }
    }

    func revealPreset(_ entry: PresetEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    /// The name shown for a preset's device kind: the built-in's name, else the saved device's name.
    func presetDeviceName(_ entry: PresetEntry) -> String {
        if entry.format == "builtin" { return BuiltInEffects.spec(entry.identifier)?.name ?? entry.deviceName }
        return entry.deviceName
    }

    /// True for a preset of an instrument (a built-in instrument, a MIDI rack, or an `aumu` plugin).
    func presetIsInstrument(_ entry: PresetEntry) -> Bool {
        if entry.format == "builtin" { return BuiltInEffects.spec(entry.identifier)?.isInstrument == true || entry.identifier == "midirack" }
        return entry.identifier.hasPrefix("aumu")
    }
}
