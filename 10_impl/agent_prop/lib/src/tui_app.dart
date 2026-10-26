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
      case MouseWheelMsg(:final mouse):
        app.handleWheel(mouse.button);
      case MouseClickMsg(:final mouse):
        app.handleMouseDown(mouse);
      case MouseMotionMsg(:final mouse):
        app.handleMouseDrag(mouse);
      case MouseReleaseMsg(:final mouse):
        app.handleMouseUp(mouse);
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
  _TuiApp({required this.repl, required this.console, required this.program})
    : width = 80,
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

  /// The modal popup over the frame, if any. While set, every key and paste
  /// routes to it (C6); the editor and run queue stay untouched underneath.
  TuiPopup? popup;
  Completer<String?>? _popupCompleter;

  /// The slash-command completion menu anchored above the editor, if any.
  /// Unlike [popup] it never steals the keyboard: typing continues in the
  /// editor and merely filters it (C6, after Crush's `/` completions).
  TuiPopup? completions;
  String? _dismissedCompletionsFor;

  /// The masked one-line modal input (an API key), if any (C6). Like
  /// [popup] it owns the keyboard while open; the value never renders.
  TuiPrompt? inputPrompt;
  Completer<String?>? _inputCompleter;

  /// In-progress mouse selection over the transcript (C6): the anchor and
  /// the drag head, in frame rows and visible columns. [selection] holds the
  /// normalized span — live while dragging, kept after release until the
  /// next press (so the highlighted text stays visible to copy again).
  (int, int)? _selectionAnchor;
  (int, int)? _selectionHead;
  TuiSelection? selection;

  Future<void> _active = Future<void>.value();

  /// A command turn running beside the live turn (C6): read-only commands and
  /// pickers dispatched while output streams. Awaited at shutdown with the
  /// main turn so no callback writes into a dead frame.
  Future<void> _side = Future<void>.value();

  /// List rows a popup may show at the current terminal height.
  int get _popupRows => (height - 8).clamp(3, 40);

  /// Present [next] modally and resolve with the chosen value, or null when
  /// cancelled. A popup already open is cancelled first; the newcomer owns
  /// the keyboard from here on.
  Future<String?> showPopup(TuiPopup next) {
    final previous = _popupCompleter;
    if (previous != null) closePopup(null);
    next.maxRows = _popupRows;
    next.toTop();
    popup = next;
    _clearSelection();
    final completer = Completer<String?>();
    _popupCompleter = completer;
    _changed();
    return completer.future;
  }

  /// Resolve the open popup (if any) with [value] and hand the keyboard back.
  void closePopup(String? value) {
    final completer = _popupCompleter;
    _popupCompleter = null;
    popup = null;
    if (completer != null && !completer.isCompleted) completer.complete(value);
    _changed();
  }

  /// Present [next] as a masked one-line modal and resolve with the entered
  /// value, or null when skipped (Esc) or cancelled (Ctrl+C, shutdown).
  Future<String?> showPrompt(TuiPrompt next) {
    final previous = _inputCompleter;
    if (previous != null) closePrompt(null);
    inputPrompt = next;
    _clearSelection();
    final completer = Completer<String?>();
    _inputCompleter = completer;
    _changed();
    return completer.future;
  }

  /// Resolve the open input prompt (if any) and hand the keyboard back.
  void closePrompt(String? value) {
    final completer = _inputCompleter;
    _inputCompleter = null;
    inputPrompt = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(value);
    }
    _changed();
  }

  /// Completes when the current run (and any queued follow-up) is done.
  Future<void> get drained => Future.wait([_active, _side]);

  /// Replay a resumed session into the transcript so the TUI opens with the
  /// same conversation the session file holds.
  void _hydrate() => console.replay(repl.session.transcript);

  TextAreaModel get _sizedEditor =>
      editor.copyWith(width: (width - 6).clamp(1, width), focused: true);

  /// The queued-messages panel and the plan panel as the view draws them.
  /// Fold limits scale with the terminal so the panels can never push the
  /// editor or footer off a short frame: the queue keeps at most three rows
  /// and the plan at most five, minus what the rest of the frame needs.
  (List<String>, List<String>) get _panels {
    final inputCount = _sizedEditor.view().content.split('\n').length;
    final queueMax = (height - 11 - inputCount).clamp(1, 3);
    final queueLines = queue.isEmpty
        ? const <String>[]
        : queuePanel(queue, maxRows: queueMax, width: width);
    final planMax = (height - 10 - inputCount - queueLines.length).clamp(1, 5);
    return (
      queueLines,
      planPanel(repl.session.plan, maxRows: planMax, width: width),
    );
  }

  int get _transcriptHeight {
    final inputLines = _sizedEditor.view().content.split('\n').length;
    final (queueLines, planLines) = _panels;
    return TuiFrame.transcriptHeight(
      height: height,
      headerLines: 2 + planLines.length,
      inputLines: inputLines,
      queueLines: queueLines.length,
    );
  }

  void resize(int nextWidth, int nextHeight) {
    width = nextWidth.clamp(8, 500);
    height = nextHeight.clamp(6, 300);
    editor = editor.copyWith(width: (width - 6).clamp(1, width));
    console.width = (width - 2).clamp(20, 500);
    popup?.maxRows = _popupRows;
    _changed();
  }

  void _changed() {
    if (!closed) program.send(const _TuiRedraw());
  }

  View view() {
    final provider = repl.config.provider.display;
    final sessionId = repl.session.id;
    final shortId = sessionId.length > 14
        ? '${sessionId.substring(0, 12)}…'
        : sessionId;
    final shortWorkspace = shortPath(
      repl.workspaceRoot,
      (width - 38).clamp(8, width),
    );
    final entries = repl.session.transcript.length;
    final (queueLines, planLines) = _panels;
    final header = [
      '${_s('  Sudoer $kBuildLabel', bold: true, fg: _tuiSky)}'
          '${_s('  ·  ', dim: true)}${_s(provider, fg: _tuiMauve)}',
      _s(
        '  workspace $shortWorkspace  ·  session $shortId  ·  '
        '$entries entries',
        dim: true,
      ),
      ...planLines,
    ];

    final editorView = _sizedEditor.view();
    final inputLines = editorView.content.split('\n');
    final cursor = editorView.cursor;

    String status;
    final baseHint = running
        ? (shellRunning
              ? 'running command · PgUp/PgDn scroll · Enter queues a message'
              : 'Esc cancel · PgUp/PgDn scroll · Enter queues a message')
        : 'Enter send · Shift+Enter newline · Ctrl+P commands · Ctrl+L models · Ctrl+C quit';
    if (running) {
      status = console.thinkingLine();
    } else {
      final text = console.statusText;
      status = text == null
          ? _s('  ready', dim: true)
          : _s('  $text', fg: _statusColor(console.statusKind));
    }
    var hint = baseHint;
    if (console.hint != null) hint = '$hint · ${console.hint}';
    if (queue.isNotEmpty) hint = '$hint · ${queue.length} queued';
    final activePopup = popup;
    final activeCompletions = completions;
    final activePrompt = inputPrompt;
    final String hintLine;
    if (activePrompt != null) {
      hintLine = _s('  ${activePrompt.footerHint}', fg: _tuiYellow, dim: true);
    } else if (activePopup != null) {
      hintLine = _s('  ${activePopup.footerHint}', fg: _tuiYellow, dim: true);
    } else if (activeCompletions != null) {
      hintLine = _s(
        '  ↑↓ select · Tab complete · Enter send · Esc close',
        fg: _tuiYellow,
        dim: true,
      );
    } else {
      hintLine = _s('  $hint', fg: _tuiYellow, dim: true);
    }

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
      queueLines: queueLines,
    ).render();
    _frameLines = frame.content.split('\n');
    var frameContent = frame.content;
    final activeSelection = selection;
    if (activeSelection != null) {
      frameContent = applySelectionSpans(_frameLines, activeSelection).join(
        '\n',
      );
    }
    const mouseMode = MouseMode.cellMotion;

    if (activePrompt != null) {
      // The masked input is the interaction surface while open (C6): draw
      // it over everything and move the cursor after the masked value.
      final overlaid = activePrompt.overlay(
        frameContent,
        width: width,
        height: height,
      );
      return View(
        content: overlaid.content,
        cursor: overlaid.cursor,
        windowTitle: 'Sudoer — $provider',
        mouseMode: mouseMode,
      );
    }

    if (activePopup != null || activeCompletions != null) {
      // The popup or the completion menu is the interaction surface while
      // open: draw it over the frame (C6). A modal popup also moves the
      // cursor into its filter line; the completion menu leaves the editor's
      // caret alone because typing continues below it.
      var content = frameContent;
      if (activeCompletions != null) {
        content = activeCompletions.overlayAnchored(
          content,
          width: width,
          height: height,
          // The row just above the editor's top border: header (3 rows) plus
          // the transcript viewport, minus one.
          bottomRow: 2 + _transcriptHeight,
        );
      }
      if (activePopup != null) {
        final overlaid = activePopup.overlay(
          content,
          width: width,
          height: height,
        );
        return View(
          content: overlaid.content,
          cursor: overlaid.cursor,
          windowTitle: 'Sudoer — $provider',
          mouseMode: mouseMode,
        );
      }
      return View(
        content: content,
        cursor: frame.cursor,
        windowTitle: 'Sudoer — $provider',
        mouseMode: mouseMode,
      );
    }

    return View(
      content: frameContent,
      cursor: frame.cursor,
      windowTitle: 'Sudoer — $provider',
      mouseMode: mouseMode,
    );
  }

  void handleKey(TeaKey key) {
    if (closed) return;
    final prompt = inputPrompt;
    if (prompt != null) {
      if (key.code == KeyCode.rune && _hasControl(key.text)) {
        _insertRuneText(key.text);
      } else {
        _handlePromptKey(prompt, key);
      }
      return;
    }
    final activePopup = popup;
    if (activePopup != null) {
      if (key.code == KeyCode.rune && _hasControl(key.text)) {
        _insertRuneText(key.text);
      } else {
        _handlePopupKey(activePopup, key);
      }
      return;
    }
    // KeyReader normally emits one key at a time; this is a safety net for a
    // coalesced printable run (for example a fallback paste). Split embedded
    // control bytes out before the editor sees them: a literal newline inside
    // a TextArea line would corrupt the cursor.
    if (key.code == KeyCode.rune && _hasControl(key.text)) {
      _insertRuneText(key.text);
      _syncCompletions();
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
    // Crush-style global shortcuts (C6): the pickers and the palette. They
    // are idle-surface gestures; while a run is in flight the keys keep
    // their editor meaning.
    if (!running) {
      switch (stroke) {
        case 'ctrl+g':
          _runShortcut('/help');
          return;
        case 'ctrl+l':
          _runShortcut('/model');
          return;
        case 'ctrl+s':
          _runShortcut('/sessions');
          return;
        case 'ctrl+n':
          _runShortcut('/new');
          return;
        case 'ctrl+p':
          _openPalette();
          return;
      }
    }
    if (stroke == 'esc') {
      if (running) {
        cancelRun();
      } else if (completions != null) {
        // First Esc dismisses the completion menu, not the draft.
        _dismissedCompletionsFor = editor.value;
        _syncCompletions();
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
        _submitDuringRun();
      } else {
        final menu = completions;
        if (menu != null && menu.visible.isNotEmpty) {
          final choice = menu.confirm();
          // Complete-then-send (after Crush): Enter on a different row fills
          // the command in; Enter on the exact text sends it.
          if (choice != null && choice != editor.value) {
            setEditor(choice);
            _syncCompletions();
          } else {
            submitEditor();
          }
        } else {
          submitEditor();
        }
      }
      _syncCompletions();
      return;
    }
    if (stroke == 'shift+enter' || stroke == 'alt+enter') {
      editor = _applyKey(editor, const TeaKey(code: KeyCode.enter));
      _syncCompletions();
      return;
    }
    if (stroke == 'tab') {
      final menu = completions;
      final choice = menu?.confirm();
      if (menu != null && choice != null && choice != editor.value) {
        setEditor(choice);
      }
      _syncCompletions();
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
      final menu = completions;
      if (menu != null && menu.visible.isNotEmpty) {
        menu.move(stroke == 'up' ? -1 : 1);
        _changed();
        return;
      }
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
    _syncCompletions();
  }

  /// Mouse wheel (C6): the wheel scrolls the surface that owns the pointer —
  /// an open popup's list when one is up, otherwise the transcript. It never
  /// targets the editor, so the wheel cannot walk input history by accident.
  void handleWheel(MouseButton button) {
    if (closed) return;
    final delta = switch (button) {
      MouseButton.wheelUp || MouseButton.wheelLeft => -3,
      MouseButton.wheelDown || MouseButton.wheelRight => 3,
      _ => 0,
    };
    if (delta == 0) return;
    final activePopup = popup;
    if (activePopup != null) {
      activePopup.move(delta);
      _changed();
      return;
    }
    scrollBy(delta);
  }

  /// The frame rows the transcript occupies: the first row and the count.
  (int, int) get _transcriptRegion {
    final headerLines = 2 + _panels.$2.length;
    return (headerLines + 1, _transcriptHeight);
  }

  /// Left press (C6): begin a selection in the transcript region. A press
  /// elsewhere — or with a modal up — clears any selection instead.
  void handleMouseDown(Mouse mouse) {
    if (closed || inputPrompt != null || popup != null || completions != null) {
      return;
    }
    final (first, count) = _transcriptRegion;
    final row = mouse.y;
    if (row < first || row >= first + count) {
      _clearSelection();
      _changed();
      return;
    }
    _selectionAnchor = (row, mouse.x);
    _selectionHead = (row, mouse.x);
    selection = null;
    _changed();
  }

  /// Drag with the button down (C6): extend the selection head, clamped to
  /// the transcript rows, so the highlight tracks the pointer live.
  void handleMouseDrag(Mouse mouse) {
    if (_selectionAnchor == null || closed) return;
    _selectionHead = _clampToTranscript(mouse);
    selection = _normalizedSelection();
    _changed();
  }

  /// Release (C6): commit the span and copy its text to the clipboard via
  /// OSC 52. An empty span (a plain click) just clears the highlight.
  void handleMouseUp(Mouse mouse) {
    if (_selectionAnchor == null || closed) return;
    _selectionHead = _clampToTranscript(mouse);
    selection = _normalizedSelection();
    _selectionAnchor = null;
    _selectionHead = null;
    final text = selection == null
        ? ''
        : extractSelection(_frameLines, selection!);
    if (text.isNotEmpty) _copyToClipboard(text);
    _changed();
  }

  (int, int) _clampToTranscript(Mouse mouse) {
    final (first, count) = _transcriptRegion;
    return (
      mouse.y.clamp(first, first + count - 1),
      mouse.x.clamp(0, width - 1),
    );
  }

  TuiSelection? _normalizedSelection() {
    final anchor = _selectionAnchor;
    final head = _selectionHead;
    if (anchor == null || head == null) return null;
    final anchorFirst = anchor.$1 < head.$1 ||
        (anchor.$1 == head.$1 && anchor.$2 <= head.$2);
    final (start, end) = anchorFirst ? (anchor, head) : (head, anchor);
    return TuiSelection(
      startRow: start.$1,
      startCol: start.$2,
      endRow: end.$1,
      endCol: end.$2,
    );
  }

  void _clearSelection() {
    _selectionAnchor = null;
    _selectionHead = null;
    selection = null;
  }

  /// The current frame's content lines, refreshed on every render; selection
  /// extraction reads the same lines the user sees.
  List<String> _frameLines = const [];

  /// OSC 52: hand the selected text to the host clipboard through the
  /// terminal, the one clipboard channel a raw-mode TUI always has.
  void _copyToClipboard(String text) {
    final encoded = base64.encode(utf8.encode(text));
    stdout.write('\x1b]52;c;$encoded\x07');
  }

  void handlePaste(String content) {
    if (closed) return;
    final normalized = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final prompt = inputPrompt;
    if (prompt != null) {
      // A paste into the key prompt edits the value (newlines flatten);
      // it still renders masked.
      prompt.type(normalized.replaceAll('\n', ' '));
      _changed();
      return;
    }
    final activePopup = popup;
    if (activePopup != null) {
      // A paste into an open popup feeds the filter (newlines become
      // spaces); the editor below is untouched.
      activePopup.type(normalized.replaceAll('\n', ' '));
      _changed();
      return;
    }
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

  /// Keys for the open input prompt (C6): typing edits the masked value,
  /// Enter confirms it, Esc (or Ctrl+C) skips. Everything else is swallowed
  /// so neither the editor nor a popup beneath sees a keystroke.
  void _handlePromptKey(TuiPrompt prompt, TeaKey key) {
    final stroke = key.keystroke();
    switch (stroke) {
      case 'esc':
      case 'ctrl+c':
        closePrompt(null);
        return;
      case 'enter':
      case 'ctrl+j':
        closePrompt(prompt.value);
        return;
      case 'backspace':
        prompt.backspace();
      case 'space':
        prompt.type(' ');
      default:
        if (key.code == KeyCode.rune &&
            key.text.isNotEmpty &&
            !_hasControl(key.text)) {
          prompt.type(key.text);
        } else {
          return; // unmapped key: nothing changed, no redraw needed
        }
    }
    _changed();
  }

  /// Keys for the open popup (C6): movement and filtering here, Enter
  /// confirms, Esc (or Ctrl+C) cancels. Everything else is swallowed so the
  /// editor never sees a keystroke while a modal is up.
  void _handlePopupKey(TuiPopup activePopup, TeaKey key) {
    final stroke = key.keystroke();
    switch (stroke) {
      case 'esc':
      case 'ctrl+c':
        closePopup(null);
        return;
      case 'enter':
      case 'ctrl+j':
        closePopup(activePopup.confirm());
        return;
      case 'up':
        activePopup.move(-1);
      case 'down':
        activePopup.move(1);
      case 'pgup':
        activePopup.page(-1);
      case 'pgdown':
        activePopup.page(1);
      case 'home':
        activePopup.toTop();
      case 'end':
        activePopup.toBottom();
      case 'backspace':
        activePopup.backspace();
      case 'space':
        activePopup.type(' ');
      default:
        if (key.code == KeyCode.rune &&
            key.text.isNotEmpty &&
            !_hasControl(key.text)) {
          activePopup.type(key.text);
        } else {
          return; // unmapped key: nothing changed, no redraw needed
        }
    }
    _changed();
  }

  /// Type printable runes into whichever surface owns the keyboard: the open
  /// popup's filter, or the editor.
  /// Type printable runes into whichever surface owns the keyboard: the
  /// masked input prompt, the open popup's filter, or the editor.
  void _typeRunes(String text) {
    if (text.isEmpty) return;
    final prompt = inputPrompt;
    if (prompt != null) {
      prompt.type(text);
      return;
    }
    final activePopup = popup;
    if (activePopup != null) {
      activePopup.type(text);
      return;
    }
    editor = _applyKey(editor, TeaKey(code: KeyCode.rune, text: text));
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
      _typeRunes(buffer.toString());
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
        handleKey(const TeaKey(code: KeyCode.backspace));
        continue;
      }
      if (code == 0x09) {
        flushText();
        handleKey(const TeaKey(code: KeyCode.tab));
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
        handleKey(const TeaKey(code: KeyCode.enter, modifiers: {KeyMod.shift}));
        return 2;
      }
      final key = switch (text[1]) {
        'b' => const TeaKey(code: KeyCode.left, modifiers: {KeyMod.alt}),
        'f' => const TeaKey(code: KeyCode.right, modifiers: {KeyMod.alt}),
        '\x7f' => const TeaKey(
          code: KeyCode.backspace,
          modifiers: {KeyMod.alt},
        ),
        _ => null,
      };
      if (key != null) {
        handleKey(key);
        return 2;
      }
    }
    return 0;
  }

  /// The `/` commands with descriptions, shared by the completion menu and
  /// the ctrl+p palette (C6).
  List<TuiPopupItem>? _commandItems;
  List<TuiPopupItem> get _commands => _commandItems ??= [
    for (final (command, description) in replCommandCatalog(
      interactive: repl.interactive,
      tui: repl.tui,
    ))
      TuiPopupItem(value: command, label: command, detail: description),
  ];

  /// Refresh the slash-completion menu against the editor text. Shown only
  /// for a single-line, space-free `/` prefix that has at least one match;
  /// [TuiPopup.matchLabelPrefix] keeps descriptions out of the match.
  void _syncCompletions() {
    final text = editor.value;
    final eligible =
        !running &&
        !closed &&
        text.startsWith('/') &&
        !text.contains('\n') &&
        !text.contains(' ') &&
        text != _dismissedCompletionsFor;
    if (!eligible) {
      if (completions != null) {
        completions = null;
        _changed();
      }
      return;
    }
    final menu = completions ??= TuiPopup(
      title: 'Commands',
      items: _commands,
      matchLabelPrefix: true,
    );
    if (menu.query != text) {
      menu.query = text;
      menu.cursor = 0;
      menu.scroll = 0;
    }
    if (menu.visible.isEmpty) {
      completions = null;
    }
    _changed();
  }

  /// Run a shortcut's command line as if it were typed and submitted —
  /// echoed into the transcript, but not kept in input history (C6).
  void _runShortcut(String line) {
    if (running || closed) return;
    completions = null;
    setEditor('');
    _active = _runTurn(line);
  }

  /// The ctrl+p command palette: every command in one filterable popup;
  /// Enter runs the chosen one (C6, after Crush's palette).
  Future<void> _openPalette() async {
    if (running || closed) return;
    completions = null;
    final picked = await showPopup(
      TuiPopup(title: 'Commands', items: _commands),
    );
    if (picked != null && !closed) _runShortcut(picked);
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

  /// C6: a line submitted while a turn streams. Output must never block
  /// input: read-only commands and the live-safe provider/model switches run
  /// at once (a switch retires the old transport when the stream ends), the
  /// session picker queues its resume, and everything else queues as before.
  void _submitDuringRun() {
    final text = editor.value.trim();
    if (text.isEmpty) return;
    final immediate = repl.runsImmediately(text);
    if (immediate || repl.isTuiModal(text)) {
      setEditor('');
      _remember(text);
      console.user(text);
      _side = _runSideTurn(text, deferApply: !immediate);
      return;
    }
    queueTurn();
  }

  /// Run one line concurrently with the streaming turn (C6): never touches
  /// `running` or the queue, which belong to the live run. With
  /// [deferApply], a picker's switch is queued instead of applied.
  Future<void> _runSideTurn(String text, {bool deferApply = false}) async {
    if (closed) return;
    repl.deferCommand = deferApply ? queueCommand : null;
    try {
      final keep = await repl.submitTui(text, deferApply: deferApply);
      if (!keep) close();
    } on Object catch (e) {
      // Never interpolate a raw transport error: it can carry a key.
      final detail = switch (e) {
        StepFailure(:final message) => message,
        ConfigException(:final message) => message,
        GuardDeniedException(:final message) => message,
        _ => '${e.runtimeType}',
      };
      console.error('run failed: $detail');
    } finally {
      repl.deferCommand = null;
    }
  }

  /// Queue a command line for the end of the live turn (C6): the deferred
  /// half of a picker opened while a run streamed.
  void queueCommand(String line) {
    if (closed) return;
    queue.add(line);
    console.setHint('${queue.length} queued');
  }

  Future<void> _runTurn(String text) async {
    if (closed) return;
    // A popup command is a modal interaction, not a model run: the app stays
    // idle (no cancel hint, no running border) while the popup is up.
    running = !repl.isTuiModal(text);
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
    final wrapped = TuiFrame.transcriptContent(
      console.transcript,
      console.partial,
      (width - 2).clamp(1, width),
    ).split('\n');
    final rows = _transcriptHeight;
    final maxOffset = (wrapped.length - rows).clamp(0, wrapped.length);
    final current = follow ? maxOffset : scrollOffset.clamp(0, maxOffset);
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
    _syncCompletions();
  }

  /// Close from `/exit` or another local command (a normal, zero-ish exit).
  void close({bool natural = true}) {
    if (closed) return;
    naturalExit = natural;
    closed = true;
    closePrompt(null);
    closePopup(null);
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
    closePrompt(null);
    closePopup(null);
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
  }) => TuiFrame.style(text, bold: bold, dim: dim, italic: italic, fg: fg);

  static RgbColor _statusColor(String? kind) => switch (kind) {
    'complete' => _tuiGreen,
    'incomplete' => _tuiYellow,
    'blocked' => _tuiRed,
    _ => _tuiSlate,
  };
}
