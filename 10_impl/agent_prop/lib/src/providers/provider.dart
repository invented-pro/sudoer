import '../cancellation.dart';
import '../models.dart';

/// C2: the single boundary through which the loop reaches an LLM.
abstract class Provider {
  /// Produce the model's next output for [request].
  ///
  /// The adapter always requests a streamed completion on the wire, so the
  /// call is bounded by the inactivity timeout rather than a total deadline
  /// (C8). When [onDelta] or [onReasoning] is supplied it invokes [onDelta]
  /// with each new chunk of *visible* text (plan blocks withheld) and
  /// [onReasoning] with each new chunk of `<think>` reasoning (both stripped
  /// from the answer) as they arrive; with neither callback no deltas are
  /// forwarded and only the assembled response is returned — the one-shot
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

/// C2: an adapter that owns a transport and can release it when the interface
/// replaces it (`/provider`, `/model`) or the process closes. Kept separate
/// from [Provider] so test fakes and the scripted gate adapter need not
/// implement it.
abstract interface class ClosableProvider {
  void close();
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
