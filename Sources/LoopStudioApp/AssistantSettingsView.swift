import LoopStudioControl
import SwiftUI

/// Settings › Assistant: the provider, its key and model, the effort, plan mode.
struct AssistantSettingsView: View {
    @Environment(AssistantModel.self) private var assistant
    @State private var key = ""
    @State private var customModel = ""
    @FocusState private var keyFocused: Bool

    private var provider: ModelProvider { assistant.provider }
    private var knownModel: Bool { provider.models.contains { $0.id == assistant.modelID } }

    var body: some View {
        @Bindable var assistant = assistant
        Form {
            Section("Provider") {
                Picker("Provider", selection: $assistant.provider) {
                    ForEach(ModelProvider.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Each provider keeps its own key and model. A change starts a new conversation with the model; the rows stay.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("\(provider.name) API key") {
                // In a grouped form the first string of a field is its label, drawn to the left, and the field
                // itself has no border until it has focus. A hidden label and a bordered field keep it visible.
                SecureField("API key", text: $key, prompt: Text(provider.keyHint))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($keyFocused)
                    .onSubmit { assistant.setKey(key, for: provider) }
                HStack {
                    Button("Save") { assistant.setKey(key, for: provider) }.disabled(key == assistant.key(for: provider))
                    if assistant.hasKey {
                        Button("Remove") { key = ""; assistant.setKey("", for: provider) }
                        Text("A key is stored.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No key stored.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("The key lives in the login Keychain of this Mac. The app never writes it to a file or a log.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Model") {
                Picker("Model", selection: Binding(
                    get: { knownModel ? assistant.modelID : "custom" },
                    set: { if $0 != "custom" { assistant.modelID = $0; customModel = "" } else { customModel = assistant.modelID } }
                )) {
                    ForEach(provider.models, id: \.id) { Text($0.name).tag($0.id) }
                    Text("Other…").tag("custom")
                }
                if !knownModel || !customModel.isEmpty {
                    TextField("Model id", text: $customModel, prompt: Text("Model id, as the provider names it"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onSubmit { if !customModel.isEmpty { assistant.modelID = customModel } }
                    Text("Type the model id as the provider names it, then press Return.").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Effort", selection: $assistant.effort) {
                    ForEach(AssistantModel.efforts, id: \.self) { Text($0).tag($0) }
                }
                Text(provider == .openai
                     ? "OpenAI: the effort maps to reasoning_effort on reasoning models (xhigh and max become high); other models ignore it."
                     : "Medium is enough for most edits. Raise it for long, multi-step changes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Changes") {
                Toggle("Ask before every change", isOn: $assistant.askBeforeChanges)
                Text("Off: edits apply at once and show as receipts; one turn is one undo step. Removals always ask.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            key = assistant.key(for: provider); customModel = knownModel ? "" : assistant.modelID
            // The tab opens to enter a key: the cursor waits in the field.
            if key.isEmpty { keyFocused = true }
        }
        .onChange(of: assistant.provider) { _, p in
            key = assistant.key(for: p); customModel = knownModel ? "" : assistant.modelID
            if key.isEmpty { keyFocused = true }
        }
    }
}
