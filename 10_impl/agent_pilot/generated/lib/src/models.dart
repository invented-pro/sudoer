/// Domain models mirroring the frozen blueprints in `00_bp/agent_prop/`.
///
/// The JSON shapes here are the contract; keep them in lockstep with the
/// schemas (`config`, `run`, `session`, `message`, `tool`, `provider`,
/// `completion`).
library;

import 'package:path/path.dart' as p;

import 'errors.dart';

enum RunStatus { complete, incomplete, blocked }

enum Outcome { ok, error, guardDenied }

extension OutcomeJson on Outcome {
  String get wire => switch (this) {
        Outcome.ok => 'ok',
        Outcome.error => 'error',
        Outcome.guardDenied => 'guard_denied',
      };

  static Outcome fromWire(String value) => switch (value) {
        'ok' => Outcome.ok,
        'error' => Outcome.error,
        'guard_denied' => Outcome.guardDenied,
        _ => throw FormatException('unknown outcome: $value'),
      };
}

extension RunStatusJson on RunStatus {
  String get wire => name;
}

/// One item in the agent's plan (C1): a short task and whether it is done.
final class PlanItem {
  const PlanItem({required this.text, this.done = false});

  final String text;
  final bool done;

  factory PlanItem.fromJson(Map<String, dynamic> json) => PlanItem(
        text: json['text'] as String,
        done: json['done'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {'text': text, 'done': done};
}

/// An action the model chose: finish, or a batch of tool calls
/// (`message.schema.json`: `action` = `finish` | `toolBatch`).
sealed class Action {
  const Action();

  factory Action.fromJson(Map<String, dynamic> json) => switch (json['type']) {
        'finish' => Finish(json['answer'] as String),
        // Legacy single-call actions (pre-batch sessions) wrap into a
        // batch of one so an old session file still resumes.
        'tool_call' => ToolBatch([ToolCall.fromJson(json)]),
        _ => ToolBatch([
            for (final call in (json['tool_calls'] as List? ?? const []))
              ToolCall.fromJson((call as Map).cast<String, dynamic>()),
          ]),
      };

  /// The tool calls this action carries, in the model's listed order;
  /// empty for a finish.
  List<ToolCall> get calls => const [];

  Map<String, dynamic> toJson();
}

/// A model request to run a tool with validated-shape arguments
/// (`tool.schema.json`: `toolCall`). Not itself an action: a step's action
/// is a [ToolBatch] carrying one or more of these.
final class ToolCall {
  const ToolCall({required this.name, required this.arguments, this.id});

  /// The provider's tool-call id when it supplied one; used to bind the
  /// matching observation on replay. Assigned by the loop when absent.
  final String? id;
  final String name;
  final Map<String, dynamic> arguments;

  factory ToolCall.fromJson(Map<String, dynamic> json) => ToolCall(
        id: json['id'] as String?,
        name: json['name'] as String,
        arguments: (json['arguments'] as Map).cast<String, dynamic>(),
      );

  Map<String, dynamic> toJson() => {
        'type': 'tool_call',
        if (id != null) 'id': id,
        'name': name,
        'arguments': arguments,
      };
}

/// One step's action: one or more tool calls emitted together. Independent
/// read-only calls may run in parallel (C1); observations return bound to
/// their calls, in the listed order.
final class ToolBatch extends Action {
  const ToolBatch(this.calls);

  @override
  final List<ToolCall> calls;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'tool_calls',
        'tool_calls': [for (final call in calls) call.toJson()],
      };
}

final class Finish extends Action {
  const Finish(this.answer);

  final String answer;

  @override
  Map<String, dynamic> toJson() => {'type': 'finish', 'answer': answer};
}

/// One entry in the session transcript (C1, C5) that context (C4) sends.
sealed class Entry {
  const Entry();

  factory Entry.fromJson(Map<String, dynamic> json) => switch (json['role']) {
        'user' => UserEntry(
            json['text'] as String,
            images: [
              for (final image in (json['images'] as List? ?? const []))
                image as String,
            ],
          ),
        'assistant' => AssistantEntry(
            thought: json['thought'] as String,
            action:
                Action.fromJson((json['action'] as Map).cast<String, dynamic>()),
          ),
        'observation' => ObservationEntry(
            text: json['text'] as String,
            outcome: OutcomeJson.fromWire(json['outcome'] as String),
            toolCallId: json['tool_call_id'] as String?,
          ),
        _ => throw FormatException('unknown entry role: ${json['role']}'),
      };

  Map<String, dynamic> toJson();
}

final class UserEntry extends Entry {
  const UserEntry(this.text, {this.images = const []});
  final String text;

  /// Path references of the images attached to this goal (`@path` tokens,
  /// C7). Text only: the binaries are attached to that goal's provider
  /// requests at runtime and are never persisted (C4, C5).
  final List<String> images;

  @override
  Map<String, dynamic> toJson() => {
        'role': 'user',
        'text': text,
        if (images.isNotEmpty) 'images': images,
      };
}

final class AssistantEntry extends Entry {
  const AssistantEntry({required this.thought, required this.action});
  final String thought;
  final Action action;

  @override
  Map<String, dynamic> toJson() =>
      {'role': 'assistant', 'thought': thought, 'action': action.toJson()};
}

final class ObservationEntry extends Entry {
  const ObservationEntry({
    required this.text,
    required this.outcome,
    this.toolCallId,
  });
  final String text;
  final Outcome outcome;

  /// The tool call this observation answers, when it is a tool result. Null
  /// for harness-level observations (e.g. a provider timeout), which must not
  /// be replayed as tool results.
  final String? toolCallId;

  @override
  Map<String, dynamic> toJson() => {
        'role': 'observation',
        'text': text,
        'outcome': outcome.wire,
        if (toolCallId != null) 'tool_call_id': toolCallId,
      };
}

final class ProviderResponse {
  const ProviderResponse({
    required this.thought,
    required this.action,
    this.plan,
    this.reasoning = '',
  });
  final String thought;
  final Action action;

  /// A plan update from the completion; null means the plan is unchanged.
  final List<PlanItem>? plan;

  /// Private reasoning stripped from the `<think>` block (C2); never part of
  /// the answer. Empty when the model did not think aloud.
  final String reasoning;
}

/// A model response after wire parsing (C2 -> `completion.schema.json`).
final class Completion {
  const Completion({
    required this.text,
    this.toolCalls = const [],
    this.plan,
    this.reasoning = '',
  });
  final String text;
  final List<ToolCall> toolCalls;
  final List<PlanItem>? plan;

  /// Private reasoning stripped from a `<think>` block (C2).
  final String reasoning;
}

final class ToolDefinition {
  const ToolDefinition({
    required this.name,
    required this.description,
    required this.parameters,
  });
  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'parameters': parameters,
      };
}

final class ToolOutcome {
  const ToolOutcome(this.outcome, this.text, {this.guard});
  const ToolOutcome.ok(String text) : this(Outcome.ok, text);
  const ToolOutcome.error(String text) : this(Outcome.error, text);
  const ToolOutcome.guardDenied(String text, {GuardArea? guard})
      : this(Outcome.guardDenied, text, guard: guard);

  final Outcome outcome;
  final String text;

  /// Which guard denied, when [outcome] is [Outcome.guardDenied]. Runtime-only;
  /// not part of the wire shape (`toolOutcome`).
  final GuardArea? guard;

  Map<String, dynamic> toJson() => {'outcome': outcome.wire, 'text': text};
}

/// C1/C6: live progress for a human interface. Automation and the gate pass
/// none, so they take the one-shot provider path.
abstract interface class RunObserver {
  /// A chunk of newly generated, visible model text (plan blocks withheld).
  void onDelta(String text);

  /// A chunk of newly generated private reasoning (`<think>` contents, C2).
  void onReasoning(String text);

  /// The loop is about to take step [step]; [stalls] of [stallBudget]
  /// consecutive non-progress steps have accumulated. Progress resets
  /// [stalls] to zero, so a productive run is never cut off by step count.
  void onStep(int step, int stalls, int stallBudget);

  /// The assembled prompt used [usedTokens] of [windowTokens].
  void onContext(int usedTokens, int windowTokens);

  /// The assembler folded [steps] earlier transcript entries into a summary,
  /// taking the prompt from [beforeTokens] to [afterTokens] (C4).
  void onCompaction(int steps, int beforeTokens, int afterTokens);

  /// The agent is dispatching [name] with [arguments].
  void onTool(String name, Map<String, dynamic> arguments);

  /// The last provider response took [elapsed] to stream and return.
  void onResponse(Duration elapsed);

  /// The result of the last tool call, which took [elapsed] when known.
  void onObservation(Outcome outcome, String text, {Duration? elapsed});

  /// A short phase label: `thinking`, `acting`, `done`, `blocked`.
  void onPhase(String phase);
}

final class ProviderRequest {
  const ProviderRequest({
    required this.model,
    required this.system,
    required this.messages,
    required this.tools,
    this.images = const [],
  });
  final String model;
  final String system;
  final List<Entry> messages;
  final List<ToolDefinition> tools;

  /// Images attached to the current goal's `@path` tokens (C7). Runtime-only:
  /// adapters attach them to the goal's user message; the transcript keeps a
  /// text reference and the binaries are never persisted.
  final List<ImageAttachment> images;
}

/// A coding task's image, loaded once at goal submission (C7).
final class ImageAttachment {
  const ImageAttachment({required this.path, required this.bytes});
  final String path;
  final List<int> bytes;

  /// The MIME type for [path], or null when the extension is unknown.
  static String? mimeFor(String path) => switch (p.extension(path).toLowerCase()) {
    '.png' => 'image/png',
    '.jpg' || '.jpeg' => 'image/jpeg',
    '.gif' => 'image/gif',
    '.webp' => 'image/webp',
    _ => null,
  };
}

final class RunRequest {
  const RunRequest(this.goal, {this.images = const []});
  final String goal;

  /// Images named by `@path` tokens in the goal line (C7).
  final List<ImageAttachment> images;
}

final class RunResult {
  const RunResult({
    required this.status,
    this.answer,
    this.reason,
    this.timings = const <RunTiming>[],
  });

  final RunStatus status;
  final String? answer;
  final String? reason;

  /// Runtime-only measured spans for this run: one per provider response, one
  /// per tool dispatch, and one `run` total. Never serialized (not part of the
  /// run wire shape); the human and automate surfaces render it.
  final List<RunTiming> timings;

  factory RunResult.complete(String answer,
          {List<RunTiming> timings = const <RunTiming>[]}) =>
      RunResult(status: RunStatus.complete, answer: answer, timings: timings);
  factory RunResult.incomplete(String answer,
          {String? reason, List<RunTiming> timings = const <RunTiming>[]}) =>
      RunResult(
          status: RunStatus.incomplete,
          answer: answer,
          reason: reason,
          timings: timings);
  factory RunResult.blocked(
          {String? reason, List<RunTiming> timings = const <RunTiming>[]}) =>
      RunResult(status: RunStatus.blocked, reason: reason, timings: timings);

  Map<String, dynamic> toJson() => {
        'status': status.wire,
        if (answer != null) 'answer': answer,
        if (reason != null) 'reason': reason,
      };
}

/// One measured span of a run (C1/C6): a provider response, a tool dispatch,
/// or the `run` total. Runtime-only; never serialized.
final class RunTiming {
  const RunTiming(this.label, this.duration);
  final String label;
  final Duration duration;
}
