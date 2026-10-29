import LoopStudioCore
import SwiftUI

/// Export Audio (⇧⌘R): what to render, then the file or folder dialog.
struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @State private var options = ExportOptions()

    var body: some View {
        let hasLoop = (model.project.loop.map { $0.end > $0.start }) ?? false
        let hasSelection = (model.rangeSelection.map { $0.end > $0.start }) ?? false
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Audio").font(.headline)
            Form {
                Picker("Range", selection: $options.range) {
                    Text("Whole arrangement").tag(ExportOptions.Range.whole)
                    Text(hasLoop ? "Loop brace" : "Loop brace (none set)").tag(ExportOptions.Range.loop)
                    Text(hasSelection ? "Time selection" : "Time selection (none)").tag(ExportOptions.Range.selection)
                }
                .pickerStyle(.radioGroup)
                Picker("Render", selection: $options.stems) {
                    Text("Master mix, one file").tag(false)
                    Text("All individual tracks, one file each (stems)").tag(true)
                }
                .pickerStyle(.radioGroup)
                Stepper("Tail: \(options.tailSeconds, specifier: "%.0f") s", value: $options.tailSeconds, in: 0...30, step: 1)
                Text(options.stems
                     ? "Each track after its fader, with its effects and automation; the returns with what was sent to them; the master mix. Aligned to the timeline, 24-bit WAV, into a folder you choose."
                     : "The master mix as you hear it, 24-bit WAV. An empty arrangement renders the Session performance instead.")
                    .font(.caption).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("Cancel") { model.exportSheetOpen = false }.keyboardShortcut(.cancelAction)
                Button("Export…") {
                    model.exportSheetOpen = false
                    model.runExport(options)
                }
                .keyboardShortcut(.defaultAction)
                .disabled((options.range == .loop && !hasLoop) || (options.range == .selection && !hasSelection))
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            options = model.exportOptions
            if options.range == .loop, !hasLoop { options.range = .whole }
            if options.range == .selection, !hasSelection { options.range = .whole }
        }
    }
}
