# Prop Build Gate

> Status: draft · Version 0.8 · **Current tier: Prop**

The gate is how Prop is judged done. Per [arch.md](../arch.md), every rung
must pass its eval suite before it may build the next: the gate is a fixed
set of coding tasks run against a deterministic scripted provider so results
are reproducible offline. Passing it is what permits Prop to build Pilot
(`C9`–`C11`).

## Frozen constants

The gate pins the compiled-in Prop guards, since they are deliberately not
configuration (`C8`). A gate failure after changing one of these is a
blueprint change, not a test bug.

| Constant | Value |
| --- | --- |
| `stall budget` | a run ends after 3 consecutive non-progress steps (a repeat, error, or timeout) |
| `step ceiling` | 200 steps, a runaway safety net only; productive steps are never cut off by count |
| `timeout` | per tool class: 30s provider calls (inactivity when streamed), 10m `run_command`, 20s web calls |
| `web bounds` | 256 KB per fetch, 10 search results (`kWebMaxBytes`, `kWebMaxResults`) |
| best-effort | one final provider call with tools withheld; answer is the completion text, else a local summary; status `incomplete` |

## Deterministic scripted provider

- Implements the provider boundary (`C2`) and replays a script
  ([script.schema.json](script.schema.json)), one step per provider call.
- Each step is a normalized completion
  ([completion.schema.json](completion.schema.json)) or a simulated error:
  `timeout` is recoverable (`C2`, `C8`), `unrecoverable` blocks.
- A completion may carry a `plan` (C1); it replaces the session plan. It may
  also carry `reasoning` (C2), the post-parse form of a `<think>` block; the
  gate injects it after wire parsing, so `<think>` extraction itself is
  unit-tested per adapter, not here.
- A task scripts every call the session makes, including the best-effort
  call after a run stalls or hits the step ceiling and the tools-withheld
  summarization call when compaction fires (the watermark is reached
  deterministically via a small `context_window` override and bulk
  `run_command` output, whose tokens are not re-fetchable and so do count).
- A completion may carry several `tool_calls` (`C1`): the suite exercises
  both a single call and a batch, and read-only calls in a batch run in
  parallel. The ordered tool-call log records every call and its observation.
- No network, no wall-clock: identical output every run.
- **Web tools stay out of scope, except the denial path.** The gate default
  config sets `web.enabled: false`, so no task can fetch. One carve-out: a
  task may enable the web tools and deny the target host
  (`web.deny_hosts`), because the host check runs before any socket opens —
  [guard-denied](tasks/guard-denied.json) covers that block offline. Size
  and parsing logic stays unit-tested with an injected HTTP client, not
  here.
- **Coverage boundary.** The scripted provider injects a completion *after*
  wire parsing, so a specific endpoint's wire format (OpenAI JSON, ollama)
  is out of gate scope and unit-tested per adapter. It does exercise `C2`'s
  completion-to-action normalization, including *no tool call becomes a
  finish*.
- **Other out-of-gate behavior.** `job` needs runtime-generated ids and
  timing, and the host shell is platform-specific; background jobs and the
  Windows/macOS shell paths are unit-tested with an injected clock and
  process, not here. A task whose `run_command` strings assume the POSIX
  host shell declares `"host_shell": "posix"`; the runner skips such tasks
  (reported as SKIP, never as failures) on platforms without a POSIX host
  shell, where the shell paths are unit-tested instead.

## Procedure

1. Materialize the task's `workspace` into a fresh temp dir and use it as
   `workspace_root` (with the session dir inside it).
2. Load the gate default config, deep-merged with the task's `config`
   (defaults: `provider.kind = ollama`, `model = scripted`,
   `context_window = 8192`); inject the scripted provider with the task's
   `script`.
3. Drive the **automation** surface (`C6` with `--automate`) with the task's
   `turns` (goals and commands), ending with `/exit`. The styled human
   surface and real streaming are out of gate scope; the scripted provider
   takes the one-shot path. Streaming and the wire formats are unit-tested per
   adapter.
4. Capture the per-goal `runResult`s, the final session (transcript and
   plan), the final workspace, and the ordered tool-call log with each
   call's observation.
5. Compare against `expect`: `status`/`answer`/`runs`, `plan`,
   `sessionPersisted`, `stdoutContains`, `files`, `tools`, and
   `observations`. Record pass/fail.

## Pass criteria

- Every task in [`tasks/`](tasks/) passes.
- The suite is deterministic: reruns produce identical results.
- No network access and no wall-clock dependence.
- Any failed task is a gate failure; Prop may not build Pilot until the
  whole suite is green.

## Built-in tool argument contracts

The concrete argument shapes the scripts rely on, frozen in
[tool.schema.json](tool.schema.json):

| Tool | Arguments |
| --- | --- |
| `read` | `{path, offset?, limit?}` — 0-based `offset` plus `limit` lines, returned as text |
| `write` | `{path, content}` |
| `edit` | `{path, old, new, replace_all?}` — replace the unique occurrence; error if absent or ambiguous |
| `multi_edit` | `{path, edits:[{old, new, replace_all?}]}` — an ordered batch in one step |
| `glob` | `{pattern, path?}` |
| `search` | `{pattern, path?}` |
| `run_command` | `{command}` |
| `job` | `{action, command?, id?}` — out of gate scope (needs runtime ids) |
| `diff` | `{path?}` — changes against the session baseline |
| `restore` | `{path?}` — revert to the session baseline |
| `web_fetch` | `{url}` — fetch one URL as text; the gate covers only its denial path |

## Coverage

| Task | Exercises |
| --- | --- |
| [answer-from-read](tasks/answer-from-read.json) | end-to-end path; `finish` |
| [write-file](tasks/write-file.json) | `C3` write; workspace effect |
| [edit-file](tasks/edit-file.json) | `C3` edit; workspace effect |
| [glob-orientation](tasks/glob-orientation.json) | `C3` glob; orientation |
| [read-range](tasks/read-range.json) | `C3` read line range |
| [edit-replace-all](tasks/edit-replace-all.json) | `C3` edit `replace_all` |
| [multi-edit](tasks/multi-edit.json) | `C3` multi_edit batch; workspace effect |
| [edit-ambiguous-recovery](tasks/edit-ambiguous-recovery.json) | `C3` edit ambiguity error; `C1` re-iterate |
| [search](tasks/search.json) | `C3` search |
| [run-command](tasks/run-command.json) | `C3` run_command; workspace effect (POSIX shell) |
| [diff-restore](tasks/diff-restore.json) | `C3` baseline `diff`/`restore`; `C5` baseline |
| [parallel-reads](tasks/parallel-reads.json) | `C1`/`C2` batch tool calls; parallel read-only |
| [tool-error-recovery](tasks/tool-error-recovery.json) | `C3` error observation; `C1` re-iterate |
| [guard-denied](tasks/guard-denied.json) | `C3` network guard denial (`web.deny_hosts`, offline); `C1`/`C8` block |
| [provider-timeout-recovery](tasks/provider-timeout-recovery.json) | `C2`/`C8` recoverable; `C1` re-iterate |
| [provider-unrecoverable](tasks/provider-unrecoverable.json) | `C2`/`C8` unrecoverable; `C1` block |
| [stall-exhausted](tasks/stall-exhausted.json) | `C1`/`C8` stall detection (repeated steps); best-effort |
| [timeout-stall](tasks/timeout-stall.json) | `C1`/`C8` stall on non-progress timeouts; local best-effort summary |
| [sustained-progress](tasks/sustained-progress.json) | `C1`/`C8` productive steps run past the old step cap to a finish |
| [context-overflow](tasks/context-overflow.json) | `C4` overflow; `C1` block |
| [compaction](tasks/compaction.json) | `C4` watermark fold at a goal boundary (scripted brief); `C5` continuity (POSIX shell) |
| [session-continuity](tasks/session-continuity.json) | `C5` continuous session; two goals; persistence |
| [plan-persistence](tasks/plan-persistence.json) | `C1` plan update; `C5` persistence |
| [repl-command](tasks/repl-command.json) | `C6` command handling; `/plan` |

## CLI smoke (`C6`)

Separate from the task suite, at the real process boundary:

- a one-shot `complete` run prints the answer to stdout and exits `0`;
- a one-shot `blocked` run writes a diagnostic to stderr and exits non-zero;
- an interactive run fed a goal and `/exit` on stdin prints the answer and
  exits `0`.

## Schemas

| File | Defines |
| --- | --- |
| [completion.schema.json](completion.schema.json) | normalized model completion (with optional plan) |
| [script.schema.json](script.schema.json) | the scripted response sequence |
| [task.schema.json](task.schema.json) | one eval task (turns and expectations) |
| [session.schema.json](session.schema.json) | the persisted session file |
