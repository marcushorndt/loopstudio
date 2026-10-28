import Foundation
import LoopStudioCore

/// A clip on the clipboard, with its place relative to the first copied clip.
struct ClipboardItem {
    var clip: Clip
    var trackOffset: Int
    var startOffset: Int64
}

extension AppModel {
    // MARK: Action dispatch

    func title(of action: AppAction) -> String {
        switch action {
        case .play: transportPlaying ? "Stop" : (recordArmed ? "Start Recording" : "Play")
        case .record: recording ? "Stop Recording" : (recordArmed ? "Disarm Recording" : "Arm Recording")
        case .renameTrack: selectedClip != nil ? "Rename Clip" : "Rename Track"
        case .pause: transportPlaying ? "Pause" : "Continue"
        default: action.title
        }
    }

    func isEnabled(_ action: AppAction) -> Bool {
        switch action {
        case .undo: canUndo
        case .redo: canRedo
        case .cut, .copy, .deleteSelection, .duplicate: !selectedClips.isEmpty || selectedClip != nil
        case .paste: !clipboard.isEmpty
        case .backToArrangement: arrangementOverridden
        case .renameTrack: selectedTrack != nil || selectedClip != nil
        case .groupTracks, .duplicateTrack: selectedTrack != nil
        default: true
        }
    }

    func perform(_ action: AppAction) {
        switch action {
        case .newProject: newProject()
        case .newDemo: newDemoProject()
        case .save: save()
        case .undo: undo()
        case .redo: redo()
        case .cut: cutSelection()
        case .copy: copySelection()
        case .paste: pasteClipboard()
        case .duplicate: duplicateSelection()
        case .deleteSelection: deleteSelected()
        case .splitAtPlayhead: splitAtPlayhead()
        case .record: toggleRecordArm()
        case .toggleMetronome: toggleMetronome()
        case .play: togglePlay()
        case .pause: togglePause()
        case .stopRewind: stop()
        case .stopAllClips: stopAllClips()
        case .loopSelection: loopSelection()
        case .loopToggle: toggleLoop()
        case .backToArrangement: backToArrangement()
        case .insertAudioTrack: addTrack(kind: .audio)
        case .insertMIDITrack: addTrack(kind: .midi)
        case .insertReturnTrack: addTrack(kind: .returnTrack)
        case .insertGroupTrack: addTrack(kind: .group)
        case .groupTracks: groupSelectedTracks()
        case .renameTrack:
            if let clip = selectedClip { clipRenameRequest = clip } else { renameRequest = selectedTrack }
        case .duplicateTrack: if let t = selectedTrack { duplicateTrack(t) }
        case .insertScene: insertScene(at: (selectedSceneRow ?? project.tracks.map(\.slots.count).max() ?? 0 - 1) + 1)
        case .deleteScene: if let r = selectedSceneRow { deleteScene(r) }
        case .duplicateScene: if let r = selectedSceneRow { duplicateScene(r) }
        case .sessionView: viewMode = .session
        case .arrangementView: viewMode = .arrangement
        case .switchView: viewMode = viewMode == .session ? .arrangement : .session
        case .toggleDetail: detailOpen.toggle()
        case .showShortcuts: shortcutsOpen = true
        }
    }

    // MARK: Sound card

    /// Sends the master to the chosen device and channel pair. Falls back to the default and says so.
    func applyAudioSettings() {
        do {
            try engine.setOutput(uid: outputUID, left: outputLeft, right: outputLeft + 1, bufferFrames: bufferFrames > 0 ? bufferFrames : nil)
        } catch {
            status = "Could not use that output (\(error)). Using the default."
            outputUID = nil; outputLeft = 0
            try? engine.setOutput(uid: nil)
        }
    }

    // MARK: Clipboard

    func copySelection() {
        var found: [(Int, Clip)] = []
        for (i, t) in project.tracks.enumerated() {
            for c in t.clips where selectedClips.contains(c.id) { found.append((i, c)) }
        }
        if found.isEmpty, let id = selectedClip, let (tid, clip) = project.findClip(id), let i = project.tracks.firstIndex(where: { $0.id == tid }) {
            found.append((i, clip))
        }
        guard !found.isEmpty else { return }
        let firstTrack = found.map(\.0).min()!, firstStart = found.map { $0.1.start.rawValue }.min()!
        clipboard = found.map { ClipboardItem(clip: $0.1, trackOffset: $0.0 - firstTrack, startOffset: $0.1.start.rawValue - firstStart) }
    }

    func cutSelection() { copySelection(); deleteSelected() }

    /// Pastes at the cursor, starting on the selected track.
    func pasteClipboard() {
        guard !clipboard.isEmpty else { return }
        let base = selectedTrack.flatMap { id in project.tracks.firstIndex { $0.id == id } } ?? 0
        var commands: [Command] = [], pasted: [ClipID] = []
        for item in clipboard {
            let index = base + item.trackOffset
            guard project.tracks.indices.contains(index) else { continue }
            let track = project.tracks[index]
            let clip = fresh(item.clip, start: Tick(snap(currentTick).rawValue + item.startOffset))
            guard fits(clip, track.kind) else { continue }
            commands.append(.insertClip(track: track.id, clip: clip))
            pasted.append(clip.id)
        }
        guard !commands.isEmpty else { return }
        apply(.batch(commands: commands))
        selectedClips = Set(pasted)
        viewMode = .arrangement
    }

    /// Copies each marked arrangement clip to just after itself, or the selected session clip into the next free slot.
    func duplicateSelection() {
        var commands: [Command] = [], made: [ClipID] = []
        for t in project.tracks {
            for c in t.clips where selectedClips.contains(c.id) {
                let copy = fresh(c, start: c.start + c.length)
                commands.append(.insertClip(track: t.id, clip: copy))
                made.append(copy.id)
            }
        }
        if commands.isEmpty {
            if let id = selectedClip, let (tid, _) = project.findClip(id), let t = project.track(tid),
               let row = t.slots.firstIndex(where: { $0?.clip.id == id }) { duplicateSlot(track: tid, row: row) }
            return
        }
        apply(.batch(commands: commands))
        selectedClips = Set(made)
    }

    private func fits(_ clip: Clip, _ kind: TrackKind) -> Bool {
        switch clip {
        case .audio: kind == .audio
        case .midi: kind == .midi
        case .dummy: kind != .master
        }
    }

    func fresh(_ clip: Clip, start: Tick) -> Clip {
        switch clip {
        case .audio(var c): c.id = ClipID(); c.start = start; return .audio(c)
        case .midi(var c): c.id = ClipID(); c.start = start; return .midi(c)
        case .dummy(var c): c.id = ClipID(); c.start = start; return .dummy(c)
        }
    }

    // MARK: Clip tools

    /// Cuts every marked clip (or every clip under the cursor on the selected track) in two at the cursor.
    func splitAtPlayhead() {
        let at = currentTick
        var commands: [Command] = []
        for t in project.tracks {
            let marked = t.clips.filter { selectedClips.contains($0.id) }
            let targets = marked.isEmpty && t.id == selectedTrack && selectedClips.isEmpty ? t.clips : marked
            for c in targets where c.start < at && at < c.start + c.length {
                let head = Tick(at.rawValue - c.start.rawValue), tail = Tick(c.length.rawValue - head.rawValue)
                switch c {
                case .audio(var a):
                    var second = a
                    second.id = ClipID(); second.start = at; second.length = tail
                    second.offset = Tick(a.offset.rawValue + head.rawValue)
                    commands.append(.setClipRange(clip: a.id, start: a.start, length: head))
                    commands.append(.insertClip(track: t.id, clip: .audio(second)))
                    a.length = head
                case .midi(let m):
                    let first = m.notes.filter { $0.tick < head }.map { n -> MIDINote in
                        var n = n; n.length = Tick(min(n.length.rawValue, head.rawValue - n.tick.rawValue)); return n
                    }
                    let later = m.notes.filter { $0.tick >= head }.map { n -> MIDINote in var n = n; n.tick = Tick(n.tick.rawValue - head.rawValue); return n }
                    let second = MIDIClip(start: at, length: tail, loop: m.loop, notes: later)
                    commands.append(.setClipRange(clip: m.id, start: m.start, length: head))
                    commands.append(.setMIDINotes(clip: m.id, notes: first))
                    commands.append(.insertClip(track: t.id, clip: .midi(second)))
                case .dummy: break
                }
            }
        }
        if !commands.isEmpty { apply(.batch(commands: commands)) }
    }

    /// Sets the loop brace to the span of the marked clips.
    func loopToClips() {
        let marked = project.tracks.flatMap(\.clips).filter { selectedClips.contains($0.id) }
        guard let start = marked.map(\.start).min(), let end = marked.map({ $0.start + $0.length }).max() else { return }
        setLoop(start: start, end: end)
    }

    func setClipFades(_ clip: AudioClip, fadeInMs: Double, fadeOutMs: Double) {
        apply(.setAudioClip(clip: clip.id, gainDb: clip.gainDb, fadeInMs: fadeInMs, fadeOutMs: fadeOutMs, muted: clip.muted))
    }

    func toggleClipMute(_ clip: AudioClip) {
        apply(.setAudioClip(clip: clip.id, gainDb: clip.gainDb, fadeInMs: clip.fadeInMs, fadeOutMs: clip.fadeOutMs, muted: !clip.muted))
    }

    /// Puts a copy of a session clip on the arrangement timeline at the cursor.
    func insertSlotIntoArrangement(track: TrackID, row: Int) {
        guard let t = project.track(track), row < t.slots.count, let slot = t.slots[row] else { return }
        if case .dummy = slot.clip { return }
        apply(.insertClip(track: track, clip: fresh(slot.clip, start: snap(currentTick))))
    }

    enum FollowPreset: String, CaseIterable {
        case none = "None", next = "Play Next", loop = "Loop", random = "Random Any", nextOrStop = "Next or Stop"
    }

    func setFollowPreset(track: TrackID, row: Int, _ preset: FollowPreset) {
        guard let t = project.track(track), row < t.slots.count, var slot = t.slots[row] else { return }
        let time = FollowTime.loops(1)
        switch preset {
        case .none: slot.follow = nil
        case .next: slot.follow = FollowActions(a: FollowAction(.next), b: FollowAction(.next, weight: 0), time: time)
        case .loop: slot.follow = FollowActions(a: FollowAction(.replay), b: FollowAction(.replay, weight: 0), time: time)
        case .random: slot.follow = FollowActions(a: FollowAction(.any), b: FollowAction(.any, weight: 0), time: time)
        case .nextOrStop: slot.follow = FollowActions(a: FollowAction(.next), b: FollowAction(.stop), time: time, edge: .stop)
        }
        apply(.setSlot(track: track, index: row, slot: slot))
    }

    // MARK: Tracks

    func setTrackColor(_ id: TrackID, _ index: Int) { apply(.setTrackColor(id: id, colorIndex: index)) }

    func toggleMute(_ t: Track) { apply(.setMute(id: t.id, mute: !t.mute)) }
    func toggleSolo(_ t: Track) { apply(.setSolo(id: t.id, solo: !t.solo)) }

    func duplicateTrack(_ id: TrackID) {
        guard var copy = project.track(id), let index = project.tracks.firstIndex(where: { $0.id == id }) else { return }
        copy.id = TrackID()
        copy.name += " copy"
        copy.clips = copy.clips.map { fresh($0, start: $0.start) }
        copy.slots = copy.slots.map { slot in slot.map { var s = $0; s.clip = fresh($0.clip, start: $0.clip.start); return s } }
        copy.devices = copy.devices.map { var d = $0; d.id = DeviceID(); return d }
        copy.automation = copy.automation.map { var l = $0; l.id = LaneID(); return l }
        apply(.insertTrack(track: copy, index: index + 1))
        selectedTrack = copy.id
    }

    /// Removes every clip, slot and device from a track.
    func clearTrack(_ id: TrackID) {
        guard let t = project.track(id) else { return }
        var commands: [Command] = t.clips.map { .removeClip(clip: $0.id) }
        for row in t.slots.indices where t.slots[row] != nil { commands.append(.setSlot(track: id, index: row, slot: nil)) }
        if !commands.isEmpty { apply(.batch(commands: commands)) }
    }

    func clearDevices(_ id: TrackID) {
        guard let t = project.track(id), !t.devices.isEmpty else { return }
        apply(.batch(commands: t.devices.map { .removeDevice(track: id, device: $0.id) }))
    }

    func clearAutomation(_ id: TrackID) {
        guard let t = project.track(id), !t.automation.isEmpty else { return }
        apply(.batch(commands: t.automation.map { .setAutomation(track: id, target: $0.target, points: []) }))
    }

    func moveDevice(_ track: TrackID, _ device: DeviceID, by delta: Int) {
        guard let t = project.track(track), let i = t.devices.firstIndex(where: { $0.id == device }) else { return }
        let to = i + delta
        guard t.devices.indices.contains(to) else { return }
        apply(.moveDevice(track: track, device: device, to: to))
    }

    func duplicateDevice(_ track: TrackID, _ device: DeviceID) {
        guard let t = project.track(track), let i = t.devices.firstIndex(where: { $0.id == device }) else { return }
        var copy = t.devices[i]
        copy.id = DeviceID()
        apply(.insertDevice(track: track, device: copy, index: i + 1))
    }

    // MARK: Scenes

    func insertScene(at row: Int) {
        apply(.batch(commands: shiftCommands(from: row, by: 1)))
        selectedSceneRow = row
    }

    func deleteScene(_ row: Int) {
        var commands: [Command] = []
        for t in project.tracks {
            if row < t.slots.count, t.slots[row] != nil { commands.append(.setSlot(track: t.id, index: row, slot: nil)) }
            for i in stride(from: row + 1, to: t.slots.count, by: 1) {
                guard let slot = t.slots[i] else { continue }
                commands.append(.setSlot(track: t.id, index: i, slot: nil))
                commands.append(.setSlot(track: t.id, index: i - 1, slot: slot))
            }
        }
        if !commands.isEmpty { apply(.batch(commands: commands)) }
        selectedSceneRow = nil
    }

    func duplicateScene(_ row: Int) {
        var commands = shiftCommands(from: row + 1, by: 1)
        for t in project.tracks where row < t.slots.count {
            if var slot = t.slots[row] { slot.clip = fresh(slot.clip, start: slot.clip.start); commands.append(.setSlot(track: t.id, index: row + 1, slot: slot)) }
        }
        apply(.batch(commands: commands))
        selectedSceneRow = row + 1
    }

    /// Moves every slot from `row` downward by `by` rows (top row first, so no clip exists twice).
    private func shiftCommands(from row: Int, by: Int) -> [Command] {
        var commands: [Command] = []
        for t in project.tracks {
            for i in stride(from: t.slots.count - 1, through: row, by: -1) {
                guard let slot = t.slots[i] else { continue }
                commands.append(.setSlot(track: t.id, index: i, slot: nil))
                commands.append(.setSlot(track: t.id, index: i + by, slot: slot))
            }
        }
        return commands
    }
}
