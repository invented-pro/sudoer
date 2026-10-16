/// C6: verbose diagnostics. The interface owns the toggle; every component
/// reports its internal routing and behavior through [event] using its own
/// component id (`C1`–`C8`). The hot path is free when disabled, which is the
/// default.
final class Diagnostics {
  Diagnostics({this.enabled = false, this.sink, this.traceContent = false});

  /// A shared, permanently silent instance for callers that do not wire one
  /// (the gate, unit tests, and any direct assembly).
  static final Diagnostics silent = Diagnostics();

  /// Whether events are emitted. Toggled live by `/verbose on|off` (C6).
  bool enabled;

  /// Where events go; a null sink drops them even when enabled.
  final void Function(String line)? sink;

  /// Whether full LLM request/response content is also traced (C2): wired
  /// only by the automate surface, whose piped log is the record of exactly
  /// what the model saw and said. The human surface keeps its routing brief
  /// whatever this says, so it is off there and in tests unless asked.
  final bool traceContent;

  /// Emit one diagnostic line for [component], or drop it when disabled.
  /// [detail] should be a short, single-line summary.
  void event(String component, String detail) {
    if (!enabled) return;
    sink?.call('[$component] $detail');
  }
}

/// A wall-clock timestamp for log lines, e.g. `2026-10-06T02:21:53.123Z`.
/// UTC, so lines correlate with the session/ledger clock, and millisecond
/// precision, so consecutive events still order within a step.
String logTimestamp([DateTime? now]) {
  final t = (now ?? DateTime.now()).toUtc();
  String pad2(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${pad2(t.month)}-${pad2(t.day)}'
      'T${pad2(t.hour)}:${pad2(t.minute)}:${pad2(t.second)}'
      '.${t.millisecond.toString().padLeft(3, '0')}Z';
}

/// A compact human duration: `840ms`, `3.2s`, `2m03s`. The one formatter for
/// both the inline run timings and the human status line.
String formatDuration(Duration d) {
  final ms = d.inMilliseconds;
  if (ms < 1000) return '${ms}ms';
  if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
  final minutes = d.inMinutes;
  final seconds = d.inSeconds - minutes * 60;
  return '${minutes}m${seconds.toString().padLeft(2, '0')}s';
}

/// A [StringSink] that prefixes every line written through [writeln] with
/// [logTimestamp] — the automate surface's log format, so a piped build log
/// reads as a timeline. Each line of a multi-line write is stamped on its
/// own; blank separator lines pass through unstamped. [write] and friends
/// forward unchanged (only line-oriented output is log lines).
final class StampingSink implements StringSink {
  StampingSink(this._sink);

  final StringSink _sink;

  @override
  void write(Object? object) => _sink.write(object);

  @override
  void writeAll(Iterable? objects, [String separator = '']) =>
      _sink.writeAll(objects ?? [], separator);

  @override
  void writeCharCode(int charCode) => _sink.writeCharCode(charCode);

  @override
  void writeln([Object? object = '', String? terminator]) {
    final text = '$object';
    if (text.isEmpty) {
      _sink.writeln(terminator ?? '\n');
      return;
    }
    final stamp = logTimestamp();
    for (final line in text.split('\n')) {
      if (line.isEmpty) {
        _sink.writeln();
      } else {
        _sink.write('$stamp $line${terminator ?? '\n'}');
      }
    }
  }
}

/// Collapse [text] to a single line and cap it at [max] characters, for
/// diagnostics where the full value would be noise.
String brief(Object? text, [int max = 120]) {
  final flat = (text ?? '').toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length > max ? '${flat.substring(0, max)}…' : flat;
}
