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
/// per provider call; no network, no wall-clock.
final class ScriptedProvider implements Provider {
  ScriptedProvider(this.steps);

  final List<ScriptStep> steps;
  int _index = 0;

  /// Number of provider calls consumed so far.
  int get calls => _index;

  factory ScriptedProvider.fromJson(Map<String, dynamic> json) {
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
    return ScriptedProvider(steps);
  }

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
    if (_index >= steps.length) {
      throw const StepFailure.unrecoverable('script exhausted');
    }
    final step = steps[_index++];
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
}
