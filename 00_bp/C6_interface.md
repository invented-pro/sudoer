# C6 — Interface

> Status: draft · Version 1.7 · **Current tier: Prop**

The interface is how a human reaches the agent: `C6` is the surface that
takes a goal in and puts an answer out. The loop is the engine; the
interface is the dashboard.

## Overview

Every tier exposes the agent through some surface, and every surface funnels
into the same session (C5) and loop (C1) with a goal and an answer. The
tiers differ in the surfaces offered: a human terminal UI and a line CLI for
automation at Prop; a **web page** for non-technical users and a
**REST server** that everything else (messenger adapters, scripts, the
scheduler) plugs into, at Pilot; and a multi-user gateway with desktop
clients at Orbit.

```plantuml
@startuml
hide footbox
skinparam backgroundColor transparent
skinparam defaultFontColor #64748B
skinparam participantBackgroundColor #E8F5E9
skinparam participantBorderColor #64748B
skinparam participantFontColor #1F2937
skinparam arrowColor #64748B
actor User
participant "interface (C6)" as I
participant "session (C5)" as S
participant "loop (C1)" as L
User -> I : goal
I -> S : open session
S -> L : run(goal)
L --> S : answer + status
S --> I : answer + status
I --> User : render
@enduml
```

The interface does not reason. It parses input, normalizes it (`modality`,
C7), opens a session, invokes the loop, and renders the result — nothing
about *how* the goal is solved lives here.

## Prop

Prop is a line CLI in both modes; the modes differ only in presentation.
On a terminal the **human** surface renders the normal scrollback with color,
italics, a thinking spinner, a `› ` prompt, streamed replies, and a status
line — no full-screen takeover. Under `--automate`, or when stdin/stdout is
not a terminal (a pipe, a script, the gate), the **automate** surface is
plain, one-shot, and pipe-friendly. Either way, a line that begins with `/`
is a **command** handled locally; any other line is a **goal**, normalized by
`C7` and run inside the current session. There is no server or daemon, but
there is a resident session, and it outlives a single goal.

```plantuml
@startuml
skinparam backgroundColor transparent
skinparam defaultFontColor #64748B
skinparam activityBackgroundColor #E8F5E9
skinparam activityBorderColor #64748B
skinparam activityFontColor #1F2937
skinparam arrowColor #64748B
start
:parse startup arguments; load config; open session (C5);
if (--automate or stdin/stdout not a terminal?) then (yes)
  :automate surface (plain, one-shot);
else (no)
  :human surface (styled, streamed);
endif
repeat
  :read a goal or command;
  if (line begins with "/"?) then (yes)
    :handle command locally;
    if (command is exit?) then (yes)
      :close session; stop
    endif
  else (no)
    :normalize goal (C7); append to session;
    :run the loop (C1) inside the session;
    :stream the reply inline; show a thinking spinner;
    :render answer and status;
  endif
repeat while (still running?) is (yes)
@enduml
```

### Commands

| Command | Effect |
| --- | --- |
| `/help` | list commands |
| `/exit`, `/quit` | persist and close the session, then exit |
| `/new` | start a new session (new id) |
| `/sessions` | list saved sessions |
| `/resume <id>` | switch to a saved session |
| `/plan` | print the current plan (C1) |
| `/status` | print the current run status and budget use (C1, C8) |
| `/diff` | show the workspace's changes against the session baseline (C3) |
| `/cancel` | cancel the in-flight run (C1, C8); automate surface only |
| `/compact` | fold earlier context into a brief now (C4) |
| `/workspace [path]` | print or change the workspace root (C3) |
| `/verbose on\|off` | emit per-step diagnostics on stderr (off by default) |

Behavior change on the fly is limited to session and interface concerns —
the active session, the plan, the workspace root, and verbosity. Changing
the provider, model, or safety policy is a Pilot concern (`C2`, `C10`)
and is not offered here.

- **Human surface (inline).** Stays on the normal scrollback: a `› ` prompt,
  color and italics for user/tool/status lines, a spinner while thinking, the
  reply streamed in as it is generated, and a one-line status after each run
  (the response number within the session, the result, context use against the
  window as `used/window (percent)` with token counts in K/M units, plan
  progress, step/budget, workspace).
  No alternate screen and no full-screen takeover.
- **Interactive input (raw terminal).** On a real terminal the human surface
  takes over the keyboard for line editing: Left/Right move the cursor to
  insert or correct, Up/Down walk the input history (the in-progress draft is
  restored when you return to it), Home/End jump within the line, and
  Backspace/Delete edit. A line ending in `\` continues onto the next line
  (drawn with a `  ` continuation prompt), so a goal may span multiple lines,
  and `/help` notes the gesture; a plain Enter submits. Only a line that starts a submission is a command: a
  `/` command sitting on a continuation line is goal text, and the interface
  says so rather than silently sending it to the model. While a run is in
  flight the thinking spinner carries
  an `press Esc twice to interrupt` hint, and a double `Esc` cancels the run
  immediately (the partial transcript is kept). On Windows the console is put
  into virtual-terminal input mode first, so these keys reach the editor as
  bytes instead of being swallowed by the legacy console. Off a terminal — a
  pipe, `--automate`, or the gate — the plain line path is used and none of
  this applies.
- **Direct shell (`!`).** On the interactive human surface a submitted line
  beginning with `!` is run directly as a shell command in the workspace root;
  its stdout and stderr are forwarded verbatim and the model is never involved.
  It runs through the same host shell as `run_command` (C3) — `/bin/sh -c` on
  POSIX, `cmd.exe /c` on Windows — so the escape hatch is platform-neutral.
  This is a human-CLI escape hatch only: `/help` lists it, a `!` line is not
  interruptible (the double `Esc` gesture does not apply to it), and on the
  automate surface a `!` line is an ordinary goal.
- **Visual channels.** Each kind of output gets its own colour and mark, so a
  transcript is easy to scan and the three voices never blur together:
  - **User input** stays in the terminal's default color: the `› ` prompt and
    the typed line are exactly what the tty shows, so nothing about typing
    changes. Off a terminal (a pipe) the interface prints the goal once as a
    default-colored `❯ ` header.
  - **Model output** (the answer) is rendered markdown in magenta, with its
    own accents (sky headings, peach inline code, mauve list markers), so the
    model's voice is unmistakable against the default-colored input and the
    yellow command output.
  - **Command output** (`/help`, `/plan`, `/status`, … — local, not the model)
    is yellow.
  - **Private reasoning** (`<think>`, C2) is a dim italic `│` block, so it
    reads as an aside and is clearly not the answer.
  - **Tool calls** are mauve `→` lines; **tool/command results** are coloured
    `✓`/`✗` lines with a multi-line body indented and capped beneath them.
  - **Verbose `[C1]`–`[C8]` diagnostics** are a dim gutter with a
    colour-coded tag; **errors and blocked runs** are red; the **status line**
    is a dim rule with the result coloured (green complete, yellow
    incomplete, red blocked).

  Styling is presentation only — with color off, each channel degrades to its
  plain prefix and stdout stays machine-readable.
- **Markdown rendering.** The model's reply is markdown, so the human surface
  renders it: headings, emphasis, inline code, fenced code (with a language
  tag), lists, task items, blockquotes, horizontal rules, links, and tables
  (with aligned columns). Rendering is block-buffered — a block is emitted
  when it completes at a blank line or a closing code fence, and the rest is
  flushed at the end of the step — so the display is always a correct,
  complete block rather than a half-typed one. Rendering is on for the human
  surface only; the automate surface keeps the raw markdown so its stdout
  stays machine-readable.
- **Mode switch.** Human is the default on a terminal. `--automate` forces
  the plain surface; a non-interactive stdin/stdout selects it automatically,
  so scripts, pipes, and the gate never block on a prompt. `--human` forces
  the styled surface when terminal detection is wrong.
- **Session and one-shot.** `--session <id>` names the session on both
  surfaces: it resumes that saved session, or opens a new one under that id if
  none exists yet (so a caller that pins an id gets one stable session across
  runs). Without it a new session opens with a readable id (C5). A positional
  goal argument runs exactly one goal on the plain surface — even on a
  terminal — then exits; the exit code follows *Exit codes* below. The
  one-shot form is what scripts and the gate's CLI smoke drive.
- **Resume hint.** On the automate surface the interface logs the session id
  on exit (stderr, alongside the timings) as
  `session <id> (resume: --session <id>)`, so a scripted or one-shot run is
  easy to pick up again by copy-pasting the flag. Stdout stays the clean
  answer surface.
- **Streaming.** On the human surface the provider streams generated text
  (`C2`) and the loop forwards visible deltas (`C1`), which are written inline
  to stdout, while reasoning deltas (`<think>`, C2) stream dim and italic to
  stderr. A plan block is withheld until it is complete, so it is never shown
  as it arrives. Automation takes the one-shot path and gets the whole reply
  at once.
- **Timing.** Each provider response and each tool dispatch is measured
  (`C1`) and reported, so the cost of a slow model or command is visible.
  On the human surface the thinking spinner ticks up the elapsed time of the
  call once it passes a second, placed right after the phase word
  (`thinking · 3.2s · ctx 421/8.2K`); the response latency rides as a dim
  `· 2.4s` suffix on the `→` tool line it produced, tool results carry their
  own `· 0.03s`, and the run total leads the status line in place of the
  status word (e.g. `8.4s #3 · …`), still coloured by the run's status. The
  automate surface leaves stdout untouched and prints plain
  `timing: <span> <duration>` lines on stderr after the run. Timings are
  runtime-only and are never written to the session or the run wire shape.
- **Resident session.** The program stays running across many goals; it exits
  only on `/exit`, `/quit`, Ctrl+C, or end of input (EOF).
- **Command vs goal.** A leading `/` marks a local command; everything else
  is a goal for the loop. This keeps interface control from being sent to
  the model.
- **Attachments.** A goal line may carry `@path` tokens —
  whitespace-separated paths beginning with `@`. The interface strips them
  from the line and hands them to `C7`, which validates each (it must exist
  and be an image) and attaches it to that goal only; a bad token is
  reported locally and the goal is not submitted. `/help` notes the syntax,
  and the automate surface accepts the same tokens.
- **Output channels.** Answers (streamed or whole) go to stdout; reasoning,
  diagnostics, the plan, status, and errors go to stderr, so stdout stays
  machine-readable even on the human surface.
- **Context compaction.** When `C4` folds earlier transcript into a summary,
  the human surface reports it as command output
  (`↺ compacted N earlier steps … (before → after tokens)`), so the user sees
  that context was shortened instead of it happening silently; the verbose
  `[C4 context]` diagnostic carries the same detail.
- **Manual compaction.** `/compact` folds the current session's older context
  into a brief on demand (C4), even below the automatic watermark, then
  reports the same `↺ compacted …` line. It works on both surfaces; a session
  with nothing foldable reports that instead of making a call.
- **Verbose diagnostics.** `/verbose on` makes each component report its
  internal routing and behavior as `[C1]`–`[C8]`-tagged lines on stderr: the
  run/session/provider selection, the assembled prompt fit (`C4`), the tool
  call and its evaluated result (`C3`), plan updates and progress/stall
  accounting (`C1`), guard timeouts (`C8`), and the final status. It is off by default
  and never touches stdout.
- **Exit codes.** Zero only when the final run status is `complete`. A run
  that did not complete — `incomplete` (a stall or the step ceiling; it may
  still have delivered a best-effort answer) or `blocked` — exits non-zero, so
  scripts and the build button treat it as failure rather than success; a fatal
  startup or configuration error also exits non-zero. The status string
  (`complete` / `incomplete` / `blocked`) still distinguishes *why* for callers
  that need more than success/failure, but the exit code never reports a
  non-`complete` run as clean.
- **Cancellation.** A run is aborted at once (C8) — a model request is cut off
  mid-stream and a running command is killed — so the surface returns
  immediately instead of waiting for the model to finish; the session and its
  partial transcript are kept. The gesture differs by surface: on the automate
  surface input is read *concurrently* with the run, so a `/cancel` line that
  arrives mid-run interrupts it, and `/cancel` is the only cancel command
  listed in its `/help`; on the human surface the run owns the line editor, so
  a double `Esc` is the interrupt gesture, `/cancel` is not offered (absent
  from `/help` and rejected as an unknown command), and a `/cancel` typed
  mid-run is not delivered. Both surfaces reach the same cancel signal.
- **Clarifying questions.** If the loop finishes with a question (C1), it is
  printed like any answer; the user's reply is the next goal, in the same
  session, so the conversation continues.
- **Text only.** Input and output are text (`modality`, C7).

### Configuration

Prop reads one configuration source at startup, owned here and passed
down; each component reads only its own keys. The source is a single JSON
file, selected by `--config` / `-c` or the `SUDOER_CONFIG` environment
variable and defaulting to `sudoer.json` in the process working directory.
The name is tier-agnostic: Prop, Pilot, and Orbit all read `sudoer.json`.

A missing config is a fatal startup error, not a silent default: before any
session opens, the resolved path it looked for and a copy-pasteable sample
config (the same shape as the README example) are written to stderr, and the
process exits non-zero. The user can create the file in place and retry.

| Key | Owner |
| --- | --- |
| `provider kind`, `base_url`, `api_key`, `model`, `context_window`, `sampling` | providers (C2) |
| `workspace_root`, `web.enabled`, `web.search_url`, `web.deny_hosts` | tools (C3) |
| `session_dir` | sessions (C5) |

`workspace_root` is optional: when omitted it defaults to the process
working directory at startup, and it may be changed during a session with
`/workspace`.

The budget bounds and per-tool-class timeouts are compiled-in constants, not
configuration — they are built-in guards (`reliability`, C8). Provider
settings are fixed for the process; session-level, non-policy settings
(active session, workspace root, verbosity) may change during a session via
commands. User-tunable policy and model/provider switching arrive with
`safety` (C10) and the Pilot catalog (C2).

## Pilot

Pilot keeps both Prop surfaces untouched and makes the **REST API the
spine**: one resident server hosts a built-in web page and everything
else — messenger adapters, scripts, other machines — connects to it as a
client. New CLI commands cover the Pilot components; new config keys are
frozen in [config-pilot.schema.json](agent_pilot/config-pilot.schema.json).

| Command | Effect |
| --- | --- |
| `/schedule <when> <goal>` | set a scheduled task, one-shot or recurring (C11) |
| `/remind <when> <goal>` | one-shot sugar for `/schedule` (C11) |
| `/tasks [cancel <id> \| run <id>]` | list pending tasks; cancel or fire one (C11) |
| `/memory [query \| rebuild]` | list or search memory notes; rebuild the embedding index (C9) |
| `/model [name]` | show the catalog, or switch `main` at the next goal boundary (C2) |
| `/channels` | list registered channels and their status (C6) |

### REST server (the spine)

`sudoer-pilot serve` runs a single-owner REST server. The web page,
messenger adapters, scripts, and the scheduler/background runner all
live in or talk to this one process. It is what makes Pilot a personal
assistant rather than a REPL you must keep open. `serve`, `tick`,
`install`, `uninstall`, and `status` are CLI **subcommands**, dispatched
before any goal is parsed; the binary identifies itself as
`sudoer-pilot` in `--version` and `--help`, never Prop's name.

- **Auth.** One bearer token (`http.token`, generated and printed once
  to stderr when absent). API clients send
  `Authorization: Bearer <token>`; the web page logs in with the token
  and receives a signed, `HttpOnly`, `SameSite` session cookie. It is a
  **single owner**: no accounts, no per-user permissions (multi-user
  access is `C15`, Orbit). Every endpoint but the login page and static
  assets requires auth.
- **Bind.** Loopback by default; `http.bind` may name a LAN/interface
  address so adapters on another host can connect. When it is not
  loopback, the token is the only gate, so the server refuses to start
  without a token.
- **Endpoints.** Frozen in
  [http-api.schema.json](agent_pilot/http-api.schema.json): sessions
  list/search/new/info; one streamed run per session (SSE events
  `delta`, `tool`, `result`), cancel; channels list/register/remove;
  inbound `POST /channels/{id}/messages`; scheduled tasks; non-secret
  config get/update; secret *names*; service status. A run POSTed to a
  busy session is `409`. The server reuses the automate run machinery
  and the human surface's delta callbacks; it never renders styled
  output.
- **Supervision.** The service reloads the task store, arms the next
  wake (`C11`), and resumes unfinished background runs on start
  (`C8`). It shuts down cleanly on SIGTERM.
- **Wake-only mode.** The same binary serves `sudoer-pilot tick` — a
  one-shot fire-and-exit used by the OS scheduler (`C11`) — and
  `sudoer-pilot install` / `uninstall` / `status` manage the OS hook.

### Web page

The first-party non-technical client, served by the server at `/`. It is
a client of the REST API, not a special path.

- **Pages.** `chat` (talk to the agent), `config` (view and edit
  non-secret configuration; secrets appear as names only), and `status`
  (service state, next fire, channels).
- **Auth.** A login form takes the bearer token once and sets the
  session cookie; subsequent page and `fetch` calls ride the cookie.
- **Chat.** Streams the reply over SSE from the same run endpoint;
  history is the channel's session (`C5`).
- **Config.** Reads `GET /config` and writes `PUT /config` for
  non-secret keys only; the server validates the merged object against
  the config schema before it takes effect, and a change is logged
  (`C10`). Secret values are never sent to the page, in either
  direction.
- **Presentation.** Basic, server-rendered HTML, inline; no full-screen
  takeover.

### Channels and messenger adapters

A **channel** is a registered REST client with a stable id. The built-in
`web` channel is the web page; a **messenger adapter** is an external
program (possibly on another machine) that implements the same contract
for a messaging service. This is how non-CLI users reach the agent, and
how new messengers are added without touching Pilot.

- **Registration.** Channels come from config (`channels: [...]`, `C6`)
  or are registered over the API; each is
  `{id, kind?, outbound_url?, outbound_secret?, allow_from?, enabled?}`,
  frozen in [channel.schema.json](agent_pilot/channel.schema.json).
- **Inbound.** An adapter POSTs `{from, text}` to
  `/channels/{id}/messages`. If the channel is enabled and the sender is
  permitted (`allow_from`, empty = any), the text becomes a goal in that
  channel's session (`C5`, channel-keyed) and runs exactly like a CLI
  goal. Otherwise the request is refused (`403`) and logged; its text
  never reaches the model (`C10`).
- **Outbound.** Pilot delivers a reply, or a scheduled/background
  result, by POSTing `{to, text, at, task?}` to the channel's
  `outbound_url`; the `web` channel delivers over SSE instead. The
  adapter must expose an endpoint Pilot can reach (loopback or LAN).
- **Adapters.** Telegram and Signal are first-party reference adapters,
  specified by [adapter.md](agent_pilot/adapter.md) and generated by the
  builder from that blueprint; each bridges its service to this contract
  and sits outside the agent core and outside the gate. An adapter's own
  service credentials live with the adapter, never in Pilot; a channel's
  optional `outbound_secret` is the shared secret Pilot injects as a
  bearer header on outbound delivery (`C10`).
- **Outbound from the agent.** The `send` tool (`C3`) delivers to a
  channel under policy (`C10`); a scheduled task or background run
  delivers to its task channel the same way (`C11`).
- **Untrusted input.** Inbound channel text is data, not instructions,
  exactly like fetched web content (`C3`).

### Tasks in the surface

At startup, tasks that came due while away are listed or fired per
`autonomy.catch_up` (`C11`). Between runs, a fired task is echoed like a
goal and its run proceeds exactly like a user goal. On the web page a
proactive message is marked so the user can tell it from a reply.
