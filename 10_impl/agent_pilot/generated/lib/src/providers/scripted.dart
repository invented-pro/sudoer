import 'dart:convert';

import '../cancellation.dart';
import '../errors.dart';
import '../models.dart';
import 'provider.dart';

/// One scripted provider response: a completion, or a simulated failure.
sealed class ScriptStep {
  const ScriptStep();
}

final class CompleteStep extends ScriptStep {
  const CompleteStep(this.completion);
  final Completion completion;
}

final class ErrorStep extends ScriptStep {
  const ErrorStep(this.kind);
  final FailureKind kind;
}

/// The deterministic scripted provider used by the gate. Replays one step
/// per provider call; no network, no wall-clock. Every assembled prompt is
/// recorded, so the harness can assert the C4 prefix property and the
/// recall injection offline.
final class ScriptedProvider implements Provider {
  ScriptedProvider(this.steps)
      : _cursor = null,
        _cursorKey = null;

  final List<ScriptStep> steps;
  int _index = 0;

  /// The assembled prompts this provider has seen, in order (harness
  /// assertions only; never part of the wire).
  final List<String> prompts = [];

  /// Number of provider calls consumed so far.
  int get calls => _cursorKey == null ? _index : _cursor![_cursorKey]!;

  /// The shared-cursor position when this provider is one of several views
  /// over one process-registered script (the served process builds an agent
  /// per run); null when this provider owns its own cursor.
  final Map<String, int>? _cursor;
  final String? _cursorKey;

  /// The step lists registered per script file: the served process builds
  /// one agent per run, but the harness injects one chain per *process*, so
  /// every agent built from the same script consumes the same cursor — the
  /// order the gate scripted is the order the process replays.
  static final Map<String, List<ScriptStep>> _sharedSteps = {};
  static final Map<String, int> _sharedCursor = {};

  factory ScriptedProvider.fromJson(Map<String, dynamic> json,
      {String? sharedKey}) {
    final steps = <ScriptStep>[];
    for (final raw in (json['steps'] as List? ?? const [])) {
      final step = (raw as Map).cast<String, dynamic>();
      if (step.containsKey('complete')) {
        final completion =
            (step['complete'] as Map).cast<String, dynamic>();
        final toolCalls = <ToolCall>[
          for (final call in (completion['tool_calls'] as List? ?? const []))
            ToolCall.fromJson((call as Map).cast<String, dynamic>()),
        ];
        final planRaw = completion['plan'] as List?;
        final plan = planRaw == null
            ? null
            : [
                for (final item in planRaw)
                  PlanItem.fromJson((item as Map).cast<String, dynamic>()),
              ];
        steps.add(CompleteStep(Completion(
          text: completion['text'] as String? ?? '',
          toolCalls: toolCalls,
          plan: plan,
          reasoning: completion['reasoning'] as String? ?? '',
        )));
      } else if (step.containsKey('error')) {
        steps.add(ErrorStep(
          step['error'] == 'timeout'
              ? FailureKind.timeout
              : FailureKind.unrecoverable,
        ));
      }
    }
    if (sharedKey != null) {
      if (!_sharedSteps.containsKey(sharedKey)) {
        // First agent in this process: register the script and start its
        // shared cursor.
        _sharedSteps[sharedKey] = steps;
        _sharedCursor[sharedKey] = 0;
      }
      return ScriptedProvider._onSharedCursor(
          _sharedSteps[sharedKey]!, _sharedCursor, sharedKey);
    }
    return ScriptedProvider(steps);
  }

  /// The shared-cursor constructor: [steps] is the process-registered list,
  /// [cursor] the shared position in it, [key] the script that owns both.
  ScriptedProvider._onSharedCursor(
      this.steps, Map<String, int> cursor, String key)
      : _cursor = cursor,
        _cursorKey = key;

  @override
  Future<ProviderResponse> complete(
    ProviderRequest request, {
    void Function(String delta)? onDelta,
    void Function(String delta)? onReasoning,
    CancelSignal? cancel,
  }) async {
    if (cancel?.isCancelled ?? false) {
      throw const StepFailure.cancelled('cancelled by user');
    }
    // The cursor is per-provider when owned, shared across every provider
    // built from one script file when the harness pinned one chain per
    // process (the served process builds an agent per run, C2/gate).
    final position = _cursor == null ? _index : _cursor[_cursorKey]!;
    if (position >= steps.length) {
      throw const StepFailure.unrecoverable('script exhausted');
    }
    prompts.add('${request.model}\u0000${request.system}\u0000'
        '${[for (final entry in request.messages) _entryKey(entry)].join('\u0001')}');
    final step = steps[position];
    if (_cursor == null) {
      _index++;
    } else {
      _cursor[_cursorKey!] = position + 1;
    }
    return switch (step) {
      CompleteStep(:final completion) => () {
          if (onReasoning != null && completion.reasoning.isNotEmpty) {
            onReasoning(completion.reasoning);
          }
          if (onDelta != null && completion.text.isNotEmpty) {
            onDelta(completion.text);
          }
          return parseCompletion(completion);
        }(),
      ErrorStep(:final kind) =>
        throw StepFailure(kind, 'simulated ${kind.name}'),
    };
  }

  /// A stable text key for one transcript entry (prompt recording).
  static String _entryKey(Entry entry) => switch (entry) {
        UserEntry(:final text) => 'user:$text',
        AssistantEntry(:final thought, :final action) => 'assistant:$thought:'
            '${[for (final call in action.calls) '${call.name}:${jsonEncode(call.arguments)}'].join(';')}',
        ObservationEntry(:final text, :final outcome, :final toolCallId) =>
          'observation:${outcome.wire}:$toolCallId:$text',
      };
}
