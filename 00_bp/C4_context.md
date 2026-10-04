# C4 — Context

> Status: draft · Version 0.7 · **Current tier: Prop**

Context is what the model actually sees: `C4` is the assembly of the prompt
sent to the provider on every turn. The loop decides; context frames the
decision.

## Overview

Before each provider call the runtime builds one prompt from three parts:
the system prompt, the tool definitions, and the conversation so far. It
must fit that prompt inside the model's context window. Every tier shares
this assembly boundary; the tiers differ in how much survives: an in-window
compacted transcript at Prop, prompt caching at Pilot, and a pluggable
engine with retrieval over history at Orbit.

```plantuml
@startuml
hide footbox
skinparam backgroundColor transparent
skinparam defaultFontColor #64748B
skinparam participantBackgroundColor #E8F5E9
skinparam participantBorderColor #64748B
skinparam participantFontColor #1F2937
skinparam arrowColor #64748B
participant "loop" as L
participant "context (C4)" as C
participant "provider" as P
L -> C : assemble(transcript)
C -> C : fit to window
C --> L : prompt
L -> P : complete(prompt)
@enduml
```

Context is rebuilt on every iteration; it is not a store. Anything that must
outlive a run belongs to `sessions` (C5) or `memory` (C9), not here.

## Prop

Prop fits the session transcript to the window by folding older work into a
small, **structured memory** — never by dropping it silently. The prompt is
the system prompt plus the pinned current goal and plan, a structured brief
of earlier work, and a **verbatim recent tail**. Folding happens at a
milestone — the first step of a new goal past a watermark of the window, or
mid-run past a higher high-water mark — so it is deliberate rather than a
last-second scramble. The brief is written by the model in one tools-withheld
call under the model timeout, and falls back to a deterministic digest when
that call is unavailable (offline, the gate, or a failure). Folding is
*sticky*: once history is folded it stays folded rather than re-expanding on
the next step. Folding is turn-aligned, so a tool call is never separated from
its observation. There is no prompt caching — that arrives at Pilot.

```plantuml
@startuml
skinparam backgroundColor transparent
skinparam defaultFontColor #64748B
skinparam activityBackgroundColor #E8F5E9
skinparam activityBorderColor #64748B
skinparam activityFontColor #1F2937
start
:gather system prompt + tool definitions (C3);
:gather pinned current goal and plan (C1, C5);
:estimate prompt tokens over the full transcript (C5);
if (past high-water? or (past watermark? and at a goal boundary?)) then (yes)
  :choose a turn-aligned tail that fits the retain budget;
  :ask the model (tools withheld, model timeout) for a brief
  of everything older;
  if (model call failed or unavailable?) then (yes)
    :fall back to the deterministic digest;
  endif
  :keep any previous fold (sticky): never un-fold;
endif
while (estimate > model window? AND tail can shrink?) is (yes)
  :fold one more turn-aligned segment;
  :re-estimate;
endwhile (no)
while (estimate > model window? AND a removable segment remains?) is (yes)
  :drop the oldest non-pinned segment;
  :re-estimate;
endwhile (no)
if (estimate > model window?) then (yes)
  :return context-overflow error to the loop;
  stop
else (no)
  :return prompt to the loop;
  stop
endif
@enduml
```

- **Three-part prompt.** The assembled prompt is the pinned goal and plan, the
  brief of older work, and the verbatim recent tail, all under the system
  prompt and tool definitions. Only the older work is folded.
- **Model-written brief.** At a fold the loop makes one provider call with no
  tools, under the model timeout, asking for a brief that preserves the goals,
  the files touched and their current state, the commands and outcomes,
  decisions, errors, and open threads. The call sees only the newly eligible
  work plus the existing brief, and folds the new work into it, so a long
  session never sends the whole history to the summarizer in one prompt. The
  prompt carries each tool call's path or command, so the brief can preserve
  them. The brief is computed once per fold and kept; it is never regenerated
  every step. It can also be triggered on demand by `/compact` (C6), which
  forces a fold below the watermark.
- **Deterministic fallback.** If the brief call fails, times out, or is
  unavailable — offline, the gate, or any error — the fold falls back to a
  locally derived digest, so context fit never depends on a model call.
- **Structured digest.** The fallback digest has named sections — the goals
  seen, the **files touched** (path plus the last action and outcome), the
  commands run and their outcomes, and the errors encountered. Paths, commands,
  and errors survive verbatim; only bulky prose is compressed. The working set
  of files is the same information the model brief is asked to preserve.
- **Working set.** The file section is the run's working set: for each path the
  latest action (`read`, `write`, `edit`, …) and outcome, so a later step can
  still find the files that matter without the full transcript.
- **Verbatim recent tail.** The most recent turns are kept raw, up to a retain
  budget of the window, so the current thread of work is never summarized
  while it is still live.
- **Turn-aligned folding.** A fold boundary only ever lands before a goal or
  before a tool-call reply, never between a tool call and its observation, so
  the provider always receives a well-formed exchange.
- **Sticky folding.** Once a region is folded it stays folded for the life of
  the session/agent; a later step does not re-expand it just because the raw
  transcript estimate dipped below the trigger again.
- **Milestone trigger.** Folding is not a raw overflow test: it runs at a
  goal boundary (the first step of a new goal) once the prompt passes the
  watermark (75% of the window), or mid-run at the high-water mark (90%), so it
  lands on a natural milestone and keeps headroom.
- **Compaction is reported.** When a new fold happens, the loop surfaces it
  (C6), so the interface can tell the user context was shortened — and whether
  the brief was model-written or the local fallback — rather than silently
  dropping history.
- **Pinned goal and plan.** The current goal and the plan (`C1`) survive
  compaction; the goal is kept even when the fold boundary moves past it.
- **Plan convention in the prompt.** The system prompt instructs the model
  to report plan updates with the fenced `plan` block (the wire convention
  owned by `C2`), so a text-only model can drive the plan without a dedicated
  API field.
- **Bounded, then dropped, then error.** The system prompt and tool
  definitions are pinned. If the folded prompt still overflows, more of the
  tail is folded turn-aligned; only if no turn-aligned fold remains are the
  oldest non-pinned segments dropped, and a prompt that still overflows is
  returned to the loop as an error (`reliability`, C8).
- **The stored transcript is unchanged.** Folding is an assembly-time view on
  top of `sessions` (C5); the persisted transcript is never rewritten, and the
  brief is not persisted — it is rebuilt (one call) on resume if needed.
- **No caching.** The prompt is rebuilt on every iteration; only the brief is
  kept between steps. Prompt-cache reuse across calls arrives at Pilot.
- **Approximate fit.** The token estimate may be approximate; the window is
  `context_window` from provider config (C2).
- **Usage is reported.** The estimate for the last assembled prompt is
  exposed to the loop and, through it, to the interface (C6), so the human
  surface can show context used against the window.

