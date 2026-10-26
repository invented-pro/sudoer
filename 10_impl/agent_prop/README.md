# Sudoer — Prop agent

The human-written **Prop** tier of Sudoer: the assembled agent (components
`C1`–`C8`) built to the language-agnostic blueprint in `00_bp/`. It is the seed
from which the higher tiers are meant to be self-built: a continuous
interactive session with a persistent transcript and plan, deep enough to
work on its own codebase.

- Language: **Dart 3.13.5**, via [mise](https://mise.jdx.dev) (`mise.toml`)
- Terminal UI: [dart_tui](https://pub.dev/packages/dart_tui) (full-screen
  alternate-buffer app, differential rendering, text editor components)
- Args: [args](https://pub.dev/packages/args)
- Blueprint: [`00_bp/agent_prop.md`](../../00_bp/agent_prop.md),
  [`00_bp/agent_prop/gate.md`](../../00_bp/agent_prop/gate.md),
  [`00_bp/schemas.md`](../../00_bp/schemas.md)

## Layout

```
mise.toml                 Dart 3.13.5
pubspec.yaml              args, dart_tui, ffi, http, markdown, path
bin/
  sudoer.dart             CLI entry point (C6)
  gate.dart               build-gate runner
tool/
  build.dart              portable build: compile + publish (C3)
  generate_catalog.dart   regenerate catalog_generated.dart from models.dev
  version.dart            print the pubspec version for release naming
lib/src/
  agent.dart              assembles C1–C8; owns the workspace baseline
  models.dart             transcript/action/tool/run/completion contracts
  console.dart            inline human formatting: channels, spinner, status (C6)
  tui_console.dart        full-screen transcript console + Pi-style frame (C6)
  tui_app.dart            full-screen app: editor, history, queue, scroll (C6)
  markdown_render.dart    block-buffered markdown -> styled terminal text (C6)
  plan_block.dart         fenced `plan` block parse/stream (C2)
  think_block.dart        `<think>` reasoning block parse/stream (C2)
  config.dart             config load + validation + $ENV expansion (C6)
  platform.dart           host shell + Windows console raw input (C3/C6)
  context.dart            versioned system prompt + assembly + compaction (C4)
  reliability.dart        stall-driven budget + per-class timeouts (C8)
  session.dart            persistent, resumable session (C5)
  modality.dart           text normalization (C7)
  tools/tool.dart         read/write/edit/multi_edit/glob/search/run_command
                           + guards and the read-only set (C3)
  tools/baseline.dart     workspace baseline snapshot + diff/restore (C3/C5)
  tools/job.dart          background jobs: start/poll/stop + reaping (C3/C8)
  tools/web.dart          web_search (SearXNG) + web_fetch, guarded (C3)
  providers/              openai-compatible, ollama, scripted (C2)
  loop.dart               plan-driven multi-call ReAct loop (C1)
  interface.dart          provider selection + interactive CLI (C6)
  gate/                   task loader + runner
test/
  agent_prop_test.dart    contract and wiring unit tests
```

## Setup

```bash
cd 10_impl/agent_prop
mise install          # installs Dart 3.13.5
mise exec -- dart pub get
```

## Build

```bash
cd 10_impl/agent_prop
mise run build        # -> dist/sudoer-prop (dist/sudoer-prop.exe on Windows)
./dist/sudoer-prop --help
```

`mise run build` runs `tool/build.dart`: it compiles a native, self-contained
binary (the Dart runtime is bundled, so it runs without a Dart install),
publishes the runnable to `20_eval/agent_prop/`, and stages a release
directory in `90_dist/`:

```
90_dist/sudoer-prop-<version>-<os>-<arch>/sudoer-prop[.exe]
# e.g. 90_dist/sudoer-prop-0.1.0-linux-x64/sudoer-prop
```

The full metadata lives in the **directory/archive name**; the executable
inside keeps the short name the user types (`sudoer-prop`, `sudoer-prop.exe`
on Windows). The version comes from `pubspec.yaml` (`tool/version.dart` prints
it), and `<os>`/`<arch>` are `linux|macos|windows` and `x64|arm64`.

The agent runs on **Linux, macOS, and Windows**. `run_command` and the `!`
shell go through one host shell (C3): `/bin/sh -c` on POSIX (`setsid` process
groups when available) and `cmd.exe /c` on Windows, with the process tree
reaped by `taskkill /T /F`. Dart does not cross-compile, so each platform's
binary is built on that platform — [CI](/.github/workflows/agent-prop.yml)
builds all three and uploads one `sudoer-prop-<version>-<os>-<arch>` artifact
per platform (a zip containing the short executable).

Common mise tasks:

| Task | Does |
| --- | --- |
| `mise run build` | Compile `dist/sudoer-prop` |
| `mise run analyze` | `dart analyze` |
| `mise run test` | `dart test` |
| `mise run gate` | Full build gate (suite + CLI smoke) |
| `mise run gate:suite` | Gate task suite only |

## Use it as a Prop agent

### 1. Choose a provider

The quickest path is the interactive wizard (it uses `dart_tui` for the
selection and a masked key prompt):

```bash
mise exec -- dart run bin/sudoer.dart --setup
```

It picks a provider preset, takes the key (stored in
`~/.config/sudoer/auth.json`, owner-only 0600), discovers the endpoint's
models when reachable, selects one, and writes `~/.config/sudoer/config.json`.
The prompts are
full-screen, and the key/text fields accept a paste. The provider chooser is
searchable (type to filter) because the catalog tracks the full
OpenAI-compatible models.dev set. `--login` is an alias.

You rarely need the flag: with no config on a terminal, `sudoer-prop` opens
this same wizard by itself (see the CLI bullets below), then continues into
the session with the config it wrote.

Or write a config by hand. The smallest form names a preset and a model;
`kind`, `base_url`, and `context_window` come from the built-in catalog
(`--list-providers`):

```json
{
  "provider": { "preset": "openai", "model": "gpt-6-astra" },
  "workspace_root": "/path/to/myproject"
}
```

`workspace_root` is optional: omit it to use the working directory
`sudoer-prop` was started from. It can be changed mid-session with
`/workspace <dir>`.

Local models use the `ollama` preset (the daemon's models are discovered when
reachable):

```json
{
  "provider": { "preset": "ollama", "model": "qwen2.5-coder:7b" }
}
```

Any explicit OpenAI-compatible endpoint (a legacy form, still supported) or
a preset not in the catalog:

```json
{
  "provider": {
    "kind": "openai-compatible",
    "base_url": "https://api.openai.com/v1",
    "api_key": "$OPENAI_API_KEY",
    "model": "gpt-6-astra",
    "context_window": 1050000
  },
  "workspace_root": "$HOME/src/myproject"
}
```

String values may reference environment variables as `$VAR` or `${VAR}`.
A referenced variable that is unset is an error (no silent empty key).
Prefer `api_key_env` (a bare variable name) or the auth store to a literal
key in the config.

Optional sampling parameters ride under `provider.sampling` (sent where the
adapter supports them; omitted keys use the endpoint defaults):

```json
{
  "provider": {
    "preset": "ollama",
    "model": "qwen2.5-coder:7b",
    "sampling": { "temperature": 0.2, "top_p": 0.9, "max_tokens": 4096 }
  }
}
```

#### Provider catalog and keys

- `--list-providers` lists the presets and whether a key is available (never
  the key itself). The catalog is the curated core plus the full
  OpenAI-compatible subset of models.dev/OpenCode (Nvidia, OpenCode Zen,
  Z.AI, Alibaba, regional/coding-plan variants, gateways, and the long tail),
  so it currently carries 200+ presets (211 of models.dev's 232 providers).
  The remaining 21 need a native SDK (Bedrock, Vertex, Azure, native
  Anthropic/Google, …) or a per-account URL placeholder; use `custom` or an
  OpenAI-compatible gateway for those. The generated list is checked in as
  `catalog_generated.dart`; refresh it with
  `dart run tool/generate_catalog.dart /path/to/models.dev-api.json` after
  downloading `https://models.dev/api.json`.
- `--list-models --provider openai` prints the endpoint's live models when
  reachable, else the built-in catalog.
- `--provider <id>`, `--model <id>`, `--base-url`, `--context-window`,
  `--api-key`, and `--api-key-env` override the config for one process.
  `--provider` alone is enough to run without a config (rooted at the
  working directory).
- `--save-key --provider openai --api-key …` stores a key for scripts
  without running the wizard.
- MiniMax keys are region-specific. Use `--provider minimax` for the
  international `api.minimax.io` endpoint and `--provider minimax-cn` for the
  China `api.minimax.cn` endpoint. A 401 from the wrong region now carries a
  hint naming the other preset (the key is never echoed).
- Keys are validated as printable ASCII without whitespace (surrounding
  whitespace is trimmed). Setup and `--save-key` reject a pasted terminal
  transcript or multi-line blob before storing it; a stale stored/env key is
  reported as `invalid` (and is never sent as an HTTP header).
- Inside a session, `/provider [id]` and `/model [id]` list and switch at a
  goal boundary.
- Key precedence: `provider.api_key` → auth store → `provider.api_key_env`
  → the preset's conventional env var (`OPENAI_API_KEY`,
  `ANTHROPIC_API_KEY`, …). The auth store is
  `~/.config/sudoer/auth.json` (XDG; `%APPDATA%` on Windows;
  `SUDOER_AUTH_FILE` overrides) and is written 0600.

Web tools are on by default (any host). Point `search_url` at a self-hosted
SearXNG to enable `web_search`; set `deny_hosts` to block specific hosts:

```json
{
  "web": {
    "search_url": "http://localhost:8080",
    "deny_hosts": []
  }
}
```

Set `"enabled": false` to remove the web tools entirely. A network denial
blocks the run; there is no interactive override.

Context management defaults to the built-in *harness* ladder (clip, clear,
fold). Set `context.mode` to `clm` to hand the live context to the model as
an editable file it manages with its own tools (*context as a file*), with
optional natural-language steering:

```json
{
  "context": {
    "mode": "clm",
    "strategy": "keep a running ledger and compact around sub-questions"
  }
}
```

The live file defaults to `<workspace_root>/.sudoer/context.md`; override it
with `context.file` (relative paths resolve against `workspace_root`). The
session file (C5) stays the authoritative store — the context file is a
mirror the model edits. `/context` reports the active mode and file; see
`00_bp/C4_context.md`.

### 2. Start a session

With no positional goal on a terminal, `sudoer-prop` runs the **full-screen
TUI**: a fixed header (build, provider/model, workspace, session, transcript
size, and the plan as a bordered checklist panel once one exists), a
scrollable transcript, a bordered multi-line editor, and a status
footer. Queued follow-up messages draw as their own bordered `queued` panel
between the transcript and the editor. It uses the alternate screen and restores the shell's scrollback on
exit. The layout follows Pi's interactive mode: the editor and status area
stay put while the transcript scrolls, so a long run never pushes the input
off-screen. `--inline` keeps the older scrollback surface when a takeover is
not wanted; `--automate` (or a non-interactive stdin/stdout) is the plain
one-shot CLI.

The header doubles as the ongoing progress area: once the model has sent a
plan, it draws as a bordered panel under the session line — slate edges with
a `plan` label on the top border, and one row per item: `✓` (green, dim text)
for done steps, `❯` (mauve, bold) on the step currently in flight, `○` for
queued steps. Long plans fold to at most five rows plus a `… +N more` line,
keeping the active step visible; the panel grows and shrinks with the plan as
the run progresses. The panel is live twice over: the streaming adapter
reports the plan while the model is still writing the `plan` block (each
checkbox lands as it arrives), and each response's authoritative plan is
applied the moment it completes — the checklist never waits for the run to
finish.

The footer carries the spinner and step/context detail while a run is in
flight, then the latest status: response number, result, context use as
`used/window (percent)` in K/M units with a bar, plan progress, step count
(with stall state once steps stop making progress), and the workspace.

Each kind of output has its own colour so the three voices never blur
together: **user input** is echoed as a bold `›` turn; **model output** is
rendered markdown in magenta (sky headings, peach inline code, mauve list
markers); **command output** (`/help`, `/plan`, `/status`, …) is yellow; the
model's `<think>` **reasoning** is a dim italic `│` block distinct from the
answer; tool calls are mauve `→` lines; tool/command results are coloured
`✓`/`✗` lines with any multi-line body indented beneath; verbose `[C1]`–`[C8]`
diagnostics are a dim gutter with a colour-coded tag; and the status footer has
its result word coloured. Styling is presentation only.

The model's reply is markdown, so the human surface renders it: headings,
emphasis, inline code, fenced code (with a language tag), lists, task items,
blockquotes, rules, links, and tables. Rendering is **block-buffered** — a
block appears when it completes at a blank line or closing fence, and the
rest at the end of the run — so text arrives per block rather than per token,
always complete. The automation surface keeps the raw markdown, so its stdout
stays machine-readable.

The TUI editor is multi-line: `Enter` submits, `Shift+Enter` (or `Alt+Enter`,
which works even when the terminal does not report modified Enter) adds a
line, and bracketed paste inserts text verbatim, including line breaks,
without submitting. `←`/`→`/`Home`/`End` move within the text; `↑`/`↓` at the
first/last line walk your input history and restore the in-progress draft.
`PgUp`/`PgDn` scroll the transcript, and so does the mouse wheel — the wheel
scrolls the content under the pointer's context: an open popup's list when
one is up, the transcript otherwise; it never touches the editor, so it
cannot walk input history by accident. The mouse buttons stay a selection
device: press and drag across the transcript to select (reverse-video
highlight, live as you drag), and on release the text is copied to the host
clipboard via OSC 52; a plain click just clears the highlight. No toggle and
no modifier: the wheel scrolls, the drag selects. While a run is in
flight, `Enter`
queues a follow-up to
run after it; the queued messages show as a bordered `queued` panel just
above the editor (folded with `+N more` when long), and the footer shows the
queue depth; one `Esc` cancels the run
and keeps the partial transcript. `Ctrl+C` restores the terminal and exits.
The `--inline` fallback keeps the line editor, `\`-continued multi-line goals,
and double-`Esc` cancellation. On a pipe or with `--automate` input is read
one line at a time.

Selection and reference commands open **popups** instead of dumping listings
into the transcript: `/provider`, `/model`, `/sessions`, `/resume`, `/help`,
and `/plan` (bare, without an argument) draw a centered bordered box over the
frame. While a popup is open it owns the keyboard: `↑`/`↓` (and
`PgUp`/`PgDn`/`Home`/`End`) move, typed text filters — every whitespace token
must match the id, name, or detail column — `Enter` selects, and `Esc` (or
`Ctrl+C`) cancels without changing anything. The provider picker shows each
preset's key *state* (`stored`, `env`, `missing`, …, never a value) and marks
the preset in effect with `●`; the model picker shows each model's context
window; the session picker resumes the chosen session on `Enter`. A popup
command is not a model run, so the footer keeps its idle hints and the run
queue stays untouched underneath. An explicit argument (`/provider ollama`)
skips the popup and switches directly.

The interaction grammar follows [Crush](https://github.com/charmbracelet/crush):

- `Ctrl+P` opens the **command palette** — every command with its description,
  filterable; `Enter` runs the chosen one.
- `Ctrl+L` opens the model picker, `Ctrl+S` the session picker, `Ctrl+N` a new
  session, and `Ctrl+G` the help popup.
- Typing `/` in the editor shows a **completion menu** anchored above
  the input (the bare `/` already triggers it): matching commands with
  one-line descriptions, filtered as you type. The editor keeps the keyboard —
  `↑`/`↓` move the selection (history recall pauses while it is open), `Tab`
  fills the highlighted command in, `Enter` fills it when it differs from the
  typed text and sends when it is exact, and `Esc` dismisses the menu (a
  second `Esc` clears the draft).
- Choosing a provider whose API key is missing (or stored but unusable)
  **prompts for the key** in a masked one-line modal before the switch
  applies: `Enter` validates and stores it in the auth store (never echoed,
  never written to the config), `Esc` or an empty `Enter` switches without a
  key and shows the usual hint instead. Paste works too.
- Shortcuts are idle-surface gestures: while a run is in flight the keys keep
  their editor meaning.

```bash
cd 10_impl/agent_prop
mise exec -- dart run bin/sudoer.dart --config /path/to/config.json
```

Pass `--automate` — or pipe stdin/stdout — for the plain CLI (used by
scripts and the gate), where each input line is a goal and the reply is
printed whole:

```bash
printf 'summarize README.md\n/exit\n' \
  | mise exec -- dart run bin/sudoer.dart --automate -c config.json
```

Built-in commands (both surfaces):

| Command | Effect |
| --- | --- |
| `/help` | list commands (popup in the TUI) |
| `/exit` | persist and close the session, then exit (`/quit` is a hidden alias) |
| `/new` | start a new session |
| `/sessions` | list saved sessions (pick-to-resume popup in the TUI) |
| `/resume <id>` | switch to a saved session (picker popup in the TUI) |
| `/plan` | print the current plan (popup in the TUI) |
| `/status` | print the session status |
| `/provider [id]` | list the provider presets, or switch the active provider (filterable picker popup in the TUI); a keyed preset prompts for its key — empty keeps the current one, so re-selecting the active preset rotates its key |
| `/model [id]` | list the current provider's models, or switch model (filterable picker popup in the TUI); recently used provider/model pairs are offered first — picking one switches provider and model together |
| `/context [harness\|clm]` | show or switch the context strategy (and live file) |
| `/diff [path]` | show the workspace's changes against the session baseline |
| `/cancel` | cancel the in-flight run (automate surface; `Esc` on human surfaces) |
| `/workspace [dir]` | print or change the workspace root |
| `/verbose on\|off` | emit per-step routing (TUI transcript; stderr otherwise; default off) |

A positional goal is a one-shot convenience: run it and exit.

```bash
mise exec -- dart run bin/sudoer.dart -c /path/to/config.json \
  "Read README.md and summarize it"
```

- On the automate surface, answers go to **stdout**; diagnostics, plan, and
  status to **stderr**. The human surfaces render those into the transcript
  and footer.
- Output never blocks input in the TUI: while a run streams, read-only
  commands (`/status`, `/help`, `/plan`, `/diff`, `/verbose`) and the
  provider/model switches (`/provider`, `/model`, `/rekey`) answer at once —
  a switch applies mid-run without aborting the stream (the live run keeps
  its retired transport until it ends). Goals and `!` lines queue as before
  (the footer shows the queue depth), and so does a session resume.
- Recently used provider/model pairs are kept in
  `~/.config/sudoer/recent.json` (capped, most recent first) and offered at
  the top of the `/model` picker; picking a cross-provider pair switches
  both at once.
- `--config` / `-c` defaults to `$SUDOER_CONFIG`, then
  `~/.config/sudoer/config.json` (`$SUDOER_HOME` moves the whole app dir;
  the dir and its `sessions/` sub-directory are created on first start).
- A first run with no config opens the setup wizard on a terminal (the
  provider page) and continues with the config it wrote; `--automate`,
  `--list-models`, and piped stdin/stdout keep the missing-config report
  instead, so scripts and the gate never hang.
- `--automate` forces the plain surface; `--human` forces the styled surface;
  `--inline` uses the scrollback line editor instead of the full-screen TUI;
  `--verbose` emits per-step events.
- `--provider <id>` / `--model <id>` select or override the provider and
  model; `--api-key`, `--api-key-env`, `--base-url`, and
  `--context-window` override the other provider fields. With `--provider`,
  a config file is optional (an ephemeral config is rooted at the current
  directory).
- `--list-providers`, `--list-models`, and `--setup` (alias `--login`) are
  catalog/setup surfaces: they exit before a session starts. `--save-key`
  persists a `--api-key` for `--provider` in the auth store.
- `--session` / `-s <id>` resumes a saved session, or starts one under that
  id if it does not exist yet (on both the one-shot and interactive surfaces);
  `--help` / `-h` prints usage.
- Sessions live under `session_dir` (default `~/.config/sudoer/sessions`),
  one JSONL file per session. A new session's id is the local time
  `YYMMDD-HHmmSS`; after the first run the model summarizes the goal into at
  most five keywords and the file becomes `YYMMDD-HHmmSS_<keywords>.jsonl`
  (e.g. `261020-142530_fix-login-loop.jsonl`; `/sessions` lists them).
  A `--session`-pinned id is kept verbatim and never renamed.
- On the automate surface the session id is logged on exit as
  `session <id> (resume: --session <id>)`, so a one-shot or scripted run is
  easy to resume.

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | the final run completed |
| `1` | the final run was incomplete or blocked, or a fatal error occurred |
| `2` | usage or config error |

### Behavior and limits

- **Model must support tool calling** (e.g. `llama3.1`/`qwen2.5` on ollama,
  `gpt-4o*` on OpenAI); the tools are sent as function definitions.
- **Ten built-in tools plus the web pair.** Orientation (`glob`, `search`),
  reading (`read`, with `offset`/`limit` line ranges returned as text),
  editing (`write`, `edit` with `replace_all`, `multi_edit`), execution
  (`run_command` foreground, `job` background start/poll/stop), review and
  undo (`diff`, `restore` against the session baseline), and — unless
  `web.enabled` is false — `web_search`/`web_fetch`.
- **Multi-call steps.** One provider decision may carry several tool calls
  (`action` = `finish` | a batch of `tool_calls`): independent read-only
  calls (`read`, `glob`, `search`, `diff`, `web_fetch`, `web_search`) are
  dispatched in parallel, while side-effecting calls (`write`, `edit`,
  `multi_edit`, `run_command`, `job`, `restore`) run sequentially in the
  listed order. Observations return bound to their calls by id, in the
  listed order; a sibling's timeout or denial never discards completed
  observations (C8).
- **Two surfaces, one CLI.** The full-screen TUI is the default human surface
  on a terminal; `--inline` selects the scrollback variant, and `--automate`
  (or a non-interactive stdin/stdout) selects the plain surface, so scripts
  never hang.
- **Streaming.** On the human surface the reply streams as tokens arrive
  (OpenAI SSE, ollama NDJSON) and is applied to the transcript; a fenced
  `plan` block is withheld until complete and a `<think>` reasoning block
  streams dim/italic, apart from the answer. The visible reply is markdown
  and is rendered block by block. The automation path takes the one-shot
  request and prints the whole reply raw. Streamed tool-call deltas are
  merged per call index, so an interleaved batch reassembles into the same
  action.
- **Reasoning.** If the model wraps private reasoning in `<think> … </think>`,
  the adapter strips it from the visible text and normalizes it to a separate
  `reasoning` value; it is never part of the answer and never replayed to the
  model as a tool result.
- **Sampling.** `provider.sampling` in the config
  (`temperature`, `top_p`, `top_k`, `seed`, `max_tokens`) is passed through
  to the adapter where supported (OpenAI: temperature/top_p/seed/max_tokens;
  ollama: all five, `max_tokens` as `num_predict`). Omitted keys use the
  endpoint defaults.
- **Workspace baseline.** When a session opens, the runtime snapshots the
  workspace (text files; VCS/dependency/build trees skipped) beside the
  session file and records an opaque handle. `diff` shows the working tree
  against that snapshot (falling back to `git diff` for legacy sessions
  without one) and `restore` reverts to it — added files are removed,
  snapshotted files rewritten. The baseline refreshes only when the workspace
  root changes, and is never shown to the model.
- **Continuous, persistent session.** Goals share one transcript and plan;
  the session is written to disk after each run and can be resumed.
- **Plan-driven.** The model sends plan updates in a fenced `plan` block of
  Markdown checkboxes (taught by the system prompt); the adapter strips the
  block, replaces the session plan, and `/plan` shows it. No block means the
  plan is unchanged.
- **Versioned system prompt.** The system prompt is a pinned artifact
  (`prop-prompt-v2`) shipped with the build: identity, tool guidance
  (orient with glob/search, read before editing, prefer `multi_edit`, review
  with `diff`, verify with `run_command`), the coding contract, the plan
  convention, and the output format.
- **Compaction.** Older transcript is folded into a summary at a milestone —
  the first step of a new goal once the prompt passes 75% of the window, or
  mid-run at 90%; the goal and plan are pinned. The human surface reports it
  as command output (`↺ compacted N earlier steps …`).
- **Stall-driven guards:** a run continues while steps make progress and ends
  after 3 consecutive non-progress steps (a repeat, error, or timeout); a
  1000-step ceiling is only a runaway safety net, so long productive work is
  never cut off by step count. Timeouts are 120s for provider calls and 10m for
  `run_command` (`lib/src/reliability.dart`). On a stall the loop makes one
  best-effort call with tools withheld, falling back to a local summary.
- **Background jobs are reaped.** Every `job` runs under the same host shell
  as `run_command`; jobs are killed when the run is cancelled and when the
  session closes, so no child process outlives the agent.
- **Verbose routing.** `/verbose on` (or `--verbose`) emits `[C1]`–`[C8]`-
  tagged events: session/provider selection, prompt fit (C4), each tool call
  and its evaluated result (C3), plan updates and progress/stall accounting
  (C1), guard timeouts (C8), and the final status. They join the TUI
  transcript, go to stderr under `--inline`, and use the automate stderr log
  otherwise. Off by default; automate stdout stays clean.
- **Tools are workspace-rooted** (`read`, `write`, `edit`, `multi_edit`,
  `glob`, `search`, `diff`, `restore`); a path that escapes `workspace_root`
  is a guard denial. The root defaults to the invocation directory and can
  change with `/workspace`. On the human surface a denial prompts `⚠ … [y/N]`;
  `y` opens the guard for the rest of the session (in memory only) and
  retries the call. Automation never prompts and blocks as before.
- **Web tools are on by default** (`web_search`, `web_fetch`). They are
  assembled unless `web.enabled` is false; `web_search` uses the SearXNG
  `web.search_url` (unset means `web_search` reports it is not configured),
  and `web.deny_hosts` is an empty blacklist reserved for later policy (an
  entry is an exact host or a `.suffix` matching subdomains). A network denial
  is a hard block — there is no interactive override — and fetched text is
  tagged untrusted and never treated as instructions. Web calls use a 20s
  timeout and cap fetches at 256 KB / 10 results (compiled-in).
- **No sandbox yet** — `run_command` and `job` run via the host shell inside
  `workspace_root` (and anywhere, once outside-workspace access is granted),
  so they can also reach the network. The web guard governs the web tools
  only, not the shell. Hard isolation is Pilot's safety tier.

## Build gate

The gate is Prop's definition of done: a fixed task suite run against a
deterministic scripted provider, reproducible offline. **No LLM is
involved**; every task scripts its own responses.

```bash
cd 10_impl/agent_prop
mise run gate          # suite + CLI smoke
mise run gate:suite    # suite only
```

- Tasks live in [`00_bp/agent_prop/tasks/`](../../00_bp/agent_prop/tasks)
  (32 tasks: reading, editing, orientation, execution, baseline diff/restore,
  batch/parallel calls, error/denial/timeout paths, context overflow and
  watermark compaction, sessions, plans, the REPL, and provider/model
  switching). A task whose
  `run_command` strings assume the POSIX host shell declares
  `"host_shell": "posix"` and is skipped (not failed) on Windows, where the
  host-shell paths are unit-tested.
- The runner injects a `ScriptedProvider`; each task may script a completion
  with several `tool_calls` (one batch step). The runner compares the ordered
  tool-call log **and each call's observation** against `expect.tools` and
  `expect.observations`. The CLI smoke spawns the real `bin/sudoer.dart`
  offline via the `SUDOER_SCRIPT_FILE` seam.
- Deterministic: repeated runs are identical. `job` stays out of gate scope
  (runtime ids and timing); it is covered by unit tests instead.

## Tests and checks

```bash
cd 10_impl/agent_prop
mise run analyze
mise run test
```

The real provider adapters (`openai-compatible`, `ollama`) are exercised
only in normal CLI use, never by the gate or unit tests.

## Notes

- `PUB_CACHE` currently resolves to the repository's `.pub-cache/`, and
  `.dart_tool/` is generated — both are build artifacts.
- The `SUDOER_SCRIPT_FILE` environment variable is a test seam: when set, the
  CLI uses a scripted provider instead of a real endpoint.
