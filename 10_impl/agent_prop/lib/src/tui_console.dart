import 'dart:async';
import 'dart:convert';

import 'package:dart_tui/dart_tui.dart'
    show Cursor, CursorShape, RgbColor, Style, getWidth, truncate;

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

  /// Repaint the frame without touching the transcript: the hook the plan
  /// updates come through (C1), so the header panel advances live.
  @override
  void touch() => _changed();

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
    transcript.add(style('› ', bold: true) + style(lines.first, bold: true));
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
      transcript.add(
        style('  ✗ ', fg: _red) + style(lines.first, fg: _red, bold: true),
      );
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
      transcript.add(
        style('  │ ', fg: _slate) + style(line, dim: true, italic: true),
      );
    }
    _changed();
  }

  @override
  void tool(String name, Map<String, dynamic> arguments, {Duration? elapsed}) {
    _flushReasoning();
    _flushMarkdown();
    _flushPartial();
    final timing = elapsed == null
        ? ''
        : style(' · ${formatDuration(elapsed)}', dim: true);
    transcript.add(
      style('  → ', fg: _mauve) +
          style(name, bold: true, fg: _mauve) +
          style(' ${briefText(jsonEncode(arguments), 72)}', dim: true) +
          timing,
    );
    _changed();
  }

  @override
  void observation(
    Outcome outcome,
    String text, {
    String? label,
    Duration? elapsed,
  }) {
    _flushReasoning();
    _flushMarkdown();
    _flushPartial();
    final ok = outcome == Outcome.ok;
    final color = ok ? _green : _red;
    final timing = elapsed == null
        ? ''
        : style(' · ${formatDuration(elapsed)}', dim: true);
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
        transcript.add(
          style('      │ ', fg: _slate, dim: true) +
              style(briefText(line, 160), dim: ok, fg: ok ? null : _red),
        );
      }
      final hidden = lines.length - 1 - _maxBodyLines;
      if (hidden > 0) {
        transcript.add(
          style('      │ ', fg: _slate, dim: true) +
              style('… (+$hidden more lines)', dim: true),
        );
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
      transcript.add(
        style('  · ', fg: _slate) +
            style('[$tag]', fg: componentColor(tag)) +
            style(' ${match.group(2)!}', dim: true),
      );
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
    final elapsed = start == null
        ? Duration.zero
        : DateTime.now().difference(start);
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
    transcript.add(
      style('  │ ', fg: _slate) + style(_reasoning, dim: true, italic: true),
    );
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

/// One lexed piece of a styled terminal line: an ANSI SGR sequence (zero
/// cells, never split) or one visible rune.
final class AnsiToken {
  const AnsiToken(this.text, this.width, {required this.isEscape});

  final String text;
  final int width;
  final bool isEscape;

  bool get isSpace => !isEscape && text == ' ';
  bool get isVisible => !isEscape;
}

/// Split a styled line into escape/visible tokens, so wrap, selection
/// highlight, and text extraction all agree on what occupies a cell.
List<AnsiToken> tokenizeAnsi(String line) {
  final tokens = <AnsiToken>[];
  var i = 0;
  while (i < line.length) {
    if (line.codeUnitAt(i) == 0x1b) {
      final match = ansiSgrPattern.firstMatch(line.substring(i));
      if (match != null && match.start == 0) {
        final text = match.group(0)!;
        tokens.add(AnsiToken(text, 0, isEscape: true));
        i += text.length;
        continue;
      }
    }
    final first = line.codeUnitAt(i);
    var take = 1;
    if (first >= 0xd800 && first <= 0xdbff && i + 1 < line.length) {
      final second = line.codeUnitAt(i + 1);
      if (second >= 0xdc00 && second <= 0xdfff) take = 2;
    }
    final char = line.substring(i, i + take);
    i += take;
    tokens.add(AnsiToken(char, getWidth(char), isEscape: false));
  }
  return tokens;
}

/// Soft-wrap a styled line to [width] visible cells. Escape sequences count
/// as zero cells and are never split; a break lands after the most recent
/// space inside the window (that trailing space is dropped), an over-long
/// word hard-breaks, and an escape run at the break carries onto the
/// continuation line so styling stays open. A line that fits is returned
/// unchanged.
List<String> wrapAnsi(String line, int width) {
  if (width < 1) width = 1;
  final tokens = tokenizeAnsi(line);
  if (tokens.fold(0, (sum, t) => sum + t.width) <= width) return [line];
  final lines = <String>[];
  var current = <AnsiToken>[];
  var currentWidth = 0;
  var lastSpace = -1;

  void emit(List<AnsiToken> part) {
    lines.add([for (final t in part) t.text].join());
  }

  void breakHere() {
    if (lastSpace >= 0) {
      // lastSpace == current.length is the virtual break point an overflowing
      // trailing space left: everything so far stays on this line.
      final atEnd = lastSpace >= current.length;
      final head = atEnd ? current : current.sublist(0, lastSpace);
      final tail = atEnd ? <AnsiToken>[] : current.sublist(lastSpace + 1);
      if (head.any((t) => t.isVisible)) emit(head);
      current = tail;
    } else {
      // No space in the window: hard-break the over-long word after its
      // last visible cell, carrying any trailing escapes along.
      var cut = current.length;
      while (cut > 0 && current[cut - 1].isEscape) {
        cut--;
      }
      if (cut == 0) return;
      emit(current.sublist(0, cut));
      current = current.sublist(cut);
    }
    currentWidth = current.fold(0, (sum, t) => sum + t.width);
    lastSpace = -1;
    for (var i = 0; i < current.length; i++) {
      if (current[i].isSpace) lastSpace = i;
    }
  }

  for (final token in tokens) {
    if (!token.isEscape) {
      // A space that would overflow is dropped, and it marks the break point
      // at the end of this line: the next word that does not fit starts the
      // next line, without pulling back the word that still fit.
      if (token.isSpace &&
          currentWidth > 0 &&
          currentWidth + token.width > width) {
        lastSpace = current.length;
        continue;
      }
      if (currentWidth > 0 && currentWidth + token.width > width) {
        breakHere();
      }
    }
    current.add(token);
    currentWidth += token.width;
    if (token.isSpace) lastSpace = current.length - 1;
  }
  if (current.any((t) => t.isVisible)) emit(current);
  return lines;
}

/// A selection over rendered frame rows: (row, column) pairs in visible
/// cells; row 0 is the frame's first content line. [startRow]/[startCol]
/// precede or equal [endRow]/[endCol] in row-major order.
final class TuiSelection {
  const TuiSelection({
    required this.startRow,
    required this.startCol,
    required this.endRow,
    required this.endCol,
  });

  final int startRow;
  final int startCol;
  final int endRow;
  final int endCol;
}

/// Apply reverse-video spans to [lines] over [selection]; the markers are
/// inserted at visible-cell boundaries so the underlying styling survives.
List<String> applySelectionSpans(List<String> lines, TuiSelection selection) {
  final out = <String>[];
  for (var row = 0; row < lines.length; row++) {
    final line = lines[row];
    if (row < selection.startRow || row > selection.endRow) {
      out.add(line);
      continue;
    }
    final from = row == selection.startRow ? selection.startCol : 0;
    final to = row == selection.endRow ? selection.endCol : 1 << 30;
    if (to <= from) {
      out.add(line);
      continue;
    }
    final buffer = StringBuffer();
    var col = 0;
    var open = false;
    for (final token in tokenizeAnsi(line)) {
      if (token.isEscape) {
        buffer.write(token.text);
        continue;
      }
      if (!open && col >= from && col < to) {
        buffer.write('\x1b[7m');
        open = true;
      } else if (open && col >= to) {
        buffer.write('\x1b[27m');
        open = false;
      }
      buffer.write(token.text);
      col += token.width;
    }
    if (open) buffer.write('\x1b[27m');
    out.add(buffer.toString());
  }
  return out;
}

/// The visible text [selection] covers across [lines], one source row per
/// output line (rows outside the selection are skipped, not blank).
String extractSelection(List<String> lines, TuiSelection selection) {
  final out = <String>[];
  for (var row = selection.startRow; row <= selection.endRow; row++) {
    if (row < 0 || row >= lines.length) continue;
    final from = row == selection.startRow ? selection.startCol : 0;
    final to = row == selection.endRow ? selection.endCol : 1 << 30;
    final buffer = StringBuffer();
    var col = 0;
    for (final token in tokenizeAnsi(lines[row])) {
      if (token.isEscape) continue;
      final next = col + token.width;
      if (next > from && col < to) buffer.write(token.text);
      col = next;
    }
    out.add(buffer.toString());
  }
  return out.join('\n');
}

/// The terminal frame produced by [TuiFrame].
final class TuiFrameResult {
  const TuiFrameResult({required this.content, required this.cursor});

  final String content;
  final Cursor cursor;
}

/// One bordered header panel: a slate box with [label] on the top border and
/// one padded row per entry, every line exactly [width] visible cells wide.
List<String> _panelBox(String label, List<String> rows, {required int width}) {
  final edge = _slate;
  final inner = width - 4;
  return [
    '${TuiFrame.style('╭─ $label ', fg: edge)}'
        '${TuiFrame.style('─' * (width - label.length - 5).clamp(0, width), fg: edge)}'
        '${TuiFrame.style('╮', fg: edge)}',
    for (final content in rows)
      '${TuiFrame.style('│ ', fg: edge)}'
          '${truncate(content, inner)}'
          '${' ' * (inner - visibleWidth(content)).clamp(0, inner)}'
          '${TuiFrame.style(' │', fg: edge)}',
    TuiFrame.style('╰${'─' * (width - 2).clamp(0, width)}╯', fg: edge),
  ];
}

/// The session plan as a bordered checklist panel for the TUI header (C1,
/// C6): the top area carries the ongoing progress, so the plan draws as a
/// box with slate edges — a green `✓` with dim text per done step, a mauve
/// bold `❯` on the first pending item (the step in flight), a dim `○` for
/// the steps still queued. At most [maxRows] item rows are drawn and any
/// remainder folds into a trailing `+N more` row so a long plan can never
/// crowd out the transcript; the active item is always kept within the shown
/// rows. Empty when there is no plan.
List<String> planPanel(List<PlanItem> plan, {int maxRows = 5, int width = 80}) {
  if (plan.isEmpty) return const [];
  if (maxRows < 2) maxRows = 2;
  if (width < 8) width = 8;
  final active = plan.indexWhere((item) => !item.done);
  final overflow = plan.length > maxRows;
  final slots = overflow ? maxRows - 1 : plan.length;
  final shown = [for (var i = 0; i < slots; i++) i];
  if (overflow && active >= slots) shown[slots - 1] = active;
  String item(int i) {
    final item = plan[i];
    if (item.done) {
      return '${TuiFrame.style('✓ ', fg: _green)}'
          '${TuiFrame.style(item.text, dim: true)}';
    }
    if (i == active) {
      return '${TuiFrame.style('❯ ', bold: true, fg: _mauve)}'
          '${TuiFrame.style(item.text, bold: true)}';
    }
    return '${TuiFrame.style('○ ', dim: true, fg: _slate)}'
        '${TuiFrame.style(item.text, dim: true)}';
  }

  return _panelBox('plan', [
    for (final i in shown) item(i),
    if (overflow)
      TuiFrame.style('… +${plan.length - slots} more', dim: true, fg: _slate),
  ], width: width);
}

/// The queued follow-up messages as a bordered panel (C6), drawn just above
/// the editor: one unstyled row per message in run order (newlines
/// flattened), folded to [maxRows] rows with a `+N more` tail. Empty when
/// nothing is queued.
List<String> queuePanel(
  List<String> messages, {
  int maxRows = 3,
  int width = 80,
}) {
  if (messages.isEmpty) return const [];
  if (maxRows < 1) maxRows = 1;
  if (width < 8) width = 8;
  final overflow = messages.length > maxRows;
  final shown = overflow ? messages.sublist(0, maxRows - 1) : messages;
  return _panelBox('queued', [
    for (final message in shown)
      message.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim(),
    if (overflow)
      TuiFrame.style(
        '… +${messages.length - shown.length} more',
        dim: true,
        fg: _slate,
      ),
  ], width: width);
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
    this.queueLines = const <String>[],
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

  /// Pre-rendered queued-messages panel drawn between the transcript and the
  /// editor (C6); the transcript viewport shrinks by these rows.
  final List<String> queueLines;
  final bool running;
  final int scrollOffset;
  final bool follow;
  final String placeholder;

  static int transcriptHeight({
    required int height,
    required int headerLines,
    required int inputLines,
    int queueLines = 0,
  }) {
    // header + rule, queue panel, editor top/bottom, status, hint.
    final available =
        height - (headerLines + 1) - (inputLines + 2) - 2 - queueLines;
    return available < 1 ? 1 : available;
  }

  /// The transcript content pre-wrapped to [available] visible cells with
  /// [wrapAnsi] (word-aware, ANSI-safe). The viewport's own soft wrap counts
  /// escape bytes as cells, which breaks words mid-run and can split a color
  /// sequence across rows — so the frame wraps first and the viewport only
  /// slices. The scroll probe uses the same builder, so line counts and
  /// offsets always agree.
  static String transcriptContent(
    List<String> transcript,
    String partial,
    int available,
  ) => [
    for (final line in [...transcript, if (partial.isNotEmpty) partial])
      ...wrapAnsi(line, available),
  ].join('\n');

  TuiFrameResult render() {
    final w = width < 8 ? 8 : width;
    final h = height < 6 ? 6 : height;
    final headerLines = header.map((line) => truncate(line, w)).toList();
    headerLines.add(style('  ${'─' * (w - 4).clamp(0, w)}', dim: true));

    var shownInput = inputLines.isEmpty
        ? <String>['']
        : List<String>.of(inputLines);
    // On a very short terminal, keep the editor and footer visible rather
    // than letting a tall multi-line draft eat the transcript.
    final maxEditor = (h - (header.length + 1) - queueLines.length - 2 - 1)
        .clamp(1, shownInput.length);
    if (shownInput.length > maxEditor) {
      shownInput = shownInput.take(maxEditor).toList();
    }
    var transcriptRows = transcriptHeight(
      height: h,
      headerLines: header.length,
      inputLines: shownInput.length,
      queueLines: queueLines.length,
    );
    if (transcriptRows < 1) transcriptRows = 1;

    // The rows are already word-wrapped and ANSI-safe (transcriptContent), so
    // the frame slices them itself: the viewport's cell counting treats
    // escape-sequence bytes as visible cells, which truncates styled rows
    // mid-word and can leak sequence fragments.
    final wrapped = transcriptContent(
      transcript,
      partial,
      (w - 2).clamp(1, w),
    ).split('\n');
    final maxOffset = (wrapped.length - transcriptRows).clamp(
      0,
      wrapped.length,
    );
    final offset = (follow ? maxOffset : scrollOffset).clamp(0, maxOffset);
    final contentWidth = (w - 2).clamp(1, w);
    final visible = <String>[
      for (
        var i = offset;
        i < offset + transcriptRows && i < wrapped.length;
        i++
      )
        '  ${truncate(wrapped[i], contentWidth)}',
    ];
    while (visible.length < transcriptRows) {
      visible.add('  ');
    }

    final lines = <String>[...headerLines, ...visible];
    // The queued panel sits between the transcript and the editor (C6).
    lines.addAll([for (final line in queueLines) truncate(line, w)]);

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
      lines.add(
        truncate(
          '${style('│ ', fg: borderColor)}'
          '${style(prompt, bold: true)}$clipped$padding'
          '${style(' │', fg: borderColor)}',
          w,
        ),
      );
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

    final row =
        (headerLines.length +
                transcriptRows +
                1 +
                cursorRow.clamp(0, shownInput.length - 1))
            .clamp(0, h - 1);
    final col = (4 + cursorColumn).clamp(0, w - 1);
    return TuiFrameResult(
      content: lines.join('\n'),
      cursor: Cursor(x: col, y: row, shape: CursorShape.bar),
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
