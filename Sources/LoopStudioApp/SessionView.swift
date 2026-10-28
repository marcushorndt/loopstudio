import LoopStudioCore
import SwiftUI

private let columnWidth: CGFloat = 128
private let slotHeight: CGFloat = 28
private let gap: CGFloat = 2

struct SessionView: View {
    @Environment(AppModel.self) private var model
    /// The slot grid and the mixer scroll sideways together.
    @State private var scrollX = ScrollPosition()

    var body: some View {
        let all = model.project.tracks
        // Tracks pile up from the left and scroll. Busses (returns) and the master stay at the right edge.
        let tracks = all.filter { $0.kind != .returnTrack }
        let busses = all.filter { $0.kind == .returnTrack }
        let rows = max(8, (all.map(\.slots.count).max() ?? 0) + 1)

        VStack(spacing: 6) {
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: gap) {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: gap) {
                            ForEach(tracks, id: \.id) { TrackColumn(track: $0, rows: rows) }
                            NewTrackColumn(rows: rows)
                        }
                    }
                    .scrollPosition($scrollX)
                    .scrollIndicators(.hidden)
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(busses, id: \.id) { TrackColumn(track: $0, rows: rows) }
                        SceneColumn(rows: rows)
                    }
                }
                .padding(.horizontal, 6).padding(.top, 6)
            }
            // Stop buttons stay in view under the slots: tracks, busses and the master.
            HStack(alignment: .top, spacing: gap) {
                ScrollView(.horizontal) {
                    HStack(spacing: gap) {
                        ForEach(tracks, id: \.id) { StopButton(track: $0, width: columnWidth) }
                        Color.clear.frame(width: columnWidth * 0.6)
                    }
                }
                .scrollPosition($scrollX)
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
                .scrollPosition($scrollX)
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
        .dropDestination(for: URL.self) { urls, _ in model.dropOnNewTrack(urls) }
    }
}

private struct TrackColumn: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let rows: Int

    var body: some View {
        VStack(spacing: gap) {
            header
            // Busses have slots too: a dummy clip there is silent but carries automation.
            ForEach(0..<rows, id: \.self) { row in SlotCell(track: track, row: row) }
        }
        .frame(width: columnWidth)
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
        .onTapGesture(count: 2) { model.openTrackInspector(track.id) }
        .onTapGesture { model.focusTrack(track.id) }
        .dropDestination(for: String.self) { items, _ in
            return model.dropDevices(items, on: track.id)
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
                Image(systemName: "stop.fill").font(.system(size: 11)).foregroundStyle(Theme.dim).frame(width: 26)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: slotHeight)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .frame(width: width)
        .help(track.kind == .master ? "Stop all clips" : (track.kind == .returnTrack ? "Stop every track that feeds this bus" : "Stop this track's clip at the next bar"))
    }
}

private struct SlotCell: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let row: Int

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !model.transportPlaying)) { context in
            let state = model.slotState(track: track, row: row, at: model.sessionTick)
            cell(state, blink: Int(context.date.timeIntervalSinceReferenceDate * 5) % 2 == 0)
        }
        .dropDestination(for: URL.self) { urls, _ in model.dropOnSlot(urls, track: track.id, row: row) }
    }

    @ViewBuilder
    private func cell(_ state: SlotState, blink: Bool) -> some View {
        let slot = row < track.slots.count ? track.slots[row] : nil
        let tint = Theme.track(slot?.clip.colorIndex ?? track.colorIndex)
        if let slot {
            let selected = model.selectedClip == slot.clip.id
            HStack(spacing: 0) {
                Button { model.launch(track: track.id, row: row) } label: {
                    Image(systemName: icon(state)).font(.system(size: 11))
                        .foregroundStyle(isPlaying(state) ? Theme.play : tint)
                        .frame(width: 26, height: slotHeight)
                        .background(isPlaying(state) ? Theme.background.opacity(0.7) : Color.clear)
                }
                .buttonStyle(.plain)
                HStack {
                    Text(model.clipName(slot.clip)).lineLimit(1).font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 0)
                    if slot.follow != nil { Image(systemName: "arrow.triangle.branch").font(.system(size: 9)) }
                }
                .padding(.horizontal, 5).frame(maxWidth: .infinity, minHeight: slotHeight)
                .contentShape(Rectangle())
                .onTapGesture { model.selectedClip = slot.clip.id; model.selectedTrack = track.id }
            }
            .foregroundStyle(Theme.onTint)
            .background(alignment: .leading) {
                GeometryReader { geo in
                    Rectangle().fill(Theme.panel)
                    Rectangle().fill(Theme.clipBody(slot.clip.colorIndex ?? track.colorIndex, active: isPlaying(state)))
                    if !slot.clip.lanes.isEmpty { MiniCurves(clip: slot.clip, owner: track).padding(.leading, 26).padding(.vertical, 2) }
                    if case .playing(let p) = state {
                        Rectangle().fill(tint.opacity(0.35)).frame(width: geo.size.width * p)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(state.isQueued && blink ? Theme.accent : (selected ? Theme.text : tint.opacity(0.5)), lineWidth: selected || state.isQueued ? 1.5 : 1))
            .frame(height: slotHeight)
            .contextMenu { SlotMenu(track: track, row: row) }
        } else {
            Button {
                switch track.kind {
                case .midi: model.createMIDIClip(track: track.id, row: row)
                default: model.stopClips(of: track)
                }
            } label: {
                HStack(spacing: 0) {
                    Image(systemName: track.kind == .midi ? "plus" : "stop.fill").font(.system(size: 11)).foregroundStyle(Theme.dim.opacity(0.5))
                        .frame(width: 26)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: slotHeight)
                    .background(Theme.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.radius))
            }
.buttonStyle(.plain)
            .contextMenu { SlotMenu(track: track, row: row) }
            .help(track.kind == .midi ? "Create an empty MIDI clip"
                  : (track.kind == .audio ? "Empty slot. Drop an audio file here." : "Empty slot. Right-click for a dummy clip: silent, it carries automation."))
        }
    }

    private func isPlaying(_ s: SlotState) -> Bool { if case .playing = s { true } else { false } }
    private func icon(_ s: SlotState) -> String { isPlaying(s) ? "play.fill" : "play.fill" }
}

extension SlotState {
    var isQueued: Bool { if case .queued = self { true } else { false } }
}

private struct NewTrackColumn: View {
    @Environment(AppModel.self) private var model
    let rows: Int

    var body: some View {
        VStack(spacing: gap) {
            Menu {
                Button("Audio Track") { model.addTrack(kind: .audio) }
                Button("MIDI Track") { model.addTrack(kind: .midi) }
            } label: {
                Image(systemName: "plus").frame(maxWidth: .infinity, minHeight: 30)
            }
            .menuStyle(.borderlessButton).foregroundStyle(Theme.dim)
            Text("Drop audio here\nfor a new track").font(.caption).foregroundStyle(Theme.dim.opacity(0.6)).multilineTextAlignment(.center)
                .padding(.top, 20)
            Spacer()
        }
        .frame(width: columnWidth * 0.6, height: CGFloat(rows) * (slotHeight + gap) + 30)
        .dropDestination(for: URL.self) { urls, _ in model.dropOnNewTrack(urls) }
    }
}

/// Scene launch buttons: one per row. Starts every clip of that row.
private struct SceneColumn: View {
    @Environment(AppModel.self) private var model
    let rows: Int

    var body: some View {
        VStack(spacing: gap) {
            Text("Scenes").font(.system(size: 10)).foregroundStyle(Theme.dim).frame(height: 30)
            ForEach(0..<rows, id: \.self) { row in
                Button { model.launchScene(row) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 9))
                        Text("\(row + 1)").font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundStyle(Theme.text)
                    .frame(width: columnWidth, height: slotHeight)
                    .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .contextMenu { SceneMenu(row: row) }
            }
        }
    }
}
