import 'dart:async';
import 'dart:convert';

import 'package:dart_tui/dart_tui.dart'
    show
        Cursor,
        CursorShape,
        RgbColor,
        Style,
        ViewportModel,
        getWidth,
        truncate;

import 'console.dart';
import 'diagnostics.dart';
import 'markdown_render.dart';
import 'models.dart';

/// C6: the full-screen console. It keeps the same rendering vocabulary as the
/// inline [Console] (channels, markdown, tool lines, status) but writes into a
/// transcript buffer instead of the terminal's scrollback. The TUI app owns
/// the alternate screen and draws the fixed header, transcript viewport,
/// editor, and status footer.
const RgbColor _sky = RgbColor(137, 180, 250);
const RgbColor _mauve = RgbColor(203, 166, 247);
const RgbColor _green = RgbColor(166, 227, 161);
const RgbColor _red = RgbColor(243, 139, 168);
const RgbColor _yellow = RgbColor(249, 226, 175);
const RgbColor _slate = RgbColor(108, 112, 134);

const int _maxBodyLines = 8;
final RegExp _diagTag = RegExp(r'^\[([^\]]+)\]\s?(.*)$');

/// The interactive console used by the full-screen TUI.
///
/// Output is kept as ANSI-styled logical lines. The app wraps them with a
/// [ViewportModel], so the transcript scrolls independently of the editor and
/// footer. The spinner and status live in the footer rather than being painted
/// over the transcript.
final class TuiConsole implements ConsoleSurface {
  TuiConsole({int width = 80, this.onChange})
      : _width = width,
        _markdown = MarkdownStream(width: width) {
    out = TuiSink(this);
    err = TuiSink(this);
  }

  int _width;
  MarkdownStream _markdown;

  /// Called after any visible mutation; the app queues a render.
  void Function()? onChange;

  /// Logical transcript lines, already styled for the terminal.
  final List<String> transcript = [];

  /// Startup header lines supplied by the REPL; the app normally builds its
  /// own header from the live provider/session state.
  final List<String> headerLines = [];

  /// The current streamed line (without its trailing newline), if any.
  String partial = '';

  String? statusText;
  String? statusKind;
  String? thinkingLabel;
  String? thinkingDetail;
  String? hint;

  String _reasoning = '';
  Timer? _timer;
  int _frame = 0;
  DateTime? _phaseStart;

  @override
  late final TuiSink out;
  @override
  late final TuiSink err;

  static const List<String> _frames = [
    '⠋',
    '⠙',
    '⠹',
    '⠸',
    '⠼',
    '⠴',
    '⠦',
    '⠧',
    '⠇',
    '⠏',
  ];

  int get width => _width;

  set width(int value) {
    if (value == _width || value < 1) return;
    _width = value;
    // Markdown tables and fenced blocks are width-sensitive. A resize starts a
    // fresh stream; a mid-table resize is rare and the next block reflows.
    _markdown = MarkdownStream(width: value);
    _changed();
  }

  bool get isThinking => _timer != null;

  String get spinnerFrame => _frames[_frame % _frames.length];

  void _changed() => onChange?.call();

  @override
  String style(
    String text, {
    bool bold = false,
    bool dim = false,
    bool italic = false,
    bool reverse = false,
    RgbColor? fg,
  }) {
    if (text.isEmpty) return text;
    if (!bold && !dim && !italic && !reverse && fg == null) return text;
    return Style(
      isBold: bold,
      isDim: dim,
      isItalic: italic,
      isReverse: reverse,
      foregroundRgb: fg,
    ).render(text);
  }

  @override
  void banner(String text) {
    headerLines.add(style('── $text', bold: true, fg: _sky));
    _changed();
  }

  @override
  void header(String text) {
    headerLines.add(style('   $text', dim: true));
    _changed();
  }

  @override
  void prompt() {
    // The editor draws its own prompt.
  }

  @override
  void user(String text) {
    _flushReasoning();
    _flushMarkdown();
    _flushPartial();
    if (transcript.isNotEmpty && transcript.last.isNotEmpty) {
      transcript.add('');
    }
    final lines = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '')
        .split('\n');
    transcript.add(style('› ', bold: true) +
        style(lines.first, bold: true));
    for (final line in lines.skip(1)) {
      transcript.add(style('  $line'));
    }
    _changed();
  }

  @override
  void info(String text) {
    _flushReasoning();
    _flushMarkdown();
    _flushPartial();
    final lines = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '')
        .split('\n');
    for (final line in lines) {
      transcript.add(style(line, fg: _yellow));
    }
    _changed();
  }

  @override
  void error(String text) {
    _flushReasoning();
    _flushMarkdown();
    _flushPartial();
    final lines = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '')
        .split('\n');
    if (lines.isEmpty) {
      transcript.add(style('  ✗ ', fg: _red));
    } else {
      transcript.add(style('  ✗ ', fg: _red) +
          style(lines.first, fg: _red, bold: true));
      for (final line in lines.skip(1)) {
        transcript.add(style('    $line', fg: _red));
      }
    }
    _changed();
  }

  @override
  void reasoning(String text) {
    if (text.isEmpty) return;
    _flushMarkdown();
    _flushPartial();
    _reasoning += text.replaceAll('\r\n', '\n').replaceAll('\r', '');
    while (true) {
      final nl = _reasoning.indexOf('\n');
      if (nl < 0) break;
      final line = _reasoning.substring(0, nl);
      _reasoning = _reasoning.substring(nl + 1);
      transcript.add(style('  │ ', fg: _slate) +
          style(line, dim: true, italic: true));
    }
    _changed();
  }

  @override
  void tool(String name, Map<String, dynamic> arguments,
      {Duration? elapsed}) {
    _flushReasoning();
    _flushMarkdown();
    _flushPartial();
    final timing =
        elapsed == null ? '' : style(' · ${formatDuration(elapsed)}', dim: true);
    transcript.add(style('  → ', fg: _mauve) +
        style(name, bold: true, fg: _mauve) +
        style(' ${briefText(jsonEncode(arguments), 72)}', dim: true) +
        timing);
    _changed();
  }

  @override
  void observation(Outcome outcome, String text,
      {String? label, Duration? elapsed}) {
    _flushReasoning();
    _flushMarkdown();
    _flushPartial();
    final ok = outcome == Outcome.ok;
    final color = ok ? _green : _red;
    final timing =
        elapsed == null ? '' : style(' · ${formatDuration(elapsed)}', dim: true);
    final lines = const LineSplitter().convert(text);
    final first = lines.isEmpty ? '' : briefText(lines.first, 130);
    transcript.add(
      style('  ${outcomeMark(outcome)} ', fg: color) +
          (label == null ? '' : style('$label ', bold: true, fg: color)) +
          style(first, fg: ok ? null : color) +
          timing,
    );
    if (lines.length > 1) {
      final body = lines.skip(1).take(_maxBodyLines);
      for (final line in body) {
        transcript.add(style('      │ ', fg: _slate, dim: true) +
            style(briefText(line, 160), dim: ok, fg: ok ? null : _red));
      }
      final hidden = lines.length - 1 - _maxBodyLines;
      if (hidden > 0) {
        transcript.add(style('      │ ', fg: _slate, dim: true) +
            style('… (+$hidden more lines)', dim: true));
      }
    }
    _changed();
  }

  @override
  void diagnostic(String line) {
    _flushReasoning();
    _flushMarkdown();
    _flushPartial();
    final match = _diagTag.firstMatch(line);
    if (match == null) {
      transcript.add(style('  · $line', dim: true));
    } else {
      final tag = match.group(1)!;
      transcript.add(style('  · ', fg: _slate) +
          style('[$tag]', fg: componentColor(tag)) +
          style(' ${match.group(2)!}', dim: true));
    }
    _changed();
  }

  @override
  void startThinking(String label) {
    thinkingLabel = label;
    thinkingDetail = null;
    if (_timer == null) {
      _phaseStart = DateTime.now();
      _timer = Timer.periodic(const Duration(milliseconds: 90), (_) {
        _frame++;
        _changed();
      });
    }
    _changed();
  }

  @override
  void ensureThinking() {
    if (_timer != null) return;
    thinkingLabel ??= 'composing';
    _phaseStart ??= DateTime.now();
    _timer = Timer.periodic(const Duration(milliseconds: 90), (_) {
      _frame++;
      _changed();
    });
    _changed();
  }

  @override
  void updateThinking(String label) {
    thinkingLabel = label;
    _changed();
  }

  @override
  void setDetail(String? detail) {
    thinkingDetail = detail;
    _changed();
  }

  @override
  void setHint(String? value) {
    hint = value;
    _changed();
  }

  @override
  void stopThinking() {
    final timer = _timer;
    if (timer == null) return;
    timer.cancel();
    _timer = null;
    thinkingLabel = null;
    thinkingDetail = null;
    _phaseStart = null;
    _changed();
  }

  /// A single styled line for the footer while a run is in flight.
  String thinkingLine() {
    final label = thinkingLabel ?? 'working';
    final start = _phaseStart;
    final elapsed =
        start == null ? Duration.zero : DateTime.now().difference(start);
    final timing = elapsed.inMilliseconds >= 1000
        ? style(' · ${formatDuration(elapsed)}', dim: true)
        : '';
    final detail = thinkingDetail;
    return '  $spinnerFrame ${style(label, dim: true)}$timing'
        '${detail == null ? '' : style(' · $detail', dim: true)}';
  }

  @override
  void delta(String text) {
    _flushReasoning();
    final rendered = _markdown.add(text, style);
    if (rendered.isEmpty) {
      ensureThinking();
      return;
    }
    _writeRendered(rendered);
  }

  @override
  void answer(String text) {
    _flushReasoning();
    _writeRendered(_markdown.add('$text\n', style));
    _writeRendered(_markdown.flush(style));
    _flushPartial();
  }

  @override
  void endLine() {
    _flushReasoning();
    _flushMarkdown();
    _flushPartial();
  }

  @override
  void status(String text, {String? kind}) {
    _flushReasoning();
    _flushMarkdown();
    _flushPartial();
    statusText = text;
    statusKind = kind;
    _changed();
  }

  @override
  void close() {
    _timer?.cancel();
    _timer = null;
    _flushReasoning();
    _flushMarkdown();
    _flushPartial();
    _changed();
  }

  void _flushMarkdown() {
    _writeRendered(_markdown.flush(style));
  }

  void _flushReasoning() {
    if (_reasoning.isEmpty) return;
    transcript.add(style('  │ ', fg: _slate) +
        style(_reasoning, dim: true, italic: true));
    _reasoning = '';
  }

  void _flushPartial() {
    if (partial.isEmpty) return;
    transcript.add(partial);
    partial = '';
    _changed();
  }

  void _writeRendered(String text) {
    if (text.isEmpty) return;
    var rest = text.replaceAll('\r\n', '\n').replaceAll('\r', '');
    while (true) {
      final nl = rest.indexOf('\n');
      if (nl < 0) {
        partial += rest;
        break;
      }
      transcript.add(partial + rest.substring(0, nl));
      partial = '';
      rest = rest.substring(nl + 1);
    }
    _changed();
  }

  /// Clear the visible transcript, e.g. when `/new` or `/resume` changes the
  /// session. The session file remains the authority.
  void resetTranscript() {
    transcript.clear();
    partial = '';
    _reasoning = '';
    _markdown = MarkdownStream(width: _width);
    statusText = null;
    statusKind = null;
    _changed();
  }

  /// Replay a saved session into the transcript so a resumed TUI opens with
  /// the same conversation the session file holds. Presentation only.
  void replay(Iterable<Entry> entries) {
    for (final entry in entries) {
      switch (entry) {
        case UserEntry(:final text):
          user(text);
        case AssistantEntry(:final thought, :final action):
          switch (action) {
            case Finish(:final answer):
              // A finish stores the answer in `thought` too; do not render it
              // twice as reasoning.
              if (answer.isNotEmpty) this.answer(answer);
            case ToolBatch(:final calls):
              if (thought.isNotEmpty) reasoning('$thought\n');
              for (final call in calls) {
                tool(call.name, call.arguments);
              }
          }
        case ObservationEntry(:final text, :final outcome):
          observation(outcome, text);
      }
    }
    endLine();
  }

  /// Append raw text from a shell command or another [StringSink] writer.
  void writeRaw(Object? value) {
    _writeRendered('${value ?? ''}');
  }

  /// Append raw text followed by a newline.
  void writeRawLine([Object? value = '']) {
    writeRaw('${value ?? ''}\n');
  }
}

/// A [StringSink] backed by [TuiConsole], used for shell output and any code
/// that writes directly to the console's stdout/stderr.
final class TuiSink implements StringSink {
  TuiSink(this.console);

  final TuiConsole console;

  @override
  void write(Object? object) => console.writeRaw(object);

  @override
  void writeAll(Iterable objects, [String separator = '']) {
    var first = true;
    for (final object in objects) {
      if (!first) write(separator);
      write(object);
      first = false;
    }
  }

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void writeln([Object? object = '']) => console.writeRawLine(object);
}

/// The terminal frame produced by [TuiFrame].
final class TuiFrameResult {
  const TuiFrameResult({required this.content, required this.cursor});

  final String content;
  final Cursor cursor;
}

/// C6: compose one full-screen frame.
///
/// Layout follows Pi's interactive mode: a compact header, a scrollable
/// transcript, a bordered multi-line editor, then the status and key hints.
/// The frame always fills [height] rows so the differential renderer can clear
/// stale cells; every line is truncated to [width].
final class TuiFrame {
  TuiFrame({
    required this.width,
    required this.height,
    required this.header,
    required this.transcript,
    required this.partial,
    required this.inputLines,
    required this.cursorRow,
    required this.cursorColumn,
    required this.status,
    required this.hint,
    required this.running,
    required this.scrollOffset,
    required this.follow,
    this.placeholder = 'Type a goal, or /help for commands…',
  });

  final int width;
  final int height;

  /// Two styled header lines; the frame adds the dim rule beneath them.
  final List<String> header;
  final List<String> transcript;
  final String partial;
  final List<String> inputLines;
  final int cursorRow;
  final int cursorColumn;
  final String status;
  final String hint;
  final bool running;
  final int scrollOffset;
  final bool follow;
  final String placeholder;

  static int transcriptHeight({
    required int height,
    required int headerLines,
    required int inputLines,
  }) {
    // header + rule, editor top/bottom, status, hint.
    final available = height - (headerLines + 1) - (inputLines + 2) - 2;
    return available < 1 ? 1 : available;
  }

  TuiFrameResult render() {
    final w = width < 8 ? 8 : width;
    final h = height < 6 ? 6 : height;
    final headerLines = header.map((line) => truncate(line, w)).toList();
    headerLines.add(style('  ${'─' * (w - 4).clamp(0, w)}', dim: true));

    var shownInput =
        inputLines.isEmpty ? <String>[''] : List<String>.of(inputLines);
    // On a very short terminal, keep the editor and footer visible rather
    // than letting a tall multi-line draft eat the transcript.
    final maxEditor =
        (h - (header.length + 1) - 2 - 1).clamp(1, shownInput.length);
    if (shownInput.length > maxEditor) {
      shownInput = shownInput.take(maxEditor).toList();
    }
    var transcriptRows = transcriptHeight(
      height: h,
      headerLines: header.length,
      inputLines: shownInput.length,
    );
    if (transcriptRows < 1) transcriptRows = 1;

    final content = [
      ...transcript,
      if (partial.isNotEmpty) partial,
    ].join('\n');
    final probe = ViewportModel(
      content: content,
      width: w,
      height: transcriptRows,
      softWrap: true,
      fillHeight: true,
      gutterBuilder: (_) => '  ',
    );
    final maxOffset =
        (probe.totalLines - transcriptRows).clamp(0, probe.totalLines);
    final offset =
        (follow ? maxOffset : scrollOffset).clamp(0, maxOffset);
    final visible = (offset == 0 ? probe : probe.scrollTo(offset))
        .view()
        .content
        .split('\n');

    final lines = <String>[...headerLines, ...visible];

    final borderColor = running ? _mauve : _slate;
    final title = running ? ' running ' : ' message ';
    lines.add(_topBorder(w, title, borderColor));

    final textWidth = (w - 6).clamp(1, w);
    final blankEditor = shownInput.length == 1 && shownInput.first.isEmpty;
    for (var i = 0; i < shownInput.length; i++) {
      final raw = shownInput[i];
      final display = blankEditor
          ? style(placeholder, dim: true, italic: true)
          : raw;
      final clipped = truncate(display, textWidth);
      final padding = ' ' * (textWidth - getWidth(clipped)).clamp(0, textWidth);
      final prompt = i == 0 ? '› ' : '  ';
      lines.add(truncate(
        '${style('│ ', fg: borderColor)}'
        '${style(prompt, bold: true)}$clipped$padding'
        '${style(' │', fg: borderColor)}',
        w,
      ));
    }
    lines.add(style('╰${'─' * (w - 2).clamp(0, w)}╯', fg: borderColor));
    lines.add(truncate(status, w));
    lines.add(truncate(hint, w));

    while (lines.length < h) {
      lines.add('');
    }
    if (lines.length > h) {
      lines.removeRange(h, lines.length);
    }

    final row = (headerLines.length +
            transcriptRows +
            1 +
            cursorRow.clamp(0, shownInput.length - 1))
        .clamp(0, h - 1);
    final col = (4 + cursorColumn).clamp(0, w - 1);
    return TuiFrameResult(
      content: lines.join('\n'),
      cursor: Cursor(
        x: col,
        y: row,
        shape: CursorShape.bar,
      ),
    );
  }

  static String _topBorder(int width, String title, RgbColor color) {
    if (width < 4) return style('─' * width, fg: color);
    final label = truncate(title, width - 2);
    final fill = (width - 2 - getWidth(label)).clamp(0, width);
    return style('╭$label${'─' * fill}╮', fg: color);
  }

  static String style(
    String text, {
    bool bold = false,
    bool dim = false,
    bool italic = false,
    RgbColor? fg,
  }) {
    if (text.isEmpty) return text;
    if (!bold && !dim && !italic && fg == null) return text;
    return Style(
      isBold: bold,
      isDim: dim,
      isItalic: italic,
      foregroundRgb: fg,
    ).render(text);
  }
}
