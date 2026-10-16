# AGENTS.md — sudoer_pilot

Pilot agent (C1–C11): the personal-assistant tier. This package is
**built by the Prop agent** against the Pilot blueprint — it is not
hand-written. The button starts one autonomous run; humans review and
commit.

## Layout — prop + blueprint driven evolvement

This folder is `10_impl/agent_pilot/`. Everything outside `generated/`
is human-written scaffolding; the Prop agent writes **only** under
`10_impl/agent_pilot/generated/`:

```
pilot-build.json   live LLM config (git-ignored) — the startup button's -c
startup.sh         the button: starts the published Prop binary on a goal
generated/         the Dart package Prop builds (pubspec, lib/, bin/, test/, tool/)
```

The button is `./startup.sh`: with no arguments it feeds this contract
(AGENTS.md, read fresh each run) as the goal; a positional goal
overrides it. The run executes from the **repo root**, so every path in
this contract and the goal (`00_bp/…`, `10_impl/…`) resolves as
written. Output goes to the invoking terminal AND
`10_impl/agent_pilot/.build/build.log`, in the foreground (Ctrl-C
interrupts, recorded as INTERRUPTED).

**When to continue vs start fresh is decided by an input lock.**
`10_impl/agent_pilot/.build/lock` hashes every upstream dependency —
the blueprint (`00_bp/` arch, C1–C11, `agent_pilot/` schemas + gate +
tasks), this AGENTS.md, `pilot-build.json`, the resolved Prop binary
(by content, not version), and the mise SDK pins. Unchanged inputs ⇒
continue the standing session
(`10_impl/agent_pilot/.build/current-session`); changed inputs ⇒ fresh timestamped session, with
the changed paths printed — a session built against stale assumptions
is never continued. `-s <id>` / `--session <id>` overrides manually (and refreshes the
lock, accepting the drift).

Run status is also explicit: `10_impl/agent_pilot/.build/ledger.jsonl`
records every run start/end (session, exit code, goal head) and
`10_impl/agent_pilot/.build/last-run` carries the latest end — the
button prints CLEAN / BLOCKED / INTERRUPTED (128+n = killed mid-run)
and injects a re-orient instruction into the goal when the last run
did not end cleanly. A run that stalls (or hits the step ceiling) returns
status `incomplete` and therefore a **non-zero** exit (`C6`), so the button
reports it BLOCKED and re-orients: an out-of-budget build is never mistaken
for a clean one.

**Existing `generated/` content on a fresh run is archived, not
built upon.** A fresh session (changed inputs, or `-f`) moves the
current `generated/` to `10_impl/agent_pilot/.archive/<datetime>/` and
the previous `.build/build.log` to
`10_impl/agent_pilot/.archive/build.log.<datetime>` — history, never
destroyed — and the goal becomes a from-scratch build from the blueprint
with a fresh, newly created log, starting with the package scaffold.
Continuing sessions (the unchanged-inputs case) keep the folder, append
to the same log, and keep the standing session's context. `-s <id>` /
`--session <id>` resumes a named session without archiving (the caller owns
that choice).
`--print-goal` is a dry run showing the exact decision and goal without
touching any state. All builder runtime state is self-contained and
hidden under `10_impl/agent_pilot/.build/`.

## Source of truth

The blueprint owns every design decision. Read before writing code:

1. `00_bp/agent_pilot.md` — the Pilot assembly: components, wiring,
   runtime path, profile. Start here.
2. `00_bp/C9_memory.md`, `C10_safety.md`, `C11_autonomy.md` — the new
   components. `00_bp/C2`–`C8` docs carry a `## Pilot` section each
   with the tier's additions.
3. `00_bp/agent_pilot/*.schema.json` — frozen wire contracts
   (config, tools, stores, HTTP API, channel, logs, gate tasks). Code
   is generated against these shapes; do not invent fields.
4. `00_bp/agent_pilot/gate.md` + `tasks/` — the build gate this package
   must pass (every Prop task plus every Pilot task).
5. `10_impl/agent_prop/` — the Prop implementation (C1–C8). Pilot is a
   superset: reuse its structure, conventions, and code wherever the
   blueprint does not change them. Do not edit Prop while building
   here unless a Prop defect is the root cause — then fix Prop and
   rebuild it (`mise run build` in `10_impl/agent_prop`) first.

## Toolchain

If `10_impl/agent_pilot/generated/` is empty (fresh build), create the
package scaffold first: `pubspec.yaml` (name `sudoer_pilot`, SDK
constraint, `test` as dev-dependency) and `analysis_options.yaml`.

**The gate harness is a deliverable, and it comes first.** Immediately
after the scaffold, port Prop's harness
(`10_impl/agent_prop/bin/gate.dart`, `10_impl/agent_prop/lib/src/gate/`)
into `generated/bin/gate.dart` and `generated/lib/src/gate/`, then extend
it per `00_bp/agent_pilot/gate.md`: the Pilot fakes (clock, sleeper,
notifier, scheduler, channels, embedder, loopback stubs) and expectations,
driving **both** `00_bp/agent_prop/tasks/` and `00_bp/agent_pilot/tasks/`.
`dart run bin/gate.dart` must run the full superset and print
`Pilot build gate` — it is not Prop's gate under a new name. Stand it up
early so every component is judged by the gate as it lands; do **not**
leave the gate harness, the serve API, or `tool/build.dart` for the end.
Keep the working context small: copy Prop's tree with shell commands and
read only the files the current component needs, rather than loading all
of `00_bp/` and `10_impl/agent_prop/` into the conversation at once.

Run Dart from `10_impl/agent_pilot/generated` (or use the mise tasks
in `10_impl/agent_pilot`, which do the same):

- `dart pub get` — once, after cloning or adding dependencies
- `dart analyze` — must report no issues before any claim of done
- `dart test` — unit tests; keep them green
- `dart run bin/gate.dart` — the Pilot gate: all tasks from
  `00_bp/agent_prop/tasks/` and `00_bp/agent_pilot/tasks/`, plus the
  CLI smoke. Green gate = tier done.
- `dart run tool/build.dart` — compile straight into the versioned release
  in `90_dist/sudoer-pilot-<version>-<os>-<arch>/` (final builds live only
  in 90_dist/), then symlink it into place as
  `10_impl/agent_pilot/sudoer-pilot` and `20_eval/agent_pilot/sudoer-pilot`.
  Mirror `10_impl/agent_prop/tool/build.dart` but adapt it for Pilot's
  layout — it is **not** a verbatim copy: the executable and release name
  are `sudoer-pilot` (not `sudoer-prop`), the package root is
  `10_impl/agent_pilot/generated` (one level deeper than Prop's
  `10_impl/agent_prop`), so the repo root is three parents up from the
  package root, not two, and the in-tree link points at `10_impl/agent_pilot`
  (the package's parent), not the package root. Getting any of these wrong
  writes into a stray `10_impl/90_dist/` and links a `sudoer-prop` that
  does not exist.

Dart SDK is pinned by `10_impl/agent_pilot/mise.toml` (`mise exec --
dart …` if `dart` is not on PATH). `PUB_CACHE` is the repo-root
`.pub-cache/` — `mise.toml` sets it via `[env]` (machine-independent).

## Conventions

- Package layout mirrors Prop inside `10_impl/agent_pilot/generated/
  lib/src/` per component (`loop.dart`, `providers/`, `tools/`,
  `interface.dart`, …), entry points in `generated/bin/`
  (`sudoer.dart`, `gate.dart`), tests in `generated/test/`.
- The CLI is `sudoer-pilot`; the serve subcommand is
  `sudoer-pilot serve` (C6).
- No stubs, no placeholders, no TODO markers: every component is
  implemented fully or not at all. Gate-harness doubles (scripted
  providers, stub servers, injected clock/sleeper/notifier) are real
  test tooling, not stubs.
- Pilot never retunes Prop's coding behavior — it adds the personal
  domain on top.
- Bound guards (budgets, timeouts, caps, retry counts) stay
  compiled-in constants, per the gate's frozen-constants table.
