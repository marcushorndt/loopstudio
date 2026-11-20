import AppKit
import SwiftUI

/// Every command a key can start. The menu bar, the right-click menus, the key monitor and the
/// shortcut sheet all read this one table, so they cannot disagree.
enum AppAction: String, CaseIterable, Identifiable {
    case newProject, newDemo, save, saveAs, exportAudio
    case undo, redo, cut, copy, paste, duplicate, deleteSelection, deleteTime, splitAtPlayhead, deactivateClip, drawMode
    case record, toggleMetronome, play, pause, stopRewind, stopAllClips, loopSelection, loopToggle, backToArrangement, captureSession
    case insertAudioTrack, insertMIDITrack, insertReturnTrack, insertGroupTrack, groupTracks, ungroup, renameTrack, duplicateTrack
    case insertScene, deleteScene, duplicateScene
    case toggleKeyboardMIDI, midiLearn
    case moveUp, moveDown, moveLeft, moveRight, extendUp, extendDown, extendLeft, extendRight, launchSelected
    case noteOctaveUp, noteOctaveDown, noteLonger, noteShorter, noteOtherGridLeft, noteOtherGridRight, snapNotes, selectAll
    case gridNarrower, gridWider, gridTriplet, gridFixed
    case sessionView, arrangementView, switchView, toggleDetail, toggleAutomation, automationEditMode, showShortcuts

    var id: String { rawValue }

    enum Category: String, CaseIterable { case file = "File", edit = "Edit", transport = "Transport", track = "Track", scene = "Scene", navigate = "Navigate", view = "View" }

    var category: Category {
        switch self {
        case .newProject, .newDemo, .save, .saveAs, .exportAudio: .file
        case .undo, .redo, .cut, .copy, .paste, .duplicate, .deleteSelection, .deleteTime, .splitAtPlayhead, .deactivateClip, .drawMode: .edit
        case .record, .toggleMetronome, .play, .pause, .stopRewind, .stopAllClips, .loopSelection, .loopToggle, .backToArrangement, .captureSession: .transport
        case .insertAudioTrack, .insertMIDITrack, .insertReturnTrack, .insertGroupTrack, .groupTracks, .ungroup, .renameTrack, .duplicateTrack: .track
        case .insertScene, .deleteScene, .duplicateScene: .scene
        case .toggleKeyboardMIDI, .midiLearn: .transport
        case .moveUp, .moveDown, .moveLeft, .moveRight, .extendUp, .extendDown, .extendLeft, .extendRight, .launchSelected: .navigate
        case .noteOctaveUp, .noteOctaveDown, .noteLonger, .noteShorter, .noteOtherGridLeft, .noteOtherGridRight, .snapNotes, .selectAll: .edit
        case .gridNarrower, .gridWider, .gridTriplet, .gridFixed: .edit
        case .sessionView, .arrangementView, .switchView, .toggleDetail, .toggleAutomation, .automationEditMode, .showShortcuts: .view
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
        case .deleteSelection: "Delete (a marked range leaves a gap)"
        case .deleteTime: "Delete Time (the arrangement closes up)"
        case .splitAtPlayhead: "Split at Playhead or at the Marked Range"
        case .deactivateClip: "Activate / Deactivate Clip or Marked Notes"
        case .selectAll: "Select All (notes of the open clip, else the clips)"
        case .drawMode: "Draw Mode (Pen)"
        case .record: "Arm Recording"
        case .toggleMetronome: "Metronome On/Off"
        case .play: "Play / Stop"
        case .pause: "Pause / Continue"
        case .stopRewind: "Stop and Rewind"
        case .stopAllClips: "Stop All Clips"
        case .loopSelection: "Loop Selection"
        case .loopToggle: "Loop On/Off"
        case .backToArrangement: "Back to Arrangement"
        case .captureSession: "Capture Session into Arrangement"
        case .insertAudioTrack: "Insert Audio Track"
        case .insertMIDITrack: "Insert MIDI Track"
        case .insertReturnTrack: "Insert Return Track"
        case .insertGroupTrack: "Insert Group Track"
        case .groupTracks: "Group (selected tracks; marked devices into a Rack)"
        case .ungroup: "Ungroup Rack"
        case .renameTrack: "Rename Track"
        case .duplicateTrack: "Duplicate Track"
        case .insertScene: "Insert Scene"
        case .deleteScene: "Delete Scene"
        case .midiLearn: "MIDI Learn"
        case .duplicateScene: "Duplicate Scene"
        case .toggleKeyboardMIDI: "Computer Keyboard as MIDI Keys"
        case .moveUp: "Select Up (marked notes: a semitone up)"
        case .moveDown: "Select Down (marked notes: a semitone down)"
        case .moveLeft: "Select Left (marked notes: a step earlier; snap on: on the grid, off: a 1/128)"
        case .moveRight: "Select Right (marked notes: a step later; snap on: on the grid, off: a 1/128)"
        case .extendUp: "Extend the Marking Up (Session clips)"
        case .extendDown: "Extend the Marking Down (Session clips)"
        case .extendLeft: "Extend the Marking Left (Session clips)"
        case .extendRight: "Extend the Marking Right (Session clips)"
        case .noteOtherGridLeft: "Marked Notes Earlier on the Other Grid (snap off: the grid, on: a 1/128)"
        case .noteOtherGridRight: "Marked Notes Later on the Other Grid (snap off: the grid, on: a 1/128)"
        case .noteOctaveUp: "Marked Notes an Octave Up"
        case .noteOctaveDown: "Marked Notes an Octave Down"
        case .noteLonger: "Marked Notes a Grid Step Longer"
        case .noteShorter: "Marked Notes a Grid Step Shorter"
        case .snapNotes: "Snap to Grid"
        case .gridNarrower: "Narrower Grid"
        case .gridWider: "Wider Grid"
        case .gridTriplet: "Triplet Grid"
        case .gridFixed: "Fixed Grid"
        case .launchSelected: "Launch Selected Clip or Scene"
        case .sessionView: "Session View"
        case .arrangementView: "Arrangement View"
        case .switchView: "Switch Session / Arrangement"
        case .toggleDetail: "Show Clip and Device Panel"
        case .toggleAutomation: "Show / Hide Automation"
        case .automationEditMode: "Automation Mode (Edit Over the Clips)"
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
        case .deleteTime: KeyBinding("\u{7F}", [.command, .shift])
        case .splitAtPlayhead: KeyBinding("e", .command)
        case .deactivateClip: KeyBinding("0", [])
        case .drawMode: KeyBinding("b", [])
        case .record: KeyBinding("r", [])
        case .toggleMetronome: KeyBinding("k", [])
        case .play: KeyBinding(" ", [])
        case .pause: KeyBinding(" ", .shift)
        case .stopRewind: KeyBinding(".", .command)
        case .stopAllClips: KeyBinding(".", [.command, .shift])
        case .captureSession: KeyBinding("c", [.command, .shift])
        case .loopSelection: KeyBinding("l", .command)
        case .loopToggle: KeyBinding("l", [.command, .shift])
        case .insertAudioTrack: KeyBinding("t", .command)
        case .insertMIDITrack: KeyBinding("t", [.command, .shift])
        case .insertReturnTrack: KeyBinding("t", [.command, .option])
        case .groupTracks: KeyBinding("g", .command)
        case .ungroup: KeyBinding("g", [.command, .shift])
        case .renameTrack: KeyBinding("r", .command)
        case .insertScene: KeyBinding("i", [.command, .shift])
        case .toggleKeyboardMIDI: KeyBinding("m", [])
        case .midiLearn: KeyBinding("m", [.command, .shift])
        case .moveUp: KeyBinding("\u{F700}", [])
        case .moveDown: KeyBinding("\u{F701}", [])
        case .moveLeft: KeyBinding("\u{F702}", [])
        case .moveRight: KeyBinding("\u{F703}", [])
        case .extendUp: KeyBinding("\u{F700}", .shift)
        case .extendDown: KeyBinding("\u{F701}", .shift)
        case .extendLeft: KeyBinding("\u{F702}", .shift)
        case .extendRight: KeyBinding("\u{F703}", .shift)
        case .noteOctaveUp: KeyBinding("\u{F700}", .shift)
        case .noteOctaveDown: KeyBinding("\u{F701}", .shift)
        case .noteShorter: KeyBinding("\u{F702}", .shift)
        case .noteLonger: KeyBinding("\u{F703}", .shift)
        case .noteOtherGridLeft: KeyBinding("\u{F702}", .command)
        case .noteOtherGridRight: KeyBinding("\u{F703}", .command)
        case .snapNotes: KeyBinding("4", .command)
        // The grid keys as in Live: ⌘1 narrower, ⌘2 wider, ⌘3 triplets, ⌘4 snap, ⌘5 fixed.
        case .gridNarrower: KeyBinding("1", .command)
        case .gridWider: KeyBinding("2", .command)
        case .gridTriplet: KeyBinding("3", .command)
        case .gridFixed: KeyBinding("5", .command)
        case .selectAll: KeyBinding("a", .command)
        case .launchSelected: KeyBinding("\r", [])
        case .sessionView: KeyBinding("1", [.command, .option])
        case .arrangementView: KeyBinding("2", [.command, .option])
        case .switchView: KeyBinding("\t", [])
        case .toggleDetail: KeyBinding("d", [.command, .option])
        case .toggleAutomation: KeyBinding("a", [])
        case .automationEditMode: KeyBinding("a", .option)
        case .showShortcuts: KeyBinding("/", .command)
        default: nil
        }
    }
}

extension AppAction {
    /// True for the arrow keys: holding one moves on at the key repeat rate.
    var repeats: Bool {
        switch self {
        case .moveUp, .moveDown, .moveLeft, .moveRight, .extendUp, .extendDown, .extendLeft, .extendRight,
             .noteOctaveUp, .noteOctaveDown, .noteLonger, .noteShorter, .noteOtherGridLeft, .noteOtherGridRight: true
        default: false
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
        // A text edit stays enabled: with the cursor in a text field its key goes to the field, whatever
        // the selection on the screen is.
        let enabled = run != nil || textSelector != nil || model.isEnabled(self)
        let act = { if let run { run() } else if !self.forwardToText() { model.perform(self) } }
        if let b = binding {
            Button(label, action: act)
                .keyboardShortcut(b.key, modifiers: b.modifiers)
                .disabled(!enabled)
        } else {
            Button(label, action: act).disabled(!enabled)
        }
    }

    /// The field editor's own action for an edit that a text field also knows.
    private var textSelector: Selector? {
        switch self {
        case .cut: #selector(NSText.cut(_:))
        case .copy: #selector(NSText.copy(_:))
        case .paste: #selector(NSText.paste(_:))
        case .selectAll: #selector(NSText.selectAll(_:))
        case .deleteSelection: #selector(NSText.deleteBackward(_:))
        default: nil
        }
    }

    /// With the cursor in a text field, the edit goes to that field. Returns true when it did.
    private func forwardToText() -> Bool {
        guard let selector = textSelector, let window = NSApp.keyWindow, window.firstResponder is NSText else { return false }
        return NSApp.sendAction(selector, to: window.firstResponder, from: nil)
    }
}

@MainActor
final class KeyMonitor {
    /// One monitor for the app: the root view is rebuilt on a theme change, and a second monitor would act twice.
    private static var token: Any?
    private static var clickToken: Any?
    private static var flagsToken: Any?

    /// Piano layout on the home row, like Live: A W S E D F T G Y H U J K.
    private static let piano: [String: Int] = ["a": 0, "w": 1, "s": 2, "e": 3, "d": 4, "f": 5, "t": 6, "g": 7, "y": 8, "h": 9, "u": 10, "j": 11, "k": 12, "o": 13, "l": 14, "p": 15]
    private var held: [String: UInt8] = [:]

    func install(model: AppModel) {
        guard Self.token == nil else { return }
        // The key-up of a note never arrives when another app takes the keyboard: release everything then.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self, weak model] _ in
            guard let self, let model else { return }
            MainActor.assumeIsolated {
                for pitch in self.held.values { model.noteOff(pitch) }
                self.held.removeAll()
            }
        }
        // A click outside a text field ends the typing: the keys go back to the transport. Without this a
        // field (the assistant's prompt, the search) keeps the keyboard until another field takes it.
        Self.flagsToken = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak model] event in
            AppModel.heldModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.type == .leftMouseUp, AppModel.selectAllOnMouseUp {
                AppModel.selectAllOnMouseUp = false
                DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil) }
            }
            // A click ends the focus of a number segment, so the arrows go back to the app. A click on a
            // segment gives it the focus again when the click ends.
            if event.type == .leftMouseDown, let model, MainActor.assumeIsolated({ model.focusedSegment != nil }) {
                event.window?.makeFirstResponder(nil)
            }
            return event
        }
        Self.clickToken = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window, window.firstResponder is NSText,
                  let hit = window.contentView?.hitTest(event.locationInWindow) else { return event }
            var view: NSView? = hit
            while let v = view {
                if v is NSTextView || v is NSTextField { return event }
                view = v.superview
            }
            window.makeFirstResponder(nil)
            return event
        }
        Self.token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self, weak model] event in
            guard let self, let model else { return event }
            // Up and Down in the tempo field step the tempo: 1 BPM, with Shift 0.1 BPM. A text field would
            // only move the cursor with them.
            if event.type == .keyDown, model.tempoFieldFocused, event.keyCode == 126 || event.keyCode == 125,
               event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                let step = event.modifierFlags.contains(.shift) ? 0.1 : 1
                model.nudgeTempo(by: event.keyCode == 126 ? step : -step)
                return nil
            }
            // A focused number segment takes the arrows, the digits, Delete, Return and Escape; Space and
            // the other keys still work as shortcuts.
            if model.focusedSegment != nil, [123, 124, 125, 126, 51, 36, 76, 53].contains(event.keyCode)
                || (event.characters.map { !$0.isEmpty && $0.allSatisfy { "0123456789.,-".contains($0) } } ?? false)
                && event.modifierFlags.intersection([.command, .control]).isEmpty {
                return event
            }
            // In the tempo field only the keys of a number stay in the field. Every other key (Space, the
            // letters, Tab) works as it does outside, and a key with no shortcut is dropped, not typed.
            let tempoKeys = model.tempoFieldFocused && !Self.isNumberKey(event)
            // Typing in a text field keeps its keys. So do the Settings window, a plugin's editor and a sheet.
            if let window = NSApp.keyWindow {
                if window.firstResponder is NSText, !tempoKeys { return event }
                let id = window.identifier?.rawValue ?? ""
                if window.sheetParent != nil || window.attachedSheet != nil || id.contains("Settings") || id.hasPrefix("loopstudio.") { return event }
            }
            let typed = event.charactersIgnoringModifiers?.lowercased() ?? ""
            // Turning the keyboard off releases the notes it still holds.
            if !model.keyboardMIDI, !held.isEmpty {
                for pitch in held.values { model.noteOff(pitch) }
                held.removeAll()
            }
            // Escape leaves a mode that swallows clicks or keys: MIDI Learn first, then the draw mode.
            if event.type == .keyDown, event.keyCode == 53 {
                if model.midiLearn { model.toggleMIDILearn(); return nil }
                if model.macroMap != nil { model.endMacroMap(); return nil }
                if model.keyboardMIDI { model.perform(.toggleKeyboardMIDI); return nil }
                if model.drawMode { model.drawMode = false; model.status = "Draw mode off"; return nil }
            }
            // A key that sounds a note ends it on release, whatever modifier came down meanwhile: a note held
            // through a ⌘ press must not stick.
            if event.type == .keyUp, let pitch = held.removeValue(forKey: typed) {
                model.noteOff(pitch)
                return nil
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
            guard event.type == .keyDown else { return event }
            // A held arrow key repeats, so it moves fast through the grid. Other shortcuts act once per press.
            // The arrow keys go through the monitor with every modifier: a menu shortcut never repeats.
            for action in AppAction.allCases where !event.isARepeat || action.repeats {
                if let b = action.binding, b.isPlain || action.repeats, b.matches(event), model.isEnabled(action) {
                    model.perform(action)
                    return nil
                }
            }
            return tempoKeys ? nil : event
        }
    }

    /// The keys a typed number needs: digits, the decimal point or comma, Delete, the left and right arrows,
    /// Return, Enter and Escape. A key with Command, Option or Control is a menu shortcut (copy, paste) and
    /// stays with the field too.
    private static func isNumberKey(_ event: NSEvent) -> Bool {
        if !event.modifierFlags.intersection([.command, .option, .control]).isEmpty { return true }
        if [51, 117, 123, 124, 36, 76, 53].contains(event.keyCode) { return true }
        let typed = event.charactersIgnoringModifiers ?? ""
        return !typed.isEmpty && typed.allSatisfy { "0123456789.,".contains($0) }
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
