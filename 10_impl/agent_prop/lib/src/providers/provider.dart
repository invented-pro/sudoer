import '../cancellation.dart';
import '../models.dart';

/// C2: the single boundary through which the loop reaches an LLM.
abstract class Provider {
  /// Produce the model's next output for [request].
  ///
  /// When [onDelta] or [onReasoning] is supplied the adapter streams: it
  /// invokes [onDelta] with each new chunk of *visible* text (plan blocks
  /// withheld) and [onReasoning] with each new chunk of `<think>` reasoning
  /// (both stripped from the answer) as they arrive, then returns the
  /// assembled response. With neither callback the adapter takes the one-shot
  /// path used by automation and the gate.
  ///
  /// When [cancel] is supplied the adapter races it: a user cancel aborts the
  /// in-flight HTTP request and response stream at once and the call fails
  /// with a cancelled `StepFailure` (C8).
  Future<ProviderResponse> complete(
    ProviderRequest request, {
    void Function(String delta)? onDelta,
    void Function(String delta)? onReasoning,
    CancelSignal? cancel,
  });
}

/// C2 normalization: a completion with no tool call becomes a finish; one or
/// more tool calls become a single batch action preserving the model's order.
ProviderResponse parseCompletion(Completion completion) {
  if (completion.toolCalls.isEmpty) {
    return ProviderResponse(
      thought: completion.text,
      action: Finish(completion.text),
      plan: completion.plan,
      reasoning: completion.reasoning,
    );
  }
  return ProviderResponse(
    thought: completion.text,
    action: ToolBatch(List<ToolCall>.of(completion.toolCalls)),
    plan: completion.plan,
    reasoning: completion.reasoning,
  );
}
