/// C2 wire convention for private model reasoning.
///
/// A model may wrap its private reasoning in a `<think> … </think>` block:
///
/// ```text
/// <think>
/// the user wants the file summarized
/// </think>
/// Here is the summary.
/// ```
///
/// Like the plan block (`plan_block.dart`) it is not part of the answer: the
/// adapter strips it from the visible text and normalizes it into a separate
/// `reasoning` string, which the human interface (C6) renders dim and italic.
/// A missing block means there is no reasoning.
///
/// The same scanner backs both the one-shot parse ([parseThinkBlock]) and the
/// streaming filter ([ThinkTextStream]), so the displayed text and the final
/// completion agree.
const String _openTag = '<think>';
const String _closeTag = '</think>';

final class ThinkExtraction {
  const ThinkExtraction(this.text, this.reasoning);

  /// Visible text with the reasoning block removed.
  final String text;

  /// The accumulated contents of every `<think>` block, concatenated.
  final String reasoning;
}

/// Strip `<think>` blocks from a complete model response.
ThinkExtraction parseThinkBlock(String text) {
  final scan = _scan(text, complete: true);
  return ThinkExtraction(_tidy(scan.visible), scan.reasoning);
}

String _tidy(String text) =>
    text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();

/// Newly revealed text from one [ThinkTextStream] feed: the visible slice and
/// the reasoning slice that became known since the previous call.
final class ThinkChunk {
  const ThinkChunk(this.visible, this.reasoning);

  final String visible;
  final String reasoning;

  bool get isEmpty => visible.isEmpty && reasoning.isEmpty;
}

/// Incremental view over a streamed model response. Feed raw content deltas to
/// [add] and render the returned slices; a partially-arrived tag (or one that
/// could still become a tag) is withheld until it resolves. Call [flush] once
/// the stream ends to emit any trailing text and capture the full reasoning.
final class ThinkTextStream {
  final StringBuffer _raw = StringBuffer();
  int _visibleEmitted = 0;
  int _reasoningEmitted = 0;
  String _reasoning = '';

  String get raw => _raw.toString();

  /// The reasoning revealed so far (complete only after [flush]).
  String get reasoning => _reasoning;

  ThinkChunk add(String delta) {
    _raw.write(delta);
    return _emit(_scan(_raw.toString(), complete: false));
  }

  ThinkChunk flush() => _emit(_scan(_raw.toString(), complete: true));

  ThinkChunk _emit(_Scan scan) {
    final visible = scan.visible.length > _visibleEmitted
        ? scan.visible.substring(_visibleEmitted)
        : '';
    _visibleEmitted = scan.visible.length;
    final reasoning = scan.reasoning.length > _reasoningEmitted
        ? scan.reasoning.substring(_reasoningEmitted)
        : '';
    _reasoningEmitted = scan.reasoning.length;
    _reasoning = scan.reasoning;
    return ThinkChunk(visible, reasoning);
  }
}

final class _Scan {
  const _Scan(this.visible, this.reasoning);
  final String visible;
  final String reasoning;
}

_Scan _scan(String raw, {required bool complete}) {
  // Match tags case-insensitively against a lowered copy, slice the original.
  final lower = raw.toLowerCase();
  final visible = StringBuffer();
  final reasoning = StringBuffer();
  var i = 0;
  var inThink = false;
  while (i < raw.length) {
    if (!inThink) {
      final open = lower.indexOf(_openTag, i);
      if (open < 0) {
        // While streaming, a trailing run that could grow into `<think>` is
        // withheld so earlier visible text is never withdrawn.
        if (!complete) {
          final stop = _partialStart(lower, i, _openTag);
          if (stop != null) {
            visible.write(raw.substring(i, stop));
            return _Scan(visible.toString(), reasoning.toString());
          }
        }
        visible.write(raw.substring(i));
        i = raw.length;
      } else {
        visible.write(raw.substring(i, open));
        i = open + _openTag.length;
        inThink = true;
      }
    } else {
      final close = lower.indexOf(_closeTag, i);
      if (close < 0) {
        if (!complete) {
          final stop = _partialStart(lower, i, _closeTag);
          if (stop != null) {
            reasoning.write(raw.substring(i, stop));
            return _Scan(visible.toString(), reasoning.toString());
          }
        }
        reasoning.write(raw.substring(i));
        i = raw.length;
      } else {
        reasoning.write(raw.substring(i, close));
        i = close + _closeTag.length;
        inThink = false;
      }
    }
  }
  return _Scan(visible.toString(), reasoning.toString());
}

/// When [lower] ends with a proper prefix of [tag] starting at or after
/// [from], return that prefix's start; otherwise null. Used to withhold a tag
/// that may still be arriving.
int? _partialStart(String lower, int from, String tag) {
  for (var k = tag.length - 1; k >= 1; k--) {
    if (lower.endsWith(tag.substring(0, k))) {
      final start = lower.length - k;
      if (start >= from) return start;
    }
  }
  return null;
}
