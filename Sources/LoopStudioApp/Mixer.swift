import LoopStudioCore
import SwiftUI

/// dB to meter position: -60 dB at the bottom, +6 dB at the top.
func meterPosition(linear: Float) -> Double {
    guard linear > 0.000_001 else { return 0 }
    return min(1, max(0, (20 * log10(Double(linear)) + 60) / 66))
}

struct LevelBar: View {
    let level: Float
    var horizontal = false

    var body: some View {
        GeometryReader { geo in
            let p = meterPosition(linear: level)
            ZStack(alignment: horizontal ? .leading : .bottom) {
                Rectangle().fill(Color.black.opacity(0.5))
                Rectangle()
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: horizontal ? .leading : .bottom,
                                         endPoint: horizontal ? .trailing : .top))
                    .frame(width: horizontal ? geo.size.width * p : nil, height: horizontal ? nil : geo.size.height * p)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

/// Vertical fader. The scale puts 0 dB at 71 % of the travel and +6 dB at the top.
struct Fader: View {
    let db: Double
    let onChange: (Double) -> Void

    static func position(db: Double) -> Double { min(1, max(0, (pow(10, db / 20) / 2).squareRoot())) }
    static func db(position p: Double) -> Double { p <= 0.003 ? -96 : 20 * log10(p * p * 2) }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let y = h * (1 - Self.position(db: db))
            ZStack(alignment: .top) {
                Capsule().fill(Color.black.opacity(0.6)).frame(width: 4).frame(maxWidth: .infinity)
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.6)], startPoint: .top, endPoint: .bottom))
                    .overlay(Rectangle().fill(.black.opacity(0.7)).frame(height: 1))
                    .frame(width: 26, height: 14)
                    .offset(y: min(max(0, y - 7), h - 14))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                onChange(Self.db(position: 1 - min(max(0, g.location.y / h), 1)))
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { onChange(0) })
        }
    }
}

/// A mixer strip: pan, fader with meter, and the mute and solo buttons.
struct MixerStrip: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let isMaster: Bool
    let width: CGFloat

    var body: some View {
        VStack(spacing: 5) {
            Slider(value: Binding(get: { track.pan }, set: { model.apply(.setPan(id: track.id, pan: $0), key: "pan\(track.id)") }), in: -1...1)
                .controlSize(.mini)
                .contextMenu { Button("Center") { model.apply(.setPan(id: track.id, pan: 0)) } }
                .help("Pan")

            if !isMaster && track.kind != .returnTrack {
                ForEach(model.project.tracks.filter { $0.kind == .returnTrack }, id: \.id) { ret in
                    HStack(spacing: 4) {
                        Text(String(ret.name.prefix(1))).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.track(ret.colorIndex))
                        Slider(value: Binding(
                            get: { (model.sendLevel(track, to: ret.id) + 48) / 48 },
                            set: { model.setSend(from: track, to: ret.id, db: $0 <= 0.01 ? -96 : -48 + 48 * $0) }), in: 0...1)
                            .controlSize(.mini)
                    }
                    .help("Send to \(ret.name)")
                }
            }

            HStack(spacing: 6) {
                Fader(db: track.volumeDb) { model.apply(.setVolume(id: track.id, db: $0), key: "vol\(track.id)") }
                    .frame(width: 44, height: 100)
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                    LevelBar(level: model.meterLevel(track: isMaster ? nil : track.id)).frame(width: 9, height: 100)
                }
            }

            Text(track.volumeDb <= -90 ? "-inf" : String(format: "%.1f dB", track.volumeDb))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)

            if !isMaster {
                HStack(spacing: 4) {
                    toggle("S", on: track.solo, tint: Color(red: 0.4, green: 0.65, blue: 1)) {
                        model.apply(.setSolo(id: track.id, solo: !track.solo))
                    }
                    toggle("M", on: !track.mute, tint: Theme.accent, invert: true) {
                        model.apply(.setMute(id: track.id, mute: !track.mute))
                    }
                }
            }
        }
        .padding(6)
        .frame(width: width)
        .background(model.selectedTrack == track.id ? Theme.panelRaised : Theme.panel, in: RoundedRectangle(cornerRadius: 4))
        .onTapGesture { model.selectedTrack = track.id }
        .dropDestination(for: String.self) { items, _ in drop(items) }
    }

    private func drop(_ items: [String]) -> Bool {
        return model.dropDevices(items, on: track.id)
    }

    /// For mute, the lit state means "audible", as in Live (the activator).
    private func toggle(_ label: String, on: Bool, tint: Color, invert: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 11, weight: .bold)).frame(width: 34, height: 22)
                .foregroundStyle(on ? .black : Theme.dim)
                .background(on ? tint : Theme.panelRaised, in: RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
    }
}
