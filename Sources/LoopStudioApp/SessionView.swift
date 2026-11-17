import LoopStudioCore
import SwiftUI

private let columnWidth: CGFloat = 128
private let slotHeight: CGFloat = 28
private let gap: CGFloat = 2

struct SessionView: View {
    @Environment(AppModel.self) private var model
    /// The slot grid, the stop buttons and the mixer scroll sideways together: each has its own position,
    /// and a scroll in one moves the other two.
    @State private var slotsX = ScrollPosition()
    @State private var stopsX = ScrollPosition()
    @State private var mixerX = ScrollPosition()
    @State private var offsetX: CGFloat = 0
    @State private var visibleWidth: CGFloat = 0
    /// The slots also scroll up and down to show the row the arrow keys select.
    @State private var slotsY = ScrollPosition()
    @State private var offsetY: CGFloat = 0
    @State private var visibleHeight: CGFloat = 0
    /// The full height of the slot grid. The grid is never taller, so the panel below can use the rest.
    @State private var slotsHeight: CGFloat = 0
    /// The rubber band over the slot grid, in the grid's coordinates. A drag that began on a clip's name moves
    /// the clip instead, so it draws no band.
    @State private var band: CGRect?
    @State private var bandIgnored = false

    private func reveal(row: Int?) {
        guard let row, row < model.sessionRows, visibleHeight > 0 else { return }
        let top = 6 + 30 + gap + CGFloat(row) * (slotHeight + gap), bottom = top + slotHeight
        if top - 36 < offsetY { slotsY.scrollTo(y: max(0, top - 36 - gap)) }
        else if bottom > offsetY + visibleHeight { slotsY.scrollTo(y: bottom - visibleHeight + gap) }
    }

    private func follow(_ x: CGFloat) {
        guard abs(x - offsetX) > 0.5 else { return }
        offsetX = x
        slotsX.scrollTo(x: x); stopsX.scrollTo(x: x); mixerX.scrollTo(x: x)
    }

    /// Scrolls just enough to show the selected track, for the arrow keys.
    private func reveal(_ id: TrackID?, in tracks: [Track]) {
        guard let id, let i = tracks.firstIndex(where: { $0.id == id }), visibleWidth > 0 else { return }
        let left = CGFloat(i) * (columnWidth + gap), right = left + columnWidth
        if left < offsetX { follow(left) } else if right > offsetX + visibleWidth { follow(right - visibleWidth) }
    }

    var body: some View {
        let all = model.project.tracks
        // Tracks pile up from the left and scroll. Busses (returns) and the master stay at the right edge.
        let tracks = all.filter { $0.kind != .returnTrack }
        let busses = all.filter { $0.kind == .returnTrack }
        let rows = model.sessionRows

        VStack(spacing: 6) {
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: gap) {
                    ScrollView(.horizontal) {
                        // Lazy: with many tracks, only the columns in view are built.
                        LazyHStack(alignment: .top, spacing: gap) {
                            ForEach(tracks, id: \.id) { TrackColumn(track: $0, rows: rows) }
                            NewTrackColumn(rows: rows)
                        }
                        .coordinateSpace(name: "slots")
                        .simultaneousGesture(bandGesture(tracks))
                        .overlay(alignment: .topLeading) {
                            if let band {
                                Rectangle().fill(Color.white.opacity(0.08))
                                    .overlay(Rectangle().stroke(Color.white.opacity(0.7), lineWidth: 1))
                                    .frame(width: band.width, height: band.height)
                                    .offset(x: band.minX, y: band.minY)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .scrollPosition($slotsX)
                    .scrollIndicators(.hidden)
                    .onScrollGeometryChange(for: CGFloat.self, of: \.contentOffset.x) { _, x in follow(x) }
                    .onScrollGeometryChange(for: CGFloat.self, of: \.containerSize.width) { _, w in visibleWidth = w }
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(busses, id: \.id) { TrackColumn(track: $0, rows: rows) }
                        SceneColumn(rows: rows)
                    }
                }
                .padding(.horizontal, 6).padding(.top, 6)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { slotsHeight = $0 }
            }
            .frame(maxHeight: slotsHeight > 0 ? slotsHeight : nil)
            .scrollPosition($slotsY)
            .onScrollGeometryChange(for: CGFloat.self, of: \.contentOffset.y) { _, y in offsetY = y }
            .onScrollGeometryChange(for: CGFloat.self, of: \.containerSize.height) { _, h in visibleHeight = h }
            // Stop buttons stay in view under the slots: tracks, busses and the master.
            HStack(alignment: .top, spacing: gap) {
                ScrollView(.horizontal) {
                    HStack(spacing: gap) {
                        ForEach(tracks, id: \.id) { StopButton(track: $0, width: columnWidth) }
                        Color.clear.frame(width: columnWidth * 0.6)
                    }
                }
                .scrollPosition($stopsX)
                .scrollIndicators(.hidden)
                .scrollDisabled(true)
                .frame(height: slotHeight)
                HStack(spacing: gap) {
                    ForEach(busses, id: \.id) { StopButton(track: $0, width: columnWidth) }
                    StopButton(track: model.project.master, width: columnWidth)
                }
            }
            .padding(.horizontal, 6)
            .layoutPriority(2)
            // The mixer sits under the slots and lines up with the tracks above it.
            HStack(alignment: .bottom, spacing: gap) {
                ScrollView(.horizontal) {
                    HStack(alignment: .bottom, spacing: gap) {
                        ForEach(tracks, id: \.id) { MixerStrip(track: $0, isMaster: false, width: columnWidth) }
                        Color.clear.frame(width: columnWidth * 0.6)
                    }
                }
                .scrollPosition($mixerX)
                .onScrollGeometryChange(for: CGFloat.self, of: \.contentOffset.x) { _, x in follow(x) }
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(busses, id: \.id) { MixerStrip(track: $0, isMaster: false, width: columnWidth) }
                    MixerStrip(track: model.project.master, isMaster: true, width: columnWidth)
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 6)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(2)
        }
        .background(Theme.background)
        .dropDestination(for: DropItem.self) { items, _ in model.dropOnNewTrack(items) }
        .onChange(of: model.selectedTrack) { _, id in reveal(id, in: tracks) }
        .onChange(of: model.selectedSceneRow) { _, row in reveal(row: row) }
    }
}

extension SessionView {
    /// A drag across the grid marks the slots it touches. Starting on a clip's name is a move, not a band.
    fileprivate func bandGesture(_ tracks: [Track]) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("slots"))
            .onChanged { g in
                if band == nil {
                    let p = g.startLocation
                    let col = Int(p.x / (columnWidth + gap)), inCol = p.x - CGFloat(col) * (columnWidth + gap)
                    let row = Int((p.y - 30 - gap) / (slotHeight + gap))
                    let onName = col >= 0 && col < tracks.count && row >= 0 && row < tracks[col].slots.count
                        && tracks[col].slots[row] != nil && inCol > 26 && inCol < columnWidth
                    bandIgnored = onName
                }
                guard !bandIgnored else { return }
                let rect = CGRect(x: min(g.startLocation.x, g.location.x), y: min(g.startLocation.y, g.location.y),
                                  width: abs(g.translation.width), height: abs(g.translation.height))
                band = rect
                model.markSlots(inBand: rect, columnWidth: columnWidth, slotHeight: slotHeight, gap: gap, headerHeight: 30)
            }
            .onEnded { _ in band = nil; bandIgnored = false }
    }
}

private struct TrackColumn: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let rows: Int

    var body: some View {
        let deviceOver = model.deviceDragTrack == track.id
        VStack(spacing: gap) {
            header
            // Busses have slots too: a dummy clip there is silent but carries automation.
            ForEach(0..<rows, id: \.self) { row in SlotCell(track: track, row: row) }
        }
        .frame(width: columnWidth)
        .overlay {
            if deviceOver {
                RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.accent.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                    .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        let selected = model.selectedTrack == track.id
        return HStack(spacing: 4) {
            Text(track.name).lineLimit(1).font(.system(size: 12, weight: .medium)).padding(.leading, 4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).frame(height: 30)
        .foregroundStyle(Theme.text)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(alignment: .leading) {
            Capsule().fill(Theme.track(track.colorIndex)).frame(width: 3).padding(.vertical, 7).padding(.leading, 2)
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(selected ? Theme.text.opacity(0.7) : Theme.line, lineWidth: 1))
        .contentShape(Rectangle())
        // The single click acts at once; a double-click also opens the inspector.
        .onTapGesture { model.focusTrack(track.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.openTrackInspector(track.id) })
        // The header drags the track: dropped on another header it moves in front of that track.
        .draggable(AppModel.trackDrag(track.id))
        .dropDestination(for: String.self) { items, _ in
            return model.dropOnTrackHeader(items, track: track.id)
        } isTargeted: { over in
            guard DragPasteboard.carriesDevices else { return }
            if over { model.deviceDragTrack = track.id } else if model.deviceDragTrack == track.id { model.deviceDragTrack = nil }
        }
        .contextMenu { TrackMenuItems(track: track) }
    }
}

/// Stops the clips of a track at the next bar. A bus stops every track that feeds it; the master stops all clips.
private struct StopButton: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let width: CGFloat

    var body: some View {
        Button { model.stopClips(of: track) } label: {
            HStack(spacing: 0) {
                // A stop waiting for the next bar blinks with the beat.
                TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !model.transportPlaying)) { _ in
                    let tick = model.sessionTick
                    let waiting = model.transportPlaying && model.stopPending(below: track, at: tick)
                    Image(systemName: "stop.fill").font(.system(size: 11))
                        .foregroundStyle(waiting ? (model.waitBlink() ? Theme.text : Theme.dim.opacity(0.4)) : Theme.dim)
                }
                .frame(width: 26)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: slotHeight)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                .stroke(model.stopRowSelected && model.selectedTrack == track.id ? Theme.text : Theme.line,
                        lineWidth: model.stopRowSelected && model.selectedTrack == track.id ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .midiLearnable(.stopTrack(track.id))
        .frame(width: width)
        .hint(track.kind == .master ? "Stop all clips" : (track.kind == .returnTrack ? "Stop every track that feeds this bus" : "Stop this track's clip at the next bar"))
    }
}

private struct SlotCell: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let row: Int
    /// A dragged clip hovers over this slot: it shows where the clip would land.
    @State private var targeted = false

    var body: some View {
        Group {
            // Only a slot with a clip shows play progress; an empty slot is drawn once, not 24 times a second.
            if row < track.slots.count, track.slots[row] != nil {
                TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !model.transportPlaying)) { context in
                    let state = model.slotState(track: track, row: row, at: model.sessionTick)
                    cell(state, look: SlotLook(state, blink: model.waitBlink()))
                }
            } else {
                cell(.empty, look: SlotLook(.empty, blink: false))
            }
        }
        .dropDestination(for: DropItem.self) { items, _ in model.dropOnSlot(items, track: track.id, row: row) } isTargeted: { over in
            // A device goes on the track, so the column lights up and the slot shows no frame.
            if DragPasteboard.carriesDevices {
                targeted = false
                if over { model.deviceDragTrack = track.id } else if model.deviceDragTrack == track.id { model.deviceDragTrack = nil }
            } else {
                targeted = over
            }
        }
        .overlay { if targeted { placeholder } }
    }

    /// The placeholder under a dragged clip: a dashed frame on the slot it would drop into. With Option held
    /// the drop is a copy, and the frame says so.
    private var placeholder: some View {
        let copy = NSEvent.modifierFlags.contains(.option)
        return RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.accent.opacity(0.22))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            .overlay(alignment: .trailing) {
                if copy { Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent).padding(.trailing, 6) }
            }
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func cell(_ state: SlotState, look: SlotLook) -> some View {
        let slot = row < track.slots.count ? track.slots[row] : nil
        let tint = Theme.track(slot?.clip.colorIndex ?? track.colorIndex)
        if let slot {
            let selected = model.selectedClip == slot.clip.id
            HStack(spacing: 0) {
                Button { model.launch(track: track.id, row: row) } label: {
                    Image(systemName: "play.fill").font(.system(size: 11))
                        .foregroundStyle(look.icon(tint: tint))
                        .frame(width: 26, height: slotHeight)
                        .background(Theme.background.opacity(look.iconWell))
                        // The well is transparent while the clip rests; the whole column must still take the click.
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .midiLearnable(.slot(track.id, row))
                HStack {
                    Text(model.clipName(slot.clip)).lineLimit(1).font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 0)
                    if slot.follow != nil { Image(systemName: "arrow.triangle.branch").font(.system(size: 9)) }
                }
                .padding(.horizontal, 5).frame(maxWidth: .infinity, minHeight: slotHeight)
                .contentShape(Rectangle())
                .onTapGesture {
                    // Command adds or removes (gaps allowed), Shift marks the rectangle from the last plain click.
                    let flags = NSEvent.modifierFlags
                    model.selectSlot(track: track.id, row: row, clip: slot.clip.id, add: flags.contains(.command), range: flags.contains(.shift))
                }
                // Drag the name onto another slot: the clip moves there, with the whole marking when it is part of it.
                .draggable("slot:\(track.id.rawValue.uuidString):\(row)") {
                    Text(model.clipName(slot.clip)).font(.system(size: 11, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 4)
                        .background(tint.opacity(0.8), in: RoundedRectangle(cornerRadius: Theme.radius))
                }
            }
            .foregroundStyle(Theme.onTint)
            .background(alignment: .leading) {
                GeometryReader { geo in
                    Rectangle().fill(Theme.panel)
                    Rectangle().fill(Theme.clipBody(slot.clip.colorIndex ?? track.colorIndex, lift: look.lift))
                    if !slot.clip.lanes.isEmpty { MiniCurves(clip: slot.clip, owner: track).padding(.leading, 26).padding(.vertical, 2) }
                    if let p = state.progress {
                        Rectangle().fill(tint.opacity(0.35)).frame(width: geo.size.width * p)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(look.frame(tint: tint, selected: selected), lineWidth: selected || look.frameLit ? 1.5 : 1))
            .frame(height: slotHeight)
            .hint(state == .ready ? "\(model.clipName(slot.clip)): played when the transport stopped. Play starts it again."
                  : "\(model.clipName(slot.clip)): the play icon launches it, a click selects it, Return launches the selection. Command-click adds, Shift-click marks a range, drag the name to move it.")
            .contextMenu { SlotMenu(track: track, row: row) }
        } else {
            // An empty slot reached with the arrow keys shows a frame.
            let selected = model.selectedClip == nil && model.selectedTrack == track.id && model.selectedSceneRow == row
            let armed = model.armedTracks.contains(track.id) && (track.kind == .audio || track.kind == .midi)
            let takeHere = model.recording && model.recordSlots[track.id] == row
            HStack(spacing: 0) {
                Button {
                    if armed || takeHere { model.recordIntoSlot(track: track.id, row: row); return }
                    switch track.kind {
                    case .midi: model.createMIDIClip(track: track.id, row: row)
                    default: model.stopClips(of: track)
                    }
                } label: {
                    Group {
                        if takeHere {
                            // The slot that records: a red dot that pulses, like Live's recording slot.
                            // It blinks with the beat while the take waits: in the count-in, for its start bar, or for its stop bar.
                            TimelineView(.animation(minimumInterval: 1.0 / 24)) { _ in
                                let waiting = model.engine.isCountingIn || model.recordStopTick != nil || model.recordWaitsForGrid
                                Image(systemName: "record.circle.fill").font(.system(size: 12))
                                    .foregroundStyle(Color.red.opacity(!waiting || model.waitBlink() ? 1 : 0.35))
                            }
                        } else if armed {
                            Image(systemName: "circle.fill").font(.system(size: 9)).foregroundStyle(Color.red.opacity(0.75))
                        } else {
                            Image(systemName: track.kind == .midi ? "plus" : "stop.fill").font(.system(size: 11)).foregroundStyle(Theme.dim.opacity(0.5))
                        }
                    }
                    .frame(width: 26, height: slotHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The rest of the slot selects it; the arrow keys go on from there.
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: slotHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectSlot(track: track.id, row: row) }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { if track.kind == .midi { model.createMIDIClip(track: track.id, row: row) } })
            }
            .background(takeHere ? Color.red.opacity(0.22) : Theme.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(takeHere ? Color.red : (selected ? Theme.text : Color.clear), lineWidth: 1.5))
            .contextMenu { SlotMenu(track: track, row: row) }
            .hint(takeHere ? "Recording into this slot. Click the dot or press Space to stop; the clip then loops."
                  : armed ? "Armed track: the dot records into this slot. Click it again to stop; the clip then loops."
                  : track.kind == .midi ? "Empty slot. Click selects it; the + or a double-click creates a MIDI clip."
                  : (track.kind == .audio ? "Empty slot. Click selects it; the square stops the track. Drop an audio file here."
                     : "Empty slot. Click selects it. Right-click for a dummy clip: silent, it carries automation."))
        }
    }

}


/// How a slot with a clip looks in each state. The one place for these colors: playing, waiting (blinking with
/// the beat), ready after a stop, or resting.
struct SlotLook {
    let state: SlotState
    let blink: Bool
    init(_ state: SlotState, blink: Bool) { self.state = state; self.blink = blink }

    /// 0 resting, 1 playing. A ready clip sits between, so it shows what Play starts.
    var lift: Double {
        switch state {
        case .playing, .stopping: 1
        case .ready: 0.55
        default: 0
        }
    }

    /// The dark well behind the play icon, while the clip plays or is ready.
    var iconWell: Double {
        switch state {
        case .playing, .stopping: 0.7
        case .ready: 0.4
        default: 0
        }
    }

    /// Green while it plays. Waiting, it blinks with the beat: green and the clip color for a launch, green and
    /// grey for a stop. Ready after a stop, a softer green.
    func icon(tint: Color) -> Color {
        switch state {
        case .playing: Theme.play
        case .stopping: blink ? Theme.play : Theme.dim
        case .queued: blink ? Theme.play : tint
        case .ready: Theme.play.opacity(0.6)
        default: tint
        }
    }

    /// A waiting launch also blinks the frame.
    var frameLit: Bool { state.isQueued }

    func frame(tint: Color, selected: Bool) -> Color {
        if state.isQueued && blink { return Theme.accent }
        return selected ? Theme.text : tint.opacity(0.5)
    }
}

private struct NewTrackColumn: View {
    @Environment(AppModel.self) private var model
    let rows: Int
    @State private var targeted = false

    var body: some View {
        VStack(spacing: gap) {
            Menu {
                Button("Audio Track") { model.addTrack(kind: .audio) }
                Button("MIDI Track") { model.addTrack(kind: .midi) }
            } label: {
                Image(systemName: "plus").frame(maxWidth: .infinity, minHeight: 30)
            }
            .menuStyle(.borderlessButton).foregroundStyle(Theme.dim)
            Text("Drop audio or a device\nhere for a new track").font(.caption).foregroundStyle(Theme.dim.opacity(0.6)).multilineTextAlignment(.center)
                .padding(.top, 20)
            Spacer()
        }
        .frame(width: columnWidth * 0.6, height: CGFloat(rows) * (slotHeight + gap) + 30)
        .overlay {
            // The drag over it says where the new track comes: the whole column lights up.
            if targeted {
                RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.accent.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: DropItem.self) { items, _ in model.dropOnNewTrack(items) } isTargeted: { targeted = $0 }
    }
}

/// The master's column: a scene launch button per row, and beside it the master's own slot. A clip there
/// is a dummy clip: never heard, it moves the master's knobs while it plays, and a scene launches it too.
private struct SceneColumn: View {
    @Environment(AppModel.self) private var model
    let rows: Int

    /// The arrow keys reach the scene column as the master's column.
    private func sceneSelected(_ row: Int) -> Bool {
        model.selectedTrack == model.project.master.id && model.selectedSceneRow == row && model.selectedClip == nil
    }

    private static let sceneWidth: CGFloat = 40

    var body: some View {
        let master = model.project.master
        VStack(spacing: gap) {
            header(master)
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: gap) {
                    sceneButton(row)
                    SlotCell(track: master, row: row)
                }
            }
        }
        .frame(width: columnWidth)
    }

    /// The master's header: a click selects the master (its devices show below), an effect dropped on it
    /// lands on the master.
    private func header(_ master: Track) -> some View {
        let selected = model.selectedTrack == master.id
        return Text("Master").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity).frame(height: 30)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(selected ? Theme.text.opacity(0.7) : Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { model.focusTrack(master.id) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { model.openTrackInspector(master.id) })
            .dropDestination(for: String.self) { items, _ in model.dropDevices(items, on: master.id) }
            .contextMenu { TrackMenuItems(track: master) }
            .hint("The master: every track ends here. Click to see its effects; drop an effect on it. Its slots take dummy clips that move its knobs.")
    }

    private func sceneButton(_ row: Int) -> some View {
                Button { model.launchScene(row) } label: {
                    TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !model.transportPlaying)) { _ in
                        // A clip of this scene waits to launch: the play icon blinks with the beat, like a slot's.
                        let queued = model.transportPlaying && model.sceneQueued(row)
                        HStack(spacing: 3) {
                            Image(systemName: "play.fill").font(.system(size: 9))
                                .foregroundStyle(queued && model.waitBlink() ? Theme.play : Theme.text)
                            Text("\(row + 1)").font(.system(size: 11, design: .monospaced))
                        }
                    }
                    .foregroundStyle(Theme.text)
                    .frame(width: Self.sceneWidth, height: slotHeight)
                    .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(sceneSelected(row) ? Theme.text : Color.clear, lineWidth: 1.5))
                .midiLearnable(.scene(row))
                .contextMenu { SceneMenu(row: row) }
                .hint("Scene \(row + 1): launches every clip of this row, the master's too.")
    }
}
