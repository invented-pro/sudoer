import 'dart:convert';

import 'clm.dart';
import 'context.dart';
import 'diagnostics.dart';
import 'errors.dart';
import 'models.dart';
import 'providers/provider.dart';
import 'reliability.dart';
import 'session.dart';
import 'tools/tool.dart';

/// The result of dispatching one call of a step's batch: its outcome, how
/// long it took, and — on a timeout — the failure message (the outcome is
/// null and the loop records the timeout as an observation bound to the
/// call).
class _Dispatched {
  _Dispatched(this.outcome, this.elapsed, {this.timeoutMessage});
  final ToolOutcome? outcome;
  final Duration elapsed;
  final String? timeoutMessage;
}

/// Diff state for the C2 automate request trace: the system text and the
/// rendered message blocks of the previous request in a run, so a later
/// request logs only what changed instead of re-dumping the whole prompt.
class _RequestTrace {
  String? system;
  List<String> blocks = const [];
}

/// C1: the plan-driven multi-step ReAct loop. Owns the plan, the stall-based
/// budget, the recoverable/blocked decision, and the run result. The
/// transcript and plan live in the session (C5), so work carries across runs.
final class AgentLoop {
  AgentLoop({
    required this.model,
    required this.provider,
    required this.tools,
    required this.context,
    this.contextLog,
    this.reliability = const Reliability(),
    Diagnostics? diagnostics,
  }) : diagnostics = diagnostics ?? Diagnostics.silent;

  final String model;
  final Provider provider;
  final ToolRegistry tools;
  final ContextAssembler context;
  final Reliability reliability;
  final Diagnostics diagnostics;

  /// C4 (CLM): the model-owned live context file, or null for the harness
  /// ladder. When set, the loop mirrors the transcript to the file, adopts a
  /// model edit as the new context, and leaves the fitting to the model.
  final ContextLog? contextLog;

  /// The exact context-file text the harness last wrote this run, so a change
  /// means the model edited it. Reset per step by [_syncContextFile].
  String? _synced;

  bool get _clm => contextLog != null;

  Future<RunResult> run(
    RunRequest request,
    Session session, {
    RunObserver? observer,
  }) async {
    // A fresh goal starts with no pending cancel; a cancel only aborts the
    // call it was raised during.
    session.cancel.reset();
    // The transcript keeps a text reference to the goal's `@path` images;
    // the binaries ride the provider requests of this run only (C7).
    session.transcript.add(UserEntry(request.goal,
        images: [for (final image in request.images) image.path]));
    var steps = 0;
    var stalls = 0;
    final seen = <String>{};
    // Calls already credited as a cleared-content recovery this run (C8):
    // recovering what the model cannot see is progress exactly once per
    // call; looping re-fetches after that are ordinary stalls.
    final recovered = <String>{};
    // C2 automate trace: the request content already on the record, so each
    // step logs only the messages it appended instead of the whole prompt.
    final shown = _RequestTrace();
    final runWatch = Stopwatch()..start();
    final timings = <RunTiming>[];
    // Every return path stamps the run total (and forwards it to the observer)
    // so both surfaces can show how long the goal took.
    RunResult done(RunStatus status, {String? answer, String? reason}) {
      runWatch.stop();
      // CLM: leave the live context file mirroring the final transcript, so a
      // resumed session and the human surface see the same context.
      if (_clm) _syncContextFile(session);
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
      // CLM: mirror the live transcript to the context file before the call,
      // giving the model a clean baseline to edit (C4).
      if (_clm) _syncContextFile(session);
      await compact(session, observer: observer);
      final ProviderRequest prompt;
      try {
        prompt = context.assemble(
          model: model,
          tools: tools.definitions,
          transcript: session.transcript,
          plan: session.plan,
          images: request.images,
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
      _traceRequest('request', prompt, session, shown, step: steps + 1);
      try {
        response = await _completeWithRetry(prompt, observer, session);
      } on StepFailure catch (failure) {
        responseWatch.stop();
        if (failure.kind == FailureKind.cancelled) {
          // The user aborted the in-flight call (C6, C8): end the run at once.
          diagnostics.event('C1 loop', 'run cancelled mid-call');
          await tools.reapJobs();
          observer?.onPhase('done');
          return done(RunStatus.incomplete,
              answer: 'run cancelled', reason: 'cancelled');
        }
        if (failure.kind == FailureKind.timeout) {
          diagnostics.event(
              'C8 reliability', 'provider timeout; recovering: ${failure.message}');
          if (diagnostics.enabled && diagnostics.traceContent) {
            diagnostics.event('C8 reliability',
                'timing: response (timeout) ${formatDuration(responseWatch.elapsed)}');
          }
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
      _traceResponse('response', response, session, responseWatch.elapsed,
          step: steps + 1);
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
      final batch = action as ToolBatch;
      // Bind each observation to its call with a stable id so adapters can
      // replay one assistant tool_calls message paired with its tool results.
      final calls = [
        for (var i = 0; i < batch.calls.length; i++)
          batch.calls[i].id == null
              ? ToolCall(
                  id: 'call_${session.id}_${session.transcript.length}_$i',
                  name: batch.calls[i].name,
                  arguments: batch.calls[i].arguments,
                )
              : batch.calls[i],
      ];
      // CLM: everything appended from here is this turn; if the model edited
      // the context file during the tools, that edit is adopted as the base
      // and this turn is re-appended on top of it (C4).
      final turnStart = session.transcript.length;
      session.transcript.add(
          AssistantEntry(thought: response.thought, action: ToolBatch(calls)));
      for (final call in calls) {
        observer?.onTool(call.name, call.arguments);
        diagnostics.event(
          'C3 tools',
          'call ${call.name} ${brief(jsonEncode(call.arguments), 100)}'
          ' (id=${call.id})',
        );
      }

      // Dispatch the batch (C1): runs of independent read-only calls go in
      // parallel, side-effecting calls run sequentially in the listed order,
      // and the results keep the listed order.
      final wall = Stopwatch()..start();
      final results = List<_Dispatched?>.filled(calls.length, null);
      var i = 0;
      while (i < calls.length && !session.cancel.isCancelled) {
        if (kReadOnlyTools.contains(calls[i].name)) {
          final run = <int>[i++];
          while (i < calls.length &&
              !session.cancel.isCancelled &&
              kReadOnlyTools.contains(calls[i].name)) {
            run.add(i++);
          }
          final dispatched =
              await Future.wait([for (final j in run) _dispatch(calls[j], session)]);
          for (var k = 0; k < run.length; k++) {
            results[run[k]] = dispatched[k];
          }
        } else {
          results[i] = await _dispatch(calls[i], session);
          i++;
        }
      }

      // A guard denial is a hard block with no override (C3, C8): the network
      // guard is the only denial source at Prop.
      final denied = [
        for (final result in results)
          if (result?.outcome?.outcome == Outcome.guardDenied)
            result!.outcome!.text,
      ];
      wall.stop();

      // Record the turn: one observation per call, in the listed order, so
      // every tool call is answered even when a sibling timed out, was
      // denied, or the run was cancelled mid-batch (C8 keeps completed
      // siblings' observations).
      var novel = false;
      for (var k = 0; k < calls.length; k++) {
        final dispatched = results[k];
        final outcome = dispatched?.outcome;
        if (outcome == null) {
          final message = dispatched?.timeoutMessage ??
              (session.cancel.isCancelled ? 'cancelled' : 'dispatch skipped');
          timings.add(RunTiming(
              '${calls[k].name} (${dispatched == null ? 'skipped' : 'timeout'})',
              dispatched?.elapsed ?? Duration.zero));
          session.transcript.add(ObservationEntry(
            text: 'tool error: $message',
            outcome: Outcome.error,
            toolCallId: calls[k].id,
          ));
          continue;
        }
        timings.add(RunTiming(calls[k].name, dispatched!.elapsed));
        diagnostics.event(
          'C3 tools',
          '${calls[k].name} -> ${outcome.outcome.wire}: ${brief(outcome.text)}',
        );
        // The tool's measured time rides with its result (C2 automate trace).
        if (diagnostics.enabled && diagnostics.traceContent) {
          diagnostics.event('C3 tools',
              'timing: ${calls[k].name} ${formatDuration(dispatched.elapsed)}');
        }
        observer?.onObservation(outcome.outcome, outcome.text,
            elapsed: dispatched.elapsed);
        session.transcript.add(ObservationEntry(
          text: outcome.text,
          outcome: outcome.outcome,
          toolCallId: calls[k].id,
        ));
        if (_novel(calls[k], outcome, seen)) {
          novel = true;
        } else if (outcome.outcome == Outcome.ok &&
            context.clearedInLastView(calls[k].name, calls[k].arguments) &&
            recovered.add('${calls[k].name}\u0000'
                '${jsonEncode(calls[k].arguments)}')) {
          // A repeat whose earlier result was cleared to a placeholder (C4)
          // is recovery, not a loop: the model could not see the content it
          // just re-fetched, so the step delivered new information — once
          // per call; after that the recovered copy is in the transcript.
          novel = true;
        }
      }
      if (calls.length > 1) {
        timings.add(RunTiming('batch', wall.elapsed));
      }
      if (_clm) _resolveModelEdit(session, turnStart);

      if (denied.isNotEmpty) {
        diagnostics.event('C1 loop', 'blocked: ${denied.first}');
        observer?.onPhase('blocked');
        return done(RunStatus.blocked, reason: denied.first);
      }
      if (session.cancel.isCancelled) {
        break;
      }

      steps++;
      // A step makes progress when it advances the plan or yields any
      // observation not seen before in this run. Only consecutive
      // non-progress steps (repeats, errors, timeouts) end a run, so a long
      // run of distinct productive steps is never cut off by step count.
      if (planAdvanced || novel) {
        stalls = 0;
        diagnostics.event('C1 loop', 'progress; stall counter reset');
      } else {
        stalls++;
        diagnostics.event('C1 loop', 'no progress ($stalls/$kStallBudget)');
      }
    }

    if (session.cancel.isCancelled) {
      session.cancel.reset();
      // Every background job is reaped on cancel (C3, C8).
      await tools.reapJobs();
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
    final watch = Stopwatch()..start();
    _traceRequest(
        'compaction request', task.prompt, session, _RequestTrace());
    try {
      final response = await reliability.guardModel(
          () => provider.complete(task.prompt, cancel: session.cancel));
      summary = response.thought.trim();
      _traceResponse('compaction response', response, session, watch.elapsed);
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

  /// C2 trace (automate only): log what is about to be sent to the model as
  /// a *diff* against [shown], the previous request in this run — the system
  /// prompt only when it changed, then just the messages appended since.
  /// The header line carries the call's context every time (step, session,
  /// model, ctx used/window/percent, message and tool counts). A no-op unless
  /// diagnostics are enabled with content tracing on.
  void _traceRequest(String kind, ProviderRequest prompt, Session session,
      _RequestTrace shown,
      {int? step}) {
    if (!diagnostics.enabled || !diagnostics.traceContent) return;
    final blocks = [for (final entry in prompt.messages) _entryBlock(entry)];
    final systemChanged = shown.system != prompt.system;
    final common = _commonPrefix(shown.blocks, blocks);
    final fresh = blocks.length - common;
    diagnostics.event('C2 provider', '── $kind${_stepTag(step)} ── '
        'session=${session.id} model=${prompt.model}${_ctxTag(step)} '
        'messages=${blocks.length} new=$fresh tools=${prompt.tools.length}'
        '${_toolNames(prompt.tools)}${_imageTag(prompt.images)}');
    if (systemChanged) {
      _emitBlock('── system${_tokTag(prompt.system)} ──',
          _indentBlock(prompt.system));
    }
    if (common > 0) {
      diagnostics.event('C2 provider',
          '   ($common earlier message${common == 1 ? '' : 's'} unchanged)');
    }
    shown.system = prompt.system;
    shown.blocks = blocks;
    for (final block in blocks.skip(common)) {
      for (final line in block.split('\n')) {
        diagnostics.event('C2 provider', line);
      }
    }
  }

  /// C2 trace (automate only): log what the model answered — reasoning,
  /// thought, plan, and the action — with the call's context and its measured
  /// time as an inline `timing:` line.
  void _traceResponse(String kind, ProviderResponse response, Session session,
      Duration elapsed,
      {int? step}) {
    if (!diagnostics.enabled || !diagnostics.traceContent) return;
    final action = response.action;
    diagnostics.event('C2 provider', '── $kind${_stepTag(step)} ── '
        'session=${session.id} action='
        '${action is Finish ? 'finish' : 'tool_batch(${action.calls.length})'}'
        '${_ctxTag(step)}');
    if (response.reasoning.trim().isNotEmpty) {
      _emitBlock('── reasoning${_tokTag(response.reasoning)} ──',
          _indentBlock(response.reasoning));
    }
    if (action is ToolBatch && response.thought.trim().isNotEmpty) {
      _emitBlock(
          '── thought${_tokTag(response.thought)} ──', _indentBlock(response.thought));
    }
    if (response.plan != null) {
      final done = response.plan!.where((item) => item.done).length;
      _emitBlock('── plan $done/${response.plan!.length} done ──', [
        for (final item in response.plan!)
          '  - [${item.done ? 'x' : ' '}] ${item.text}',
      ]);
    }
    switch (action) {
      case Finish(:final answer):
        _emitBlock(
            '── finish${_tokTag(answer)} ──', _indentBlock(answer));
      case ToolBatch(:final calls):
        _emitBlock('── tool_calls ──', [
          for (final call in calls)
            '  ${call.name} ${jsonEncode(call.arguments)}'
            '${call.id == null ? '' : ' (id=${call.id})'}',
        ]);
    }
    diagnostics.event(
        'C2 provider', 'timing: $kind ${formatDuration(elapsed)}');
  }

  /// Emit one trace block: its header then its indented body, each line
  /// through the diagnostics sink (which timestamps them in automate mode).
  void _emitBlock(String header, List<String> body) {
    diagnostics.event('C2 provider', header);
    for (final line in body) {
      diagnostics.event('C2 provider', line);
    }
  }

  /// One transcript entry as a trace block: a section header carrying a
  /// token estimate plus the entry's content.
  static String _entryBlock(Entry entry) => switch (entry) {
        UserEntry(:final text, :final images) => _block(
            'user${images.isEmpty ? '' : ' (+${images.length} images)'}',
            _indentBlock(text)),
        AssistantEntry(:final thought, :final action) => _block('assistant', [
            ..._indentBlock(thought),
            for (final call in action.calls)
              '  call ${call.name} ${jsonEncode(call.arguments)}'
              '${call.id == null ? '' : ' (id=${call.id})'}',
          ]),
        ObservationEntry(:final text, :final outcome, :final toolCallId) =>
          _block(
              'observation ${outcome.wire}'
              '${toolCallId == null ? '' : ' for $toolCallId'}',
              _indentBlock(text)),
      };

  static String _block(String label, List<String> body) {
    final joined = body.join('\n');
    final header = '── $label${_tokTag(joined)} ──';
    return joined.isEmpty ? header : '$header\n$joined';
  }

  /// The count of leading blocks [a] and [b] share, so only the tail a new
  /// request appended is logged (C2 automate trace).
  static int _commonPrefix(List<String> a, List<String> b) {
    final n = a.length < b.length ? a.length : b.length;
    var i = 0;
    while (i < n && a[i] == b[i]) {
      i++;
    }
    return i;
  }

  static String _stepTag(int? step) => step == null ? '' : ' step $step';

  /// The call-context suffix shared by the request/response headers: the
  /// token estimate against the window, with a whole-percent reading.
  String _ctxTag(int? step) {
    if (step == null) return '';
    final used = context.lastUsedTokens;
    final window = context.contextWindow;
    final pct =
        window <= 0 ? '' : ' (${(used / window * 100).round()}%)';
    return ' ctx ~$used/$window$pct';
  }

  static String _toolNames(List<ToolDefinition> tools) =>
      tools.isEmpty ? '' : ' (${[for (final t in tools) t.name].join(', ')})';

  static String _imageTag(List<ImageAttachment> images) =>
      images.isEmpty ? '' : ' images=${images.length}';

  static String _tokTag(String text) => ' (~${_tokens(text)} tok)';

  static int _tokens(String text) => (text.length / 4).ceil();

  /// A free-text block as indented trace lines; empty input traces nothing.
  static List<String> _indentBlock(String text) {
    final block = text.trimRight();
    if (block.trim().isEmpty) return const [];
    return [for (final line in block.split('\n')) '  $line'];
  }

  /// True when [outcome] is an observation not seen before in this run: a
  /// repeat of the same call with the same result is a stall, not progress —
  /// unless the earlier result was cleared to a placeholder (C4), which the
  /// caller credits as recovery, since the model could not see it.
  static bool _novel(ToolCall call, ToolOutcome outcome, Set<String> seen) {
    if (outcome.outcome == Outcome.guardDenied) return false;
    final key = '${call.name}\u0000${jsonEncode(call.arguments)}\u0000'
        '${outcome.outcome.wire}\u0000${outcome.text}';
    return seen.add(key);
  }

  /// Dispatch [call] under the tool-timeout guard (C8). Never touches the
  /// transcript; the loop records every observation itself, in listed order.
  Future<_Dispatched> _dispatch(ToolCall call, Session session) async {
    final watch = Stopwatch()..start();
    try {
      final outcome = await reliability.guardTool(
        () => tools.dispatch(call, cancel: session.cancel),
        tools.timeoutFor(call.name),
      );
      watch.stop();
      return _Dispatched(outcome, watch.elapsed);
    } on StepFailure catch (failure) {
      watch.stop();
      diagnostics.event(
          'C8 reliability', 'tool timeout; recovering: ${failure.message}');
      return _Dispatched(null, watch.elapsed,
          timeoutMessage: failure.message);
    }
  }

  /// C4 (CLM): write the canonical rendering of the live transcript to the
  /// context file and remember it, so a later difference means the model
  /// edited the file. A write failure is reported and ignored: losing the
  /// mirror must not break the run, since the session (C5) is the store.
  void _syncContextFile(Session session) {
    final log = contextLog;
    if (log == null) return;
    try {
      _synced = log.write(session.transcript);
    } on Object catch (e) {
      _synced = null;
      diagnostics.event('C4 context', 'CLM: context file write failed: $e');
    }
  }

  /// C4 (CLM): after a turn, adopt a model edit to the context file as the new
  /// live context, then re-append the turn that produced it ([turnStart] is
  /// where this turn began). A malformed edit is ignored with a notice to the
  /// model, leaving the harness's context intact — never a silent wipe.
  void _resolveModelEdit(Session session, int turnStart) {
    final log = contextLog;
    if (log == null) return;
    final current = log.read();
    if (current == null || current == _synced) return; // the model left it be
    final turn = session.transcript.sublist(turnStart);
    try {
      final adopted = ContextLog.normalize(log.parse(current));
      session.transcript
        ..clear()
        ..addAll(adopted)
        ..addAll(turn);
      diagnostics.event(
          'C4 context',
          'CLM: adopted model context edit '
          '(${adopted.length} entries + ${turn.length} this turn)');
    } on FormatException catch (e) {
      session.transcript.add(ObservationEntry(
        text: 'context edit ignored (malformed): ${e.message}. '
            'Your previous context is unchanged; re-read the file before '
            'editing it again.',
        outcome: Outcome.error,
      ));
      diagnostics.event(
          'C4 context', 'CLM: malformed context edit ignored: ${e.message}');
    }
  }

  /// C8: a provider timeout is a transport failure, not model behavior, so it
  /// is retried in place — up to [Reliability.providerTimeoutRetries] times
  /// with exponential backoff — before it reaches the loop and counts as a
  /// non-progress step. A retry that succeeds is invisible: the transcript is
  /// unchanged and the stall budget is untouched.
  Future<ProviderResponse> _completeWithRetry(
    ProviderRequest prompt,
    RunObserver? observer,
    Session session,
  ) async {
    var attempt = 0;
    while (true) {
      try {
        if (observer == null) {
          return await reliability.guardModel(
              () => provider.complete(prompt, cancel: session.cancel));
        }
        return await provider.complete(prompt,
            onDelta: observer.onDelta,
            onReasoning: observer.onReasoning,
            cancel: session.cancel);
      } on StepFailure catch (failure) {
        if (failure.kind != FailureKind.timeout ||
            attempt >= reliability.providerTimeoutRetries) {
          rethrow;
        }
        attempt++;
        final delay = reliability.backoffFor(attempt);
        diagnostics.event(
            'C8 reliability',
            'provider timeout; retrying $attempt/'
            '${reliability.providerTimeoutRetries} in '
            '${formatDuration(delay)}: ${failure.message}');
        await reliability.sleep(delay);
      }
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
      _traceRequest(
          'best-effort request', prompt, session, _RequestTrace());
      final response =
          await reliability.guardModel(() => provider.complete(prompt));
      watch.stop();
      timings.add(RunTiming('response (best-effort)', watch.elapsed));
      _traceResponse('best-effort response', response, session, watch.elapsed);
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
