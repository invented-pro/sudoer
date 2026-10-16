import '../memory.dart';
import '../models.dart';
import '../safety.dart';
import 'tool.dart';

/// The guard the memory tools carry: the store lives at `memory_dir`, not
/// under a workspace anchor, so the [Tool] base's guard is a root-only
/// placeholder — memory tools never resolve workspace paths.
final _memoryGuard = WorkspaceGuard('.');
/// C9: the memory store's three built-in catalog tools — `memory_write`,
/// `memory_search`, `memory_read` (arguments frozen in
/// `tools-pilot.schema.json`). Observations are scrubbed like every tool's
/// (C10), though notes should never hold secrets.
List<Tool> memoryTools(MemoryStore store, Secrets secrets) => [
      MemoryWriteTool(store, secrets),
      MemorySearchTool(store, secrets),
      MemoryReadTool(store, secrets),
    ];

/// Shared scrubbing: every observation passes the C10 scrubber before it
/// can reach the transcript.
String _scrub(Secrets secrets, String text) => secrets.scrubObservation(text);

/// `memory_write {id?, title, tags?, body}` — creates or updates the note
/// and returns the id (C9: update is replace).
final class MemoryWriteTool extends Tool {
  MemoryWriteTool(this._store, this._secrets) : super(_memoryGuard);

  final MemoryStore _store;
  final Secrets _secrets;

  @override
  String get name => 'memory_write';

  @override
  String get description =>
      'Write a durable memory note (a fact or preference worth keeping '
      'across sessions). Creates or replaces the note with this id and '
      'returns it.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'id': {'type': 'string', 'pattern': r'^[a-z0-9-]+$'},
          'title': {'type': 'string'},
          'tags': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'body': {'type': 'string'},
        },
        'required': ['title', 'body'],
      };

  @override
  String? validate(Map<String, dynamic> arguments) {
    final title = arguments['title'];
    if (title is! String || title.trim().isEmpty) {
      return 'argument title must be a non-empty string';
    }
    final body = arguments['body'];
    if (body is! String || body.trim().isEmpty) {
      return 'argument body must be a non-empty string';
    }
    final id = arguments['id'];
    if (id != null &&
        (id is! String || !RegExp(r'^[a-z0-9-]+$').hasMatch(id))) {
      return 'argument id must match ^[a-z0-9-]+\$';
    }
    final tags = arguments['tags'];
    if (tags != null && tags is! List) {
      return 'argument tags must be an array of strings';
    }
    return null;
  }

  @override
  Future<ToolOutcome> execute(Map<String, dynamic> arguments) async {
    try {
      final note = _store.write(
        title: arguments['title'] as String,
        body: arguments['body'] as String,
        id: arguments['id'] as String?,
        tags: [
          for (final tag in (arguments['tags'] as List? ?? const []))
            if (tag is String && tag.trim().isNotEmpty) tag.trim(),
        ],
        now: DateTime.now().toUtc(),
      );
      return ToolOutcome.ok(_scrub(
          _secrets, 'saved note ${note.id} — ${note.title}'));
    } on Object catch (e) {
      return ToolOutcome.error('memory_write failed: $e');
    }
  }
}

/// `memory_search {query}` — the hybrid, deterministic catalog (C9).
final class MemorySearchTool extends Tool {
  MemorySearchTool(this._store, this._secrets) : super(_memoryGuard);

  final MemoryStore _store;
  final Secrets _secrets;

  @override
  String get name => 'memory_search';

  @override
  String get description =>
      'Search durable memory notes; returns the top hits as '
      '"id — title (score, match)". memory_read a hit for its full body.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
        },
        'required': ['query'],
      };

  @override
  String? validate(Map<String, dynamic> arguments) =>
      arguments['query'] is String ? null : 'argument query must be a string';

  @override
  Future<ToolOutcome> execute(Map<String, dynamic> arguments) async {
    try {
      final hits = _store.search(arguments['query'] as String);
      if (hits.isEmpty) {
        return ToolOutcome.ok(_scrub(_secrets, 'no memory notes matched'));
      }
      return ToolOutcome.ok(
          _scrub(_secrets, [for (final hit in hits) hit.line].join('\n')));
    } on NoteFormatException catch (e) {
      return ToolOutcome.error(e.toString());
    } on Object catch (e) {
      return ToolOutcome.error('memory_search failed: $e');
    }
  }
}

/// `memory_read {id}` — one note's full Markdown body (C9).
final class MemoryReadTool extends Tool {
  MemoryReadTool(this._store, this._secrets) : super(_memoryGuard);

  final MemoryStore _store;
  final Secrets _secrets;

  @override
  String get name => 'memory_read';

  @override
  String get description =>
      'Read one memory note in full by id (from memory_search).';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'id': {'type': 'string', 'pattern': r'^[a-z0-9-]+$'},
        },
        'required': ['id'],
      };

  @override
  String? validate(Map<String, dynamic> arguments) {
    final id = arguments['id'];
    if (id is! String || !RegExp(r'^[a-z0-9-]+$').hasMatch(id)) {
      return 'argument id must match ^[a-z0-9-]+\$';
    }
    return null;
  }

  @override
  Future<ToolOutcome> execute(Map<String, dynamic> arguments) async {
    final id = arguments['id'] as String;
    try {
      final note = _store.read(id);
      if (note == null) {
        return ToolOutcome.error('no memory note with id $id');
      }
      return ToolOutcome.ok(
          _scrub(_secrets, '${note.title}\n\n${note.body}'));
    } on NoteFormatException catch (e) {
      return ToolOutcome.error(e.toString());
    } on Object catch (e) {
      return ToolOutcome.error('memory_read failed: $e');
    }
  }
}

/// Memory tools need no workspace anchor; their store is `memory_dir`. The
/// registry requires a [WorkspaceGuard]; a root-less one is fine because the
/// guard only resolves file paths for the file tools.
