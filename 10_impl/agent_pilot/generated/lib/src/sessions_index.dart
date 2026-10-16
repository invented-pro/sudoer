import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// C5 Pilot: the derived session index — `index.json` in the session
/// directory, one record per saved session (`http-api.schema.json`
/// `sessionInfo`). Updated atomically whenever a session file is written;
/// rebuilt from the files whenever it is missing. Never a second source of
/// truth.
final class SessionsIndex {
  SessionsIndex(this.dir);

  final String dir;

  String get _path => p.join(dir, 'index.json');

  /// Every record, oldest-first by updated time (deterministic).
  List<Map<String, dynamic>> load() {
    final file = File(_path);
    if (!file.existsSync()) return const [];
    final decoded = jsonDecode(file.readAsStringSync());
    final sessions = decoded['sessions'];
    if (sessions is! List) return const [];
    return [
      for (final session in sessions)
        (session as Map).cast<String, dynamic>(),
    ];
  }

  /// Upsert one session's record and persist the index atomically (C5/C8).
  void upsert({
    required String id,
    required String title,
    required String workspaceRoot,
    String? channel,
    required DateTime created,
    required DateTime updated,
    required int runs,
    String? lastStatus,
  }) {
    final records = [
      for (final record in load())
        if (record['id'] != id) record,
      {
        'id': id,
        'title': title,
        'channel': ?channel,
        'workspace_root': workspaceRoot,
        'created': created.toIso8601String(),
        'updated': updated.toIso8601String(),
        'runs': runs,
        'last_status': ?lastStatus,
      },
    ];
    records.sort((a, b) =>
        (a['updated'] as String).compareTo(b['updated'] as String));
    final file = File(_path);
    if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
    final temp = File('$_path.tmp');
    temp.writeAsStringSync(
        jsonEncode({'sessions': records, 'version': 1}));
    temp.renameSync(_path);
  }

  /// One record by id, or null.
  Map<String, dynamic>? byId(String id) {
    for (final record in load()) {
      if (record['id'] == id) return record;
    }
    return null;
  }

  /// The session id bound to [channel], or null (C5: channel-keyed
  /// sessions; the mapping lives in the derived index).
  String? sessionForChannel(String channel) {
    for (final record in load()) {
      if (record['channel'] == channel) return record['id'] as String;
    }
    return null;
  }

  /// Deterministic search (C5): filter the index by id, title substring, or
  /// date, top-10, then optionally grep matching session files' transcripts.
  List<Map<String, dynamic>> search(String? query, {int limit = 10}) {
    final records = load().reversed.toList(); // newest first
    if (query == null || query.trim().isEmpty) {
      return records.take(limit).toList();
    }
    final q = query.trim().toLowerCase();
    final hits = <Map<String, dynamic>>[
      for (final record in records)
        if ((record['id'] as String).toLowerCase().contains(q) ||
            (record['title'] as String).toLowerCase().contains(q) ||
            (record['updated'] as String).contains(q))
          record,
    ];
    return hits.take(limit).toList();
  }
}

/// The title for a session: its first goal's first line (C5).
String sessionTitle(String goal) {
  final firstLine = goal.trim().split('\n').first.trim();
  return firstLine.isEmpty ? '(empty)' : firstLine;
}
