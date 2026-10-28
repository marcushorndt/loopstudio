import AppKit
import SwiftUI

/// Every command a key can start. The menu bar, the right-click menus, the key monitor and the
/// shortcut sheet all read this one table, so they cannot disagree.
enum AppAction: String, CaseIterable, Identifiable {
    case newProject, newDemo, save, saveAs, exportAudio
    case undo, redo, cut, copy, paste, duplicate, deleteSelection, splitAtPlayhead, deactivateClip
    case record, toggleMetronome, play, pause, stopRewind, stopAllClips, loopSelection, loopToggle, backToArrangement
    case insertAudioTrack, insertMIDITrack, insertReturnTrack, insertGroupTrack, groupTracks, renameTrack, duplicateTrack
    case insertScene, deleteScene, duplicateScene
    case toggleKeyboardMIDI
    case moveUp, moveDown, moveLeft, moveRight, launchSelected
    case sessionView, arrangementView, switchView, toggleDetail, toggleAutomation, showShortcuts

    var id: String { rawValue }

    enum Category: String, CaseIterable { case file = "File", edit = "Edit", transport = "Transport", track = "Track", scene = "Scene", navigate = "Navigate", view = "View" }

    var category: Category {
        switch self {
        case .newProject, .newDemo, .save, .saveAs, .exportAudio: .file
        case .undo, .redo, .cut, .copy, .paste, .duplicate, .deleteSelection, .splitAtPlayhead, .deactivateClip: .edit
        case .record, .toggleMetronome, .play, .pause, .stopRewind, .stopAllClips, .loopSelection, .loopToggle, .backToArrangement: .transport
        case .insertAudioTrack, .insertMIDITrack, .insertReturnTrack, .insertGroupTrack, .groupTracks, .renameTrack, .duplicateTrack: .track
        case .insertScene, .deleteScene, .duplicateScene: .scene
        case .toggleKeyboardMIDI: .transport
        case .moveUp, .moveDown, .moveLeft, .moveRight, .launchSelected: .navigate
        case .sessionView, .arrangementView, .switchView, .toggleDetail, .toggleAutomation, .showShortcuts: .view
        }
    }

    var title: String {
        switch self {
        case .newProject: "New Project"
        case .newDemo: "New Demo Project"
        case .save: "Save"
        case .saveAs: "Save As…"
        case .exportAudio: "Export Audio…"
        case .undo: "Undo"
        case .redo: "Redo"
        case .cut: "Cut"
        case .copy: "Copy"
        case .paste: "Paste"
        case .duplicate: "Duplicate"
        case .deleteSelection: "Delete"
        case .splitAtPlayhead: "Split at Playhead"
        case .deactivateClip: "Activate / Deactivate Clip"
        case .record: "Arm Recording"
        case .toggleMetronome: "Metronome On/Off"
        case .play: "Play / Stop"
        case .pause: "Pause / Continue"
        case .stopRewind: "Stop and Rewind"
        case .stopAllClips: "Stop All Clips"
        case .loopSelection: "Loop Selection"
        case .loopToggle: "Loop On/Off"
        case .backToArrangement: "Back to Arrangement"
        case .insertAudioTrack: "Insert Audio Track"
        case .insertMIDITrack: "Insert MIDI Track"
        case .insertReturnTrack: "Insert Return Track"
        case .insertGroupTrack: "Insert Group Track"
        case .groupTracks: "Group Selected Tracks"
        case .renameTrack: "Rename Track"
        case .duplicateTrack: "Duplicate Track"
        case .insertScene: "Insert Scene"
        case .deleteScene: "Delete Scene"
        case .duplicateScene: "Duplicate Scene"
        case .toggleKeyboardMIDI: "Computer Keyboard as MIDI Keys"
        case .moveUp: "Select Up"
        case .moveDown: "Select Down"
        case .moveLeft: "Select Left"
        case .moveRight: "Select Right"
        case .launchSelected: "Launch Selected Clip or Scene"
        case .sessionView: "Session View"
        case .arrangementView: "Arrangement View"
        case .switchView: "Switch Session / Arrangement"
        case .toggleDetail: "Show Clip and Device Panel"
        case .toggleAutomation: "Show / Hide Automation"
        case .showShortcuts: "Keyboard Shortcuts"
        }
    }

    var binding: KeyBinding? {
        switch self {
        case .newProject: KeyBinding("n", .command)
        case .save: KeyBinding("s", .command)
        case .saveAs: KeyBinding("s", [.command, .shift])
        case .exportAudio: KeyBinding("r", [.command, .shift])
        case .undo: KeyBinding("z", .command)
        case .redo: KeyBinding("z", [.command, .shift])
        case .cut: KeyBinding("x", .command)
        case .copy: KeyBinding("c", .command)
        case .paste: KeyBinding("v", .command)
        case .duplicate: KeyBinding("d", .command)
        case .deleteSelection: KeyBinding("\u{7F}", [])
        case .splitAtPlayhead: KeyBinding("e", .command)
        case .deactivateClip: KeyBinding("0", [])
        case .record: KeyBinding("r", [])
        case .toggleMetronome: KeyBinding("k", .command)
        case .play: KeyBinding(" ", [])
        case .pause: KeyBinding(" ", .shift)
        case .stopRewind: KeyBinding(".", .command)
        case .stopAllClips: KeyBinding(".", [.command, .shift])
        case .loopSelection: KeyBinding("l", .command)
        case .loopToggle: KeyBinding("l", [.command, .shift])
        case .insertAudioTrack: KeyBinding("t", .command)
        case .insertMIDITrack: KeyBinding("t", [.command, .shift])
        case .insertReturnTrack: KeyBinding("t", [.command, .option])
        case .groupTracks: KeyBinding("g", .command)
        case .renameTrack: KeyBinding("r", .command)
        case .insertScene: KeyBinding("i", [.command, .shift])
        case .toggleKeyboardMIDI: KeyBinding("m", [])
        case .moveUp: KeyBinding("\u{F700}", [])
        case .moveDown: KeyBinding("\u{F701}", [])
        case .moveLeft: KeyBinding("\u{F702}", [])
        case .moveRight: KeyBinding("\u{F703}", [])
        case .launchSelected: KeyBinding("\r", [])
        case .sessionView: KeyBinding("1", .command)
        case .arrangementView: KeyBinding("2", .command)
        case .switchView: KeyBinding("\t", [])
        case .toggleDetail: KeyBinding("d", [.command, .option])
        case .toggleAutomation: KeyBinding("a", [])
        case .showShortcuts: KeyBinding("/", .command)
        default: nil
        }
    }
}

struct KeyBinding {
    let character: Character
    let modifiers: EventModifiers

    init(_ character: Character, _ modifiers: EventModifiers) {
        self.character = character
        self.modifiers = modifiers
    }

    var key: KeyEquivalent { KeyEquivalent(character) }

    /// Keys without Command, Option or Control. The menu system can lose these to the focused control,
    /// so the key monitor handles them first.
    var isPlain: Bool { modifiers.isDisjoint(with: [.command, .option, .control]) }

    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch character {
        case " ": text += "Space"
        case "\t": text += "Tab"
        case "\u{7F}": text += "⌫"
        case "\u{F700}": text += "↑"
        case "\u{F701}": text += "↓"
        case "\u{F702}": text += "←"
        case "\u{F703}": text += "→"
        case "\r": text += "Return"
        default: text += String(character).uppercased()
        }
        return text
    }

    func matches(_ event: NSEvent) -> Bool {
        guard let typed = event.charactersIgnoringModifiers?.lowercased(), !typed.isEmpty else { return false }
        let wanted = character == "\u{7F}" ? ["\u{7F}", "\u{F728}"] : [String(character).lowercased()]
        guard wanted.contains(typed) else { return false }
        var flags: EventModifiers = []
        let f = event.modifierFlags
        if f.contains(.command) { flags.insert(.command) }
        if f.contains(.shift) { flags.insert(.shift) }
        if f.contains(.option) { flags.insert(.option) }
        if f.contains(.control) { flags.insert(.control) }
        return flags == modifiers
    }
}

@MainActor
extension AppAction {
    /// A menu item for the action, with its key shown. Use it in the menu bar and in right-click menus.
    /// With `run`, the item acts on the right-clicked thing, so the global selection does not disable it.
    @ViewBuilder
    func button(_ model: AppModel, title custom: String? = nil, run: (() -> Void)? = nil) -> some View {
        let label = custom ?? model.title(of: self)
        let enabled = run != nil || model.isEnabled(self)
        if let b = binding {
            Button(label) { if let run { run() } else { model.perform(self) } }
                .keyboardShortcut(b.key, modifiers: b.modifiers)
                .disabled(!enabled)
        } else {
            Button(label) { if let run { run() } else { model.perform(self) } }.disabled(!enabled)
        }
    }
}

@MainActor
final class KeyMonitor {
    private var token: Any?

    /// Piano layout on the home row, like Live: A W S E D F T G Y H U J K.
    private static let piano: [String: Int] = ["a": 0, "w": 1, "s": 2, "e": 3, "d": 4, "f": 5, "t": 6, "g": 7, "y": 8, "h": 9, "u": 10, "j": 11, "k": 12, "o": 13, "l": 14, "p": 15]
    private var held: [String: UInt8] = [:]

    func install(model: AppModel) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self, weak model] event in
            guard let self, let model else { return event }
            // Typing in a text field keeps its keys.
            if NSApp.keyWindow?.firstResponder is NSText { return event }
            let typed = event.charactersIgnoringModifiers?.lowercased() ?? ""
            // Turning the keyboard off releases the notes it still holds.
            if !model.keyboardMIDI, !held.isEmpty {
                for pitch in held.values { model.noteOff(pitch) }
                held.removeAll()
            }
            let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            if model.keyboardMIDI, plain {
                if let step = Self.piano[typed] {
                    if event.type == .keyDown, !event.isARepeat {
                        let pitch = UInt8(min(127, max(0, 12 * (model.keyboardOctave + 1) + step)))
                        held[typed] = pitch
                        model.noteOn(pitch, velocity: UInt8(model.keyboardVelocity))
                    } else if event.type == .keyUp, let pitch = held.removeValue(forKey: typed) {
                        model.noteOff(pitch)
                    }
                    return nil
                }
                if event.type == .keyDown, typed == "z" || typed == "x" {
                    model.keyboardOctave = min(8, max(-1, model.keyboardOctave + (typed == "x" ? 1 : -1)))
                    model.status = "Keyboard octave C\(model.keyboardOctave)"
                    return nil
                }
                if event.type == .keyDown, typed == "c" || typed == "v" {
                    model.keyboardVelocity = min(127, max(1, model.keyboardVelocity + (typed == "v" ? 20 : -20)))
                    model.status = "Keyboard velocity \(model.keyboardVelocity)"
                    return nil
                }
            }
            guard event.type == .keyDown, !event.isARepeat else { return event }
            for action in AppAction.allCases {
                if let b = action.binding, b.isPlain, b.matches(event), model.isEnabled(action) {
                    model.perform(action)
                    return nil
                }
            }
            return event
        }
    }
}

/// The sheet that lists every shortcut as it is now.
struct ShortcutsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts").font(.title3.bold())
                Spacer()
                TextField("Search", text: $filter).textFieldStyle(.roundedBorder).frame(width: 200)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(AppAction.Category.allCases, id: \.self) { category in
                        let items = AppAction.allCases.filter {
                            $0.category == category && (filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter)
                                                         || ($0.binding?.display.localizedCaseInsensitiveContains(filter) ?? false))
                        }
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(category.rawValue).font(.caption.bold()).foregroundStyle(Theme.dim)
                                ForEach(items) { action in
                                    HStack {
                                        Text(action.title)
                                        Spacer()
                                        Text(action.binding?.display ?? "none")
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(action.binding == nil ? Theme.dim : .white)
                                            .padding(.horizontal, 8).padding(.vertical, 2)
                                            .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
                                    }
                                }
                            }
                        }
                    }
                    Text("Mouse: double-click a MIDI lane to create a clip. Shift-click a curve point to change its shape. Right-click almost anywhere for more actions.")
                        .font(.caption).foregroundStyle(Theme.dim)
                }
                .padding(14)
            }
        }
        .frame(width: 460, height: 560)
        .background(Theme.background)
    }
}
