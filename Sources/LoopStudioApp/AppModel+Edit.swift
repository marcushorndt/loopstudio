import Foundation
import LoopStudioCore

/// A clip on the clipboard, with its place relative to the first copied clip.
struct ClipboardItem {
    var clip: Clip
    var trackOffset: Int
    var startOffset: Int64
    /// Set for a session slot: its follow action travels with the clip.
    var slot: SessionSlot? = nil
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
        case .deleteSelection: !selectedClips.isEmpty || selectedClip != nil || (trackFocused && selectedTrack != nil)
        case .cut, .copy, .duplicate: !selectedClips.isEmpty || selectedClip != nil
        case .paste: !clipboard.isEmpty
        case .backToArrangement, .captureSession: arrangementOverridden
        case .renameTrack: selectedTrack != nil || selectedClip != nil
        case .groupTracks, .duplicateTrack: selectedTrack != nil
        case .exportAudio: !exporting
        default: true
        }
    }

    func perform(_ action: AppAction) {
        switch action {
        case .newProject: newProject()
        case .newDemo: newDemoProject()
        case .save: save()
        case .saveAs: saveAs()
        case .exportAudio: exportAudio()
        case .undo: undo()
        case .redo: redo()
        case .cut: cutSelection()
        case .copy: copySelection()
        case .paste: pasteClipboard()
        case .duplicate: duplicateSelection()
        case .deleteSelection: deleteSelected()
        case .splitAtPlayhead: splitAtPlayhead()
        case .deactivateClip: deactivateSelected()
        case .record: toggleRecordArm()
        case .toggleMetronome: toggleMetronome()
        case .play: togglePlay()
        case .pause: togglePause()
        case .stopRewind: stop()
        case .stopAllClips: stopAllClips()
        case .loopSelection: loopSelection()
        case .loopToggle: toggleLoop()
        case .backToArrangement: backToArrangement()
        case .captureSession: captureSession()
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
        case .toggleKeyboardMIDI:
            keyboardMIDI.toggle()
            status = keyboardMIDI ? "Computer keyboard plays notes (A W S E D F T G Y H U J K, Z/X octave, C/V velocity). Press M to stop." : "Computer keyboard is off."
        case .moveUp: moveSelection(rows: -1, tracks: 0)
        case .moveDown: moveSelection(rows: 1, tracks: 0)
        case .moveLeft: moveSelection(rows: 0, tracks: -1)
        case .moveRight: moveSelection(rows: 0, tracks: 1)
        case .launchSelected: launchSelection()
        case .sessionView: viewMode = .session
        case .arrangementView: viewMode = .arrangement
        case .switchView: viewMode = viewMode == .session ? .arrangement : .session
        case .toggleDetail: detailOpen.toggle()
        case .toggleAutomation: toggleAutomationView()
        case .showShortcuts: shortcutsOpen = true
        }
    }

    // MARK: Keyboard navigation

    /// The slot the selection points at: the row of the selected clip, else the selected scene row.
    private var selectedRow: Int? {
        if let id = selectedClip, let (tid, _) = project.findClip(id),
           let row = project.track(tid)?.slots.firstIndex(where: { $0?.clip.id == id }) { return row }
        return selectedSceneRow
    }

    /// A click on a session slot, empty or not. The arrow keys go on from it.
    func selectSlot(track: TrackID, row: Int, clip: ClipID? = nil) {
        selectedClip = clip
        selectedTrack = track
        selectedSceneRow = row
        trackFocused = false
    }

    /// The rows the Session view shows: at least 8, and one empty row below the last slot.
    var sessionRows: Int { max(8, (project.tracks.map(\.slots.count).max() ?? 0) + 1) }

    /// Arrow keys. Session view moves through slots; arrangement view moves between tracks.
    func moveSelection(rows: Int, tracks: Int) {
        let columns = orderedTracks
        guard !columns.isEmpty else { return }
        let current = selectedTrack.flatMap { id in columns.firstIndex { $0.id == id } } ?? 0
        let column = min(max(current + tracks + (viewMode == .arrangement ? rows : 0), 0), columns.count - 1)
        selectedTrack = columns[column].id
        guard viewMode == .session else { return }
        // A slot is selected now, not the track, so Delete cannot remove the track.
        trackFocused = false
        let rowCount = sessionRows
        let row = min(max((selectedRow ?? (rows > 0 ? -1 : rowCount)) + rows, 0), rowCount - 1)
        selectedSceneRow = row
        let track = columns[column]
        selectedClip = row < track.slots.count ? track.slots[row]?.clip.id : nil
    }

    /// Return: launches the selected session clip, or the selected scene when the slot is empty.
    func launchSelection() {
        guard viewMode == .session, let row = selectedRow else { return }
        if let track = selectedTrack, let t = project.track(track), row < t.slots.count, t.slots[row] != nil {
            launch(track: track, row: row)
        } else {
            launchScene(row)
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
        let ordered = orderedTracks
        for (i, t) in ordered.enumerated() {
            for c in t.clips where selectedClips.contains(c.id) { found.append((i, c)) }
        }
        if found.isEmpty, let id = selectedClip, let (tid, clip) = project.findClip(id), let i = ordered.firstIndex(where: { $0.id == tid }) {
            found.append((i, clip))
        }
        let slots: [ClipID: SessionSlot] = Dictionary(project.tracks.flatMap { $0.slots.compactMap { $0 } }.map { ($0.clip.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard !found.isEmpty else { return }
        let firstTrack = found.map(\.0).min()!, firstStart = found.map { $0.1.start.rawValue }.min()!
        clipboard = found.map { ClipboardItem(clip: $0.1, trackOffset: $0.0 - firstTrack, startOffset: $0.1.start.rawValue - firstStart, slot: slots[$0.1.id]) }
    }

    func cutSelection() { copySelection(); deleteSelected() }

    /// Pastes at the cursor, starting on the selected track.
    func pasteClipboard() {
        guard !clipboard.isEmpty else { return }
        if viewMode == .session { pasteIntoSlots(); return }
        let ordered = orderedTracks
        let base = selectedTrack.flatMap { id in ordered.firstIndex { $0.id == id } } ?? 0
        var commands: [Command] = [], pasted: [ClipID] = []
        for item in clipboard {
            let index = base + item.trackOffset
            guard ordered.indices.contains(index) else { continue }
            let track = ordered[index]
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

    /// Session view: puts the copied clips into the selected slot and the slots to its right, same row.
    private func pasteIntoSlots() {
        let ordered = orderedTracks
        let base = selectedTrack.flatMap { id in ordered.firstIndex { $0.id == id } } ?? 0
        let row = selectedRow ?? 0
        var commands: [Command] = []
        for item in clipboard {
            let index = base + item.trackOffset
            guard ordered.indices.contains(index) else { continue }
            let track = ordered[index]
            let clip = fresh(item.clip, start: 0)
            guard fits(clip, track.kind) else { continue }
            var slot = item.slot ?? SessionSlot(clip: clip)
            slot.clip = clip
            // The clip lands in the selected scene; empty slots fill the gap.
            commands.append(.setSlot(track: track.id, index: row, slot: slot))
        }
        guard !commands.isEmpty else { return }
        apply(.batch(commands: commands))
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
                let head = at - c.start
                guard let second = c.tail(from: head) else { continue }
                // The first half keeps its notes, envelopes and automation; it only gets shorter.
                commands.append(.setClipRange(clip: c.id, start: c.start, length: head))
                if case .midi(let m) = c {
                    let first = m.notes.filter { $0.tick < head }.map { n -> MIDINote in
                        var n = n; n.length = Tick(min(n.length.rawValue, head.rawValue - n.tick.rawValue)); return n
                    }
                    commands.append(.setMIDINotes(clip: m.id, notes: first))
                }
                commands.append(.insertClip(track: t.id, clip: fresh(second, start: second.start)))
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

    /// Key 0: turns the selected audio clips off or on together. The first clip decides the direction.
    func deactivateSelected() {
        var ids = selectedClips
        if let c = selectedClip { ids.insert(c) }
        let clips = ids.compactMap { project.findClip($0)?.1 }.compactMap { clip -> AudioClip? in
            if case .audio(let a) = clip { return a } else { return nil }
        }
        guard let first = clips.first else { status = "Only audio clips can be deactivated."; return }
        let mute = !first.muted
        let commands = clips.map { Command.setAudioClip(clip: $0.id, gainDb: $0.gainDb, fadeInMs: $0.fadeInMs, fadeOutMs: $0.fadeOutMs, muted: mute) }
        apply(commands.count == 1 ? commands[0] : .batch(commands: commands))
    }

    func toggleClipMute(_ clip: AudioClip) {
        apply(.setAudioClip(clip: clip.id, gainDb: clip.gainDb, fadeInMs: clip.fadeInMs, fadeOutMs: clip.fadeOutMs, muted: !clip.muted))
    }

    /// Writes what the Session played into the arrangement, at the times it played (Live's arrangement
    /// record, after the fact), then lets the arrangement play again. One undo step.
    func captureSession() {
        // The performance goes where it played on the timeline, counted back from the playhead. Each jump of the
        // arrangement loop moves the two clocks apart, so with the loop on the performance keeps its session times.
        let shift = project.loop?.enabled == true ? 0 : engine.clockOffset
        var stops: [TrackID: Tick] = [:]
        for l in project.launches where l.slot == nil {
            let t = project.onTimeline(l.tick, shift: shift)
            stops[l.track] = min(stops[l.track] ?? t, t)
        }
        let until = shift == 0 ? sessionTick : currentTick
        let commands = project.captureCommands(project.onTimeline(simulation.events, shift: shift), until: until, stops: stops)
        guard !commands.isEmpty else { status = "Nothing to capture: no Session clip has played yet"; return }
        let count = commands.filter { if case .insertClip = $0 { true } else { false } }.count
        apply(.batch(commands: commands))
        backToArrangement()
        viewMode = .arrangement
        status = "Captured the Session into the arrangement (\(count) clip\(count == 1 ? "" : "s"))"
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
        // The copy's automation must drive the copy, not the original track and its devices.
        var nodes: [UUID: UUID] = [id.rawValue: copy.id.rawValue]
        copy.devices = copy.devices.map { var d = $0; d.id = DeviceID(); nodes[$0.id.rawValue] = d.id.rawValue; return d }
        func retarget(_ lanes: [AutomationLane]) -> [AutomationLane] {
            lanes.map { var l = $0; l.id = LaneID(); l.target.node = nodes[l.target.node] ?? l.target.node; return l }
        }
        func retarget(_ clip: Clip) -> Clip {
            var clip = clip
            clip.lanes = retarget(clip.lanes)
            return clip
        }
        copy.clips = copy.clips.map { retarget(fresh($0, start: $0.start)) }
        copy.slots = copy.slots.map { slot in slot.map { var s = $0; s.clip = retarget(fresh($0.clip, start: $0.clip.start)); return s } }
        copy.automation = retarget(copy.automation)
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
