import 'dart:convert';

import 'diagnostics.dart';
import 'errors.dart';
import 'models.dart';

const String kPropSystemPrompt =
    'You are Sudoer, a coding assistant running locally. Take one step at a '
    'time: call exactly one tool per step. Keep the plan up to date by ending '
    'a message with a fenced block labelled "plan" holding one Markdown '
    'checkbox per item, for example:\n'
    '```plan\n- [ ] next step\n- [x] finished step\n```\n'
    'The block is hidden from your answer. When you have the answer, finish '
    'with it.';

/// The system prompt for the one tools-withheld call that writes a compact
/// brief of earlier work (C4).
const String kCompactionSystemPrompt =
    'You compress an AI coding agent\'s earlier session so later steps keep '
    'what they need. You may be given an existing brief and some new earlier '
    'work; merge them into one updated brief with short labeled sections: '
    'Goals, Files (each path with what changed and its current state), '
    'Commands (with their outcomes), Decisions, Errors, Open threads. Preserve '
    'paths and commands verbatim. Do not add commentary, do not answer, do not '
    'ask questions.';

/// Prop compaction watermarks, as a fraction of the context window. The
/// prompt is folded at a natural boundary (a new goal, when the previous run
/// has finished) once it passes [kCompactWatermark]; [kCompactHighWater]
/// forces folding mid-run. Both leave headroom so folding is a deliberate
/// milestone step, not a last-second scramble.
const double kCompactWatermark = 0.75;
const double kCompactHighWater = 0.90;

/// The share of the window kept as a verbatim recent tail when older work is
/// folded into the brief.
const double kRetainFraction = 0.45;

/// The share of the window the fallback digest may occupy.
const double kDigestFraction = 0.25;

/// What the last fold compacted.
final class CompactionInfo {
  const CompactionInfo({
    required this.steps,
    required this.beforeTokens,
    required this.afterTokens,
  });

  /// Transcript entries folded into the brief.
  final int steps;
  final int beforeTokens;
  final int afterTokens;
}

/// C4: a fold the loop must summarize before it next assembles. The loop makes
/// the tools-withheld provider call and hands the text back via
/// [ContextAssembler.applyCompaction].
final class CompactionTask {
  const CompactionTask({
    required this.through,
    required this.prompt,
    required this.beforeTokens,
  });

  /// The transcript index to fold through.
  final int through;

  /// The summarization request (tools withheld), sent under the model timeout.
  final ProviderRequest prompt;

  final int beforeTokens;
}

/// C4: rebuilds the prompt each iteration and fits it to the window by folding
/// older work into a brief; the current goal and plan are pinned, and an
/// unfittable prompt is an error.
final class ContextAssembler {
  ContextAssembler({
    required this.contextWindow,
    this.systemPrompt = kPropSystemPrompt,
    this.diagnostics,
  });

  final int contextWindow;
  final String systemPrompt;
  final Diagnostics? diagnostics;

  /// Estimated tokens of the most recently assembled prompt (status, C6).
  int lastUsedTokens = 0;

  /// Set by [assemble] when it folded new work on its own (the loop did not),
  /// else null.
  CompactionInfo? lastCompaction;

  /// The transcript prefix already folded into the brief. Folding is sticky: a
  /// later step never re-expands history it has already summarized.
  int _foldedThrough = 0;

  /// The brief for transcript[0:_foldedThrough]; null means nothing folded.
  String? _brief;

  /// The full prompt estimate measured when the pending fold was planned.
  int _plannedBefore = 0;

  /// If a fold is warranted and not yet applied, the task the loop must
  /// summarize. Null when the prompt fits or the fold is already in place.
  CompactionTask? planCompaction({
    required String model,
    required List<ToolDefinition> tools,
    required List<Entry> transcript,
    List<PlanItem> plan = const [],
    bool force = false,
  }) {
    final system = _systemWithPlan(plan);
    final toolsJson = jsonEncode([for (final tool in tools) tool.toJson()]);
    final cut = _desiredCut(system, toolsJson, transcript, force: force);
    if (cut <= 0 || cut <= _foldedThrough) return null;

    // Fold only the newly eligible segment into the existing brief, so a long
    // session never sends the whole history to the summarizer in one prompt.
    final segment = transcript.sublist(_foldedThrough, cut);
    final rendered = segment
        .map(_renderForBrief)
        .map((text) => text.trim())
        .where((text) => text.isNotEmpty)
        .join('\n');
    _plannedBefore = _estimate(system, toolsJson, transcript);
    final prior = _brief;
    final body = StringBuffer();
    if (prior != null && prior.trim().isNotEmpty) {
      body.write('Existing brief:\n$prior\n\n');
    }
    body.write('New earlier work to fold in:\n$rendered\n\n'
        'Write the updated brief now.');
    return CompactionTask(
      through: cut,
      beforeTokens: _plannedBefore,
      prompt: ProviderRequest(
        model: model,
        system: kCompactionSystemPrompt,
        messages: [UserEntry(body.toString())],
        tools: const <ToolDefinition>[],
      ),
    );
  }

  /// Apply a fold planned by [planCompaction]. [brief] is the model's text; an
  /// empty or null value falls back to the deterministic digest.
  CompactionInfo applyCompaction(
      List<Entry> transcript, int through, String? brief) {
    if (through > _foldedThrough) {
      _foldedThrough = through;
      _brief = (brief != null && brief.trim().isNotEmpty)
          ? brief.trim()
          : _digest(transcript.sublist(0, through)).text;
    }
    return CompactionInfo(
      steps: through,
      beforeTokens: _plannedBefore,
      afterTokens: _estimate(
        systemPrompt,
        '[]',
        <Entry>[
          ObservationEntry(text: _brief ?? '', outcome: Outcome.ok),
          ...transcript.sublist(_foldedThrough),
        ],
      ),
    );
  }

  ProviderRequest assemble({
    required String model,
    required List<ToolDefinition> tools,
    required List<Entry> transcript,
    List<PlanItem> plan = const [],
  }) {
    final system = _systemWithPlan(plan);
    final toolsJson = jsonEncode([for (final tool in tools) tool.toJson()]);
    final lastUser = transcript.lastIndexWhere((entry) => entry is UserEntry);
    final startTokens = _estimate(system, toolsJson, transcript);

    // Fallback folding: when the loop did not pre-summarize a warranted fold
    // (or a direct caller has no loop), fold deterministically so the prompt
    // always fits even without a model call.
    lastCompaction = null;
    final startFolded = _foldedThrough;
    final cut = _desiredCut(system, toolsJson, transcript);
    if (cut > _foldedThrough) {
      _foldedThrough = cut;
      _brief = _digest(transcript.sublist(0, cut)).text;
    }

    var messages = _build(transcript, lastUser, _foldedThrough);
    // If the prompt still overflows, fold more of the tail turn-aligned before
    // ever dropping a segment.
    while (_estimate(system, toolsJson, messages) > contextWindow &&
        _foldedThrough < transcript.length) {
      final next = _nextBoundary(transcript, _foldedThrough);
      if (next <= _foldedThrough) break;
      _foldedThrough = next;
      _brief = _digest(transcript.sublist(0, _foldedThrough)).text;
      messages = _build(transcript, lastUser, _foldedThrough);
    }

    // Last resort: drop the oldest non-pinned segments, but never the goal and
    // never the last entry.
    while (_estimate(system, toolsJson, messages) > contextWindow &&
        messages.length > 2) {
      var removable = -1;
      for (var i = 0; i < messages.length - 1; i++) {
        if (messages[i] is! UserEntry) {
          removable = i;
          break;
        }
      }
      if (removable < 0) break;
      messages.removeAt(removable);
    }

    final used = _estimate(system, toolsJson, messages);
    lastUsedTokens = used;
    if (_foldedThrough > startFolded) {
      lastCompaction = CompactionInfo(
        steps: _foldedThrough,
        beforeTokens: startTokens,
        afterTokens: used,
      );
    }
    if (used > contextWindow) {
      diagnostics?.event('C4 context',
          'overflow: ~$used > $contextWindow tokens; blocking the run');
      throw ContextOverflowException(
          'prompt exceeds context window ($contextWindow tokens)');
    }
    diagnostics?.event(
      'C4 context',
      'prompt ${messages.length} messages, ~$used/$contextWindow tokens, '
      '${_foldedThrough > 0 ? 'folded $_foldedThrough entries' : 'no folding'}',
    );
    return ProviderRequest(
      model: model,
      system: system,
      messages: messages,
      tools: tools,
    );
  }

  List<Entry> _build(List<Entry> transcript, int lastUser, int through) {
    if (through <= 0) return List<Entry>.of(transcript);
    return <Entry>[
      ObservationEntry(
          text: _brief ?? _digest(transcript.sublist(0, through)).text,
          outcome: Outcome.ok),
      if (lastUser >= 0 && lastUser < through) transcript[lastUser],
      ...transcript.sublist(through),
    ];
  }

  /// The index to fold through when a fold is warranted, or [_foldedThrough]
  /// when it is not.
  int _desiredCut(String system, String toolsJson, List<Entry> transcript,
      {bool force = false}) {
    if (contextWindow <= 0 || transcript.length <= 1) return _foldedThrough;
    final ratio = _estimate(system, toolsJson, transcript) / contextWindow;
    final atGoalBoundary = transcript.last is UserEntry;
    final shouldFold = force ||
        ratio >= kCompactHighWater ||
        (atGoalBoundary && ratio >= kCompactWatermark);
    if (!shouldFold) return _foldedThrough;
    final chosen =
        _chooseCut(transcript, (contextWindow * kRetainFraction).round());
    return chosen > _foldedThrough ? chosen : _foldedThrough;
  }

  /// The transcript index to fold through: keep the most recent entries that
  /// fit [budget] tokens, snapped to a turn boundary so a tool call is never
  /// split from its observation.
  int _chooseCut(List<Entry> transcript, int budget) {
    var used = 0;
    var i = transcript.length;
    while (i > 0) {
      used += _tokens(_render(transcript[i - 1]));
      if (used > budget) break;
      i--;
    }
    while (i < transcript.length && transcript[i] is ObservationEntry) {
      i++;
    }
    return i;
  }

  /// The next turn-aligned fold boundary after [cut], folding at least one
  /// more exchange.
  int _nextBoundary(List<Entry> transcript, int cut) {
    var next = cut + 1;
    while (next < transcript.length && transcript[next] is ObservationEntry) {
      next++;
    }
    return next;
  }

  String _systemWithPlan(List<PlanItem> plan) {
    if (plan.isEmpty) return systemPrompt;
    final lines =
        plan.map((item) => '- [${item.done ? 'x' : ' '}] ${item.text}').join('\n');
    return '$systemPrompt\n\nCurrent plan:\n$lines';
  }

  /// Fold [entries] into a structured digest: the goals seen, the working set
  /// of files touched, the commands run, and the errors hit. This is the
  /// offline fallback when a model brief is unavailable.
  ObservationEntry _digest(List<Entry> entries) {
    final goals = <String>[];
    final files = <String, String>{};
    final commands = <String>[];
    final errors = <String>[];
    String? tool;
    String? path;
    String? command;
    for (final entry in entries) {
      switch (entry) {
        case UserEntry(:final text):
          goals.add(_short(text, 100));
        case AssistantEntry(:final action):
          tool = null;
          path = null;
          command = null;
          if (action is ToolCall) {
            tool = action.name;
            final p = action.arguments['path'];
            final c = action.arguments['command'];
            if (action.name == 'run_command' && c is String) {
              command = _short(c, 80);
            } else if (p is String) {
              path = p;
            }
          }
        case ObservationEntry(:final text, :final outcome):
          if (outcome == Outcome.error) errors.add(_short(text, 100));
          if (command != null) {
            commands.add('$command -> ${outcome.wire}');
          } else if (path != null) {
            files[path] = '${tool ?? '?'} -> ${outcome.wire}';
          }
          tool = null;
          path = null;
          command = null;
      }
    }

    final buffer = StringBuffer(
        'Earlier session summary (${entries.length} entries folded).');
    if (goals.isNotEmpty) buffer.write('\nGoals: ${goals.join('; ')}');
    if (files.isNotEmpty) {
      buffer.write('\nFiles:');
      for (final file in files.entries.take(20)) {
        buffer.write('\n- ${file.key}: ${file.value}');
      }
    }
    if (commands.isNotEmpty) {
      buffer.write('\nCommands: ${commands.take(10).join('; ')}');
    }
    if (errors.isNotEmpty) {
      buffer.write('\nErrors: ${errors.take(5).join('; ')}');
    }

    final text = buffer.toString();
    final cap = _digestCap;
    return ObservationEntry(
      text: text.length > cap ? '${text.substring(0, cap)}…' : text,
      outcome: Outcome.ok,
    );
  }

  /// A character cap for the fallback digest, so folding always leaves room
  /// for the tail even on a small window.
  int get _digestCap {
    final chars = (contextWindow * kDigestFraction).round() * 4;
    return chars.clamp(200, 1600);
  }

  static int _estimate(String system, String toolsJson, List<Entry> messages) =>
      _tokens(system) +
      _tokens(toolsJson) +
      messages.fold<int>(0, (sum, entry) => sum + _tokens(_render(entry)));

  static String _short(String text, int max) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length > max ? '${flat.substring(0, max)}…' : flat;
  }

  static int _tokens(String text) => (text.length / 4).ceil();

  static String _render(Entry entry) => switch (entry) {
        UserEntry(:final text) => text,
        AssistantEntry(:final thought, :final action) =>
          '$thought ${action is ToolCall ? action.name : ''}',
        ObservationEntry(:final text) => text,
      };

  /// Render an entry for the summarizer, including a tool call's arguments so
  /// the brief can preserve paths and commands verbatim (C4).
  static String _renderForBrief(Entry entry) => switch (entry) {
        UserEntry(:final text) => text,
        AssistantEntry(:final thought, :final action) => action is ToolCall
            ? '${thought.trim()} ${action.name} '
                '${jsonEncode(action.arguments)}'.trim()
            : thought,
        ObservationEntry(:final text) => text,
      };
}
