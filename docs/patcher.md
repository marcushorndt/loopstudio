# The modular device: modules, ports, panel and scripts

2026-11-06. Marcus: the script is only a part. He wants what Max for Live and Reaktor give: a device that is
patched together from the lowest building blocks, with inputs and outputs for audio and MIDI (later more),
a user interface where he steers the steerable parts, and scripts as items with inputs and outputs. This
document thinks that through and sets the model, the compiler, the UI, and the stages. It replaces §6 of
`docs/scripting.md` from stage 2 on. Stage 1 (the text language) stays and becomes one kind of module.

## 1. The one decision: the graph is the document

Stage 1 planned the text as the source of truth and the patcher as a view of it. That order is wrong for
what Marcus describes. A device with a panel, several scripts, a voice section, and MIDI and audio ports
is a graph. A text is one way to write the inside of one node. So:

- **A patch is a graph document** (`PatchDocument`, Core, `Codable`): modules, cables, the panel, and the
  device's own ports. It is stored as JSON in `DeviceSlot.source` (the string stays; its content changes
  from text to a document with a version field). A stage 1 device loads as a document with one Script
  module and the panel of its params. Nothing that exists breaks.
- **The text language is a module kind** ("Script"). Its `in`, `out` and `param` lines are the ports and
  panel items of that node. A Script is the "lowest building block" for a sound idea that is simpler to
  write than to wire; Reaktor Core and Max's `gen~` have that role.
- **The compiler of the graph produces the same `PatchProgram`.** The VM, `PatchDSP`, the hot reload, the
  `EffectSpec` route into knobs, automation, macros, MIDI learn and MCP: all of stage 1 stays as the
  backend. A graph compiles by inlining: every module becomes ops; a Script module becomes its compiled
  ops; a sub-patch inlines its inside. One program, one state layout, one `switch` loop. No per-module
  virtual calls on the audio thread.

Reaktor (Native Instruments) is the reference for the module set and the panel; Max for Live for the device
in a Live-like set and for scripts with ports; Bitwig's Grid for the port types and the clean rate model.

## 2. Ports and their types

A port has a type and a rate. Cables connect equal types; a few adapters are inserted by the compiler.

| Type | Rate | Carries | Example modules |
|---|---|---|---|
| `audio` | every frame | one float, mono or stereo (stereo spreads a mono source) | osc, filter, delay, the device in/out |
| `control` | every grid step (32 frames) and on change | one float | a knob, an LFO at control rate, envelope follower output, a macro |
| `event` | at a frame | a timed message: note on/off, cc, trigger, a value with a time | MIDI in/out, a sequencer, `on grid`, a Script's `on` blocks |
| `clock` | per grid step | beat, bar, tempo, phase of a note value, transport state | the song clock module, a divider |
| `data` | on change | a value that is not a number: a buffer, a table, a string, a path (later: OSC, a file, a video frame) | a sample player's buffer, a Control Script's message |

Rules:

- **Rate is explicit at the port, never guessed.** `control` into `audio` passes through a hold with a
  short slew (click-free), inserted by the compiler and drawn as a small mark on the cable. `audio` into
  `control` needs a module (`follow`, `sah`, `peak`): the user says how.
- **One source per input, many targets per output.** An input that takes several cables sums (`audio`,
  `control`) or merges in time order (`event`). That is what Reaktor and Max do; it needs no mixer node.
- **Feedback** closes through one frame of delay on the cable that closes the loop. The compiler marks that
  cable (`z⁻¹` on the canvas) and keeps the choice stable across edits, so the sound does not change when
  a module moves. Inside a Script, `prev` stays explicit. A `control` or `event` loop is an error with the
  two module names.
- **The device's own ports** are modules too: "Audio In", "Audio Out", "MIDI In", "MIDI Out", "Sidechain
  In", "Clock". Which of them are present decides what the device is: audio in and out, an audio effect;
  MIDI in and audio out, an instrument; MIDI in and out, a MIDI effect. The engine already has these three
  shapes. A later port type adds a boundary module, not a new device kind.

## 3. Modules

A module is a kind, an id, parameter values, a position, and for some kinds an inside.

- **Primitive modules** are the VM ops, one each: the oscillators, filters, delay, slew, follow, sah, noise,
  the arithmetic, clip, mix, tanh, dbToGain, the song clock. Their set grows with the VM, not with the
  patcher. A primitive has its ports typed; its parameters are `control` inputs with a default and a range.
- **Script** (the stage 1 language) with ports from its `in`, `out`, `param` lines. Several Scripts in one
  patch are normal: one for a filter, one for a sequencer.
- **Sub-patch**: a graph inside a module with "Inlet" and "Outlet" modules as its ports and its own panel
  items, which the parent's panel shows in a frame. A sub-patch saved to the library is a reusable module
  with a name, like a Reaktor macro.
- **Voice**: a sub-patch the engine instantiates N times. Its inside sees `note`, `velocity`, `gate`, and the
  voice's `env` as inputs; its audio outlet sums over the voices. The allocation (round robin, steal the
  oldest) is the engine's, like for the built-in instruments. N is a parameter; the memory is laid out at
  compile time for N voices.
- **Control Script** (stage 4): JavaScript on a worker thread. Ports: `event`, `control` and `data`, never
  `audio`. It talks to the VM through two lock-free queues: values and events in, values and events out,
  stamped with a frame. Delay compensation hides one block of lookahead for what it sends into audio.
  This is the item "that does something": a mapping with curves, an arpeggiator, a generator, a reaction
  to a display click, a message to another device later.
- **Panel items**: knob, slider, button, toggle, switch (choices), xy pad, number, label; displays: meter,
  scope, waveform of a buffer, xy plot, a text line. A panel item is a module with a `control` or `event`
  output (and an input, so a cable can move a knob). A display is a module with an input and no output.
- **Containers for later**: "Table" (a data buffer with a position input), "Sequencer" (events on the
  clock, editable in the panel), "Sample" (a buffer from the project's assets).

Every module kind has a `ModuleSpec`: name, category, ports with types, parameters with ranges, the
inside kind, and the ops it compiles to. The palette, the inspector, the compiler and the MCP tools read
the same spec. A built-in effect of the app is not a module (it has its own instance and state); a later
"Device" module can host one, like Max's `vst~`, when a use shows up.

## 4. The panel

The panel is the face of the device: the card shows it; the editor shows the same panel in a second pane.

- **Exposed items only.** A panel item that is marked "on panel" appears on the card; the others only in
  the editor. A sub-patch's items come as a group with the sub-patch's name.
- **Every panel control is an `EffectParam`.** Its key is the module id. So automation lanes, macro links,
  MIDI learn, the MCP `param_set`, undo, and presets work on the first day with no new code. A display
  maps to `meters`, `waveform` or `spectrum` of `DSPEffect`, as the built-in devices do.
- **Layout** is a grid in the document: column, row, width, height per item. The card uses the layout at
  card height; the editor at any size. No free pixels, so a panel stays tidy without a designer.
- **The card** keeps the title row of every device: power, name, the pen (opens the editor), presets, remove.

## 5. The editor

One window per device, as now. Three parts, resizable: the canvas (modules and cables), the panel, and an
inspector for the selected module (its parameters, its Script text with the error line, the sub-patch's
ports). The canvas:

- A palette by category (Generate, Filter, Dynamics, Delay, Math, Clock, Events, MIDI, Panel, Display, I/O,
  Library). Double-click an empty spot to type a module name, like Max.
- Cables drag from an output to an input; a wrong type does not connect and says why in the status line.
  A cable shows its type by colour and its adapter marks (hold, `z⁻¹`).
- Modules show their ports, their panel controls in small, and their live values on `control` ports.
- Select, move, copy, paste, duplicate, delete, group into a sub-patch, undo: all through `Command`
  edits of the document (`setDeviceSource` stays the one command: the document is one value; an edit
  replaces it as one undo step, like a text edit does now).
- Compile on every edit, as the text editor does on Apply: errors appear on the module they belong to; the
  old program keeps running until the graph compiles.

## 6. The compiler

```
PatchDocument ──check──▶ typed graph ──order──▶ inline ──▶ PatchProgram (ops, state layout, spec)
      ▲                      │                                       │
   the editor             errors per module                     PatchDSP runs it
```

- **Check**: every cable's types match or an adapter exists; every input has at most one cable or a sum;
  the audio graph has no zero-delay cycle (feedback cables get their `z⁻¹`); `control` and `event` graphs
  are acyclic; the boundary modules make a known device shape.
- **Order**: Kahn over the audio graph, with feedback cables removed; ties by position (left to right, top
  to bottom), so the order is stable and visible.
- **Inline**: a module writes its ops with its state slots; a Script module compiles with the stage 1
  compiler into the same op list, its `in` ports mapped to the cable sources, its `out` ports to new slots;
  a sub-patch repeats this for its inside; a Voice lays out N copies of its inside and a sum. Names of
  state slots are the module path (`voice.3/filter/svf`), which is what hot reload matches on.
- **Events and clock**: `event` and `clock` ports compile to a second, small program that runs at grid steps
  and at event frames inside `PatchDSP.step` and `PatchDSP.note` (stage 1 has the hooks: `step`,
  `tempoChanged`). An `on grid` or an `on note` block of a Script lands there too.
- **Hot reload** stays as it is: a new program, a new instance that takes the state of the old by name. A
  moved module keeps its state; a renamed one starts clean, as a renamed delay does now.
- **Cost**: inlining adds no calls. The budget of stage 1 holds: 100 ops per frame per patch is 2.4 % of a
  core. Voices multiply; N of 8 at 60 ops is 1.2 % more. Vectorising op chains per block (the Accelerate
  pass) stays an optimisation behind the same program form.

## 7. Storage, library, MCP

- `DeviceSlot.source` holds the document as JSON with `"version": 2`. A string that starts with `patch`
  is a stage 1 text and loads as a document with one Script. `Command.setDeviceSource` stays the edit;
  `name` comes from the document.
- The library (`~/Library/Application Support/LoopStudio/Patches/`, and the sidebar section) holds whole
  devices and sub-patch modules. A preset of a modular device is its parameter values, as for any device.
- MCP: `patch_read` returns the document; `patch_write` takes a document or a text; `patch_check` checks
  either and returns the errors per module. New: `patch_modules` (the `ModuleSpec` list, so an agent knows
  the blocks), and `patch_edit` with small operations (add a module, connect, set a parameter, expose on
  the panel), so an agent builds a patch step by step with a receipt per step. The resource
  `loopstudio://help/patch` describes both the text and the document.

## 8. Stages, revised

| Stage | Scope | Exit criteria |
|---|---|---|
| 2. The graph and the patcher | `PatchDocument`, `ModuleSpec` for every VM op, Script and sub-patch modules, the graph compiler to `PatchProgram`, `control` and `audio` ports with the adapters and `z⁻¹`, the canvas, the panel with knobs and meters, stage 1 texts loading as one-Script documents | A patch wired from primitives and one Script renders the same as the equal text. A moved module keeps its delay line. Knobs on the panel automate and map to macros. An agent builds a tremolo through `patch_edit`. |
| 3. Events, clock, voices, displays | `event` and `clock` ports, MIDI In/Out boundary modules, the Voice container, `on grid` and `on note`, scope and waveform, a Sequencer module, the library folder and sidebar | A patch instrument plays a clip with 8 voices. A Live Cut-like patch stutters on the bar. A MIDI effect patch arpeggiates. |
| 4. Control Scripts and `data` | JavaScript on a worker, the queues, `data` ports, a Table module, messages between a script and the panel | A script maps one controller to four params with curves. A script drives a sequencer from a display click. |
| 5. Beyond audio and MIDI | OSC in/out, a `data` port to and from the assistant, a "Device" module that hosts a built-in effect | A patch answers an OSC message. A patch exposes a value the assistant reads. |

Stage 2 is the big one: the document, the compiler, the canvas and the panel. About a week and a half of
focused work on top of stage 1. Stages 3 and 4 are three to four days each.

## 9. What is decided, what is open

Decided by this document: the graph is the document; the text is a module; one program and one VM; ports
with explicit types and rates; the panel items are `EffectParam`s; the Control Script is JavaScript on a
worker, never on the audio thread.

Open, to be settled during stage 2 with the first patches:

- Implicit `z⁻¹` on feedback cables (Reaktor, Bitwig), or an explicit delay module (Max). The document
  chooses implicit with a mark; a first week of use will show whether that surprises.
- The grid size of the panel (Reaktor uses 4 px; the card needs rows of knobs like the built-in devices).
- Whether a Script may expose its displays without a panel item (a `meter` line could be enough).
