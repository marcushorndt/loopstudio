import LoopStudioControl
import LoopStudioCore
import SwiftUI

/// The Assistant tab of the browser: the transcript with receipt cards, the input, the status line.
struct AssistantPane: View {
    @Environment(AppModel.self) private var model
    @Environment(AssistantModel.self) private var assistant
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var assistant = assistant
        VStack(spacing: 0) {
            if !assistant.hasKey {
                noKey
            } else {
                transcript
                Divider()
                status
                inputField
            }
        }
    }

    private var noKey: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The assistant needs an API key for \(assistant.provider.name).").font(.system(size: 12)).foregroundStyle(Theme.text)
            Text("The key goes into the Keychain of this Mac. Open Settings › Assistant to enter it or to pick another provider.").font(.system(size: 11)).foregroundStyle(Theme.dim)
            SettingsLink { Text("Open Settings…") }.buttonStyle(.bordered).controlSize(.small)
            Spacer()
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if assistant.rows.isEmpty {
                        Text("Ask for an edit in the words of the screen: \"add a delay after the EQ on the bass\", \"make slot 2 of track 1 loop two bars\", \"pull the feedback of the delay down a bit\".")
                            .font(.system(size: 11)).foregroundStyle(Theme.dim).padding(.top, 4)
                        Text("Right-click a track, clip, note, device or knob and choose Send to Assistant: the request then refers to that thing.")
                            .font(.system(size: 11)).foregroundStyle(Theme.dim)
                    }
                    ForEach(assistant.rows) { row in
                        AssistantRowView(row: row).id(row.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .onChange(of: assistant.rows) { _, _ in withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }

    private var status: some View {
        HStack(spacing: 8) {
            Text("\(assistant.provider.name) · \(assistant.modelName)").font(.system(size: 10)).foregroundStyle(Theme.dim).lineLimit(1)
                .hint("The provider and the model. Change them in Settings › Assistant.")
            Toggle(isOn: Binding(get: { assistant.askBeforeChanges }, set: { assistant.askBeforeChanges = $0 })) {
                Text("Ask first").font(.system(size: 10))
            }
            .toggleStyle(.checkbox).controlSize(.mini).foregroundStyle(Theme.dim)
            .hint("Every change waits for Apply. Removals always wait.")
            Spacer()
            if assistant.cost > 0 {
                Text(String(format: "$%.3f", assistant.cost)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)
                    .hint("Estimated cost of this conversation: \(assistant.usage.input + assistant.usage.cacheRead) in, \(assistant.usage.output) out")
            }
            if assistant.lastTurnUndoable {
                Button { assistant.undoLastTurn() } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.plain).foregroundStyle(Theme.dim).hint("Undo the last turn (one undo step)")
            }
            Button { assistant.clear() } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(Theme.dim).disabled(assistant.running).hint("New conversation")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var inputField: some View {
        @Bindable var assistant = assistant
        return VStack(spacing: 4) {
            if let a = assistant.attachment {
                HStack(spacing: 6) {
                    Image(systemName: "paperclip").font(.system(size: 10))
                    Text(a.label).font(.system(size: 11)).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { assistant.attachment = nil } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                        .buttonStyle(.plain).hint("Drop the attachment")
                }
                .foregroundStyle(Theme.dim).padding(.horizontal, 4)
                .hint("Sent here by right-click. The next request refers to it.")
            }
            HStack(alignment: .bottom, spacing: 6) {
            TextField(assistant.attachment == nil ? "Ask the assistant…" : "What should happen with it?", text: $assistant.input, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...6).font(.system(size: 12))
                .padding(6).background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
                .focused($focused)
                .onSubmit { assistant.send() }
                .onChange(of: assistant.focusRequest) { _, _ in focused = true }
                .onAppear { if assistant.attachment != nil { focused = true } }
            if assistant.running {
                Button { assistant.stop() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.plain).foregroundStyle(Theme.automationDot).frame(width: 22, height: 26).hint("Stop the turn")
            } else {
                Button { assistant.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 18)) }
                    .buttonStyle(.plain).foregroundStyle(assistant.input.isEmpty ? Theme.dim : Theme.accent)
                    .frame(width: 22, height: 26).disabled(assistant.input.isEmpty).hint("Send (Return)")
            }
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 10)
    }
}

private struct AssistantRowView: View {
    @Environment(AssistantModel.self) private var assistant
    let row: AssistantModel.Row

    var body: some View {
        switch row {
        case .user(_, let text, let attachment):
            VStack(alignment: .leading, spacing: 4) {
                if let attachment {
                    Label(attachment, systemImage: "paperclip").font(.system(size: 10)).foregroundStyle(Theme.dim).lineLimit(1)
                }
                Text(text).font(.system(size: 12)).foregroundStyle(Theme.text).textSelection(.enabled)
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
        case .assistant(_, let text):
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .progress(_, let text):
            Text(text).font(.system(size: 10)).italic().foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .notice(_, let text):
            Label(text, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(let id, let name, let input, let state):
            ToolCard(id: id, name: name, input: input, state: state)
        }
    }
}

/// A tool call. Running: a spinner. Done with a receipt: the read-back lines, the proof of the change.
/// Pending: Apply and Skip. The model's prose never changes what a card shows.
private struct ToolCard: View {
    @Environment(AssistantModel.self) private var assistant
    let id: String
    let name: String
    let input: JSONValue
    let state: AssistantModel.ToolState

    private var bar: Color {
        switch state {
        case .running: Theme.dim
        case .pending: Theme.accent
        case .done(_, let isError, let receipt): isError ? Theme.automationDot : (receipt != nil ? Theme.play : Theme.line)
        case .skipped: Theme.line
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1).fill(bar).frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.dim)
                    Text(AssistantModel.inputLabel(input)).font(.system(size: 10)).foregroundStyle(Theme.dim).lineLimit(1)
                    Spacer(minLength: 0)
                    if case .running = state { ProgressView().controlSize(.mini) }
                }
                switch state {
                case .running:
                    EmptyView()
                case .pending(let destructive):
                    HStack(spacing: 6) {
                        Text(destructive ? "Removes something. Apply?" : "Apply this change?").font(.system(size: 11)).foregroundStyle(Theme.text)
                        Spacer()
                        Button("Skip") { assistant.decide(id, apply: false) }.controlSize(.mini)
                        Button("Apply") { assistant.decide(id, apply: true) }.controlSize(.mini).buttonStyle(.borderedProminent)
                    }
                case .done(let summary, let isError, let receipt):
                    ForEach(Array(summary.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11)).foregroundStyle(isError ? Theme.automationDot : Theme.text).textSelection(.enabled)
                    }
                    if let receipt {
                        Text("rev \(receipt.revisionBefore) to \(receipt.revisionAfter)").font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.dim)
                    }
                case .skipped:
                    Text("Skipped.").font(.system(size: 11)).foregroundStyle(Theme.dim)
                }
            }
            .padding(.leading, 8)
        }
        .padding(.vertical, 2)
    }
}
