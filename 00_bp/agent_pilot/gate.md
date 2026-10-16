# Pilot Build Gate

> Status: draft · Version 0.2 · **Current tier: Prop**

The gate is how the built Pilot is judged done. Per [arch.md](../arch.md),
a rung must pass its eval suite before it may build the next — and a
superset tier is gated on a superset suite: **the Pilot gate runs every
Prop task plus the Pilot tasks below**, against the built `sudoer-pilot`
binary, offline except loopback stubs and injected-adapter fakes,
deterministically. Prop's own gate ([agent_prop/gate.md](../agent_prop/gate.md))
stays the coding regression suite; a Pilot change that breaks a Prop task
is a gate failure here too.

Pilot's earned capabilities reach outside the process — the OS scheduler,
the messenger channels, the embedder. None of them run for real in the
gate:
each is an **injected adapter** pinned to a deterministic fake, and the
harness drives the fake directly. That is what keeps a personal assistant
testable offline.

## Frozen constants

Everything pinned at Prop stands (stall budget, step ceiling, timeouts,
web bounds, best-effort). Pilot additions, compiled-in as at Prop:

| Constant | Value |
| --- | --- |
| provider retry | inherited from Prop: 2 retries per call, backoff 0.5s ×4 capped at 30s; the Pilot sleep adapter is pinned to a no-op in the gate |
| memory `memory_search` | top 10 results, deterministic hybrid rank (semantic + tag/title/body, then id order) |
| recall injection | top 10 notes, capped (compiled-in token budget); omitted when empty |
| session search | top 10 index hits; transcript grep capped the same way |
| `http` tool | web-class timeout and the Prop web size cap (256 KB) |
| channel confirm | block-and-ask timeout 120s (injected clock); timeout denies |
| task concurrency | 2 background runs at once; excess queue |
| idempotent fire | one fire per `(task id, due instant)`; recorded before the run |
| SSE stream | `delta`* events, then exactly one `result` |

## Harness extensions

The Pilot gate extends the Prop harness contract
([agent_prop/gate.md](../agent_prop/gate.md)); everything not listed here
is unchanged.

- **Scripted chain.** A task may set `scripts` (ordered) instead of
  `script`; the harness injects one scripted provider per entry onto the
  configured `providers` chain — never config-reachable, as at Prop. A
  single-provider task keeps using `script`.
- **Injected clock.** A task may pin `clock.now` (ISO 8601). Every
  due-time comparison, log timestamp, task resolution, and confirm
  timeout uses it; no wall-clock anywhere.
- **Injected sleeper and notifier.** Backoff sleeps no-op; `notify`
  delivers to a recorder, not a desktop. Expectations may assert
  recorded notifications.
- **Injected scheduler and time travel.** The OS scheduler is a fake:
  `install` records the unit/wake it would write (assertable) without
  touching the host. The harness advances the injected clock and issues
  `tick`s — `task.advance(now)`, or driving `sudoer-pilot tick` — which
  fire due tasks exactly as a real OS wake would. No real OS scheduler
  runs; the platform unit files are unit-tested from the recorded shape.
- **Injected channels.** Channels are fakes: the task registers channels
  (`channels.register`) and queues **inbound** messages
  (`channels.inbound: [{channel, from, text}]`); the harness records
  **outbound** deliveries. Permitted senders, disallowed senders, and
  unknown or unauthenticated requests are all drivable, so admission and
  refusal are both gate-covered. No network call is made for a channel,
  and no adapter process is launched.
- **Injected embedder.** Memory's embedder is a deterministic fake:
  a fixed hash-to-vector function, so "similar" notes can be authored to
  collide and ranking is byte-stable. A task may instead set the
  embedder to `fallback` to exercise the lexical path when the real
  embedder is unavailable. The embedding index is asserted as a derived,
  rebuildable artifact.
- **Loopback stubs.** A task may declare `stubs`: named canned HTTP
  responders (`{status, headers?, body}`) that the harness binds to
  `127.0.0.1` ephemeral ports. `{{stub:name}}` in a goal or script
  argument is replaced with the bound origin before driving. No
  non-loopback network is permitted; a task that reaches elsewhere fails.
- **Prompt recording.** The scripted provider records every assembled
  prompt. `expect.prefixStable` asserts that, within each goal run and
  each fold segment, every prompt is a prefix of the next — the C4
  cache contract, pinned offline. The injected recall segment is
  asserted to be goal-stable by the same property.
- **API driver.** A task with an `api` block is driven over the real
  served API by **spawning the built `sudoer-pilot serve` as a separate
  process** on a loopback ephemeral port (token and port from the task
  config), driven through the same scripted-provider seam as the CLI
  smoke — the harness must NOT instantiate the server class in-process,
  or the shipped `serve` subcommand goes untested. It then performs the
  declared sequence — session create, run POST reading the SSE stream to
  its `result`, cancel, task list, `GET`/`PUT /config`, channel inbound,
  login — asserting HTTP shapes and status codes, and finally sends
  SIGTERM and asserts a clean exit. Busy-session `409`, unauthorized
  `401`, disallowed `403`, and concurrent interleavings are unit-tested
  with injected providers, not here; this task pins the API's
  deterministic path.
- **Pilot stores in the sandbox.** The gate default config points
  `memory_dir`, `tasks_file`, `secrets_file`, `policy.log`, and
  `log_file` inside the task's temp workspace, so expectations can read
  them and nothing leaks out of the sandbox.

## Extended expectations

Beside every Prop expectation (`status`, `answer`, `runs`, `plan`,
`sessionPersisted`, `stdoutContains`, `files`, `tools`, `observations`),
all frozen in [task-pilot.schema.json](task-pilot.schema.json):

| Key | Asserts |
| --- | --- |
| `prefixStable` | the recorded prompts satisfy the C4 prefix property |
| `memory` | expected memory notes by id: `{id: substring-of-body}`; unlisted ids ignored |
| `recall` | expected memory ids injected into the first prompt of a goal (order-insensitive) |
| `embeddings` | the embedding index: `{rebuilt: bool, model?: string, ids?: [...]}` against the derived file |
| `tasks` | expected scheduled-task statuses by goal substring, and optional `next_due` |
| `fired` | the ordered `{task, due}` fire log (idempotency: no duplicates) |
| `notifications` | expected recorded notifications (`{title?, message}` substrings, in order) |
| `channels` | expected recorded outbound channel deliveries (`{channel?, to, message}` substrings, in order) |
| `scheduler` | the recorded OS wake units/paths the fake scheduler captured |
| `logs` | expected `{kind, tool?, detail?}` fields of JSONL log lines, in order |
| `policy` | expected `{event, tool}` decision-log lines, in order |
| `api` | the API driver's declared sequence and its results |

## Procedure

As at Prop, with the additions above: materialize the workspace, load
the gate defaults deep-merged with the task config, inject the scripted
chain, clock, sleeper, notifier, scheduler, channel adapters, and
embedder, then drive — the automation surface for CLI tasks, the API
driver for `api` tasks (a spawned `serve` process), and `tick`s / inbound
channel messages for autonomy and channel tasks — and compare against
`expect`, now including
the Pilot stores (memory files and embedding index, scheduled tasks,
decision log, JSONL log, recorded notifications and channel deliveries).

## Pass criteria

- Every task in [`tasks/`](tasks/) **and** every task in
  [`../agent_prop/tasks/`](../agent_prop/tasks/) passes on the built
  `sudoer-pilot`.
- The CLI smoke runs the built binary's **own subcommands** — `serve`,
  `tick`, and `install` are spawned as processes, not emulated in-process
  — and `--version`/`--help` name the Pilot agent. A smoke that
  instantiates the server class directly, or that leaves Prop's name in
  the CLI, does not count as passing.
- Deterministic reruns; no non-loopback network; no wall-clock; no real
  OS scheduler, messenger service, or embedder.
- Any failed task is a gate failure; root-cause it to the builder
  (Prop defect) or to the blueprint (missing/vague instruction), fix
  there, and re-run — never weaken the gate.

## Coverage

| Task | Exercises |
| --- | --- |
| [memory-write-recall](tasks/memory-write-recall.json) | `C9` write in one session, recall in another; cross-session store |
| [memory-search-rank](tasks/memory-search-rank.json) | `C9` deterministic hybrid ranking (semantic + tag before body) |
| [semantic-recall](tasks/semantic-recall.json) | `C9`/`C4` paraphrase recall via the fake embedder; automatic injection |
| [memory-lexical-fallback](tasks/memory-lexical-fallback.json) | `C9` lexical fallback when the embedder is unavailable |
| [embedding-index-rebuild](tasks/embedding-index-rebuild.json) | `C9` derived index rebuilds deterministically |
| [session-search](tasks/session-search.json) | `C5` index + `/sessions` search across sessions |
| [channel-session](tasks/channel-session.json) | `C5` channel-keyed session; web/messenger continuity |
| [policy-network-deny](tasks/policy-network-deny.json) | `C10` policy deny on the `http` tool (offline, pre-socket) |
| [policy-confirm-deny](tasks/policy-confirm-deny.json) | `C10` confirm matcher on automate → immediate denial, blocked |
| [secrets-redaction](tasks/secrets-redaction.json) | `C10` secret injection at the connector + scrub from observation |
| [channel-inbound](tasks/channel-inbound.json) | `C6` permitted channel message → goal → reply |
| [channel-denied](tasks/channel-denied.json) | `C10`/`C6` disallowed sender refused, never reaches the model |
| [send-confirm](tasks/send-confirm.json) | `C10` confirm on `send`; channel-surface ask/timeout |
| [config-api](tasks/config-api.json) | `C6` non-secret config get/update over the API; secret values rejected |
| [scheduler-wake](tasks/scheduler-wake.json) | `C11` OS-wake `tick` fires a task with no interactive session |
| [background-task](tasks/background-task.json) | `C11` delegated run completes after the CLI exits; delivered |
| [recurring-task](tasks/recurring-task.json) | `C11` recurrence advances `next_due`; fires again |
| [catchup-missed](tasks/catchup-missed.json) | `C11` overdue one-shot reported vs fired per policy |
| [task-cancel](tasks/task-cancel.json) | `C11` `/tasks cancel`; cancels and logs |
| [reminder-mid-run](tasks/reminder-mid-run.json) | `C11` a due task fires between runs; system goal; `notify` |
| [reminder-at-startup](tasks/reminder-at-startup.json) | `C11` due-while-away reported, not auto-run (report policy) |
| [provider-failover](tasks/provider-failover.json) | `C2`/`C8` retry then chain failover to completion |
| [prompt-prefix-stability](tasks/prompt-prefix-stability.json) | `C4` append-stable segments (recorded prompts) |
| [http-connector-task](tasks/http-connector-task.json) | `C3` `http` tool against a loopback stub |
| [http-api-goal](tasks/http-api-goal.json) | `C6` served API end-to-end (SSE result) |
| [concurrent-sessions](tasks/concurrent-sessions.json) | `C5`/`C6` two API sessions, both persisted and indexed |
| [structured-log-shape](tasks/structured-log-shape.json) | `C8` JSONL log kinds and order |

## CLI smoke (`C6`)

Every check spawns the **built `sudoer-pilot` binary** (via the
scripted-provider seam, no real LLM) — never an in-process shortcut.

The Prop smoke, on the Pilot binary: one-shot `complete` exits 0;
one-shot `blocked` exits non-zero; an interactive goal + `/exit` exits 0.

Plus Pilot checks, each a required assertion:

- **Identity.** `sudoer-pilot --version` prints `sudoer-pilot <version>`
  and `sudoer-pilot --help` names the Pilot agent and shows
  `Usage: sudoer-pilot …`. A copied Prop entrypoint that still says
  `sudoer-prop` / "Prop coding agent" fails here.
- **`serve`.** `sudoer-pilot serve` is a dispatched subcommand: it boots
  the REST server, serves one API run to its SSE `result`, and shuts down
  cleanly on SIGTERM (exit 0).
- **Web/channel.** The web login exchanges the token for a session cookie,
  and the inbound channel endpoint round-trips.
- **Config.** `GET /config` returns the effective non-secret config and
  `PUT /config` rejects a secret value.
- **`tick`.** `sudoer-pilot tick` with a due task fires it and exits 0.
- **`install`.** `sudoer-pilot install` reports the recorded wake unit
  without touching the host.

## Schemas

| File | Defines |
| --- | --- |
| [task-pilot.schema.json](task-pilot.schema.json) | one Pilot eval task (Prop fields + Pilot extensions) |
| [config-pilot.schema.json](config-pilot.schema.json) | the Pilot configuration object |
| [tools-pilot.schema.json](tools-pilot.schema.json) | Pilot tool argument contracts |
| [memory.schema.json](memory.schema.json) | memory notes, the embedding index, and search hits |
| [autonomy.schema.json](autonomy.schema.json) | scheduled tasks, the task store, and fire records |
| [channel.schema.json](channel.schema.json) | registered channels and inbound/outbound message shapes |
| [policy.schema.json](policy.schema.json), [http-api.schema.json](http-api.schema.json), [log.schema.json](log.schema.json) | the Pilot component stores and wire shapes |

The Prop gate schemas (`completion`, `script`, `session`) are reused
as-is from [`../agent_prop/`](../agent_prop/).

Adapters are outside the gate ([adapter.md](adapter.md)): the fake
channels stand in for them, so the REST contract they use is covered
here, but no adapter process is built or launched by the suite.
