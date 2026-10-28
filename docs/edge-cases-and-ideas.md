# Edge cases and creative ideas

Status: 2026-10-28. Companion to `architecture.md`.
Each edge case has a **rule**: what the system does. Each rule becomes a test.
Items marked **(design change)** changed `architecture.md`.

## A. Time and tempo

| Case | Rule |
|---|---|
| Tempo ramp inside a clip | Clip is warped against the tempo map, not a single tempo. The warp cache key includes the tempo segment. |
| Time signature change mid-bar | Not allowed. The change snaps to the next bar line. |
| Tempo below 20 or above 999 BPM | Clamp at the edit. A file with such a value loads, and the tempo map clamps it and logs it. |
| Loop region shorter than one audio block | Renderer splits the block at each wrap. A 1-frame loop must not hang the thread. |
| Loop region of length 0 or negative | Rejected by the command. Loader repairs a bad file to "loop off". |
| Loop wrap inside a block | Block is split at the wrap frame; clip players, MIDI and automation all re-seek at that frame. |
| Start playback in the middle of a warped clip | Warper needs pre-roll. The rendered warp cache gives random access, so a seek is exact and free. |
| Count-in and pre-roll before bar 1 | Positions can be negative. `Tick` and `Frame` are signed. |
| Sample rate changes (44.1 to 48 kHz) | Plan rebuilds. Warp cache entries for the old rate stay valid under their own key. Tick positions do not change. |
| Very long project (10 h) | `Int64` frames never overflow. Tests cover 100 h at 192 kHz. |
| Video sync at 23.976 / 29.97 fps | Time code is a view over the tempo map. Drop-frame math has its own tested module. |
| Two tempo changes on one tick | Last one wins. Loader normalises. |

## B. Audio files

| Case | Rule |
|---|---|
| Corrupt or truncated file | Clip shows an error state, plays silence, keeps all its settings. Never a crash. |
| MP3 with a wrong length header | Decode once to find the real length. Store it in the analysis cache. |
| File has another sample rate than the project | Convert once on import into the cache (high-quality converter). Original stays untouched. |
| Mono, stereo, 5.1, 8-bit, 24-bit, float | Import converts to float. Channel count is kept; the mixer applies the pan law. |
| File changes on disk while open | Compare content hash on focus. Offer "reload" and keep the old audio until the user answers. |
| File in iCloud, not downloaded yet | Detect the placeholder. Request the download. Show "downloading". Never block the audio thread. |
| File larger than 4 GB | Streaming reader uses 64-bit offsets. Test with a sparse file. |
| Missing file after moving a project | Relink dialog. Search by content hash first, name second. |
| Clip offset beyond end of file | Clamp at load. Clip plays silence for the excess, no read past the end. |
| Two clips overlap on one track | Later clip wins. A short crossfade removes the click. User can change the fade. |
| Clip edge click | Every clip edge gets a default 2 ms fade (**design change**: clip fades are in the model). |
| Loop points in file metadata (Apple Loops, WAV "acid" chunk) | Read them as the *suggested* tempo and length. User edits override. |
| Unicode file names (NFC vs NFD) | Assets are stored by content hash, so the name is only a label. No problem when the project moves to Linux or git. |
| DC offset, near-silence, clipping at the source | Analysis flags them. No automatic change. |

## C. Graph, mixer, routing

| Case | Rule |
|---|---|
| Send from a bus back to a track that feeds it | The UI blocks the route and names the loop. The compiler also rejects it, so a hand-edited file cannot start a feedback loop. |
| Deliberate feedback (a delay return into itself) | Allowed only inside one plugin, never across tracks. |
| Delete a bus that has sends | Sends are removed in the same command. Undo restores both. |
| Delete a track that is a sidechain source | Same rule: the dependent slot shows "no source", keeps its settings. |
| Mono track into a stereo bus | Equal-power pan law (-3 dB centre, a project setting). |
| Plugin latency changes at runtime (a look-ahead limiter is switched on) | Plugin posts a latency change. Compiler recomputes PDC. Transport adjusts at the next block, with a click-free crossfade. |
| Record-armed track with input monitoring | Monitored path skips PDC to keep input latency low. Recorded audio is shifted back by the measured round-trip latency. |
| Solo, mute and sends | Solo mutes other tracks but keeps return tracks audible if a soloed track sends to them. "Solo-safe" flag for returns. |
| Plugin outputs NaN or Inf | A cheap check on plugin outputs. On a hit: mute that node, flag it, never let it reach the device. |
| Denormals (CPU spikes on silence) | Set flush-to-zero on the audio thread, add a tiny noise or DC offset in feedback paths. |
| Plugin is too slow (misses its time) | Per-node CPU watchdog. After repeated misses: bypass with a fade, show a warning, offer "freeze". Policy is a setting. |
| Plugin changes its channel layout | The graph compiler reads the layout at instantiate time. A change later triggers a recompile. |
| Bypass / enable a device while playing | 5 ms equal-power crossfade between dry and wet. No click. |
| Output above 0 dBFS | Mix is 32-bit float, so there is no internal clipping. Master meter shows the true peak. Clip only at the device. |
| Master track missing in a loaded file | Loader adds one. |
| Deep group nesting (1000 levels) | Depth limit of 16. |

## D. Plugins

| Case | Rule |
|---|---|
| Plugin hangs during instantiate | 10 s timeout. Slot shows "failed". App stays responsive. |
| Plugin crashes while rendering (AUv3 out of process) | Slot is bypassed, shown in red, audio continues. Offer "reload". |
| Plugin updated; parameter IDs changed | Automation points keep their old address and show as "orphaned" with the old name. User can remap. |
| Plugin missing on another Mac | Slot keeps the state blob, name, vendor and version. It plays bypassed. |
| Plugin has several outputs or sidechain input | Model allows many ports per slot. UI offers "split outputs to tracks". |
| Intel-only plugin on Apple Silicon | Detect the architecture at scan. Host it in a Rosetta helper later, or show "not supported". |
| `maximumFramesToRender` smaller than our block | Set it to our maximum block at instantiate. If the plugin refuses, split the block. |
| Editor window opens on the wrong thread | All editor work on the main thread. A watchdog marks a stalled editor. |
| State restore fails | Load defaults, flag the slot, keep the blob in the project so nothing is lost. |
| Plugin allocates in its render call | We cannot fix it. The watchdog and the freeze option are the protection. |

## E. MIDI

| Case | Rule |
|---|---|
| Stuck notes on stop, seek, loop wrap, clip trim, clip delete, mute, plugin removal | One function, `silenceAll(track)`, sends note-offs for every sounding note plus CC 64 (sustain) off, pitch bend centre, CC 123. Each trigger above has a test. |
| Note-off and note-on on the same tick | Note-off first. |
| Overlapping notes of the same pitch | Count-based voice tracking, so the first note-off does not cut the second note. |
| Note-on with velocity 0 | Treated as note-off (MIDI 1.0 rule). |
| MIDI 1.0 values into MIDI 2.0 | Scale with the standard bit-replication rule. Tested at the ends of the range. |
| Device unplugged while playing | Notes held by that device are released. A hot-plug watcher reconnects by the device's unique ID, not its name. |
| Two devices with the same name | Identify by unique ID and entity. UI shows both. |
| Recording while looping | Each pass becomes a take. The user chooses to merge, keep latest or comp. |
| Quantise with a swing and a groove | Stored as a non-destructive transform on the clip. The original notes stay. |
| Huge SysEx | Capped length. Sent from a worker thread, never the audio thread. |
| MIDI clock input jitter | Smooth with a filter. Tempo follow is optional and shows a "locked" state. |

## F. Devices, system and performance

| Case | Rule |
|---|---|
| Output device unplugged | Switch to the default device. If none: keep the transport clock running on a dummy clock, so recording and automation timing do not stall. |
| Another app changes the device sample rate | Notification arrives; plan rebuilds; no restart. |
| Bluetooth headphones (high latency) | Report the output latency. Never shift the timeline. Show a warning for recording. |
| Mac sleeps and wakes during playback | Stop transport on sleep. Re-open the device on wake. |
| App goes to the background | Opt out of App Nap and automatic termination while playing. |
| Low Power Mode or thermal throttling | Show a banner. Offer to raise the buffer size. |
| Audio thread priority on Apple Silicon | Join the device's `os_workgroup` so the scheduler treats our threads as part of the I/O deadline. |
| Microphone permission denied | Record button explains how to enable it. Playback is not affected. |
| Sandbox (if shipped) | Needs the audio-input entitlement, user-selected file access, security-scoped bookmarks for sample folders, and a check that plugin hosting still works. |

## G. Project files and editing

| Case | Rule |
|---|---|
| Power loss during save | Atomic write (temp file, then rename). Nothing half-written. |
| Crash between two saves | **Command journal** (**design change**): every command is appended to a journal file before it is applied. On start, replay the journal over the last save. |
| Project saved by a newer version | Open read-only with a clear message. Never rewrite a file in a format we do not know. |
| Same project open twice | Lock file with process ID. Second open is read-only. Stale locks (dead PID) are ignored. |
| Duplicate IDs after copy and paste | Paste always assigns new UUIDs and rewrites internal references. |
| Undo after a plugin was removed | The command keeps the plugin state blob. Undo restores the slot, bypassed if the plugin is gone. |
| Undo while a background job (analysis, warp render) is running | Jobs carry the project revision. A result for an old revision is dropped. |
| A drag creates 200 commands | Coalesce into one undo step. |
| Git merge of two edits | **(design change)** One file per track (`tracks/<uuid>.json`), one note or point per line, sorted. Two people editing different tracks merge cleanly. |
| Project with 500 tracks | Lazy load of clip audio. UI virtualises rows. |
| Case-insensitive file system | All paths inside the package are lowercase hashes or UUIDs. |

## H. UI

| Case | Rule |
|---|---|
| Zoom from 1 sample to 1 hour | Waveform uses a multi-level peak cache. Below 1 sample per pixel, draw interpolated samples. |
| Dragging a clip to negative time | Clamped, unless pre-roll is on. |
| VoiceOver and keyboard only | Timeline items are accessibility elements. Every action has a key command and a menu item. |
| Many windows (plugin editors) | Window state is stored per project and restored. |
| Retina, external display, different scale | Waveforms are drawn at the backing scale. |
| Dark and light mode | Colours come from asset catalog tokens, no hard-coded values. |

## I. Creative ideas that fit this stack

1. **The agent API is the command API.** The project model is plain data and every edit is a JSON command. Expose the same commands as an MCP server and a CLI. Then Claude can "build a 16-bar loop from these samples" or "put a send on every drum track" with the same code path as the UI. This matches your existing MCP workflow.
2. **Git-native music.** A branch is an alternate arrangement. `loopstudio diff` shows "bar 17-24: snare clip moved, reverb send +3 dB". Your Gitea setup already handles the rest.
3. **Command journal as a time machine.** Because every edit is logged, you get crash recovery, a full session replay, and a "go back to yesterday 15:00" scrubber for free.
4. **Capture, always on.** Keep the last 60 s of MIDI and audio in a ring buffer even when not recording. A "capture" key turns what you just played into a clip. (Live has this for MIDI. We can do audio too.)
5. **Incremental bounce.** The render plan is deterministic and hashable. Cache each track's rendered audio under the hash of its plan. Export only re-renders tracks that changed. Freeze comes for free.
6. **Beat grid to video.** You already edit video in ContentMaschine Studio. Export the beat grid and markers as a cut list for your `edit-video-from-cutlist` skill, or put a video track in the timeline (AVFoundation) and score to picture. A shared JSON timeline schema with the browser editor makes both directions possible.
7. **Smart sample browser.** `SoundAnalysis` and Core ML label loops (kick, vocal, pad). A key and tempo detector pitches and stretches any loop to the project key on audition. A Core ML stem-separation model (converted Demucs-type model) could split a loop into parts. That model is third-party; the feature is optional.
8. **Resample the Mac.** Core Audio taps record the output of another app (a browser, a video call) straight onto a track.
9. **iPhone and iPad as partners.** `LoopStudioCore` has no macOS-only code, so it also builds for iOS. An iPad can show Session view; an iPhone can be a Bluetooth MIDI pad controller. Network MIDI works over Wi-Fi.
10. **Spatial audio.** `AVAudioEnvironmentNode` for 3D panning and head-tracked monitoring on AirPods. ADM export for Dolby Atmos later.
11. **Automation by gesture.** Record trackpad, mouse or MIDI-knob movement, then thin the points with a curve-fit pass (Ramer-Douglas-Peucker). You get a clean lane, not 2000 points.
12. **Parameter morphing.** Store parameter snapshots of a device and morph between them along a lane. This is the "settings animation" idea taken further.
13. **Panic key and `doctor`.** Cmd-period silences everything and resets every device. `loopstudio doctor` checks devices, permissions, plugins and disk speed, and prints a fix for each problem.
14. **Reproducible renders.** Same project + same version = same bytes. A render report stores the plan hash, so you can prove a master was not changed.
15. **Practice mode.** A loop with a gradual tempo ramp from 70% to 100%, with the key kept. A direct use of the tempo map and the warper.

## J. Changes this made to the architecture

1. Clip fades and crossfades are model fields (section 5).
2. A write-ahead **command journal** joins the project store (sections 5 and 13).
3. The package stores one file per track, with stable line ordering, for merge-friendly git history (section 13).
4. A per-node CPU watchdog, NaN guard and bypass crossfade join the render rules (section 7).
5. A `silenceAll(track)` function is the single exit path for all stuck-note cases (section 9).
6. A dummy clock lets the transport run without a device (section 12).
7. Background job results carry a project revision number (section 14).
8. `loopstudio doctor` and the agent API join the CLI target (section 3).
