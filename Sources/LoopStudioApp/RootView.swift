import LoopStudioCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var keys = KeyMonitor()
    /// The height of the column right of the sidebar. The panel never asks for more than fits in it.
    @State private var columnHeight: CGFloat = 0
    /// The inspector shows the device chain: one fixed height, no resize handle.
    private var devicesShown: Bool { model.detailTab == .devices }

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
                       maxHeight: model.detailOpen && model.viewMode == .session && !devicesShown ? nil : .infinity, alignment: .top)
                .layoutPriority(1)
                if model.detailOpen {
                    // Above the view over it, so its grab area can reach over that view's bottom edge.
                    DetailResizeHandle().zIndex(1)
                    // The device view is exactly one card high and does not resize; the clip view keeps the
                    // height the user dragged.
                    DetailPanel()
                        .frame(minWidth: 0, maxWidth: .infinity,
                               minHeight: devicesShown ? DeviceLayout.panelHeight
                                   : columnHeight > 0 ? min(model.detailHeight, max(120, columnHeight - 220)) : model.detailHeight,
                               maxHeight: devicesShown ? DeviceLayout.panelHeight : .infinity)
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
        .sheet(isPresented: Bindable(model).exportSheetOpen) { ExportSheet().environment(model) }
        .onAppear {
            keys.install(model: model)
            // `defaults write app.loopstudio.dev openPatchEditor 1`: the editor of the first Patch device opens at
            // launch, once. For looking at the editor without a click.
            if UserDefaults.standard.bool(forKey: "openPatchEditor") {
                UserDefaults.standard.removeObject(forKey: "openPatchEditor")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    for t in model.project.allTracks {
                        if let d = t.devices.first(where: { $0.format == "builtin" && $0.identifier == "patch" }) {
                            PatchEditorWindow.show(model: model, track: t.id, device: d.id)
                            return
                        }
                    }
                }
            }
        }
        .sheet(isPresented: Binding(get: { model.renameRequest != nil || model.clipRenameRequest != nil },
                                    set: { if !$0 { model.renameRequest = nil; model.clipRenameRequest = nil } })) {
            RenameSheet().environment(model)
        }
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model
    /// A new message holds the line for a few seconds before the hover text may take it back.
    @State private var statusFresh = false

    var body: some View {
        HStack(spacing: 12) {
            // A mode that swallows clicks or keys stays visible whatever the pointer rests on.
            if model.midiLearn { modePill("MIDI Map · click a control, move a knob · Esc ends", tint: Theme.midiMap) }
            if model.macroMap != nil { modePill("Macro Map · click a knob in the rack · Esc ends", tint: Theme.macroMap) }
            if model.keyboardMIDI { modePill("Keyboard plays notes · C\(model.keyboardOctave) · Esc ends", tint: Theme.play) }
            if model.drawMode { modePill("Draw · Esc ends", tint: Theme.track(2)) }
            if model.automationEdit { modePill("Automation · the curve over the clips takes the clicks", tint: Theme.automationDot) }
            // A fresh message first, then the control under the pointer, then the last message, then a warning.
            if !model.hoverInfo.isEmpty, !(statusFresh && !model.status.isEmpty) {
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
        .task(id: model.status) {
            statusFresh = !model.status.isEmpty
            try? await Task.sleep(for: .seconds(4))
            statusFresh = false
        }
    }

    private func modePill(_ text: String, tint: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(tint.opacity(0.16), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.5), lineWidth: 1))
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
                    .hint("Metronome (K)")
                    .midiLearnable(.metronome)
                Button { model.toggleMIDILearn() } label: {
                    Text("MIDI").font(.system(size: 10, weight: .bold))
                        .frame(width: 36, height: 28)
                        .foregroundStyle(model.midiLearn ? Theme.accent : Theme.text.opacity(0.85))
                        .background(model.midiLearn ? Theme.accent.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.radius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(model.midiLearn ? Theme.accent.opacity(0.5) : Theme.line, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hint(model.midiLearn ? "MIDI Learn is on: click a control in the app, then move a control on your device (⌘⇧M ends it)."
                      : "MIDI Learn (⌘⇧M): map knobs, faders and buttons to your MIDI device.\(model.midiMappings.isEmpty ? "" : " \(model.midiMappings.count) mapped.")")
                Button { model.linkEnabled.toggle() } label: {
                    Text(model.linkEnabled && model.linkPeers > 0 ? "Link \(model.linkPeers)" : "Link").font(.system(size: 10, weight: .bold))
                        .frame(width: model.linkEnabled && model.linkPeers > 0 ? 48 : 36, height: 28)
                        .foregroundStyle(model.linkEnabled ? Theme.play : Theme.text.opacity(0.85))
                        .background(model.linkEnabled ? Theme.play.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.radius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(model.linkEnabled ? Theme.play.opacity(0.5) : Theme.line, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hint(model.linkEnabled
                      ? "Ableton Link is on: \(model.linkPeers == 0 ? "no other app yet" : "\(model.linkPeers) other app\(model.linkPeers == 1 ? "" : "s")") on the network share the tempo and the beat grid. Play starts on the shared bar. Start/stop sync is in Settings > Audio."
                      : "Ableton Link: share the tempo and the beat grid with Live, Push and other Link apps on the network.")
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

            if model.midiClockInUID != nil { externalClockLight }

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

    /// "EXT": the transport follows a MIDI clock. Lit while the clock's beats come in, like Live's EXT button.
    private var externalClockLight: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let clock = model.externalClock
            let live = clock.map { context.date.timeIntervalSince($0.lastBeat) < 1.5 } ?? false
            let tint = live ? (clock?.running == true ? Theme.play : Theme.accent) : Theme.dim
            Text("EXT").font(.system(size: 10, weight: .bold))
                .frame(width: 36, height: 28)
                .foregroundStyle(live ? tint : Theme.text.opacity(0.5))
                .background(live ? tint.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(live ? tint.opacity(0.5) : Theme.line, lineWidth: 1))
                .hint(live ? "External MIDI clock: \(clock?.bpm.map { String(format: "%.2f BPM", $0) } ?? "measuring"), \(clock?.running == true ? "running" : "stopped"). Turn it off in Settings > Audio."
                      : "External MIDI clock chosen in Settings > Audio, but no clock comes in.")
        }
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
                .onChange(of: model.tempoNudges) { bpmText = String(format: "%.2f", model.bpm) }
                // A drag up or down changes the tempo: 1 BPM per step, with Shift 0.1 BPM. A click types.
                .dragsValue(focus: $bpmFocus) { n, fine in model.setBPM(model.bpm + Double(n) * (fine ? 0.1 : 1)) }
                .onChange(of: bpmFocus) { _, focused in
                    model.tempoFieldFocused = focused
                    // A click into the field marks the whole tempo, so typing replaces it.
                    // The click that gave the focus still places the cursor when the button comes up, so the
                    // key monitor marks it all after that release.
                    if focused { DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil) } }
                }
            Text("BPM").font(.system(size: 10)).foregroundStyle(Theme.dim)
        }
        .hint("Tempo. Drag up or down to change it, click to type it, or press Up and Down: 1 BPM, with Shift 0.1 BPM")
    }

    private func tile(_ symbol: String, on: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 28)
                .foregroundStyle(on ? tint : Theme.text.opacity(0.85))
                .background(on ? tint.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(on ? tint.opacity(0.5) : Theme.line, lineWidth: 1))
                // The frame takes the click, not only the symbol: a clear background is not hit-tested.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        if model.detailTab == .devices {
            // The device view has one height: the line is only a line.
            Rectangle().fill(Theme.line).frame(height: 1).frame(maxWidth: .infinity, minHeight: 7)
        } else {
            // The grab area reaches 12 points up, over the bottom edge of the row above. That edge (the Master
            // row in the arrangement) has its own height handle and draws a line too; without the overlap a drag
            // on the line one sees resizes that row instead of the inspector.
            Rectangle().fill(Theme.line).frame(height: 1)
                .frame(maxWidth: .infinity, minHeight: 7)
                .padding(.top, 12)
                .contentShape(Rectangle())
                .padding(.top, -12)
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
}
