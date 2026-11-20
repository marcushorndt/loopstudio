# LoopStudio

A native macOS DAW in the spirit of Live, written in Swift. It has a Session view with clips and
scenes, an Arrangement, a mixer with groups, returns and sends, device chains of built-in effects,
built-in instruments and hosted Audio Units, racks with macros, a modular patch device, automation
in tracks and in clips, MIDI in and out, Ableton Link, and a control surface for agents over a local
socket.

The app owns its audio graph: one realtime callback renders the whole project from a compiled plan.
An offline export renders the same plan, so a bounce is bit-identical to what you hear. Output
depends only on the absolute frame, so the result is the same for every block size.

LoopStudio is early software. It runs on the author's Macs every day, but it has no installer
signed by Apple yet, and the project format can still change.

## Requirements

- macOS 26 on Apple Silicon
- Xcode 26 (Swift 6) for a build from source

## Build, run, test

```
git clone --recurse-submodules https://github.com/marcushorndt/loopstudio.git
cd loopstudio
scripts/run-app.sh            # debug build, starts the app
scripts/install-app.sh -j 2   # release build into /Applications/LoopStudio.app
swift test                    # the tests
```

`scripts/run-app.sh` signs the app with an Apple Development certificate when one exists, so the
microphone permission survives a rebuild. It starts the binary from the shell, because an app opened
with `open` gets no Local Network prompt on macOS 26 and then cannot see Link peers.

Some tests need hardware or installed plugins and stay off by default:

| Variable | Runs |
|---|---|
| `LOOPSTUDIO_LEMUS=1` | Tests that load the Lemus machines from `~/Library/Audio/Plug-Ins/Components` |
| `LOOPSTUDIO_PERF=1` | The performance spikes (a thousand clips, a one-hour file) |
| `R303_STATE=<file>` | The plugin automation test with a saved 303 state |

The app runs without any plugin. Audio Units in `~/Library/Audio/Plug-Ins/Components` show up in
the device browser and load out of process, so a plugin crash does not take the app down.

## What it does

**Session and Arrangement.** Clips in slots, scenes, follow actions (stop, replay, next, previous,
any, other, jump), launch quantize, legato takeover, one-shot or loop. A launch while stopped resumes
the kept clips; a session clip always starts from its beginning. Capture puts a jam into the
arrangement. The arrangement has a loop brace, time selection, split at the playhead, clip fades,
clip gain envelopes, and automation lanes per track. Returns and the master sit at the bottom of the
arrangement and scroll with the tracks.

**Audio clips.** Warping with warp markers in six modes: Beats (cut at the transients or on a note
grid, with loop and envelope settings), Tones (aligned grains), Texture (loose grains with Flux),
Re-Pitch (speed and pitch together), Complex and Complex Pro (Rubber Band R2 and R3, with
formants). Transpose and Detune in every mode but Re-Pitch. Each clip renders offline on a worker
and is cached; the last render plays while a new one is made. A dropped file finds its tempo from
its name, its loop length or its beats, and then follows the project tempo: a loop in Beats, a
song in Complex. `docs/warp.md` describes the design. Tempo ramps bend time. A sample editor with a loop bar, a start marker and
zoom. Recording from a sound card input with latency compensation, from another track, or the
master (resampling); takes that start and end on the bar; a count-in; a metronome.

**MIDI clips.** A piano roll with an adaptive grid and snap, a velocity lane, control lanes
(sustain, mod wheel, pitch bend, pressure, program) with ramps or steps, a draw mode (B) that draws
notes and automation steps, band marking, arrow keys that move notes on the grid, grooves that
swing a clip without moving its notes, quantize with an amount, humanize. The computer keyboard
plays notes (M).

**Built-in devices.** Effects: Utility, Auto Filter, Tone EQ, EQ One to EQ Eight, Delay, Tape Echo, Overdrive,
Reverb, Compressor, Limiter, Multiband Compressor, Live Cut (a port of Livecut with the BBCut
procedures) and Granulator. Instruments: Acid Bass (a 303-style mono synth with accent and slide),
808 Drums (twelve synthesized pads) and a DX7 (six-operator FM with the 32 algorithms, which reads the
original 32-voice SysEx banks). An Audio Effect Rack and a MIDI Rack hold chains behind
eight macro knobs and a chain selector, with key and velocity zones. Compressors take a sidechain
source. Every knob automates, learns MIDI, maps to a macro and shows in the agent tools.

**The Patch device.** A modular device of its own: modules with typed ports, cables and a panel,
compiled in the app to an op list that runs per frame without allocation. A Script module takes a
small realtime text language. Panel inputs become knobs of the device. Hot reload keeps the delay
lines. See `docs/patcher.md` and `docs/scripting.md`.

**Hosted plugins.** Audio Units as effects, instruments and music effects (`aumf`). Parameters get
knobs on the device card, grouped or paged, with the plugin's own value strings. Plugin windows keep
their size. State goes into the project. A plugin's parameters automate from a track lane or from a
clip; the renderer schedules every step as an immediate event, which version 2 plugins built with
JUCE need. Device presets save a built-in's parameters, a plugin's state or a whole rack, and load
onto a device of the same kind without losing its automation.

**Automation.** Several lanes per track in the arrangement, each with a parameter menu grouped by
mixer and device. Clip automation in audio, MIDI and dummy clips, with an own loop length, moved to
the track with one command. Curves have slopes and shapes (hold, ease in, ease out, ease in and
out). The editor adds a point on a click, moves a segment on a drag, marks points with a band and
moves the group. A knob shows the automated value as a red arc beside its setting.

**Routing.** Group tracks, return tracks, sends, per-track output (the master, a bus, an audio
track, a sound card port, sends only), per-track input (a sound card lane, another track,
resampling, no input), monitoring In, Auto and Off. Busses and the master take devices and dummy
clips with automation. Delay compensation lines every path up, including a node's own clips and the
automation of each effect, so the whole mix is late by one latency and nothing inside it.

**Mixer.** Faders, pan, mute, solo (solo overrides mute), arm, stereo meters with peak hold and a
clip light, a gain reduction meter on dynamics.

**MIDI.** Notes in from hardware and Network MIDI, notes out per track with channel and time shift,
MIDI clock in (start, continue, stop, song position, tempo follow) and out, MIDI map mode (⇧⌘M) for
the whole UI with key ranges, min and max, and device on and off as a target. See `docs/midi.md`.

**Ableton Link.** Tempo both ways, play on the shared grid, start and stop sync, phase keeping.
Verified with Live on another Mac.

**Export.** The whole arrangement, the loop brace or a time selection; the master mix or stems
(every track after its fader, the returns, the master, aligned); a tail. Hosted plugins render in
their own offline instances.

**Agents.** `loopstudio mcp` is a Model Context Protocol server. While the app runs it forwards to
the app's socket, so an agent edits the open project, drives the transport and launches scenes, with
undo and autosave like a click. Without the app it works on project files. An assistant pane in the
sidebar talks to Claude or an OpenAI model with the same tools. See `docs/mcp.md` and
`docs/assistant.md`.

## Keys

Every key has one place, `AppAction` in `Sources/LoopStudioApp/Shortcuts.swift`. The menu bar, the
right-click menus and the shortcut sheet (⌘/) read it. The most used:

| Key | Action |
|---|---|
| Space, ⇧Space | Play, pause (arrangement) |
| ⌘. , ⇧⌘. | Stop and rewind, stop all clips |
| R, ⌘K | Arm the selected track, metronome |
| ⌘1, ⌘2, Tab | Session, Arrangement, switch |
| ⌘T, ⇧⌘T, ⌥⌘T | Audio track, MIDI track, return track |
| ⌘G, ⇧⌘G | Group, ungroup (tracks or devices) |
| ⌘E, ⌘D, ⌘L | Split at the playhead, duplicate, loop the selection |
| ⇧⌘C | Capture the Session into the Arrangement |
| B, M, A | Draw mode, keyboard MIDI, automation lanes |
| ⌘4, ⌘←/→ | Snap notes, move a note on the other grid |
| ⇧⌘M | MIDI map mode |
| ⇧⌘R | Export audio |
| ⌥⌘D | Detail panel |

## Project files

A project is a package folder `Name.loopstudio`: `project.json`, one JSON file per track in
`tracks/`, `audio/` with files named by their SHA-256, `cache/` that is safe to delete, and
`journal.jsonl` with every command since the last save. JSON is written with sorted keys, so git
diffs stay small. A save is atomic as a whole, and a crash is recovered from the journal on the
next open. `relative.loopstudio` in this repository is the sample project the control tests use.

## Repository layout

| Path | Contains |
|---|---|
| `Sources/LoopStudioCore` | Time types, tempo map, project model, commands, undo, automation, racks, the patch compiler. No audio frameworks. |
| `Sources/LoopStudioProject` | The package format, migrations, the journal, the asset store. |
| `Sources/LoopStudioEngine` | The renderer, the plan compiler, delay compensation, built-in DSP, plugin hosting, transport, device I/O, MIDI, Link, offline render. |
| `Sources/LoopStudioControl` | The tool registry, receipts, named tools, the MCP server, the assistant engine. |
| `Sources/LoopStudioApp` | The SwiftUI app. |
| `Sources/loopstudio` | The command line tool: `mcp`, render, checks. |
| `Sources/LinkBridge` | Ableton Link as a C++ target (git submodule). |
| `Sources/RubberBandBridge` | Rubber Band Library as a C++ target (git submodule), for the Complex warp modes. |
| `Tests/` | One test target per library. The engine tests include a malloc-hook soak test: zero allocations on the audio thread. |
| `docs/` | `architecture.md` is the map of the code and the rules for the realtime path. `warp.md`, `midi.md`, `patcher.md`, `scripting.md`, `mcp.md`, `assistant.md` and `lemus-handover.md` cover one area each. `edge-cases-and-ideas.md` holds the rules for the edge cases. |
| `scripts/` | `run-app.sh`, `install-app.sh`, `pack-release.sh` (a disk image with the app and the installed plugins), `make-icon.swift`. |
| `Resources/` | The app icon. |

`Package.swift` compiles Core and Engine with `-O` in debug builds too: unoptimized Swift allocates
in generic loops on the audio thread.

## Plugins that live elsewhere

LoopStudio hosts Audio Units and runs without any of them. These are the ones the author uses:

| Plugin | Source | Note |
|---|---|---|
| Lemus machines: ro-mono-303, ro-drums-808, ro-drums-909, ro-mono-101, ac-digital-vc (Virus C), al-fx-quadgt | https://github.com/lemus-dev/lemus (AGPL v3) | Emulations at circuit and firmware level. They need ROM dumps that you supply yourself; neither Lemus nor LoopStudio ships one. |
| Gaze | private | A shoegaze room: guitars, amps, pedals, tapes, drums. Not released. |
| Remote MIDI | https://git.marcushorndt.de/marcushorndt/remote-midi | MIDI over the network. |

`scripts/pack-release.sh` builds a disk image with the app, these plugins as installed on the
build Mac, an installer that removes the download mark, and the licences. `--no-gaze` and
`--no-lemus` leave a plugin out.

## Rules of the realtime path

The audio callback never allocates, never locks and never waits. It tries the control lock at its
start and its end, and renders with the state of the last block when a control thread holds it.
Plugins and files that fail are reported, never fatal. A project file never loses data: every edit
is journaled until the save that holds it. `docs/architecture.md` section 7 has the full list.

## Contributing

Issues and pull requests are welcome. Keep the realtime rules, add a test for a change in Core or
Engine, and run `swift test` before a pull request. Commits made with an AI agent carry an
`Assisted-by:` trailer that names the agent and model.

## Licence

GNU GPL v3, see `LICENSE`. The licence follows from Ableton Link, Rubber Band and Live Cut, which are GPL.
`THIRD-PARTY.md` lists what the app links and which plugins live in their own repositories.
