import LoopStudioCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var keys = KeyMonitor()

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .background(Theme.panel)
                .scrollContentBackground(.hidden)
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 440)
        } detail: {
            VStack(spacing: 0) {
                TransportBar()
                Divider().overlay(Theme.line)
                Group {
                    switch model.viewMode {
                    case .session: SessionView()
                    case .arrangement: ArrangementView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.detailOpen {
                    DetailResizeHandle()
                    DetailPanel().frame(height: model.detailHeight)
                }
                StatusBar()
            }
            .background(Theme.background)
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
            Text(model.status.isEmpty ? (model.warnings.first ?? "Ready") : model.status)
                .lineLimit(1).foregroundStyle(model.status.isEmpty ? Theme.dim : Theme.accent)
            Spacer()
            Text("\(Int(model.sampleRate / 1000)) kHz").foregroundStyle(Theme.dim)
            if let s = model.selectedTrack.flatMap({ model.project.track($0) }) { Text(s.name).foregroundStyle(Theme.dim) }
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
                    .help("Play / pause (Space)")
                tile("stop.fill", on: false, tint: Theme.dim) { model.stop() }
                    .help("Stop; press again to go to the start (⌘.)")
                tile(model.recordArmed ? "record.circle.fill" : "record.circle", on: model.recordArmed, tint: .red) { model.toggleRecordArm() }
                    .help("Arm recording (R). Space starts it.")
                tile("metronome", on: model.metronomeOn, tint: Theme.accent) { model.toggleMetronome() }
                    .help("Metronome (⌘K)")
                Menu {
                    ForEach([0, 1, 2, 4], id: \.self) { n in
                        Button(n == 0 ? "No count-in" : "\(n) bar\(n == 1 ? "" : "s") count-in") { model.countInBars = n }
                    }
                } label: {
                    Text(model.countInBars == 0 ? "No pre" : "Pre \(model.countInBars)").font(.system(size: 10, design: .monospaced))
                }
                .menuStyle(.borderlessButton).frame(width: 58).help("Count-in before recording")
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

            HStack(spacing: 4) {
                tile("repeat", on: model.project.loop?.enabled == true, tint: Theme.accent) { model.toggleLoop() }
                    .help("Loop on/off (⇧⌘L)")
                Button("Loop Selection") { model.loopSelection() }.controlSize(.small)
                    .help("Loop the marked range or clips and turn the loop on (⌘L)")
                if model.arrangementOverridden {
                    Button("Back to Arrangement") { model.backToArrangement() }
                        .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
                }
                Button("Stop All Clips") { model.stopAllClips() }.controlSize(.small).disabled(!model.transportPlaying)
            }

            Spacer()

            Picker("", selection: Bindable(model).viewMode) {
                Text("Session").tag(ViewMode.session)
                Text("Arrangement").tag(ViewMode.arrangement)
            }
            .pickerStyle(.segmented).frame(width: 210).labelsHidden()

            HStack(spacing: 4) {
                tile("arrow.uturn.backward", on: false, tint: Theme.text) { model.undo() }.disabled(!model.canUndo)
                tile("arrow.uturn.forward", on: false, tint: Theme.text) { model.redo() }.disabled(!model.canRedo)
                tile("rectangle.bottomthird.inset.filled", on: model.detailOpen, tint: Theme.accent) { model.detailOpen.toggle() }
                    .help("Clip and device panel")
            }

            MasterMeter()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
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
                    if startHeight == nil { startHeight = model.detailHeight }
                    model.detailHeight = min(640, max(150, (startHeight ?? 260) - g.translation.height))
                }
                .onEnded { _ in startHeight = nil })
            .onTapGesture(count: 2) { model.detailHeight = 260 }
            .help("Drag to resize the inspector. Double-click resets it.")
    }
}
