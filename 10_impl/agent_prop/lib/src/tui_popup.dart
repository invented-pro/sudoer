import 'package:dart_tui/dart_tui.dart'
    show Cursor, CursorShape, RgbColor, Style, getWidth, truncate;

/// C6: one row of a modal popup. [label] is the filter target and the main
/// text; [detail] rides right-aligned (a key state, a context window);
/// [active] marks the row already in effect.
final class TuiPopupItem {
  const TuiPopupItem({
    required this.value,
    required this.label,
    this.detail,
    this.active = false,
  });

  /// The id returned when the row is chosen; viewers use the line itself.
  final String value;
  final String label;
  final String? detail;
  final bool active;
}

const RgbColor _popupSky = RgbColor(137, 180, 250);
const RgbColor _popupMauve = RgbColor(203, 166, 247);
const RgbColor _popupGreen = RgbColor(166, 227, 161);
const RgbColor _popupSlate = RgbColor(108, 112, 134);

/// C6: the modal popup drawn over the frame: a bordered, centered box with a
/// type-to-filter line, a scrolling list, and a footer hint. The app routes
/// every key here while a popup is open, so the editor and the run queue stay
/// untouched underneath. Selection-style interactions (provider, model,
/// session pickers) and read-only listings (help, plan) both render through
/// this one component.
final class TuiPopup {
  TuiPopup({
    required this.title,
    required this.items,
    this.selectable = true,
    this.footer,
    this.matchLabelPrefix = false,
  });

  final String title;

  /// The full row set; [visible] applies the filter.
  final List<TuiPopupItem> items;

  /// False for read-only viewers: Enter closes without a value.
  final bool selectable;

  /// Footer override; defaults to the standard keys hint.
  final String? footer;

  /// Match [query] against the label prefix only (completion menus), instead
  /// of substring-matching label and detail.
  final bool matchLabelPrefix;

  /// The type-to-filter query.
  String query = '';

  /// Index into [visible]; also the scroll cursor for viewers.
  int cursor = 0;

  /// First visible row index into [visible].
  int scroll = 0;

  /// List rows the box may show; the app sets it from the terminal height.
  int maxRows = 12;

  /// True when every whitespace-separated query token appears in the row
  /// (case-insensitive), so `zhipu glm` narrows like a fuzzy finder. With
  /// [matchLabelPrefix] the query must prefix the label instead — a slash
  /// completion menu must not match its descriptions.
  List<TuiPopupItem> get visible {
    if (matchLabelPrefix) {
      if (query.isEmpty) return items;
      final prefix = query.toLowerCase();
      return [
        for (final item in items)
          if (item.label.toLowerCase().startsWith(prefix)) item,
      ];
    }
    final tokens = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty);
    if (tokens.isEmpty) return items;
    return [
      for (final item in items)
        if (() {
          final haystack = '${item.label} ${item.detail ?? ''}'.toLowerCase();
          return tokens.every((token) => haystack.contains(token));
        }())
          item,
    ];
  }

  /// The footer hint the frame should show while the popup is open.
  String get footerHint =>
      footer ??
      (selectable
          ? '↑↓ move · type to filter · Enter select · Esc close'
          : '↑↓ scroll · type to filter · Enter or Esc close');

  /// The chosen [TuiPopupItem.value], or null when nothing is choosable.
  String? confirm() {
    if (!selectable) return null;
    final rows = visible;
    if (rows.isEmpty) return null;
    return rows[cursor.clamp(0, rows.length - 1)].value;
  }

  void move(int delta) {
    final rows = visible;
    if (rows.isEmpty) {
      cursor = 0;
      scroll = 0;
      return;
    }
    cursor = (cursor + delta).clamp(0, rows.length - 1);
    _keepCursorVisible();
  }

  void page(int direction) => move(direction * _rowsShown);

  void toTop() {
    cursor = 0;
    scroll = 0;
  }

  void toBottom() {
    final rows = visible;
    if (rows.isEmpty) return;
    cursor = rows.length - 1;
    _keepCursorVisible();
  }

  void type(String text) {
    query += text;
    cursor = 0;
    scroll = 0;
  }

  void backspace() {
    if (query.isEmpty) return;
    query = query.substring(0, query.length - 1);
    cursor = 0;
    scroll = 0;
  }

  int get _rowsShown {
    final rows = visible;
    if (rows.isEmpty) return 1;
    return rows.length.clamp(1, maxRows.clamp(1, 64));
  }

  void _keepCursorVisible() {
    final shown = _rowsShown;
    if (cursor < scroll) scroll = cursor;
    if (cursor >= scroll + shown) scroll = cursor - shown + 1;
    scroll = scroll.clamp(0, (visible.length - shown).clamp(0, visible.length));
  }

  /// Draw the box over [frameContent] (the rendered frame) and return the
  /// composed content plus the popup's cursor (the filter line caret).
  /// Covered rows are replaced wholesale, so the popup hides whatever it
  /// overlaps; rows above and below keep the frame (and its styles).
  ({String content, Cursor cursor}) overlay(
    String frameContent, {
    required int width,
    required int height,
  }) {
    final lines = frameContent.split('\n');
    final rows = visible;
    final shown = _rowsShown;
    final shownCount = rows.isEmpty ? 0 : shown;

    // Natural width from the widest row, capped by the terminal.
    var contentWidth = 12;
    for (final row in rows) {
      final w =
          4 +
          getWidth(row.label) +
          (row.detail == null ? 0 : getWidth(row.detail!) + 2);
      if (w > contentWidth) contentWidth = w;
    }
    final footerText = '$shownCount/${rows.length} · $footerHint';
    if (footerText.length + 4 > contentWidth) {
      contentWidth = footerText.length + 4;
    }
    var boxWidth = contentWidth + 4;
    if (boxWidth > width) boxWidth = width;
    if (boxWidth < 16 && width >= 16) boxWidth = 16;
    final innerWidth = (boxWidth - 4).clamp(2, boxWidth);

    final boxHeight = 2 + 1 + shown + 1; // borders + filter + rows + footer
    final top = ((height - boxHeight) ~/ 2).clamp(0, lines.length - 1);
    final left = ((width - boxWidth) ~/ 2).clamp(0, width - 1);

    final box = <String>[
      _topBorder(title, boxWidth),
      _filterLine(query, innerWidth),
      for (var i = 0; i < shown; i++)
        scroll + i < rows.length
            ? _rowLine(rows[scroll + i], i == cursor, innerWidth, selectable)
            : _blankRow(innerWidth),
      _footerLine(footerText, innerWidth),
      _bottomBorder(boxWidth),
    ];

    for (var r = 0; r < box.length; r++) {
      final row = top + r;
      if (row >= lines.length) break;
      final line = truncate(box[r], width);
      final trailing = width - left - getWidth(line);
      lines[row] = '${' ' * left}$line${trailing > 0 ? ' ' * trailing : ''}';
    }

    final caretRow = (top + 1).clamp(0, height - 1);
    final caretCol = (left + 4 + _queryWidth(query)).clamp(0, width - 1);
    return (
      content: lines.join('\n'),
      cursor: Cursor(x: caretCol, y: caretRow, shape: CursorShape.bar),
    );
  }

  static int _queryWidth(String query) => getWidth(query);

  /// Draw a compact completion menu anchored with its bottom edge at
  /// [bottomRow] (the row above the editor): a plain bordered list with no
  /// filter line or footer, because the editor below stays the interaction
  /// surface and keeps the hardware cursor. Returns the composed content, or
  /// [frameContent] unchanged when there is nothing (or no room) to show.
  String overlayAnchored(
    String frameContent, {
    required int width,
    required int height,
    required int bottomRow,
    int left = 2,
    int maxRows = 8,
    int minTopRow = 3,
  }) {
    final rows = visible;
    if (rows.isEmpty) return frameContent;
    final available = bottomRow - minTopRow + 1;
    if (available < 3) return frameContent;
    final shown = rows.length.clamp(1, maxRows.clamp(1, available - 2));

    var contentWidth = 10;
    for (final row in rows.take(shown)) {
      final w =
          4 +
          getWidth(row.label) +
          (row.detail == null ? 0 : getWidth(row.detail!) + 2);
      if (w > contentWidth) contentWidth = w;
    }
    var boxWidth = contentWidth + 4;
    if (boxWidth > width - left) boxWidth = width - left;
    final innerWidth = (boxWidth - 4).clamp(2, boxWidth);

    final lines = frameContent.split('\n');
    final top = bottomRow - (shown + 1);
    final box = <String>[
      _style('╭${'─' * (boxWidth - 2).clamp(0, boxWidth)}╮', fg: _popupMauve),
      for (var i = 0; i < shown; i++)
        _rowLine(rows[scroll + i], scroll + i == cursor, innerWidth, true),
      _style('╰${'─' * (boxWidth - 2).clamp(0, boxWidth)}╯', fg: _popupMauve),
    ];

    for (var r = 0; r < box.length; r++) {
      final row = top + r;
      if (row < 0 || row >= lines.length) break;
      final line = truncate(box[r], width);
      final trailing = width - left - getWidth(line);
      lines[row] = '${' ' * left}$line${trailing > 0 ? ' ' * trailing : ''}';
    }
    return lines.join('\n');
  }

  static String _style(
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

  static String _topBorder(String title, int boxWidth) {
    if (boxWidth < 6) return _style('─' * boxWidth, fg: _popupMauve);
    final label = _style(
      ' ${truncate(title, boxWidth - 4)} ',
      fg: _popupSky,
      bold: true,
    );
    final fill = (boxWidth - 2 - getWidth(label)).clamp(0, boxWidth);
    return _style('╭', fg: _popupMauve) +
        label +
        _style('${'─' * fill}╮', fg: _popupMauve);
  }

  static String _bottomBorder(int boxWidth) =>
      _style('╰${'─' * (boxWidth - 2).clamp(0, boxWidth)}╯', fg: _popupMauve);

  static String _filterLine(String query, int innerWidth) {
    final body = query.isEmpty
        ? _style('type to filter…', dim: true, italic: true)
        : _style(query);
    return _style('│ ', fg: _popupMauve) +
        _style('› ', bold: true) +
        truncate(body, innerWidth) +
        _style(' │', fg: _popupMauve);
  }

  static String _blankRow(int innerWidth) =>
      _style('│ ', fg: _popupMauve) +
      ' ' * innerWidth +
      _style(' │', fg: _popupMauve);

  static String _rowLine(
    TuiPopupItem item,
    bool selected,
    int innerWidth,
    bool selectable,
  ) {
    final prefix = selected && selectable
        ? _style('❯ ', fg: _popupSky, bold: true)
        : '  ';
    final marker = item.active ? _style('●', fg: _popupGreen) : ' ';
    final detail = item.detail;
    var labelSpace = innerWidth - 4;
    var styledDetail = '';
    if (detail != null && detail.isNotEmpty) {
      final detailWidth = detail.length;
      labelSpace = innerWidth - 4 - detailWidth - 2;
      styledDetail = _style(
        truncate(detail, (innerWidth - 4).clamp(0, innerWidth)),
        dim: true,
      );
    }
    labelSpace = labelSpace.clamp(1, innerWidth);
    var label = truncate(item.label, labelSpace);
    final labelWidth = getWidth(label);
    final padding = (labelSpace - labelWidth).clamp(0, labelSpace);
    final styledLabel = selected
        ? _style('$label${' ' * padding}', bold: true, fg: _popupSky)
        : _style('$label${' ' * padding}');
    final detailSegment = styledDetail.isEmpty ? '' : '  $styledDetail';
    final border = _style('│ ', fg: _popupMauve);
    return '$border$prefix$marker $styledLabel$detailSegment${_style(' │', fg: _popupMauve)}';
  }

  static String _footerLine(String text, int innerWidth) =>
      _style('│ ', fg: _popupMauve) +
      _style(truncate(' $text', innerWidth), dim: true, fg: _popupSlate) +
      _style(' │', fg: _popupMauve);
}

/// C6: a one-line modal input drawn like [TuiPopup] — used for secrets (an
/// API key), where the value is masked and never echoed into a frame the
/// transcript could keep. The app routes every key while it is open: typing
/// edits, Enter resolves the value, Esc (or Ctrl+C) resolves null.
final class TuiPrompt {
  TuiPrompt({required this.title, this.note, this.mask = true, this.footer});

  final String title;

  /// A dim explanation line under the input (why the value is asked).
  final String? note;

  /// Render typed characters as bullets instead of the value itself.
  final bool mask;

  /// Footer override; defaults to the confirm/skip hint.
  final String? footer;

  /// The typed value, masked in [overlay] while [mask] is set.
  String value = '';

  String get footerHint => footer ?? 'Enter confirm · Esc skip';

  void type(String text) => value += text;

  void backspace() {
    if (value.isNotEmpty) value = value.substring(0, value.length - 1);
  }

  String get _masked => mask ? '•' * value.length : value;

  /// Draw the box over [frameContent], centered like a popup, with the
  /// hardware cursor just after the (masked) input.
  ({String content, Cursor cursor}) overlay(
    String frameContent, {
    required int width,
    required int height,
  }) {
    final lines = frameContent.split('\n');
    final hasNote = note != null && note!.isNotEmpty;
    final boxHeight = 2 + 1 + (hasNote ? 1 : 0) + 1; // borders, input, footer
    var boxWidth = 44;
    for (final candidate in [
      getWidth(title) + 8,
      footerHint.length + 6,
      if (hasNote) getWidth(note!) + 6,
    ]) {
      if (candidate > boxWidth) boxWidth = candidate;
    }
    if (boxWidth > width) boxWidth = width;
    final innerWidth = (boxWidth - 4).clamp(2, boxWidth);

    final top = ((height - boxHeight) ~/ 2).clamp(0, lines.length - 1);
    final left = ((width - boxWidth) ~/ 2).clamp(0, width - 1);

    final box = <String>[
      TuiPopup._topBorder(title, boxWidth),
      TuiPopup._style('│ ', fg: _popupMauve) +
          TuiPopup._style('› ', bold: true) +
          TuiPopup._style(_masked) +
          TuiPopup._style(' │', fg: _popupMauve),
      if (hasNote)
        TuiPopup._style('│ ', fg: _popupMauve) +
            TuiPopup._style(
              truncate(' ${truncate(note!, innerWidth - 1)}', innerWidth),
              dim: true,
              italic: true,
            ) +
            TuiPopup._style(' │', fg: _popupMauve),
      TuiPopup._footerLine(footerHint, innerWidth),
      TuiPopup._bottomBorder(boxWidth),
    ];

    for (var r = 0; r < box.length; r++) {
      final row = top + r;
      if (row >= lines.length) break;
      final line = truncate(box[r], width);
      final trailing = width - left - getWidth(line);
      lines[row] = '${' ' * left}$line${trailing > 0 ? ' ' * trailing : ''}';
    }

    final caretRow = (top + 1).clamp(0, height - 1);
    final caretCol = (left + 4 + getWidth(_masked)).clamp(0, width - 1);
    return (
      content: lines.join('\n'),
      cursor: Cursor(x: caretCol, y: caretRow, shape: CursorShape.bar),
    );
  }
}
