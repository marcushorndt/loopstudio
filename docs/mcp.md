# Using loopstudio from an agent (MCP)

`loopstudio mcp` is a Model Context Protocol server. It speaks JSON-RPC 2.0 over stdin and stdout, one message per line. Logs go to stderr. Nothing else is written to stdout.

## Two modes: the running app, or project files

- **The app is running:** `loopstudio mcp` finds the app's socket and forwards every message to it. The agent then edits the project that is open on screen. Each change shows and sounds at once, lands in the app's undo history, and autosaves like a click. The app adds the tools `app_status`, `transport` and `launch`. `project_open` and `project_new` switch the app to another project.
- **No app:** `loopstudio mcp` works on project files on its own, with the same tools (minus the three app tools). Open such a project in the app afterwards.

`--files` forces the file mode even when the app runs. `--live` insists on the app and fails when it is not running. The socket is `~/Library/Application Support/LoopStudio/mcp.sock` (override with `LOOPSTUDIO_SOCKET`); it is owned by the user with mode 600. The app's status line reports when the socket could not be opened.

## Set up

Build once:

```
swift build -c release
```

Add the server to Claude Code:

```
claude mcp add loopstudio -- /Users/marcushorndt/Documents/repos/loopstudio/.build/release/loopstudio mcp
```

Or in a client config file (Claude Desktop and others):

```json
{
  "mcpServers": {
    "loopstudio": {
      "command": "/Users/marcushorndt/Documents/repos/loopstudio/.build/release/loopstudio",
      "args": ["mcp"]
    }
  }
}
```

To open a project at start, add `"--project", "/path/to/MyProject.loopstudio"` to the arguments.

## Tools

| Tool | Reads or changes | What it does |
|---|---|---|
| `project_new` | creates | New project folder (`.loopstudio`). Never overwrites. |
| `project_open` | reads | Open a project. Restores unsaved changes from the crash journal. |
| `project_save` | writes | Write the project files, empty the journal. |
| `project_info` | reads | Summary: tempo, tracks, ports, revision, unsaved state, problems. |
| `track_list`, `track_get` | reads | Tracks, or all data of one track. |
| `command_apply` | changes | Apply one edit command (JSON). Any command; one undo step; `batch` for several. |
| `command_examples` | reads | A valid example for every command. |
| `undo`, `redo` | changes | Step through the history. |
| `audio_devices` | reads | Sound cards, channel names, rates, buffer sizes, latency. |
| `midi_endpoints` | reads | MIDI inputs and outputs with unique IDs. |
| `io_resolve` | reads | Preview how ports map to the connected sound cards. |
| `follow_simulate` | reads | Run the follow-action dice many times and count outcomes. |
| `tempo_convert` | reads | Ticks, seconds and frames, using the tempo map. |
| `app_status` | reads | App only: transport, position, tempo, open project, selection, session clips that play, Link peers, status line. |
| `transport` | changes | App only: `play`, `stop`, `pause`, `continue`, `seek` (with `tick`). |
| `launch` | changes | App only: start a slot (`track` + `slot`), a `scene`, or stop clips (`stopTrack`, `stopAll`). |
| `ui_state` | reads | App only: the screen in its own words: view, selected track with its devices (knobs, values), slots, the marked device, selected clips, the open panel. |
| `patch_read` | reads | The text of a Patch device (the programmable built-in device, `docs/scripting.md`), its knobs and op count, or its compile error. |
| `patch_check` | reads | Compiles a patch text without placing it: the knobs, or the error with its line. The tool description holds the language in short. |
| `patch_write` | changes | Compiles a text (or a graph document) and, when it is good, puts it on a Patch device and names the device after it. The sound keeps playing; delay lines carry over. |
| `patch_modules` | reads | The module kinds of the modular patch (`docs/patcher.md`): ports with types, ranges and units, settings. |
| `patch_edit` | changes | Steps on the graph of a Patch device, in order (add, remove, move, connect, disconnect, set, setting, source, label, expose, rename, group, ungroup; `"in":"sub1"` runs a step inside a Sub), compiled and put on the device as one undo step. A text becomes a graph with one Script module first. |
| `track_add`, `track_rename`, `track_set`, `track_remove` | changes | Named track edits. A track is an id, a name, `master` or its position from 1. |
| `device_add`, `device_remove`, `device_move`, `device_bypass`, `param_set` | changes | Named device edits. A device is an id, a name or its position; a parameter its key or name. |
| `clip_create`, `clip_set`, `clip_remove`, `notes_set` | changes | Named clip edits. A clip is an id, a name or `<track>/slot N`. |
| `audio_notes` | reads | The notes in an audio clip's file (also the notes of a chord): key, name, pitch with cents, start and end in seconds, peak level, and the note's change. |
| `audio_notes_edit` | changes | Changes notes by key (pitch, shift, stretch, gainDb, muted), `tune` to the nearest semitone, `reset`. Renders a new file from the original and switches the clip in one undo step. |
| `send_set`, `tempo_set`, `loop_set` | changes | Sends, the tempo at the start, the loop region. |

Every changing tool returns a **receipt**: the command, the revision before and after, and the touched values read back from the project after the change ("Drums › Delay › Feedback: 0.40 to 0.55"). The receipt is the proof; the arguments are not. A name that matches several things is an error that lists them, so ask instead of guessing.

`command_apply` takes every edit the app can do: tracks and routing (`setOutput` to a bus or into an audio track, `setSends`, `setInputTrack`, `setNoInput`, `setMonitor`, `setSendsOnly`), clips and session slots, follow actions, devices and their parameters, MIDI notes, automation on tracks and in dummy clips, warping (`setAssetTempo`, `setClipWarp`), tempo, loop and launches. `command_examples` shows a valid JSON for each.

Resources: `loopstudio://help/ui` (the words of the screen) and `loopstudio://help/patch` (the patch language on one page) always; `loopstudio://project/summary` and `loopstudio://project/full` when a project is open.

## Example

```
project_new   {"path": "/Users/me/Music/Demo.loopstudio"}
command_examples
command_apply {"command": {"insertTrack": {"index": 0, "track": { ... }}}}
command_apply {"command": {"setSlot": {"track": "<id>", "index": 0, "slot": { ... follow actions ... }}}}
follow_simulate {"track": "<id>", "slot": 0, "launches": 2000}
project_save
```

## Rules the server keeps

- A rejected command changes nothing and returns `isError: true` with the reason.
- Only absolute paths ending in `.loopstudio` are accepted.
- Positions are in ticks: 960 per quarter note, 3840 per 4/4 bar.
- The server handles one request at a time.
