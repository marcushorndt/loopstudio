import AppKit
import LoopStudioCore
import SwiftUI

@main
struct LoopStudioApp: App {
    @State private var model = AppModel()

    init() {
        // Started from the shell or a bare bundle, the app needs this to get a menu bar and focus.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup("LoopStudio") {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1320, minHeight: 700)
        }
        .defaultSize(width: 1500, height: 940)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") { model.newProject() }.keyboardShortcut("n")
                Button("New Demo Project") { model.newDemoProject() }
                Button("Save") { model.save() }.keyboardShortcut("s")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }.keyboardShortcut("z").disabled(!model.canUndo)
                Button("Redo") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo)
            }
            CommandMenu("Transport") {
                Button(model.transportPlaying ? "Stop" : "Play") { model.togglePlay() }.keyboardShortcut(.space, modifiers: [])
                Button("Stop and Rewind") { model.stop() }.keyboardShortcut(".", modifiers: .command)
                Button("Stop All Clips") { model.stopAllClips() }.keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Loop Selection") { model.loopSelection() }.keyboardShortcut("l", modifiers: .command)
                Button("Loop On/Off") { model.toggleLoop() }.keyboardShortcut("l", modifiers: [.command, .shift])
            }
            CommandMenu("Track") {
                Button("Insert Audio Track") { model.addTrack(kind: .audio) }.keyboardShortcut("t", modifiers: .command)
                Button("Delete Selected Clips") { model.deleteSelected() }.keyboardShortcut(.delete, modifiers: [])
                Button("Insert Group Track") { model.addTrack(kind: .group) }
                Button("Group Selected Tracks") { model.groupSelectedTracks() }.keyboardShortcut("g", modifiers: .command)
                Button("Insert Return Track") { model.addTrack(kind: .returnTrack) }.keyboardShortcut("t", modifiers: [.command, .option])
                Button("Insert MIDI Track") { model.addTrack(kind: .midi) }.keyboardShortcut("t", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Session View") { model.viewMode = .session }.keyboardShortcut("1", modifiers: .command)
                Button("Arrangement View") { model.viewMode = .arrangement }.keyboardShortcut("2", modifiers: .command)
                Button("Switch View") { model.viewMode = model.viewMode == .session ? .arrangement : .session }
                    .keyboardShortcut(.tab, modifiers: [])
                Button("Show Clip and Device Panel") { model.detailOpen.toggle() }.keyboardShortcut("d", modifiers: [.command, .option])
            }
        }
    }
}
