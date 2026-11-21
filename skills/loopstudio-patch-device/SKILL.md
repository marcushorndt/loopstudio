---
name: loopstudio-patch-device
description: Write and change the programmable Patch device of loopstudio through the MCP. A text patch (patch_check, then patch_write) or a modular graph (patch_modules, then patch_edit), its knobs, and the limits of the language. Use it when the person asks for a custom effect, a tremolo, a filter, a delay or any sound that no built-in device makes.
metadata:
  updated: 2026-11-21
---

# The Patch device

The Patch device is a built-in effect that you program. It holds a text in a small realtime language,
or a graph of modules with cables. Its knobs come from the patch. Read the skill `loopstudio-mcp` first.

## 1. Put a Patch device on a track

1. Call `device_add` with `device` `patch` and the track. The receipt gives the device id.
2. The new device holds a starter text. Read it with `patch_read` (`track`, `device`).
3. Decide: a **text** for a formula (section 2), or a **graph** to wire modules (section 3).
   Do not mix both ways on one device without a reason. `patch_edit` turns a text into a graph with one
   Script module, and after that `patch_read` returns the graph.

## 2. A text patch

1. Write the text. One statement per line:
   - `patch "Name"`: the device name.
   - `param key min..max = default`, with `log` and a unit (`"Hz"`, `"ms"`, `"dB"`, `"%"`) after it.
     A `"ms"` knob arrives in the program as seconds.
   - `param key note = 1/16`: a knob in note values that follows the tempo.
   - `in x` and `out y`. The text must set `y`.
   - `delay name = 2 s`: a delay line (1 ms to 60 s). `meter name`: a value on the card (up to 4).
   - `name = expression` and `name.write(expression)`.
2. Check it with `patch_check` (`source`). It changes nothing. It returns `ok`, the knobs and the op
   count, or the error with its `line`. Correct the line and check again.
3. Put it on the device with `patch_write` (`track`, `device`, `source`). The tool compiles first. A text
   with an error is refused and the device keeps its old program.
4. A good text replaces the program at once while the song plays. A delay line keeps its content only
   when its name and its length stay the same. When you change the length (`2 s` to `3 s`), the line
   starts empty and the echo stops. The device takes the name from the `patch` line.

For the full language, read the resource `loopstudio://help/patch` or the description of `patch_check`.

Rules of the language that catch agents:

- Every line runs once per sample on stereo values. There are no loops, no strings and no recursion.
- A name must be set on a line above the line that reads it.
- Feedback needs `prev(name)` (the value of the last frame) or a delay line.
- These exist only in the design notes and the compiler refuses them: `state`, `group`, `on grid`,
  `on note`, `voice`, `def`, `for`, `scope`, `waveform`. Do not write them.

A text that compiles (it ships with the app as an example):

```
patch "Tremolo"
param rate note = 1/8
param depth 0..1 = 0.6
param shape 0..1 = 0

in x
out y
meter level

soft  = lfo(rate, sine)
hard  = lfo(rate, square)
wave  = mix(soft, hard, shape)
level = 1 - depth * (1 - wave)
y     = x * level
```

## 3. A graph patch

1. Call `patch_modules`. It lists every module kind with its ports (type, range, unit), its settings,
   and the cable rules. Use only kinds and port names from that list.
2. Call `patch_edit` with `track`, `device` and `steps`, a list of step objects in order:
   `add`, `remove`, `move`, `connect`, `disconnect`, `set`, `setting`, `source`, `label`, `expose`,
   `rename`, `group`, `ungroup`. The `patch_edit` description shows the JSON of each step.
3. Give every module you add an `id`, so later steps can name it. A cable end is `module.port`, for
   example `"from": "osc1.out", "to": "lp1.in"`.
4. The steps run in order. When one step cannot run, the edit stops and nothing changes. The error names
   the step. Correct it and send the whole list again.
5. All steps of one call are one undo step. The receipt holds the new `document` and the `program`, or
   an `error` when the graph does not compile. Unlike `patch_write`, `patch_edit` puts a graph with an
   error on the device. The device then passes the sound through unchanged. Correct the graph with the
   next `patch_edit`, or call `undo`.

Rules of the graph:

- A cable joins an output to an input of the same type. A control output also goes into an audio input.
  Several cables into one input add up.
- A patch needs an Audio Out module.
- A cable that closes a loop gets a delay of one frame. You do not need a delay module for feedback.
  A cable from a module back into the same module is refused; put another module between them.
- A step with `"in": "sub1"` runs inside the Sub `sub1`. Inside a Sub, an Inlet stands for Audio In and
  an Outlet for Audio Out.

## 4. The knobs

- A text patch: each `param` line is a knob, and its key is the param name.
- A graph: a Knob module is a knob with its id as the key. A module on the panel (`expose`) shows its
  inputs without a cable as knobs with the key `module.port`. A Script module's params keep their own
  names as keys, so the keys stay the same when `patch_edit` turns a text into a graph. Exception: when
  two Scripts have a param with the same name, the compiler puts the module id before one of the keys,
  such as `script2.cutoff`. A knob inside a Sub carries the Sub id first, such as `sub1.filter.cutoff`.
- Do not guess a key. Read the keys from `knobs` in the `program` of the `patch_edit` receipt or of
  `patch_read`.
- Set a knob with `param_set` (track, device, the key, a value). Automation, macros and MIDI learn use
  the same keys. A key belongs to a param name or a module id. When you rename a param, or add a
  module again with another id, the key changes and automation on the old key stops.

## 5. Check the sound

- `patch_read` shows the program (knobs, op count, delays) or the compile error.
- In file mode, render a few bars with `render_bounce` and read `peakDb` and `clipping`. Feedback and
  resonance can grow fast; keep a `tanh` or a `clip` at the output when a patch feeds back.
- In live mode, the person hears every change at once. Keep the levels low while you try things.
