part of 'interface.dart';

const RgbColor _tuiSky = RgbColor(137, 180, 250);
const RgbColor _tuiMauve = RgbColor(203, 166, 247);
const RgbColor _tuiGreen = RgbColor(166, 227, 161);
const RgbColor _tuiRed = RgbColor(243, 139, 168);
const RgbColor _tuiYellow = RgbColor(249, 226, 175);
const RgbColor _tuiSlate = RgbColor(108, 112, 134);

/// A console mutation happened; render the next frame.
final class _TuiRedraw extends Msg {
  const _TuiRedraw();
}

/// Elm-style adapter around [_TuiApp]. Program owns the terminal; the app owns
/// the mutable editor, queue, scroll position, and the run in flight.
final class _TuiModel extends Model {
  _TuiModel(this.app);

  final _TuiApp app;

  @override
  (Model, Cmd?) update(Msg msg) {
    switch (msg) {
      case _TuiRedraw():
        break;
      case WindowSizeMsg(:final width, :final height):
        app.resize(width, height);
      case KeyPressMsg(:final keyEvent):
        app.handleKey(keyEvent);
      case PasteMsg(:final content):
        app.handlePaste(content);
      default:
        break;
    }
    return (this, null);
  }

  @override
  View view() => app.view();
}

/// C6: the full-screen interactive app. It keeps one editor, a bounded run
/// queue, and the transcript owned by [TuiConsole].
final class _TuiApp {
  _TuiApp({
    required this.repl,
    required this.console,
    required this.program,
  })  : width = 80,
        height = 24,
        editor = TextAreaModel(
          width: 60,
          maxHeight: 8,
          minHeight: 1,
          dynamicHeight: true,
          focused: true,
          styles: const TextAreaStyles(
            text: Style(foregroundRgb: RgbColor(205, 214, 244)),
            placeholder: Style(
              foregroundRgb: RgbColor(108, 112, 134),
              isDim: true,
              isItalic: true,
            ),
          ),
        ) {
    width = console.width.clamp(8, 500);
    // Markdown renders into the transcript's content column (the frame adds a
    // two-cell gutter).
    console.width = (width - 2).clamp(20, 500);
    editor = editor.copyWith(width: (width - 6).clamp(1, width));
    _hydrate();
  }

  final _Repl repl;
  final TuiConsole console;
  final Program program;
  late _TuiModel model;

  TextAreaModel editor;
  final List<String> history = [];
  final List<String> queue = [];

  int width;
  int height;
  int historyIndex = -1;
  String historyDraft = '';
  int scrollOffset = 0;
  bool follow = true;
  bool running = false;
  bool cancelled = false;
  bool shellRunning = false;
  bool closed = false;
  bool naturalExit = false;

  Future<void> _active = Future<void>.value();

  /// Completes when the current run (and any queued follow-up) is done.
  Future<void> get drained => _active;

  /// Replay a resumed session into the transcript so the TUI opens with the
  /// same conversation the session file holds.
  void _hydrate() => console.replay(repl.session.transcript);

  TextAreaModel get _sizedEditor =>
      editor.copyWith(width: (width - 6).clamp(1, width), focused: true);

  int get _transcriptHeight {
    final inputLines = _sizedEditor.view().content.split('\n').length;
    return TuiFrame.transcriptHeight(
      height: height,
      headerLines: 2,
      inputLines: inputLines,
    );
  }

  void resize(int nextWidth, int nextHeight) {
    width = nextWidth.clamp(8, 500);
    height = nextHeight.clamp(6, 300);
    editor = editor.copyWith(width: (width - 6).clamp(1, width));
    console.width = (width - 2).clamp(20, 500);
    _changed();
  }

  void _changed() {
    if (!closed) program.send(const _TuiRedraw());
  }

  View view() {
    final provider = repl.config.provider.display;
    final sessionId = repl.session.id;
    final shortId =
        sessionId.length > 14 ? '${sessionId.substring(0, 12)}…' : sessionId;
    final shortWorkspace =
        shortPath(repl.workspaceRoot, (width - 38).clamp(8, width));
    final entries = repl.session.transcript.length;
    final header = [
      '${_s('  Sudoer $kBuildLabel', bold: true, fg: _tuiSky)}'
          '${_s('  ·  ', dim: true)}${_s(provider, fg: _tuiMauve)}',
      _s('  workspace $shortWorkspace  ·  session $shortId  ·  '
          '$entries entries', dim: true),
    ];

    final editorView = _sizedEditor.view();
    final inputLines = editorView.content.split('\n');
    final cursor = editorView.cursor;

    String status;
    final baseHint = running
        ? (shellRunning
            ? 'running command · PgUp/PgDn scroll · Enter queues a message'
            : 'Esc cancel · PgUp/PgDn scroll · Enter queues a message')
        : 'Enter send · Shift+Enter newline · /help · Ctrl+C quit';
    if (running) {
      status = console.thinkingLine();
    } else {
      final text = console.statusText;
      final plan = repl.session.plan;
      final planText = plan.isEmpty
          ? ''
          : ' · plan ${plan.where((item) => item.done).length}/${plan.length}';
      status = text == null
          ? _s('  ready$planText', dim: true)
          : _s('  $text', fg: _statusColor(console.statusKind));
    }
    var hint = baseHint;
    if (console.hint != null) hint = '$hint · ${console.hint}';
    if (queue.isNotEmpty) hint = '$hint · ${queue.length} queued';
    final hintLine = _s('  $hint', fg: _tuiYellow, dim: true);

    final frame = TuiFrame(
      width: width,
      height: height,
      header: header,
      transcript: console.transcript,
      partial: console.partial,
      inputLines: inputLines,
      cursorRow: cursor?.y ?? 0,
      cursorColumn: cursor?.x ?? 0,
      status: status,
      hint: hintLine,
      running: running,
      scrollOffset: scrollOffset,
      follow: follow,
    ).render();

    return View(
      content: frame.content,
      cursor: frame.cursor,
      windowTitle: 'Sudoer — $provider',
    );
  }

  void handleKey(TeaKey key) {
    if (closed) return;
    // KeyReader normally emits one key at a time; this is a safety net for a
    // coalesced printable run (for example a fallback paste). Split embedded
    // control bytes out before the editor sees them: a literal newline inside
    // a TextArea line would corrupt the cursor.
    if (key.code == KeyCode.rune && _hasControl(key.text)) {
      _insertRuneText(key.text);
      return;
    }
    final stroke = key.keystroke();

    if (stroke == 'ctrl+c') {
      if (running) {
        cancelRun();
      } else {
        close(natural: false);
      }
      return;
    }
    if (stroke == 'esc') {
      if (running) {
        cancelRun();
      } else if (editor.value.isNotEmpty) {
        setEditor('');
        historyIndex = -1;
        historyDraft = '';
      }
      return;
    }
    if (stroke == 'ctrl+d') {
      if (!running && editor.value.isEmpty) close();
      return;
    }

    if (stroke == 'enter' || stroke == 'ctrl+j') {
      if (running) {
        queueTurn();
      } else {
        submitEditor();
      }
      return;
    }
    if (stroke == 'shift+enter' || stroke == 'alt+enter') {
      editor = _applyKey(editor, const TeaKey(code: KeyCode.enter));
      return;
    }
    if (stroke == 'pgup') {
      scrollBy(-_transcriptHeight);
      return;
    }
    if (stroke == 'pgdown') {
      scrollBy(_transcriptHeight);
      return;
    }
    if (stroke == 'up' || stroke == 'down') {
      final sized = _sizedEditor;
      if (stroke == 'up' &&
          sized.cursorVisualRow == 0 &&
          sized.cursorRow == 0) {
        recall(-1);
        return;
      }
      if (stroke == 'down' &&
          sized.cursorVisualRow >= sized.visualLineCount - 1) {
        recall(1);
        return;
      }
    }

    editor = _applyKey(editor, key);
  }

  void handlePaste(String content) {
    if (closed) return;
    final normalized =
        content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final segments = normalized.split('\n');
    for (var i = 0; i < segments.length; i++) {
      if (segments[i].isNotEmpty) {
        editor = _applyKey(
          editor,
          TeaKey(code: KeyCode.rune, text: segments[i]),
        );
      }
      if (i != segments.length - 1) {
        editor = _applyKey(editor, const TeaKey(code: KeyCode.enter));
      }
    }
  }

  TextAreaModel _applyKey(TextAreaModel value, TeaKey key) {
    final (next, _) = value.update(KeyPressMsg(key));
    return next as TextAreaModel;
  }

  static bool _hasControl(String text) {
    for (final code in text.codeUnits) {
      if (code < 0x20 || code == 0x7f) return true;
    }
    return false;
  }

  /// Insert a coalesced printable run. dart_tui's parser can put up to four
  /// bytes in one rune key, so control bytes (Enter, Backspace, an escape
  /// sequence typed immediately after text) can arrive inside [text]. Split
  /// them back out instead of inserting literal control characters.
  void _insertRuneText(String text) {
    final buffer = StringBuffer();
    void flushText() {
      if (buffer.isEmpty) return;
      editor = _applyKey(
        editor,
        TeaKey(code: KeyCode.rune, text: buffer.toString()),
      );
      buffer.clear();
    }

    for (var i = 0; i < text.length; i++) {
      final code = text.codeUnitAt(i);
      if (code == 0x1b) {
        flushText();
        final consumed = _handleEscapeSequence(text.substring(i));
        if (consumed > 0) {
          i += consumed - 1;
        } else {
          handleKey(const TeaKey(code: KeyCode.escape));
        }
        continue;
      }
      if (code == 0x0d || code == 0x0a) {
        flushText();
        handleKey(const TeaKey(code: KeyCode.enter));
        continue;
      }
      if (code == 0x7f || code == 0x08) {
        flushText();
        editor = _applyKey(editor, const TeaKey(code: KeyCode.backspace));
        continue;
      }
      if (code == 0x09) {
        flushText();
        editor = _applyKey(editor, const TeaKey(code: KeyCode.tab));
        continue;
      }
      if (code < 0x20) {
        // Other C0 controls carry no meaning in the editor.
        flushText();
        continue;
      }
      buffer.writeCharCode(code);
    }
    flushText();
  }

  /// Handle an escape sequence that arrived inside a coalesced rune key.
  /// Returns the number of code units consumed, or 0 for a lone ESC.
  int _handleEscapeSequence(String text) {
    if (text.length >= 3 && text.startsWith('\x1b[')) {
      final key = switch (text[2]) {
        'A' => const TeaKey(code: KeyCode.up),
        'B' => const TeaKey(code: KeyCode.down),
        'C' => const TeaKey(code: KeyCode.right),
        'D' => const TeaKey(code: KeyCode.left),
        'H' => const TeaKey(code: KeyCode.home),
        'F' => const TeaKey(code: KeyCode.end),
        'Z' => const TeaKey(code: KeyCode.tab, modifiers: {KeyMod.shift}),
        _ => null,
      };
      if (key != null) {
        handleKey(key);
        return 3;
      }
      if (text.length >= 4 &&
          text[2].codeUnitAt(0) >= 0x31 &&
          text[2].codeUnitAt(0) <= 0x39 &&
          text[3] == '~') {
        final key = switch (text[2]) {
          '1' || '7' => const TeaKey(code: KeyCode.home),
          '3' => const TeaKey(code: KeyCode.delete),
          '4' || '8' => const TeaKey(code: KeyCode.end),
          '5' => const TeaKey(code: KeyCode.pageUp),
          '6' => const TeaKey(code: KeyCode.pageDown),
          _ => null,
        };
        if (key != null) {
          handleKey(key);
          return 4;
        }
      }
    }
    if (text.length >= 2) {
      if (text[1] == '\r' || text[1] == '\n') {
        handleKey(
            const TeaKey(code: KeyCode.enter, modifiers: {KeyMod.shift}));
        return 2;
      }
      final key = switch (text[1]) {
        'b' => const TeaKey(code: KeyCode.left, modifiers: {KeyMod.alt}),
        'f' => const TeaKey(code: KeyCode.right, modifiers: {KeyMod.alt}),
        '\x7f' =>
          const TeaKey(code: KeyCode.backspace, modifiers: {KeyMod.alt}),
        _ => null,
      };
      if (key != null) {
        handleKey(key);
        return 2;
      }
    }
    return 0;
  }

  void submitEditor() {
    if (running || closed) return;
    final text = editor.value.trim();
    if (text.isEmpty) return;
    setEditor('');
    _remember(text);
    _active = _runTurn(text);
  }

  void queueTurn() {
    if (!running || closed) return;
    final text = editor.value.trim();
    if (text.isEmpty) return;
    queue.add(text);
    _remember(text);
    setEditor('');
    console.setHint('${queue.length} queued');
  }

  Future<void> _runTurn(String text) async {
    if (closed) return;
    running = true;
    cancelled = false;
    shellRunning = text.trim().startsWith('!');
    follow = true;
    scrollOffset = 0;
    try {
      console.user(text);
      final keep = await repl.submitTui(text);
      if (!keep) close();
    } on Object catch (e) {
      if (closed) return;
      // StepFailure normally becomes a blocked result inside the loop. Keep a
      // last line of defence, but never interpolate a raw transport error: it
      // can contain an Authorization header or key.
      final detail = switch (e) {
        StepFailure(:final message) => message,
        ConfigException(:final message) => message,
        GuardDeniedException(:final message) => message,
        _ => '${e.runtimeType}',
      };
      console.error('run failed: $detail');
    } finally {
      running = false;
      cancelled = false;
      shellRunning = false;
      if (!closed) {
        console.setHint(queue.isEmpty ? null : '${queue.length} queued');
        if (queue.isNotEmpty) {
          await _runTurn(queue.removeAt(0));
        }
      }
    }
  }

  void cancelRun() {
    // A direct `!` shell command is an escape hatch, not a model run; it is
    // not interruptible (C6).
    if (!running || cancelled || shellRunning) return;
    cancelled = true;
    repl.session.cancel.cancel();
    console.setHint('interrupting…');
  }

  void scrollBy(int delta) {
    final content = [
      ...console.transcript,
      if (console.partial.isNotEmpty) console.partial,
    ].join('\n');
    final rows = _transcriptHeight;
    final viewport = ViewportModel(
      content: content,
      width: width,
      height: rows,
      softWrap: true,
      fillHeight: true,
      gutterBuilder: (_) => '  ',
    );
    final maxOffset =
        (viewport.totalLines - rows).clamp(0, viewport.totalLines);
    final current =
        follow ? maxOffset : scrollOffset.clamp(0, maxOffset);
    final next = (current + delta).clamp(0, maxOffset);
    scrollOffset = next;
    follow = next >= maxOffset;
    _changed();
  }

  void recall(int direction) {
    if (history.isEmpty) return;
    if (direction < 0) {
      if (historyIndex < 0) {
        historyDraft = editor.value;
        historyIndex = history.length - 1;
      } else if (historyIndex > 0) {
        historyIndex--;
      }
      setEditor(history[historyIndex]);
      return;
    }
    if (historyIndex < 0) return;
    if (historyIndex < history.length - 1) {
      historyIndex++;
      setEditor(history[historyIndex]);
    } else {
      historyIndex = -1;
      setEditor(historyDraft);
    }
  }

  void _remember(String text) {
    if (history.isEmpty || history.last != text) {
      history.add(text);
      if (history.length > 200) history.removeAt(0);
    }
    historyIndex = -1;
    historyDraft = '';
  }

  void setEditor(String value) {
    final lines = value.split('\n');
    editor = TextAreaModel(
      value: value,
      width: editor.width,
      maxHeight: editor.maxHeight,
      minHeight: editor.minHeight,
      dynamicHeight: true,
      focused: true,
      styles: editor.styles,
      cursorRow: lines.length - 1,
      cursorCol: 1 << 30,
    );
  }

  /// Close from `/exit` or another local command (a normal, zero-ish exit).
  void close({bool natural = true}) {
    if (closed) return;
    naturalExit = natural;
    closed = true;
    if (running) repl.session.cancel.cancel();
    if (!natural) repl.exitCode = 130;
    program.send(QuitMsg());
  }

  /// Called after the program loop stops, including a terminal SIGINT that
  /// Program handled without consulting the model. Always cancel an in-flight
  /// run so cleanup can actually drain.
  void shutdown() {
    final wasClosed = closed;
    closed = true;
    if (running) repl.session.cancel.cancel();
    if (!wasClosed && !naturalExit) repl.exitCode = 130;
    program.send(QuitMsg());
  }

  static String _s(
    String text, {
    bool bold = false,
    bool dim = false,
    bool italic = false,
    RgbColor? fg,
  }) =>
      TuiFrame.style(text, bold: bold, dim: dim, italic: italic, fg: fg);

  static RgbColor _statusColor(String? kind) => switch (kind) {
        'complete' => _tuiGreen,
        'incomplete' => _tuiYellow,
        'blocked' => _tuiRed,
        _ => _tuiSlate,
      };
}
