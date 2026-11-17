# Lemus machines in LoopStudio: handover and backlog

Status: 2026-11-17. Written after the Lemus plugins were built and installed on this Mac. Nothing in
LoopStudio was changed for it. This file lists what is known, what to fix, and what to test.

## What is installed

Lemus (`~/Documents/repos/3rd-party/lemus`, GPL) emulates studio machines at circuit and firmware
level. Each machine is an AU, a VST3 and a standalone app, built from the repo and installed for this
user:

- AU: `~/Library/Audio/Plug-Ins/Components/<plugin>.component`
- VST3: `~/Library/Audio/Plug-Ins/VST3/<plugin>.vst3`
- ROMs: `~/Library/Application Support/Lemus/ROMs` (copies; the originals are in
  `~/Documents/repos/3rd-party/lemus-roms`). Lemus finds ROMs by SHA1, loose or in zips.

| Plugin | Machine | LoopStudio identifier | Buses (in / out) | ROM state |
|---|---|---|---|---|
| ro-mono-303 | TB-303 | `aumu/R303/Lmus` | 0 / 1 | full (tested in the app) |
| ro-drums-808 | TR-808 | `aumu/R808/Lmus` | 0 / 12 | ROM present, not opened yet |
| ro-drums-909 | TR-909 | `aumu/R909/Lmus` | 0 / 11 | ROM present, heard playing |
| ro-mono-101 | SH-101 | `aumu/R101/Lmus` | 0 / 1 | voice mode: the SH-101 zip is the known bad dump |
| ac-digital-vc | Virus C | `aumu/Avrc/Lmus` | **1** / 3 | full, v6.6 (tested in the app) |
| al-fx-quadgt | QuadraVerb GT | `aumf/Aqvg/Lmus` | 1 / 1 | not checked |

All six pass `auval`. In voice mode a machine sounds the same from MIDI, but its own sequencer,
arpeggio and panel keys do not work.

Each plugin gives the host 128 fixed parameters (`p001` to `p128`) that take the machine's control
names, so automation survives plugin updates.

To rebuild after `git pull` in the Lemus repo:
`cmake --build build/cmake -j --target plugin_tb303_All plugin_tr909_All plugin_tr808_All plugin_virusc_All plugin_qvgt_All plugin_sh101_All`.
The build copies the plugins over the installed ones. Quit LoopStudio first, or configure with
`-DLEMUS_COPY_PLUGINS=OFF`. If a host still sees the old version, run
`killall -9 AudioComponentRegistrar`.

## Backlog

Priority: **P1** blocks a machine, **P2** affects normal use, **P3** is a feature.

### P1-1. The Virus C plays as an effect, so it gets no notes

**Done 2026-11-17.** `AudioUnitEffect.isInstrument` reads the component type
(`kAudioUnitType_MusicDevice`). Test `aSynthWithAnInputBusIsAnInstrumentAndGetsTheNotes`
(`Tests/LoopStudioEngineTests/InstrumentWithInputTests.swift`) registers a fake `aumu` with an input bus
and renders its note through the plan. Original text follows.

- The engine decides "instrument" from the bus layout: `AudioUnitEffect.isInstrument` is
  `unit.inputBusses.count == 0` (`Sources/LoopStudioEngine/AudioUnitEffect.swift:73`).
- The Virus C is an `aumu` with one audio input bus (its EXT IN). So the engine puts it into the
  effect chain (`Sources/LoopStudioEngine/RenderPlan.swift:728`), and `noteSink` never sends it MIDI.
- The app decides differently: `AppModel.isInstrument` also accepts the `aumu` prefix
  (`Sources/LoopStudioApp/AppModel.swift:1631`). The UI places the Virus C as the track's instrument,
  but the engine plays it as an effect. The result is a silent track with no warning.
- The device card label uses the engine value (`Sources/LoopStudioApp/DevicePanel.swift:394`), so it
  shows "Audio Unit effect".
- Fix: take the type from the component description (`componentType == kAudioUnitType_MusicDevice`).
  `AudioUnitInfo.isInstrument` already does this from the identifier
  (`Sources/LoopStudioEngine/Devices.swift:10`). Keep the input bus enabled for an instrument that
  has one. Feed it silence, or later the track's audio for the EXT IN.
- Done when: the Virus C on a MIDI track plays clip notes, and its card says "Instrument". Add an
  engine test with a fake `aumu` that has an input bus.

### P1-2. Out-of-process loading and the ROM folder

**Answered 2026-11-17: the hosting process reads the ROM folder.** The 303 and the Virus C play notes
out of process (`theLemusMachinesPlayOutOfProcess`, runs with `LOOPSTUDIO_LEMUS=1`, half a minute).
The test keeps real-time pace on purpose, which found the next item.

### P1-3. The Virus C is silent in a bounce (found 2026-11-17)

- The Virus C boots its firmware on a thread of its own (`VirusCProcessor` `m_boot`) and its
  `processBlock` clears the buffer until `m_ready`. A bounce renders faster than real time from the first
  frame, so a fresh offline instance gives silence for the first seconds, or for the whole bounce of a
  short clip. In the live engine it plays after about four seconds.
- LoopStudio side, done: `OfflineRender.prepare` sets `isRenderingOffline` on every hosted unit.
- Lemus side, open: in non-realtime mode `processBlock` should wait for the boot (`waitForBoot()` when
  `isNonRealtime()`), so a bounce holds until the machine is ready. One line in
  `machines/virusc/plugin/PluginProcessor.cpp`, then rebuild.
- Test idea for later: bounce a Virus C clip after the Lemus change and expect sound.

- LoopStudio loads plugins out of process by default (`Sources/LoopStudioEngine/PluginHost.swift:41`,
  `.loadOutOfProcess`).
- Not tested: whether the macOS hosting process may read `~/Library/Application Support/Lemus/ROMs`.
  If it may not, every machine falls back to voice mode, and the Virus C does not run at all.
- Test: load the 303 and the Virus C, open the plugin window, and read the bar. `VOICE MODE` or a
  missing-ROM message on the 303 means the ROM is not readable from there.
- If it fails: allow in-process loading per plugin (a device setting or a per-manufacturer list), or
  find which folder the hosting process can read.

### P2-1. Host sync of the machines' own sequencers

- The 303, 808, 909 and (with a good ROM) the 101 have their own sequencers. The SYNC pill on the
  plugin's bar makes the firmware follow the host transport: MIDI clock, start or song position and
  continue, and stop (see the TR-909 README, "Sync").
- LoopStudio already gives tempo, beat and transport to plugins (`musicalContextBlock` and
  `transportStateBlock`, `AudioUnitEffect.swift:91-109`). `cycleStart` and `cycleEnd` are always 0.
- Test: SYNC on, then play in LoopStudio. The machine must run in tempo, stop with the transport,
  and start at the right step after a jump to bar 2. Test a tempo change while playing, and a loop
  in the arrangement, where the `changed` flag and the song position matter.

### P2-2. Project state: patterns and big states

**Done 2026-11-17, for the parts that need no plugin window.** Tests `the303StateRoundTripKeepsAKnob`
and `theLemusStateSizes` (`Tests/LoopStudioEngineTests/LemusTests.swift`, run with `LOOPSTUDIO_LEMUS=1`).
Original text follows the findings.

- The 303 round trip works. The test moves CUT OFF (slot `p002`, AU address 3384258) to 0.25, reads
  `fullState`, restores it into a fresh instance, and gets the value back. The 303 gives 128 writable
  parameters. The first 19 carry the machine's names: Tuning, Cut Off Freq, Resonance, Env Mod, Decay,
  Accent, Volume, Waveform, Tempo, Mode, Track / Patt. Group, Sync to Host, TM1 to TM6, Full Cut Off.
  The rest are named `Slot 20` to `Slot 128` and can be hidden (see P3-2). A pattern travels in the
  same state: the `machine` property of the JUCE value tree holds the battery-backed RAM as base64
  (`machines/tb303/plugin/PluginProcessor.cpp:534`). The panel part of the test stays manual.
- State sizes, as `savedState()` writes them (binary property list):

  | Machine | At load | After 1 s (Virus C: 6 s) of rendering |
  |---|---|---|
  | 303 | 6,442 bytes | 6,442 bytes |
  | 808 | 8,573 bytes | 8,573 bytes |
  | 909 | 13,555 bytes | 13,555 bytes |
  | Virus C | 2,491 bytes | 221,021 bytes (0.21 MB) |

- The Virus C is far below 2 MB. Its state is small until the firmware has booted (about four seconds
  in the live engine), then it is 216 KB. A save in those first seconds stores the small state. Open
  question: what the Virus C restores from the small state; probably its factory state.
- Autosave: `save()` calls `captureStates()`, which reads `fullState` of every hosted plugin on the main
  thread (`PluginHost.states()`). `ProjectPackage.write` then encodes each track as JSON, with the state
  as base64 (4/3 of its size: 295 KB for one Virus C), and writes a track file only when its bytes
  changed. 1.5 s after an edit that is one 221 KB read and one JSON encode per Virus C: no problem.
  Ten Virus C instances give about 3 MB of track files; still fine.
- Journal: a plugin state never enters the journal through `captureStates`, because it writes into
  `project` directly, not as a command. A state goes into a journal line only when a command carries a
  `DeviceSlot` with one: a paste from the device clipboard (`snapshot` in `AppModel+DeviceClipboard.swift`)
  or a preset load (`setDevices` in `AppModel+Presets.swift`). One Virus C paste is one 295 KB line with
  an fsync. No problem at these sizes.

- Each machine keeps its patterns in emulated RAM, and `savedState()` stores `fullState` in the
  project (`AudioUnitEffect.swift:231`).
- Test: write a 303 pattern on the panel, save, quit, reopen. The pattern must be there.
- Check the state size of the Virus C (flash and RAM may be several hundred KB) and what it does to
  project files, autosave (1.5 s after an edit) and the journal.

### P2-3. CPU and long tails

- Lemus models circuits. The README of the SH-101 measures about 4 to 8 % of one core per instance at
  48 kHz, and 0.5 % when idle. The Virus C emulates a DSP and is probably heavier.
- The SH-101 tail lasts up to 36 s with RELEASE at maximum. Check that stop (`silenceNotes`, CC 123
  and CC 120) silences each machine.
- Test: all five instruments on five tracks, playing. Watch `missedLocks` and the CPU meter, in
  process and out of process.

### P2-4. MIDI channels

**Done 2026-11-17.** Test `theLemusMachinesAnswerOnTheseMIDIChannels`
(`Tests/LoopStudioEngineTests/LemusTests.swift`, `LOOPSTUDIO_LEMUS=1`, about 50 s at real-time pace).
Original text follows the findings.

- The 303 and the 909 answer on channel 1 (status 0x90), channel 10 (0x99) and channel 2 (0x91). A
  clip on channel 1 reaches both. No change in LoopStudio is needed.
- Peaks, note-on velocity 100 (303: note 48; 909: note 36): 303 0.125 / 0.129 / 0.127 on channels
  1 / 10 / 2; 909 0.606 / 0.608 / 0.596. The 909 snare, note 38 on channel 1: 0.773.
- Why: the 303 plays its voice from MIDI with no channel setting. The 909 firmware is omni at power-on
  with basic channel 10 (`machines/tr909/docs/firmware.md`, "MIDI"). SHUFFLE/FLAM + a step key n in
  track play mode sets the receive channel to n and omni off. That setting lives in the 909's RAM, so
  a state from another host can be on one channel only. The 808 plays its voices from MIDI like the
  303; not measured.
- Drum map of the TR-909 (`machines/tr909/docs/firmware.md`, "The voice board latches"; also in its
  README). Velocity sets the accent code: 50 is the sequencer's normal level, 80 its accent.

  | Note | Voice |
  |---|---|
  | 35, 36 | BD, bass drum |
  | 38, 40 | SD, snare drum |
  | 41, 43 | LT, low tom |
  | 45, 47 | MT, mid tom |
  | 48, 50 | HT, hi tom |
  | 37 | RS, rim shot |
  | 39 | HC, hand clap |
  | 42, 44 | CH, closed hi-hat |
  | 46 | OH, open hi-hat |
  | 49 | Crash cymbal |
  | 51 | Ride cymbal |

  Other notes are ignored. Note-off and velocity 0 are ignored.

- Drum map of the TR-808 (`machines/tr808/plugin/PluginProcessor.cpp`, `noteVoice`; General MIDI
  numbers, as Roland's TR-08). Velocity 100 or more is an accent. The conga, claves and maracas notes
  play the shared rows; the panel's voice switch picks the sound.

  | Note | Voice |
  |---|---|
  | 35, 36 | BD, bass drum |
  | 38, 40 | SD, snare drum |
  | 37, 75 | RS, rim shot (75: claves, same row) |
  | 39, 70 | CP, hand clap (70: maracas, same row) |
  | 41, 43, 64 | LT, low tom (64: low conga, same row) |
  | 45, 47, 63 | MT, mid tom (63: mid conga, same row) |
  | 48, 50, 62 | HT, hi tom (62: hi conga, same row) |
  | 42, 44 | CH, closed hi-hat |
  | 46 | OH, open hi-hat |
  | 49, 57 | CY, cymbal |
  | 56 | CB, cowbell |

  Other notes are ignored.

- Clip notes keep their channel in the status byte. Check which channel each machine listens on
  (the TR-909 firmware has its own MIDI channel settings) and whether a clip on channel 1 reaches it.
- The drum machines play their voices from fixed notes. Note the note map of the 808 and 909 per
  machine in the Lemus READMEs, and consider a drum-name view in the piano roll.

### P3-1. Separate outputs of the 808 and 909

- The engine renders output bus 0 only. By default every voice of the 808 and 909 is in that main
  mix, so nothing is lost.
- Trap: a cable plugged into a MULTI OUT jack on the plugin's rear panel takes that voice out of the
  main mix, as on the real unit. In LoopStudio that voice then goes silent.
- Feature: show buses 1 and up as extra sources, for example as return tracks or "Audio From" choices,
  like Live's multi-output instruments.

### P3-2. Knobs for AU parameters, and MIDI map

- Open since 2026-11-02: AU parameters have no knobs in LoopStudio's UI, so MIDI map mode cannot
  reach them. Automation lanes already list them (`automatableParameters`, up to 256).
- Lemus helps here: its 128 slots keep their addresses across updates, and unused slots probably
  have no machine name. Hide those slots.

### P3-3. MIDI for an AU effect (the QuadraVerb GT)

- An `aumf` is an effect that also takes MIDI. LoopStudio's `EffectPlan` sends it none. Only needed if
  you want program changes or CCs into the QuadraVerb GT from a clip.

### P3-4. MCP

**Done 2026-11-17.** Test `anAssistantCanBounceA303Line`
(`Tests/LoopStudioControlTests/LemusControlTests.swift`, `LOOPSTUDIO_LEMUS=1`). The calls: `track_add`
(midi), `command_apply` with `insertDevice` for `aumu/R303/Lmus`, `clip_create`, `notes_set` with four
notes, `render_bounce`. Result: 2.25 s, peak -18.1 dBFS, RMS -35.9 dBFS, no warnings. The bounce
loads the 303 in its own offline instance, out of process. Note: `device_add` takes built-in devices
only; an Audio Unit goes in through `command_apply` with `insertDevice`, as the tool's description says.
A `device_add` that also accepts an AU identifier would make this one call. Original text follows.

- `device_add` with the identifiers in the table above loads a machine, which lets the assistant build
  a 303 and 909 set. A test: load `aumu/R303/Lmus` on a MIDI track, write a clip, render a bounce and
  check that it is not silent.
- MCP cannot see a plugin's voice mode. A plugin window screenshot is the only check.

## Not needed any more

The standalone apps and the temporary "Claude MIDI" virtual source (a scratchpad tool) were for the
first test only. Inside LoopStudio the tracks send the notes.
