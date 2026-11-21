---
name: loopstudio-mcp
description: How to drive the loopstudio audio workstation through its MCP server. The two modes (the running app or project files), the order of the calls, how to name tracks, devices and clips, ticks, receipts, undo and save, and the traps. Read it first in every loopstudio session.
metadata:
  updated: 2026-11-21
---

# Work with loopstudio through the MCP

loopstudio is a native macOS audio workstation. `loopstudio mcp` is its MCP server on stdin and stdout.
Every edit goes through the same tools, so you cannot change a project in any other way.

## 1. Know the mode before you edit

The server runs in one of two modes. The tool list shows which one.

- **Live mode.** The LoopStudio app runs, and `loopstudio mcp` forwards to its socket. You edit the project
  that is open on screen. Each change shows and sounds at once and goes into the app's undo history. The
  app autosaves. Only in this mode do the tools `app_status`, `ui_state`, `transport`, `show` and `launch` exist.
- **File mode.** No app runs (or the client started `loopstudio mcp --files`). The server edits project
  folders on disk. There is no sound and no transport. Use `render_bounce` to check the result.

`--live` fails when the app is not running. The socket is
`~/Library/Application Support/LoopStudio/mcp.sock`, or the path in `LOOPSTUDIO_SOCKET`. The socket
belongs to the user who runs the app, so run the MCP client as that user.

Do not edit a project in file mode while the app has the same project open. The app keeps its own copy
in memory and its next autosave writes over your changes.

## 2. The order of the calls

1. Call `list_skills`. Load the skill for your task with `get_skill`.
2. Open a project. `project_open` takes an absolute path that ends in `.loopstudio` (a leading `~` is
   allowed). `project_new` makes a new one and never writes over an existing project.
   In live mode, both switch the app to that project. The app saves the old project first.
3. Read before you change: `project_info`, `track_list`, `track_get`. In live mode, call `ui_state`
   when the person says "this", "the marked device" or "slot 2".
4. Change with the named tools (section 4). Use `command_apply` for the rest.
5. Read the result of every change (section 5).
6. File mode: call `project_save` at the end. Live mode: the app autosaves; `project_save` writes at once.

In file mode, `project_open` reports `recoveredCommands`. A number above 0 means that a crash left edits
in the journal and the server replayed them. `recoveryFailed: true` means that some of them did not
apply. Tell the person, and save only when they agree. In live mode the app recovers and saves by itself.

## 3. Time and positions

- Ticks: 960 per quarter note, 3840 per 4/4 bar. `tempo_convert` turns ticks into seconds and back,
  with the tempo map.
- Notes: `tick` and `length` count from the clip start. Pitch 60 is C3. Velocity is 1 to 127, default 100.
- Counting is not the same everywhere. Check the base before you use a number:

| From 1 | From 0 |
|---|---|
| A track position in a name (`"2"`) | `track_add` `index` |
| A device position in a name | `device_add` and `device_move` `index` |
| `clip_create` `slot`, and `"<track>/slot N"` | `sample_drop` `slot`, `follow_simulate` `slot` |
| The slot rows and `selectedScene` of `ui_state` | `launch` `slot` and `scene`, the `setSlot` `index` |
| | `sessionPlaying` `slot` in `app_status` |

## 4. Name things, or use ids

The named tools take words:

- A track: its id, its name, `master`, or its position from 1.
- A device: its id, its name, or its position in the chain from 1.
- A clip: its id, its name, or `"<track>/slot N"`.
- A parameter: its key or its name from `effect_catalog`.

When a track, device or clip name matches more than one thing, the tool returns an error that lists them.
Ask the person which one they mean. Do not guess. A parameter name takes the first match, so use the key
from `effect_catalog`. A track named with a number hides the position with that number; use the id.

Some tools take only a track id (a UUID): `track_get`, `sample_drop`, `follow_simulate` and `launch`.
Get the id from `track_list` first.

The named tools: `track_add`, `track_rename`, `track_set`, `track_remove`, `device_add`, `device_remove`,
`device_move`, `device_bypass`, `param_set`, `clip_create`, `clip_set`, `clip_remove`, `notes_set`,
`send_set`, `tempo_set`, `loop_set`. The Patch device has its own tools (skill `loopstudio-patch-device`).

`command_apply` takes every other edit as one JSON command, for example
`{"setVolume": {"id": "<track id>", "db": -6}}`. Call `command_examples` and copy the example of the
command you need. Do not write a command from memory. Use `batch` for several changes in one undo step.
Give a `coalescingKey` to merge repeated edits (a fader move) into one undo step.

## 5. Trust the receipt, not your arguments

The named tools and the patch tools return a receipt: the command, the revision before and after, and
the touched values read back from the project after the change. Report the receipt values to the person.

Other changing tools return less. `command_apply` returns only `applied` and the new `revision`;
`sample_drop` returns the clip id and its length. After such a call, read the result back with
`track_get` or `project_info` before you report it.

A rejected command returns `isError` with the reason, and nothing changes. Read the reason, correct the
call, and try again.

`undo` and `redo` step through the history and return `changed`. In live mode they share the history with
the clicks of the person, so undo only your own changes, and only when the person asks.

## 6. Devices and sound

- `effect_catalog` lists every built-in effect and instrument with its parameter keys, ranges and
  defaults, the 808 pads with their notes, and the grooves. Read it before `device_add` or `param_set`.
- `param_set` refuses a value outside the range. For a choice parameter, give the index of the choice.
- `device_add` puts a built-in instrument at the front of a MIDI track, or in the place of the built-in
  instrument that is there. It does not remove an Audio Unit instrument. A MIDI track made in the app
  starts with the Apple DLS Synth, and only the first instrument plays. Read the chain with `track_get`
  and remove the other instrument with `device_remove`.
- An Audio Unit goes in with `command_apply` and `insertDevice`. Its parameters exist only after the app
  has loaded the plugin. "The plugin has not reported its parameters yet" means: wait, then read again.
- `audio_devices`, `midi_endpoints` and `io_resolve` only read. They show the sound cards, the MIDI ports
  and how the project's ports map to the hardware.

## 7. Notes in audio

An audio clip's notes can change one by one, as on the clip's Notes page (after Melodyne).

1. Call `audio_notes` with the clip. It lists the notes in the clip's original file, also the notes of a
   chord. Each note has a `key`, its name, its pitch (a MIDI number with cents), its start and end in
   seconds of the file, its peak level, and its `change` when it has one. Give `from` and `to` (seconds)
   for a part of a long file.
2. Call `audio_notes_edit` with the clip and `changes`: a list of `{key, pitch, shift, stretch, gainDb,
   muted}`. `pitch` is in semitones (a fraction is cents), `shift` in seconds, `stretch` a length factor.
   A field you leave out keeps the note's current change. `tune` puts notes on the nearest semitone
   (`"all"` or a list of keys). `reset` clears every change first.

The edit renders a new file from the original and switches the clip to it in one undo step. A change
always counts against the recording, not against the last edit. Without any change left, the clip plays
its original again. A note that only changes its level keeps the recording; a moved note is built again
from its partials. Drums, noise and speech give few or no notes, and a dense full mix gives many short
notes. The first `audio_notes` call on a long file takes some seconds (about 15 s for 2 minutes).

## 8. Long calls

The server handles one request at a time. `render_bounce` renders the whole mix offline, hosted plugins
included, and can take a long time on a long song. Give it a range (`startTick`, `endTick`) when you only
need a part. `follow_simulate` takes up to 100000 launches; 1000 is enough for a check.

## 9. Resources

- `loopstudio://help/ui`: the words of the screen and what the app cannot do. Read it when the person
  uses a word you do not know.
- `loopstudio://help/patch`: the Patch language on one page.
- `loopstudio://project/summary` and `loopstudio://project/full`: only while a project is open.

## Related skills

- `loopstudio-make-music`: build a track from nothing, and check the result with a bounce.
- `loopstudio-patch-device`: write and change the programmable Patch device.
