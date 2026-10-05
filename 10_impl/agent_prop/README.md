# Sudoer — Prop agent

The human-written **Prop** tier of Sudoer: the assembled agent (components
`C1`–`C8`) built to the language-agnostic blueprint in `00_bp/`. It is the seed
from which the higher tiers are meant to be self-built: a continuous
interactive session with a persistent transcript and plan, deep enough to
work on its own codebase.

- Language: **Dart 3.13.5**, via [mise](https://mise.jdx.dev) (`mise.toml`)
- Inline styling: [dart_tui](https://pub.dev/packages/dart_tui) (styles only; no full-screen app)
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
  version.dart            print the pubspec version for release naming
lib/src/
  agent.dart              assembles C1–C8; owns the workspace baseline
  models.dart             transcript/action/tool/run/completion contracts
  console.dart            inline human formatting: channels, spinner, status (C6)
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

### 1. Write a config (JSON)

Local model via ollama (`base_url` defaults to `http://localhost:11434`):

```json
{
  "provider": {
    "kind": "ollama",
    "model": "llama3.1",
    "context_window": 8192
  },
  "workspace_root": "/home/s1/src/myproject"
}
```

`workspace_root` is optional: omit it to use the working directory `sudoer-prop`
was started from. It can be changed mid-session with `/workspace <dir>`.

Any OpenAI-compatible endpoint:

```json
{
  "provider": {
    "kind": "openai-compatible",
    "base_url": "https://api.openai.com/v1",
    "api_key": "$OPENAI_API_KEY",
    "model": "gpt-4o-mini",
    "context_window": 128000
  },
  "workspace_root": "$HOME/src/myproject"
}
```

String values may reference environment variables as `$VAR` or `${VAR}`.
A referenced variable that is unset is an error (no silent empty key).

Optional sampling parameters ride under `provider.sampling` (sent where the
adapter supports them; omitted keys use the endpoint defaults):

```json
{
  "provider": {
    "kind": "ollama",
    "model": "llama3.1",
    "context_window": 8192,
    "sampling": { "temperature": 0.2, "top_p": 0.9, "max_tokens": 4096 }
  }
}
```

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

### 2. Start a session

With no positional goal on a terminal, `sudoer-prop` runs the **human CLI**: the
normal scrollback, with color/italics, a `› ` prompt, a spinner while
thinking, replies streamed in as they are generated, and a one-line status
after each run: the response number within the session, the result, context
use as `used/window (percent)` in K/M units with a bar, plan progress,
step count (with stall state once steps stop making progress), and the
workspace. It does **not** take over the screen.

Each kind of output has its own colour so the three voices never blur
together, with no change to how typing feels: **user input** stays in the
terminal's default color (the `› ` prompt and the typed line exactly as the
tty shows them); **model output** is rendered markdown in magenta (sky
headings, peach inline code, mauve list markers); **command output**
(`/help`, `/plan`, `/status`, …) is yellow; the model's `<think>`
**reasoning** streams as a dim italic `│` block distinct from the answer;
tool calls are mauve `→` lines; tool/command results are coloured `✓`/`✗`
lines with any multi-line body indented beneath; verbose `[C1]`–`[C8]`
diagnostics are a dim gutter with a colour-coded tag; and the status line has
its result word coloured. Styling is presentation only; with color off each
channel degrades to its plain prefix.

The model's reply is markdown, so the human surface renders it: headings,
emphasis, inline code, fenced code (with a language tag), lists, task items,
blockquotes, rules, links, and tables. Rendering is **block-buffered** — a
block appears when it completes at a blank line or closing fence, and the
rest at the end of the run — so text arrives per block rather than per token,
always complete. The automation surface keeps the raw markdown, so its stdout
stays machine-readable.

On a terminal the prompt is a real line editor: `←`/`→` move the cursor to
insert or correct, `↑`/`↓` walk your input history (the in-progress draft is
restored when you come back to it), `Home`/`End` jump within the line, and a
line ending in `\` continues onto the next line, so a goal can span multiple
lines. While the agent is working the spinner carries an `Esc Esc to
interrupt` hint; press `Esc` twice to cancel the run (like `/cancel`, keeping
the partial transcript). On a pipe or with `--automate` this is skipped and
input is read one line at a time.

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
| `/help` | list commands |
| `/exit`, `/quit` | persist and close the session, then exit |
| `/new` | start a new session |
| `/sessions` | list saved sessions |
| `/resume <id>` | switch to a saved session |
| `/plan` | print the current plan |
| `/status` | print the session status |
| `/diff [path]` | show the workspace's changes against the session baseline |
| `/cancel` | cancel the in-flight run |
| `/workspace [dir]` | print or change the workspace root |
| `/verbose on\|off` | emit per-step routing on stderr (default off) |

A positional goal is a one-shot convenience: run it and exit.

```bash
mise exec -- dart run bin/sudoer.dart -c /path/to/config.json \
  "Read README.md and summarize it"
```

- On the line surface, answers go to **stdout**; diagnostics, plan, and
  status to **stderr**.
- `--config` / `-c` defaults to `$SUDOER_CONFIG`, then `./sudoer.json`.
- `--automate` forces the plain surface; `--human` forces the styled surface;
  `--verbose` emits per-step events.
- `--session` / `-s <id>` resumes a saved session; `--help` / `-h` prints usage.
- Sessions live under `session_dir` (default `<workspace_root>/.sudoer/sessions`).

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | clean exit (interactive), or answered (one-shot complete/incomplete) |
| `1` | fatal error (one-shot: blocked) |
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
- **Two surfaces, one CLI.** Styled human output by default on a terminal;
  `--automate` (or a non-interactive stdin/stdout) selects the plain surface,
  so scripts never hang. Neither is full-screen.
- **Streaming.** On the human surface the reply streams as tokens arrive
  (OpenAI SSE, ollama NDJSON); a fenced `plan` block is withheld until
  complete and a `<think>` reasoning block streams dim/italic to stderr,
  apart from the answer. The visible reply is markdown and is rendered block
  by block. The automation path takes the one-shot request and prints the
  whole reply raw. Streamed tool-call deltas are merged per call index, so
  an interleaved batch reassembles into the same action.
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
  200-step ceiling is only a runaway safety net, so long productive work is
  never cut off by step count. Timeouts are 30s for provider calls and 10m for
  `run_command` (`lib/src/reliability.dart`). On a stall the loop makes one
  best-effort call with tools withheld, falling back to a local summary.
- **Background jobs are reaped.** Every `job` runs under the same host shell
  as `run_command`; jobs are killed when the run is cancelled and when the
  session closes, so no child process outlives the agent.
- **Verbose routing.** `/verbose on` (or `--verbose`) prints `[C1]`–`[C8]`-
  tagged events on stderr: session/provider selection, prompt fit (C4), each
  tool call and its evaluated result (C3), plan updates and progress/stall
  accounting (C1), guard timeouts (C8), and the final status. Off by default; stdout
  stays clean.
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
  (24 tasks: reading, editing, orientation, execution, baseline diff/restore,
  batch/parallel calls, error/denial/timeout paths, context overflow and
  watermark compaction, sessions, plans, and the REPL). A task whose
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
