# An assistant in the app: the exploration and the plan

2026-11-05. Marcus asked for an assistant that does the work in the app: it knows the available tools, it knows
the UI (when the user describes what they want, it knows what they mean), and it is deterministic in the sense
that it never claims an edit it did not make. This document sets the architecture and the stages.

## 1. What is already there

The app is already controllable from outside (`docs/mcp.md`):

- `loopstudio mcp --live` forwards every tool call over a socket into the running app. 20 tools exist:
  project, tracks, `command_apply`, `command_examples`, `effect_catalog`, `asset_import`, `sample_drop`,
  `render_bounce`, `audio_devices`, `midi_endpoints`, `io_resolve`, `follow_simulate`, `tempo_convert`, and in
  the app `app_status`, `transport`, `launch`.
- Every edit is a `Command` (174 cases). All commands go through one `ProjectStore` actor. The store validates,
  applies, bumps a `revision`, and records one undo step. A rejected command changes nothing.
- `app_status` reports the transport, the open project and the selection.
- Claude Code and Claude Desktop can drive the app through this today.

What is missing for an assistant in the app: a pane, a model call, a snapshot of the UI in the UI's own words,
and above all a proof mechanism. The model must not be the one who reports what happened.

## 2. The three properties, and how each one is built

### 2.1 It knows the tools: the tool layer is the only hand

The assistant has no other way to change anything than the tool layer. It cannot touch the model, the files or
the engine. This is already true for MCP, and the in-app assistant reuses the same `ToolRegistry`.

Two additions make the tools usable by a language model:

- **Named tools for the common edits.** One `command_apply` with 174 JSON shapes is hard for a model. The common
  edits get a flat, named tool each: `track_add`, `track_rename`, `track_set_volume`, `device_add`, `device_remove`,
  `device_move`, `param_set`, `clip_create`, `clip_set_loop`, `notes_add`, `send_set`, `tempo_set`. Each one is a
  thin wrapper that builds a `Command`. Every tool carries `strict: true` and a closed schema, so the arguments
  always validate. `command_apply` stays for the long tail.
- **A catalog the model reads, not guesses.** `effect_catalog` already lists every built-in device with its
  parameter keys, ranges and units from `EffectSpec`. Audio Units report their parameters through the host. The
  model sets `param_set(device, key, value)` with a key from the catalog; an unknown key is a rejection, not a
  silent no-op.

### 2.2 It knows the UI: a snapshot in the UI's words, plus a glossary

The user speaks in the words of the screen: "the delay on the drums", "the second slot", "the marked device",
"the inspector". The assistant must map these words to IDs without guessing.

- **`ui_state`.** One read tool returns the screen as a structured snapshot: the open view (Session or Arrangement),
  the selected tracks, the marked device, the selected clips and slots, the open panels (device chain, sample
  editor, piano roll), the scroll range of the arrangement, the sidebar section. Every item carries its id, its
  name and its position (track 3, slot 2, device 2 of 4). Devices come with their visible knob names and values.
  This extends `app_status`. The model calls `ui_state` first in every turn that refers to the screen.
- **A glossary resource.** `loopstudio://help/ui` maps the words the UI uses to the model's concepts: "inspector"
  and "device panel" are the device chain of the selected track; "slot" is a session slot; "scene" is a row; "the
  highlighted device" is the marked device. The glossary also lists what the app cannot do, so the model says
  "not possible" instead of inventing a tool.
- **Resolution rules in the system prompt.** Resolve a reference from `ui_state` and the project. One match: act.
  Several matches: ask one question with the candidates by name and position. No match: say so. Never invent an
  id. These rules are text, so they do not make the model deterministic. The receipt mechanism below is what
  keeps a wrong resolution visible and undoable.

### 2.3 It never lies about an edit: the host reports, not the model

This is the core design. A language model is not deterministic and can describe an edit that did not happen.
The fix is structural: the model's prose carries no authority. The app shows what the store did.

- **A receipt per tool call.** Every changing tool returns a receipt built by the store: the command, the
  revision before and after, the undo step id, and a read-back of the touched values after the apply (the new
  name, the new parameter value, the new device list). The read-back comes from the project after the
  change, not from the arguments. A rejected call returns the rejection and the unchanged revision.
- **The transcript renders receipts, not claims.** The pane shows two kinds of rows. A receipt card is a fact
  from the store: "Drums › Delay › Feedback: 0.35 to 0.55 (rev 1232)". The model's text is commentary and is
  styled as such. A turn with no receipt cannot show a "done" state. The user never has to trust the prose.
- **One turn, one undo step.** All commands of one assistant turn are wrapped in one `batch`, so "Undo" in the
  app (and an "Undo" button on the turn) reverts the whole turn at once. A single wrong resolution is one key
  press away from gone.
- **Claim check.** When the model's final text contains an edit verb (set, added, moved, removed, renamed) and the
  turn holds no receipt, the host appends a notice: "No change was made in this turn." This is a heuristic on
  top of the structural rule, not a replacement for it.
- **Plan mode.** A toggle "Ask before changes" makes every changing tool return "pending" and shows the planned
  commands as cards with Apply and Skip. Apply runs the commands through the same path and produces the same
  receipts. Destructive commands (delete track, delete clip, clear automation) always require Apply, regardless
  of the toggle.

### 2.4 Determinism: what is and what is not

The model is not deterministic. The pipeline around it is:

- The same command on the same project gives the same project (this is what the store guarantees today, and the
  `Command` tests check).
- The receipt is derived from the project state, so the same edit always produces the same receipt.
- A conversation is replayable: the transcript stores every model output and every tool result. The test
  harness replays recorded model outputs against a fixture project without a network call and checks the final
  project and the receipts. A change in the tool layer that breaks a recorded conversation fails the test.

## 3. Where the model runs

| Option | Pro | Contra |
|---|---|---|
| **In the app, Claude API over HTTPS** | Pane in the app, the UI snapshot and receipts are native, streaming text, one key in the Keychain | Needs a key and a network; costs per turn |
| Claude Code or Desktop over MCP (today) | Zero work, full agent harness, file access | A second window, no UI snapshot, no receipt cards, the agent's prose is the report |
| A local model (MLX or Ollama) | Offline, free | Tool calling is weak at this size; a wrong tool call per minute is worse than no assistant |

Decision: build the in-app pane on the Claude API, and keep the MCP path with the same tool layer. `ui_state`,
the named tools and the receipts serve both; an external agent gets the honesty for free.

Model and wire (from the `claude-api` skill, checked 2026-11-05): `claude-opus-5-5` as the default, selectable
in the settings. Raw HTTPS from Swift with `URLSession` (no Swift SDK exists), streaming, `tool_choice: auto` (a
forced tool choice is rejected on this model family), `strict: true` on every tool, `output_config.effort`
`medium` for chat turns and `high` for multi-step edits. Thinking stays on (it cannot be turned off on this model);
the raw chain of thought is never returned. The key lives in the Keychain under the app's service name and is
entered once in the settings. The app never writes it to a file or a log. Every request carries the server-side
fallback option, so a refusal routes to a sibling model instead of ending the turn.

## 4. The pane

A third sidebar tab "Assistant", at the place where Live has nothing. Live's browser is on the left, so the
assistant sits there too and the main views keep their width. Content from top to bottom:

- The transcript: user rows, model commentary rows, receipt cards (with an Undo button on the last turn), pending
  cards in plan mode, host notices.
- A one-line status: the model, the open project, "Ask before changes" toggle, the cost of this session.
- The input field. ⌘⏎ sends. While a turn runs, the field shows "Stop".

Everything the model did is also visible where it always is: the device chain updates, the undo history has
one step, the status line shows the last command.

## 5. Stages

### Stage 1: the honest tool layer (Control and App, no network)

- `Receipt` type in Control: command, revision before and after, undo id, read-back as JSON.
- `ProjectStore.apply` returns the new revision; a `readBack(for: Command)` in Core returns the touched values
  from the project after the apply.
- Named tools (`track_*`, `device_*`, `param_set`, `clip_*`, `notes_add`, `send_set`, `tempo_set`) with strict
  schemas, built on `Command`. `command_apply` returns a receipt too.
- `ui_state` in the App tools. `loopstudio://help/ui` glossary resource.
- Tests in Control: every named tool produces a receipt whose read-back matches the project; a rejected call
  leaves the revision unchanged; a batch is one undo step.
- Visible result: Claude Code over MCP gets receipts at once.

### Stage 2: the pane and the model call

- `AssistantModel` on the App: transcript, the turn loop (send, stream, run tool calls, send results, repeat),
  the one-batch-per-turn wrapping, the claim check, the plan mode.
- The HTTPS client with streaming and tool use, key in the Keychain, settings page entry.
- The sidebar tab with the transcript, the receipt cards, Undo per turn, the status line.
- Tests: the turn loop with a fake model that returns recorded outputs; the batch wrapping; the claim check.

### Stage 3: reference resolution and the replay harness

- The system prompt with the resolution rules and the glossary.
- Recorded conversations as fixtures (`Tests/Fixtures/assistant/*.json`): "rename the drums to Kit", "add a
  delay after the EQ on the bass", "make the second slot of track 2 loop two bars", "the delay is too loud, pull
  the feedback down a bit". Each replays without a network call and asserts the project and the receipts.
- A live smoke test behind an environment flag that runs five of them against the real API.

### Stage 4: later

- Voice input through the system dictation.
- The assistant reads meters and spectra (`ui_state` with the display buffers) to answer "why does this clip").
- The Patch device (`docs/scripting.md`): the assistant writes a device program and the receipt is the compiled
  program's parameter list.

## 6. Open points for Marcus

- The default model and the effort levels are a guess until the first conversations run. The settings page lets
  you change both.
- Plan mode on or off by default? The design starts with off, and destructive commands always ask.
- Where the pane goes is a UI decision. The sidebar tab is the smallest change; a bottom panel beside the device
  chain is the alternative.
