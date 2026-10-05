import 'dart:async';
import 'dart:convert';

import 'package:dart_tui/dart_tui.dart' show RgbColor, Style;

import 'config.dart';
import 'markdown_render.dart';
import 'models.dart';

/// C6: inline console rendering for the human CLI. Everything here stays on
/// the normal terminal scrollback — no alt-screen, no full-screen takeover.
/// When [ansi] is false (automation, a pipe, the gate) every method degrades
/// to plain text with no escape sequences.
///
/// The user's input (prompt and echo) is left in the terminal's default
/// color — it is what the user is already looking at. The model's answer is
/// rendered by markdown in the model channel color, and local command output
/// is yellow, so the three are easy to tell apart.

const RgbColor _sky = RgbColor(137, 180, 250);
const RgbColor _mauve = RgbColor(203, 166, 247);
const RgbColor _green = RgbColor(166, 227, 161);
const RgbColor _red = RgbColor(243, 139, 168);
const RgbColor _yellow = RgbColor(249, 226, 175);
const RgbColor _teal = RgbColor(148, 226, 213);
const RgbColor _peach = RgbColor(250, 179, 135);
const RgbColor _slate = RgbColor(108, 112, 134);

/// Local command output (`/help`, `/plan`, `/status`, …).
const RgbColor _command = _yellow;

/// Longest tool/command result body shown before the rest is summarized.
const int _maxBodyLines = 8;

final RegExp _diagTag = RegExp(r'^\[([^\]]+)\]\s?(.*)$');

final class Console {
  Console({
    required this.out,
    required this.err,
    required this.ansi,
    bool spinner = false,
    int width = 80,
  })  : _spinnerEnabled = spinner && ansi,
        _markdown = MarkdownStream(width: width);

  final StringSink out;
  final StringSink err;
  final bool ansi;
  final bool _spinnerEnabled;
  final MarkdownStream _markdown;

  Timer? _timer;
  int _frame = 0;
  String _label = '';
  String? _detail;
  String? _hint;
  DateTime? _phaseStart;
  bool _midLine = false;
  bool _reasoningOpen = false;

  /// Wrap [text] in ANSI attributes, or return it unchanged when styling is
  /// off.
  String style(
    String text, {
    bool bold = false,
    bool dim = false,
    bool italic = false,
    bool reverse = false,
    RgbColor? fg,
  }) {
    if (!ansi || text.isEmpty) return text;
    // With no attributes set, leave the text in the terminal's own colors
    // rather than emitting a bare reset.
    if (!bold && !dim && !italic && !reverse && fg == null) return text;
    return Style(
      isBold: bold,
      isDim: dim,
      isItalic: italic,
      isReverse: reverse,
      foregroundRgb: fg,
    ).render(text);
  }

  /// A startup banner line, e.g. the product/config header.
  void banner(String text) {
    endLine();
    err.writeln(style('── ', fg: _sky) + style(text, bold: true, fg: _sky));
  }

  void header(String text) => err.writeln(style('   $text', dim: true));

  /// The leading input prompt, e.g. `› `. Left in the default color.
  void prompt() => out.write(style('› ', bold: true));

  /// Echo a user goal as its own turn header when it was not typed on the
  /// terminal (e.g. a piped script). Left in the default color.
  void user(String text) {
    endLine();
    err.writeln(style('❯ ', bold: true) + style(text, bold: true));
  }

  /// Local command output (`/help`, `/plan`, `/status`, …). Yellow marks the
  /// interface's own output, distinct from the model's answer. The status
  /// spinner is cleared first so the two never share a line, then resumed.
  void info(String text) => _aroundSpinner(() {
        endLine();
        out.writeln(style(text, fg: _command));
      });

  void error(String text) => _aroundSpinner(() {
        endLine();
        err.writeln(style('  ✗ ', fg: _red) + style(text, fg: _red, bold: true));
      });

  /// Print a permanent line without colliding with the status spinner: clear
  /// it, write, then resume it if it was running.
  void _aroundSpinner(void Function() write) {
    final running = _timer != null;
    stopThinking();
    write();
    if (running) _startSpinner();
  }

  /// Stream a chunk of private model reasoning as a dim italic block, prefixed
  /// with a `│` gutter on every line.
  void reasoning(String text) {
    if (text.isEmpty) return;
    stopThinking();
    if (!_reasoningOpen) {
      if (_midLine) {
        out.writeln();
        _midLine = false;
      }
      err.write(_gutter());
      _reasoningOpen = true;
    }
    var rest = text;
    while (true) {
      final nl = rest.indexOf('\n');
      if (nl < 0) {
        err.write(style(rest, dim: true, italic: true));
        return;
      }
      err.write(style(rest.substring(0, nl), dim: true, italic: true));
      err.writeln();
      err.write(_gutter());
      rest = rest.substring(nl + 1);
    }
  }

  String _gutter() => style('  │ ', fg: _slate);

  /// End an open reasoning block, if any.
  void _closeReasoning() {
    if (!_reasoningOpen) return;
    err.writeln();
    _reasoningOpen = false;
  }

  void tool(String name, Map<String, dynamic> arguments,
      {Duration? elapsed}) {
    endLine();
    final timing =
        elapsed == null ? '' : style(' · ${formatDuration(elapsed)}', dim: true);
    err.writeln(style('  → ', fg: _mauve) +
        style(name, bold: true, fg: _mauve) +
        style(' ${briefText(jsonEncode(arguments), 72)}', dim: true) +
        timing);
  }

  /// Render a tool or command result. [label] names the tool; multi-line
  /// results (e.g. `run_command`, `search`, `read`) are indented beneath the
  /// first line and capped. [elapsed] is the dispatch time when measured.
  void observation(Outcome outcome, String text,
      {String? label, Duration? elapsed}) {
    endLine();
    final ok = outcome == Outcome.ok;
    final color = ok ? _green : _red;
    final timing =
        elapsed == null ? '' : style(' · ${formatDuration(elapsed)}', dim: true);
    final lines = const LineSplitter().convert(text);
    final first = lines.isEmpty ? '' : briefText(lines.first, 130);
    err.writeln(
      style('  ${outcomeMark(outcome)} ', fg: color) +
          (label == null ? '' : style('$label ', bold: true, fg: color)) +
          style(first, fg: ok ? null : color) +
          timing,
    );
    if (lines.length <= 1) return;
    // Result bodies are supporting evidence, not the answer: nest them under a
    // dim gutter and dim successful lines so they never outshout the user's
    // input or the model's reply. Errors stay red and un-dimmed to draw the eye.
    final body = lines.skip(1).take(_maxBodyLines);
    for (final line in body) {
      err.writeln(style('      │ ', fg: _slate, dim: true) +
          style(briefText(line, 160), dim: ok, fg: ok ? null : _red));
    }
    final hidden = lines.length - 1 - _maxBodyLines;
    if (hidden > 0) {
      err.writeln(style('      │ ', fg: _slate, dim: true) +
          style('… (+$hidden more lines)', dim: true));
    }
  }

  /// A verbose `[C1]`–`[C8]` diagnostic: a dim gutter and a component-coloured
  /// tag, with the detail dimmed. Clears the status spinner first so the two
  /// never share a line, then resumes it.
  void diagnostic(String line) => _aroundSpinner(() {
        endLine();
        if (!ansi) {
          err.writeln(line);
          return;
        }
        final match = _diagTag.firstMatch(line);
        if (match == null) {
          err.writeln(style('  · $line', dim: true));
          return;
        }
        final tag = match.group(1)!;
        err.writeln(style('  · ', fg: _slate) +
            style('[$tag]', fg: _componentColor(tag)) +
            style(' ${match.group(2)!}', dim: true));
      });

  void startThinking(String label) {
    _label = label;
    _detail = null;
    if (!_spinnerEnabled || _timer != null) return;
    // Give the spinner its own line so clearing it can never erase streamed
    // reply text that is still on the current line.
    endLine();
    _startSpinner();
  }

  /// Start the spinner without flushing the markdown stream, used while a
  /// block is still buffering so the surface does not look frozen. Safe
  /// because no visible reply text is pending on the current line.
  void ensureThinking() {
    if (!_spinnerEnabled || _timer != null) return;
    if (_label.isEmpty) _label = 'composing';
    _startSpinner();
  }

  void _startSpinner() {
    _phaseStart = DateTime.now();
    _timer = Timer.periodic(const Duration(milliseconds: 90), (_) => _tick());
    _tick();
  }

  void updateThinking(String label) {
    _label = label;
  }

  /// Secondary text shown after the elapsed time, e.g. `step 2` or
  /// `ctx 421/8.2K`. Null clears it.
  void setDetail(String? detail) => _detail = detail;

  /// A short suffix appended to the spinner label, e.g. `press Esc twice to
  /// interrupt`. Pass null to clear it.
  void setHint(String? hint) => _hint = hint;

  void _tick() {
    const frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
    final hint = _hint;
    final detail = _detail;
    final start = _phaseStart;
    final elapsed =
        start == null ? Duration.zero : DateTime.now().difference(start);
    // Only tick a visible timer once a call is slow enough to notice; a
    // sub-second call just flashes otherwise.
    final timing = elapsed.inMilliseconds >= 1000
        ? style(' · ${formatDuration(elapsed)}', dim: true)
        : '';
    err.write('\r\x1b[2K  ${frames[_frame++ % frames.length]} '
        '${style(_label, dim: true)}'
        '$timing'
        '${detail == null ? '' : style(' · $detail', dim: true)}'
        '${hint == null ? '' : style(' · $hint', fg: _yellow, dim: true)}');
  }

  /// Stop the spinner, if one is running. A no-op otherwise — importantly,
  /// it must not emit a line-clear when idle, or it would wipe streamed text.
  void stopThinking() {
    final timer = _timer;
    if (timer == null) return;
    timer.cancel();
    _timer = null;
    _phaseStart = null;
    err.write('\r\x1b[2K');
  }

  /// A chunk of streamed reply text. Rendering is progressive, but a partial
  /// line is held until its newline; while nothing is visible the spinner is
  /// kept alive so a slow block does not look like a freeze.
  void delta(String text) {
    _closeReasoning();
    final rendered = _markdown.add(text, style);
    if (rendered.isEmpty) {
      ensureThinking();
      return;
    }
    stopThinking();
    _midLine = !rendered.endsWith('\n');
    out.write(rendered);
  }

  /// Render a whole (one-shot) answer through the markdown renderer.
  void answer(String text) {
    endLine();
    final rendered = _markdown.add('$text\n', style) + _markdown.flush(style);
    out.write(rendered);
    _midLine = rendered.isNotEmpty && !rendered.endsWith('\n');
    if (_midLine) {
      out.writeln();
      _midLine = false;
    }
  }

  /// Finish a partially streamed block, if any.
  void endLine() {
    _closeReasoning();
    final tail = _markdown.flush(style);
    if (tail.isNotEmpty) {
      _midLine = !tail.endsWith('\n');
      out.write(tail);
    }
    if (_midLine) {
      out.writeln();
      _midLine = false;
    }
  }

  void status(String text, {String? kind}) {
    endLine();
    stopThinking();
    if (!ansi) {
      err.writeln(text);
      return;
    }
    final split = text.indexOf(' · ');
    if (split > 0) {
      final head = text.substring(0, split);
      err.writeln(
          style(head,
              bold: true,
              fg: _statusColor(kind ?? head.split(' ').first)) +
              style(text.substring(split), dim: true));
    } else {
      err.writeln(style(text, dim: true));
    }
  }

  void close() {
    endLine();
    stopThinking();
  }
}

RgbColor _statusColor(String status) => switch (status) {
      'complete' => _green,
      'incomplete' => _yellow,
      'blocked' => _red,
      _ => _slate,
    };

/// Colour for a diagnostic tag by its component prefix (`C1`, `C2`, …).
RgbColor _componentColor(String tag) {
  if (tag.startsWith('C1')) return _sky;
  if (tag.startsWith('C2')) return _mauve;
  if (tag.startsWith('C3')) return _green;
  if (tag.startsWith('C4')) return _yellow;
  if (tag.startsWith('C5')) return _teal;
  if (tag.startsWith('C6')) return _sky;
  if (tag.startsWith('C7')) return _peach;
  return _red;
}

/// A fixed-width usage bar, e.g. `[████░░░░]`, or empty when [window] <= 0.
String contextBar(int used, int window, int cells) {
  if (window <= 0) return '';
  final ratio = (used / window).clamp(0.0, 1.0);
  final filled = (ratio * cells).round();
  return '[${'█' * filled}${'░' * (cells - filled)}]';
}

String outcomeMark(Outcome outcome) => switch (outcome) {
      Outcome.ok => '✓',
      Outcome.error => '✗',
      Outcome.guardDenied => '⛔',
    };

/// A compact human duration: `840ms`, `3.2s`, `2m03s`.
String formatDuration(Duration d) {
  final ms = d.inMilliseconds;
  if (ms < 1000) return '${ms}ms';
  if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
  final minutes = d.inMinutes;
  final seconds = d.inSeconds - minutes * 60;
  return '${minutes}m${seconds.toString().padLeft(2, '0')}s';
}

/// Collapse [text] to one line and cap it at [max] characters.
String briefText(Object? text, [int max = 100]) {
  final flat = (text ?? '').toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length > max ? '${flat.substring(0, max)}…' : flat;
}

/// Keep the tail of a path, prefixing `…` when it exceeds [max] columns.
String shortPath(String path, int max) =>
    path.length > max ? '…${path.substring(path.length - max + 1)}' : path;

/// The wire label for a provider kind (`openai-compatible` / `ollama`).
String providerLabel(ProviderKind kind) =>
    kind == ProviderKind.openAiCompatible ? 'openai-compatible' : 'ollama';
