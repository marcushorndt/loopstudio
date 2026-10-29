import LoopStudioCore
import SwiftUI

/// Settings that belong to the open project: how dropped samples play, their fades, and the follow-action dice.
struct ProjectSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var seedText = ""

    private var rule: AutoLoopRule { model.project.autoLoop }

    private func setRule(_ change: (inout AutoLoopRule) -> Void) {
        var r = rule
        change(&r)
        r.maxSeconds = max(r.maxSeconds, r.minSeconds)
        model.apply(.setAutoLoop(rule: r), key: "autoLoop")
    }

    var body: some View {
        Form {
            Section("Dropped samples") {
                Toggle("Loop by length", isOn: Binding(get: { rule.enabled }, set: { v in setRule { $0.enabled = v } }))
                LabeledContent("Loop when longer than") {
                    Stepper(String(format: "%.1f s", rule.minSeconds),
                            value: Binding(get: { rule.minSeconds }, set: { v in setRule { $0.minSeconds = max(0, v) } }),
                            in: 0...60, step: 0.5)
                }
                .disabled(!rule.enabled)
                LabeledContent("and not longer than") {
                    Stepper(String(format: "%.0f s", rule.maxSeconds),
                            value: Binding(get: { rule.maxSeconds }, set: { v in setRule { $0.maxSeconds = v } }),
                            in: 1...600, step: 1)
                }
                .disabled(!rule.enabled)
                Text("A sample inside these limits loops; shorter hits and longer recordings play once.")
                    .font(.caption).foregroundStyle(Theme.dim)
                LabeledContent("Fade at both ends") {
                    Stepper(String(format: "%.0f ms", model.project.defaultFadeMs),
                            value: Binding(get: { model.project.defaultFadeMs },
                                           set: { model.apply(.setDefaultFade(ms: min(1000, max(0, $0))), key: "defaultFade") }),
                            in: 0...1000, step: 1)
                }
                Text("Every new clip gets this fade, so a cut never clicks.").font(.caption).foregroundStyle(Theme.dim)
            }
            Section("Follow actions") {
                LabeledContent("Random seed") {
                    HStack {
                        TextField("", text: $seedText).frame(width: 110)
                            .onSubmit { if let v = UInt32(seedText) { model.apply(.setRandomSeed(seed: v)) } else { seedText = "\(model.project.randomSeed)" } }
                        Button("New") { model.apply(.setRandomSeed(seed: UInt32.random(in: 1...UInt32.max))) }
                    }
                }
                Text("The same seed gives the same chain of follow actions on every playback and bounce.")
                    .font(.caption).foregroundStyle(Theme.dim)
            }
        }
        .formStyle(.grouped)
        .onAppear { seedText = "\(model.project.randomSeed)" }
        .onChange(of: model.project.randomSeed) { seedText = "\(model.project.randomSeed)" }
    }
}
