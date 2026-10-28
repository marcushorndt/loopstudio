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
        if !isMaster {
            Menu("Add Effect") {
                ForEach(BuiltInEffects.all, id: \.id) { spec in Button(spec.name) { model.addEffect(spec.id, to: track.id) } }
            }
        }
        Divider()
        if showsAutomation {
            Button(model.shownLanes(track).isEmpty ? "Show Automation" : "Hide Automation") { model.toggleAutomation(track) }
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
        switch clip {
        case .audio(let a):
            Button(a.loop ? "Loop Off" : "Loop On") { model.apply(.setClipLoop(clip: a.id, loop: !a.loop)) }
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
        Button(device.bypassed ? "Turn On" : "Bypass") { model.apply(.setDeviceBypass(track: track.id, device: device.id, bypassed: !device.bypassed)) }
        Button("Duplicate") { model.duplicateDevice(track.id, device.id) }
        Button("Move Left") { model.moveDevice(track.id, device.id, by: -1) }.disabled(track.devices.first?.id == device.id)
        Button("Move Right") { model.moveDevice(track.id, device.id, by: 1) }.disabled(track.devices.last?.id == device.id)
        if device.format == "audiounit", let unit = model.host.units[device.id] {
            Button("Open Plugin Window") { PluginWindow.show(unit, title: device.name) }
        }
        Divider()
        Button("Delete", role: .destructive) { model.apply(.removeDevice(track: track.id, device: device.id)) }
    }
}

/// The checkmark items of the lane menu, for use inside any menu.
struct AutomationLaneToggles: View {
    @Environment(AppModel.self) private var model
    let track: Track

    var body: some View {
        Button("Lanes With Points") { model.showAllUsedLanes(track) }
            .disabled(track.automation.allSatisfy { $0.points.isEmpty })
        Button("Hide All") { model.automationShown[track.id] = nil }.disabled(model.shownLanes(track).isEmpty)
        Divider()
        ForEach(model.project.automationTargets(of: track), id: \.address) { target in
            Toggle(target.name, isOn: Binding(
                get: { model.isLaneShown(track, target.address) },
                set: { on in model.setLane(track, target.address, shown: on); if on { model.viewMode = .arrangement } }))
        }
    }
}

/// A menu of checkmarks: which automation lanes of a track are visible.
struct AutomationLanesMenu: View {
    @Environment(AppModel.self) private var model
    let track: Track
    var title = "Automation Lanes"

    var body: some View {
        Menu(title) {
            Button("Lanes With Points") { model.showAllUsedLanes(track) }
                .disabled(track.automation.allSatisfy { $0.points.isEmpty })
            Button("Hide All") { model.automationShown[track.id] = nil }.disabled(model.shownLanes(track).isEmpty)
            Divider()
            ForEach(model.project.automationTargets(of: track), id: \.address) { target in
                Toggle(target.name, isOn: Binding(
                    get: { model.isLaneShown(track, target.address) },
                    set: { model.setLane(track, target.address, shown: $0) }))
            }
        }
    }
}
