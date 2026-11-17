# LoopStudio

A native macOS DAW in the spirit of Live: a session view with clips, an arrangement, a mixer,
device chains with Audio Units, a patcher, MIDI mapping, Ableton Link, and a control surface for
assistants over a local socket.

## Requirements

- macOS 26 on Apple Silicon
- Xcode 26 (Swift 6)

## Build and run

```
git clone --recurse-submodules <this repository>
cd loopstudio
scripts/run-app.sh          # debug build, starts the app
scripts/install-app.sh -j 2 # release build into /Applications/LoopStudio.app
swift test                  # the tests
```

The app runs without any plugin. Audio Units in `~/Library/Audio/Plug-Ins/Components` show up
in the device browser.

## Documents

`docs/architecture.md` is the map of the code. `docs/midi.md`, `docs/patcher.md`, `docs/mcp.md`
and `docs/scripting.md` cover one area each.

## Licence

GNU GPL v3, see `LICENSE`. `THIRD-PARTY.md` lists what the app links and which plugins live in
their own repositories.
