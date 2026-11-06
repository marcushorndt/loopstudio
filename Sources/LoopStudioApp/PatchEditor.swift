import AppKit
import LoopStudioCore
import SwiftUI

/// The card of a Patch device: its knobs from the `param` lines, or the error when the text does not compile.
/// The pen in the card's title row opens the editor.
struct PatchCardView: View {
    let track: Track
    let device: DeviceSlot
    let spec: EffectSpec

    var body: some View {
        if let error = device.patchError {
            VStack(alignment: .leading, spacing: 4) {
                Text("Does not compile").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.automationDot)
                Text(error.description).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim).lineLimit(4)
                Text("The sound passes through unchanged. Click the pen to edit.").font(.system(size: 10)).foregroundStyle(Theme.dim)
            }
            .frame(width: 200, alignment: .leading)
        } else if spec.params.isEmpty {
            Text("No knobs: add a param line. Click the pen to edit.").font(.system(size: 10)).foregroundStyle(Theme.dim).frame(width: 150)
        } else {
            KnobSection(title: spec.name) {
                ForEach(spec.shownParams, id: \.key) { ParamKnob(track: track, device: device, spec: spec, key: $0.key) }
            }
        }
    }
}

/// One editor window per patch device. Apply (⌘↩) compiles and, when the text is good, writes it into the
/// project as one undo step; the engine takes the new program at the next plan. A text that does not
/// compile shows its error and changes nothing. The window stays open while the song plays.
@MainActor
enum PatchEditorWindow {
    private static var windows: [DeviceID: NSWindow] = [:]

    static func show(model: AppModel, track: TrackID, device: DeviceID) {
        if let w = windows[device] { w.makeKeyAndOrderFront(nil); return }
        let name = model.project.track(track)?.device(device)?.name ?? "Patch"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(name) – Patch"
        // The key monitor leaves "loopstudio." windows alone: typing here must not play notes or delete clips.
        window.identifier = NSUserInterfaceItemIdentifier("loopstudio.patch")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 480, height: 320)
        let view = PatchEditorView(track: track, device: device, close: { windows[device]?.close() })
            .environment(model)
            .preferredColorScheme(model.isLightTheme ? .light : .dark)
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
        windows[device] = window
        window.makeKeyAndOrderFront(nil)
    }

    static func close(_ device: DeviceID) { windows[device]?.close(); windows[device] = nil }
}

struct PatchEditorView: View {
    @Environment(AppModel.self) private var model
    let track: TrackID
    let device: DeviceID
    let close: () -> Void
    @State private var text = ""
    @State private var loadedSource: String?
    @FocusState private var focused: Bool

    private var slot: DeviceSlot? { model.project.track(track)?.device(device) }
    private var compiled: Result<PatchProgram, PatchError> { PatchCompiler.cached(text) }
    private var dirty: Bool { text != (slot?.source ?? "") }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(slot?.name ?? "Patch").font(.system(size: 13, weight: .semibold))
                Spacer()
                Menu("Examples") {
                    ForEach(PatchExamples.all, id: \.name) { example in
                        Button(example.name) { text = example.source }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .hint("Replace the text with an example. Apply puts it on the device.")
                Button("Revert") { text = slot?.source ?? "" }.disabled(!dirty)
                    .hint("Back to the text the device has now.")
                Button("Apply") { apply() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!dirty || !compiles)
                    .hint("Compile and put the text on the device (⌘↩). One undo step.")
            }
            .padding(10)
            Divider()
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Theme.panel)
                .focused($focused)
                .autocorrectionDisabled()
            Divider()
            HStack(spacing: 8) {
                switch compiled {
                case .success(let program):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.play)
                    Text("\(program.name): \(program.spec.params.count) knob\(program.spec.params.count == 1 ? "" : "s"), \(program.ops.count) ops per sample")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim)
                case .failure(let error):
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.automationDot)
                    Text(error.description).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(2)
                }
                Spacer()
                if dirty { Text("Not applied").font(.system(size: 10)).foregroundStyle(Theme.dim) }
                Text("Reference: docs/scripting.md").font(.system(size: 10)).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .frame(minWidth: 480, minHeight: 320)
        .onAppear { load() }
        .onChange(of: slot?.source) { _, _ in load() }
    }

    private var compiles: Bool { if case .success = compiled { true } else { false } }

    /// The device's text, when it changed under the editor (an undo, the assistant) and the editor shows
    /// the old one unchanged. An edit in progress stays.
    private func load() {
        let source = slot?.source ?? ""
        if loadedSource == nil || text == loadedSource { text = source; focused = true }
        loadedSource = source
    }

    private func apply() {
        guard case .success(let program) = compiled, let slot else { return }
        let name = program.name == slot.name ? nil : program.name
        model.apply(.setDeviceSource(track: track, device: device, source: text, name: name))
        loadedSource = text
        model.status = "\(program.name) applied: \(program.spec.params.count) knobs"
    }
}
