import LoopStudioCore
import LoopStudioEngine
import SwiftUI

/// What a running take holds so far, for one track.
enum LiveTake {
    /// Peaks of the sound card input, one per captured buffer.
    case audio(peaks: [Float], secondsPerPeak: Double)
    /// Notes played so far, and how long the take is, in ticks from its start.
    case notes([MIDINote], length: Int64)
    /// The track records another track's sound; there is no live picture of it.
    case resampling
}

extension AppModel {
    func liveTake(of id: TrackID) -> LiveTake {
        if project.track(id)?.kind == .midi {
            let offset = recordFrameOffset, sr = sampleRate, map = project.tempoMap, start = recordStartTick.rawValue
            let notes = MIDIRecorder.notes(from: recorder.snapshot(), endFrame: engine.sessionFrame) { frame in
                max(0, map.tick(atFrame: Frame(frame + offset), sampleRate: sr).rawValue - start)
            }
            return .notes(notes, length: max(0, currentTick.rawValue - start))
        }
        guard let lane = recordLaneTracks.firstIndex(where: { $0.contains(id) }) else { return .resampling }
        return .audio(peaks: audioRecorder.livePeaks(lane: lane), secondsPerPeak: Double(audioRecorder.bufferFrames) / sampleRate)
    }
}

/// The inspector while a take records: where it goes, how long it is, and the sound or notes coming in.
struct RecordingPanel: View {
    @Environment(AppModel.self) private var model
    let track: Track

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15)) { _ in
            let slot = model.recordSlots[track.id]
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    Text("Recording").font(.system(size: 12, weight: .semibold))
                    Text(track.name).font(.system(size: 12)).foregroundStyle(Theme.dim)
                    Text(slot.map { "into slot \($0 + 1)" } ?? "into the arrangement").font(.system(size: 12)).foregroundStyle(Theme.dim)
                    Spacer()
                    Text(lengthText).font(.system(size: 12, design: .monospaced))
                    if let stop = model.recordStopTick {
                        Text("ends at bar \(barNumber(stop))").font(.system(size: 11)).foregroundStyle(.red)
                    } else if slot != nil {
                        Button("Stop at Next Bar") { model.stopSlotRecordingAtGrid(launch: true) }.controlSize(.small)
                    } else {
                        Button("Stop") { model.toggleRecordArm() }.controlSize(.small)
                    }
                }
                picture
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Color.red.opacity(0.5), lineWidth: 1))
            }
            .padding(10)
        }
    }

    /// Bars and beats since the take began, or the count-in.
    private var lengthText: String {
        if model.engine.isCountingIn { return "Count-in" }
        let ticks = max(0, model.currentTick.rawValue - model.recordStartTick.rawValue)
        let beat = Int64(Tick.perQuarter)
        let bar = max(1, model.barTicks)
        return "\(ticks / bar) bars \((ticks % bar) / beat) beats"
    }

    private func barNumber(_ sessionTick: Tick) -> Int64 { sessionTick.rawValue / max(1, model.barTicks) + 1 }

    @ViewBuilder private var picture: some View {
        switch model.liveTake(of: track.id) {
        case .audio(let peaks, _):
            Canvas { context, size in
                guard !peaks.isEmpty else { return }
                // The whole take fits the width; it gets denser as it grows.
                let columns = max(1, Int(size.width / 2))
                let per = max(1, Int((Double(peaks.count) / Double(columns)).rounded(.up)))
                let mid = size.height / 2
                var x: CGFloat = 0
                var i = 0
                while i < peaks.count {
                    let p = CGFloat(min(1, peaks[i..<min(peaks.count, i + per)].max() ?? 0))
                    let h = max(1, p * (size.height - 8))
                    context.fill(Path(CGRect(x: x, y: mid - h / 2, width: 1.5, height: h)), with: .color(.red.opacity(0.85)))
                    x += 2
                    i += per
                }
            }
        case .notes(let notes, let length):
            Canvas { context, size in
                guard length > 0 else { return }
                let low = Int(notes.map(\.pitch).min() ?? 48) - 2, high = Int(notes.map(\.pitch).max() ?? 72) + 2
                let rows = CGFloat(max(12, high - low + 1))
                let rowH = size.height / rows
                let scale = size.width / CGFloat(max(length, Int64(Tick.perQuarter) * 4))
                for note in notes {
                    let y = size.height - CGFloat(Int(note.pitch) - low + 1) * rowH
                    let rect = CGRect(x: CGFloat(note.tick.rawValue) * scale, y: y,
                                      width: max(2, CGFloat(note.length.rawValue) * scale), height: max(2, rowH - 1))
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.red.opacity(0.4 + Double(note.velocity) / 254)))
                }
            }
        case .resampling:
            Text("It records the sound of the track chosen under Audio From.").foregroundStyle(Theme.dim)
        }
    }
}
