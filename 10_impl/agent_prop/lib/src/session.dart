import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'cancellation.dart';
import 'models.dart';
import 'providers/provider.dart';

/// C5: a continuous, persistent session. It holds the transcript and plan
/// that survive across runs and can be resumed by id (see
/// `00_bp/agent_prop/session.schema.json`).
///
/// Persistence is one JSONL file per session under the session directory:
/// the first line is a header object (`type: "header"`) carrying the id,
/// timestamps, workspace, baseline handle, and plan; every following line is
/// one transcript entry.
///
/// The id names the file: `YYMMDD-HHmmSS` (local time) while unnamed, and
/// `YYMMDD-HHmmSS_<keywords>` once an LLM summary produced keywords (at most
/// five, see [summarizeSessionKeywords]). A pinned id (`--session`, C6) is
/// used verbatim and never renamed.
final class Session {
  Session({
    required this.stamp,
    this.keywords = '',
    this.pinned = false,
    required this.workspaceRoot,
    required this.createdAt,
    required this.updatedAt,
    required this.transcript,
    required this.plan,
    this.baseline,
  });

  /// The timestamp part of the id (`YYMMDD-HHmmSS`, local time), or a pinned
  /// caller-chosen id. Grown with a `-2`-style suffix only when a same-second
  /// session would otherwise share the file name.
  String stamp;

  /// The LLM keyword slug appended after the stamp; empty while unnamed.
  String keywords;

  /// True when a caller pinned the id: the id never gains keywords.
  final bool pinned;

  String workspaceRoot;
  DateTime createdAt;
  DateTime updatedAt;
  final List<Entry> transcript;
  List<PlanItem> plan;

  /// Opaque handle to the workspace baseline captured at session open,
  /// backing diff/restore (C3/C5). Refreshed when the workspace root changes;
  /// never shown to the model.
  String? baseline;

  /// The file last written by [save] in this process, so a keyword rename can
  /// remove the file under the previous name. Null until the first save.
  String? _savedPath;

  /// Raised when the user cancels (`/cancel`, a double `Esc`); the loop passes
  /// it into the in-flight call so it aborts at once (C6, C8).
  final CancelSignal cancel = CancelSignal();

  /// The session identity and file name (without extension).
  String get id =>
      pinned || keywords.isEmpty ? stamp : '${stamp}_$keywords';

  factory Session.create({
    required String workspaceRoot,
    String? id,
    DateTime? at,
  }) {
    final now = at ?? DateTime.now();
    return Session(
      stamp: id ?? _newStamp(now),
      pinned: id != null,
      workspaceRoot: workspaceRoot,
      createdAt: now,
      updatedAt: now,
      transcript: <Entry>[],
      plan: <PlanItem>[],
    );
  }

  factory Session.fromJson(Map<String, dynamic> json) => Session(
    stamp: (json['stamp'] as String?) ?? json['id'] as String,
    keywords: json['keywords'] as String? ?? '',
    pinned: json['pinned'] as bool? ?? false,
    workspaceRoot: json['workspace_root'] as String,
    createdAt: DateTime.parse(json['created_at'] as String),
    updatedAt: DateTime.parse(json['updated_at'] as String),
    transcript: [
      for (final entry in (json['transcript'] as List? ?? const []))
        Entry.fromJson((entry as Map).cast<String, dynamic>()),
    ],
    plan: [
      for (final item in (json['plan'] as List? ?? const []))
        PlanItem.fromJson((item as Map).cast<String, dynamic>()),
    ],
    baseline: json['baseline'] as String?,
  );

  /// The header line: everything but the transcript, which the JSONL body
  /// carries one entry per line.
  Map<String, dynamic> headerJson() => {
    'type': 'header',
    'id': id,
    'stamp': stamp,
    if (keywords.isNotEmpty) 'keywords': keywords,
    if (pinned) 'pinned': true,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'workspace_root': workspaceRoot,
    if (baseline != null) 'baseline': baseline,
    'plan': [for (final item in plan) item.toJson()],
  };

  /// The in-memory shape (header + transcript) used by diagnostics and the
  /// gate; not the file layout.
  Map<String, dynamic> toJson() => {
    ...headerJson(),
    'transcript': [for (final entry in transcript) entry.toJson()],
  }..remove('type');

  /// Write this session to [sessionDir] as `<id>.jsonl`; returns the path.
  ///
  /// A keyword rename (or a same-second collision) picks a new file name and
  /// removes the file previously written under the old one. A file that
  /// belongs to a different session is never overwritten: the stamp grows a
  /// numeric suffix instead.
  String save(String sessionDir) {
    final dir = Directory(sessionDir)..createSync(recursive: true);
    final path = _targetPath(dir);
    final body = StringBuffer()
      ..writeln(jsonEncode(headerJson()))
      ..writeAll([
        for (final entry in transcript) '${jsonEncode(entry.toJson())}\n',
      ]);
    File(path).writeAsStringSync(body.toString());
    final previous = _savedPath;
    _savedPath = path;
    if (previous != null && previous != path) {
      final old = File(previous);
      if (old.existsSync()) old.deleteSync();
    }
    _removePreRenameFile(dir, path);
    return path;
  }

  /// The file this save should write, resolving collisions against other
  /// sessions by growing the stamp (`-2`, `-3`, …).
  String _targetPath(Directory dir) {
    var file = File(p.join(dir.path, '$id.jsonl'));
    for (var n = 2; file.existsSync(); n++) {
      if (_isOwnedByThisSession(file)) break;
      stamp = '$stamp-$n';
      file = File(p.join(dir.path, '$id.jsonl'));
    }
    return file.path;
  }

  bool _isOwnedByThisSession(File file) {
    try {
      return Session.load(
        p.dirname(file.path),
        p.basenameWithoutExtension(file.path),
      ).createdAt ==
          createdAt;
    } on Object {
      return false;
    }
  }

  /// After a keyword rename, remove the plain-stamp file this session wrote
  /// before it was named (the in-process path bookkeeping cannot know it
  /// after a resume).
  void _removePreRenameFile(Directory dir, String current) {
    if (keywords.isEmpty) return;
    final plain = File(p.join(dir.path, '$stamp.jsonl'));
    if (!plain.existsSync() || plain.path == current) return;
    try {
      if (Session.load(dir.path, stamp).createdAt == createdAt) {
        plain.deleteSync();
      }
    } on Object {
      // Not ours, or unreadable: leave it alone.
    }
  }

  /// Load a session by [id] from [sessionDir] (`<id>.jsonl`).
  static Session load(String sessionDir, String id) {
    final file = File(p.join(sessionDir, '$id.jsonl'));
    if (!file.existsSync()) {
      throw StateError('session not found: $id');
    }
    Map<String, dynamic>? header;
    final entries = <Entry>[];
    for (final line in file.readAsStringSync().split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final json = (jsonDecode(trimmed) as Map).cast<String, dynamic>();
      if (header == null && json['type'] == 'header') {
        header = json;
        continue;
      }
      entries.add(Entry.fromJson(json));
    }
    if (header == null) {
      throw StateError('session file has no header line: ${file.path}');
    }
    final session = Session.fromJson(header);
    if (entries.isNotEmpty) {
      session.transcript.addAll(entries);
    }
    return session;
  }

  /// List saved session ids in [sessionDir], sorted (the `YYMMDD-HHmmSS`
  /// stamp prefix keeps the order chronological).
  static List<String> list(String sessionDir) {
    final dir = Directory(sessionDir);
    if (!dir.existsSync()) return const [];
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.jsonl'))
        .map((f) => p.basenameWithoutExtension(f.path))
        .toList()
      ..sort();
  }

  /// A new session stamp: the local time as `YYMMDD-HHmmSS`, e.g.
  /// `261020-142530`. Sortable and readable; two sessions opened in the same
  /// second are kept distinct on disk by [save].
  static String _newStamp(DateTime now) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(now.year % 100)}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }
}

/// File-name slug from the model's keyword answer: at most five lowercase
/// alphanumeric words joined by hyphens, capped at 48 characters.
String keywordsToSlug(String raw) {
  final words =
      <String>[
        for (final match in RegExp(r'[a-z0-9]+').allMatches(raw.toLowerCase()))
          match.group(0)!,
      ].take(5).toList();
  var slug = words.join('-');
  while (slug.length > 48 && words.length > 1) {
    words.removeLast();
    slug = words.join('-');
  }
  if (slug.length > 48) slug = slug.substring(0, 48);
  return slug;
}

/// The goal text used to name a session: the first user entry, truncated.
String sessionGoalSummary(Session session) {
  for (final entry in session.transcript) {
    if (entry is UserEntry) {
      final text = entry.text.trim();
      if (text.isNotEmpty) {
        return text.length > 1200 ? text.substring(0, 1200) : text;
      }
    }
  }
  return '';
}

/// The naming prompt: keywords only, so the answer needs no parsing beyond
/// the slug rules.
const String _kNamingPrompt =
    'You name coding-agent session files. From the goal, reply with at most 5 '
    'short lowercase keywords that describe it, separated by single hyphens '
    '(letters and digits only). Reply with the keywords only: no sentence, no '
    'punctuation, no quotes. Example: fix-login-redirect-loop';

/// C5: one-shot LLM naming call. Asks the model to summarize the session's
/// first goal into at most five keywords and returns the file-name slug, or
/// null when nothing usable came back. Errors from the provider propagate to
/// the caller (the agent treats naming as best-effort).
Future<String?> summarizeSessionKeywords({
  required Provider provider,
  required String model,
  required String goal,
  CancelSignal? cancel,
}) async {
  if (goal.isEmpty) return null;
  final response = await provider.complete(
    ProviderRequest(
      model: model,
      system: _kNamingPrompt,
      messages: [UserEntry(goal)],
      tools: const [],
    ),
    cancel: cancel,
  );
  return keywordsToSlug(response.thought);
}
