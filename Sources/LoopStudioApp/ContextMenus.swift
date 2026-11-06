import LoopStudioCore
import AppKit
import SwiftUI

/// Right-click menu content, shared by the views. Items that have a key show it, because they are built
/// from `AppAction`.

/// A small coloured dot that keeps its colour inside a menu.
@MainActor private func swatch(_ color: Color) -> Image {
    let size = NSSize(width: 12, height: 12)
    let image = NSImage(size: size, flipped: false) { rect in
        NSColor(color).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
        return true
    }
    image.isTemplate = false
    return Image(nsImage: image)
}

struct ClipColorMenu: View {
    @Environment(AppModel.self) private var model
    let clip: Clip
    let track: Track

    var body: some View {
        Menu("Color") {
            Button("Track Color") { model.apply(.setClipColor(clip: clip.id, colorIndex: nil)) }
            Divider()
            ForEach(0..<Theme.trackColors.count, id: \.self) { i in
                Button { model.apply(.setClipColor(clip: clip.id, colorIndex: i)) } label: {
                    Text(colorNames[i]); swatch(Theme.track(i))
                }
            }
        }
    }
}

private let colorNames = ["Red", "Orange", "Yellow", "Green", "Teal", "Blue", "Violet", "Pink"]

struct TrackMenuItems: View {
    @Environment(AppModel.self) private var model
    let track: Track
    var showsAutomation = false

    var body: some View {
        AppAction.renameTrack.button(model) { model.renameRequest = track.id }
        // The master is always there, once: it cannot be duplicated, deleted, grouped or soloed.
        let isMaster = track.kind == .master
        if !isMaster {
            AppAction.duplicateTrack.button(model) { model.duplicateTrack(track.id) }
            // Only this track: a marked range on other tracks does not widen a right-click delete.
            AppAction.deleteSelection.button(model, title: "Delete Track") { model.rangeSelection = nil; model.focusTrack(track.id); model.deleteFocusedTracks() }
        }
        Divider()
        Menu("Color") {
            ForEach(0..<colorNames.count, id: \.self) { i in
                Button(colorNames[i]) { model.setTrackColor(track.id, i) }
            }
        }
        Button(track.mute ? "Unmute" : "Mute") { model.toggleMute(track) }
        if !isMaster { Button(track.solo ? "Unsolo" : "Solo") { model.toggleSolo(track) } }
        if track.kind == .audio || track.kind == .midi {
            Button(model.armedTracks.contains(track.id) ? "Disarm" : "Arm for Recording") { model.toggleArm(track.id, additive: true) }
        }
        if track.kind == .audio {
            Menu("Monitor") {
                ForEach([(MonitorMode.input, "In"), (.auto, "Auto"), (.off, "Off")], id: \.1) { mode, name in
                    Toggle(name, isOn: Binding(get: { track.monitorMode == mode }, set: { _ in model.apply(.setMonitor(id: track.id, mode: mode)) }))
                }
            }
        }
        if !isMaster, !track.slots.allSatisfy({ $0 == nil }) {
            Button("Stop Track Clips") { model.stopClips(of: track) }.disabled(!model.transportPlaying)
        }
        if track.kind == .midi {
            Menu("Add Instrument") {
                ForEach(BuiltInInstruments.all, id: \.id) { spec in Button(spec.name) { model.addEffect(spec.id, to: track.id) } }
            }
        }
        if !isMaster {
            Menu("Add Effect") {
                ForEach(BuiltInEffects.all, id: \.id) { spec in Button(spec.name) { model.addEffect(spec.id, to: track.id) } }
            }
        }
        Divider()
        if showsAutomation {
            Button(model.laneList(track).isEmpty ? "Show Automation" : (model.isAutomationCollapsed(track) ? "Expand Automation" : "Collapse Automation")) {
                model.toggleAutomation(track)
            }
            AutomationLanesMenu(track: track)
        }
        Button("Clear Automation") { model.clearAutomation(track.id) }.disabled(track.automation.isEmpty)
        Button("Clear Devices") { model.clearDevices(track.id) }.disabled(track.devices.isEmpty)
        Button("Clear Clips") { model.clearTrack(track.id) }.disabled(track.clips.isEmpty && track.slots.allSatisfy { $0 == nil })
        Divider()
        if !isMaster { AppAction.groupTracks.button(model) { model.selectedTrack = track.id; model.groupSelectedTracks() } }
        AppAction.insertAudioTrack.button(model)
        AppAction.insertMIDITrack.button(model)
        AppAction.insertReturnTrack.button(model)
        AppAction.insertGroupTrack.button(model)
    }
}

struct ArrangementClipMenu: View {
    @Environment(AppModel.self) private var model
    let clip: Clip
    let track: Track

    /// The menu acts on the clip under the pointer, even if it was not marked.
    private func act(_ action: AppAction) -> () -> Void {
        { if !model.selectedClips.contains(clip.id) { model.select(clip: clip.id, extend: false) }; model.perform(action) }
    }

    var body: some View {
        AppAction.cut.button(model, run: act(.cut))
        AppAction.copy.button(model, run: act(.copy))
        AppAction.paste.button(model)
        AppAction.duplicate.button(model, run: act(.duplicate))
        AppAction.deleteSelection.button(model, run: act(.deleteSelection))
        Divider()
        Button("Edit Clip Automation") { model.openClipAutomation(clip.id) }
        Button("Move Clip Automation to Track") { model.moveClipAutomationToTrack(clip.id) }
            .disabled(clip.lanes.allSatisfy { $0.points.isEmpty })
        Divider()
        AppAction.splitAtPlayhead.button(model, run: act(.splitAtPlayhead))
        AppAction.loopSelection.button(model, title: "Loop Clip") {
            if !model.selectedClips.contains(clip.id) { model.select(clip: clip.id, extend: false) }
            model.loopToClips()
        }
        Button("Select All Clips on Track") { model.selectedClips = Set(track.clips.map(\.id)); model.selectedTrack = track.id }
        Divider()
        AppAction.renameTrack.button(model, title: "Rename Clip") { model.clipRenameRequest = clip.id }
        switch clip {
        case .audio(let a):
            Button(a.loop ? "Loop Off" : "Loop On") { model.apply(.setClipLoop(clip: a.id, loop: !a.loop)) }
            Button(a.warpMode == .off ? "Warp On" : "Warp Off") { model.apply(.setClipWarp(clip: a.id, mode: a.warpMode == .off ? .beats : .off, markers: a.warpMarkers)) }
            Button(a.muted ? "Activate Clip" : "Deactivate Clip") { model.toggleClipMute(a) }
            Menu("Fade In") {
                ForEach([0.0, 2, 10, 50, 200], id: \.self) { ms in Button(ms == 0 ? "None" : "\(Int(ms)) ms") { model.setClipFades(a, fadeInMs: ms, fadeOutMs: a.fadeOutMs) } }
            }
            Menu("Fade Out") {
                ForEach([0.0, 2, 10, 50, 200], id: \.self) { ms in Button(ms == 0 ? "None" : "\(Int(ms)) ms") { model.setClipFades(a, fadeInMs: a.fadeInMs, fadeOutMs: ms) } }
            }
            Menu("Gain") {
                ForEach([-12.0, -6, 0, 6], id: \.self) { db in
                    Button(db == 0 ? "0 dB (reset)" : String(format: "%+.0f dB", db)) {
                        model.apply(.setAudioClip(clip: a.id, gainDb: db, fadeInMs: a.fadeInMs, fadeOutMs: a.fadeOutMs, muted: a.muted))
                    }
                }
            }
        case .midi(let m):
            Button(m.loop ? "Loop Off" : "Loop On") { model.apply(.setClipLoop(clip: m.id, loop: !m.loop)) }
            Button("Clear Notes") { model.setNotes(m.id, []) }
        case .dummy:
            EmptyView()
        }
        ClipColorMenu(clip: clip, track: track)
        Button("Show in Clip Panel") { model.selectedClip = clip.id; model.detailTab = .clip; model.detailOpen = true }
    }
}

struct LaneMenu: View {
    @Environment(AppModel.self) private var model
    let track: Track

    var body: some View {
        AppAction.paste.button(model) { model.selectedTrack = track.id; model.pasteClipboard() }.disabled(model.clipboard.isEmpty)
        AppAction.splitAtPlayhead.button(model) { model.selectedTrack = track.id; model.selectedClips = []; model.splitAtPlayhead() }
        if track.kind == .midi {
            Button("New MIDI Clip at Playhead") { model.createMIDIClip(track: track.id, at: model.snap(model.currentTick)) }
        }
        Button("Select Track") { model.selectedTrack = track.id }
        Divider()
        TrackMenuItems(track: track, showsAutomation: true)
    }
}

struct RulerMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        AppAction.loopToggle.button(model)
        Button("Set Loop Start at Playhead") {
            let t = model.snap(model.currentTick)
            model.setLoop(start: t, end: max(model.project.loop?.end ?? t + Tick(model.barTicks * 4), t + Tick(Tick.perQuarter)))
        }
        Button("Set Loop End at Playhead") {
            let t = model.snap(model.currentTick)
            model.setLoop(start: min(model.project.loop?.start ?? 0, t - Tick(Tick.perQuarter)), end: t)
        }
        Button("Remove Loop") { model.apply(.setLoop(loop: nil)) }.disabled(model.project.loop == nil)
        Divider()
        Button("Return to Start") { model.seek(to: 0) }
    }
}

struct SlotMenu: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let row: Int

    var body: some View {
        if row < track.slots.count, let slot = track.slots[row] {
            Button("Launch") { model.launch(track: track.id, row: row) }
            Button("Stop Track") { model.stopTrack(track.id) }
            Divider()
            AppAction.duplicate.button(model) { model.duplicateSlot(track: track.id, row: row) }
            Button("Edit Clip Automation") { model.openClipAutomation(slot.clip.id) }
            AppAction.deleteSelection.button(model, title: "Delete Clip") { model.apply(.setSlot(track: track.id, index: row, slot: nil)) }
            if case .dummy = slot.clip {} else {
                Button("Insert into Arrangement at Playhead") { model.insertSlotIntoArrangement(track: track.id, row: row) }
            }
            Divider()
            Menu("Follow Action") {
                ForEach(AppModel.FollowPreset.allCases, id: \.self) { p in Button(p.rawValue) { model.setFollowPreset(track: track.id, row: row, p) } }
            }
            Menu("Launch Quantize") {
                ForEach([(LaunchQuantize.none, "None"), (.beat, "Beat"), (.bar, "Bar")], id: \.1) { q, name in
                    Button(name) { var s = slot; s.quantize = q; model.apply(.setSlot(track: track.id, index: row, slot: s)) }
                }
            }
            switch slot.clip {
            case .audio(let a): Button(a.loop ? "Loop Off" : "Loop On") { model.apply(.setClipLoop(clip: a.id, loop: !a.loop)) }
            case .midi(let m): Button(m.loop ? "Loop Off" : "Loop On") { model.apply(.setClipLoop(clip: m.id, loop: !m.loop)) }
            case .dummy: EmptyView()
            }
            ClipColorMenu(clip: slot.clip, track: track)
            Button("Show in Clip Panel") { model.selectedClip = slot.clip.id; model.selectedTrack = track.id; model.detailTab = .clip; model.detailOpen = true }
        } else {
            if track.kind == .midi { Button("New MIDI Clip") { model.createMIDIClip(track: track.id, row: row) } }
            Button("New Dummy Clip") { model.createDummyClip(track: track.id, row: row) }
            if track.kind == .audio || track.kind == .midi {
                AppAction.record.button(model, title: "Record into This Slot") { model.recordIntoSlot(track: track.id, row: row) }
                    .disabled(model.recording)
            }
            if track.kind != .master { Button("Stop Track") { model.stopClips(of: track) }.disabled(!model.transportPlaying) }
            Divider()
            Button("Launch Scene \(row + 1)") { model.launchScene(row) }
        }
        Divider()
        AppAction.insertScene.button(model, title: "Insert Scene Below") { model.insertScene(at: row + 1) }
        AppAction.duplicateScene.button(model, title: "Duplicate Scene") { model.duplicateScene(row) }
        AppAction.deleteScene.button(model, title: "Delete Scene") { model.deleteScene(row) }
    }
}

struct SceneMenu: View {
    @Environment(AppModel.self) private var model
    let row: Int

    var body: some View {
        Button("Launch Scene") { model.launchScene(row) }
        Divider()
        AppAction.insertScene.button(model, title: "Insert Scene Below") { model.insertScene(at: row + 1) }
        AppAction.duplicateScene.button(model) { model.duplicateScene(row) }
        AppAction.deleteScene.button(model) { model.deleteScene(row) }
    }
}

struct DeviceMenu: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let device: DeviceSlot

    var body: some View {
        let siblings = model.siblings(of: device.id, on: track)
        let holder = track.chainHolding(device.id)
        Button(device.bypassed ? "Turn On" : "Bypass") { model.apply(.setDeviceBypass(track: track.id, device: device.id, bypassed: !device.bypassed)) }
        Button("Duplicate") { model.duplicateDevice(track.id, device.id) }
        Button("Copy") { model.selectDevice(device.id); model.copyDevice() }
        Button("Cut") { model.selectDevice(device.id); model.cutDevice() }
        Button("Paste After") { model.selectDevice(device.id); model.pasteDevice() }.disabled(model.deviceClipboard == nil)
        Button("Move Left") { model.moveDevice(track.id, device.id, by: -1) }.disabled(siblings.first?.id == device.id)
        Button("Move Right") { model.moveDevice(track.id, device.id, by: 1) }.disabled(siblings.last?.id == device.id)
        Divider()
        if device.isRack {
            Button("Ungroup Rack") { model.ungroupRack(device.id, on: track.id) }
            Button("Add Chain") { model.addChain(to: device.id, on: track.id) }
        } else if model.selectedDevices.contains(device.id), model.selectedDevices.count > 1 {
            Button("Group \(model.selectedDevices.count) Marked Devices into a Rack") { model.groupDevices(model.selectedDevices, on: track.id) }
        } else {
            Button("Group into a Rack") { model.groupDevice(device.id, on: track.id) }
        }
        // Every chain on the track the device could move into, with its rack's name.
        let chains = track.allDevices.filter { $0.rack != nil && $0.id != device.id && !device.nestedChainIDs.contains($0.id.rawValue) }
            .flatMap { rack in (rack.rack?.chains ?? []).map { (rack: rack, chain: $0) } }
            .filter { !device.nestedChainIDs.contains($0.chain.id.rawValue) }
        if !chains.isEmpty || holder != nil {
            Menu("Move to") {
                if holder != nil { Button("The Track") { model.moveDevice(device.id, on: track.id, toChain: nil) } }
                ForEach(chains, id: \.chain.id) { pair in
                    Button("\(pair.rack.name) › \(pair.chain.name)") { model.moveDevice(device.id, on: track.id, toChain: pair.chain.id) }
                        .disabled(pair.chain.id == holder?.id)
                }
            }
        }
        Divider()
        if device.format == "audiounit", let unit = model.host.units[device.id] {
            Button("Open Plugin Window") { PluginWindow.show(unit, title: device.name) }
        }
        if device.identifier == "patch", device.format == "builtin" {
            Button("Edit Patch…") { PatchEditorWindow.show(model: model, track: track.id, device: device.id) }
        }
        if device.format == "builtin", !device.params.isEmpty {
            Button("Reset All Parameters") {
                model.apply(.batch(commands: device.params.keys.sorted().map { .setDeviceParam(track: track.id, device: device.id, key: $0, value: nil) }))
            }
        }
        let automated = track.automation.filter { $0.target.node == device.id.rawValue && !$0.points.isEmpty }
        Button("Clear Automation of This Device") {
            model.apply(.batch(commands: automated.map { .setAutomation(track: track.id, target: $0.target, points: []) }))
        }
        .disabled(automated.isEmpty)
        Divider()
        // Presets: the device's settings as a file, for any project. Plugins keep their state, racks everything inside.
        Button("Save Preset…") { model.presetPrompt = PresetPrompt(track: track.id, device: device.id, name: device.name) }
        let presets = model.presets(for: device.identifier)
        if !presets.isEmpty {
            Menu("Load Preset") {
                ForEach(presets) { p in Button(p.name) { model.loadPreset(p, onto: device.id, on: track.id) } }
            }
        }
        Button("Import Preset…") { model.importPresets(onto: device.id, on: track.id) }
        Button("Export Preset…") { model.exportPreset(track: track.id, device: device.id) }
        Divider()
        AppAction.deleteSelection.button(model, title: "Delete") { model.apply(.removeDevice(track: track.id, device: device.id)) }
    }
}

/// The automation targets of a track in groups: the mixer, then each device. The menus list them this way.
struct LaneGroup: Identifiable {
    let id: UUID
    let name: String
    let targets: [AutomationTarget]

    @MainActor static func groups(of track: Track, in project: Project) -> [LaneGroup] {
        let all = project.automationTargets(of: track)
        var groups = [LaneGroup(id: track.id.rawValue, name: "Mixer", targets: all.filter { $0.node == track.id.rawValue })]
        for device in track.devices {
            let mine = all.filter { $0.node == device.id.rawValue }
            if !mine.isEmpty { groups.append(LaneGroup(id: device.id.rawValue, name: device.name, targets: mine)) }
        }
        return groups.filter { !$0.targets.isEmpty }
    }

    /// The parameter name without the "Device › " prefix, for use under the device's own heading.
    static func shortName(_ target: AutomationTarget) -> String {
        target.name.components(separatedBy: " › ").last ?? target.name
    }
}

private extension AutomationTarget {
    var node: UUID { address.node }
}

/// A row of the lane menus: the parameter name, with a dot in front when it holds automation points.
private func laneLabel(_ target: AutomationTarget, automated: Set<ParameterAddress>) -> Text {
    automated.contains(target.address) ? Text("● ") + Text(LaneGroup.shortName(target)) : Text(LaneGroup.shortName(target))
}

/// The checkmark items of the lane menu, for use inside any menu. A dot marks a parameter with points.
struct AutomationLaneToggles: View {
    @Environment(AppModel.self) private var model
    let track: Track
    /// Also switches to the arrangement when a lane is turned on (for menus in the session view).
    var reveals = false

    var body: some View {
        let automated = model.automatedTargets(track)
        Button("Lanes With Points") { model.showAllUsedLanes(track); if reveals { model.viewMode = .arrangement } }
            .disabled(automated.isEmpty)
        Button("Add Lane") { model.addLane(track); if reveals { model.viewMode = .arrangement } }
        Button("Hide All") { model.hideLanes(track) }.disabled(model.laneList(track).isEmpty)
        Divider()
        ForEach(LaneGroup.groups(of: track, in: model.project)) { group in
            Section(group.name) {
                ForEach(group.targets, id: \.address) { target in
                    Toggle(isOn: Binding(
                        get: { model.isLaneShown(track, target.address) },
                        set: { on in model.setLane(track, target.address, shown: on); if on && reveals { model.viewMode = .arrangement } })) {
                        laneLabel(target, automated: automated)
                    }
                }
            }
        }
    }
}

/// A menu of checkmarks: which automation lanes of a track are visible.
struct AutomationLanesMenu: View {
    let track: Track
    var title = "Automation Lanes"

    var body: some View {
        Menu(title) { AutomationLaneToggles(track: track) }
    }
}

/// The parameter chooser of one lane: picking a parameter makes this lane show it.
struct LaneParameterMenu<Label: View>: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let index: Int
    @ViewBuilder let label: () -> Label

    var body: some View {
        let automated = model.automatedTargets(track)
        let current = model.shownLanes(track).indices.contains(index) ? model.shownLanes(track)[index] : nil
        Menu {
            ForEach(LaneGroup.groups(of: track, in: model.project)) { group in
                Section(group.name) {
                    ForEach(group.targets, id: \.address) { target in
                        Toggle(isOn: Binding(
                            get: { current == target.address },
                            set: { _ in model.replaceLane(track, at: index, with: target.address) })) {
                            laneLabel(target, automated: automated)
                        }
                    }
                }
            }
        } label: { label() }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    }
}
