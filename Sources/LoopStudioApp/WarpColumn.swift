import LoopStudioCore
import LoopStudioEngine
import SwiftUI

/// The Warp column of an audio clip: on or off, the mode, the tempo of the file, the mode's own settings,
/// and the pitch. Every change is one command, so it undoes and the assistant can make it too.
struct WarpColumn: View {
    @Environment(AppModel.self) private var model
    let clip: AudioClip

    var body: some View {
        let a = clip
        let asset = model.project.asset(a.asset)
        let w = a.warp
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Warp")
            HStack {
                Toggle("Warp", isOn: Binding(get: { a.warpMode != .off }, set: { on in
                    model.apply(.setClipWarp(clip: a.id, mode: on ? model.warpModeToTurnOn(a) : .off, markers: a.warpMarkers))
                }))
                if a.warpMode != .off {
                    Picker("", selection: Binding(get: { a.warpMode }, set: { model.apply(.setClipWarp(clip: a.id, mode: $0, markers: a.warpMarkers)) })) {
                        ForEach(WarpMode.stretching, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 124)
                }
            }
            if a.warpMode != .off {
                Text(Self.summary(a.warpMode)).font(.caption).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                sourceTempo(a, asset: asset)
                modeSettings(a, w)
                if a.warpMode.keepsPitch {
                    Divider()
                    HStack {
                        Text("Transpose").frame(width: 62, alignment: .leading)
                        Stepper("\(w.transpose > 0 ? "+" : "")\(w.transpose) st", value: Binding(get: { w.transpose }, set: { v in edit(a) { $0.transpose = v } }),
                                in: WarpSettings.ranges.transpose)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    row("Detune", value: w.detune, range: WarpSettings.ranges.detune, format: "%+.0f ct") { v in edit(a) { $0.detune = v.rounded() } }
                } else {
                    Text("The pitch follows the speed.").font(.caption).foregroundStyle(Theme.dim)
                }
            }
            Spacer()
        }
        .font(.system(size: 12))
    }

    static func summary(_ mode: WarpMode) -> String {
        switch mode {
        case .off: ""
        case .beats: "Cuts at the attacks and plays each piece at its own speed. For drums and percussive loops. The fastest."
        case .tones: "Grains that follow the waveform. For a voice, a bass or a lead line."
        case .texture: "Loose grains with a random spread. For pads, noise and ambience."
        case .repitch: "Speed and pitch change together, like tape or a turntable."
        case .complex: "A phase vocoder (Rubber Band R2). For full mixes and chords. Takes longer to render."
        case .complexPro: "The finer phase vocoder (Rubber Band R3), with formants. The best sound; the longest render."
        }
    }

    @ViewBuilder
    private func sourceTempo(_ a: AudioClip, asset: Asset?) -> some View {
        HStack(spacing: 4) {
            Text("Source").frame(width: 46, alignment: .leading)
            TextField("BPM", value: Binding(get: { asset?.sourceTempo ?? 0 }, set: { v in
                if let asset, v >= 20, v <= 400 { model.apply(.setAssetTempo(id: asset.id, bpm: v)) }
            }), format: .number.precision(.fractionLength(0...3)))
            .textFieldStyle(.roundedBorder).frame(width: 66)
            Button("÷2") { if let t = asset?.sourceTempo, let asset { model.apply(.setAssetTempo(id: asset.id, bpm: t / 2)) } }
            Button("×2") { if let t = asset?.sourceTempo, let asset { model.apply(.setAssetTempo(id: asset.id, bpm: t * 2)) } }
        }
        .controlSize(.small)
        HStack(spacing: 4) {
            Button("Detect") { model.detectTempo(of: a) }
                .hint("Find the tempo from the file name, the loop length or the beats")
            Button("Fit") { model.fitTempo(a) }
                .hint("Set the source tempo so this clip's audio fills the clip length once")
        }
        .controlSize(.small)
        if asset?.sourceTempo == nil, a.warpMarkers.count < 2 {
            Text("No tempo yet: Detect, or enter it.").font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func modeSettings(_ a: AudioClip, _ w: WarpSettings) -> some View {
        switch a.warpMode {
        case .beats:
            HStack {
                Text("Preserve").frame(width: 62, alignment: .leading)
                Picker("", selection: Binding(get: { w.preserve }, set: { v in edit(a) { $0.preserve = v } })) {
                    ForEach(WarpSettings.Preserve.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 120)
            }
            .hint("Where the audio is cut: at the attacks, or on a note grid of the file")
            HStack {
                Text("Gaps").frame(width: 62, alignment: .leading)
                Picker("", selection: Binding(get: { w.transientLoop }, set: { v in edit(a) { $0.transientLoop = v } })) {
                    ForEach(WarpSettings.TransientLoop.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 150)
            }
            .hint("At a slower tempo each piece is shorter than its place. This fills the rest")
            row("Envelope", value: w.transientEnvelope, range: WarpSettings.ranges.percent, format: "%.0f %%") { v in edit(a) { $0.transientEnvelope = v } }
                .hint("100 plays each piece to its end. Lower values fade every piece out sooner")
        case .tones:
            row("Grain", value: w.tonesGrainMs, range: WarpSettings.ranges.tonesGrainMs, format: "%.0f ms") { v in edit(a) { $0.tonesGrainMs = v } }
                .hint("Longer grains are smoother for low notes; shorter grains keep fast lines clear")
        case .texture:
            row("Grain", value: w.textureGrainMs, range: WarpSettings.ranges.textureGrainMs, format: "%.0f ms") { v in edit(a) { $0.textureGrainMs = v } }
            row("Flux", value: w.flux, range: WarpSettings.ranges.percent, format: "%.0f %%") { v in edit(a) { $0.flux = v } }
                .hint("How far the grains wander from their place")
        case .complexPro:
            row("Formants", value: w.formants, range: WarpSettings.ranges.percent, format: "%.0f %%") { v in edit(a) { $0.formants = v } }
                .hint("With Transpose: 100 keeps the character of a voice where it is, 0 moves it with the pitch")
        case .off, .repitch, .complex:
            EmptyView()
        }
    }

    private func edit(_ a: AudioClip, _ change: (inout WarpSettings) -> Void) {
        var w = a.warp
        change(&w)
        model.apply(.setClipWarpSettings(clip: a.id, settings: w), key: "warp\(a.id)")
    }

    private func row(_ label: String, value: Double, range: ClosedRange<Double>, format: String, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(label).frame(width: 62, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range).controlSize(.small)
            Text(String(format: format, value)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim).frame(width: 50, alignment: .trailing)
        }
    }
}

extension AppModel {
    /// The mode Warp On picks: the one a new clip of the file would get, else Beats.
    func warpModeToTurnOn(_ a: AudioClip) -> WarpMode {
        guard let asset = project.asset(a.asset) else { return .beats }
        let auto = project.autoWarp(for: asset)
        if auto != .off { return auto }
        return autoLoopSeconds(asset) ? .beats : .complex
    }

    private func autoLoopSeconds(_ asset: Asset) -> Bool {
        project.autoLoop.shouldLoop(seconds: Double(asset.frames) / max(1, asset.sampleRate))
    }

    /// Finds the file's tempo (name, loop length, beats) and sets it as the source tempo.
    func detectTempo(of a: AudioClip) {
        guard let asset = project.asset(a.asset), let pcm = bank.buffer(for: asset.id) else { return }
        let loop = autoLoopSeconds(asset)
        if let e = TempoDetect.estimate(pcm, name: asset.name, loop: loop) {
            apply(.setAssetTempo(id: asset.id, bpm: e.bpm))
            status = String(format: "%@: %.2f BPM, from the %@", asset.name, e.bpm,
                            e.method == .name ? "file name" : e.method == .loopLength ? "loop length" : "beats")
        } else if let heard = TempoDetect.onsetTempo(pcm), heard.confidence > 0.15 {
            apply(.setAssetTempo(id: asset.id, bpm: heard.bpm))
            status = String(format: "%@: perhaps %.2f BPM (the beat is not clear)", asset.name, heard.bpm)
        } else {
            status = "\(asset.name): no tempo found"
        }
    }

    /// Makes the whole sample span the clip length: sets the source tempo that does it.
    func fitTempo(_ a: AudioClip) {
        guard let asset = project.asset(a.asset), asset.sampleRate > 0 else { return }
        let seconds = Double(asset.frames) / asset.sampleRate
        let beats = Double(a.length.rawValue) / Double(Tick.perQuarter)
        guard seconds > 0, beats > 0 else { return }
        apply(.setAssetTempo(id: asset.id, bpm: min(400, max(20, beats * 60 / seconds))))
    }
}
