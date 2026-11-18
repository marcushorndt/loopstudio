import AppKit
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
        case .deleteSelection: !selectedClips.isEmpty || selectedClip != nil || (trackFocused && selectedTrack != nil) || !selectedNotes.isEmpty
            || rangeSelection != nil || selectedDevice != nil
        case .deleteTime: rangeSelection != nil
            || selectedScene != nil || selectedDevice != nil
        case .cut, .copy: !selectedClips.isEmpty || selectedClip != nil || deviceFocused
        case .duplicate: !selectedClips.isEmpty || selectedClip != nil || !selectedNotes.isEmpty || selectedScene != nil || (trackFocused && selectedTrack != nil) || deviceFocused
        case .paste: !clipboard.isEmpty || !noteClipboard.isEmpty || deviceClipboard != nil
        case .backToArrangement, .captureSession: arrangementOverridden
        case .renameTrack: selectedTrack != nil || selectedClip != nil
        case .groupTracks: selectedTrack != nil || deviceFocused
        case .ungroup: rackToUngroup != nil
        case .duplicateTrack: selectedTrack != nil
        case .noteOctaveUp, .noteOctaveDown, .noteLonger, .noteShorter, .noteOtherGridLeft, .noteOtherGridRight: markedMIDIClip != nil
        // Shift and an arrow: the same keys move marked notes an octave or a step, so they come first.
        case .extendUp, .extendDown, .extendLeft, .extendRight: viewMode == .session && markedMIDIClip == nil
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
        case .cut: if deviceFocused { cutDevice() } else { cutSelection() }
        case .copy: if deviceFocused { copyDevice() } else { copySelection() }
        case .paste: pasteClipboard()
        case .duplicate:
            // Marked notes: a copy right after them, like Live. The note clipboard keeps the copy. A marked
            // device card gets its copy right next to it. A focused track with nothing else marked
            // duplicates the track, as ⌘D does in Live.
            if !selectedNotes.isEmpty { copySelection(); pasteClipboard() }
            else if let id = selectedDevice, let (track, _) = deviceLocation(id) { duplicateDevice(track.id, id) }
            else if trackFocused, selectedClips.isEmpty, selectedClip == nil, selectedScene == nil, let t = selectedTrack { duplicateTrack(t) }
            else { duplicateSelection() }
        case .deleteSelection: deleteSelected()
        case .deleteTime: deleteTime()
        case .drawMode:
            // The pen belongs to the piano roll: without an open MIDI clip the key does nothing.
            guard drawMode || (detailTab == .clip && selectedClip.flatMap { project.findClip($0) }.map { if case .midi = $0.1 { true } else { false } } == true) else {
                status = "Draw mode needs an open MIDI clip"; return
            }
            drawMode.toggle(); status = drawMode ? "Draw mode: click or drag to draw notes, click a note to delete it (Esc ends it)" : "Draw mode off"
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
        // ⌘G is Live's Group: marked device cards go into a Rack, else the selected tracks into a group track.
        case .groupTracks: if deviceFocused { groupSelectedDevices() } else { groupSelectedTracks() }
        case .ungroup: ungroupSelectedRack()
        case .renameTrack:
            if let clip = selectedClip { clipRenameRequest = clip } else { renameRequest = selectedTrack }
        case .duplicateTrack: if let t = selectedTrack { duplicateTrack(t) }
        case .insertScene: insertScene(at: (selectedSceneRow ?? project.tracks.map(\.slots.count).max() ?? 0 - 1) + 1)
        case .deleteScene: if let r = selectedSceneRow { deleteScene(r) }
        case .duplicateScene: if let r = selectedSceneRow { duplicateScene(r) }
        case .toggleKeyboardMIDI:
            keyboardMIDI.toggle()
            status = keyboardMIDI ? "Computer keyboard plays notes (A W S E D F T G Y H U J K, Z/X octave, C/V velocity). Press M to stop." : "Computer keyboard is off."
        case .midiLearn: toggleMIDILearn()
        case .moveUp: moveSelection(rows: -1, tracks: 0)
        case .moveDown: moveSelection(rows: 1, tracks: 0)
        case .moveLeft: moveSelection(rows: 0, tracks: -1)
        case .moveRight: moveSelection(rows: 0, tracks: 1)
        case .extendUp: extendSelection(rows: -1, tracks: 0)
        case .extendDown: extendSelection(rows: 1, tracks: 0)
        case .extendLeft: extendSelection(rows: 0, tracks: -1)
        case .extendRight: extendSelection(rows: 0, tracks: 1)
        case .noteOctaveUp: nudgeNotes(pitch: 12)
        case .noteOctaveDown: nudgeNotes(pitch: -12)
        case .noteLonger: nudgeNotes(length: noteStep)
        case .noteShorter: nudgeNotes(length: -noteStep)
        case .noteOtherGridLeft: nudgeNotes(time: -otherNoteStep, toGrid: !snapNotes)
        case .noteOtherGridRight: nudgeNotes(time: otherNoteStep, toGrid: !snapNotes)
        case .snapNotes: snapNotes.toggle(); status = snapNotes ? "Snap to the grid is on" : "Snap off: notes, clips and the playhead land on the exact tick"
        case .gridNarrower: stepGrid(by: -1)
        case .gridWider: stepGrid(by: 1)
        case .gridTriplet: toggleGridTriplet()
        case .gridFixed: toggleGridFixed()
        case .selectAll: selectAll()
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

    /// A click on a session slot, empty or not. The arrow keys go on from it. `add` (Command) adds the clip
    /// to the marking or takes it out, with gaps allowed; `range` (Shift) marks the rectangle of slots from
    /// the last plain click to this one.
    func selectSlot(track: TrackID, row: Int, clip: ClipID? = nil, add: Bool = false, range: Bool = false) {
        trackFocused = false
        selectedNotes = []
        if range, let anchor = slotAnchor {
            markSlots(from: anchor, to: (track, row))
            selectedTrack = track
            selectedSceneRow = row
            selectedClip = clip ?? selectedClips.first
            return
        }
        if add, let clip {
            if selectedClips.contains(clip) {
                selectedClips.remove(clip)
                if selectedClip == clip { selectedClip = selectedClips.first }
            } else {
                selectedClips.insert(clip)
                selectedClip = clip
            }
            selectedTrack = track
            selectedSceneRow = row
            slotAnchor = (track, row)
            return
        }
        selectedClip = clip
        selectedClips = clip.map { [$0] } ?? []
        selectedTrack = track
        selectedSceneRow = row
        slotAnchor = (track, row)
    }

    /// Marks every clip in the rectangle of slots between two slots. Columns are the session's tracks in
    /// their shown order, so a rectangle can span busses too.
    func markSlots(from a: (track: TrackID, row: Int), to b: (track: TrackID, row: Int)) {
        let columns = sessionColumns
        guard let ca = columns.firstIndex(where: { $0.id == a.track }), let cb = columns.firstIndex(where: { $0.id == b.track }) else { return }
        var ids = Set<ClipID>()
        for c in min(ca, cb)...max(ca, cb) {
            let t = columns[c]
            for r in min(a.row, b.row)...max(a.row, b.row) where r < t.slots.count {
                if let s = t.slots[r] { ids.insert(s.clip.id) }
            }
        }
        selectedClips = ids
        if let current = selectedClip, ids.contains(current) {} else { selectedClip = ids.first }
        status = ids.isEmpty ? "" : "\(ids.count) clip\(ids.count == 1 ? "" : "s") marked"
    }

    /// Shift and an arrow key in the Session view: the marking grows from the anchor to the new slot.
    func extendSelection(rows: Int, tracks: Int) {
        guard viewMode == .session else { moveSelection(rows: rows, tracks: tracks); return }
        let columns = sessionColumns
        guard !columns.isEmpty else { return }
        let anchor = slotAnchor ?? selectedTrack.map { ($0, selectedSceneRow ?? 0) } ?? (columns[0].id, 0)
        slotAnchor = anchor
        let current = selectedTrack.flatMap { id in columns.firstIndex { $0.id == id } } ?? 0
        let column = min(max(current + tracks, 0), columns.count - 1)
        let row = min(max((selectedSceneRow ?? anchor.row) + rows, 0), sessionRows - 1)
        selectedTrack = columns[column].id
        selectedSceneRow = row
        trackFocused = false
        selectedNotes = []
        markSlots(from: anchor, to: (columns[column].id, row))
    }

    /// The rubber band over the slot grid (the scrolling tracks, in the grid's own coordinates): every slot
    /// the rectangle touches is marked.
    func markSlots(inBand rect: CGRect, columnWidth: CGFloat, slotHeight: CGFloat, gap: CGFloat, headerHeight: CGFloat) {
        let columns = orderedTracks.filter { $0.kind != .returnTrack }
        guard !columns.isEmpty else { return }
        func col(_ x: CGFloat) -> Int { min(max(Int(x / (columnWidth + gap)), 0), columns.count - 1) }
        func row(_ y: CGFloat) -> Int { min(max(Int((y - headerHeight - gap) / (slotHeight + gap)), 0), sessionRows - 1) }
        let c0 = col(rect.minX), c1 = col(rect.maxX), r0 = row(rect.minY), r1 = row(rect.maxY)
        slotAnchor = (columns[c0].id, r0)
        selectedTrack = columns[c1].id
        selectedSceneRow = r1
        trackFocused = false
        selectedNotes = []
        markSlots(from: (columns[c0].id, r0), to: (columns[c1].id, r1))
    }

    /// A slot dragged onto another slot. The dragged clip moves there; when it is part of the marking, the
    /// whole marking moves by the same offset, so a column of clips can go down a row together. The clips
    /// keep their IDs, so follow actions and automation stay. With `copy` (Option held) the clips stay and
    /// copies land, with new IDs. A full slot in the way is replaced, like in Live; undo brings it back.
    func moveSlots(from source: (track: TrackID, row: Int), to destination: (track: TrackID, row: Int), copy: Bool = false) {
        guard source.track != destination.track || source.row != destination.row else { return }
        let columns = sessionColumns
        guard let cs = columns.firstIndex(where: { $0.id == source.track }), let cd = columns.firstIndex(where: { $0.id == destination.track }),
              let st = project.track(source.track), source.row < st.slots.count, let sourceSlot = st.slots[source.row] else { return }
        var moving: [(track: Track, row: Int, slot: SessionSlot)] = []
        if selectedClips.contains(sourceSlot.clip.id) {
            for t in columns { for (r, s) in t.slots.enumerated() { if let s, selectedClips.contains(s.clip.id) { moving.append((t, r, s)) } } }
        } else {
            moving = [(st, source.row, sourceSlot)]
        }
        let dc = cd - cs, dr = destination.row - source.row
        let movingIDs = Set(moving.map(\.slot.clip.id))
        var clears: [Command] = [], sets: [Command] = []
        for m in moving {
            guard let ci = columns.firstIndex(where: { $0.id == m.track.id }) else { continue }
            let tc = ci + dc, tr = m.row + dr
            guard tc >= 0, tc < columns.count, tr >= 0 else { status = "The clips do not fit there"; return }
            let target = columns[tc]
            guard fits(m.slot.clip, target.kind) else { status = "\(clipName(m.slot.clip)) does not fit on \(target.name)"; return }
            var slot = m.slot
            if copy { slot.clip = fresh(slot.clip, start: slot.clip.start) }
            // A copy onto its own source: nothing to clear. Clearing comes first, so no clip exists twice.
            if !copy { clears.append(.setSlot(track: m.track.id, index: m.row, slot: nil)) }
            sets.append(.setSlot(track: target.id, index: tr, slot: slot))
        }
        let replaced = sets.filter { if case .setSlot(let t, let i, _) = $0, let track = project.track(t), i < track.slots.count,
                                        let old = track.slots[i], !movingIDs.contains(old.clip.id) { true } else { false } }.count
        do { try tryApply(.batch(commands: clears + sets)) } catch { status = "Cannot \(copy ? "copy" : "move"): \(error)"; return }
        let landed = Set(sets.compactMap { if case .setSlot(_, _, let s) = $0 { s?.clip.id } else { nil } })
        selectedClips = landed
        selectedClip = sets.compactMap { if case .setSlot(_, _, let s) = $0 { s?.clip.id } else { nil } }.first
        selectedTrack = destination.track
        selectedSceneRow = destination.row
        slotAnchor = destination
        let what = moving.count == 1 ? "clip" : "\(moving.count) clips"
        status = (copy ? "Copied \(what)" : (moving.count == 1 ? "" : "Moved \(what)")) + (replaced > 0 ? " (\(replaced) replaced)" : "")
    }

    /// The rows the Session view shows: at least 8, and one empty row below the last slot.
    var sessionRows: Int { max(8, (project.allTracks.map(\.slots.count).max() ?? 0) + 1) }

    /// Arrow keys. Session view moves through slots; arrangement view moves between tracks.
    /// In the Session view the master is the last column (the scene buttons), and the row under the last
    /// slot row holds the stop buttons.
    func moveSelection(rows: Int, tracks: Int) {
        // Marked notes in the open clip take the arrow keys: up and down transpose, left and right move in time.
        if markedMIDIClip != nil {
            nudgeNotes(pitch: -rows, time: Int64(tracks) * noteStep, toGrid: snapNotes)
            return
        }
        let columns = viewMode == .session ? sessionColumns : orderedTracks
        guard !columns.isEmpty else { return }
        let current = selectedTrack.flatMap { id in columns.firstIndex { $0.id == id } } ?? 0
        let column = min(max(current + tracks + (viewMode == .arrangement ? rows : 0), 0), columns.count - 1)
        selectedTrack = columns[column].id
        guard viewMode == .session else { return }
        // A slot is selected now, not the track, so Delete cannot remove the track.
        trackFocused = false
        let last = sessionRows // the stop row
        // With no row yet: down starts at the top, up at the last scene, left and right at the top.
        let start = selectedRow ?? (rows > 0 ? -1 : (rows < 0 ? last : 0))
        let row = min(max(start + rows, 0), last)
        selectedSceneRow = row
        let track = columns[column]
        selectedClip = row < track.slots.count ? track.slots[row]?.clip.id : nil
    }

    /// The columns of the Session view in their shown order: the tracks, the busses, then the master.
    var sessionColumns: [Track] { orderedTracks + [project.master] }

    /// The step of the arrow keys on notes: the grid of the piano roll at its zoom with snap on, a 1/128
    /// note with snap off. `otherNoteStep` is the one the switch does not point at (Command and an arrow).
    var noteStep: Int64 { snapNotes ? max(1, noteGrid) : fineNoteStep }
    var otherNoteStep: Int64 { snapNotes ? fineNoteStep : max(1, noteGrid) }
    private var fineNoteStep: Int64 { Tick.perQuarter / 32 }

    /// The open MIDI clip, when notes in it are marked.
    var markedMIDIClip: MIDIClip? {
        guard !selectedNotes.isEmpty, let id = selectedClip, case .midi(let m)? = project.findClip(id)?.1 else { return nil }
        return m
    }

    /// Moves the marked notes: `pitch` in semitones, `time` in ticks, `length` in ticks. Notes stay in the
    /// clip and the key range, a note never gets shorter than a sixty-fourth, and the marking follows them.
    /// A held key repeats into one undo step per key. With `toGrid`, a group off the grid lands on the next
    /// grid line in the pressed direction first, then walks the grid.
    func nudgeNotes(pitch: Int = 0, time: Int64 = 0, length: Int64 = 0, toGrid: Bool = false) {
        guard let m = markedMIDIClip else { return }
        let marked = m.notes.filter { selectedNotes.contains($0) }
        guard !marked.isEmpty else { return }
        // The whole group stops at the edges, so the chord or the phrase keeps its shape.
        let lowest = marked.map { Int($0.pitch) }.min()!, highest = marked.map { Int($0.pitch) }.max()!
        let dp = min(max(pitch, -lowest), 127 - highest)
        let first = marked.map(\.tick.rawValue).min()!, last = marked.map(\.tick.rawValue).max()!
        let step = toGrid ? snappedTimeStep(time, from: first) : time
        let dt = min(max(step, -first), max(0, m.length.rawValue - abs(time)) - last)
        guard dp != 0 || dt != 0 || length != 0 else { return }
        var moved: Set<MIDINote> = []
        let notes = m.notes.map { n -> MIDINote in
            guard selectedNotes.contains(n) else { return n }
            var x = n
            x.pitch = UInt8(Int(n.pitch) + dp)
            x.tick = Tick(n.tick.rawValue + dt)
            let room = max(Tick.perQuarter / 16, m.length.rawValue - x.tick.rawValue)
            x.length = Tick(min(max(Tick.perQuarter / 16, n.length.rawValue + length), room))
            moved.insert(x)
            return x
        }
        let key = "nudge\(m.id)\(dp != 0 ? "p" : "")\(dt != 0 ? "t" : "")\(length != 0 ? "l" : "")"
        setNotes(m.id, notes, key: key)
        selectedNotes = moved
        noteNudges += 1
        if previewNotes, let note = moved.min(by: { ($0.tick, $0.pitch) < ($1.tick, $1.pitch) }), dp != 0 { auditionNote(note.pitch) }
    }

    /// The time step of an arrow key for a group whose first note sits at `first`: a group off the grid
    /// lands on the next grid line in the pressed direction on the first press, and walks the grid from
    /// there. On the grid already, the step is the plain grid step.
    func snappedTimeStep(_ time: Int64, from first: Int64) -> Int64 {
        let grid = max(1, noteGrid)
        guard time != 0, grid > 1 else { return time }
        let off = first % grid
        guard off != 0 else { return time }
        return time > 0 ? grid - off : -off
    }

    /// The selection sits on the row of stop buttons.
    /// The scene whose button is selected (master column, Session view). Delete and ⌘D act on it.
    var selectedScene: Int? {
        guard viewMode == .session, selectedTrack == project.master.id, selectedClip == nil,
              let row = selectedSceneRow, row < sessionRows else { return nil }
        return row
    }

    var stopRowSelected: Bool { viewMode == .session && selectedClip == nil && selectedSceneRow == sessionRows }

    /// Return: launches the selected session clip, or the selected scene when the slot is empty or on the
    /// scene column. On the stop row it stops the track, or every clip from the scene column.
    func launchSelection() {
        guard viewMode == .session, let row = selectedRow else { return }
        let master = selectedTrack == project.master.id
        if row >= sessionRows {
            if master { stopAllClips() } else if let id = selectedTrack, let t = project.track(id) { stopClips(of: t) }
            return
        }
        if !master, let track = selectedTrack, let t = project.track(track), row < t.slots.count, t.slots[row] != nil {
            launch(track: track, row: row)
        } else {
            launchScene(row)
        }
    }

    // MARK: Sound card

    /// The output ports that tracks play to directly, past the master. The master's own port is not one.
    var directPorts: [IOPort] {
        let used = Set(project.tracks.compactMap(\.hardwareOutput))
        return project.ports.filter { $0.direction == .output && used.contains($0.id) }
    }

    /// Output ports a track can choose as "Audio To": every output port but the master's own.
    var assignablePorts: [IOPort] {
        project.ports.filter { $0.direction == .output && $0.id != project.master.hardwareOutput }
    }

    /// The first channel (from 0) of a port's pair on this Mac. Unset: the pairs after the master, in port order.
    func portLeft(_ port: IOPort) -> Int {
        if let saved = portChannels[port.id.rawValue.uuidString] { return saved }
        let k = (assignablePorts.firstIndex { $0.id == port.id } ?? 0) + 1
        return outputLeft + 2 * k
    }

    func setPortLeft(_ port: IOPort, _ left: Int) {
        portChannels[port.id.rawValue.uuidString] = left
        applyAudioSettings()
    }

    /// Sends the master to the chosen device and channel pair, and each direct port to its own pair.
    /// Falls back to the default and says so.
    func applyAudioSettings() {
        let ports = Dictionary(uniqueKeysWithValues: directPorts.map { ($0.id, (portLeft($0), portLeft($0) + 1)) })
        appliedDirectPorts = Set(ports.keys)
        do {
            try engine.setOutput(uid: outputUID, left: outputLeft, right: outputLeft + 1, bufferFrames: bufferFrames > 0 ? bufferFrames : nil,
                                 ports: ports)
        } catch {
            status = "Could not use that output (\(error)). Using the default."
            outputUID = nil; outputLeft = 0
            try? engine.setOutput(uid: nil)
        }
    }

    // MARK: Clipboard

    func copySelection() {
        // Marked notes in the open clip: copy the notes, not the clip.
        if !selectedNotes.isEmpty, let id = selectedClip, case .midi(let m)? = project.findClip(id)?.1 {
            let notes = m.notes.filter { selectedNotes.contains($0) }
            guard let first = notes.map(\.tick.rawValue).min(), let end = notes.map({ $0.tick.rawValue + $0.length.rawValue }).max() else { return }
            noteClipboard = notes.map { var n = $0; n.tick = Tick(n.tick.rawValue - first); return n }
            notePasteTick = Tick(end)
            deviceClipboard = nil
            return
        }
        noteClipboard = []
        deviceClipboard = nil
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
        if !noteClipboard.isEmpty { pasteNotes(); return }
        if clipboard.isEmpty, deviceClipboard != nil { pasteDevice(); return }
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

    /// Puts the copied notes into the open MIDI clip, after the copied ones. Each paste goes on from there.
    /// Notes past the clip end are dropped. The pasted notes are marked.
    private func pasteNotes() {
        guard let id = selectedClip, case .midi(let m)? = project.findClip(id)?.1 else {
            status = "Select a MIDI clip to paste the notes into"
            return
        }
        let span = noteClipboard.map { $0.tick.rawValue + $0.length.rawValue }.max() ?? 0
        let start = notePasteTick.rawValue < m.length.rawValue ? notePasteTick.rawValue : 0
        let pasted = noteClipboard.compactMap { n -> MIDINote? in
            var n = n
            n.tick = Tick(n.tick.rawValue + start)
            guard n.tick.rawValue < m.length.rawValue else { return nil }
            n.length = Tick(min(n.length.rawValue, m.length.rawValue - n.tick.rawValue))
            return n
        }
        guard !pasted.isEmpty else { return }
        setNotes(id, m.notes + pasted.filter { !m.notes.contains($0) })
        selectedNotes = Set(pasted)
        notePasteTick = Tick(start + span)
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
            if let scene = selectedScene { duplicateScene(scene); return }
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
        case .dummy: true
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

    /// Cuts every marked clip (or every clip under the cursor on the selected track) at the cursor. With a time
    /// range marked, the cuts are at both ends of the range instead, so the range becomes clips of its own.
    func splitAtPlayhead() {
        let cuts = rangeSelection.map { [$0.start, $0.end] } ?? [currentTick]
        var commands: [Command] = []
        for t in project.tracks {
            let marked = t.clips.filter { selectedClips.contains($0.id) }
            let targets = marked.isEmpty && t.id == selectedTrack && selectedClips.isEmpty ? t.clips : marked
            for c in targets {
                let inside = cuts.filter { c.start < $0 && $0 < c.start + c.length }.sorted()
                guard let first = inside.first else { continue }
                // The first piece keeps its notes, envelopes and automation; it only gets shorter.
                let head = first - c.start
                commands.append(.setClipRange(clip: c.id, start: c.start, length: head))
                if case .midi(let m) = c { commands.append(.setMIDINotes(clip: m.id, notes: notes(m, before: head))) }
                for (i, cut) in inside.enumerated() {
                    guard var piece = c.tail(from: cut - c.start) else { continue }
                    if i + 1 < inside.count { piece = shortened(piece, to: inside[i + 1] - cut) }
                    commands.append(.insertClip(track: t.id, clip: fresh(piece, start: piece.start)))
                }
            }
        }
        if !commands.isEmpty { apply(.batch(commands: commands)) }
    }

    /// The notes of a MIDI clip that start before `head`, cut off there.
    private func notes(_ m: MIDIClip, before head: Tick) -> [MIDINote] {
        m.notes.filter { $0.tick < head }.map { n -> MIDINote in
            var n = n; n.length = Tick(min(n.length.rawValue, head.rawValue - n.tick.rawValue)); return n
        }
    }

    /// A clip cut off at `length`: the notes past it go.
    private func shortened(_ clip: Clip, to length: Tick) -> Clip {
        switch clip {
        case .audio(var a): a.length = length; return .audio(a)
        case .midi(var m): m.length = length; m.notes = notes(m, before: length); return .midi(m)
        case .dummy(var d): d.length = length; return .dummy(d)
        }
    }

    /// The commands that take the time `start..<end` out of one clip on `track`: the part before stays as
    /// the clip, the part after comes back as a new clip, moved left by `shift`.
    private func removing(from start: Tick, to end: Tick, in c: Clip, track: TrackID, shift: Tick = 0) -> [Command] {
        let clipEnd = c.start + c.length
        guard start < clipEnd, end > c.start else { return [] }
        if start <= c.start, end >= clipEnd { return [.removeClip(clip: c.id)] }
        var commands: [Command] = []
        if start > c.start {
            let head = start - c.start
            commands.append(.setClipRange(clip: c.id, start: c.start, length: head))
            if case .midi(let m) = c { commands.append(.setMIDINotes(clip: m.id, notes: notes(m, before: head))) }
        } else {
            commands.append(.removeClip(clip: c.id))
        }
        if end < clipEnd, let rest = c.tail(from: end - c.start) {
            commands.append(.insertClip(track: track, clip: fresh(rest, start: rest.start - shift)))
        }
        return commands
    }

    /// Delete with a time range marked: the range goes out of the clips on the marked tracks and leaves a gap.
    func deleteRange(_ r: RangeSelection) {
        var commands: [Command] = []
        for t in project.allTracks where r.tracks.contains(t.id) {
            for c in t.clips { commands += removing(from: r.start, to: r.end, in: c, track: t.id) }
        }
        rangeSelection = nil
        selectedClips = []
        selectedClip = nil
        guard !commands.isEmpty else { status = "Nothing in the marked range"; return }
        apply(.batch(commands: commands))
        status = "Removed the marked range; the time stays"
    }

    /// ⇧⌘Delete: the marked time goes out of the whole arrangement. Clips, automation and the loop brace after
    /// it move left, as in Live.
    func deleteTime() {
        guard let r = rangeSelection, r.end > r.start else { status = "Mark a time range first"; return }
        let shift = r.end - r.start
        var commands: [Command] = []
        for t in project.allTracks {
            for c in t.clips {
                if c.start >= r.end { commands.append(.moveClip(clip: c.id, toTrack: t.id, start: c.start - shift)) }
                else { commands += removing(from: r.start, to: r.end, in: c, track: t.id, shift: shift) }
            }
            for lane in t.automation {
                let points = lane.points.compactMap { p -> AutomationPoint? in
                    if p.tick < r.start { return p }
                    if p.tick < r.end { return nil }
                    var p = p; p.tick = p.tick - shift; return p
                }
                if points.count != lane.points.count { commands.append(.setAutomation(track: t.id, target: lane.target, points: points)) }
            }
        }
        if let loop = project.loop, loop.start >= r.end {
            commands.append(.setLoop(loop: LoopRegion(start: loop.start - shift, end: loop.end - shift, enabled: loop.enabled)))
        }
        rangeSelection = nil
        selectedClips = []
        selectedClip = nil
        if !commands.isEmpty { apply(.batch(commands: commands)) }
        if currentTick >= r.end { seek(to: currentTick - shift) } else if currentTick > r.start { seek(to: r.start) }
        status = "Deleted \(gridName(shift.rawValue, bar: barTicks)) of time"
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
    /// Marks every note of the open MIDI clip; without one, every clip of the arrangement (or the session slots
    /// of the selected track).
    func selectAll() {
        if let id = selectedClip, case .midi(let m)? = project.findClip(id)?.1, !m.notes.isEmpty {
            selectedNotes = Set(m.notes)
            status = "\(m.notes.count) notes marked"
            return
        }
        if viewMode == .arrangement {
            selectedClips = Set(orderedTracks.flatMap { $0.clips.map(\.id) })
            status = "\(selectedClips.count) clips marked"
        } else if let t = selectedTrack, let track = project.track(t) {
            selectedClips = Set(track.slots.compactMap { $0?.clip.id })
            status = "\(selectedClips.count) slots of \(track.name) marked"
        }
    }

    /// Marked notes: mutes them, or unmutes them when the first one is muted. A muted note stays but does not play.
    func toggleMarkedNotesMute() {
        guard let m = markedMIDIClip else { return }
        let marked = m.notes.filter { selectedNotes.contains($0) }
        guard let first = marked.first else { return }
        let mute = !first.muted
        var changed: Set<MIDINote> = []
        let notes = m.notes.map { n -> MIDINote in
            guard selectedNotes.contains(n) else { return n }
            var x = n; x.muted = mute; changed.insert(x); return x
        }
        setNotes(m.id, notes)
        selectedNotes = changed
        status = mute ? "\(changed.count) notes deactivated (0 brings them back)" : "\(changed.count) notes active"
    }

    func deactivateSelected() {
        if markedMIDIClip != nil { toggleMarkedNotesMute(); return }
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
        for l in session.launches where l.slot == nil {
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
    /// Solo is exclusive, like Live: a click solos this track and unsolos the others. With Command held,
    /// the click only toggles this track, so several tracks can be soloed together.
    /// A plain click solos this track alone; on a soloed track it releases every solo. ⌘-click adds or removes
    /// one track from the soloed set.
    func toggleSolo(_ t: Track, additive: Bool = NSEvent.modifierFlags.contains(.command)) {
        if additive {
            apply(.setSolo(id: t.id, solo: !t.solo))
            return
        }
        let soloed = project.allTracks.filter(\.solo)
        if t.solo {
            apply(.batch(commands: soloed.map { .setSolo(id: $0.id, solo: false) }))
            return
        }
        var commands: [Command] = soloed.map { .setSolo(id: $0.id, solo: false) }
        commands.append(.setSolo(id: t.id, solo: true))
        apply(.batch(commands: commands))
    }

    func duplicateTrack(_ id: TrackID) {
        guard var copy = project.track(id), let index = project.tracks.firstIndex(where: { $0.id == id }) else { return }
        copy.id = TrackID()
        copy.name += " copy"
        // The copy's automation must drive the copy, not the original track and its devices.
        var nodes: [UUID: UUID] = [id.rawValue: copy.id.rawValue]
        copy.devices = copy.devices.map { $0.withFreshIDs(map: &nodes) }
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
        guard let t = project.track(track) else { return }
        let list = siblings(of: device, on: t)
        guard let i = list.firstIndex(where: { $0.id == device }) else { return }
        let to = i + delta
        guard list.indices.contains(to) else { return }
        apply(.moveDevice(track: track, device: device, to: to))
    }

    /// A copy right after the device, in the same list, with the parameters and the plugin state as they are
    /// now. A rack copies with everything inside under new IDs.
    func duplicateDevice(_ track: TrackID, _ device: DeviceID) {
        guard let t = project.track(track), let original = t.device(device) else { return }
        let list = siblings(of: device, on: t)
        guard let i = list.firstIndex(where: { $0.id == device }) else { return }
        var map: [UUID: UUID] = [:]
        let copy = snapshot(original).withFreshIDs(map: &map)
        if let chain = t.chainHolding(device) {
            apply(.insertDeviceInChain(track: track, chain: chain.id, device: copy, index: i + 1))
        } else {
            apply(.insertDevice(track: track, device: copy, index: i + 1))
        }
        selectedDevice = copy.id
    }

    // MARK: Scenes

    func insertScene(at row: Int) {
        apply(.batch(commands: shiftCommands(from: row, by: 1)))
        selectedSceneRow = row
    }

    func deleteScene(_ row: Int) {
        var commands: [Command] = []
        for t in project.allTracks {
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
        for t in project.allTracks where row < t.slots.count {
            if var slot = t.slots[row] { slot.clip = fresh(slot.clip, start: slot.clip.start); commands.append(.setSlot(track: t.id, index: row + 1, slot: slot)) }
        }
        apply(.batch(commands: commands))
        selectedSceneRow = row + 1
    }

    /// Moves every slot from `row` downward by `by` rows (top row first, so no clip exists twice).
    private func shiftCommands(from row: Int, by: Int) -> [Command] {
        var commands: [Command] = []
        for t in project.allTracks {
            for i in stride(from: t.slots.count - 1, through: row, by: -1) {
                guard let slot = t.slots[i] else { continue }
                commands.append(.setSlot(track: t.id, index: i, slot: nil))
                commands.append(.setSlot(track: t.id, index: i + by, slot: slot))
            }
        }
        return commands
    }
}
