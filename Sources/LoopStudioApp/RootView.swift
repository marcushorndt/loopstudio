import LoopStudioCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var keys = KeyMonitor()
    /// The height of the column right of the sidebar. The panel never asks for more than fits in it.
    @State private var columnHeight: CGFloat = 0

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .background(Theme.panel)
                .scrollContentBackground(.hidden)
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 440)
        } detail: {
            VStack(spacing: 0) {
                // A bar wider than the window must not widen the whole column: it is cut at the edge instead.
                TransportBar().frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
                Divider().overlay(Theme.line)
                Group {
                    switch model.viewMode {
                    case .session: SessionView()
                    case .arrangement: ArrangementView()
                    }
                }
                // The Session view takes the height of its content; the panel below gets the rest.
                // The arrangement fills the space itself, so the panel then keeps its own height.
                .frame(minWidth: 0, maxWidth: .infinity,
                       maxHeight: model.detailOpen && model.viewMode == .session ? nil : .infinity, alignment: .top)
                .layoutPriority(1)
                if model.detailOpen {
                    DetailResizeHandle()
                    DetailPanel()
                        .frame(minWidth: 0, maxWidth: .infinity,
                               minHeight: columnHeight > 0 ? min(model.detailHeight, max(120, columnHeight - 220)) : model.detailHeight,
                               maxHeight: .infinity)
                        .clipped()
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { model.detailShownHeight = $0 }
                }
                StatusBar().frame(minWidth: 0, maxWidth: .infinity).clipped()
            }
            .background(Theme.background)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { columnHeight = $0 }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("\(model.project.name)\(model.dirty ? " •" : "")").font(.headline)
                }
            }
        }
        .navigationTitle("")
        .sheet(isPresented: Bindable(model).shortcutsOpen) { ShortcutsSheet().environment(model) }
        .onAppear { keys.install(model: model) }
        .sheet(isPresented: Binding(get: { model.renameRequest != nil || model.clipRenameRequest != nil },
                                    set: { if !$0 { model.renameRequest = nil; model.clipRenameRequest = nil } })) {
            RenameSheet().environment(model)
        }
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            // The control under the pointer first, then the last message, then a warning.
            if !model.hoverInfo.isEmpty {
                Text(model.hoverInfo).lineLimit(1).foregroundStyle(Theme.text)
            } else {
                Text(model.status.isEmpty ? (model.warnings.first ?? "Ready") : model.status)
                    .lineLimit(1).foregroundStyle(model.status.isEmpty ? Theme.dim : Theme.accent)
            }
            Spacer()
            Text("\(Int(model.sampleRate / 1000)) kHz").foregroundStyle(Theme.dim)
            if let s = model.selectedTrack.flatMap({ model.project.track($0) }) { Text(s.name).foregroundStyle(Theme.dim) }
            if model.detailOpen { DetailTabs() }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Theme.panel)
    }
}

struct TransportBar: View {
    @Environment(AppModel.self) private var model
    @State private var bpmText = ""
    @FocusState private var bpmFocus: Bool

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                tile(model.transportPlaying ? "pause.fill" : "play.fill", on: model.transportPlaying, tint: Theme.play) { model.togglePlay() }
                    .hint("Play / pause (Space)")
                    .midiLearnable(.play)
                tile("stop.fill", on: false, tint: Theme.dim) { model.stop() }
                    .hint("Stop; press again to go to the start (⌘.)")
                    .midiLearnable(.stop)
                // During the count-in the record button blinks with the beat, like everything that waits.
                TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !(model.recording && model.engine.isCountingIn))) { _ in
                    let dim = model.recording && model.engine.isCountingIn && !model.waitBlink()
                    tile(model.recordArmed ? "record.circle.fill" : "record.circle", on: model.recordArmed && !dim, tint: .red) { model.toggleRecordArm() }
                }
                .hint("Arm recording (R). Space starts it.")
                .midiLearnable(.record)
                tile("metronome", on: model.metronomeOn, tint: Theme.accent) { model.toggleMetronome() }
                    .hint("Metronome (⌘K)")
                    .midiLearnable(.metronome)
                Button { model.toggleMIDILearn() } label: {
                    Text("MIDI").font(.system(size: 10, weight: .bold))
                        .frame(width: 36, height: 28)
                        .foregroundStyle(model.midiLearn ? Theme.accent : Theme.text.opacity(0.85))
                        .background(model.midiLearn ? Theme.accent.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.radius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(model.midiLearn ? Theme.accent.opacity(0.5) : Theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .hint(model.midiLearn ? "MIDI Learn is on: click a control in the app, then move a control on your device (⌘⇧M ends it)."
                      : "MIDI Learn (⌘⇧M): map knobs, faders and buttons to your MIDI device.\(model.midiMappings.isEmpty ? "" : " \(model.midiMappings.count) mapped.")")
                Menu {
                    ForEach([0, 1, 2, 4], id: \.self) { n in
                        Button(n == 0 ? "No count-in" : "\(n) bar\(n == 1 ? "" : "s") count-in") { model.countInBars = n }
                    }
                } label: {
                    Text(model.countInBars == 0 ? "No pre" : "Pre \(model.countInBars)").font(.system(size: 10, design: .monospaced))
                }
                .menuStyle(.borderlessButton).frame(width: 58).hint("Count-in before recording")
            }

            tempoField

            Text("4 / 4").font(.system(.body, design: .monospaced)).foregroundStyle(Theme.dim)

            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !model.transportPlaying)) { _ in
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.positionText()).font(.system(size: 22, weight: .medium, design: .monospaced))
                    Text(model.timeText()).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
                }
                .frame(width: 130, alignment: .leading)
            }

            // In a narrow window the buttons lose their text labels, so the bar never grows wider than the window.
            ViewThatFits(in: .horizontal) {
                loopButtons(labels: true)
                loopButtons(labels: false)
            }
            .frame(minWidth: 0, alignment: .leading)

            Spacer(minLength: 0)

            Picker("", selection: Bindable(model).viewMode) {
                Text("Session").tag(ViewMode.session)
                Text("Arrangement").tag(ViewMode.arrangement)
            }
            .pickerStyle(.segmented).frame(width: 210).labelsHidden()

            HStack(spacing: 4) {
                tile("arrow.uturn.backward", on: false, tint: Theme.text) { model.undo() }.disabled(!model.canUndo)
                tile("arrow.uturn.forward", on: false, tint: Theme.text) { model.redo() }.disabled(!model.canRedo)
                tile("rectangle.bottomthird.inset.filled", on: model.detailOpen, tint: Theme.accent) { model.detailOpen.toggle() }
                    .hint("Clip and device panel")
            }

            MasterMeter()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func loopButtons(labels: Bool) -> some View {
        HStack(spacing: 4) {
            tile("repeat", on: model.project.loop?.enabled == true, tint: Theme.accent) { model.toggleLoop() }
                .hint("Loop on/off (⇧⌘L)")
            Button { model.loopSelection() } label: { label("Loop Selection", "arrow.left.and.right", labels) }
                .controlSize(.small).fixedSize()
                .hint("Loop the marked range or clips and turn the loop on (⌘L)")
            if model.arrangementOverridden {
                Button { model.backToArrangement() } label: { label("Back to Arrangement", "arrow.uturn.backward.circle", labels) }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small).fixedSize()
                    .hint("Back to Arrangement: the arrangement plays again on all tracks")
            }
            Button { model.stopAllClips() } label: { label("Stop All Clips", "stop.circle", labels) }
                .controlSize(.small).fixedSize().disabled(!model.transportPlaying)
                .hint("Stop All Clips")
        }
    }

    @ViewBuilder private func label(_ text: String, _ symbol: String, _ withText: Bool) -> some View {
        if withText { Text(text) } else { Image(systemName: symbol) }
    }

    private var tempoField: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("", text: $bpmText)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .medium, design: .monospaced))
                .frame(width: 84)
                .focused($bpmFocus)
                .onSubmit { if let v = Double(bpmText.replacingOccurrences(of: ",", with: ".")) { model.setBPM(v) }; bpmFocus = false }
                .onAppear { bpmText = String(format: "%.2f", model.bpm) }
                .onChange(of: model.bpm) { if !bpmFocus { bpmText = String(format: "%.2f", model.bpm) } }
            Text("BPM").font(.system(size: 10)).foregroundStyle(Theme.dim)
        }
    }

    private func tile(_ symbol: String, on: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 28)
                .foregroundStyle(on ? tint : Theme.text.opacity(0.85))
                .background(on ? tint.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(on ? tint.opacity(0.5) : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct MasterMeter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            LevelBar(level: model.meterLevel(track: nil), horizontal: true)
                .frame(width: 110, height: 10)
        }
    }
}

/// One text field, focused at once, so a typed name replaces the old one. Return renames, Escape cancels.
struct RenameSheet: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @FocusState private var focused: Bool

    private var isClip: Bool { model.clipRenameRequest != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isClip ? "Rename Clip" : "Rename Track").font(.headline)
            TextField("Name", text: $text)
                .focused($focused)
                .onSubmit(commit)
                .frame(width: 260)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                Button("Rename", action: commit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onAppear {
            if let id = model.clipRenameRequest { text = model.project.findClip(id)?.1.ownName ?? "" }
            else if let id = model.renameRequest { text = model.project.track(id)?.name ?? "" }
            focused = true
        }
    }

    private func commit() {
        if let id = model.clipRenameRequest { model.apply(.setClipName(clip: id, name: text)) }
        else if let id = model.renameRequest, !text.isEmpty { model.apply(.setTrackName(id: id, name: text)) }
        close()
    }

    private func close() { model.renameRequest = nil; model.clipRenameRequest = nil }
}

/// The line above the inspector. Drag it to make the inspector taller or shorter; the slots above scroll.
struct DetailResizeHandle: View {
    @Environment(AppModel.self) private var model
    @State private var startHeight: CGFloat?

    var body: some View {
        Rectangle().fill(Theme.line).frame(height: 1)
            .frame(maxWidth: .infinity, minHeight: 7)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    if startHeight == nil { startHeight = max(model.detailHeight, model.detailShownHeight) }
                    model.detailHeight = min(2_000, max(150, (startHeight ?? 260) - g.translation.height))
                }
                .onEnded { _ in startHeight = nil })
            .onTapGesture(count: 2) { model.detailHeight = 260 }
            .hint("Drag to resize the inspector. Double-click resets it.")
    }
}
