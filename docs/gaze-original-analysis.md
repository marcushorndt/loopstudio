# Stitches Gaze: analysis for a reimplementation

Files: the original scripts are in `docs/gaze-original/` (script5.js is the app). Line numbers below refer to script5.js. The section markers sit at these lines: dsp-core 3, dsp-amp 540, dsp-drums 1276, dsp-fx 2137, dsp-guitar 3042, dsp 3765, tapes 3886, play 4123, audiofile 5757, reg 5910, gear 5981, pix 6061, draw 6209, audio 6524, gear/amp 6792, gear/bow 7122, gear/drums 7282, gear/fx 7682, gear/guitar 7738, gear/lodestone 9045, gear/out 9191, gear/pedal 9315, gear/tape 9526, playsheet 9883, composer 10937, presets 11295, desk 11539, ui 12006.

script0.js is empty. script1.js is the host's frame preamble (claude.ai artifact plumbing), not part of the app.

## 0. Before you plan: "GEAR FIT" is not in the code

None of the scripts contain the strings "GEAR FIT", "SONG + GEAR" or any gear-scoring logic. I grepped for "fit" in every form. It only appears in four places:
- `fit` in play.js `nameOf()` (line ~4568): the quality score of a chord, `QUAL[rot(mask, root)]`.
- `VIEW.fit()`: zooms the camera to show all gear (F key, the fit button `#bFit`).
- `fits()` in the free-spot placer for new gear.
- comments.

So "SONG + GEAR FIT ?" is probably text in the HTML page, which was not supplied, or it is your own label. The nearest real features are: (a) the song is voiced to fit every guitar's tuning (`Play.voice`); (b) AUTO key takes the key from the lead guitar's tuning; (c) the amp-to-guitar air feedback depends on distance on the floor. Section 5 covers these.

## 1. What the app is, from the user's side

It is "STITCHES / GAZE", tagline "notes that ring and pile up, patched however you like". It is a top-down pixel-art rehearsal room. Gear lies on a wooden floor with a rug: guitars, a bass, amps, pedals, cassette tape loops, a drum machine, magnetic string drivers (BOW), a spinning magnet disc (LODESTONE) and an OUT mixer. You patch everything with cables in any order. Loops are allowed. Everything is synthesised live in AudioWorklets. There are no samples except the tapes, which are generated from code too.

Flow from load to sound:
1. `boot()` (line ~12868) loads the saved room from `localStorage['stitches-gaze.v1']`. With no save it loads PRESETS[0], "THE ROOM". It tidies the layout and fits the view.
2. The desk is drawn dark (`LAMP = 9` of 16 dither levels). A START button says the sound is off.
3. START (or the Space key) calls `Engine.start()`. It creates an `AudioContext({latencyHint:'interactive'})` at the device's default rate. It adds the gaze worklet module (source text built from the DSP functions) and the WASM device runtime. The button reads "warming the valves…" meanwhile. Then the lamp fades in (LAMP 6, 3, 0 at 80 ms steps). Every amp switches on. `Engine.sync(ST)` builds a unit per piece of gear and wires the cables.
4. PLAY (the top-bar chip `#bPlay`) starts the Transport. That is a 16th-note clock on the audio clock. Guitars strum their pattern, the bass plays, the drums play, and the song moves pads bar by bar.

The top bar holds: the room name (opens ROOMS, the presets), PLAY, the tempo (opens TRANSPORT with PLAY, TAP and a TEMPO slider from 40 to 200 BPM, default 90), SONG (opens the Composer), + GEAR, fit, HELP.

What the user can change:
- Drag gear around. Distance matters for amp feedback, and for BOW and LODESTONE placement over strings.
- Turn knobs: drag up or down, mouse wheel, double-tap to reset.
- Patch cables by dragging jack to jack, or by tapping two jacks. Drag a cable off an input to move or remove it.
- Tap a piece to open its "sheet", a bottom sheet with big sliders and that piece's own controls.
- The guitar and bass sheet is a full play surface (section 3).
- Load your own audio file onto a TAPE. File picker or drag and drop. WAV and AIFF are parsed by hand, MP3 is cut at 15 MB, other formats go to the browser decoder up to 24 MB. The file is kept in IndexedDB.
- Footswitches: tap for on and off, long press for HOLD or FREEZE.
- Keys: Esc closes, F fits, + and - zoom, Delete removes, and the play sheet has many keys (section 3).

The HELP text says: "Reverb before distortion, a pedal patched into itself, a tape that records its own echo: all fine. A loop with gain runs up into a loud, saturated tone and holds there; nothing past full scale ever reaches the speakers." Credits: "Clouds by Emilie Gillet (Mutable Instruments, MIT) and Cloud Seed by Ghost Note Audio (MIT). Monochrome, after the other Stitches."

## 2. The signal chain

### 2.1 Architecture

- Each gear piece is a unit: `{ins:{jack:[node,input]}, outs:{...}, m (meters), apply(g), dispose()}`.
- Native units run on one of five AudioWorklet processors: `gaze-tape`, `gaze-pedal`, `gaze-guitar`, `gaze-amp`, `gaze-drums`. Each has 1 stereo input and 1 stereo output.
- The compiled pedals GRAINS and HALL run on `md-device` (WASM).
- A cable is: out node → GainNode (fades 0 to 1 with time constant 8 ms, fades out over 6 ms on unplug) → `DelayNode(delayTime 0)` → in node. The zero delay lets Web Audio allow cycles, so every loop gets one 128-sample block of delay.
- `gazeWorklet` runs a "safe" stage on every unit output. NaN or Infinity becomes 0. Above 1, a soft knee: `1 + 0.5 * satf((x-1)/0.5)`, which tops out at 1.5. A runaway loop therefore saturates instead of exploding.
- Timed messages: any message with numeric `at` (in audio-context seconds) is queued. The processor splits its 128-sample block at that frame, so hits and plucks are sample-accurate.

### 2.2 GUITAR and BASS (dsp-guitar.js, `Guitar` class): a digital waveguide

Build constants:
- Guitar (an offset body, 2 wide single coils, a vibrato arm): 6 strings, scale 0.648 m. Neck pickup at 0.235 and bridge pickup at 0.075 of the scale from the bridge. Aperture 0.013.
- Guitar coils: neck L 3.0 H, R 7600 ohm; bridge L 2.6 H, R 7000 ohm. Coil capacitance 110 pF. Pots 1 Mohm. Tone cap 22 nF. Eddy loss 300 kohm. Cable 470 pF.
- Arm depth per string, in semitones at full travel: [1.0, 0.96, 0.92, 0.86, 0.8, 0.76].
- Standard tuning: [40, 45, 50, 55, 59, 64].
- Bass: 4 strings, scale 0.864, pickups [0.185, 0.185, 0.155, 0.155], L 4.6 H, R 10500 ohm, Cc 150 pF, pots 250 kohm, tone cap 47 nF. Standard [28, 33, 38, 43]. No arm.
- Each string can be tuned from 12 semitones below to 5 above standard. OCT drops everything another octave. The floor is MIDI 16. A lower note folds up an octave.
- Control block `CB = 32` samples. Pitch, filters and the bow update once per block.

Per string loop:
- A delay line, `pow2` of one period at MIDI 14.5 plus padding, as Float64.
- Read with a 4-point Lagrange interpolator at fractional delay D. D is the period, less the phase delay of the loss filter, less 2 × the all-pass phase delay.
- Fret changes crossfade two read heads over 4 ms (`XF_FRET`) with a smoothstep. A hammer-on keeps the energy.
- Tuning pegs, capo (0 to 7 frets) and OCT glide with time constant 0.06 s. The arm follows in about 15 ms.
- Loss filter: one-pole `lz = lb*v + la*lz`, designed per note in `lossDesign`:
  - Guitar: `T0 = 4*7.5^ring*(82.4/f0)^(f0<82.4?0.3:0.55)` seconds at the fundamental. `Th = (0.7+0.8*ring)*(f0/82.4)^(0.3 or 0.45)` at a high reference `fh = max(3000, 2.5*f0)`, or `max(900, 36*f0)` below E2.
  - Bass: `T0 = 5*8^ring*(41.2/f0)^...`, `Th = (0.3+0.3*ring)*...`.
  - The pole `a` is solved from the gain ratio at the two frequencies, clamped to 0 to 0.97. Gain `g = min(0.99995, G0*sqrt(1-2a cos w0+a^2)/(1-a))`, and `lb = g*(1-a)`.
- Stiffness: two first-order all-passes with coefficient `c = -min(0.95, max(0.3, 0.35+0.175*log2(330/f0)) + (bass?0.06:0))`.
- Level ceiling: `u *= CEIL/env` when the peak envelope exceeds 0.8. The envelope releases with a 0.08 s time constant. Steel against frets limits itself.
- Sympathetic bridge coupling: every string adds `u/NS` into a shared buffer. Each string then gets `u += 0.0009*(cpl[w-CB] - u)`, one control block late.
- Unison detune: strings sounding the same pitch spread ±1.5 cents (`DETUNE = 0.015` semitones), so pairs beat.
- Damping: a muted string (fret -1, quick MUTE for 0.2 s, or MUTE held) decays 60 dB in 40 ms, or 20 ms when held. A loop gain ramp applies it.

Excitation (the pluck):
- A one-period pulse. It is high for `beta*Pc` samples, where `beta = clamp(pos*Po/Pc, 0.03, 0.5)`, and low for the rest so there is no DC. Amplitude `A = 0.5*v`.
- It goes through a one-pole low-pass. Guitar cutoff `fc = (2000 + 9000 v²) × darkness`; bass `450 + 1800 v²`. Darkness is `f0/110` (or `f0/55` for bass), clamped 0.25 to 1.5, square-rooted above 1.
- Pick noise is added for 1.5 ms (level 0.02 v guitar, 0.004 v bass).
- During the pulse the existing wave is multiplied by 0.55. The pick stops part of what is ringing.
- A pick on a damped string is a "dead tick": noise and low-passed thud at `900+900v` Hz.
- Default pick position 0.18 of the scale (guitar), 0.22 (bass). The PICK knob maps to `0.05 + 0.4*ppos`.

Strum: strings go in order (dir 1 low to high, -1 high to low). Each string is delayed by `k*spread` with ±15% jitter. SPREAD maps to `0.002 + 0.06*spread²` seconds, default 0.4 gives about 11.6 ms. Per-string velocity is `v*(0.86+0.22*rnd)`. An upstroke plays the two lowest strings at 0.8×. Pick position jitters ±0.015.

Pickups:
- Each coil hears `u - y[w - tau]`, a comb from where it sits. The taps are fixed by the open-string period.
- Mix by the PICKUP switch (NECK, BOTH, BRIDGE) as `gN*u - gN*yN - gB*yB`. The bridge coil gets 1.35× gain.
- Aperture smoothing: a one-pole low-pass at `0.44*c/aperture` scaled by string pitch.
- Then the electrics. The coil, tone pot plus cap, volume pot, cable and the amp's 1 Mohm input are solved as a resonant low-pass by 6 fixed-point iterations. That yields frequency, Q (0.35 to 6) and DC gain, run as a TPT state-variable low-pass.
- Then the volume pot divider and a cable one-pole (treble loss when the volume is turned down).
- Both pots use the audio taper `(e^(3.47x)-1)/(e^3.47-1)`.
- Output gain is `0.36` (guitar) or `0.5` (bass) times LEVEL² × 1.6. A soft limit above 0.7 keeps it under 1.

Air input: the amp's sound comes back through `U.air` (the node's input). It is scaled by `airK = 0.012*AIR²` after `2*satf(x/2)` and added into every string loop. Each string answers at its own harmonics, which is how feedback works.

The guitar knobs (gear/guitar.js):
- CAPO, 8 steps.
- PICKUP, 3 steps, default 0.5 (BOTH).
- TONE 0.8, VOLUME 1, RING 0.7, AIR 0.5, LEVEL 0.8.
- GLIDE 0.25. This is an arm dip on every strum, with envelope points [0,0], [0.03,0.6], [0.08,1], [0.18,0.78], [0.3,0.45], [0.45,0.15], [0.6,0], scaled by depth.
- SPREAD 0.4.
- PICK 0.33.
- Flags: oct, follow (1), padstrum (1), lock.

The bass knobs: TONE 0.6, VOLUME 1, RING 0.7, AIR 0.3, LEVEL 0.8. Flags: oct, follow, pedal.

The arm spring-back after release: `v*exp(-u/0.05)*cos(2π·7·u)` for 0.35 s.

### 2.3 BOW (e-bow, gear/bow.js and `bowControl`)

On the desk the BOW is a small block dropped on one string. Its knob is DRIVE (default 0.6). Flags are pw (on) and harm (HARMONIC, the octave). About every 50 ms the desk sends each host `[{s, u, harm, lvl}]`, where `u` runs from 0 (mellow) to 1 (bright) along the body.

The DSP, per string:
- Bow distance from the bridge: `gam = 0.36 - 0.24u` of the scale, so `a = gam*Po/2` samples.
- Sense: `y[w-(P-a)] - y[w-a]`. That is the string's motion at the bow point, a quarter cycle ahead.
- Two TPT SVF band-passes at f0 and at 2f0, both with Q 3. HARM crossfades between them over 50 ms.
- Envelope follower with time constant `max(0.012, 1.5/f0)`.
- Push force: `F = -cd*bAs*(satf((bp+0.5bAs)/bAs) - satf(0.5))`, plus a little noise (4e-4). The offset makes it lopsided, which gives even harmonics like a horn.
- `cd = cMax*bA*max(0, 1 - bEnv*1.5708/bAt)`. Full push while below the target level, easing as it gets there. Target `bAt = 0.5*lvl*2*sn` with `sn = |sin(π k 2a/P)|`. `bAs = bAt*(1-0.5u)`.
- `cMax = clamp((rho/f0 + (1 - gk*dm))/(4 sn²), 0, 4)` with `rho = min(24, 0.3 f0)`. This makes the mode grow about 100 dB/s, and it cancels the loop loss at the driven mode.
- The force is written to a second buffer `fh`. It is injected through the same two taps (`fh[w-(P-a)] - fh[w-a]`), which lands it in phase.
- Attack: on over 30 ms, off over 80 ms. A string held by MUTE is not driven.

Result: the note swells in, holds forever, and still follows frets, the arm and plucks.

### 2.4 LODESTONE (spinning magnet disc)

Knobs: SPIN default 0.55. Rate is `spinRate = 1.5*60^k` turns per second (1.5 to 90; the knob shows RPM). HEIGHT default 0.3, shown as `0.6+24h` mm. Flag pw (motor).

The motor eases to its target: spin-up time constant 0.5 s, spin-down 1.4 s. Each frame the desk computes each string's weight from the disc's footprint: a Gaussian with σ ≈ 6.5 px across the strings and 6 px along. It also computes `near` to the pickup (σ 16 px) and the position p along the string. It sends `{id, rate, h, p, w[], near}` at 40 Hz.

DSP:
- `MAGNETS = 4` per disc. The phase advances at `rate*4*(1+wob)`, with a random wobble.
- Each magnet pass is a Gaussian bump (σ 0.045 of the cycle) with random amplitude `1±0.45`.
- The bump is high-passed (one-pole 0.002) and scaled by `pull(h) = (13.8/(mm+6))²` with `mm = 0.6+24h`.
- The bump history drives each string as a force at distance `tau = p*Po` from the bridge: `g*(h[w] - h[w-tau])`. Here `g = w_s * clamp((1-tau/Pc)*20, 0, 1) * min(3, Pc/200)`.
- Some bump also leaks straight into the pickup (`near*sqrt(amp)*0.006`).
- When the height is under 0.07 it touches the strings. Each magnet pass then sets a "buzz" rattle. That is noise into the strings (0.004) and high-passed noise into the pickup (0.12), decaying at 0.9965 per sample.

Slow spins wake low strings, fast spins high ones.

### 2.5 AMP (dsp-amp.js, `Amp`)

Chain:
1. Mono input (L+R average), clamped to ±4, times the model's `trim`.
2. Coupling high-pass at `hp` Hz.
3. Bright cap: adds `10^(bright*(1-G)²/20) - 1` of the treble above `brightF`.
4. Preamp hiss (`2.2e-4*hiss`) and 60 Hz heater hum (`1.2e-4*hum`) from a rotating phasor with a seeded phase.
5. Voicing biquads (`pre`).
6. Up ×4. That is two polyphase elliptic half-band stages: HA has 6 coefficients, transition 0.08; HB has 3 coefficients, transition 0.25. At 88.2 kHz and above it uses ×2.
7. Preamp stages s1, s2 and optionally s3, each:
   - A clipper `f(x) = x/sqrt(1+(k x)²)` with a separate k for each half wave (asymmetry).
   - Anti-aliased by the antiderivative mean: `(x+x1)/(F+F1)` on the same side of zero.
   - A bias b is added before the clipper and `f(b)` subtracted after.
   - Then a one-pole high-pass (coupling cap) and a one-pole low-pass (stray capacitance).
   - Drive is swept by GAIN: `d0*(d1/d0)^(G^cur)`.
8. Passive 3-knob tone stack (TMB) after stage 1 or after the last stage (`tsAt`).
   - Full third-order analog transfer function from 4 resistors and 3 caps, made digital by the bilinear transform at the oversampled rate.
   - Bass pot uses the log taper `(e^(3.4(x-1)) - 0.0334)/0.9666`.
   - Level compensation gives back 2/3 of the dB drop versus noon. Noon is measured as the geometric mean of |H| at 110, 500 and 2000 Hz.
   - Part sets:
     - scoop: 250k, 250k, 10k, 100k, 250p, 100n, 47n
     - bright: 1M, 1M, 25k, 56k, 56p, 22n, 22n
     - mids: 220k, 1M, 25k, 33k, 470p, 22n, 22n
     - low: 500k, 500k, 10k, 47k, 220p, 47n, 22n
     - flat: 500k, 250k, 10k, 22k, 220p, 22n, 47n
9. Power stage:
   - Coupling high-pass at 12 Hz, low-pass at `pw.lp`.
   - Drive `pw.d * MASTER^2.5`, scaled by `(0.6+0.4V)/V`, through the same clipper, times V.
   - Supply sag: a load follower with attack `atk` and release `rel`, plus a slow follower `slow`. `V = clamp(1 - sag*(fast - bloom*slow), 0.3, 1)`.
10. Back down to the base rate.
11. Output level `out`. Rectifier ripple `|sin| - 0.6366`, scaled `2.5e-4*rip*buzz*(0.1+0.9 MASTER)`. Output hiss `1e-3*fl`.
12. Cabinet: up to 8 biquads (peaks, shelves, low-pass, high-pass), not a convolution IR.
13. Model change fade: down over 6 ms, up over 20 ms.
14. Spring reverb send: `0.45*satf(2.2*y)` (its own saturating tube). KICK injects noise for a spring crash; it is triggered by dropping a carried amp, or by a KNOCK IT button.
15. Spring tank, run at half the sample rate:
    - An input chirp of 36 all-passes (coefficient 0.68) in K interleaved phases, `K = round(fs/8000)`.
    - Then 3 spring loops with round trips of 57.3, 66.1 and 75.7 ms.
    - Each loop: a chain of 12 stretched all-passes (coefficients 0.64, 0.67, 0.70), a loss low-pass at 3600 Hz, a high-pass at 90 Hz, gain `g` set from RT60 = 2.6 + 1.0·VERB seconds, and a random length wobble of ±0.08%.
    - Taps sit half a loop in.
    - Stereo mix: L = o0 + 0.7 o1 - 0.45 o2, R = o2 - 0.7 o1 + 0.45 o0, then a 4200 Hz low-pass.
    - Return level `VERB² × 1.6`. The tank resets and idles when VERB is 0.
16. A small room for width: 3 early taps per side, L at 5.3, 11.9, 17.7 ms with gains 0.11, -0.07, 0.05; R at 7.1, 13.6, 21.2 ms with gains 0.1, -0.08, 0.05.
17. Tremolo:
    - Rate `1.5*(11/1.5)^RATE` Hz, so 1.5 to 11.
    - The table is lopsided: the dip takes 42% of the cycle.
    - Depth shaping `1 - td*(s + (smoothstep(s) - s)*td)`.
18. Standby fade over 80 ms (smoothstep), DC block (0.0008), soft ceiling from 0.8 to 0.98.

Controls are smoothed with a 12 ms time constant. The tone stack moves at most a step per block with a 20 ms constant.

Amp knobs: MODEL (5 steps), GAIN, BASS, MID, TREBLE, REVERB, TREMOLO, RATE, MASTER, FEEDBACK. Flag `on` (STANDBY).

The five models:
- CLEAN. trim 1, hp 45, bright 4 dB at 2200. s1 d 0.6 (k 1.3/0.85, b 0.12). Stack scoop after s1. s2 d 0.4 to 16 (cur 2.2). pw d 13.5, sag 0.45, bloom 0.5. Cab: hp 75, +3 dB at 115, -2 at 900, +1.5 at 1900, -4 at 3400, -6 at 4400, lp 4800 and 5600. out 0.5. "glassy and scooped, huge headroom".
- CHIME. trim 0.7, high shelf +4 dB at 2200. s2 d 2 to 40. Stack bright. pw d 4.5, sag 0.25. Cab has +6 dB at 3000. out 0.36.
- STACK. Pre-peak +5 dB at 800. Three stages (s2 1.5 to 60, s3 1 to 3). Stack mids. pw d 2.7, sag 0.15. out 0.4. "thick mid crunch, a wall at high gain".
- DOOM. trim 0.5, low shelf +4 dB at 160. s2 2.5 to 40. Stack low. pw d 4, sag 0.6, bloom 0.55, slow 0.4. Cab hp 48, +6 dB at 72. out 0.3.
- BASS. Flat stack. pw d 30, sag 0.12. Cab hp 42 to lp 8500. out 0.42.

Starting settings per model when added (gain, bass, mid, treble, verb, master, fb):
- CLEAN: 0.45, 0.5, 0.45, 0.6, 0.35, 0.74, 0.35
- CHIME: 0.5, 0.45, 0.55, 0.55, 0.2, 0.61, 0.35
- STACK: 0.65, 0.55, 0.6, 0.5, 0.1, 0.53, 0.35
- DOOM: 0.65, 0.4, 0.5, 0.5, 0.15, 0.48, 0.4
- BASS: 0.35, 0.55, 0.5, 0.45, 0, 0.56, 0.25

Air feedback (gear/amp.js, `AIR`):
- Every amp that is on feeds the nearest string host within REACH = 260 desk px. The path runs from the grille point (60, 69 in amp body pixels) to the host's pickup.
- Gain is `12*FB²*fall(d)`. `fall` is `min(1, 40/d)`, with a cosine fade to 0 over the last 80 px.
- It is multiplied by `open(lv)`: a smoothstep from the strings' own meter level. It runs from FLOOR 0.01 when the strings are quiet (lv < 0.025) to 1 once lv > 0.1. So hiss alone does not start a howl.
- Filters: high-pass 30 Hz, then a 4th-order low-pass at 950 Hz.
- Delay: `128/sr + 0.3 ms + d/150 m / 343 m/s`. 150 px is one metre.
- A bass host gets 2.8× gain.
- Moving either piece bends the howl as the delay slides.

### 2.6 Pedals

Every pedal has three knobs a, b, c (0 to 1), an on/off footswitch with a 0.004-per-sample crossfade, and optional hold. Tail pedals (ECHO, VERB, RESO, REVERSE, SHIMMER) keep ringing after they are switched off. The lamp shows `val`.

Core ten, from dsp-core:

- **DRIVE** (GAIN 0.45, TONE 0.55, LEVEL 0.6). `g = 1+60k0²`. Formula: `satf(x*g+0.2) - satf(0.2)`, then a one-pole low-pass at `900*13^tone` Hz, then a DC block. Level is `(0.2+1.2k2)/(satf(0.4g)/0.4)`.
- **FUZZ** (FUZZ 0.7, TONE 0.4, OCTAVE 0).
  - `g = 8+400k0²`, then satf and a hard clip at ±0.72.
  - Low-pass at `500*16^tone`, DC block, output 0.62.
  - Octave: blends in `(|x| - avg|x|)*2.2`, full-wave rectified.
  - Input gate `min(1, env*80)`, attack 0.05, release 0.0008.
- **CRUSH** (BITS 0.55, RATE 0.35, MIX 1). Quantise `q = 2^(1+14(1-b)²)`. Sample hold `1+floor(rate²*40)`.
- **FILTER** (FREQ 0.45, RES 0.55, ENV 0.5). Simper SVF low-pass. `k = 2-1.93 res`. Cutoff `40*2^(8.6 freq + 5.5 env*min(1, 3 env_level))`. The envelope has attack 0.004 and release 0.00018. Output goes through satf.
- **TREM** (RATE 0.4, DEPTH 0.65, SHAPE 0.25). Rate `0.5*32^k` Hz. Shape squares the sine via `satf(sin*(1+14k))`.
- **VIBE** (RATE 0.3, DEPTH 0.45, MIX 0.5). A chorus: 6.5 ms base delay plus `5.2 ms × depth` modulation. Rate `0.08*100^k`. Right channel 90° off. MIX 1 gives vibrato.
- **ECHO** (TIME 0.5, REPEAT 0.45, MIX 0.35). Hold FREEZE.
  - Delay `0.04*30^k` s (40 ms to 1.2 s), gliding with coefficient 0.00009.
  - Wow 0.55 Hz ±0.22%. Right channel ×1.013.
  - Feedback `1.15*repeat` through a band-pass (low-pass 3200 Hz minus high-pass 160 Hz), then satf.
  - FREEZE recirculates the line and lets no input in.
- **VERB** (SIZE 0.72, TONE 0.45, MIX 0.35). Freeverb: 8 combs at 1116 to 1617 samples and 4 all-passes at 556, 441, 341, 225 (at 44.1 kHz, scaled to the rate). The right side gets +23 samples. Feedback `0.7+0.29 size`, damping `0.05+0.6(1-tone)`. FREEZE sets fb to 1, damping to 0, input to 0.
- **RING** (FREQ 0.3, SHAPE 0, MIX 0.5). Carrier `2*1000^k` Hz (2 Hz to 2 kHz), shaped sine.
- **RESO** (PITCH 0.33, DECAY 0.55, MIX 0.6). 15 band-pass biquads on a minor pentatonic [0,3,5,7,10] over 3 octaves from root `24+round(36k)`. `Q = 3*120^decay`. A slow AGC matches the output to the input level. Description: "turns noise into chords".

Eight Gaze pedals, from dsp-fx:

- **WALL** (SUSTAIN 0.7, TONE 0.45, LEVEL 0.5). The big fuzz.
  - Input high-pass at 45 Hz.
  - Oversampled ×4 at 44.1 or 48 kHz, so the clippers run near 190 kHz.
  - Stage 1: soft `x/sqrt(1+x²)` with bias 0.4, ADAA (antiderivative anti-aliasing).
  - Interstage band: high-pass 110 Hz, low-pass 3600 Hz.
  - Stage 2: hard clip with ADAA, then a 6 kHz low-pass.
  - Total gain `30+42 sustain` dB, split as g1 = 0.6·dB(G/2) and g2 = 1.6·dB(G/2).
  - Tone: a crossfade between a 330 Hz low-pass and the complement of a 1600 Hz low-pass (a scoop).
  - Gate: threshold `0.0012+0.004 sustain`, cubic, opens in 1 ms, closes in 80 ms.
  - Level compensation as written in the code.
- **REVERSE** (TIME 0.45, BLOOM 0.4, MIX 0.5). Reverse reverb.
  - The input is smeared by 3 all-passes per side (3.1, 5.3, 8.9 ms and 3.7, 6.1, 9.7 ms).
  - 48 taps spread over TIME (`0.15*10^k`, so 0.15 to 1.5 s). Tap gains rise as `exp(-3.8(1-x))` with random signs, then stop.
  - BLOOM feeds back `0.8*bloom^1.25` of the swell, crossed L/R, darkened.
  - 2 post all-passes. Equal-power mix.
- **SHIMMER** (DECAY 0.55, SHIMMER 0.45, MIX 0.4). Hold FREEZE.
  - An 8-line FDN with a Hadamard mix. Lines are 1.3× [37.3, 43.1, 51.7, 59.9, 68.3, 79.1, 89.9, 101.3] ms.
  - Each line wavers ±0.5 ms with a triangle LFO at 0.07 to 0.52 Hz.
  - RT `1.6*30^k` seconds (1.6 to 48).
  - Absorption makes the top decay faster.
  - Octave-up shifter in the feedback: 3 heads, 90 ms window, sine² windows, random restart jitter. Its feedback level is tied to the tank loss.
  - An AGC ceiling of 0.32 lets it sustain forever without growing.
  - FREEZE stops input and loss.
- **FREEZE** (LAYER 0.6, TONE 0.55, MIX 0.5). Hold CAPTURE (pulsed).
  - A spectral freeze. FFT size 4096 (8192 above 50 kHz), hop N/4, analysing the last 0.3 s.
  - Magnitude per bin is the geometric mean over windows with sound. The phase comes from the newest window.
  - Peak frequencies come from the phase advance between windows (phase vocoder). Each bin is assigned to its peak and rotates at that peak's frequency.
  - Resynthesis by overlap-add. The right channel gets a smooth phase twist across the spectrum for width.
  - Each press layers the new capture over the old pad, weighted by LAYER, and never past 0.3 rms.
  - Keeps listening while off. Tone is a low-pass at `500*36^k` Hz.
- **PITCH** (SHIFT 5/6, DETUNE 0.25, MIX 0.5). Shifts [-12, -7, -5, 5, 7, 12, 19] semitones. Two read heads on a 140 ms line. When a head runs out of room, a new one is placed by waveform correlation (coarse search at quarter rate, fine search at full rate, parabolic refinement), then a 10 ms crossfade. DETUNE wavers each side by up to 4.5 cents.
- **SWELL** (ATTACK 0.6, SENS 0.6, LEVEL 0.5). Auto-volume.
  - 4 ms look-ahead. Threshold `-30-36 sens` dB.
  - It also triggers on a top-end burst (a pick on a ringing string).
  - It dips over 2.5 ms, then fades in with sin² over `0.02*100^k` s (20 ms to 2 s).
- **FLANGE** (RATE 0.3, DEPTH 0.6, REGEN 0.45). Through-zero. Dry is fixed at 0.6 ms. Wet sweeps from -0.28 ms to +(0.4+6 depth) ms with a squared raised-cosine. Rate `0.04*150^k` Hz. Feedback `0.94*regen`, low-passed at 6 kHz. Right channel a quarter cycle behind.
- **SUSTAIN** (SUSTAIN 0.65, ATTACK 0.3, LEVEL 0.5). Feed-forward RMS compressor.
  - Threshold `-18-34k` dB. Ratio `3+17k`. 10 dB soft knee.
  - Attack `0.4*150^k` ms. Release 50 or 160 ms, adaptive.
  - Make-up so that -16 dBFS stays put. Then a 1.5 ms look-ahead peak limiter.

Two compiled (WASM) pedals:

- **GRAINS** = Mutable Instruments Clouds (script3.js). Native rate 32 kHz, block 32. Knobs: POSITION 0.3, SIZE 0.55, MIX 0.5, PITCH (49 steps, ±24 semitones, default 0), DENSITY 0.62, TEXTURE 0.6, MODE (GRAINS, STRETCH, LOOPING, SPECTRAL), SPACE 0.4. Hold FREEZE drives the freeze gate input. Device param order: position, size, pitch, density, texture, blend (fixed at 1), mode/3, reverb.
- **HALL** = Cloud Seed reverb (script4.js). Native rate 48 kHz, block 32. Knobs: SIZE 0.7, DECAY 0.65, MIX 0.45, DAMP 0.35, PREDELAY 0.15, MOD 0.45. HOLD sets decay to 1 and cuts the send, so the tail rings on.

For both, the app builds its own dry/wet around the device. Dry is `1-0.45 mix`. Wet is `mix × 1.1` (Grains) or `× 1.25` (Hall).

The md-device runtime (script2.js):
- Instantiates the WASM, which exports `dev_rate`, `dev_block`, `dev_params`, `dev_in`, `dev_out`, `dev_init`, `dev_render` and `dev_set_patched`. Up to 16 k-rate params named p0..p15.
- Resamples between the context rate and the device rate with 4-point Hermite interpolation. Pairs of 2nd-order Butterworth low-passes at 0.45 × the lower rate (24 dB/octave) guard against aliasing.
- Runs only while `active`.

### 2.7 TAPE (TapeLoop)

- A stereo loop buffer. 12 s for BLANK. A user file gets at most `TAPE_SEC = 24` s.
- Knobs:
  - SPEED 0.5: `2^((v-0.5)*3)`, so 0.35× to 2.8×. REV flag reverses.
  - LENGTH 1 and START 0: loop region, minimum 80 ms.
  - WOW 0.3: `wow²*1.6%` depth, about 0.45 Hz with its own modulation, plus a random drift.
  - FLUTTER 0.25: `flut²*0.45%` at 9.5 Hz plus a partial at 2.73×.
  - AGE 0.15: each pass flakes random patches of oxide into a 1024-bin wear map, and a general generation loss reaches up to 0.85.
  - FEEDBACK 0.8: sound on sound. The amount kept each pass.
  - HISS 0.2: high-passed noise × `hiss²*0.06`.
  - SATURATE 0.3: `satf(x*(1+5 sat))` normalised.
  - MOTOR 0.3: motor inertia, time constant `0.03 + motor²*2.4` s (0.35 s base when stopped).
  - LEVEL 0.8: `1.6*lvl²`.
- Flags: play, rec, rev.
- Reading: Catmull-Rom (cubic Hermite) interpolation. A 6 ms crossfade across the splice.
- High-frequency loss: cutoff `17500*(1-0.82*min(1, gen+0.9 wear)) - 4500 sat + 600` Hz, floor 500. A dropout gain `1-0.96*min(1, 1.25 wear)`.
- Crackle clicks on worn spots. Slowing the motor fades the level (smoothstep below speed 0.3).
- REC prints the IN jack onto the tape under the head as `satf(old*keep + in*0.85)`, filling every sample the head crosses at any speed and in either direction.
- Cassettes, all generated in code with fixed seeds:
  - PIANO (9.6 s, felt piano, 4 slow chords, additive partials)
  - CHOIR (8 s, ah to oo; 8 saws per chord into formant banks)
  - ORGAN (6 s, drawbar drone with rotary swirl)
  - RADIO (7.2 s, shortwave voices, dial whistle, beacon)
  - FIELD (10 s, wind, stream, birds)
  - BELLS (8 s, music box pentatonic)
  - BLANK
  - YOURS (the user's file, a 24 s window chosen by an offset)

### 2.8 DRUMS

Six voices (KICK, SNARE, HAT, OPEN, TOM, CRASH) on four kits (ROOM, BOX, BLOWN, DOOM).

- Skin voices (kick, snare, tom): up to 3 sine modes with ratios, levels and decay times. Pitch starts `bend×` higher and falls with time constant `bt`. Up to 2 noise bands through SVFs. Soft clip `sat`, optional gate. "hum" is per-hit variation. Envelopes ramp over 0.4 ms, so a retrigger never clicks.
- Metal voices: 8 square oscillators in 32-bit integer phase, summed (ring 0) or multiplied in pairs by XOR (ring 1), plus noise. A high-pass, then up to 3 bands each with its own decay and a slow L/R beating wobble, and a stick transient. HAT chokes OPEN.
- Each kit has its own room: 8-line Hadamard FDN with damping, multi-tap early reflections. DOOM has a gated long room opened by the snare and tom. BOX and BLOWN have a small grainy digital room.
- Bus: compressor [threshold, ratio, attack ms, release ms] per kit, drive, tone tilt, level, DC block, soft ceiling.
- Knobs: KIT, TONE 0.5, ROOM 0.4, DRIVE 0.25, LEVEL 0.8, SWING 0 (delays odd 16ths by `swing × 2/3` of a 16th), FILL EVERY (OFF, 4 BARS, 8 BARS).
- Patterns: 12 one-bar grids with `.` rest, `x` 0.8, `X` 1.0, `o` 0.45:
  - DRIVE 128, MOTORIK 136, PULSE 120, BREAK 92, WASH 112, HALF 140, STOMP 84, TIDE 104, SIX 92, POUND 90, DIRGE 64, CRAWL 50 BPM.
- Fills use shapes like 'SSSSTTTT'. The next bar opens with kick and crash.
- The ROOM kit plays up to 4 ms late, plus 1.5 ms extra on the snare, by hash.

### 2.9 OUT

- Four channel faders (default 0.8, gain `v²*1.25`), summed.
- `DynamicsCompressor` limiter: threshold -10 dB, knee 6, ratio 6, attack 3 ms, release 250 ms.
- MASTER (default 0.75, gain `v²*1.5`).
- Pre-gain 1/4, then a WaveShaper ceiling, then the destination. The ceiling is linear up to 0.9, with a tanh knee to 1.0.
- An analyser drives a VU needle (-30 to 0 dB) and a peak light.

## 3. Composer and play sheet: how music is generated

### 3.1 Transport and song

- `Transport.tick()` runs every 25 ms. It schedules 16th steps up to `LOOK = 0.25` s ahead on the audio clock. `six = 15/bpm`.
- Each step calls every gear `step(g, U, s, t, T)` with `T = {bpm, six, bar, beat, step, pad}`.
- The song (`ST.song`) is 8 bars. `prog[i]` is a pad index 0 to 7, or -1 for "stay". It loops forever, `bar % 8`.
- `key` is null (AUTO) or `{tonic, type}`. `chords` holds up to 8 `{root, q}`; chord i is pad i on every guitar that FOLLOWs.
- The PROG toggle `on` turns the song on or off. At step 0 of a bar that names a pad, following guitars go to that pad and the bass plays its note.

Tempo and evolution: the song is a fixed 8-bar loop that repeats. Nothing is generated over time except humanising and drone picks (below). The "evolution" in ambient rooms comes from the DSP: tape wear, feedback, reverb tails, bows and lodestones.

### 3.2 Tunings (play.js LIB)

Ten named tunings. Each has a home key, 8 hand-picked shapes and 2 progressions written as pad digits. Fret characters: 0-9, then a=10, b=11, c=12; x is muted.
- STANDARD 40 45 50 55 59 64, E MAJOR. Shapes: E, E5, F#m7add11, Aadd9, Bsus4, C#m7, G6, Cmaj7. Progressions 0354 and 0637.
- DROP D 38…, D MAJOR.
- DADGAD 38 45 50 55 57 62, D DORIAN. Progressions 1343, 0675.
- DADGAE, D MIXOLYDIAN.
- FACGCE 41 45 48 55 60 64, F MAJOR.
- OPEN D 38 45 50 54 57 62, D MIXOLYDIAN.
- OPEN C 36 43 48 55 60 64, C MIXOLYDIAN.
- UNISON D 38 38 50 50 62 62, D MINOR (octave shapes).
- BARITONE 35 40 45 50 54 59, B MINOR.
- DROP A 33 40 45 50 54 59, A DORIAN.

Bass tunings: STANDARD, DROP D, LOW B.

The preset helper `SONG(name, which, bars)` repeats each pad of a tuning's progression for `bars` bars (each pad, then `bars-1` stays) to fill 8 bars.

### 3.3 Harmony engine (play.js)

- Dissonance table `RUB[interval class][octaves apart]`. A minor second scores 1, a tritone 0.45, a major seventh 0.3, a whole tone 0.12. Low-interval limits `LIM` add `MUD` per semitone below them.
- Chord quality `QUAL` covers all 4096 interval sets. A fifth or a 3+7 shell gives a base. One third adds. Colour tones (9, 7, 6) add a little. Flat 9, both thirds, both sevenths, or 4 over a major third subtract. 5 notes cost -0.5, 6 notes cost -1.3.
- `makeKey`: scales LYDIAN, MAJOR, MIXOLYDIAN, DORIAN, MINOR, PHRYGIAN, LOCRIAN, MELODIC MINOR, HARMONIC MINOR. Its "core" is the five-note subset with the fewest semitones and tritones, a pentatonic.
- `analyse(notes)` finds a tuning's own key. Home is an open string, the lowest one doubled with its fifth and third. The scale should contain all the open strings.
- `shapeSet(notes)` builds 8 pads for a hand-made tuning:
  - It searches every two-finger shape.
  - It scores strings ringing, open strings, finger count, rub and clear chord names.
  - Pads: the open strings; five moves to scale notes that have a fifth, nearest home on the circle of fifths first; a COLOUR home chord; a HIGH home chord up the neck.
  - The 8 are chosen as a set so that any pad can follow any other (the clash measure).
- LET RING (`carry`): when the shape changes, a string keeps ringing its old note until it is next picked, if the old note rubs at most `RING_OK = 0.4` against the new notes. Otherwise it moves at once, like a hammer-on.
- `voice(chord, notes, {key})`:
  - The root is the lowest note. Fretted notes must be chord tones.
  - Open strings may add in-key notes that are not a semitone, major seventh or tritone from any chord tone. So IV becomes IVadd9 or IV6.
  - Limits: 3 fingers at most (2 preferred), 4 frets, 4 strings sounding (3 for a power chord). The defining note (the third, the 2 or 4 of a sus, the 7th) should be present.
  - Fallbacks loosen the limits.
- Chord qualities (QDEF): MAJ, MIN, 5, SUS2, SUS4, MAJ7, MIN7, DOM7, ADD9, MADD9, DIM.
- Borrowed chords per mode, for example MAJOR borrows bVII, bVI, bIII and iv.
- `next(chords, key)`: weighted move tables per mode (MOVE_LIB), plus all PROGS moves. Rules: the loop (repeat what followed last time), home rises after two bars away and at phrase ends, colour continuity, at most one borrowed chord. It returns numeral, name, a "why" label ("the lift", "wants home", "darker", and so on) and a weight.
- `suggest(key, {seed, mood, bars})`:
  - A seeded hash RNG (murmur-style `stir`).
  - Moods: BRIGHT, DARK, MODAL, DRONE.
  - Four-bar rhythms (RHY): 1 means a chord, 0 a stay.
    - BRIGHT: 1111 ×6, 1110 ×2, 1011 ×1, 1010 ×1.
    - DARK: 1111 ×3, 1010 ×3, 1110 ×2, 1011 ×2.
    - MODAL: 1010 ×4, others ×2.
  - Forms: AA, AA2 (new second half) and AB.
  - DRONE uses patterns `H-------`, `H---X---`, `H-X-H-X-`, `H-----X-`, `H---X-H-` (H home, X one other chord).
  - Picks among the best 5 candidates, weights squared, with a mood bias. 2 to 5 distinct chords (at most 2 for DRONE). It must end home, or on a chord that wants home.
  - It rejects copies of library progressions. It tries up to 24 attempts.
  - The Composer's seed is a hash of the room name plus the number of SUGGEST presses.
- Library PROGS: 31 progressions in moods BRIGHT, DARK, MODAL and DRONE. Examples: POP LOOP `I V vi IV…`, MINOR LOOP, LAMENT STEPS, DORIAN VAMP `i - IV -`, MIXO VAMP, LYDIAN LIFT, ONE CHORD `I - - - - - - -`, ONE MINOR, PEDAL `I - Isus4 - I - Isus2 -`, DARK PEDAL, HOME AND SUS, BARE FIFTHS `I5 - - - bVII5 - - -`, LONG PLAGAL.

### 3.4 Picking patterns (barEvents)

A pattern is one bar of 16 steps. Each row is `{step, kind strum|pluck, dir, strings, vel, spread, pos}`. `loose` is timing scatter in ms at HUMAN 1. `sway` is velocity scatter. `lazy` means LET RING.

Guitar patterns:
- OFF
- WHOLE (one strum, vel 0.9, spread 24 ms)
- HALF (steps 0 and 8)
- 8THS (down eighths, all strings on the beat, low4 off it)
- 16THS (down and up)
- TREMOLO (32 picks on the top two strings, pos 0.12)
- ARP (8 plucks walking up and down the sounding strings)
- RAKE (a slow rake with spread 0.7 steps, then an up-rake at step 10)
- DRONE: picks only strings whose meter level is below 0.25. The quietest first, 2 per bar, at steps 0, 7 and 12, vel 0.55, pos 0.24. Fresh frets go first. With no meter it rotates round the strings.

Bass patterns: WHOLE, PULSE (8ths), OFFBEAT, DRONE (every 2 bars).

Humanising: dt is a triangle-distributed hash of (seed, bar, pattern, row) × loose × human (default 0.5). Velocity ±sway. Spread ±20%. Deterministic per guitar id.

The bass: ROOT plays the lowest note of guitar 1's shape, an octave below when that note is not under B0. PEDAL holds the home note.

### 3.5 The play sheet (four pages)

- PLAY:
  - The NECK canvas: a lane per string, an open column and 12 frets. Press to fret and pick, drag along a lane to slide, drag across lanes to barre. LOCK snaps presses to the key. Hammer-ons and pull-offs work.
  - 8 PADS showing mini chord diagrams. Press to fret and strum, drag sideways to slide the shape up or down the neck (24 px per fret). A right-click menu offers KEEP.
  - STRINGS plate: tap a line to pick, swipe across to strum (speed sets loudness), lean sideways for the arm (12 px dead zone, 60 px to full travel).
  - MUTE (held) and TREM (held, or double-tap to latch; it repicks at 12 Hz or twice per 16th).
  - Caption row: tuning and key, HAND ‹ › (move the fretted strings down or up a fret), LOCK, KEEP.
- SONG: the shared 8-bar PROG, FOLLOW, the STRUM pattern (bass: PATTERN, ROOT or PEDAL), MATCH GUITAR 1, COMPOSE.
- TUNE: pegs, STRUM OPEN, OCTAVE DOWN, tuning chips, CAPO, SUGGEST PADS.
- SOUND: sliders. Under HAND: SPREAD, GLIDE, PICK. Also REMOVE and UNPLUG ALL.
- Keys: 1-8 pads, Z X C V B N strings, arrows strum and lean, 0 MUTE, T TREM, [ ] hand, L lock, K keep.
- Sets: each tuning keeps its own 8 pads (`g.sets[tkey]`). At most 24 sets are kept.

### 3.6 Composer window (the SONG chip)

From top to bottom:
- KEY: 12 notes, 6 scale types, AUTO.
- CHORDS: diatonic tiles plus borrowed tiles. A press auditions the chord on the lead guitar and writes it at the cursor.
- NEXT: 6 suggestions with "why" labels.
- COLOUR: the selected chord's variants.
- BARS: 8 cells, a cursor, PROG, PLAY/STOP, CLEAR, UNDO (one step), SUGGEST with a mood chip (ANY, BRIGHT, DARK, MODAL, DRONE).
- VOICINGS: each guitar's pad diagrams for each chord, marked approx when not exact, KEPT when the pad is the player's own.
- LIBRARY: grouped by mood. A press loads the progression on the current key note in its own scale and pins the key.

## 4. Presets (ROOMS)

The format is gear plus cables. `by: [host, px]` lays an amp next to a guitar so it howls. `att` places a BOW or LODESTONE on strings.

1. **THE ROOM**, 108 BPM, DADGAD prog 0, 2 bars each. Guitar 8THS (glide 0.3, ring 0.75, tone 0.6) → WALL (0.62, 0.6, 0.4) → REVERSE (0.45, 0.5, 0.42) → STACK amp (gain 0.5, mid 0.72, fb 0.2). Bass PULSE into a BASS amp. Drums DRIVE on the ROOM kit. A BLANK tape recording the guitar amp, bass amp and drums (feed 0.8, age 0.2, len 0.7407). OUT 4 channels.
2. **GLIDE**, 96 BPM, FACGCE. Guitar HALF with glide 0.95 (the arm dips on every strum), spread 0.55, neck pickup → REVERSE → CLEAN amp (treble 0.8) → SHIMMER (0.6, 0.45, 0.3). Bass WHOLE. Drums PULSE on BOX.
3. **SLOW WALL**, 52 BPM, DROP A an octave down (oct 1). WHOLE, ring 0.92, bridge pickup → WALL (0.85, 0.8, 0.42) → DOOM amp (gain 0.85, bass 0.15, mid 0.9) → HALL (0.8, 0.75, 0.38). Bass into a BASS amp. Drums CRAWL on DOOM.
4. **STROBE**, 132 BPM, DROP D, 1 bar per pad. TREMOLO picking → FUZZ (0.72, 0.45, 0.2) → FLANGE (0.2, 0.55, 0.5) → TREM (0.8274, 0.95, 1) → CHIME amp. Bass PULSE. MOTORIK on BLOWN.
5. **BOWED**, 66 BPM, UNISON D, strum OFF. Two bows on guitar strings 1 (u 0.52, drive 0.85) and 4 (u 0.68, drive 0.7, HARMONIC). Chain: WALL → STACK → HALL (0.95, 0.88, 0.5). Bass DRONE with PEDAL and its own bow on string 2. No drums.
6. **FEEDBACK**, 90 BPM, OPEN D, WHOLE, air 0.75. A LODESTONE (spin 0.45, h 0.4) on the strings. SUSTAIN pedal → CHIME amp placed 44 px from the guitar with FEEDBACK 0.85 → ECHO. Bass WHOLE. POUND on DOOM.
7. **LAYERS**, 96 BPM, DADGAE ARP through PITCH (+12) into a CLEAN amp. A second guitar in UNISON D, not following, with a LODESTONE (spin 0.3, h 0.2), also into the amp. The amp feeds a BLANK tape (feed 0.86, age 0.3), and the tape feeds a SHIMMER. Bass WHOLE. WASH on ROOM.
8. **WOOL**, 44 BPM, BARITONE prog 1. WHOLE, ring 0.95 → SWELL (0.75) → WALL → CLEAN amp → SHIMMER, with the amp also into a BLANK tape that feeds the SHIMMER. Bass. DIRGE on DOOM with room 0.8.
9. **ATTIC**, 63 BPM, DADGAE prog 1. HALF strum, spread 0.9, tone 0.35 → VIBE → quiet CLEAN amp (verb 0.5) → HALL. A worn BLANK tape (wow 0.7, flutter 0.45, age 0.7, motor 0.6) also feeds the HALL.
10. **BLOWN HYMN**, 60 BPM, DADGAD prog 1. Two bows on strings 0 and 1 (drive 0.9 and 0.8) → WALL 0.95 → FUZZ → STACK (gain 0.85) → HALL (0.95, 0.9). Bass. POUND on DOOM with drive 0.6.
11. **DRY CREEK**, 58 BPM, STANDARD prog 1. RAKE → CLEAN amp (verb 0.45, trem 0.2, rate 0.3) → ECHO (0.7525, 0.25, 0.2). Bass WHOLE. A custom sparse beat with fills every 4 bars.
12. **BASALT**, 40 BPM, DROP A, 4 bars per pad, no drums. Guitar 1 DRONE an octave down → WALL 0.9 → DOOM amp at 40 px, fb 0.7. Guitar 2 DRONE → STACK amp at 50 px, fb 0.6. Bass DRONE into a BASS amp at 50 px, fb 0.25.
13. **SEASICK**, 124 BPM, OPEN C prog 1. 8THS with glide 0.9 → WALL → REVERSE (mix 0.7) → STACK → VIBE. Bass PULSE. DRIVE on ROOM.
14. **EMPTY ROOM**: only OUT.

## 5. The "gear fit" question

There is no gear scoring or matching in the code (see section 0). What links song and gear:
- Every guitar with FOLLOW voices the song's chords in its own tuning via `Play.voice`. The VOICINGS panel shows how well each one fits: "approx" when notes are missing, "lost" when the defining note is gone, and a `loose` level from 0 to 3.
- AUTO key: the song key comes from the lead guitar's tuning (`Play.keyOf`, `analyse`).
- The library lists progressions written for the current scale first and dims the others.
- MATCH GUITAR 1 revoices guitar 1's pads for another tuning (`revoice`, weights RV: root 1, tone 0.6, fifth 0.5, miss 0.5, extra 0.3, mute 0.35).
- The chord-name "fit" is `QUAL` on the best root, with a threshold `NAME_OK = 0.5` for naming a chord.
- Physical fit: the amp's FEEDBACK depends on distance (NEAR 40, REACH 260 px). TIDY lays out air pieces out of reach unless `by` places them on purpose.

If you want a "GEAR FIT" feature, you would have to design it. These functions are the building blocks.

## 6. What makes it a drone and ambient machine

- Infinite sustain: BOW (regulated mode drive), and the LODESTONE's periodic magnetic pulling.
- Acoustic feedback: amp to strings through a band-limited air path that only opens when the strings already ring. Ringing notes bloom into a howl. The level is limited by the string ceiling, the amp clippers and the worklet safe-knee.
- Long tails: SHIMMER (RT up to 48 s, FREEZE holds forever, octave climbing), HALL (Cloud Seed, HOLD), VERB and ECHO FREEZE, FREEZE (spectral pad layering), REVERSE swells, GRAINS freeze and looping.
- Tape layering: sound-on-sound with FEEDBACK 0.7 to 0.86, so layers pile up. Wear builds every pass, so the loop darkens and decays over minutes. Wow, flutter and drift give pitch movement.
- Slow harmony: DRONE moods and progressions (one chord for 8 bars), the DRONE picking pattern that re-picks only strings that died, LET RING overlap, bass PEDAL, tempos down to 40 BPM.
- Pitch drift and beating: ±1.5 cent unison detune, spring length wobble, ECHO wow, SHIMMER line wavering, PITCH DETUNE, the GLIDE arm dip on every strum, tape wow and flutter.
- Loops are allowed anywhere. A cable cycle with gain settles at a loud saturated tone (soft knee 1 to 1.5), and the OUT ceiling keeps everything at or below 1.0.
- Everything is seeded per gear id, so a room sounds the same every time.

## 7. DSP core helpers (dsp-core.js and shared)

- `clamp(v, a, b)`.
- `rng(seed)`: mulberry32. `a += 0x6d2b79f5; t = imul(a ^ a>>>15, 1|a); t = (t + imul(t ^ t>>>7, 61|t)) ^ t; return ((t ^ t>>>14)>>>0)/2^32`.
- `satf(x)`: a cheap tanh. -1 below -3, 1 above 3, else `x(27+x²)/(27+9x²)`.
- `mtof(m) = 440·2^((m-69)/12)`. `pow2(n)` gives the next power of two.
- A Hann table of 1025 points. `ringRead`: linear interpolation in a power-of-two ring buffer.
- `DcBlock`: `y = x - x1 + 0.995 y1`.
- `SVF`: Cytomic/Simper TPT. `g = tan(π fc/sr)`, `a1 = 1/(1+g(g+k))`, `a2 = g a1`, `a3 = g a2`. Low-pass output v2.
- Freeverb comb and all-pass structure (see VERB).
- One-pole coefficients: `1 - exp(-2π fc/sr)` (onePole or pole) and `1 - exp(-1/(sec·sr))` (tc).
- Biquads use the RBJ cookbook (lp, hp, pk, ls, hs) in transposed direct form II.
- Half-band polyphase elliptic all-pass filters: `halfband(nc, tbw)` computes the coefficients from the elliptic modulus (the same code appears in amp and fx).
- ADAA clippers (amp and WALL), as described above.
- Drums: `fall(s, sr) = exp(-6.9078/(s·sr))` for a 60 dB decay, a sine table of 4096 points, and LCG noise `imul(ns, 1664525) + 1013904223`.
- Every unit emits meters at about 24 Hz (`sr/24`). Tape emits at 30 Hz.
- Pedal wrapper: footswitch fade `e += (on-e)*0.004`. NaN recovery rebuilds the effect.
- The LODESTONE constants also live here: `MAGNETS = 4`, `spinRate`.

## 8. UI and graphics

- The canvas `#desk` uses a 2D context with no alpha. The desk is 1200 × 900 desk pixels, drawn one canvas pixel per desk pixel and scaled with nearest-neighbour.
- Camera scale: `baseScale = clamp(min(w,h)/270, 1.25, 4)`, snapped to whole device pixels.
- Palette: six warm greys, `PAL = ['#0b0b0a','#1a1916','#302e29','#55524a','#958f81','#ece6d6']`. Monochrome only. Shading uses 4×4 Bayer dithering, `BAYER = [0,8,2,10,12,4,14,6,3,11,1,9,15,7,13,5]`.
- Font: a custom 3×5 pixel font (`FONT_SRC`). M, W and N are wider; symbols and arrows included. Text is uppercased and cached per string, colour and scale. `tag()` draws text on a filled box (silkscreen OUT labels).
- Primitives: `rect`, `px`, `box` (1 px outline with cut corners), `disc` and `ring` (pixel-exact spans), Bresenham `line`, `dither` and `ditherDisc` at levels 0 to 16.
- Enamel tones `TONES[5|3|1]`: light, mid and black panels with fill, edge, ink, knob cap, pointer and rim colour indices. `bevel` lights the top-left and darkens the bottom-right (the lamp is up and to the left). Knobs are discs with a pointer over 270° (-135° to +135°), with dot ticks for stepped knobs of 8 steps or fewer. Jacks are rings. The LED is a 3×3 lamp with a dithered halo.
- Scene: plank floor (rows 23 px tall, random joints, shade and grain, nails, knots, seed 11). A worn rug with a diamond lattice and fringe follows the gear's bounding box. A lamp overlay is dithered by distance from an ellipse. Props: cable coil, set list, picks, drumsticks, tape roll, X marks, water bottle, string packet, tuner, mug.
- Gear drawn as pixel art:
  - Amp (120×70): control panel, pilot light, standby switch, tolex pattern per model (piping, diamonds, border, bars, ribs).
  - Pedal (36×58): kind name, a 12×5 glyph either side of the LED, footswitch.
  - Guitar and bass: offset body built from Catmull-Rom curves, tortoiseshell or white pickguard, chrome, frets at true positions, tuners that turn, strings that shake while ringing, an arm, a capo bar, masking tape with the tuning name.
  - Tape: cassette shell with the tape loop round a pencil.
  - Drums: pads, 16 step lights, display, PLAY and FILL.
  - OUT: faders and a VU.
  - BOW (26×15) and LODESTONE (round puck with 4 visible magnets and rotating dashed field rings).
- Cables: cubic Béziers that sag toward the viewer, with shadows. Over other gear only a faint dotted trace shows. Flecks mark chains. Cables into OUT are brighter.
- Thumbnails for + GEAR are drawn by the same code and cached as data URLs.
- HTML chrome: top bar buttons `#bRoom #bPlay #bTempo #bSong #bAdd #bFit #bHelp`, `#start`, `#toast` (2.6 s), `#sheet` (bottom sheet), `#fileIn`. The CSS uses variables `--ink`, `--pcb`, `--line`, `--mid`, `--dim`, `--silk`, `--f-mono`. The main stylesheet is not in these files; only the drum and playsheet snippets are. Playsheet colours: ink #0b0b0a, pcb #141412, line #3b3a36, mid #55524a, dim #958f81, silk #ece6d6.
- Layout responds to width: pads, neck and strings sit in a row at 700 px and wider, or on a landscape phone under 520 px tall; otherwise stacked. Orientation is 'l' or 'p', and gear keeps a position per orientation. TIDY lays rows out by signal chain.
- Desk gestures: knobs drag or wheel, double-tap resets. Jacks drag or tap-tap. Gear drags. Floor pans, pinch or ctrl+wheel zooms, double-tap fits. Long press on a button triggers hold.

## 9. Structure facts for a reimplementation

- Size: script5.js is about 750 KB, 12,940 lines. The DSP is about 3,900 lines (core 540, amp 735, drums 860, fx 905, guitar 720). play.js about 1,630. The guitar gear file about 1,300. The play sheet about 1,050. The composer about 360. ui.js about 935.
- The WASM devices: Clouds about 138 KB including base64, Cloud Seed about 66 KB.
- Module plugin pattern: `defineGear(type, def)` registries (reg.js) with hooks for catalog, geometry, draw, hit, unit, step, tick, sheet, keys and more. Pedal kinds come from the DSP `PEDALS` tables plus `PEDAL_LOOK`.
- DSP packaging: each DSP file is one pure top-level function, `gazeCore()`, then `gazeFx(D)`, `gazeGuitar(D)`, `gazeAmp(D)`, `gazeDrums(D)`, merged into D by `makeGazeDSP()`. `gazeModuleSource()` stringifies those functions into the worklet module, so the same code runs on the main thread (for constants) and in the worklet. The code comments say it ports line for line to C or Swift.
- Sample rate: whatever the AudioContext gives (usually 44.1 or 48 kHz). Every unit takes `sr` in its constructor. Amp oversampling is ×4 below 88.2 kHz and ×2 at or above. WALL is ×4 or ×2 to stay near 190 kHz. FREEZE uses FFT 4096 or 8192. WASM devices run at a fixed native rate (Clouds 32 kHz, Cloud Seed 48 kHz) with block 32, and are resampled by the runtime.
- Block sizes: Web Audio's 128-sample quantum. Amp works in sub-blocks of up to CAP = 256 (so in practice 128). Guitar control block 32. Drums BLK 128. Timed messages split blocks at the exact frame.
- Message protocol (port): `{type:'p', p:{...}}` for params; guitar `fret`, `want`, `pluck`, `strum`, `mute`, `arm`, `bow`, `fe`, `gen`; drums `hit`, `choke`; amp `kick`; tape `tape`, `seek`, `erase`; pedal `{k:[a,b,c], on, hold}` and `{pulse:1}`; `{type:'dispose'}`. Meters return with `t`, the audio time.
- Generation counters (`gen`, `hg`, `ag`) drop stale scheduled events after STOP or a manual hand move.
- State: `ST = {name, gear:[{id, t, kind?, k:{knob:0..1}, f:{flags}, pos:{p,l}, plus type extras: tune, sets, via, strum or pattern, cas, off, pat, pn, vol, att, by}], cables:[[from, outJack, to, inJack]], neat:{p,l}, tr:{bpm, on}, song:{prog[8], on, key, chords[≤8]}}`. Fields starting with `_` are live and not saved. Saved to `localStorage['stitches-gaze.v1']` as JSON, debounced 250 ms. The user's file is stored in IndexedDB. Loading normalises everything: unknown gear is dropped, knobs are clamped, invalid cables are removed, and OUT is always present (`keep`).
- Engine lifecycle: `sync(ST)` diff-builds units by signature (type, kind and room id), applies knobs, and wires and unwires cables. A unit that fails to build is marked broken until it changes or START is pressed again. Changing room increments `Engine.room`, so everything except OUT is rebuilt.
- Frame loop: `requestAnimationFrame` runs every gear type's `tick` (lodestone motors, bow messages, amp air, VU, meters), then `VIEW.frame`, then sheet sync. The transport runs on a 25 ms `setInterval` with 0.25 s look-ahead.
- Phones: a silent looping WAV or `navigator.audioSession.type = 'playback'` so it plays with the silent switch on.
- Debug handle: `window.__gaze` exposes ST, Engine, UI, VIEW, Transport, Song, HOSTS, GEAR and helpers.
