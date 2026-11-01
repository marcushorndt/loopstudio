import LoopStudioCore
import SwiftUI

/// The groove of a MIDI clip, in the Clip column: a template from the pool, how much of its timing and its
/// accents apply, and a button that burns it into the notes. Like Live's groove pool, the clip keeps its notes
/// straight while a groove is a setting; the engine moves them when it plays.
struct GrooveControls: View {
    @Environment(AppModel.self) private var model
    let clip: MIDIClip

    var body: some View {
        let current = clip.groove.flatMap { Groove.named($0.groove) }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Groove").frame(width: 52, alignment: .leading)
                Menu {
                    Button("Straight") { set(nil) }
                    ForEach(Groove.groups, id: \.self) { group in
                        Menu(group) {
                            ForEach(Groove.all.filter { $0.group == group }) { g in
                                Button(g.name) { set(GrooveSetting(groove: g.id, timing: clip.groove?.timing ?? 1, velocity: clip.groove?.velocity ?? 1)) }
                            }
                        }
                    }
                } label: {
                    Text(current?.name ?? "Straight").frame(maxWidth: .infinity, alignment: .leading)
                }
                .controlSize(.small)
                .hint("Groove: a timing and accent template the clip plays with. The notes stay straight in the editor; the faint marks show where they play.")
            }
            if let g = clip.groove {
                slider("Timing", value: g.timing * 100) { set(GrooveSetting(groove: g.groove, timing: $0 / 100, velocity: g.velocity), key: "grooveT\(clip.id)") }
                    .hint("How far the notes move: 100 % is the full template.")
                slider("Accents", value: g.velocity * 100) { set(GrooveSetting(groove: g.groove, timing: g.timing, velocity: $0 / 100), key: "grooveV\(clip.id)") }
                    .hint("How much the template changes the velocities.")
                Button("Commit to Notes") {
                    model.apply(.commitGroove(clip: clip.id))
                    model.selectedNotes = []
                }
                .controlSize(.small)
                .hint("Burns the groove into the notes: they move and take their accents, the setting goes back to Straight. Undo brings them back.")
            }
        }
    }

    private func set(_ groove: GrooveSetting?, key: String? = nil) {
        model.apply(.setClipGroove(clip: clip.id, groove: groove), key: key)
    }

    private func slider(_ label: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(label).frame(width: 52, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: 0...100).controlSize(.small)
            Text("\(Int(value.rounded())) %").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim).frame(width: 36, alignment: .trailing)
        }
    }
}
