/// C6: raw-terminal line editing for the interactive human surface.
///
/// [KeyReader] decodes a raw byte stream into [Key] events, resolving the
/// ambiguous lone `ESC` against an escape sequence with a short timeout.
/// [LineEditor] turns those keys into an editable buffer with history, a
/// free cursor, and multi-line input (a trailing `\` continues the line).
/// Cursor placement measures text in terminal cells — a wide rune (CJK,
/// emoji) counts two columns, a combining mark none — so the cursor lands
/// after the last typed character even under an IME.
///
/// Pasted text is distinguished from typed input: with bracketed paste mode
/// active the terminal wraps a paste in `ESC[200~` … `ESC[201~`, delivered as
/// one [KeyKind.paste] carrying the whole text, so embedded newlines edit the
/// buffer instead of submitting it. Without the markers, a newline followed
/// by printable text in the same read is treated as a paste break too.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

enum KeyKind {
  rune,
  enter,
  newline,
  paste,
  backspace,
  delete,
  left,
  right,
  up,
  down,
  home,
  end,
  esc,
  ctrlC,
  ctrlD,
  tab,
  other,
}

final class Key {
  const Key(this.kind, [this.rune = 0, this.text = '']);
  final KeyKind kind;
  final int rune;

  /// Paste payload, set only when [kind] is [KeyKind.paste]: the decoded,
  /// newline-normalized text inserted in one edit. Delivered as one event so
  /// a large paste redraws once instead of once per character.
  final String text;

  @override
  String toString() => kind == KeyKind.rune
      ? 'rune(${String.fromCharCode(rune)})'
      : kind == KeyKind.paste
          ? 'paste(${text.length})'
          : kind.name;
}

/// Decodes {@code input} into key events on [keys]. One background
/// subscription feeds the buffer; a lone `ESC` is emitted only after
/// [escTimeout] passes without a following byte, so arrow sequences (which
/// begin with `ESC [`) are read whole.
final class KeyReader {
  KeyReader(
    Stream<List<int>> input, {
    this.escTimeout = const Duration(milliseconds: 40),
  }) {
    _subscription = input.listen(
      _onData,
      onDone: _onDone,
      onError: _controller.addError,
    );
  }

  final Duration escTimeout;
  final StreamController<Key> _controller =
      StreamController<Key>.broadcast();
  late final StreamSubscription<List<int>> _subscription;
  final List<int> _buffer = [];
  Timer? _escTimer;
  bool _pasting = false;

  /// Bracketed paste delimiters (DECSET 2004): `ESC [ 2 0 0 ~` opens a paste,
  /// `ESC [ 2 0 1 ~` closes it.
  static const List<int> _pasteStart = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e];
  static const List<int> _pasteEnd = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e];

  Stream<Key> get keys => _controller.stream;

  Future<void> close() async {
    _escTimer?.cancel();
    await _subscription.cancel();
    if (!_controller.isClosed) await _controller.close();
  }

  void _onData(List<int> data) {
    _buffer.addAll(data);
    _drain();
  }

  void _onDone() {
    _escTimer?.cancel();
    _escTimer = null;
    // A paste that never saw its terminator still delivers what arrived.
    if (_pasting && _buffer.isNotEmpty) {
      final key = _takePaste(atEnd: true);
      if (key != null) _controller.add(key);
    }
    // Flush a lone ESC waiting on its timeout: at end-of-input it is an ESC.
    if (_buffer.length == 1 && _buffer.first == 27) {
      _buffer.removeAt(0);
      _controller.add(const Key(KeyKind.esc));
    }
    _drain();
    if (!_controller.isClosed) _controller.close();
  }

  void _drain() {
    _escTimer?.cancel();
    _escTimer = null;
    while (true) {
      final key = _take();
      if (key == null) break;
      _controller.add(key);
    }
    if (_buffer.length == 1 && _buffer.first == 27) {
      _escTimer = Timer(escTimeout, () {
        _escTimer = null;
        if (_buffer.length == 1 && _buffer.first == 27) {
          _buffer.removeAt(0);
          _controller.add(const Key(KeyKind.esc));
        }
      });
    }
  }

  Key? _take() {
    if (_buffer.isEmpty) return null;
    if (_pasting) return _takePaste();
    final first = _buffer.first;
    if (first == 27) {
      if (_buffer.length == 1) return null;
      if (_buffer[1] == 0x5B) {
        if (_startsWith(_pasteStart)) {
          _buffer.removeRange(0, _pasteStart.length);
          _pasting = true;
          return _take();
        }
        return _takeCsi();
      }
      // Alt+<byte>: report ESC and leave the byte for the next pass.
      _buffer.removeAt(0);
      return const Key(KeyKind.esc);
    }
    return _takePlain();
  }

  /// Emit the whole bracketed paste (everything up to `ESC[201~`) as one
  /// [KeyKind.paste], so a large paste is one edit and one redraw. Returns
  /// null while the terminator has not arrived yet; [atEnd] flushes whatever
  /// is buffered when the input stream closes.
  Key? _takePaste({bool atEnd = false}) {
    final end = _indexOf(_pasteEnd, 0);
    if (end < 0 && !atEnd) return null;
    final content = end < 0 ? _buffer.sublist(0) : _buffer.sublist(0, end);
    _buffer.removeRange(0, end < 0 ? _buffer.length : end + _pasteEnd.length);
    _pasting = false;
    return Key(KeyKind.paste, 0, _decodePaste(content));
  }

  int _indexOf(List<int> sequence, int from) {
    for (var i = from; i <= _buffer.length - sequence.length; i++) {
      var match = true;
      for (var j = 0; j < sequence.length; j++) {
        if (_buffer[i + j] != sequence[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }

  /// Decode pasted UTF-8, normalizing `CR`/`CRLF` to `LF` and dropping other
  /// control bytes so a pasted escape sequence cannot hijack the editor. Only
  /// single-byte controls are removed, so multi-byte runes stay intact.
  static String _decodePaste(List<int> bytes) {
    final kept = <int>[];
    for (var i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      if (b == 13) {
        if (i + 1 < bytes.length && bytes[i + 1] == 10) i++;
        kept.add(10);
      } else if (b == 10 || b == 9) {
        kept.add(b);
      } else if (b >= 0x20 && b != 0x7f) {
        kept.add(b);
      }
    }
    return utf8.decode(kept, allowMalformed: true);
  }

  bool _startsWith(List<int> sequence) {
    if (_buffer.length < sequence.length) return false;
    for (var i = 0; i < sequence.length; i++) {
      if (_buffer[i] != sequence[i]) return false;
    }
    return true;
  }

  Key? _takeCsi() {
    if (_buffer.length < 3) return null;
    final third = _buffer[2];
    switch (third) {
      case 0x41:
        return _consume(3, const Key(KeyKind.up));
      case 0x42:
        return _consume(3, const Key(KeyKind.down));
      case 0x43:
        return _consume(3, const Key(KeyKind.right));
      case 0x44:
        return _consume(3, const Key(KeyKind.left));
      case 0x48:
        return _consume(3, const Key(KeyKind.home));
      case 0x46:
        return _consume(3, const Key(KeyKind.end));
    }
    final tilde = _buffer.indexOf(0x7E, 2);
    if (tilde >= 0) {
      final param = String.fromCharCodes(_buffer.sublist(2, tilde));
      final key = switch (param) {
        '1' || '7' => const Key(KeyKind.home),
        '3' => const Key(KeyKind.delete),
        '4' || '8' => const Key(KeyKind.end),
        _ => const Key(KeyKind.other),
      };
      return _consume(tilde + 1, key);
    }
    // Generic CSI: consume through the first final byte (0x40..0x7E), if any.
    for (var i = 2; i < _buffer.length; i++) {
      if (_buffer[i] >= 0x40 && _buffer[i] <= 0x7E) {
        return _consume(i + 1, const Key(KeyKind.other));
      }
    }
    return null;
  }

  Key? _takePlain() {
    final b = _buffer.first;
    switch (b) {
      case 13 || 10:
        return _takeNewline(b);
      case 127 || 8:
        return _consume(1, const Key(KeyKind.backspace));
      case 9:
        return _consume(1, const Key(KeyKind.tab));
      case 3:
        return _consume(1, const Key(KeyKind.ctrlC));
      case 4:
        return _consume(1, const Key(KeyKind.ctrlD));
    }
    if (b < 0x20) return _consume(1, const Key(KeyKind.other));
    if (b < 0x80) return _consume(1, Key(KeyKind.rune, b));
    final length = _utf8Length(b);
    if (length == null) return _consume(1, const Key(KeyKind.other));
    if (_buffer.length < length) return null;
    try {
      final text = utf8.decode(_buffer.sublist(0, length));
      _buffer.removeRange(0, length);
      if (text.runes.isEmpty) return const Key(KeyKind.other);
      return Key(KeyKind.rune, text.runes.first);
    } on FormatException {
      return _consume(1, const Key(KeyKind.other));
    }
  }

  /// A newline breaks the line when it is pasted text and submits when it is
  /// the typed Enter gesture (the marker-less fallback; bracketed pastes go
  /// through [_takePaste]). A newline is a paste break when printable text
  /// follows it in the same read; a real Enter is a lone byte. `CR LF` counts
  /// as one break.
  Key? _takeNewline(int b) {
    final crlf = b == 13 && _buffer.length > 1 && _buffer[1] == 10;
    final width = crlf ? 2 : 1;
    final next = _buffer.length > width ? _buffer[width] : 0;
    if (next >= 0x20 && next != 0x7f) {
      return _consume(width, const Key(KeyKind.newline));
    }
    return _consume(width, const Key(KeyKind.enter));
  }

  int? _utf8Length(int b) {
    if (b >= 0xF0) return 4;
    if (b >= 0xE0) return 3;
    if (b >= 0xC0) return 2;
    return null;
  }

  Key _consume(int count, Key key) {
    _buffer.removeRange(0, count);
    return key;
  }
}

/// Recognizes two `Esc` presses within [window], the interrupt gesture. Time
/// is injectable so the gesture is deterministic under test.
final class DoubleEsc {
  DoubleEsc({this.window = const Duration(milliseconds: 700)});

  final Duration window;
  DateTime? _first;

  /// Record an `Esc` press and report whether it completed a double `Esc`.
  bool press([DateTime? now]) {
    final at = now ?? DateTime.now();
    final first = _first;
    if (first != null && at.difference(first) < window) {
      _first = null;
      return true;
    }
    _first = at;
    return false;
  }

  void reset() => _first = null;
}

enum EditKind { pending, submit, eof }

final class EditResult {
  const EditResult.pending()
      : kind = EditKind.pending,
        text = '';
  const EditResult.submit(this.text) : kind = EditKind.submit;
  const EditResult.eof()
      : kind = EditKind.eof,
        text = '';

  final EditKind kind;
  final String text;
}

/// Terminal cell width of [rune]: 2 for East Asian wide and fullwidth runes
/// (Hangul, kana, CJK ideographs, fullwidth forms) and emoji, 0 for combining
/// marks and zero-width controls, 1 otherwise. A compiled-in approximation of
/// East Asian Width, not a full Unicode mapping (ZWJ emoji sequences still
/// count one cell per base rune).
int runeWidth(int rune) =>
    _inRanges(rune, _zeroWidth) ? 0 : _inRanges(rune, _wide) ? 2 : 1;

/// Total terminal cell width of [runes]. An emoji variation selector after a
/// narrow base counts one extra cell: the cluster renders as a wide emoji.
int runesWidth(Iterable<int> runes) {
  var width = 0;
  var narrow = false;
  for (final rune in runes) {
    if (rune == 0xFE0F) {
      if (narrow) width++;
      narrow = false;
      continue;
    }
    final cell = runeWidth(rune);
    width += cell;
    narrow = cell == 1;
  }
  return width;
}

/// Sorted, non-overlapping inclusive code-point ranges marked zero-width in
/// the combining tables (diacritics, script marks, variation selectors).
const List<(int, int)> _zeroWidth = [
  (0x0300, 0x036F), // combining diacritical marks
  (0x0483, 0x0489), // combining Cyrillic
  (0x0591, 0x05BD), // Hebrew accents
  (0x05BF, 0x05BF),
  (0x05C1, 0x05C2),
  (0x05C4, 0x05C5),
  (0x05C7, 0x05C7),
  (0x0610, 0x061A), // Arabic honorifics
  (0x064B, 0x065F), // Arabic vowels
  (0x0670, 0x0670),
  (0x06D6, 0x06DC),
  (0x06DF, 0x06E4),
  (0x06E7, 0x06E8),
  (0x06EA, 0x06ED),
  (0x0711, 0x0711), // Syriac combining marks
  (0x0730, 0x074A),
  (0x07A6, 0x07B0), // Thaana marks
  (0x07EB, 0x07F3), // Nko marks
  (0x0816, 0x0819), // Samaritan marks
  (0x081B, 0x0823),
  (0x0825, 0x0827),
  (0x0829, 0x082D),
  (0x0859, 0x085B), // Mandaic marks
  (0x08E3, 0x0902), // combining and Devanagari signs
  (0x093A, 0x093A),
  (0x093C, 0x093C),
  (0x0941, 0x0948),
  (0x094D, 0x094D),
  (0x0951, 0x0957),
  (0x0962, 0x0963),
  (0x0981, 0x0981), // Bengali signs
  (0x09BC, 0x09BC),
  (0x09C1, 0x09C4),
  (0x09CD, 0x09CD),
  (0x09E2, 0x09E3),
  (0x1AB0, 0x1AFF), // combining diacritical marks extended
  (0x1DC0, 0x1DFF), // combining diacritical marks supplement
  (0x200B, 0x200F), // zero-width space, joiners, marks
  (0x20D0, 0x20F0), // combining marks for symbols
  (0xFE00, 0xFE0F), // variation selectors
  (0xFE20, 0xFE2F), // combining half marks
  (0xFEFF, 0xFEFF), // zero-width no-break space
  (0x1F3FB, 0x1F3FF), // emoji skin-tone modifiers
  (0xE0100, 0xE01EF), // variation selectors supplement
];

/// Sorted, non-overlapping inclusive code-point ranges rendered two cells
/// wide: East Asian Wide and Fullwidth, plus the emoji presentation blocks.
const List<(int, int)> _wide = [
  (0x1100, 0x115F), // Hangul Jamo initial consonants
  (0x231A, 0x231B), (0x2329, 0x232A), // discrete wide symbols
  (0x23E9, 0x23EC), (0x23F0, 0x23F0), (0x23F3, 0x23F3), (0x25FD, 0x25FE),
  (0x2614, 0x2615), (0x2648, 0x2653), (0x267F, 0x267F), (0x2693, 0x2693),
  (0x26A1, 0x26A1), (0x26AA, 0x26AB), (0x26BD, 0x26BE), (0x26C4, 0x26C5),
  (0x26CE, 0x26CE), (0x26D4, 0x26D4), (0x26EA, 0x26EA), (0x26F2, 0x26F3),
  (0x26F5, 0x26F5), (0x26FA, 0x26FA), (0x26FD, 0x26FD), (0x2705, 0x2705),
  (0x270A, 0x270B), (0x2728, 0x2728), (0x274C, 0x274C), (0x274E, 0x274E),
  (0x2753, 0x2755), (0x2757, 0x2757), (0x2795, 0x2797), (0x27B0, 0x27B0),
  (0x27BF, 0x27BF), (0x2B1B, 0x2B1C), (0x2B50, 0x2B50), (0x2B55, 0x2B55),
  (0x2E80, 0x303E), // CJK radicals, kangxi, punctuation
  (0x3041, 0x33FF), // kana, bopomofo, CJK compatibility
  (0x3400, 0x4DBF), // CJK extension A
  (0x4E00, 0x9FFF), // CJK unified ideographs
  (0xA000, 0xA4CF), // Yi
  (0xA960, 0xA97F), // Hangul Jamo extended A
  (0xAC00, 0xD7A3), // Hangul syllables
  (0xF900, 0xFAFF), // CJK compatibility ideographs
  (0xFE10, 0xFE19), // vertical forms
  (0xFE30, 0xFE6F), // CJK compatibility forms
  (0xFF00, 0xFF60), // fullwidth forms
  (0xFFE0, 0xFFE6), // fullwidth signs
  (0x16FE0, 0x16FFF), // Tangut and Nushu marks
  (0x17000, 0x18D08), // Tangut and Nushu
  (0x1B000, 0x1B2FF), // kana supplement and extension
  (0x1F000, 0x1FAFF), // emoji blocks
  (0x20000, 0x2FFFD), // CJK extensions B–F
  (0x30000, 0x3FFFD), // CJK extension G and later
];

bool _inRanges(int rune, List<(int, int)> ranges) {
  var low = 0;
  var high = ranges.length - 1;
  while (low <= high) {
    final mid = low + ((high - low) >> 1);
    final (start, end) = ranges[mid];
    if (rune < start) {
      high = mid - 1;
    } else if (rune > end) {
      low = mid + 1;
    } else {
      return true;
    }
  }
  return false;
}

/// An editable input buffer with cursor movement, Up/Down history, and
/// multi-line entry: a line ending in `\` continues onto the next line (the
/// backslash is consumed). Rendering is done through [write] so the editor
/// owns only the input block and never the surrounding scrollback.
///
/// The buffer holds runes (code points), and the cursor is placed by display
/// width ([runesWidth]), so wide CJK runes occupy two cells and astral runes
/// (emoji) edit as one character instead of splitting a surrogate pair.
final class LineEditor {
  LineEditor({
    required this.write,
    required this.stylePrompt,
    this.maxHistory = 200,
  });

  /// Receives raw terminal chunks (may contain ANSI).
  final void Function(String chunk) write;

  /// Styles the leading prompt (zero display width is assumed for the
  /// escape sequences it adds; the prompt itself is two columns, `› `).
  final String Function(String prompt) stylePrompt;

  final int maxHistory;

  final List<List<int>> _lines = [[]];
  int _line = 0;
  int _col = 0;
  int _renderedLine = 0;

  final List<String> _history = [];
  int _historyIndex = 0;
  String _draft = '';

  List<String> get history => List.unmodifiable(_history);

  /// The whole buffer, lines joined with `\n`.
  String get text => _lines.map(String.fromCharCodes).join('\n');

  /// Reset to an empty single line and draw the prompt.
  void begin() {
    _lines
      ..clear()
      ..add([]);
    _line = 0;
    _col = 0;
    _historyIndex = _history.length;
    _draft = '';
    _render();
  }

  /// Leave the typed text on screen and move to a fresh line.
  void finish() {
    final last = _lines.length - 1;
    final buffer = StringBuffer('\r');
    final delta = last - _renderedLine;
    if (delta > 0) {
      buffer.write('\x1b[${delta}B');
    } else if (delta < 0) {
      buffer.write('\x1b[${-delta}A');
    }
    buffer.write('\r');
    final end = 2 + runesWidth(_lines[last]);
    if (end > 0) buffer.write('\x1b[${end}C');
    buffer.write('\n');
    _renderedLine = 0;
    write(buffer.toString());
  }

  EditResult handle(Key key) {
    switch (key.kind) {
      case KeyKind.rune:
        _lines[_line].insert(_col, key.rune);
        _col++;
      case KeyKind.enter:
        return _enter();
      case KeyKind.newline:
        _newline();
      case KeyKind.paste:
        _insertText(key.text);
      case KeyKind.backspace:
        _backspace();
      case KeyKind.delete:
        _delete();
      case KeyKind.left:
        if (_col > 0) {
          _col--;
        } else if (_line > 0) {
          _line--;
          _col = _lines[_line].length;
        }
      case KeyKind.right:
        if (_col < _lines[_line].length) {
          _col++;
        } else if (_line < _lines.length - 1) {
          _line++;
          _col = 0;
        }
      case KeyKind.up:
        _up();
      case KeyKind.down:
        _down();
      case KeyKind.home:
        _col = 0;
      case KeyKind.end:
        _col = _lines[_line].length;
      case KeyKind.ctrlC:
        begin();
        return const EditResult.pending();
      case KeyKind.ctrlD:
        if (text.isEmpty) return const EditResult.eof();
      case KeyKind.esc:
      case KeyKind.tab:
      case KeyKind.other:
        break;
    }
    _render();
    return const EditResult.pending();
  }

  EditResult _enter() {
    final current = String.fromCharCodes(_lines[_line]);
    if (current.endsWith('\\')) {
      _lines[_line] =
          current.substring(0, current.length - 1).runes.toList();
      _lines.add([]);
      _line++;
      _col = 0;
      _render();
      return const EditResult.pending();
    }
    final result = text;
    if (result.trim().isNotEmpty) {
      if (_history.isEmpty || _history.last != result) _history.add(result);
      if (_history.length > maxHistory) _history.removeAt(0);
    }
    return EditResult.submit(result);
  }

  /// Insert a line break at the cursor (pasted newline), splitting the
  /// current line into a head and a tail.
  void _newline() {
    final line = _lines[_line];
    final tail = line.sublist(_col);
    _lines[_line] = line.sublist(0, _col);
    _lines.insert(_line + 1, tail);
    _line++;
    _col = 0;
  }

  /// Insert a whole paste at the cursor; `\n` starts new lines. One call,
  /// one [handle] render, so a large paste does not redraw per character.
  void _insertText(String text) {
    final parts = text.split('\n');
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) _newline();
      final runes = parts[i].runes.toList();
      _lines[_line].insertAll(_col, runes);
      _col += runes.length;
    }
  }

  void _backspace() {
    if (_col > 0) {
      _lines[_line].removeAt(--_col);
      return;
    }
    if (_line == 0) return;
    final merged = _lines[_line];
    _line--;
    _col = _lines[_line].length;
    _lines[_line].addAll(merged);
    _lines.removeAt(_line + 1);
  }

  void _delete() {
    if (_col < _lines[_line].length) {
      _lines[_line].removeAt(_col);
      return;
    }
    if (_line >= _lines.length - 1) return;
    final next = _lines[_line + 1];
    _lines[_line].addAll(next);
    _lines.removeAt(_line + 1);
  }

  void _up() {
    if (_line > 0) {
      _line--;
      _col = math.min(_col, _lines[_line].length);
      return;
    }
    if (_history.isEmpty) return;
    if (_historyIndex == _history.length) _draft = text;
    if (_historyIndex > 0) _historyIndex--;
    _load(_history[_historyIndex]);
  }

  void _down() {
    if (_line < _lines.length - 1) {
      _line++;
      _col = math.min(_col, _lines[_line].length);
      return;
    }
    if (_historyIndex >= _history.length) return;
    _historyIndex++;
    _load(_historyIndex == _history.length ? _draft : _history[_historyIndex]);
  }

  void _load(String entry) {
    _lines
      ..clear()
      ..addAll(entry.split('\n').map((line) => line.runes.toList()));
    if (_lines.isEmpty) _lines.add([]);
    _line = _lines.length - 1;
    _col = _lines[_line].length;
  }

  void _render() {
    final buffer = StringBuffer('\r');
    if (_renderedLine > 0) buffer.write('\x1b[${_renderedLine}A');
    buffer.write('\x1b[0J');
    for (var i = 0; i < _lines.length; i++) {
      buffer.write(i == 0 ? stylePrompt('› ') : '  ');
      buffer.write(String.fromCharCodes(_lines[i]));
      if (i < _lines.length - 1) buffer.write('\n');
    }
    final up = _lines.length - 1 - _line;
    if (up > 0) buffer.write('\x1b[${up}A');
    buffer.write('\r');
    final col = 2 + runesWidth(_lines[_line].sublist(0, _col));
    if (col > 0) buffer.write('\x1b[${col}C');
    _renderedLine = _line;
    write(buffer.toString());
  }
}
