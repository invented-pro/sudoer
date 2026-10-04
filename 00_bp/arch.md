# Architecture

> Status: draft · Version 0.4 · **Current tier: Prop**

Every agent, at its core, is one loop. Everything else is scope built
around that loop.

## The core loop

```plantuml
@startuml
skinparam backgroundColor transparent
skinparam defaultFontColor #64748B
skinparam activityBackgroundColor #E8F5E9
skinparam activityBorderColor #64748B
skinparam activityFontColor #1F2937
skinparam arrowColor #64748B
start
:receive a goal;
while (not stalled AND steps < ceiling AND not blocked) is (yes)
  :decide the next action (LLM);
  if (action is finish?) then (yes)
    :answer;
    stop
  else (no)
    :act — call a tool;
    :observe the result;
  endif
endwhile (no)
if (blocked?) then (yes)
  :abort (policy denied or unrecoverable error);
else (no)
  :answer best-effort (stalled or ceiling reached);
endif
stop
@enduml
```

A goal is one user request; a run is one execution of this loop over it.
The model ends a run by choosing a `finish` action that produces the
answer — a clarifying question to the user counts as a finish, and the
reply arrives as a new goal. Otherwise it keeps calling tools until the run
stalls, hits the step ceiling, or is blocked. Tool errors surface as
observations and are retried within the loop (each retry counts toward the
stall budget unless it makes progress); a policy denial or an unrecoverable
error marks the run blocked. If the run stalls or hits the ceiling first, it
still answers — best-effort, marked incomplete — rather than aborting
silently.

The loop is what every tier shares. A tier is defined by the *work it is
for*, not by the components it is built from: `Prop` is for coding (turning
instructions into working artifacts and tool actions), `Pilot` extends it to
cover everyday personal tasks end-to-end, and `Orbit` extends `Pilot` to run
long, multi-step work autonomously. Each tier is a superset of the one below,
so the same loop runs everywhere; what changes is how far it is expected to
carry a task — a plan-driven interactive loop at `Prop` that streams and can
drive both a styled human CLI and a plain automation surface, reflection and
replanning at `Orbit`; session continuity at `Prop` versus durable recall at
`Pilot`; on-demand use versus autonomous long-horizon work.

## Tier scope

Three tiers, each a superset of the one below: **Prop → Pilot → Orbit**. A
tier is classified by function — the kind of work it is meant to do — rather
than by the components it happens to contain.

| Tier | Function — what the work is |
| --- | --- |
| **Prop** | Coding. Take an instruction and deliver: follow it strictly, and produce working binary artifacts and tool actions flawlessly. |
| **Pilot** | Personal assistant. Everything Prop does, plus full-coverage support for everyday personal tasks end-to-end. |
| **Orbit** | Autonomy. Everything Pilot does, plus fully autonomous execution of super-long, multi-step tasks. |

Function defines the tier; components implement it. Each tier is a prefix of
the same component list (`C1`–`C16`), so the scopes stack: `Pilot` includes
every `Prop` capability, and the implementation of a higher tier is a
superset of the lower one's.

```plantuml
@startuml
skinparam backgroundColor transparent
skinparam defaultFontColor #64748B
skinparam rectangle {
  BorderColor #64748B
  FontSize 15
}
rectangle "<color:#1F2937>Prop\ncoding · artifacts" as N #E8F5E9
rectangle "<color:#1F2937>Pilot\npersonal assistant · full coverage" as M #FFF8E1
rectangle "<color:#1F2937>Orbit\nautonomous · long-horizon" as A #F3E5F5
N -up-> M : <color:#64748B>adds everyday-task coverage
M -up-> A : <color:#64748B>adds autonomy · long-horizon execution
@enduml
```

Arrows mark newly introduced components (numbered `C1`–`C16` below);
components already present deepen within a tier — at Pilot, `loop`,
`providers`, `tools`, `context`, `sessions`, `interface`, and `reliability`
all strengthen without being new. Each component's detailed design lives in
its own file, named `C<n>_<component>.md` (for example
[C1_loop.md](C1_loop.md)). The Prop tier's components are assembled and
profiled in [agent_prop.md](agent_prop.md), and their interface contracts
are frozen in [schemas.md](schemas.md).

### Detailed breakdown

```plantuml
@startwbs
skinparam backgroundColor transparent
<style>
wbsDiagram {
  node {
    BackgroundColor #F1F5F9
    FontColor #1F2937
    LineColor #64748B
  }
  arrow {
    LineColor #64748B
  }
}
</style>
* Sudoer
** Prop (introduces C1–C8)
***:
**loop** (C1)
plan-driven multi-step ReAct, streams, resumable
;
***:
**providers** (C2)
one (openai-compatible or ollama)
;
***:
**tools** (C3)
read/write/edit, run_command, local search
;
***:
**context** (C4)
transcript in window + compaction
;
***:
**sessions** (C5)
continuous, persistent across runs
;
***:
**interface** (C6)
styled human CLI + plain automation CLI
;
***:
**modality** (C7)
text
;
***:
**reliability** (C8)
progress-driven budget, per-tool timeouts, in-loop retry
;
** Pilot (adds C9–C11)
***:
**providers** (C2)
multi-provider + fallback, model catalog
;
***:
**tools** (C3)
service and connector tools
;
***:
**context** (C4)
prompt caching
;
***:
**sessions** (C5)
session store + search
;
***:
**interface** (C6)
HTTP API (beside the interactive CLI)
;
***:
**modality** (C7)
text (unchanged)
;
***:
**reliability** (C8)
structured logs, provider retry/backoff, concurrency
;
***:
**memory** (C9)
durable Markdown notes + search
;
***:
**safety** (C10)
workspace roots, risky-action confirm
;
***:
**autonomy** (C11)
user-set reminders (fire while the agent runs)
;
** Orbit (adds C12–C16)
***:
**loop** (C1)
reflection / replanning / self-critique
;
***:
**providers** (C2)
provider registry, OAuth, per-model params
;
***:
**tools** (C3)
app + messaging connectors, browser
;
***:
**context** (C4)
pluggable context engine, retrieval over history
;
***:
**sessions** (C5)
multi-device sync, lineage
;
***:
**interface** (C6)
gateway daemon, TUI/desktop, chat apps, IDE
;
***:
**modality** (C7)
vision, audio
;
***:
**reliability** (C8)
tracing, cost accounting, self-heal
;
***:
**memory** (C9)
vector / semantic long-term store, pluggable
;
***:
**safety** (C10)
scoped capabilities, sandbox isolation, audit log
;
***:
**autonomy** (C11)
autonomous background / scheduled jobs
;
***:
**execution** (C12)
code execution backends
;
***:
**multi-agent** (C13)
subagents / orchestration
;
***:
**extensibility** (C14)
plugins, MCP, hooks, user-authored skills
;
***:
**access** (C15)
auth, pairing, profiles, multi-user
;
***:
**self-evolution** (C16)
persona/style, skills-from-experience, self-evaluation, trajectories
;
@endwbs
```

Components are numbered `C1`–`C16` in order of first introduction: each tier
is a prefix of the same list, so a capability shared by several tiers stays
on one horizon (`loop` is always `C1`, `sessions` always `C5`, and so on).
This component map is the *implementation* view; the tier names and the table
above are the *function* view. Prop enforces a fixed set of built-in guards;
`safety` (`C10`) is where those become configurable policy.

## Build ladder

Self-implementation runs *through* the tiers: **Prop implements Pilot,
Pilot implements Orbit**. It is the vertical axis, and the tiers are
its rungs. Prop is produced once by a human-driven bootstrap; every tier
above it is built by the tier below. Orbit, once built, may also modify
itself.

Every rung includes Prop's coding capability — Pilot and Orbit are supersets
of Prop, not different products — so each can work on the codebase. A rung
must pass its build gate before it may build the next: a gate is the tier's
eval suite — a fixed set of tasks the rung must complete, run against a
deterministic provider (scripted model responses) so results are
reproducible offline. This keeps a regression at one rung from silently
corrupting the one above.

```plantuml
@startuml
skinparam backgroundColor transparent
skinparam defaultFontColor #64748B
skinparam rectangle {
  BorderColor #64748B
  FontSize 15
}
rectangle "<color:#1F2937>Prop\ncoding · artifacts" as C #E8F5E9
rectangle "<color:#1F2937>Pilot\npersonal assistant · full coverage" as P #FFF8E1
rectangle "<color:#1F2937>Orbit\nautonomous · long-horizon" as A #F3E5F5
C -down-> P : <color:#64748B>implements
P -down-> A : <color:#64748B>implements
note left of P
  <color:#1F2937>every rung gated by its eval suite
end note
@enduml
```

The builder need not *possess* the capability it builds: Prop can write
memory or safety code without having memory or safety, just as a bootstrap
compiler compiles features it cannot run itself. What Prop does need is
enough to do real work on the codebase it is generated from — a multi-step
loop, file read/write/edit, `run_command`, and search.

Self-hosting is how the ladder is built, so Prop's envelope is normative.
The seed MUST be able to build and pass the Pilot gate, and MAY rebuild
itself. Envelope limits — budget, timeouts, context, session continuity —
are part of Prop's contract, not preferences; a limit that prevents
self-hosting is a Prop defect, not a lifestyle choice. Prop must therefore
run as a continuous interactive session deep enough to compile and test the
code it writes; it must not be one-shot or memoryless.

## Tier intent

- **Prop** — coding. An interactive agent that follows instructions strictly
  and delivers working binary artifacts and tool actions: a plan-driven
  multi-step loop, file read/write/edit, `run_command`, search, built-in
  `web_search`/`web_fetch`, a continuous session with on-disk continuity,
  and in-window compaction. It is the seed produced by the human-driven
  bootstrap, from which the higher tiers are self-built. It builds and runs
  as a native executable on Linux, macOS, and Windows. No durable
  *semantic* memory, only built-in guards (no configurable policy), no server.
- **Pilot** — personal assistant, full coverage: everything Prop does, plus
  support for everyday personal tasks end-to-end — durable semantic memory, a broader
  service/connector tool set, safety boundaries, context caching,
  multi-provider fallback, and an HTTP surface beside the interactive CLI.
  This is the shipping target.
- **Orbit** — autonomy, long-horizon: everything Pilot does, plus fully
  autonomous execution of super-long multi-step tasks, a distinct style and
  voice, skills grown from experience, connectors, sandboxing, extensibility,
  access control, and multi-agent. Out of scope until Pilot is solid; never
  faked (no stubs or placeholders).

> Scope boundaries are normative. The implementation MUST NOT implement a
> tier higher than the current one (`Prop`, declared at the top of this
> document); a tier becomes current only when this document is updated to
> promote it.
