import SwiftUI

/// Settings › Assistant: the key, the model, the effort, plan mode.
struct AssistantSettingsView: View {
    @Environment(AssistantModel.self) private var assistant
    @State private var key = ""

    var body: some View {
        @Bindable var assistant = assistant
        Form {
            Section("Claude API key") {
                SecureField("sk-ant-…", text: $key)
                    .onSubmit { assistant.apiKey = key }
                HStack {
                    Button("Save") { assistant.apiKey = key }.disabled(key == assistant.apiKey)
                    if assistant.hasKey {
                        Button("Remove") { key = ""; assistant.apiKey = "" }
                        Text("A key is stored.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No key stored.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("The key lives in the login Keychain of this Mac. The app never writes it to a file or a log. Get one at console.anthropic.com.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Model") {
                Picker("Model", selection: $assistant.modelID) {
                    ForEach(AssistantModel.models, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("Effort", selection: $assistant.effort) {
                    ForEach(AssistantModel.efforts, id: \.self) { Text($0).tag($0) }
                }
                Text("Medium is enough for most edits. Raise it for long, multi-step changes.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Changes") {
                Toggle("Ask before every change", isOn: $assistant.askBeforeChanges)
                Text("Off: edits apply at once and show as receipts; one turn is one undo step. Removals always ask.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { key = assistant.apiKey }
    }
}
