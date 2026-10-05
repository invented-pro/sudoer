import 'dart:convert';

import 'diagnostics.dart';
import 'errors.dart';
import 'models.dart';
import 'tools/tool.dart' show kReadOnlyTools;

/// The system prompt's version stamp (C4): the prompt is a pinned, versioned
/// artifact shipped with the build, so a prompt change is reviewable and
/// evaluation results stay attributable.
const String kPromptVersion = 'prop-prompt-v2';

const String kPropSystemPrompt =
    'You are Sudoer (Prop), a coding agent running locally in a workspace '
    '(system prompt $kPromptVersion).\n'
    '\n'
    'Work like a careful engineer:\n'
    '- Orient first: map the repo with glob and search before editing.\n'
    '- Read a file before you edit it; make small, grounded edits; prefer '
    'multi_edit for a repeated or related set of changes.\n'
    '- Verify before claiming done: run the build, linter, or tests with '
    'run_command and read the output. Report exactly what ran and what it '
    'printed.\n'
    '- Review your changes with diff, and restore to undo them.\n'
    '- Use job for a command that should keep running (a dev server or '
    'watcher) while you keep working.\n'
    '- Follow the project\'s own conventions; ask a clarifying question when '
    'the goal is ambiguous.\n'
    '\n'
    'Steps and tools:\n'
    '- One step may call several tools. Batch independent read-only calls '
    '(read, glob, search, diff) together in one step; they run in parallel.\n'
    '- Mutating calls (write, edit, multi_edit, run_command, job, restore) '
    'run one at a time, in the order you list them; keep each such step '
    'small and check the result before the next.\n'
    '\n'
    'Keep the plan up to date by ending a message with a fenced block '
    'labelled "plan" holding one Markdown checkbox per item, for example:\n'
    '```plan\n- [ ] next step\n- [x] finished step\n```\n'
    'The block is hidden from your answer. When you have the answer, finish '
    'with it: concise markdown naming what changed, the commands you ran, '
    'and the observed result.';

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

/// Cap on a single observation in the assembled prompt (C4): oversized tool
/// outputs are clipped to head and tail with an elision marker, keeping the
/// command echo and the final error and dropping the bulky middle. The cap
/// applies everywhere, including the recent tail; the stored transcript is
/// unchanged.
const int kObservationCapTokens = 4096;

/// Tools whose outputs can be recovered by re-running them (C4): exactly the
/// read-only tools. Outside the verbatim tail their successful results are
/// cleared to a one-line re-run placeholder; mutating tools keep their
/// command and outcome.
const Set<String> kRefetchableTools = kReadOnlyTools;

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

/// C4: rebuilds the prompt each iteration and fits it to the window by
/// climbing a ladder of levers — clip oversized observations, clear stale
/// re-fetchable tool results, then fold older work into a brief; the current
/// goal and plan are pinned, and an unfittable prompt is an error.
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

  /// How many observations the last view clipped / cleared (diagnostics).
  int _lastClipped = 0;
  int _lastCleared = 0;

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
    _plannedBefore = _estimate(system, toolsJson, _view(transcript));
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
      afterTokens: _estimate(systemPrompt, '[]', _view(transcript)),
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

    final startTokens = _estimate(system, toolsJson, _view(transcript));

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

    var messages = _view(transcript);
    // If the prompt still overflows after clipping and clearing, fold more of
    // the tail turn-aligned before ever dropping a segment.
    while (_estimate(system, toolsJson, messages) > contextWindow &&
        _foldedThrough < transcript.length) {
      final next = _nextBoundary(transcript, _foldedThrough);
      if (next <= _foldedThrough) break;
      _foldedThrough = next;
      _brief = _digest(transcript.sublist(0, _foldedThrough)).text;
      messages = _view(transcript);
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
      '${_foldedThrough > 0 ? 'folded $_foldedThrough entries' : 'no folding'}'
      '${_lastClipped > 0 ? ', $_lastClipped clipped' : ''}'
      '${_lastCleared > 0 ? ', $_lastCleared cleared' : ''}',
    );
    return ProviderRequest(
      model: model,
      system: system,
      messages: messages,
      tools: tools,
    );
  }

  /// The assembly-time view of [transcript] under the current fold (C4): the
  /// brief for folded work, a thinned middle whose re-fetchable tool results
  /// are cleared to placeholders, and the verbatim recent tail. Oversized
  /// observations are clipped everywhere. The stored transcript is never
  /// rewritten; thinning is a view, not a mutation.
  List<Entry> _view(List<Entry> transcript) {
    final clipped = _clipAll(transcript);
    var tailStart =
        _chooseCut(clipped, (contextWindow * kRetainFraction).round());
    if (tailStart < _foldedThrough) tailStart = _foldedThrough;
    final lastUser = transcript.lastIndexWhere((entry) => entry is UserEntry);
    final view = <Entry>[
      if (_foldedThrough > 0)
        ObservationEntry(
            text: _brief ?? _digest(transcript.sublist(0, _foldedThrough)).text,
            outcome: Outcome.ok),
      if (_foldedThrough > 0 && lastUser >= 0 && lastUser < _foldedThrough)
        transcript[lastUser],
    ];
    _lastClipped = 0;
    _lastCleared = 0;
    // The calls of the batch currently being replayed, consumed in order by
    // the observations that answer them (the loop appends one observation per
    // call, in the listed order).
    final pendingCalls = <ToolCall>[];
    for (var i = _foldedThrough; i < clipped.length; i++) {
      final entry = clipped[i];
      if (entry is! ObservationEntry) {
        pendingCalls
          ..clear()
          ..addAll(entry is AssistantEntry ? entry.action.calls : const []);
        view.add(entry);
        continue;
      }
      final call = pendingCalls.isEmpty ? null : pendingCalls.removeAt(0);
      if (i < tailStart &&
          call != null &&
          entry.outcome == Outcome.ok &&
          kRefetchableTools.contains(call.name)) {
        _lastCleared++;
        view.add(ObservationEntry(
            text: _clearedPlaceholder(call),
            outcome: entry.outcome,
            toolCallId: entry.toolCallId));
        continue;
      }
      if (!identical(entry, transcript[i])) _lastClipped++;
      view.add(entry);
    }
    return view;
  }

  /// Clip every oversized observation (C4); indices stay aligned with the
  /// transcript so pairing and fold boundaries are unaffected.
  static List<Entry> _clipAll(List<Entry> transcript) =>
      [for (final entry in transcript) _clipEntry(entry)];

  static Entry _clipEntry(Entry entry) {
    if (entry is! ObservationEntry) return entry;
    final clipped = _clip(entry.text);
    if (identical(clipped, entry.text)) return entry;
    return ObservationEntry(
        text: clipped, outcome: entry.outcome, toolCallId: entry.toolCallId);
  }

  /// Clip [text] to its head and tail with an elision marker when it exceeds
  /// the observation cap (C4).
  static String _clip(String text) {
    final capChars = kObservationCapTokens * 4;
    if (text.length <= capChars) return text;
    final head = (capChars * 0.6).round();
    final tail = capChars - head;
    final elided = ((text.length - capChars) / 4).ceil();
    return '${text.substring(0, head)}\n… $elided tokens elided …\n'
        '${text.substring(text.length - tail)}';
  }

  /// The one-line replacement for a cleared re-fetchable tool result (C4):
  /// name the tool and its path, pattern, query, or URL so a later step can
  /// re-run it.
  static String _clearedPlaceholder(ToolCall call) {
    final target = switch (call.name) {
      'read' => call.arguments['path'],
      'glob' => call.arguments['pattern'],
      'search' => call.arguments['pattern'],
      'web_fetch' => call.arguments['url'],
      'web_search' => call.arguments['query'],
      _ => null,
    };
    final what =
        target is String && target.trim().isNotEmpty ? ' $target' : '';
    return '[cleared: ${call.name}$what — re-run to recover the output]';
  }

  /// The index to fold through when a fold is warranted, or [_foldedThrough]
  /// when it is not. The watermark ratio is measured on the thinned view —
  /// after clipping and clearing — so a fold is only warranted when the
  /// cheaper levers were not enough (C4).
  int _desiredCut(String system, String toolsJson, List<Entry> transcript,
      {bool force = false}) {
    if (contextWindow <= 0 || transcript.length <= 1) return _foldedThrough;
    final ratio =
        _estimate(system, toolsJson, _view(transcript)) / contextWindow;
    final atGoalBoundary = transcript.last is UserEntry;
    final shouldFold = force ||
        ratio >= kCompactHighWater ||
        (atGoalBoundary && ratio >= kCompactWatermark);
    if (!shouldFold) return _foldedThrough;
    final chosen = _chooseCut(
        _clipAll(transcript), (contextWindow * kRetainFraction).round());
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
    // The batch calls being answered, consumed in order by the observations
    // that follow them.
    final pendingCalls = <ToolCall>[];
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
          pendingCalls
            ..clear()
            ..addAll(action.calls);
          final call =
              pendingCalls.isEmpty ? null : pendingCalls.removeAt(0);
          if (call != null) {
            tool = call.name;
            final pathArg = call.arguments['path'];
            final commandArg = call.arguments['command'];
            if (call.name == 'run_command' && commandArg is String) {
              command = _short(commandArg, 80);
            } else if (pathArg is String) {
              path = pathArg;
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
          // The next observation (if any) answers the next call of the batch.
          if (pendingCalls.isNotEmpty) {
            final call = pendingCalls.removeAt(0);
            tool = call.name;
            final pathArg = call.arguments['path'];
            final commandArg = call.arguments['command'];
            if (call.name == 'run_command' && commandArg is String) {
              command = _short(commandArg, 80);
            } else if (pathArg is String) {
              path = pathArg;
            }
          }
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
        AssistantEntry(:final thought, :final action) => '$thought '
            '${action.calls.map((call) => call.name).join(' ')}',
        ObservationEntry(:final text) => text,
      };

  /// Render an entry for the summarizer, including each tool call's arguments
  /// so the brief can preserve paths and commands verbatim (C4).
  static String _renderForBrief(Entry entry) => switch (entry) {
        UserEntry(:final text) => text,
        AssistantEntry(:final thought, :final action) => action.calls.isEmpty
            ? thought
            : '${thought.trim()} '
                '${[
                    for (final call in action.calls)
                      '${call.name} ${jsonEncode(call.arguments)}',
                  ].join(' ')}',
        ObservationEntry(:final text) => text,
      };
}
