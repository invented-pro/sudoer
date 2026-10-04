import 'dart:convert';

import 'models.dart';

/// C2 wire convention for plan updates.
///
/// The model reports a plan by including a fenced block labelled `plan` whose
/// body is one Markdown checkbox per item:
///
/// ```plan
/// - [ ] read the file
/// - [x] answer
/// ```
///
/// The block is stripped from the visible text (thought/answer) and normalized
/// into [PlanItem]s. Any non-`plan` fenced block is left untouched. A missing
/// or itemless block means the plan is unchanged.
///
/// The same scanner backs both the one-shot parse ([parsePlanBlock]) and the
/// streaming filter ([PlanTextStream]), so the displayed text and the final
/// completion agree.
final class PlanExtraction {
  const PlanExtraction(this.text, this.plan);
  final String text;
  final List<PlanItem>? plan;
}

/// Strip fenced `plan` blocks from a complete model response.
PlanExtraction parsePlanBlock(String text) {
  final scan = _scan(text, complete: true);
  return PlanExtraction(_tidy(scan.visible), scan.plan);
}

String _tidy(String text) =>
    text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();

/// Incremental view over a streamed model response. Feed raw content deltas to
/// [add] and render the returned visible deltas; a partially-arrived plan
/// block (or a fence that could still become one) is withheld until it
/// resolves. Call [flush] once the stream ends to emit any trailing text and
/// capture the plan.
final class PlanTextStream {
  final StringBuffer _raw = StringBuffer();
  int _emitted = 0;

  /// The plan parsed from the last completed block, if any.
  List<PlanItem>? plan;

  String get raw => _raw.toString();

  String add(String delta) {
    _raw.write(delta);
    return _emit(_scan(_raw.toString(), complete: false).visible);
  }

  String flush() {
    final scan = _scan(_raw.toString(), complete: true);
    plan = scan.plan;
    return _emit(scan.visible);
  }

  String _emit(String visible) {
    if (visible.length <= _emitted) return '';
    final chunk = visible.substring(_emitted);
    _emitted = visible.length;
    return chunk;
  }
}

final RegExp _fenceOpen = RegExp(r'^\s*`{3,}(.*)$');
final RegExp _fenceClose = RegExp(r'^\s*`{3,}\s*$');
final RegExp _fencePartial = RegExp(r'^\s*`{1,2}$');
final RegExp _checkbox = RegExp(r'^\s*[-*]\s*\[([ xX])\]\s*(.+?)\s*$');
final RegExp _bullet = RegExp(r'^[-*]\s+');

final class _Scan {
  const _Scan(this.visible, this.plan);
  final String visible;
  final List<PlanItem>? plan;
}

_Scan _scan(String raw, {required bool complete}) {
  final out = StringBuffer();
  List<PlanItem>? plan;
  var i = 0;
  while (i < raw.length) {
    final nl = raw.indexOf('\n', i);
    final hasNl = nl != -1;
    final lineEnd = hasNl ? nl : raw.length;
    final line = raw.substring(i, lineEnd);
    // While streaming, a trailing backtick run could still grow into a fence;
    // withhold it so earlier visible text is never withdrawn.
    if (!complete && !hasNl && _fencePartial.hasMatch(line)) {
      return _Scan(out.toString(), plan);
    }
    final m = _fenceOpen.firstMatch(line);
    if (m == null) {
      out.write(line);
      if (hasNl) out.write('\n');
      i = hasNl ? lineEnd + 1 : raw.length;
      continue;
    }
    final info = m.group(1)!.trim().toLowerCase();
    final next = hasNl ? lineEnd + 1 : raw.length;
    // An info line still arriving (to end of stream) could become `plan`.
    if (!hasNl && 'plan'.startsWith(info)) return _Scan(out.toString(), plan);
    if (info == 'plan') {
      final close = _closingFence(raw, next);
      if (close == null) {
        plan = _planItems(raw.substring(next));
        return _Scan(out.toString(), plan);
      }
      plan = _planItems(raw.substring(next, close.start));
      i = close.after;
      continue;
    }
    // A non-plan fence: emit the whole block verbatim.
    final close = _closingFence(raw, next);
    if (close == null) {
      out.write(raw.substring(i));
      return _Scan(out.toString(), plan);
    }
    out.write(raw.substring(i, close.after));
    i = close.after;
  }
  return _Scan(out.toString(), plan);
}

final class _Close {
  const _Close(this.start, this.after);
  final int start;
  final int after;
}

_Close? _closingFence(String raw, int from) {
  var i = from;
  while (i <= raw.length) {
    final nl = raw.indexOf('\n', i);
    final hasNl = nl != -1;
    final lineEnd = hasNl ? nl : raw.length;
    if (_fenceClose.hasMatch(raw.substring(i, lineEnd))) {
      return _Close(i, hasNl ? lineEnd + 1 : raw.length);
    }
    if (!hasNl) return null;
    i = lineEnd + 1;
  }
  return null;
}

List<PlanItem>? _planItems(String body) {
  final items = <PlanItem>[];
  for (final line in const LineSplitter().convert(body)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final boxed = _checkbox.firstMatch(trimmed);
    if (boxed != null) {
      items.add(PlanItem(
        text: boxed.group(2)!.trim(),
        done: boxed.group(1)!.toLowerCase() == 'x',
      ));
      continue;
    }
    final text = trimmed.replaceFirst(_bullet, '').trim();
    if (text.isNotEmpty) items.add(PlanItem(text: text));
  }
  return items.isEmpty ? null : items;
}
