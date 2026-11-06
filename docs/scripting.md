# A programmable device ("Patch"): the exploration and the plan

2026-11-04. Marcus asked for a Max for Live-like workspace as a plugin: the device card is the frontend with
the view (the knobs and displays), a click opens the backend where the device is wired and programmed. The
programming part comes first; a visual patcher can follow. This document compares the languages, picks one,
and sets the architecture and the stages.

## 1. What a device must do here

The engine gives every built-in device one contract (`DSPEffect`, `docs/architecture.md` §7):

- `process` works in place on one stereo block and uses only memory from `init`. Nothing allocates, locks
  or waits on the audio thread.
- `configure` writes plain numbers from the knobs. The renderer calls it at every 32-frame grid step when a
  knob is automated.
- `clock` tells a tempo-following device the beat, the tempo, and the bar (downbeat and length) per grid step.
- The plan is compiled off the audio thread and swapped in. Device instances survive a swap by id, so a
  buffer keeps its content when a knob turns (`kept` slots).
- An `EffectSpec` turns parameters into knobs, groups, automation lanes, macro links, MIDI learn and MCP
  access with no code per device. `meters`, `waveform`, `marks` and `spectrum` feed a display.
- A MIDI device (`DSPInstrument`) takes messages with a sample offset and renders between them.

A programmable device needs the same contract, and a second one: the program changes while the song plays,
without a click and without losing the state that should stay (a delay line's content, a filter's history).

## 2. The languages, compared

| Option | Realtime on the audio thread | Speed | Dependencies | What it is good for here |
|---|---|---|---|---|
| **JavaScript (JavaScriptCore)** | No. The collector pauses, the JIT allocates. It can run on a worker thread with a block of lookahead, which the delay compensation would hide. | Fast for control, slow per sample | None, ships with macOS | Control and MIDI scripts, UI logic, generators at control rate. Not per-sample DSP. |
| **Python (embedded CPython)** | No. GIL, collector, allocation everywhere. | Slow per sample | A 30 MB runtime, signing, packaging | Offline tools and agents. Not a device. |
| **C++ or Swift compiled at run time** (clang, dlopen) | Yes, once loaded | Native | Xcode command line tools on the user's Mac; library validation and signing of the loaded dylib; seconds per compile | The fastest path and an export target. Too fragile as the editing loop. |
| **Cmajor** (ISC licence, LLVM JIT) | Yes, by design | Near native | LLVM, tens of MB, a C++ API to bridge, its own web-based GUI stack | The closest existing fit. Heavy, and its GUI and parameter model would sit beside ours instead of being ours. |
| **Faust** (libfaust, LLVM or interpreter) | Yes | Native with LLVM, slow interpreted | LLVM again, or a slow interpreter | A strong DSP library and a block-diagram algebra. Functional style, far from Max's feel. |
| **Kyma's model** (Capytalk over a sound graph) | Yes, on its own hardware | n/a | n/a | Not a language to adopt. Its idea to borrow: every parameter of a sound object can be an expression of time and controllers, and the control surface is generated from the parameters. That is what `EffectSpec` already does. |
| **An own realtime language, compiled in the app to a small VM** | Yes, by construction | Interpreted, 5 to 10 ns per op; vectorized later | None | The device as a first-class citizen of this engine: params become knobs, hot reload is a plan swap, exports are deterministic. |

### The decision

Build the own language. The reasons, in order:

1. **It fits the engine as it is.** A patch compiles to an immutable program inside the render plan. A
   change compiles off the audio thread and swaps like any other plan change. The state carries over by
   name, like the `kept` device slots. No lock, no collector, no allocation on the audio thread.
2. **The view comes for free.** `param` declarations become an `EffectSpec`. The card shows knobs, groups and
   displays through the code that already serves every built-in device: automation, macros, MIDI learn, MCP.
3. **No toolchain on the user's Mac, no second GUI stack, no 50 MB runtime.** The app stays one binary.
4. **An export sounds like the playback.** Randomness is seeded (`CutRandom`), the clock is the song's.
5. **Text first, patcher second, on the same intermediate form.** A node graph is the natural form of this
   language. The patcher draws and edits that graph; the text is another view of it.

JavaScript stays on the list for a later control layer: scripts that react to notes and knobs at control
rate, and scripts behind a custom display. Not for sound.

Live Cut and the Granulator are the reference workload: a patch must be able to express a buffer with a
record head, a seeded random choice, a tempo grid with phrases, windows, and a display of a buffer.

## 3. The language, sketched

A patch is a text file. It declares its parameters and its state, then says what happens per sample, and
optionally per grid step and per MIDI event. Everything is typed as a signal (a float per sample, mono or
stereo), a value (a float that changes at control rate), or an event.

```
patch "Stutter Filter"

param cutoff  20..20000 = 1200 log "Hz"
param res     0..1      = 0.3
param rate    note      = 1/16            // a note value: follows the tempo
param drive   0..1      = 0.2

in  x : stereo
out y : stereo

delay line = 2 s                          // allocated at compile time
state env : float

gate   = lfo(rate, square)                // 0 or 1, on the song clock
env    = slew(gate, up: 2 ms, down: 40 ms)
cut    = cutoff * (1 + 2 * env)
wet    = svf(x, cut, res).low
line.write(wet + line.read(rate) * 0.4)
y      = mix(x, tanh(line.read(rate) * (1 + 4 * drive)), 0.5)
```

The rules that keep it simple and realtime-safe:

- **Per sample by default.** Every expression runs once per frame. Stereo values carry two channels; a
  mono value spreads to both. Functions on signals are the DSP primitives: `osc`, `lfo`, `svf`, `biquad`,
  `delay.read/write`, `follow`, `slew`, `adsr`, `sah`, `count` (rises of a trigger, wrapped at a step count, an optional reset), `noise`, `random` (seeded), `clip`, `tanh`, `mix`,
  `pan`, `window(kind, phase)`, `buffer.read/write` with a position in frames or seconds.
- **State is declared.** `delay`, `buffer`, `table` and `state` allocate at compile time. The size is a
  constant with a unit (`2 s`, `4 bars at 60 BPM`). A loop through time is explicit: `prev(x)` is the value
  of the last frame, and a feedback path must pass through a delay, a buffer or `prev`. A zero-delay cycle is
  a compile error with the two names in it.
- **Units in literals.** `ms`, `s`, `Hz`, `dB`, `st` (semitones), `ct` (cents), note values (`1/16`, `1/8.`,
  `1/4T`), `bars`, `beats`. The compiler converts to frames and factors at the song's sample rate and tempo.
- **The song clock.** `beat`, `bar`, `tempo`, `phase(1/16)` (0 to 1 inside the note value), `on grid(1/16)
  { }` runs a block at each boundary, on its exact frame, like Live Cut's units. `random(seed: bar)` makes a
  bar repeat its choices.
- **Events.** `on note(n, v) { }`, `on noteOff(n) { }`, `on cc(k, v) { }`. A `voice { }` block makes the
  patch an instrument: the engine allocates voices and runs the block per voice, with `note`, `velocity`,
  `gate` and `env` in scope.
- **Displays.** `scope y`, `meter env`, `waveform buf`, `xy a b` declare what the card shows. They map to
  `meters`, `waveform` and `spectrum` as the built-in devices use them.
- **No strings, no allocation, no recursion, no unbounded loops.** `for i in 0..<8` with a constant bound is
  fine (it unrolls). Functions are `def name(a, b) = expr` with signals in and out; they inline.

## 4. The compiler and the VM

```
text ──parse──▶ AST ──check──▶ typed graph (nodes, ports, state) ──order──▶ PatchProgram
                                        ▲                                      │
                                   the patcher edits this                      ▼
                                                              PatchDSP (a DSPEffect) runs it
```

- **`PatchProgram`** (Core, `Sendable`, value type): the op list in topological order, each op with its
  input slots, constant operands, and a state slot. Plus the `EffectSpec` derived from the `param` and
  display declarations, and the state layout with names. It lives in `EffectPlan` like a built-in effect's
  parameters.
- **`PatchDSP`** (Engine): owns one state buffer and the delay lines and buffers of the program, allocated in
  `init` from the layout. `process` runs the op list per frame with a `switch` over the op kinds and a flat
  array of signal slots. `configure` copies the knob values into the slots the params map to. `clock` sets
  beat, bar and tempo slots and fires `on grid` blocks at their frames.
- **Hot reload.** A new program compiles on the main actor. The plan swap keeps the `PatchDSP` instance when
  the device id is the same, and the instance takes the new program at a block boundary: state slots with
  the same name and size carry over; new ones start at zero. A compile error leaves the old program running
  and shows the error in the editor.
- **Speed.** Budget: 100 ops per frame at 48 kHz is 4.8 M ops per second; a switch VM at 5 ns per op is 24 ms
  per second, 2.4 % of one core per patch. Enough for v1. Stage 2 runs op chains without feedback a block at
  a time with Accelerate, which brings most patches under 1 %.
- **Tests.** Golden renders of example patches, the zero-delay check, the unit conversions, a hot reload
  that keeps a delay line's content, and a speed test with a budget.

## 5. The device and its editor

- **The card** is the view. `spec.view = "patch"`: the knobs from `param`, grouped by `group "Filter" { }`,
  and the declared displays. The same `ParamKnob`, the same automation lanes, macros and MIDI learn. A
  "Edit" button and a double-click on the title open the editor.
- **The editor** is a window of its own per device (like a plugin window): the source at the left with
  errors inline, the live displays at the right, a parameter list, and a Run/Stop for the patch. Save
  compiles and reloads. Cmd-Enter compiles without saving. The window stays open while the song plays.
- **The patcher** (stage 3) is a second tab of the editor: the typed graph as nodes and cables. A node is an
  op or a sub-patch (a `def`). An edit in the patcher rewrites the text, and the text stays the source of
  truth in the project file.
- **Storage.** The source is a string on the `DeviceSlot` (`source`), next to `params`. The compiled program
  is not stored; it compiles at load. A library of patches lives in `~/Library/Application Support/
  LoopStudio/Patches/` and in the browser's sidebar under "Patches". The MCP tools `patch_read`,
  `patch_write` and `patch_compile` let an agent write a device and read its errors.

## 6. Stages

Stage 1 is built (§7). From stage 2 on, `docs/patcher.md` (2026-11-06) replaces this table: the patch is a
graph document of modules with typed ports, the text language is one module kind, and the panel is the
device's face. The table stays as the first plan.

| Stage | Scope | Exit criteria |
|---|---|---|
| 1. Text patches as effects | Grammar, parser, checker, program, VM, `PatchDSP`, `param` to knobs, the editor window with errors, hot reload, the library folder, three example patches (a stutter filter, a tempo-synced tremolo, a comb) | The examples render and match their golden files. A reload keeps a delay line. The speed test passes. A knob of a patch automates and maps to a macro. |
| 2. Clock, events, instruments, displays | `on grid`, `on note`, `voice`, `scope`/`meter`/`waveform`, buffers with record heads, seeded random | A patch instrument plays a clip polyphonically. A Live Cut-like patch stutters on the bar. |
| 3. The patcher | The graph view, node palette, cables, sub-patches, text round trip | A patch built by wiring saves as text and reloads the same. |
| 4. Control scripts (optional) | JavaScript (JavaScriptCore) on a worker for control-rate logic and custom displays, with messages to and from the patch | A script maps a controller to several params with curves. |

Stage 1 is three to four days of work on top of the engine as it is. It touches Core (`PatchProgram`, the
compiler), Engine (`PatchDSP`, the plan), the app (the editor window, the sidebar) and the MCP tools.

## 7. Stage 1 as built (2026-11-05)

- **Core** `Sources/LoopStudioCore/Patch/`: `PatchProgram` (the op list over stereo slots; slots 0 to 6 are
  the input, beat, bar, tempo, quarter seconds, sample rate and zero), `PatchCompiler` (lexer, parser, a
  typed compile with the units plain, seconds, hertz, dB and note; `cached(_:)` compiles once per text and
  returns the program or a `PatchError` with its line), `PatchExamples` (the starter of a new device, three
  examples, and `reference`, the language on one page). `DeviceSlot.source` holds the text;
  `DeviceSlot.spec` gives every built-in device its spec, a patch the one its text declares.
  `Command.setDeviceSource` is the undoable edit.
- **Engine** `PatchDSP`: a `switch` VM, once per frame, no allocation in `process`. The delay lines are
  allocated at init. The renderer keeps the running instance while the program is the same object (the
  same text), and a new text gets a new instance that takes the delay lines of the old one by name, so an
  edit does not cut an echo. `followsTempo` is always on; the beat advances per frame inside a block, so a
  synced LFO is smooth.
- **Language as built**: `patch`, `param` (range with `log` and a unit, or `note`), `in`, `out`, `delay`,
  `meter`, assignments, `delay.write`. Functions: osc, lfo (a note value locks it to the song), phase,
  lp/hp/bp, slew, follow, prev, sah, count, noise, delay.read, tanh, abs, sqrt, sin, cos, exp, log, floor, clip,
  mix, min, max, pow, gain. Not yet from the sketch: `state` declarations, `group`, `on grid`, `on note`,
  `voice`, `scope`/`waveform`, `def`, `for`, buffers with a position (stage 2).
- **App**: the card shows the knobs from the `param` lines, or the compile error with the sound passing
  through. Edit (or the context menu) opens the editor window: the text, the error line, Examples, Revert,
  Apply (⌘↩) as one undo step. The window is left alone by the key monitor.
- **MCP**: `patch_read`, `patch_check`, `patch_write`; the resource `loopstudio://help/patch`.
- **Tests** `Tests/LoopStudioEngineTests/PatchTests.swift`: arithmetic, knobs from params, every example
  renders finite sound, a delay reads back at the right frame, a new program keeps the delay line, `prev`,
  a note value follows the tempo, the low-pass, the compile errors, and a speed budget (fifty-odd ops per
  frame, one second of sound in under a tenth of a second).
- **Open from stage 1**: the library folder and the sidebar section (the examples live in the editor's menu
  for now); `meter` values show on no card yet.
