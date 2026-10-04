import 'dart:convert';

import 'context.dart';
import 'diagnostics.dart';
import 'errors.dart';
import 'models.dart';
import 'providers/provider.dart';
import 'reliability.dart';
import 'session.dart';
import 'tools/tool.dart';

/// C1: the plan-driven multi-step ReAct loop. Owns the plan, the stall-based
/// budget, the recoverable/blocked decision, and the run result. The
/// transcript and plan live in the session (C5), so work carries across runs.
final class AgentLoop {
  AgentLoop({
    required this.model,
    required this.provider,
    required this.tools,
    required this.context,
    this.reliability = const Reliability(),
    this.authorize,
    Diagnostics? diagnostics,
  }) : diagnostics = diagnostics ?? Diagnostics.silent;

  final String model;
  final Provider provider;
  final ToolRegistry tools;
  final ContextAssembler context;
  final Reliability reliability;

  /// C6: ask the user to approve a guard denial. Null (automation) denies.
  final Future<bool> Function(String tool, String reason)? authorize;
  final Diagnostics diagnostics;

  Future<RunResult> run(
    RunRequest request,
    Session session, {
    RunObserver? observer,
  }) async {
    // A fresh goal starts with no pending cancel; a cancel only aborts the
    // call it was raised during.
    session.cancel.reset();
    session.transcript.add(UserEntry(request.goal));
    var steps = 0;
    var stalls = 0;
    final seen = <String>{};
    final runWatch = Stopwatch()..start();
    final timings = <RunTiming>[];
    // Every return path stamps the run total (and forwards it to the observer)
    // so both surfaces can show how long the goal took.
    RunResult done(RunStatus status, {String? answer, String? reason}) {
      runWatch.stop();
      timings.add(RunTiming('run', runWatch.elapsed));
      return RunResult(
          status: status, answer: answer, reason: reason, timings: timings);
    }

    diagnostics.event('C1 loop',
        'run start: goal="${brief(request.goal)}" stallBudget=$kStallBudget');
    // A plan left fully complete belongs to the previous goal, so a new goal
    // starts with fresh planning. An unfinished plan is kept so a later goal
    // can continue the work (C5). Without this an unrelated finished plan
    // lingers in the prompt and misleads the model about the new goal.
    if (session.plan.isNotEmpty && session.plan.every((item) => item.done)) {
      diagnostics.event('C1 loop', 'cleared completed plan for the new goal');
      session.plan = <PlanItem>[];
    }

    while (!session.cancel.isCancelled &&
        stalls < kStallBudget &&
        steps < kStepCeiling) {
      diagnostics.event(
          'C1 loop', 'step ${steps + 1} (stalls $stalls/$kStallBudget)');
      observer?.onPhase('thinking');
      observer?.onStep(steps + 1, stalls, kStallBudget);
      await compact(session, observer: observer);
      final ProviderRequest prompt;
      try {
        prompt = context.assemble(
          model: model,
          tools: tools.definitions,
          transcript: session.transcript,
          plan: session.plan,
        );
      } on ContextOverflowException catch (e) {
        diagnostics.event('C1 loop', 'blocked: ${e.message}');
        observer?.onPhase('blocked');
        return done(RunStatus.blocked, reason: e.message);
      }
      final compaction = context.lastCompaction;
      if (compaction != null) {
        diagnostics.event(
            'C4 context',
            'compacted ${compaction.steps} steps: ~${compaction.beforeTokens} '
            '-> ~${compaction.afterTokens} tokens');
        observer?.onCompaction(
            compaction.steps, compaction.beforeTokens, compaction.afterTokens);
      }
      observer?.onContext(context.lastUsedTokens, context.contextWindow);

      final ProviderResponse response;
      final responseWatch = Stopwatch()..start();
      try {
        if (observer == null) {
          response = await reliability.guardModel(
              () => provider.complete(prompt, cancel: session.cancel));
        } else {
          response = await provider.complete(prompt,
              onDelta: observer.onDelta,
              onReasoning: observer.onReasoning,
              cancel: session.cancel);
        }
      } on StepFailure catch (failure) {
        responseWatch.stop();
        if (failure.kind == FailureKind.cancelled) {
          // The user aborted the in-flight call (C6, C8): end the run at once.
          diagnostics.event('C1 loop', 'run cancelled mid-call');
          observer?.onPhase('done');
          return done(RunStatus.incomplete,
              answer: 'run cancelled', reason: 'cancelled');
        }
        if (failure.kind == FailureKind.timeout) {
          diagnostics.event(
              'C8 reliability', 'provider timeout; recovering: ${failure.message}');
          timings.add(RunTiming('response (timeout)', responseWatch.elapsed));
          session.transcript.add(ObservationEntry(
            text: 'provider error: ${failure.message}',
            outcome: Outcome.error,
          ));
          steps++;
          stalls++;
          continue;
        }
        diagnostics.event('C1 loop', 'blocked: ${failure.message}');
        observer?.onPhase('blocked');
        return done(RunStatus.blocked, reason: failure.message);
      }
      responseWatch.stop();
      timings.add(RunTiming('response', responseWatch.elapsed));
      observer?.onResponse(responseWatch.elapsed);

      var planAdvanced = false;
      if (response.plan != null) {
        final before = session.plan.where((item) => item.done).length;
        session.plan = List<PlanItem>.of(response.plan!);
        planAdvanced =
            session.plan.where((item) => item.done).length > before;
        diagnostics.event(
            'C1 loop',
            'plan updated: ${response.plan!.length} items'
            '${planAdvanced ? ' (advanced)' : ''}');
      }

      final action = response.action;
      if (action is Finish && _hasVisibleAnswer(action.answer)) {
        diagnostics.event('C1 loop', 'finish: ${brief(action.answer)}');
        // Persist the finished turn so a later goal in the same session reads
        // a complete user/assistant exchange instead of two user turns.
        session.transcript
            .add(AssistantEntry(thought: action.answer, action: action));
        observer?.onPhase('done');
        return done(RunStatus.complete, answer: action.answer);
      }
      if (action is Finish) {
        // A finish with no answer (e.g. the model emitted only its plan block)
        // is not a completion: record the empty turn, nudge the model, and
        // count a non-progress step rather than returning an empty `complete`.
        diagnostics.event(
            'C1 loop',
            'empty finish; asking for the answer '
            '(stalls ${stalls + 1}/$kStallBudget)');
        session.transcript
            .add(AssistantEntry(thought: action.answer, action: action));
        session.transcript.add(const ObservationEntry(
          text: 'your response contained no answer; give the final answer, '
              'or call a tool',
          outcome: Outcome.error,
        ));
        steps++;
        stalls++;
        continue;
      }

      observer?.onPhase('acting');
      final call = action as ToolCall;
      // Bind the observation to the call with a stable id so adapters can
      // replay an assistant tool_calls message paired with its tool result.
      final resolved = call.id == null
          ? ToolCall(
              id: 'call_${session.id}_${session.transcript.length}',
              name: call.name,
              arguments: call.arguments,
            )
          : call;
      session.transcript
          .add(AssistantEntry(thought: response.thought, action: resolved));
      observer?.onTool(resolved.name, resolved.arguments);
      diagnostics.event(
        'C3 tools',
        'call ${resolved.name} ${brief(jsonEncode(resolved.arguments), 100)}'
        ' (id=${resolved.id})',
      );

      var dispatch = await _dispatch(resolved, session);
      var outcome = dispatch.$1;
      var toolElapsed = dispatch.$2;
      if (outcome == null) {
        timings.add(RunTiming('${resolved.name} (timeout)', toolElapsed));
        steps++;
        stalls++;
        continue;
      }

      // A guard denial is a hard block. A workspace denial may be opened by
      // the human surface for the session, after which the call is retried in
      // place; a network denial has no override. Automation (no authorizer)
      // always blocks.
      if (outcome.outcome == Outcome.guardDenied) {
        if (outcome.guard == GuardArea.network) {
          diagnostics.event('C1 loop', 'blocked: ${outcome.text}');
          observer?.onPhase('blocked');
          return done(RunStatus.blocked, reason: outcome.text);
        }
        if (!tools.guard.allowOutside) {
          final ask = authorize;
          final granted =
              ask == null ? false : await ask(resolved.name, outcome.text);
          if (!granted) {
            diagnostics.event('C1 loop', 'blocked: ${outcome.text}');
            observer?.onPhase('blocked');
            return done(RunStatus.blocked, reason: outcome.text);
          }
          tools.guard.allowOutside = true;
          session.allowOutsideWorkspace = true;
          diagnostics.event('C3 tools', 'authorized outside the workspace');
          dispatch = await _dispatch(resolved, session);
          outcome = dispatch.$1;
          toolElapsed = dispatch.$2;
          if (outcome == null) {
            timings.add(RunTiming('${resolved.name} (timeout)', toolElapsed));
            steps++;
            stalls++;
            continue;
          }
        }
      }

      timings.add(RunTiming(resolved.name, toolElapsed));
      diagnostics.event(
        'C3 tools',
        '${resolved.name} -> ${outcome.outcome.wire}: ${brief(outcome.text)}',
      );
      observer?.onObservation(outcome.outcome, outcome.text,
          elapsed: toolElapsed);
      session.transcript.add(ObservationEntry(
        text: outcome.text,
        outcome: outcome.outcome,
        toolCallId: resolved.id,
      ));
      steps++;
      // A step makes progress when it advances the plan or yields an
      // observation not seen before in this run. Only consecutive
      // non-progress steps (repeats, errors, timeouts) end a run, so a long
      // run of distinct productive steps is never cut off by step count.
      if (planAdvanced || _novel(resolved, outcome, seen)) {
        stalls = 0;
        diagnostics.event('C1 loop', 'progress; stall counter reset');
      } else {
        stalls++;
        diagnostics.event('C1 loop', 'no progress ($stalls/$kStallBudget)');
      }
    }

    if (session.cancel.isCancelled) {
      session.cancel.reset();
      diagnostics.event('C1 loop', 'run cancelled');
      observer?.onPhase('done');
      return done(RunStatus.incomplete,
          answer: 'run cancelled', reason: 'cancelled');
    }
    final reason = stalls >= kStallBudget
        ? 'stalled after $steps steps without progress'
        : 'reached the $kStepCeiling-step ceiling';
    diagnostics.event('C1 loop', '$reason; one best-effort call');
    final best = await _bestEffort(session, timings);
    observer?.onPhase('done');
    return done(RunStatus.incomplete, answer: best, reason: reason);
  }

  /// C4: fold older work into a brief when the prompt has grown past a
  /// watermark, or on demand with [force] (the `/compact` command). Makes one
  /// tools-withheld model call under the model timeout and falls back to the
  /// deterministic digest on any failure. Returns null when nothing is
  /// foldable.
  Future<CompactionInfo?> compact(
    Session session, {
    RunObserver? observer,
    bool force = false,
  }) async {
    // A compaction is its own operation: clear any cancel left by the run
    // that preceded it so a manual `/compact` is not aborted on arrival.
    session.cancel.reset();
    final task = context.planCompaction(
      model: model,
      tools: tools.definitions,
      transcript: session.transcript,
      plan: session.plan,
      force: force,
    );
    if (task == null) return null;
    observer?.onPhase('compacting');
    String? summary;
    try {
      final response = await reliability.guardModel(
          () => provider.complete(task.prompt, cancel: session.cancel));
      summary = response.thought.trim();
    } on Object {
      summary = null;
    }
    final info =
        context.applyCompaction(session.transcript, task.through, summary);
    diagnostics.event(
        'C4 context',
        '${summary == null || summary.isEmpty ? 'local digest' : 'model brief'} '
        'folded ${info.steps} entries '
        '(~${info.beforeTokens} -> ~${info.afterTokens} tokens)');
    observer?.onCompaction(info.steps, info.beforeTokens, info.afterTokens);
    return info;
  }

  /// True when [outcome] is an observation not seen before in this run: a
  /// repeat of the same call with the same result is a stall, not progress.
  static bool _novel(ToolCall call, ToolOutcome outcome, Set<String> seen) {
    if (outcome.outcome == Outcome.guardDenied) return false;
    final key = '${call.name}\u0000${jsonEncode(call.arguments)}\u0000'
        '${outcome.outcome.wire}\u0000${outcome.text}';
    return seen.add(key);
  }

  /// Dispatch [call] under the tool-timeout guard. Returns the outcome (null
  /// on timeout, so the loop can take the next step) and how long it took.
  Future<(ToolOutcome?, Duration)> _dispatch(
      ToolCall call, Session session) async {
    final watch = Stopwatch()..start();
    try {
      final outcome = await reliability.guardTool(
        () => tools.dispatch(call, cancel: session.cancel),
        tools.timeoutFor(call.name),
      );
      watch.stop();
      return (outcome, watch.elapsed);
    } on StepFailure catch (failure) {
      watch.stop();
      diagnostics.event(
          'C8 reliability', 'tool timeout; recovering: ${failure.message}');
      session.transcript.add(ObservationEntry(
        text: 'tool error: ${failure.message}',
        outcome: Outcome.error,
        toolCallId: call.id,
      ));
      return (null, watch.elapsed);
    }
  }

  /// One final provider call after the run stalls or hits the ceiling. Tools
  /// are withheld so the model must answer in text; if the call fails or comes
  /// back empty, the answer falls back to a local summary of the run's state.
  Future<String> _bestEffort(Session session, List<RunTiming> timings) async {
    try {
      final prompt = context.assemble(
        model: model,
        tools: const <ToolDefinition>[],
        transcript: session.transcript,
        plan: session.plan,
      );
      final watch = Stopwatch()..start();
      final response =
          await reliability.guardModel(() => provider.complete(prompt));
      watch.stop();
      timings.add(RunTiming('response (best-effort)', watch.elapsed));
      final text = response.thought.trim();
      return text.isEmpty ? _fallbackSummary(session) : text;
    } on Object {
      return _fallbackSummary(session);
    }
  }

  /// What the run reached, built locally when no best-effort completion is
  /// available: the plan state and the last observation.
  static String _fallbackSummary(Session session) {
    final parts = <String>[];
    if (session.plan.isNotEmpty) {
      final done = session.plan.where((item) => item.done).length;
      parts.add('Reached $done/${session.plan.length} plan steps.');
    }
    final observations = session.transcript.whereType<ObservationEntry>();
    if (observations.isNotEmpty) {
      final last = observations.last.text.trim();
      parts.add('Last observation: '
          '${last.length > 200 ? '${last.substring(0, 200)}...' : last}');
    }
    return parts.isEmpty ? 'no answer' : parts.join(' ');
  }
}

/// True when [text] holds at least one visible character. Unlike a plain
/// `trim().isNotEmpty`, this also rejects answers made only of invisible
/// format characters (zero-width space/joiner, BOM, exotic spaces) that a
/// misbehaving model can emit as a "blank" finish.
bool _hasVisibleAnswer(String text) {
  for (final rune in text.runes) {
    if (rune <= 0x20 || rune == 0x7F) continue; // controls and ASCII space
    if (rune == 0x00A0) continue; // no-break space
    if (rune >= 0x2000 && rune <= 0x200F) continue; // spaces and format chars
    if (rune == 0x2028 || rune == 0x2029 || rune == 0xFEFF) continue;
    if (rune >= 0xFE00 && rune <= 0xFE0F) continue; // variation selectors
    return true;
  }
  return false;
}
