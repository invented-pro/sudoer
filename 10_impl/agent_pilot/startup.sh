#!/bin/sh
# The build button: start the Prop agent (the built rung) on the Pilot build.
#
# Layout (this folder is human-written; Prop writes only under generated/):
#   README.md        this package's doc
#   pilot-build.json live LLM config (git-ignored; GLM-5.3 endpoint key)
#   startup.sh       this button
#   generated/       the Dart package Prop builds (pubspec, lib/, bin/, test/, tool/)
#
# Usage:
#   ./startup.sh                              # goal = AGENTS.md contract; continue the standing session
#   ./startup.sh -s <session-id>              # same AGENTS.md goal, another session (--session also accepted)
#   ./startup.sh [-s <session-id>] <goal text># ad-hoc goal override
#   ./startup.sh -f                           # force a fresh session (archives generated/, rebuilds from blueprint)
#
# Continuation bookkeeping (all self-contained under .build/, git-ignored):
#   ledger.jsonl  one line per run start/end: session, pid, exit code, goal head
#   last-run      summary of the most recent end (exit=... time=... session=...)
# On start the button reports whether this continues an interrupted run or
# is a fresh start, and tells the agent the same thing. A fresh session
# never builds on stale output: existing generated/ content is moved to
# .archive/<datetime>/ and the previous build log to
# .archive/build.log.<datetime> (history, never destroyed) and the build
# restarts from the blueprint with a fresh log.
#
# Output is written BOTH to the invoking terminal and appended to
# ./.build/build.log. The run executes in the FOREGROUND — the press
# blocks until the run ends; Ctrl-C interrupts it (recorded as
# INTERRUPTED). Exit codes: 0 clean (answer delivered, best-effort
# included), 1 blocked/config error, 128+n killed by signal n.
# Verify after each run: cd generated && dart analyze && dart test
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)

session="pilot-build"
saw_session=0
fresh=0
print_goal=0
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--fresh) fresh=1; shift ;;
    -p|--print-goal) print_goal=1; shift ;;
    -s|--session)
        [ $# -ge 2 ] || { echo "usage: $0 [-f] [-p] [-s|--session session-id] [goal]" >&2; exit 2; }
        session=$2; saw_session=1; shift 2 ;;
    *) break ;;
  esac
done

config="$here/pilot-build.json"
if [ ! -f "$config" ]; then
  echo "config not found: $config" >&2
  exit 1
fi

binary="$repo/10_impl/agent_prop/sudoer-prop"
if [ ! -x "$binary" ]; then
  echo "prop binary not found: $binary (run mise run build in 10_impl/agent_prop)" >&2
  exit 1
fi

mkdir -p "$here/.build/sessions"
ledger="$here/.build/ledger.jsonl"
lastrun="$here/.build/last-run"
lock="$here/.build/lock"
current="$here/.build/current-session"
touch "$ledger"

# ---- Input lock: hash every upstream dependency of the Pilot build. ----
# Unchanged inputs => the standing session's context is still valid =>
# continue it. Changed inputs => the session was built against stale
# assumptions => fresh session. Explicit -s always overrides.
hasher=sha256sum
command -v "$hasher" >/dev/null 2>&1 || hasher="shasum -a 256"

manifest() {
  {
    for f in \
      "$repo/00_bp/arch.md" \
      "$repo/00_bp/agent_pilot.md" \
      "$repo/00_bp/C1_loop.md" "$repo/00_bp/C2_providers.md" \
      "$repo/00_bp/C3_tools.md" "$repo/00_bp/C4_context.md" \
      "$repo/00_bp/C5_sessions.md" "$repo/00_bp/C6_interface.md" \
      "$repo/00_bp/C7_modality.md" "$repo/00_bp/C8_reliability.md" \
      "$repo/00_bp/C9_memory.md" "$repo/00_bp/C10_safety.md" \
      "$repo/00_bp/C11_autonomy.md" \
      "$here/AGENTS.md" \
      "$config" \
      "$here/mise.toml" \
      "$repo/10_impl/agent_prop/mise.toml"
    do
      $hasher "$f"
    done
    # The whole Pilot schema/gate surface.
    for f in "$repo/00_bp/agent_pilot"/*.json \
             "$repo/00_bp/agent_pilot"/*.md \
             "$repo/00_bp/agent_pilot"/tasks/*.json
    do
      [ -f "$f" ] && $hasher "$f"
    done
    # The builder itself — resolved through the symlink and hashed by
    # content: same version, different bits must still force fresh.
    $hasher "$(readlink -f "$binary")"
  } 2>/dev/null | sort -k2
}

changed=""
if [ -f "$lock" ]; then
  manifest > "$here/.build/lock.new"
  if ! cmp -s "$lock" "$here/.build/lock.new"; then
    changed=$(diff "$lock" "$here/.build/lock.new" |
      sed -n 's/^> .*  //p' | sed "s|$repo/||" | tr '\n' ' ')
  fi
  rm -f "$here/.build/lock.new"
else
  changed="(first run — no lock yet)"
fi

# ---- Session decision (pure: no state changes yet). ----
inputs_drifted=0
if [ -n "$changed" ] && [ "$changed" != "(first run — no lock yet)" ]; then
  inputs_drifted=1
fi

note=""
is_fresh=0
ts=$(date -u +%Y%m%d%H%M%S)
if [ "$fresh" = "1" ]; then
  session="pilot-$ts"
  is_fresh=1
  note="fresh session '$session' (forced)"
elif [ "$saw_session" = "1" ] || [ "$#" -gt 0 ]; then
  : # explicit -s or goal override: session decided by the caller
elif [ "$inputs_drifted" = "1" ]; then
  session="pilot-$ts"
  is_fresh=1
  note="INPUTS CHANGED — fresh session '$session': $changed"
elif [ -f "$current" ] && [ -s "$current" ]; then
  session=$(cat "$current")
else
  session="pilot-build"
fi

# ---- Hints (pure reads). ----
resume_hint=""
if [ "$is_fresh" = "0" ] && [ -f "$lastrun" ]; then
  code=$(sed -n 's/^exit=\([0-9]*\).*/\1/p' "$lastrun")
  if [ -n "$code" ] && [ "$code" != "0" ]; then
    resume_hint=" The previous build run ended without a clean answer (exit $code): first re-orient — check the tail of 10_impl/agent_pilot/.build/build.log and the current state of 10_impl/agent_pilot/generated — then resume the work that was in flight and continue autonomously."
  fi
fi

if [ "$is_fresh" = "1" ]; then
  trigger=""
  [ "$inputs_drifted" = "1" ] && trigger=" (fresh start triggered by changed upstream inputs: $changed)"
  goal="You are the builder for 10_impl/agent_pilot. Read 10_impl/agent_pilot/AGENTS.md and follow it as your build contract. This is a fresh build: 10_impl/agent_pilot/generated is empty (any previous tree was archived away). Build the COMPLETE Pilot package from the blueprint autonomously, milestone by milestone until DONE — start with the package scaffold (pubspec.yaml, analysis_options.yaml), then implement everything per 00_bp/ (agent_pilot.md, C9-C11, the '## Pilot' sections, agent_pilot/*.schema.json, gate.md + tasks/). Do NOT stop after one milestone: keep working through all of them, keeping dart analyze clean and dart test green as you go, until dart run bin/gate.dart passes end to end. Stop only when the gate is green or you are truly blocked; report what you completed and what remains.$trigger"
else
  goal=${*:-"You are the builder for 10_impl/agent_pilot. Read 10_impl/agent_pilot/AGENTS.md and follow it as your build contract. Continue the Pilot build autonomously until DONE: look at what is already implemented in 10_impl/agent_pilot/generated, then work through ALL remaining milestones per the blueprint in 00_bp/ (agent_pilot.md, C9-C11, the '## Pilot' sections, agent_pilot/*.schema.json, gate.md + tasks/) without stopping between them, keeping dart analyze clean and dart test green as you go, until dart run bin/gate.dart passes end to end. Stop only when the gate is green or you are truly blocked; report what you completed and what remains.$resume_hint"}
fi

# ---- Run-status note (pure read of last-run). ----
if [ -z "$note" ]; then
  prior=$(cat "$lastrun" 2>/dev/null || true)
  case "$prior" in
    *"session=$session "*|*"session=$session")
      code=$(printf '%s' "$prior" | sed -n 's/.*exit=\([0-9]*\).*/\1/p')
      case "$code" in
        0) note="continuing session '$session' — last run ended CLEAN";;
        1) note="continuing session '$session' — last run ended BLOCKED (exit 1)";;
        *) note="continuing session '$session' — last run was INTERRUPTED (exit $code)";;
      esac
      ;;
    "") note="fresh start — no previous run recorded";;
    *) note="fresh start on session '$session' (last recorded run was on another session)";;
  esac
fi

# --print-goal: dry run. Report what WOULD happen and stop — before the
# archive, before the lock refresh, before any state changes.
if [ "$print_goal" = "1" ]; then
  [ -n "$note" ] && echo "$note"
  if [ "$is_fresh" = "1" ]; then
    if [ -d "$here/generated" ]; then
      echo "[dry run: generated/ would be archived to .archive/$ts/]"
    fi
    if [ -f "$here/.build/build.log" ]; then
      echo "[dry run: .build/build.log would be archived to .archive/build.log.$ts]"
    fi
  fi
  printf '%s\n' "$goal"
  exit 0
fi

# ---- Side effects start here. ----
if [ "$is_fresh" = "1" ]; then
  # A fresh session never builds on stale output: archive the current
  # generated/ tree and the previous build log (history, never destroyed),
  # then restart from the blueprint with a fresh log.
  mkdir -p "$here/.archive"
  if [ -d "$here/generated" ]; then
    arch="$here/.archive/$ts"
    mkdir -p "$arch"
    mv "$here/generated" "$arch/"
    echo "ARCHIVED generated/ → .archive/$ts/generated"
  fi
  if [ -f "$here/.build/build.log" ]; then
    mv "$here/.build/build.log" "$here/.archive/build.log.$ts"
    echo "ARCHIVED build.log → .archive/build.log.$ts"
  fi
fi
printf '%s' "$session" > "$current"

# The lock now describes the inputs THIS run builds against — regardless
# of how the session was chosen (a caller who overrides accepts drift).
manifest > "$lock"

echo "$note"

# Both sinks: live on the terminal, persisted in the log; the wrapper
# records the run's start and end (with exit code) in the ledger.
export PILOT_BIN="$binary" PILOT_CONFIG="$config" PILOT_SESSION="$session" \
       PILOT_GOAL="$goal" PILOT_LEDGER="$ledger" PILOT_LAST="$lastrun" \
       PILOT_CWD="$repo"
runner="$here/.build/run-one.sh"
cat > "$runner" <<'WRAP'
#!/bin/sh
# Written by startup.sh: run one build goal, ledger its start and end.
# Runs from the repo root so every path in the goal and the AGENTS.md
# contract (00_bp/…, 10_impl/…) resolves as written.
cd "$PILOT_CWD" || exit 1
now=$(date -u +%FT%TZ)
printf '{"time":"%s","event":"start","session":"%s","goal":"%.120s"}\n' \
  "$now" "$PILOT_SESSION" "$PILOT_GOAL" >> "$PILOT_LEDGER"
"$PILOT_BIN" --automate --verbose -c "$PILOT_CONFIG" --session "$PILOT_SESSION" "$PILOT_GOAL" 2>&1
code=$?
now=$(date -u +%FT%TZ)
printf '{"time":"%s","event":"end","session":"%s","exit":%s}\n' \
  "$now" "$PILOT_SESSION" "$code" >> "$PILOT_LEDGER"
printf 'exit=%s time=%s session=%s\n' "$code" "$now" "$PILOT_SESSION" > "$PILOT_LAST"
exit $code
WRAP
chmod +x "$runner"

# Foreground run: attached to this terminal, output live on screen AND
# appended to the log; the wrapper records start/end (with exit code) in
# the ledger. The press blocks until the run ends — Ctrl-C interrupts it
# (recorded as INTERRUPTED, exit 130).
"$runner" 2>&1 | tee -a "$here/.build/build.log"
status=$(sed -n 's/^exit=\([0-9]*\).*/\1/p' "$lastrun" 2>/dev/null)
case "${status:-1}" in
  0) echo "run ended CLEAN";;
  1) echo "run ended BLOCKED (exit 1)";;
  *) echo "run ended INTERRUPTED (exit ${status:-?})";;
esac
exit "${status:-1}"
