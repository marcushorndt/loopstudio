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
                AppAction.newProject.button(model)
                AppAction.newDemo.button(model)
                AppAction.save.button(model)
            }
            CommandGroup(replacing: .undoRedo) {
                AppAction.undo.button(model)
                AppAction.redo.button(model)
            }
            CommandGroup(replacing: .pasteboard) {
                AppAction.cut.button(model)
                AppAction.copy.button(model)
                AppAction.paste.button(model)
                AppAction.duplicate.button(model)
                AppAction.deleteSelection.button(model)
                AppAction.splitAtPlayhead.button(model)
            }
            CommandMenu("Transport") {
                AppAction.play.button(model)
                AppAction.pause.button(model)
                AppAction.stopRewind.button(model)
                AppAction.stopAllClips.button(model)
                AppAction.loopSelection.button(model)
                AppAction.loopToggle.button(model)
                AppAction.backToArrangement.button(model)
            }
            CommandMenu("Track") {
                AppAction.insertAudioTrack.button(model)
                AppAction.insertMIDITrack.button(model)
                AppAction.insertReturnTrack.button(model)
                AppAction.insertGroupTrack.button(model)
                Divider()
                AppAction.groupTracks.button(model)
                AppAction.renameTrack.button(model)
                AppAction.duplicateTrack.button(model)
                Divider()
                AppAction.insertScene.button(model)
                AppAction.duplicateScene.button(model)
                AppAction.deleteScene.button(model)
            }
            CommandGroup(after: .toolbar) {
                AppAction.sessionView.button(model)
                AppAction.arrangementView.button(model)
                AppAction.switchView.button(model)
                AppAction.toggleDetail.button(model)
            }
            CommandGroup(replacing: .help) {
                AppAction.showShortcuts.button(model)
            }
        }
    }
}
