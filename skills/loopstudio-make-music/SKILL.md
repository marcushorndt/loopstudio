---
name: loopstudio-make-music
description: Build a piece of music in loopstudio through the MCP, from an empty project to a checked bounce. Tracks, built-in instruments, MIDI notes, samples, session clips with follow actions, effects and sends, the mix, and a render_bounce check of peak, clipping and silence. Use it when the person asks you to make, sketch or arrange a track, beat or loop.
metadata:
  updated: 2026-11-21
---

# Make music in loopstudio

Read the skill `loopstudio-mcp` first. It explains the modes, the names and the counting rules.
This skill gives the order of the steps. Read the result of each step before the next step.

## 1. Set up the project

1. Call `project_new` with an absolute path that ends in `.loopstudio`. Give `sampleRate` only when the
   person asks for one (default 48000).
2. Set the tempo with `tempo_set` (20 to 999 BPM).
3. Call `effect_catalog` once. Keep its device ids, parameter keys, the `pads` of `drum808` and the
   `grooves`. Do not guess an id or a key.

## 2. A MIDI part (bass, drums, keys)

1. Add a MIDI track: `track_add` with `kind` `midi` and a name.
2. Add an instrument: `device_add` with a built-in instrument id from `effect_catalog`, for example
   `acid` (a 303-style mono bass) or `drum808`. The instrument goes to the front of the chain.
3. Make a clip: `clip_create` with `kind` `midi`, `length` in ticks (4 bars = 15360) and `loop`.
   Without `slot` the clip goes into the arrangement at `start`. With `slot` (from 1) it goes into
   that session slot.
4. Write the notes: `notes_set` with the clip (its id, its name or `"Bass/slot 1"`). `tick` and
   `length` count from the clip start. Pitch 60 is C3.
5. Check the notes. The receipt gives only the number of notes in the clip. The project changes notes
   of one pitch that overlap: a note that runs into the next one ends there, and of two notes at the same
   tick only the later one in the list stays. To see the stored pitches, ticks and lengths, call
   `track_get` with the track id and read the clip.

Instrument facts that change the notes you write:

- `acid`: a note at velocity 100 or more is accented. Notes that overlap slide into each other.
  For a plain line, make each note end before the next one starts.
- `drum808`: each pad plays on the MIDI notes that `effect_catalog` lists under `pads`. Use those
  notes, not General MIDI numbers from memory.
- A groove swings a clip without moving its notes: `command_apply` with `setClipGroove`. Copy the
  example from `command_examples`.

`notes_set` adds notes by default. Give `replace: true` to write the whole clip again. A replace with an
empty list on a clip with notes is refused; remove the clip with `clip_remove` instead.

## 3. An audio part (a sample or a loop)

1. Add an audio track: `track_add` with `kind` `audio`.
2. Import the file: `asset_import` with an absolute path (wav, aiff, caf, mp3, m4a, flac). The file is
   copied into the project. The result gives the asset id, `wouldLoop` and `sourceTempo`.
3. Get the track id with `track_list`. `sample_drop` takes ids only.
4. Place it: `sample_drop` with `track` and `asset`. Give `startTick` for the arrangement, or `slot`
   (from 0) for a session slot. Without `lengthTicks` the clip is as long as the sample at the song tempo.
   Short samples loop and long ones play once; `loop` overrides that.
5. A file with a tempo in its name or a clear loop length follows the song tempo. The warp mode and the
   clip length are fixed when you drop the sample. So check `sourceTempo` before `sample_drop`. When it
   is null or wrong, set it first with `setAssetTempo` through `command_apply` (20 to 400 BPM).
   For a clip that is already placed, also send `setClipWarp` and set the length with `clip_set`.

## 4. Session clips and follow actions

- A session clip only plays when something launches it. In live mode, `launch` starts a slot
  (`track` id + `slot` from 0) or a whole `scene` row.
- Follow actions choose what plays next. Set them with `command_apply` and `setSlot`; copy the example
  "setSlot (dummy clip with follow actions)" from `command_examples`.
- Check the odds with `follow_simulate` (`track` id, `slot` from 0, `launches` 1000) before you tell
  the person how often a clip plays.
- A bounce plays the arrangement. Session clips sound in a bounce only through saved launches:
  `command_apply` with `setLaunches` (a track id, a slot from 0, a tick). `setLaunches` replaces the
  whole list, so send every launch in one call. A launch without a slot stops the track.

## 5. Effects, sends and the mix

1. Add an effect: `device_add` with an id from `effect_catalog`, such as `reverb` or `delay`.
   Set its knobs with `param_set` (a key or a name, a value inside the range).
2. For a shared reverb: `track_add` with `kind` `return`, put the reverb on it, and set the level per
   track with `send_set` (`db`; -96 or lower removes the send).
3. Balance with `track_set`: `volumeDb` (-96 to 12), `pan` (-1 to 1), `mute`, `solo`.
4. Keep the master below 0 dB. Turn tracks down before you add a limiter.

## 6. Check the result without listening

1. Call `render_bounce` with an absolute `path` that ends in `.wav`. Give `overwrite: true` to replace an
   older file; without it the tool refuses. Give `tailSeconds` (0 to 600) for a reverb tail.
2. Read the result:
   - `clipping` must be false. `peakDb` above -1 is too hot: turn tracks down and render again.
   - `rmsDbPerSecond` has one value per second. A value of -200 is digital silence, and a value
     below -90 is close to it. Silence where the person
     expects sound means a muted track, an empty clip, a session clip without a launch, or a track sent
     straight to a hardware port (those are not in the master mix).
   - `warnings` lists plugins that did not load, assets that failed, and warps that were not ready.
     Report every warning.
3. "nothing to render" means that the range is empty: no clip plays on an audible track. With an
   `endTick` or a tail, an empty range renders silence instead, so read `rmsDbPerSecond`.

A bounce of a long song takes time, and the server answers nothing else meanwhile. Render a few bars
with `startTick` and `endTick` while you work. Render the whole song once at the end.

## 7. Finish

- File mode: call `project_save`. Then tell the person to open the project in the app.
- Live mode: the app autosaves. Call `transport` with `play` only when the person wants to hear it.
- Report what you built from the receipts and the bounce values, not from your plan.
