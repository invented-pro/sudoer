import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'cancellation.dart';
import 'models.dart';

/// C5: a continuous, persistent session. It holds the transcript and plan
/// that survive across runs and can be resumed by id (see
/// `00_bp/agent_prop/session.schema.json`).
final class Session {
  Session({
    required this.id,
    required this.workspaceRoot,
    required this.createdAt,
    required this.updatedAt,
    required this.transcript,
    required this.plan,
    this.baseline,
  });

  final String id;
  String workspaceRoot;
  DateTime createdAt;
  DateTime updatedAt;
  final List<Entry> transcript;
  List<PlanItem> plan;

  /// Opaque handle to the workspace baseline captured at session open,
  /// backing diff/restore (C3/C5). Refreshed when the workspace root changes;
  /// never shown to the model.
  String? baseline;

  /// Raised when the user cancels (`/cancel`, a double `Esc`); the loop passes
  /// it into the in-flight call so it aborts at once (C6, C8).
  final CancelSignal cancel = CancelSignal();

  /// Set when the user authorizes outside-workspace access for this session;
  /// the tool guard reads it so the grant survives an agent rebuild (C6).
  /// Not persisted: a resumed session starts confined again.
  bool allowOutsideWorkspace = false;

  static int _counter = 0;

  factory Session.create({required String workspaceRoot, String? id}) {
    final now = DateTime.now().toUtc();
    return Session(
      id: id ?? _newId(),
      workspaceRoot: workspaceRoot,
      createdAt: now,
      updatedAt: now,
      transcript: <Entry>[],
      plan: <PlanItem>[],
    );
  }

  factory Session.fromJson(Map<String, dynamic> json) => Session(
        id: json['id'] as String,
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

  Map<String, dynamic> toJson() => {
        'id': id,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'workspace_root': workspaceRoot,
        if (baseline != null) 'baseline': baseline,
        'plan': [for (final item in plan) item.toJson()],
        'transcript': [for (final entry in transcript) entry.toJson()],
      };

  /// Write this session to [sessionDir]; returns the file path.
  String save(String sessionDir) {
    final dir = Directory(sessionDir)..createSync(recursive: true);
    final file = File(p.join(dir.path, '$id.json'));
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(toJson()),
    );
    return file.path;
  }

  /// Load a session by [id] from [sessionDir].
  static Session load(String sessionDir, String id) {
    final file = File(p.join(sessionDir, '$id.json'));
    if (!file.existsSync()) {
      throw StateError('session not found: $id');
    }
    return Session.fromJson(
      (jsonDecode(file.readAsStringSync()) as Map).cast<String, dynamic>(),
    );
  }

  /// List saved session ids in [sessionDir], sorted.
  static List<String> list(String sessionDir) {
    final dir = Directory(sessionDir);
    if (!dir.existsSync()) return const [];
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .map((f) => p.basenameWithoutExtension(f.path))
        .toList()
      ..sort();
  }

  static String _newId() =>
      's${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
      '${(_counter++).toRadixString(36)}';
}
