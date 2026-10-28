# loopstudio architecture

Status: plan, 2026-10-28. Milestone 0 (single-loop player, `LoopEngine`) is done and tested.
This document sets the rules for everything after it.
Edge cases, their rules, and creative ideas are in [edge-cases-and-ideas.md](edge-cases-and-ideas.md). Its section J lists the changes it made to this plan:
clip fades in the model, a command journal for crash recovery, one file per track for git merges, a per-node CPU watchdog, a single `silenceAll` path for stuck notes, a dummy clock without a device, and a project revision on every background job.

## 1. Goals, in priority order

1. **Reliable.** The audio callback never glitches because of our code. A bad plugin or a bad file never takes the app down. A project file never loses data.
2. **Deterministic.** An offline bounce is bit-identical to what the same engine code renders in realtime.
3. **Flexible.** New track types, effects, plugin formats and views need no change to the core.
4. **Native.** Apple frameworks only for audio, MIDI, UI and file access. Third-party code is allowed only behind a protocol, and only for VST3.

## 2. The key decision: we own the audio graph

`AVAudioEngine` is a good start (milestone 0), but it blocks four features we need:

| Need | Problem with `AVAudioEngine` |
|---|---|
| Plugin delay compensation (PDC) | No latency reporting across the graph |
| Pre-fader and post-fader sends, sidechain | Graph is a strict tree of mixer inputs; sends need workarounds |
| Sample-accurate clips, MIDI and automation | Scheduling is per node, not per project timeline |
| Same code offline and live | Offline needs manual rendering mode, which has other limits |

**Decision.** One `Renderer` owns the whole mix graph and runs inside a single realtime callback.
`AVAudioEngine` or a plain Core Audio output unit only moves the final buffer to the device.
Audio Units run inside our graph by calling their `AUAudioUnit.renderBlock`. Offline bounce calls the same `Renderer.render(frames:)` in a loop.

```
 UI (SwiftUI, main actor)
   |  commands
 Project store (actor)  --- undo/redo, persistence, analysis jobs
   |  immutable Snapshot (compiled render plan)
   |  lock-free handoff
 Renderer (realtime thread)  ---> device output (Core Audio)
   |-- Transport + TempoMap
   |-- Track processors: clip player, MIDI player, automation
   |-- Mix graph: tracks -> sends -> buses -> master, PDC
   |-- Plugin hosts: AUAudioUnit.renderBlock
```

## 3. Layers and package targets

Dependencies point down only. The compiler enforces it, because each layer is a separate SwiftPM target.

| Target | Contains | May import |
|---|---|---|
| `LoopStudioCore` | Time types, `TempoMap`, project model, IDs, commands, undo. No audio frameworks. | Foundation |
| `LoopStudioDSP` | Pure DSP: stretcher, filters, envelopes, meters, ramps. No allocation after `init`. | Core, Accelerate |
| `LoopStudioEngine` | `Renderer`, graph compiler, transport, device I/O, disk streaming | Core, DSP, AVFoundation, AudioToolbox |
| `LoopStudioMIDI` | CoreMIDI input and output, MIDI clip playback, clock | Core, CoreMIDI |
| `LoopStudioPlugins` | Plugin scanning, AU host, state save, VST3 bridge (later) | Core, Engine |
| `LoopStudioProject` | Package format, migrations, asset store, analysis cache | Core |
| `LoopStudioUI` | SwiftUI views, waveform drawing (Metal or `Canvas`) | all above |
| `loopstudio` (CLI) | Headless tool: play, render, scan, validate | Engine |
| `LoopStudioApp` | macOS app shell | UI |

`LoopStudioCore` has no Apple audio imports, so its tests run fast and anywhere. Most logic lives there.

## 4. Time model

Floating-point beats drift. We use integers.

- **Musical position:** `Tick` = `Int64`, 960 ticks per quarter note (PPQ). All clip edges, notes, automation points and markers are in ticks.
- **Audio position:** `Frame` = `Int64` sample count at the engine sample rate.
- **`TempoMap`:** a sorted list of tempo and time-signature changes (constant or linear ramps). It converts tick <-> frame in both directions. It is a value type, built once per edit, and passed to the renderer inside the snapshot.
- **Rule:** conversions round once, at the edge of the audio block, with one documented rounding rule. Tests check round trips over millions of ticks.

## 5. Project model

Pure value types (`struct`, `Codable`, `Sendable`). Every object has a stable `UUID`.

```
Project
 |- tempoMap, timeSignatures, markers
 |- tracks: [Track]      kind = audio | midi | group | return | master
 |    |- clips: [Clip]   audio clip (asset, warp) or MIDI clip (notes, CCs)
 |    |- devices: [DeviceSlot]   plugin or built-in effect, bypass, state blob
 |    |- sends: [Send]   target bus, level, pre/post fader
 |    |- output: OutputRoute     master | track id
 |    |- automation: [Lane]      target parameter, points, curve shapes
 |- assets: [Asset]      content hash, original name, analysis (tempo, transients)
```

**Why this is flexible:** a track is data plus a list of processors. A new track kind is a new case plus a new processor type. The graph compiler and the UI read the model, not each other.

**Edits** go through `Command` values (`apply` and `inverse`). The undo stack stores commands, not snapshots. Every command is pure, so tests can replay a command list and compare the project.

## 6. From model to sound: the render plan

1. The project store applies a command.
2. The **graph compiler** (a pure function) turns `Project` into a `RenderPlan`:
   - topologically sorted processor list,
   - all buffers pre-allocated and assigned (buffer pool),
   - latency per node and the PDC delay for every path,
   - automation and clip events sorted by frame.
3. The compiler rejects cycles with a precise error (which track routes to which). A route that would create a cycle is blocked in the UI.
4. The plan is immutable. The store publishes it through an atomic pointer swap (triple buffer). The renderer takes the newest plan at the start of the next block.
5. The old plan goes back to a **reclaim queue**. A background thread frees it. The audio thread never frees memory.

Small edits (a fader move, a mute) skip the recompile. They go as parameter messages through an SPSC ring buffer.

## 7. Realtime rules (non-negotiable)

The render callback must not: allocate, free, take a lock, call Objective-C or Swift runtime features that allocate (closures that capture, existentials, array growth, string work), do file or network I/O, or use Swift concurrency.

How we enforce it:
- Renderer code uses only pre-allocated `UnsafeMutablePointer` buffers and `Atomic` values from the `Synchronization` module.
- A `RealtimeSafe` code-review checklist for every renderer file, and a debug build that traps on `malloc` inside the callback (malloc hook in tests).
- Soak test: render 10 minutes of a busy project in a loop under Instruments. Zero allocations, zero lock waits.
- Thread sanitizer runs in CI on the offline renderer.

## 8. Audio clips, loops and warping

- **Short clips** (under about 30 s) load fully into memory. **Long clips** stream from disk through a ring buffer filled by a reader thread. The reader runs ahead by a fixed time; an underrun plays silence and logs once, never blocks.
- **Warp** is a pluggable `Warper` protocol with two backends:
  1. *Realtime*, via `AVAudioUnitTimePitch` logic, for constant-rate loops (milestone 0 approach, kept for quick auditioning).
  2. *Rendered*, our own transient-aware stretcher in `LoopStudioDSP`. A background job renders the warped audio for a clip and stores it in the **warp cache**, keyed by `(asset hash, warp markers, mode, sample rate)`. The audio thread plays plain buffers. This is deterministic and cheap in CPU.
- **Analysis** (tempo guess, transients, waveform peaks) runs once per asset in a background task and is cached. Warp markers are user data in the project; analysis results are cache data and can be rebuilt.
- **Modes** like Ableton's Beats, Tones, Texture, Complex map to different stretcher settings. Start with two: *Beats* (transient-preserving) and *Tones* (phase vocoder).

## 9. MIDI

- Input: CoreMIDI with the UMP protocol (`MIDIEventList`), so MIDI 2.0 messages and per-note data work from day one. Events get a host timestamp. The renderer maps it to a frame offset inside the next block.
- MIDI clips: notes as `(tick, length, pitch, velocity, channel)` plus CC and pitch-bend lanes. MPE is a channel convention; the model allows it.
- Output to instruments: `AUAudioUnit.scheduleMIDIEventListBlock` with sample offsets. The player sends note-offs for all sounding notes when playback stops or a clip ends (no stuck notes; this has a test).
- External MIDI out and MIDI clock out are optional later steps. Ableton Link is a separate decision, because its license needs a check first.

## 10. Plugins

- **One abstraction:** `PluginInstance` wraps an `AUAudioUnit`. The engine never sees a format name.
- **Audio Units (v2 and v3):** found with `AVAudioUnitComponentManager`. Instantiated asynchronously (`AUAudioUnit.instantiate`). AUv3 plugins run out of process, so a crash does not take the app down. The `units` CLI command already lists them.
- **Scanning:** a separate helper process validates each plugin (load, open, render a few blocks). Results go to a cache. A plugin that crashes is on a block list and shown in the UI.
- **State:** `fullState` of the AU is stored as a blob in the project, plus a name and version for a clear error when the plugin is missing. A missing plugin keeps its slot, its state and its automation; the track plays with the device bypassed.
- **VST3:** Apple has no VST host. VST3 comes through a bridge that wraps a VST3 module as an `AUAudioUnit` subclass, so the rest of the engine stays unchanged. The VST3 SDK moved to the MIT license in 2025; I will confirm the current terms before we add it. VST2 is out: its SDK license no longer allows new hosts. CLAP can use the same bridge later.
- **Crash isolation for non-AUv3 plugins:** later option, a helper process with shared-memory audio buffers. The `PluginInstance` protocol is designed so this swap changes nothing above it.
- **Latency:** each plugin reports `latency`. The graph compiler uses it for PDC.

## 11. Automation ("settings animation")

- A lane targets a `ParameterAddress` (node id plus parameter id). It holds points `(tick, value, curve)`. Curves: linear, hold, ease in/out, bezier.
- The compiler converts a lane to frame-sorted segments. The renderer sets each parameter at the start of a block and, if the value changes inside the block, uses a sub-block ramp. For plugins it calls `scheduleParameterBlock` with a ramp duration, so changes are click-free.
- Built-in parameters (volume, pan, send level, device parameters) use the same path as plugin parameters.
- Later: LFO and envelope modulation sources that write to the same addresses.

## 12. Devices and failure handling

- Handle sample-rate change, buffer-size change, and device removal. The renderer rebuilds its plan for the new format; the transport position is kept.
- A dropped plugin, a missing file or a failed decode becomes a visible state on the track (never a crash, never a silent skip).
- The project loader never trusts input: bounds checks, version check, a clear error on unknown fields it cannot migrate.

## 13. Project files

- A project is a **package folder**: `project.json`, `audio/` (files named by SHA-256, so copies never duplicate), `cache/` (waveforms, warps, scan results; git-ignored; safe to delete).
- JSON is written with sorted keys and stable formatting, so git diffs are small and reviewable.
- `schemaVersion` in the file, with one migration function per version step and a test for each. Old files always open.
- Saves are atomic: write to a temp file, then rename. Autosave keeps a rolling set of backups.

## 14. Concurrency

- Swift 6 language mode, strict concurrency on, in every target.
- Main actor: UI. `ProjectStore` actor: model, undo, jobs. Realtime thread: plain code, no actors, no async.
- Data crosses to the realtime thread only as immutable plans (pointer swap) or small fixed-size messages (SPSC ring buffer). Data comes back through a second ring buffer (meters, playhead, underrun flags). The UI polls this at display rate.

## 15. Testing strategy

| Kind | What it proves |
|---|---|
| Unit (Core) | Tempo map round trips, command + inverse = identity, graph cycles, PDC math |
| Property tests | Random edit sequences never break project invariants |
| Golden render | Offline render of fixture projects matches stored reference within a set tolerance |
| Null test | Offline render equals realtime-path render, bit for bit |
| Realtime audit | No allocation or lock in the callback (malloc hook, TSan) |
| Soak | 10-minute busy session, no growth in memory, no underruns |
| Fuzz | Random and truncated project files: loader returns an error, never crashes |
| Plugin | Apple's built-in AUs for repeatable host tests; one bad-plugin fixture for crash handling |

## 16. Milestones and exit criteria

| # | Milestone | Done when |
|---|---|---|
| 0 | Single loop player | Done: 4 tests pass |
| 1 | **Core**: time types, `TempoMap`, project model, commands, undo, JSON package with migrations | Round-trip and property tests pass |
| 2 | **Renderer spike** (see section 17) | Custom graph hosting an Apple AU runs 10 min with zero allocations |
| 3 | Renderer v1: tracks, clips, transport, loop region, offline bounce = realtime | Null test passes |
| 4 | Mixer: sends, buses, groups, PDC, meters | Routing and latency tests pass |
| 5 | Timeline UI: tracks, clips, waveform, drag, trim, loop brace | Usable by hand on a real loop set |
| 6 | Warping v1: rendered *Beats* and *Tones*, warp markers | Stretched loops stay on grid in a golden test |
| 7 | MIDI: input, MIDI clips, piano roll, instrument AU | No stuck notes; timing within one block |
| 8 | Plugin host: scan, validate, state, PDC, editor windows | A crashing fixture does not crash the app |
| 9 | Automation lanes and drawing | Click-free ramps in a golden test |
| 10 | Built-in effects (EQ, comp, delay, reverb, filter) | Each has a golden render |
| 11 | VST3 bridge | One third-party VST3 plays inside a project |
| 12 | Session view (clip launching, Live-style) | After the arrangement view is stable |

## 17. Risks and the spikes that answer them

| Risk | Spike |
|---|---|
| Hosting AUs by calling `renderBlock` from our own callback may behave differently for AUv3 (XPC) plugins | Milestone 2: run Apple's AUs and one third-party AUv3 for 10 min; measure glitches and latency |
| Our stretcher may sound worse than Live's Complex mode | Milestone 6 starts with a listening test against `AVAudioUnitTimePitch` on 5 reference loops |
| Waveform drawing for long clips may be slow | Build a peak cache (min/max per N frames, several zoom levels) and draw with Metal; test on a 1 h file |
| SwiftUI may be too slow for a dense timeline | Draw the timeline in a custom `NSView`/Metal layer, with SwiftUI for the chrome; decide after a 1000-clip test |
| VST3 license or hosting limits | Read the current SDK license and a sample host before milestone 11 |

## 18. Open decisions for Marcus

1. **App name and bundle id.** Working name: `loopstudio`.
2. **Minimum macOS.** Package says 15. Raising it to 26 or 27 lets us use the newest APIs and drops compatibility code.
3. **Distribution.** Personal tool only, or later a product? This decides the VST3 license check, the Link license check, and sandboxing (a sandboxed app limits plugin hosting).
