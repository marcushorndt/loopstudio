# Gaze: a recreation of "Stitches Gaze" as a plugin and a standalone

Status: 2026-11-17, plan. Nothing is built yet. Source of truth for the original: the analysis in
section 9 (the scripts of the web app, read in full on 2026-11-17).

## 1. What the original is

"Stitches Gaze" is a web app: a pixel-art rehearsal room with gear on a wooden floor. Guitars, a
bass, amps, 20 pedals, cassette loops, a drum machine, magnetic string drivers (BOW), a spinning
magnet disc (LODESTONE) and an OUT mixer. Cables patch anything into anything, loops included.
Everything is synthesised in AudioWorklets. A transport strums chords from an 8 bar song, and a
composer suggests chords by key, mood and a seeded random generator. The ambient and drone
character comes from physical sustain (bows, magnets, air feedback from amp to strings), long tails
(shimmer, hall, reverse, spectral freeze, tape sound-on-sound) and slow harmony (one chord for
eight bars, drone picking that only re-picks dead strings).

Size of the original: 12,940 lines of JavaScript. DSP about 3,900 lines (core 540, amp 735, drums
860, fx 905, guitar 720). Harmony and play engine about 1,630. Guitar gear and play sheet about
2,350. Composer 360. UI 935. Plus two compiled modules: Clouds (Mutable Instruments, MIT) and the
Cloud Seed reverb (Ghost Note Audio, MIT), both C++ originals that exist in source.

"GEAR FIT" is not in the code. The nearest feature is the VOICINGS panel, which marks how well
every guitar's tuning fits the song's chords.

## 2. The two routes

| | A. JUCE plugin repo, like Lemus | B. Built-in device in LoopStudio |
|---|---|---|
| Outputs | AU, VST3 and a standalone app from one C++ tree | One device in this app; a standalone needs a second app target |
| Where it plays | LoopStudio, Live, Logic, any host | LoopStudio only |
| Clouds, Cloud Seed | The C++ originals compile as they are | A Swift port, or a C++ target behind a bridge |
| The desk UI | Its own window, pixel-exact, any size | The device card is two knob rows; the desk needs its own window like the patch editor |
| LoopStudio integration | Hosted plugin: automation of its parameters, MIDI in; knobs on AU parameters are open (handover P3-2) | Knobs, automation, macros, MCP tools, undo come free |
| Toolchain | CMake and JUCE, both on this Mac through Lemus | SwiftPM, already here |
| Source for you to work on | Plain C++ DSP files that mirror the JS files one to one | Swift, inside a large repo |

Decision: route A. The original is a standalone, its DSP is written to port line for line to C,
the two borrowed modules are C++ already, and the Lemus pipeline shows the host side of LoopStudio
works. LoopStudio gets the host improvements it needs anyway (section 7).

## 3. Shape of the plugin

One plugin, working name `gaze`, that holds the whole room. The reason: the air feedback from an
amp into the strings, bows, lodestones and cable loops need every piece in one process at one block
size. A DAW graph forbids cycles, so a split into separate plugins would lose exactly the parts
that make the drone.

- Instrument (`aumu`) with a stereo main output and three more stereo outputs (the OUT channels).
- One audio input bus: an external sound into a TAPE or a pedal chain. LoopStudio now treats a
  synth with an input bus as an instrument (fixed 2026-11-17, handover P1-1).
- MIDI in: notes play the lead guitar through the song's voicing (`voice()`), eight pad notes
  (C2 to G2) strum the pads, CC 1 is the arm, CC 64 is MUTE, program change picks a room. More
  mappings go into the MIDI page of the desk.
- Host sync: the transport follows the host tempo and position. Without a host (standalone) it
  runs its own clock, as the original does.
- 128 fixed parameters `p001` to `p128`, named after the knobs of the gear in the room, the Lemus
  pattern. Automation then survives updates.
- State: the room JSON of the original (`stitches-gaze.v1`), so the fourteen presets load as they
  are and rooms move between the web app and the plugin.
- Later, when wanted: the amp, the WALL and SHIMMER pedals and the tape as separate effect
  plugins (`aufx`) for any track. Same DSP files, thin wrappers.

## 4. Repository layout

```
gaze/
  CMakeLists.txt            JUCE as a submodule, formats AU VST3 Standalone, like Lemus
  dsp/                      plain C++17, no JUCE, one file per JS file
    core.{h,cpp}            satf, SVF, biquads, half-band, ADAA, DcBlock, rng, Hann, ringRead
    guitar.{h,cpp}          waveguide strings, pickups, electrics, bow, lodestone, air
    amp.{h,cpp}             five models, tone stack, ×4 oversampling, spring, tremolo, cab
    fx.{h,cpp}              the 18 pedals
    tape.{h,cpp}            loop, wear map, cassettes generated from code
    drums.{h,cpp}           six voices, four kits, rooms, bus
    clouds/                 Mutable Instruments Clouds, MIT, as it is
    cloudseed/              Cloud Seed core, MIT, as it is
    room.{h,cpp}            units, cables, the one-block loop delay, the safe knee
  play/                     harmony: tunings, shapes, voice, next, suggest, patterns, transport
  plugin/                   JUCE AudioProcessor, parameters, state, MIDI, host sync
  ui/                       the desk: pixel canvas, 3×5 font, gear drawing, sheets, composer
  tools/
    gaze-render             CLI: room JSON in, WAV out, for tests and A/B
    jsref/                  node scripts that run the original JS DSP for reference renders
  tests/                    per-unit comparisons against the JS reference, preset renders
```

## 5. Conformance: the original as the oracle

The JS DSP files are pure functions (`gazeCore()`, `gazeFx(D)`, `gazeGuitar(D)`, `gazeAmp(D)`,
`gazeDrums(D)`). They run under node without Web Audio. So:

1. `tools/jsref` renders each unit from a fixed input and fixed knobs to a WAV (float64).
2. `tests/` renders the same with the C++ port and compares: spectra within 0.5 dB per third
   octave, peaks within 1 %, note onsets within 1 ms. Seeded noise and the mulberry32 generator
   port exactly, so many units can match sample for sample in float32 tolerance.
3. Every preset room renders eight bars both ways; the test compares loudness curves.

This is the same method Lemus uses against unit recordings, with a better oracle: the code.

## 6. Milestones

| # | Deliverable | Done when |
|---|---|---|
| 0 | Repo, CMake, JUCE submodule, empty plugin that passes `auval`, `gaze-render` writes silence | LoopStudio loads it on a MIDI track |
| 1 | `dsp/core`, `guitar`, `amp`; MIDI notes play a guitar into the CLEAN amp | Guitar and amp match the JS reference (section 5) |
| 2 | The 18 pedals, Clouds and Cloud Seed, the room graph with loops and the safe knee | THE ROOM preset renders and matches |
| 3 | Tape, drums, OUT, bow, lodestone, air feedback | BOWED, FEEDBACK, LAYERS, BASALT match |
| 4 | `play/`: tunings, voicing, composer, patterns, host-synced transport, the MIDI map | A clip in LoopStudio drives the song; SUGGEST gives the same chords for the same seed |
| 5 | The desk UI in the plugin window and the standalone: floor, gear, cables, knobs, sheets, composer | Every preset can be built by hand from an EMPTY ROOM |
| 6 | Presets, state round trip with the web app's JSON, multi-out buses, separate effect plugins | Live and LoopStudio sessions reopen with the room intact |

Milestones 1 to 3 are the sound and can be checked without any UI through `gaze-render`.
Order of value for drones: 1, 3, 2, then 4.

## 7. What LoopStudio needs for it

From `docs/lemus-handover.md`, now also for Gaze:

- Done 2026-11-17: an `aumu` with an input bus is an instrument (P1-1). A bounce tells hosted
  plugins they render offline (`isRenderingOffline`).
- P3-2 knobs for AU parameters: Gaze's 128 named slots make this worth doing next.
- P3-1 extra output buses as sources: the OUT channels of the room.
- The air feedback inside the plugin needs no host support.

## 8. Licence

Clouds and Cloud Seed are MIT and keep their notices. The rest of the original is the work of an
unknown author, published on claude.ai without a licence text in the files that were read. A
private recreation for your own use is fine. Before the repo goes public, find the author and the
terms, or write the DSP from the descriptions in section 9 rather than from the code. The Lemus
repo is GPL; Gaze does not use Lemus code.

## 9. The original, in detail

The full analysis (560 lines: every unit's algorithm with its constants, the harmony engine, the
presets, the UI) is the file `gaze-original-analysis.md` next to this plan.
