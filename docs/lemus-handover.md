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

- `device_add` with the identifiers in the table above loads a machine, which lets the assistant build
  a 303 and 909 set. A test: load `aumu/R303/Lmus` on a MIDI track, write a clip, render a bounce and
  check that it is not silent.
- MCP cannot see a plugin's voice mode. A plugin window screenshot is the only check.

## Not needed any more

The standalone apps and the temporary "Claude MIDI" virtual source (a scratchpad tool) were for the
first test only. Inside LoopStudio the tracks send the notes.
