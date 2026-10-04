import 'dart:convert';

import 'package:dart_tui/dart_tui.dart' show RgbColor;
import 'package:markdown/markdown.dart' as md;

/// C6: render markdown to styled terminal text for the human surface.
///
/// The model's reply is markdown; the human surface renders it (headings,
/// emphasis, inline code, fenced code, lists, blockquotes, rules, links,
/// tables) with ANSI styling. The automation surface never uses this — its
/// answers stay raw and machine-readable.

/// Style one run of text; the interface's `Console.style` has this shape, so
/// markdown inherits the caller's ANSI on/off behavior.
typedef Stylize = String Function(
  String text, {
  bool bold,
  bool dim,
  bool italic,
  bool reverse,
  RgbColor? fg,
});

const RgbColor _sky = RgbColor(137, 180, 250);
const RgbColor _mauve = RgbColor(203, 166, 247);
const RgbColor _green = RgbColor(166, 227, 161);
const RgbColor _peach = RgbColor(250, 179, 135);
const RgbColor _slate = RgbColor(108, 112, 134);

/// The model channel: the answer's body text, distinct from the default-colored
/// user input and the yellow local command output.
const RgbColor _model = RgbColor(245, 194, 231);

final RegExp _ansi = RegExp(r'\x1b\[[0-9;]*m');

/// Display width of [text] ignoring ANSI escape sequences.
int visibleWidth(String text) => text.replaceAll(_ansi, '').length;

/// Block-parse [source] and render it to ANSI text, one terminal line per
/// `\n`. Never adds a trailing newline.
String renderMarkdown(String source, Stylize stylize, {int width = 80}) {
  final document = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  );
  return _Renderer(stylize, width).blocks(document.parse(source)).join('\n');
}

/// Incremental markdown renderer for the streaming surface. Rather than
/// waiting for a whole block, it emits each completed line as it arrives:
/// prose immediately, code fences as a live `╭ … │ … ╰` box, and only tables
/// (which need every row to align columns) stay buffered until the block
/// ends. Call [flush] at the end of a step to emit any partial line and close
/// an open table or code block.
final class MarkdownStream {
  MarkdownStream({this.width = 80});

  final int width;

  /// Buffered table rows; flushed once the table ends.
  final StringBuffer _table = StringBuffer();
  String _tail = '';
  bool _inFence = false;
  String _fence = '```';
  int _indent = 0;

  /// Feed a raw model delta; returns newly rendered text (empty while only a
  /// partial line has arrived).
  String add(String delta, Stylize stylize) {
    final out = StringBuffer();
    var data = _tail + delta;
    _tail = '';
    var start = 0;
    while (true) {
      final nl = data.indexOf('\n', start);
      if (nl < 0) {
        _tail = data.substring(start);
        break;
      }
      _line(data.substring(start, nl), stylize, out);
      start = nl + 1;
    }
    return out.toString();
  }

  /// Render any buffered text; call at the end of a step.
  String flush(Stylize stylize) {
    final out = StringBuffer();
    if (_tail.isNotEmpty) {
      _line(_tail, stylize, out);
      _tail = '';
    }
    _flushTable(stylize, out);
    if (_inFence) {
      _inFence = false;
      _write(out, '  ╰─', stylize, _slate);
    }
    return out.toString();
  }

  void _line(String line, Stylize stylize, StringBuffer out) {
    // Repair a fence the model glued to the end of a text line
    // (`## Steps```bash`) by splitting it into its own line, then continuing.
    if (!_inFence) {
      final split = _unglueFence(line);
      if (split != null) {
        _line(split.$1, stylize, out);
        _line(split.$2, stylize, out);
        return;
      }
    }
    final marker = _fenceMarker(line);
    if (_inFence) {
      if (marker != null && marker == _fence) {
        _inFence = false;
        _write(out, '  ╰─', stylize, _slate);
      } else {
        out.write(stylize('  │ ', fg: _slate));
        out.write(stylize(_stripIndent(line), fg: _model));
        out.write('\n');
      }
      return;
    }
    if (marker != null) {
      _flushTable(stylize, out);
      _inFence = true;
      _fence = marker;
      _indent = _leadingSpaces(line);
      _write(out, '  ╭─${_codeLang(line)}', stylize, _slate);
      return;
    }
    if (line.trim().isEmpty) {
      _flushTable(stylize, out);
      return;
    }
    if (line.trimLeft().startsWith('|')) {
      _table.writeln(line);
      return;
    }
    _flushTable(stylize, out);
    out.write(renderMarkdown(line, stylize, width: width));
    out.write('\n');
  }

  void _flushTable(Stylize stylize, StringBuffer out) {
    if (_table.isEmpty) return;
    final source = _table.toString();
    _table.clear();
    out.write(renderMarkdown(source, stylize, width: width));
    out.write('\n');
  }

  void _write(StringBuffer out, String text, Stylize stylize, RgbColor color) {
    out.write(stylize(text, fg: color));
    out.write('\n');
  }

  /// The `language-…` info string of an opening fence, as ` lang`, or empty.
  String _codeLang(String line) {
    final info = line.trimLeft().replaceFirst(RegExp(r'^[`~]+'), '').trim();
    if (info.isEmpty) return '';
    return ' ${info.split(RegExp(r'\s+')).first}';
  }

  /// A fence may be indented by up to three spaces (CommonMark), e.g. a code
  /// block nested under a list item. Returns the fence run (` ``` `/`~~~`) or
  /// null.
  String? _fenceMarker(String line) {
    final i = _leadingSpaces(line);
    if (line.length - i < 3) return null;
    final ch = line[i];
    if (ch != '`' && ch != '~') return null;
    var n = i;
    while (n < line.length && line[n] == ch) {
      n++;
    }
    return n - i < 3 ? null : ch * 3;
  }

  /// Leading spaces (capped at three) on [line].
  static int _leadingSpaces(String line) {
    var i = 0;
    while (i < 3 && i < line.length && line[i] == ' ') {
      i++;
    }
    return i;
  }

  /// Repair a fence the model glued to the end of a text line, e.g.
  /// `## Steps```bash` or `text``` `. Returns `(head, fenceLine)`, or null
  /// when the line is already a fence, has no trailing fence, or the head
  /// itself carries a fence run (inline code, not a malformed block).
  (String, String)? _unglueFence(String line) {
    if (_fenceMarker(line) != null) return null;
    final match = RegExp(r'^(.*\S)[ \t]*([`~]{3,})([^\s`~]*)[ \t]*$')
        .firstMatch(line);
    if (match == null) return null;
    final head = match.group(1)!;
    if (head.contains('```') || head.contains('~~~')) return null;
    return (head, match.group(2)! + match.group(3)!);
  }

  /// Remove the opening fence's indent from a code line.
  String _stripIndent(String line) {
    var i = 0;
    while (i < _indent && i < line.length && line[i] == ' ') {
      i++;
    }
    return line.substring(i);
  }
}

final class _Renderer {
  _Renderer(this._stylize, this._width);

  final Stylize _stylize;
  final int _width;

  String _s(
    String text, {
    bool bold = false,
    bool dim = false,
    bool italic = false,
    RgbColor? fg,
  }) =>
      _stylize(text, bold: bold, dim: dim, italic: italic, fg: fg);

  List<String> blocks(List<md.Node> nodes) {
    final out = <String>[];
    for (final node in nodes) {
      if (out.isNotEmpty && out.last.isNotEmpty) out.add('');
      out.addAll(_block(node));
    }
    return out;
  }

  List<String> _block(md.Node node) {
    if (node is md.Text) return [node.text];
    if (node is! md.Element) return const [];
    final children = node.children ?? const <md.Node>[];
    switch (node.tag) {
      case 'p':
        return _inlineAll(children).split('\n');
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        return _heading(node);
      case 'pre':
        return _codeBlock(node);
      case 'blockquote':
        return [
          for (final line in blocks(children)) _s('│ ', fg: _slate) + line,
        ];
      case 'ul':
      case 'ol':
        return _list(node);
      case 'hr':
        return [_s('─' * (_width > 2 ? _width - 2 : 2), fg: _slate)];
      case 'table':
        return _table(node);
      default:
        return blocks(children);
    }
  }

  String _inlineAll(List<md.Node> children, [RgbColor? base]) =>
      children.map((child) => _inline(child, base)).join();

  /// Render inline [node]. [base] is the surrounding text colour, so emphasis
  /// and headings tint their plain text without an outer wrap that a nested
  /// reset would erase.
  String _inline(md.Node node, [RgbColor? base]) {
    if (node is md.Text) {
      return _s(node.text.replaceAll('\n', ' '), fg: base ?? _model);
    }
    if (node is! md.Element) return node.textContent;
    final children = node.children ?? const <md.Node>[];
    switch (node.tag) {
      case 'strong':
        return _s(_inlineAll(children, base), bold: true);
      case 'em':
        return _s(_inlineAll(children, base), italic: true);
      case 'del':
        return _s(_inlineAll(children, base), dim: true);
      case 'code':
        return _s(node.textContent, fg: _peach);
      case 'a':
        final href = node.attributes['href'];
        final label = _inlineAll(children, _sky);
        if (href == null || href == node.textContent) return label;
        return label + _s(' ($href)', dim: true);
      case 'img':
        return _s('[image: ${node.attributes['alt'] ?? ''}]',
            dim: true, fg: base ?? _model);
      case 'br':
        return '\n';
      case 'input':
        return node.attributes.containsKey('checked') ? '[x] ' : '[ ] ';
      default:
        return _inlineAll(children, base);
    }
  }

  List<String> _heading(md.Element el) {
    final level = int.parse(el.tag.substring(1));
    final color = switch (level) {
      1 => _sky,
      2 => _mauve,
      3 => _green,
      _ => _slate,
    };
    final text = _inlineAll(el.children ?? const [], color);
    final line = _s(text, bold: true);
    if (level <= 2) {
      final rule = '─' * visibleWidth(text).clamp(1, _width);
      return [line, _s(rule, fg: color)];
    }
    return [line];
  }

  List<String> _codeBlock(md.Element pre) {
    md.Element? code;
    for (final child in pre.children ?? const <md.Node>[]) {
      if (child is md.Element && child.tag == 'code') {
        code = child;
        break;
      }
    }
    final raw = code?.textContent ?? pre.textContent;
    final content = raw.endsWith('\n') ? raw.substring(0, raw.length - 1) : raw;
    final cls = code?.attributes['class'];
    final lang = (cls != null && cls.startsWith('language-'))
        ? cls.substring('language-'.length)
        : null;
    return [
      _s('  ╭─${lang == null ? '' : ' $lang'}', fg: _slate),
      for (final line in const LineSplitter().convert(content))
        _s('  │ ', fg: _slate) + _s(line, fg: _model),
      _s('  ╰─', fg: _slate),
    ];
  }

  List<String> _list(md.Element el) {
    final ordered = el.tag == 'ol';
    var index = int.tryParse(el.attributes['start'] ?? '1') ?? 1;
    final out = <String>[];
    for (final child in el.children ?? const <md.Node>[]) {
      if (child is! md.Element || child.tag != 'li') continue;
      out.addAll(_listItem(child, ordered ? '${index++}. ' : '• '));
    }
    return out;
  }

  List<String> _listItem(md.Element item, String marker) {
    final pad = ' ' * marker.length;
    final inline = <md.Node>[];
    final nested = <md.Node>[];
    for (final child in item.children ?? const <md.Node>[]) {
      if (child is md.Element && _isBlockTag(child.tag)) {
        nested.add(child);
      } else {
        inline.add(child);
      }
    }
    final head = _inlineAll(inline).trim();
    final lines = <String>[];
    if (head.isNotEmpty) lines.add(_s(marker, fg: _mauve) + head);
    for (final blockNode in nested) {
      final sub = _block(blockNode);
      for (var i = 0; i < sub.length; i++) {
        if (lines.isEmpty && i == 0) {
          lines.add(_s(marker, fg: _mauve) + sub[i]);
        } else {
          lines.add(pad + sub[i]);
        }
      }
    }
    if (lines.isEmpty) lines.add(_s(marker, fg: _mauve));
    return lines;
  }

  static bool _isBlockTag(String tag) => const {
        'p', 'ul', 'ol', 'blockquote', 'pre', 'table',
        'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'hr',
      }.contains(tag);

  List<String> _table(md.Element table) {
    final headerRows = <List<String>>[];
    final bodyRows = <List<String>>[];
    for (final child in table.children ?? const <md.Node>[]) {
      if (child is! md.Element) continue;
      if (child.tag == 'thead') {
        for (final tr in child.children ?? const <md.Node>[]) {
          if (tr is md.Element && tr.tag == 'tr') headerRows.add(_row(tr));
        }
      } else if (child.tag == 'tbody') {
        for (final tr in child.children ?? const <md.Node>[]) {
          if (tr is md.Element && tr.tag == 'tr') bodyRows.add(_row(tr));
        }
      }
    }
    final rows = [...headerRows, ...bodyRows];
    if (rows.isEmpty) return const [];
    final cols = rows.fold<int>(0, (max, row) => row.length > max ? row.length : max);
    final widths = List<int>.filled(cols, 1);
    for (final row in rows) {
      for (var i = 0; i < row.length; i++) {
        final w = visibleWidth(row[i]);
        if (w > widths[i]) widths[i] = w;
      }
    }
    String render(List<String> row, {required bool bold}) {
      final cells = <String>[];
      for (var i = 0; i < cols; i++) {
        final cell = i < row.length ? row[i] : '';
        final gap = widths[i] - visibleWidth(cell);
        cells.add(cell + ' ' * (gap < 0 ? 0 : gap));
      }
      return _s('│ ', fg: _slate) +
          cells.map((cell) => bold ? _s(cell, bold: true) : cell).join(_s(' │ ', fg: _slate)) +
          _s(' │', fg: _slate);
    }

    final out = <String>[];
    for (final row in headerRows) {
      out.add(render(row, bold: true));
    }
    if (headerRows.isNotEmpty) {
      out.add(_s('├${widths.map((w) => '─' * (w + 2)).join('┼')}┤', fg: _slate));
    }
    for (final row in bodyRows) {
      out.add(render(row, bold: false));
    }
    return out;
  }

  List<String> _row(md.Element tr) {
    final cells = <String>[];
    for (final cell in tr.children ?? const <md.Node>[]) {
      if (cell is md.Element && (cell.tag == 'th' || cell.tag == 'td')) {
        cells.add(_inlineAll(cell.children ?? const []).replaceAll('\n', ' '));
      }
    }
    return cells;
  }
}
