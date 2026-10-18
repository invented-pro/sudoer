import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'models.dart';

/// C4 (CLM): model-controlled context, "context as a file".
///
/// A [ContextLog] mirrors the session transcript to a plain-text file the
/// model may edit with its ordinary tools. When the model edits the file, the
/// edit is adopted as the live context on the next step; when it does not, the
/// harness appends the turn as usual (the default append of a standard LM).
///
/// The file is a *view* the model owns, never the store: the session file
/// (C5) remains authoritative across runs, and the harness rewrites the
/// context file from the transcript whenever the model leaves it alone.
///
/// Format (v1), one block per transcript entry:
///
/// ```
/// [[ctx v1]]
/// [[ctx role=user]]
/// goal text
/// [[ctx role=assistant]]
/// thought text
/// [[call]] read {"path":"README.md"}
/// [[ctx role=observation outcome=ok id=<call id>]]
/// observation text
/// [[ctx role=note]]
/// the model's own free-form note
/// ```
///
/// A body line that begins with `[[` is escaped by prefixing a backslash
/// (`\[[`) so the block markers stay unambiguous. `role` is one of `user`,
/// `assistant`, `observation`, `note`; `outcome` is an [Outcome] wire value
/// (default `ok`); `id` binds an observation to the tool call it answers.
final class ContextLog {
  ContextLog(this.file, {this.workspaceRoot});

  /// The live context file.
  final File file;

  /// The workspace root [displayPath] is measured against, when known.
  final String? workspaceRoot;

  /// The path spelled for the model (workspace-relative, POSIX separators).
  String get displayPath {
    final root = workspaceRoot;
    if (root == null) return file.path;
    return p.posix.joinAll(
        p.relative(file.path, from: p.normalize(p.absolute(root))).split(p.separator));
  }

  /// The default context file for [config]: `context.file` when set
  /// (resolved against the workspace root when relative), else
  /// `<workspace_root>/.sudoer/context.md`.
  static File fileFor(Config config) {
    final configured = config.context.file;
    if (configured != null && configured.isNotEmpty) {
      return File(p.isAbsolute(configured)
          ? configured
          : p.join(config.workspaceRoot, configured));
    }
    return File(p.join(config.workspaceRoot, '.sudoer', 'context.md'));
  }

  /// Build the log for [config].
  factory ContextLog.forConfig(Config config) => ContextLog(fileFor(config));

  /// The version header written at the top of every rendering.
  static const String _header = '[[ctx v1]]';

  static final RegExp _block = RegExp(r'^\[\[ctx\s+(.*?)\]\]\s*$');
  static final RegExp _call =
      RegExp(r'^\[\[call(?:\s+([^\]]*))?\]\]\s+(\S+)\s*(.*)$');

  /// The canonical text for [transcript] (the harness's default rendering).
  String render(List<Entry> transcript) {
    final out = StringBuffer(_header)..write('\n');
    for (final entry in transcript) {
      switch (entry) {
        case UserEntry(:final text):
          _writeBlock(out, 'role=user', text, const []);
        case AssistantEntry(:final thought, :final action):
          _writeBlock(
            out,
            'role=assistant',
            thought,
            [for (final call in action.calls) call],
          );
        case ObservationEntry(:final text, :final outcome, :final toolCallId):
          final attrs = StringBuffer('role=observation outcome=${outcome.wire}');
          if (toolCallId != null) attrs.write(' id=$toolCallId');
          _writeBlock(out, attrs.toString(), text, const []);
      }
    }
    return out.toString();
  }

  static void _writeBlock(
    StringBuffer out,
    String attrs,
    String body,
    List<ToolCall> calls,
  ) {
    out.write('[[ctx $attrs]]\n');
    for (final line in body.split('\n')) {
      out.write(line.startsWith('[[') ? '\\$line' : line);
      out.write('\n');
    }
    for (final call in calls) {
      // The call id round-trips so observations stay bound to their call
      // across a parse (without it, an observation would look orphaned).
      final idAttr = call.id == null ? '' : ' id=${call.id}';
      out.write(
          '[[call$idAttr]] ${call.name} ${jsonEncode(call.arguments)}\n');
    }
  }

  /// Parse [text] back into transcript entries. Throws [FormatException] when
  /// the text is not a well-formed context: an unrecognized marker, a tool
  /// call outside an assistant block, no blocks at all, or no `user` block
  /// (the goal is pinned — a context that has lost it is malformed and never
  /// silently wiped).
  List<Entry> parse(String text) {
    final entries = <Entry>[];
    _Block? current;
    var sawBlock = false;
    var sawUser = false;

    void flush() {
      final block = current;
      current = null;
      if (block == null) return;
      switch (block.role) {
        case 'user':
          entries.add(UserEntry(block.body()));
        case 'assistant':
          final calls = block.calls;
          entries.add(AssistantEntry(
            thought: block.body(),
            action:
                calls.isEmpty ? Finish(block.body()) : ToolBatch(calls),
          ));
        case 'observation':
          entries.add(ObservationEntry(
            text: block.body(),
            outcome: block.attrs['outcome'] == null
                ? Outcome.ok
                : OutcomeJson.fromWire(block.attrs['outcome']!),
            toolCallId: block.attrs['id'],
          ));
        case 'note':
          // The model's own free-form note (mirrors the paper's emergent
          // "notes" role): carried as a harness-level observation.
          entries.add(ObservationEntry(text: block.body(), outcome: Outcome.ok));
        default:
          throw FormatException(
              'unknown context role: "${block.role}" '
              '(expected user, assistant, observation, note)');
      }
    }

    // The renderer terminates every line (including the last) with `\n`;
    // drop that single final newline so an EOF body does not gain a phantom
    // trailing empty line.
    final content = text.endsWith('\n')
        ? text.substring(0, text.length - 1)
        : text;
    for (final raw in content.split('\n')) {
      final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
      // An escaped body line: drop the single backslash and keep the text.
      if (line.startsWith('\\[[')) {
        if (current == null) {
          throw const FormatException(
              'escaped line outside a context block');
        }
        current!.add(line.substring(1));
        continue;
      }
      final block = _block.firstMatch(line);
      if (block != null) {
        final attrs = _parseAttrs(block.group(1)!);
        if (attrs.isEmpty) {
          // A bare marker such as `[[ctx v1]]` is a version header: allowed
          // only before any content block.
          if (current == null && !sawBlock && line.trim() == '[[ctx v1]]') {
            continue;
          }
          throw FormatException('unrecognized context marker: $line');
        }
        flush();
        final role = attrs['role'];
        if (role == null || role.isEmpty) {
          throw FormatException('context block is missing a role: $line');
        }
        sawBlock = true;
        if (role == 'user') sawUser = true;
        current = _Block(role, attrs);
        continue;
      }
      final call = _call.firstMatch(line);
      if (call != null) {
        if (current == null || current!.role != 'assistant') {
          throw const FormatException(
              'a [[call]] must appear inside an assistant block');
        }
        final callId = _parseAttrs(call.group(1) ?? '')['id'];
        final name = call.group(2)!;
        final Object? args;
        try {
          args = call.group(3)!.trim().isEmpty
              ? <String, dynamic>{}
              : jsonDecode(call.group(3)!);
        } on FormatException catch (e) {
          throw FormatException('bad call arguments for $name: ${e.message}');
        }
        if (args is! Map) {
          throw FormatException('call arguments must be a JSON object: $line');
        }
        current!.calls.add(ToolCall(
          id: callId,
          name: name,
          arguments: args.cast<String, dynamic>(),
        ));
        continue;
      }
      if (current != null) {
        current!.add(line);
      }
      // Text before the first block (a preamble the model wrote) is ignored.
    }
    flush();

    if (!sawBlock) {
      throw const FormatException('no [[ctx ...]] blocks found');
    }
    if (!sawUser) {
      throw const FormatException('context has no user (goal) block');
    }
    return entries;
  }

  static Map<String, String> _parseAttrs(String raw) {
    final attrs = <String, String>{};
    for (final token in raw.trim().split(RegExp(r'\s+'))) {
      if (token.isEmpty) continue;
      final eq = token.indexOf('=');
      if (eq <= 0) return const {}; // e.g. the `v1` version header
      attrs[token.substring(0, eq)] = token.substring(eq + 1);
    }
    return attrs;
  }

  /// The current file text, or null when the file does not exist yet.
  String? read() => file.existsSync() ? file.readAsStringSync() : null;

  /// Atomically replace the file with the canonical rendering of [transcript]
  /// (temp file then rename, like every shared store: C5, C8). Returns the
  /// text written.
  String write(List<Entry> transcript) {
    final text = render(transcript);
    file.parent.createSync(recursive: true);
    final temp = File('${file.path}.tmp');
    temp.writeAsStringSync(text);
    // Windows rename does not replace an existing destination.
    if (Platform.isWindows && file.existsSync()) file.deleteSync();
    temp.renameSync(file.path);
    return text;
  }

  /// A cheap content fingerprint (FNV-1a, 64-bit) used to tell whether the
  /// model edited the file since the harness last wrote it.
  static String fingerprint(String text) {
    var hash = 0xcbf29ce484222325;
    for (final unit in text.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16);
  }

  /// Repair the structure a model edit may have broken, deterministically:
  ///
  /// - every tool call gets exactly one observation, in listed order — a call
  ///   the model left unanswered is given a `[result elided]` placeholder so
  ///   the provider still receives a well-formed exchange;
  /// - an observation whose `id` matches no preceding call becomes a note
  ///   (drop the dangling id), so a stray id can never invalidate a request.
  static List<Entry> normalize(List<Entry> entries) {
    final out = <Entry>[];
    var i = 0;
    while (i < entries.length) {
      final entry = entries[i];
      if (entry is AssistantEntry && entry.action.calls.isNotEmpty) {
        final calls = entry.action.calls;
        final byId = <String, ObservationEntry>{};
        final trailing = <Entry>[];
        var j = i + 1;
        while (j < entries.length && entries[j] is ObservationEntry) {
          final obs = entries[j] as ObservationEntry;
          final id = obs.toolCallId;
          if (id != null && calls.any((call) => call.id == id)) {
            byId[id] = obs;
          } else {
            trailing.add(ObservationEntry(text: obs.text, outcome: obs.outcome));
          }
          j++;
        }
        out.add(entry);
        for (final call in calls) {
          out.add(byId[call.id] ??
              ObservationEntry(
                text: '[result elided]',
                outcome: Outcome.ok,
                toolCallId: call.id,
              ));
        }
        out.addAll(trailing);
        i = j;
        continue;
      }
      if (entry is ObservationEntry && entry.toolCallId != null) {
        // An observation with no matching preceding call: keep its text as a
        // note, drop the dangling id.
        out.add(ObservationEntry(text: entry.text, outcome: entry.outcome));
        i++;
        continue;
      }
      out.add(entry);
      i++;
    }
    return out;
  }
}

/// A block being parsed.
final class _Block {
  _Block(this.role, this.attrs);
  final String role;
  final Map<String, String> attrs;
  final List<String> _lines = [];
  final List<ToolCall> calls = [];

  void add(String line) => _lines.add(line);

  /// The block body, minus the single separating newline the renderer writes
  /// before the next marker.
  String body() {
    final text = _lines.join('\n');
    return text.isEmpty ? '' : text;
  }
}
