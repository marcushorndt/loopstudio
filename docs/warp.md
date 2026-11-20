# Warp: how an audio clip follows the tempo

An audio clip with warp on plays its file at the project tempo. The file's own tempo, or its warp
markers, say where every source frame belongs on the timeline; a stretch engine renders the file to
that map. The render runs offline on a worker and is cached per clip, so the audio thread only
plays a buffer.

## The pipeline

1. **The map.** `WarpMapping.make` (in `TimeStretch.swift`) builds, for every output frame, the
   source frame that sounds there, and the beat of the clip there. Without markers the source tempo
   gives a straight line; two or more markers give a polyline; a tempo ramp bends either. A looping
   clip over bars of changing tempo gets one map per pass (`RenderPlan.passStarts`).
2. **The curve.** `WarpCurve` samples the map every 64 output frames, so an engine can ask it
   millions of times. It also inverts it: the output frame of a transient, the output frame of a
   grid beat.
3. **The engine.** `TimeStretch.render(_:mode:settings:mapping:)` picks the engine by the clip's
   `WarpMode` and reads the clip's `WarpSettings`.
4. **The cache.** `RenderPlan.warpedAudio` keys the result by the file, the mode, only that mode's
   settings (`WarpSettings.key(for:)`), the source tempo, the markers, the tempo of the clip's
   bars and the sample rate. `AudioBank` keeps the renders; in the app a missing render goes to a
   worker and the clip's last render plays until the new one is ready.

## The modes

| Mode | Engine | Settings | Cost |
|---|---|---|---|
| Beats | `BeatsStretch`: cuts at the transients (`PCMBuffer.transients`) or on a note grid; every piece plays at its own speed from the output frame of its first source frame; pieces cross over 3 ms before an attack | Preserve, Gaps (loop off, forward, back and forth), Envelope | lowest |
| Tones | WSOLA (`TimeStretch.wsola`): grains aligned to the waveform | Grain | low |
| Texture | `TextureStretch`: Hann grains at four times overlap, a fixed-seed random spread | Grain, Flux | lowest |
| Re-Pitch | `Sinc.resample`: a windowed sinc read at the mapped position; the cutoff follows the speed | none | low |
| Complex | `ComplexStretch` with Rubber Band R2, the map as key frames | none | high |
| Complex Pro | `ComplexStretch` with Rubber Band R3 | Formants | highest |

Transpose and Detune (semitones and cents) work in every mode but Re-Pitch. Beats, Tones and Texture
render over a curve longer by the pitch ratio and resample the result back (`TimeStretch.pitched`);
Rubber Band moves the pitch itself, and Complex Pro keeps the formants as far as Formants says.

At a ratio of 1, Beats returns the input exactly: two pieces read the same frames under their
crossfade. The tests check this, the attack positions, the loop modes, the pitch of every mode, the
markers in Rubber Band, and that every render is deterministic.

Render speed on one Mac (two minutes of stereo at 48 kHz, `loopstudio tempo <file> --render 120`):
Beats about 4000 times real time, Texture 2000, Re-Pitch and Tones about 200, Complex 86, Complex
Pro 21.

## The tempo of a dropped file

`TempoDetect.estimate` runs during the import, on the worker:

1. A tempo in the file name ("96 BPM", "drums_128bpm", "BPM 174") wins.
2. A loop (by the project's auto-loop rule) that is not a single hit (`isOneShot`: under a second,
   or decayed by its end) gets the tempo at which it is a whole number of bars, chosen closest to the
   tempo its onsets show.
3. A longer file gets the tempo of its onsets: the spectral flux, its autocorrelation over 60 to
   200 BPM, then a phase-locked pulse over the whole file refines the period to 0.002 BPM. Below a
   confidence of 0.35 (speech, ambience, rubato) the file keeps no tempo and does not warp.

Tempos fold into 80 to 160 BPM. `Project.autoWarp` then turns warp on for a new clip with a tempo:
Beats for a loop, Complex for a longer file. The Warp column has Detect, Fit, ÷2 and ×2.

`loopstudio tempo <file>...` prints what the detection finds, without a project.

## Next on this foundation

- Warp markers on the sample editor for creative timing, and a first-beat marker from the detection.
- Scrub: a real-time stretch under the mouse.
- PaulStretch as an extreme stretch in the sample editor, to a new file.
