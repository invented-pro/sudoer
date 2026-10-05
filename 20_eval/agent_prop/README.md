# Prop eval — live-provider version comparison

`00_bp/` defines what Prop *is*; this folder measures how good a build is at
it against a real provider. The scripted gate (`00_bp/agent_prop/gate.md`,
`mise run gate`) stays the correctness blocker — it pins loop mechanics. The
suites here measure the coding disciplines the gate cannot
([agent_prop.md](../../00_bp/agent_prop.md): orient before acting, verify then
claim done, small targeted edits), by driving real binaries through the C6
automate surface.

## Layout

```
suites/<suite>/*.json   task sets (tracked) — canary | regression | capability
versions/<label>/       pinned binary copy + meta.json (gitignored)
runs/<label>/<suite>/   immutable run artifacts (gitignored)
reports/                committed compare reports — the release-decision record
tools/                  run.dart · check.dart · compare.dart (self-contained)
```

Legacy paths kept for the existing workflows: the published binary
`sudoer-prop` (republished by `mise run build`) and the provider config
`sudoer.json` / `sudoer.enc.json` (sops flow in `10_impl/AGENTS.md`).

## Quick start

```sh
cd 20_eval/agent_prop
sops -d sudoer.enc.json > sudoer.json        # once; sudoer.json is git-ignored

mise run eval:run    --bin sudoer-prop --label v0.2.0 --runs 5
mise run eval:check  --label v0.2.0
mise run eval:run    --bin <path-to-other-build> --label v0.1.0 --runs 5
mise run eval:check  --label v0.1.0
mise run eval:compare --suite canary --a v0.1.0 --b v0.2.0
```

The compare report lands in `reports/<date>_canary_<a>_vs_<b>.md` and is
committed. Only the binary differs between two labels — model and config come
from the shared `sudoer.json`, so results are budget-matched by construction.

## Task format (eval-owned)

Same shape as the bp's `task.schema.json` minus `script` (real provider) and
with `expect` replaced by `check` (deterministic judge):

```json
{
  "id": "fix-wrong-total",
  "description": "…",
  "workspace": { "total.dart": "…source…" },
  "goal": "single goal (shorthand for turns: [{goal}])",
  "turns": [ { "goal": "…" } | { "command": "/plan" } ],
  "check": {
    "finished": true,
    "answerContains": "…",
    "stdoutContains": "…",
    "files": { "summary.txt": { "equals": "sum: 107" } },
    "command": "dart test", "commandContains": "All tests passed",
    "maxSteps": 12, "maxErrors": 2
  }
}
```

All `check` keys are optional; a run passes when every declared check passes.
`finished`, `steps`, and `errors` are derived from the persisted C5 session
transcript, not from stdout parsing. Verdicts and metrics (steps, tool calls,
errors, duration) are reported separately — a version that passes more while
burning twice the steps must show it.

## Suites

- **canary** — 3 fast tasks, run on every build (N≥3; N=5 for release
  candidates). Catches live-provider regressions the scripted gate can't see.
- **regression** — failures harvested from canary runs and real use. Each task
  records in its description which label failed and why; a task graduates here
  only after its fix, and v2 must never be tuned on unfixed ones.
- **capability** *(to come)* — heavyweight drills: self-build, Prop rebuild,
  Pilot build (agent_prop.md "Build gate"), scored against the coding
  disciplines, not just file equality.

## Policies

- Gate first: a build that fails `mise run gate` is not evaluated here.
- Correctness before efficiency: compare.dart picks the winner by pass rate;
  steps only break ties.
- Runs are immutable; never edit `runs/` — rerun instead. Reports are the
  history; supersede, don't overwrite.
- Live runs are nondeterministic: compare pass *rates* over N≥3 paired runs,
  never single runs.
