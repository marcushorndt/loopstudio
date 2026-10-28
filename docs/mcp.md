# Using loopstudio from an agent (MCP)

`loopstudio mcp` is a Model Context Protocol server. It speaks JSON-RPC 2.0 over stdin and stdout, one message per line. Logs go to stderr. Nothing else is written to stdout.

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

Resources (when a project is open): `loopstudio://project/summary` and `loopstudio://project/full`.

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
