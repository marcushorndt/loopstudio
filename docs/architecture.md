# loopstudio architecture

Status: 2026-10-28. Milestones 0 and 1 are done, and the app covers most of milestones 3 to 10 (see section 16a). 233 tests pass.
Decisions made: name `loopstudio`, minimum macOS 26, distribution left open (nothing in the design blocks a later release).
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
 |    |- clips: [Clip]   arrangement: audio (asset, warp, loop flag, fades), MIDI (notes), or dummy
 |    |- slots: [SessionSlot?]   session: a clip, launch quantize, follow actions A/B (see 11a)
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
- Hosted Audio Unit parameters: when a plugin loads, the app stores its writable parameters in the device slot (`pluginParams`, keys `au.<address>`). They become automation targets like any knob. The renderer sends them as scheduled parameter events on the 32-frame grid. A ramp is used only for parameters that report `flag_CanRamp`; others ignore an event with a ramp.
- Clip gain envelopes: an audio clip can hold `gainEnvelope` points (dB, ticks from the clip start). The clip mixer reads it on the same 32-frame grid.
- Later: LFO and envelope modulation sources that write to the same addresses.

### The session clock

The arrangement loop jumps the timeline back. Session clips must not follow that jump, or a stopped clip would play again after the loop end and a launched clip would vanish. So the engine runs two clocks: the timeline position (it loops) and the session position (it only runs forward while the transport plays). Session launches count on the session clock. Session audio clips, session MIDI notes and dummy-clip automation are planned in session frames and rendered against the session clock. Offline bounce passes the same frame for both. A seek while playing moves only the timeline.

## 11a. Session view, follow actions, fades, loop or one-shot

Model and decision logic are done (milestone 1, `Session.swift`, `Follow.swift`). The engine part comes in milestone 12.

**Slots and blocks.** Each track has a column of session slots. A *block* is a run of occupied slots with no empty slot between them. Dummy clips count as occupied slots, so they can sit inside a block as decision points.

**Follow actions.** Each slot has two actions, A and B, each with a weight. The chance of A is `wA / (wA + wB)`. If both weights are 0, nothing happens and the clip goes on. Actions:

| Action | Plays |
|---|---|
| `stop` | nothing; the track stops |
| `replay` | this slot again |
| `next`, `previous` | the neighbour in the block; at the edge it wraps or stops (setting `edge`) |
| `topOfBlock`, `endOfBlock` | the first or last slot of the block |
| `any` | a random slot of the block, this one included |
| `other` | a random slot of the block except this one (a one-slot block replays) |
| `jump` | a fixed slot index |

**When.** `FollowTime` is either a number of ticks after the clip starts, or a number of full passes (`loops`). A follow action starts the next clip on the exact frame, never quantized. Quantize applies only to manual launches.

**Dummy clips.** A dummy clip has no sound. It has a length, follow actions, and optional automation lanes. It is the conductor of a block: for example four bars of nothing, then a 70/30 choice between two fills.

**Reproducible randomness.** Choices come from a counter-based generator: `f(project seed, clip ID, launch count, draw number)`. It has no stored state. Results:
- A bounce makes the same choices as live playback.
- The engine can decide the next slot *when a clip starts*, which gives it the whole clip length to prepare the audio (see the head cache below).
- Skipping or replaying a section cannot shift later choices.
- The clip ID is hashed with FNV-1a, because Swift's `Hasher` changes on every launch.
A later "new variation each play" mode changes the seed on each play; the fixed seed stays the default.

**Engine rules (milestone 12).**
- A manual launch cancels the pending decision of that track.
- The renderer follows at most 8 transitions per block. More means a zero-length loop: the track stops and the slot is flagged.
- *Head cache:* the first 200 ms of every slot in a block stay in memory, so a jump to any slot starts without a disk wait.
- If the chosen target no longer exists when it is time to run (the user deleted it), the track stops and the track shows a note.

**Fades (nothing clicks).**
- Every audio clip has `fadeInMs` and `fadeOutMs`, 2 ms by default (`Project.defaultFadeMs`). `Project.makeAudioClip` is the one way UI code creates a dropped clip, so a timeline drop and a slot drop get the same fades. 0 means the user chose "no fade".
- *Declick guard:* the renderer also ramps any node start, stop, seek, mute and bypass over at least 64 frames, whatever the clip fades say.
- *Joins inside a block:* when clip A ends where clip B starts, plain fade-out then fade-in would dip. The renderer instead overlaps an equal-power crossfade of the fade length across the join, using source audio past the clip edge when it exists, and the plain fades when it does not.
- *Loop seam:* a looping clip crossfades its end into its start over the fade length.

**Loop or one-shot.** Each clip has a `loop` flag. At drop time the project's `AutoLoopRule` sets it from the sample's length: a sample between `minSeconds` and `maxSeconds` loops (default 0 to 20 s), anything else plays once. With the rule off, every drop plays once. The flag can be changed on any clip afterwards. A one-shot plays through once and then ends, or hands over to its follow action; for a one-shot, `loops(n)` counts as one pass.

## 11b. Sound cards, channels and MIDI devices

Model and logic are done (milestone 1b). The live device switching comes with the renderer.

**Two layers.**
- The **project** has logical ports: `Main` (stereo out), `Cue` (stereo out), `Input 1-2`. You can add more (for example a mono `Out 5` for a hardware synth). Tracks point at ports: `hardwareOutput` (send straight to a port, for stems or a cue mix), `audioInput` (record from a port). The master track's `hardwareOutput` is the main speaker output.
- The **machine** has a profile (`AudioIOProfile`): output device, input device, sample rate, buffer size, and for each port the physical channels it uses. It is stored per Mac in `~/Library/Application Support/loopstudio/`, not in the project, and remembered per device UID.

A project made on a studio interface therefore opens on a laptop: the ports stay, only the profile differs.

**How a profile is applied (`IOResolver`, pure logic, tested without hardware).**
- A device is found by its **UID**, never by its numeric ID. A missing device falls back to the system default and reports `deviceMissing`.
- A saved mapping is used when valid. If a channel is out of range or the width is wrong, the port gets free channels in order and the resolver reports it. Ports without a saved mapping get free channels in order (Main on 1-2, Cue on 3-4, and so on).
- A port that a track uses but that has no channels left is reported as `unmapped` and stays silent. Unused ports are never reported.
- A stereo port on a one-channel device plays on that channel (`foldedToMono`). Two ports on the same channel add up, with a warning (`sharedChannel`).
- Sample rate and buffer size are limited to what the device supports; any change is reported.
- If input and output are different devices at different rates, the resolver reports `inputRateMismatch`. The engine then builds an **aggregate device** (`AudioHardwareCreateAggregateDevice`) with drift correction on the secondary device.

**Reading hardware (`AudioDeviceCatalog`).** For each device: UID, name, manufacturer, transport (built-in, USB, Bluetooth, AirPlay, aggregate, virtual, and so on), the **channel names** the driver reports, supported sample rates, buffer range, and input and output latency. The `loopstudio devices` command and the `audio_devices` MCP tool show it. A `DeviceChangeMonitor` fires when a device appears, disappears, or the default changes. The engine then runs the resolver again and rebuilds its plan; the transport keeps its position.

**Latency.** The reported latency of the input and output device is used for record compensation and shown in the UI. A Bluetooth or Continuity device can report thousands of frames (this Mac's iPhone microphone reports 6100); the UI warns, and the timeline is never shifted for it.

**MIDI.**
- Sources and destinations come from CoreMIDI with their **unique ID**, which stays the same across restarts. `MIDIEndpointCatalog` lists them; the `DeviceChangeMonitor` reports hot-plug.
- A MIDI track has a `MIDIInputSelection`: one source (by unique ID, with its name kept for display) or all online sources, and one channel or all.
- A chosen source that is gone gives **no input and a visible issue**. It never falls back to "all sources", because that would let the wrong keyboard play the wrong instrument. When the device returns, the selection works again.
- Later: MIDI learn (a machine-level map from controller messages to parameters and actions), MIDI output to hardware destinations with a latency offset, and MIDI clock in and out.

## 11c. Control layer and MCP

Every important action is a **tool**: a name, a description, a JSON schema for its input, annotations (read-only, destructive, idempotent), and a handler. One registry (`StandardTools`) serves all front ends, so they cannot drift apart:

| Front end | Status |
|---|---|
| MCP server over stdio (`loopstudio mcp`) | Done: 15 tools, resources, tested over real pipes |
| In-app UI | Will call the same tools |
| Live attach: the running app listens on a local socket, `loopstudio mcp` bridges to it | Planned with the renderer |

Why the design is safe and flexible:
- **One generic edit tool.** `command_apply` takes any `Command` as JSON. A new command added to the model is available to agents at once, with no new tool. `command_examples` returns one valid example per command, and a test decodes every example, so the examples stay correct.
- **Same code path as the UI.** Tools go through `ProjectSession` and `ProjectStore`: validation, undo, the crash journal. An agent cannot create a state the UI could not.
- **Errors are results.** A rejected command returns `isError: true` with the reason, and changes nothing, so the agent can fix it and try again. Only an unknown tool or a broken message is a protocol error.
- **Paths are guarded.** Tools open or create only absolute paths that end in `.loopstudio`, and never overwrite an existing project.
- **The audio thread is out of reach.** Tools talk to the project store. Anything that must reach the audio thread (transport, parameter changes) goes through the same lock-free queue as the UI.
- **Preview before commit.** `io_resolve` shows what a device choice would do, and `follow_simulate` runs the follow-action dice 1000 times, both without changing anything.

Tools to add as features land: `asset_import` (hash and copy a file into the project), `transport` (play, stop, seek, loop), `render` (offline bounce, stems), `io_apply` (store a machine profile and switch devices), `warp_*`, `automation_*`, `plugin_*` (scan, insert, set parameter). Each one is a registry entry; none needs a protocol change.

## 12. Devices and failure handling

- Handle sample-rate change, buffer-size change, and device removal. The renderer rebuilds its plan for the new format; the transport position is kept.
- A dropped plugin, a missing file or a failed decode becomes a visible state on the track (never a crash, never a silent skip).
- The project loader never trusts input: bounds checks, version check, a clear error on unknown fields it cannot migrate.

## 13. Project files

- A project is a **package folder**: `project.json`, `audio/` (files named by SHA-256, so copies never duplicate), `cache/` (waveforms, warps, scan results; git-ignored; safe to delete).
- JSON is written with sorted keys and stable formatting, so git diffs are small and reviewable.
- `schemaVersion` in the file, with one migration function per version step and a test for each. Old files always open.
- Saves are atomic as a whole. A save stages `tracks.new/` and `project.json.new` (unchanged track files are hard links), writes the `save.commit` marker, then swaps them in. A crash before the marker keeps the old save; a crash after it is finished on the next read or write (`ProjectPackage.recover`).
- `journal.jsonl` holds every command since the last save, from the app and from the control tools. A save clears it in one step with the write (`ProjectStore.checkpoint`), so an edit during a save is either in the file or still in the journal. Opening a project replays what is left and marks it unsaved.

## 14. Concurrency

- Swift 6 language mode, strict concurrency on, in every target.
- Main actor: UI. `ProjectStore` actor: model, undo, jobs. Realtime thread: plain code, no actors, no async.
- Data crosses to the realtime thread only as immutable plans (pointer swap) or small fixed-size messages. Every other thread holds the engine lock for a few plain writes only; the callback takes it and waits (os_unfair_lock lends its priority), so it never drops a block or stops a clock.
- A renderer swap keeps running effects, delay lines and held notes. Only the audio thread changes a running effect (`needsConfigure`), and on the first block it takes over the held notes of the old renderer; a note whose note-off is gone gets one at once.
- Live MIDI names a track, not a node index. Audio capture goes through a preallocated SPSC ring (`CaptureRing`) to a writer queue (`CaptureWriter`); lost frames and write errors come back in the take.
- Slow work stays off the main thread: warps are made by a worker while the clip keeps its last warped audio (`AudioBank.live()`), and opening a project decodes all samples in parallel.

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
| 1 | **Core**: time types, `TempoMap`, project model, commands, undo, JSON package with migrations, command journal, follow-action resolver | Done: 70 tests pass, including random edit sequences that undo back to the start |
| 1b | **Hardware I/O model and control layer**: logical ports, track inputs and outputs, `IOResolver`, device and MIDI catalogs, tool registry, MCP server | Done: 112 tests pass, MCP checked over real pipes |
| 2 | **Renderer spike** (see section 17) | Part 1 done: `AudioUnitEffect` hosts Apple's AUDelay through `renderBlock`; output is the same for 64 and 1024 frame blocks. Still open: 10 min soak with zero allocations, and one third-party AUv3 |
| 3 | Renderer v1: tracks, clips, transport, loop region, offline bounce = realtime | Null test passes |
| 4 | Mixer: sends, buses, groups, PDC, meters | Routing and latency tests pass |
| 5 | Timeline UI: tracks, clips, waveform, drag, trim, loop brace | Usable by hand on a real loop set |
| 6 | Warping v1: rendered *Beats* and *Tones*, warp markers | Stretched loops stay on grid in a golden test |
| 7 | MIDI: input, MIDI clips, piano roll, instrument AU | No stuck notes; timing within one block |
| 8 | Plugin host: scan, validate, state, PDC, editor windows | A crashing fixture does not crash the app |
| 9 | Automation lanes and drawing | Click-free ramps in a golden test |
| 10 | Built-in effects (EQ, comp, delay, reverb, filter) | Each has a golden render |
| 11 | VST3 bridge | One third-party VST3 plays inside a project |
| 12 | Session engine: launch, follow actions, dummy clips, head cache, block crossfades | A block with weighted follow actions renders identically offline and live |

## 16a. Status of the app (updated)

| Area | State |
|---|---|
| Renderer | Own mix graph, one realtime callback. Output depends only on the absolute frame, so it is bit-identical across block sizes, with automation too. |
| App | SwiftUI, Session and Arrangement views, collapsible sidebar, mixer, clip and device panel, piano roll, plugin windows. |
| Effects | Utility, filter, EQ3, delay, reverb, compressor, limiter. Hosted Audio Units as effects and instruments. |
| Routing | Group tracks, return tracks (busses), per-track output menu, sends, Audio From another track, Sends Only. Busses have session slots for silent dummy clips that carry automation. |
| Automation | Several lanes per track in the arrangement, dummy-clip lanes, clip gain envelopes, hosted plugin parameters. Right-click a knob or fader to show its curve. |
| Recording | R arms. Space starts. Optional count-in of 0, 1, 2 or 4 bars. Metronome. MIDI notes become a clip when the transport stops. Audio from a sound card input, aligned with latency compensation. |
| Keys | One table, `AppAction` in `Shortcuts.swift`. The menu bar, the right-click menus, the key monitor and the shortcut sheet (⌘/) all read it. Plain keys (Space, Tab, R, Delete) go through an `NSEvent` monitor, so a focused control cannot swallow them. |
| Right-click menus | Clip, lane, ruler, track header, mixer strip, session slot, scene, device, sidebar items. Items show their key. |
| Warping | Beats and Tones modes, stretched offline with WSOLA (`TimeStretch.swift`) and cached per clip. Source tempo comes from the file name or the clip panel; warp markers and tempo ramps bend time. Deterministic, so a golden test can pin it. |
| Delay compensation | Each node knows the latency of its plugins. A plan pass (`DelayCompensation.swift`) adds delay lines on the connections that skip a latent plugin, so all paths into a node line up. Sample accurate, same output for every block size. |
| Done since | Audio recording with latency compensation, clip colours, clip names, several automation lanes per track in the arrangement, dummy-clip curves in clips, a multi-lane clip editor, keyboard navigation (arrows, Return), key 0, computer keyboard as MIDI keys (M), session slot copy and paste. |
| Done since (2) | Warp marker editor, clip gain envelopes, plugin parameter automation, session clock, zinc themes (dark and light), resizable inspector, equal mixer strips. |
| Done since (3) | Clip automation with slopes, unlinked and irregular loop lengths (bars:beats:sixteenths) and a move to track automation; playheads in the clip editors; atomic package save; the Codex audit (48 items): solo feeders, session take-over timing, instrument automation, fair follow-action budget, warped loops that follow tempo changes pass by pass, a beat grid click from the tempo and meter maps, Save As, Export Audio with hosted plugins and Session launches (offline plugin instances, latency removed), recording from Audio From (resampling), record into a Session slot, Capture Session into Arrangement, MIDI time stamps, crash recovery from the journal. |
| Open | MIDI To, per-track hardware outputs, VST3 bridge, pinned return tracks in the arrangement, more MCP convenience tools, export of a range or of stems. |

## 17. Risks and the spikes that answer them

| Risk | Spike |
|---|---|
| Hosting AUs by calling `renderBlock` from our own callback may behave differently for AUv3 (XPC) plugins | Milestone 2: run Apple's AUs and one third-party AUv3 for 10 min; measure glitches and latency. **Result so far (Apple v2 AU): works.** Gotcha found: effect buses start disabled; set `isEnabled = true` on the input and output bus before `allocateRenderResources`, or every render fails with -10876 |
| Our stretcher may sound worse than Live's Complex mode | Milestone 6 starts with a listening test against `AVAudioUnitTimePitch` on 5 reference loops |
| Waveform drawing for long clips may be slow | Build a peak cache (min/max per N frames, several zoom levels) and draw with Metal; test on a 1 h file |
| SwiftUI may be too slow for a dense timeline | Draw the timeline in a custom `NSView`/Metal layer, with SwiftUI for the chrome; decide after a 1000-clip test |
| VST3 license or hosting limits | Read the current SDK license and a sample host before milestone 11 |

## 18. Decisions

1. **Name:** `loopstudio`. The bundle id is still open.
2. **Minimum macOS:** 26 (Swift tools 6.2 in `Package.swift`).
3. **Distribution:** may open up later. Until then: no sandbox-hostile choices (user-chosen folders only through bookmarks, no private APIs), and the VST3 SDK and Ableton Link licenses are checked before those features start, not before.
