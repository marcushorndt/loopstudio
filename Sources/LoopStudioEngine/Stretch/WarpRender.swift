import Foundation
import LoopStudioCore

public extension TimeStretch {
    /// A clip's audio, stretched by its warp mode and settings to follow `mapping`.
    ///
    /// Re-Pitch reads the source at the mapped position, so pitch follows speed. Beats, Tones and Texture
    /// keep the pitch; Transpose renders them longer by the pitch ratio and resamples the result back to the
    /// mapped length. Complex and Complex Pro hand the whole job (map, pitch, formants) to Rubber Band; if
    /// that fails, Tones stands in.
    static func render(_ pcm: PCMBuffer, mode: WarpMode, settings: WarpSettings, mapping: WarpMapping) -> PCMBuffer {
        let curve = WarpCurve(mapping)
        let s = settings.clamped
        let pitch = s.pitchRatio
        switch mode {
        case .off:
            return pcm
        case .repitch:
            return Sinc.resample(pcm, outFrames: curve.outFrames) { curve.source($0) }
        case .complex, .complexPro:
            if let done = ComplexStretch.render(pcm, curve: curve, finer: mode == .complexPro, pitch: pitch, formants: s.formants) {
                return done
            }
            return pitched(pcm, curve: curve, pitch: pitch) { tones(pcm, $0, grainMs: s.tonesGrainMs) }
        case .beats:
            return pitched(pcm, curve: curve, pitch: pitch) { BeatsStretch.render(pcm, curve: $0, settings: s) }
        case .tones:
            return pitched(pcm, curve: curve, pitch: pitch) { tones(pcm, $0, grainMs: s.tonesGrainMs) }
        case .texture:
            return pitched(pcm, curve: curve, pitch: pitch) { TextureStretch.render(pcm, curve: $0, grainMs: s.textureGrainMs, flux: s.flux) }
        }
    }

    /// Runs `engine` over a curve `pitch` times as long, then reads its output `pitch` times as fast: the
    /// timing of `curve`, the pitch moved by the ratio.
    internal static func pitched(_ pcm: PCMBuffer, curve: WarpCurve, pitch: Double, engine: (WarpCurve) -> PCMBuffer) -> PCMBuffer {
        guard abs(pitch - 1) > 1e-6 else { return engine(curve) }
        let long = engine(curve.scaled(by: pitch))
        return Sinc.resample(long, outFrames: curve.outFrames) { $0 * pitch }
    }

    internal static func tones(_ pcm: PCMBuffer, _ curve: WarpCurve, grainMs: Double) -> PCMBuffer {
        let n = max(64, Int((grainMs / 1000 * pcm.sampleRate / 2).rounded()) * 2)
        return wsola(pcm, window: n, outFrames: curve.outFrames) { curve.source($0) }
    }
}
