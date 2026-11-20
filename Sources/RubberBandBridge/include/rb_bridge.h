#ifndef RB_BRIDGE_H
#define RB_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/// The Rubber Band engine for one offline stretch.
typedef struct {
    /// 0: R2, the faster engine. 1: R3, the finer engine.
    int engine;
    /// Pitch as a frequency ratio: 2 is an octave up.
    double pitch;
    /// 1: keep the spectral envelope (formants) where it is when the pitch moves.
    int formantPreserved;
    /// R3 only: the formant scale. 0 lets the engine choose (1 / pitch when preserved).
    double formantScale;
    /// R2 only: 0 crisp, 1 mixed, 2 smooth transients.
    int transients;
    /// 1: the channels are analysed together, which keeps the stereo image.
    int channelsTogether;
} rb_settings;

/// Stretches `inFrames` frames of planar audio to exactly `outFrames` frames.
/// `keySource` and `keyOutput` hold `keyCount` pairs: a source frame and the output frame where it must sound.
/// Returns the number of frames written (`outFrames` on success), or -1 on a failure.
long rb_stretch_offline(const float *const *input, int channels, long inFrames, double sampleRate,
                        float *const *output, long outFrames,
                        const long *keySource, const long *keyOutput, int keyCount,
                        const rb_settings *settings);

#ifdef __cplusplus
}
#endif

#endif
