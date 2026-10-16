import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'atomic.dart';
import 'embedder.dart';

/// C9: the durable memory store — one Markdown note per file under
/// `memory_dir`, plus a derived, rebuildable embedding index at
/// `index.json`. Notes are plain files the user may read and edit; the
/// index is never a second source of truth.
final class MemoryNote {
  MemoryNote({
    required this.id,
    required this.title,
    required this.tags,
    required this.created,
    required this.updated,
    required this.body,
  });

  final String id;
  final String title;
  final List<String> tags;
  final DateTime created;
  final DateTime updated;
  final String body;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'tags': tags,
        'created': created.toIso8601String(),
        'updated': updated.toIso8601String(),
        'body': body,
      };

  /// The exact on-disk file shape: `---`, five `key: value` lines (tags
  /// comma-separated), `---`, blank line, Markdown body (memory.schema.json).
  String toFileText() => '---\n'
      'id: $id\n'
      'title: $title\n'
      'tags: ${tags.join(', ')}\n'
      'created: ${created.toIso8601String()}\n'
      'updated: ${updated.toIso8601String()}\n'
      '---\n'
      '\n'
      '$body\n';
}

/// A front-matter parse failure: reported with the file name, never guessed
/// at (C9 — a broken note surfaces, it is not silently skipped).
class NoteFormatException implements Exception {
  NoteFormatException(this.file, this.message);
  final String file;
  final String message;
  @override
  String toString() => 'note format error in $file: $message';
}

/// One memory_search result: hybrid score and how it matched
/// (`memory.schema.json` `searchHit`).
final class SearchHit {
  SearchHit(this.id, this.title, this.score, this.match);
  final String id;
  final String title;
  final double score;
  final String match;

  /// The tool's catalog line: `id — title (score, matched tag or snippet)`.
  String get line {
    final scoreText = score == score.roundToDouble()
        ? score.toStringAsFixed(0)
        : score.toStringAsFixed(4);
    return '$id — $title ($scoreText, $match)';
  }
}

/// The derived embedding index (`memory.schema.json` `embeddingIndex`).
final class EmbeddingIndex {
  EmbeddingIndex({
    required this.model,
    required this.dim,
    required this.hash,
    required this.vectors,
  });

  final String model;
  final int dim;
  final String hash;
  final Map<String, List<double>> vectors;

  factory EmbeddingIndex.fromJson(Map<String, dynamic> json) => EmbeddingIndex(
        model: json['model'] as String,
        dim: json['dim'] as int,
        hash: json['hash'] as String,
        vectors: {
          for (final entry in (json['vectors'] as Map).entries)
            entry.key as String: [
              for (final v in entry.value as List) (v as num).toDouble(),
            ],
        },
      );

  Map<String, dynamic> toJson() => {
        'model': model,
        'dim': dim,
        'hash': hash,
        'vectors': vectors,
      };
}

/// The store. All writes are atomic (temp + rename); reads rescan the
/// directory, so user edits on disk are honored immediately (C9).
final class MemoryStore {
  MemoryStore(this.dir, this.embedder);

  final String dir;
  final Embedder embedder;

  String get _indexPath => p.join(dir, 'index.json');

  /// The note ids the store holds right now, alphabetical (deterministic).
  List<String> ids() {
    final directory = Directory(dir);
    if (!directory.existsSync()) return const [];
    return [
      for (final file in directory.listSync().whereType<File>())
        if (file.path.endsWith('.md'))
          p.basenameWithoutExtension(file.path),
    ]..sort();
  }

  /// Load one note by id, or null when it does not exist.
  MemoryNote? read(String id) {
    final file = File(p.join(dir, '$id.md'));
    if (!file.existsSync()) return null;
    return parseNote(p.basename(file.path), file.readAsStringSync());
  }

  /// Every note, alphabetical by id.
  List<MemoryNote> all() => [
        for (final id in ids()) if (read(id) != null) read(id)!,
      ];

  /// Create or replace a note; update replaces title, tags, and body, stamps
  /// `updated`, preserves `created`, and re-embeds (C9: update is replace).
  /// Returns the stored note.
  MemoryNote write({
    required String title,
    required String body,
    String? id,
    List<String>? tags,
    required DateTime now,
  }) {
    final noteId = id ?? slugFrom(title);
    final existing = read(noteId);
    final note = MemoryNote(
      id: noteId,
      title: title,
      tags: tags ?? const [],
      created: existing?.created ?? now,
      updated: now,
      body: body,
    );
    atomicWrite(p.join(dir, '$noteId.md'), note.toFileText());
    _embedNote(note);
    return note;
  }

  /// The derived index; an absent file is an empty index.
  EmbeddingIndex? loadIndex() {
    final json = readJson(_indexPath);
    if (json == null) return null;
    return EmbeddingIndex.fromJson((json as Map).cast<String, dynamic>());
  }

  /// Rebuild the whole index from the note files (C9: derived and
  /// self-healing). Drops notes deleted on disk; returns the fresh index.
  EmbeddingIndex rebuildIndex() {
    final notes = all();
    final index = EmbeddingIndex(
      model: embedder.model,
      dim: _dim,
      hash: indexHash([
        for (final note in notes) (note.id, note.updated.toIso8601String()),
      ]),
      vectors: {
        for (final note in notes) note.id: _vectorFor(note),
      },
    );
    atomicWrite(_indexPath, jsonEncode(index.toJson()));
    return index;
  }

  /// The index, rebuilt when its digest says it is stale (C9: a note whose
  /// `updated` is newer than its entry, or a missing/changed note, is
  /// re-embedded on the next scan). Returns the up-to-date index.
  EmbeddingIndex ensureIndex() {
    final notes = all();
    final digest = indexHash([
      for (final note in notes) (note.id, note.updated.toIso8601String()),
    ]);
    final existing = loadIndex();
    final sameModel = existing?.model == embedder.model;
    final sameHash = existing?.hash == digest;
    final complete = existing != null &&
        notes.every((note) => existing.vectors.containsKey(note.id));
    if (sameModel && sameHash && complete) return existing;
    return rebuildIndex();
  }

  /// The index rows to rank a query against, refreshed when stale.
  EmbeddingIndex indexForSearch() => ensureIndex();

  int get _dim {
    final existing = loadIndex();
    if (existing != null && existing.vectors.isNotEmpty) {
      return existing.vectors.values.first.length;
    }
    final probe = embedder.embed('dimension probe');
    return probe.isEmpty ? kEmbeddingDim : probe.length;
  }

  List<double> _vectorFor(MemoryNote note) {
    final text = '${note.title}\n${note.tags.join(' ')}\n${note.body}';
    final vector = embedder.embed(text);
    return vector;
  }

  void _embedNote(MemoryNote note) {
    final index = loadIndex();
    final vector = _vectorFor(note);
    final entries = {
      if (index != null) ...index.vectors,
      note.id: vector,
    };
    final fresh = EmbeddingIndex(
      model: embedder.model,
      dim: vector.isEmpty ? kEmbeddingDim : vector.length,
      hash: indexHash([
        for (final note in all()) (note.id, note.updated.toIso8601String()),
      ]),
      vectors: entries,
    );
    atomicWrite(_indexPath, jsonEncode(fresh.toJson()));
  }

  /// Hybrid, deterministic ranking (C9): lexical score (exact tag > title
  /// substring > body substring) plus semantic similarity, normalized and
  /// summed; ties break by id order. Top [kMemoryTopK] hits.
  List<SearchHit> search(String query) {
    ensureIndex();
    final notes = all();
    if (notes.isEmpty) return const [];
    final queryVector = embedder.embed(query);
    final index = indexForSearch();
    final scored = <(double, String, String)>[];
    for (final note in notes) {
      final lexical = _lexicalScore(note, query);
      final vector = index.vectors[note.id];
      final semantic = vector == null ? 0.0 : cosine(queryVector, vector);
      final (score, match) = _combine(lexical, semantic);
      if (score > 0) scored.add((score, note.id, match));
    }
    scored.sort((a, b) {
      final byScore = b.$1.compareTo(a.$1);
      if (byScore != 0) return byScore;
      return a.$2.compareTo(b.$2);
    });
    return [
      for (final (score, id, match) in scored.take(kMemoryTopK))
        SearchHit(id, read(id)!.title, score, match),
    ];
  }

  /// The automatic recall: the same hybrid rank, gated by a relevance floor
  /// so a recall that finds nothing says so (C9).
  List<MemoryNote> recall(String query, {double floor = 0.25}) {
    return [
      for (final hit in search(query))
        if (hit.score >= floor) read(hit.id)!,
    ];
  }
}

/// Lexical match strength: 4 = an exact tag match, 3 = a title substring,
/// 2 = a tag substring, 1 = a body substring, 0 = no lexical match.
(double, String) _combine(
    (int, String?) lexical, double semantic) {
  final (strength, where) = lexical;
  final normalized = strength / 4;
  final score = normalized + semantic;
  final match = switch (where) {
    != null => where,
    _ => semantic >= normalized ? 'semantic' : 'body',
  };
  return (score, match);
}

(int, String?) _lexicalScore(MemoryNote note, String query) {
  final q = query.toLowerCase().trim();
  if (q.isEmpty) return (0, null);
  for (final tag in note.tags) {
    if (tag.toLowerCase() == q) return (4, 'tag');
  }
  if (note.title.toLowerCase().contains(q)) return (3, 'title');
  for (final tag in note.tags) {
    if (tag.toLowerCase().contains(q) || q.contains(tag.toLowerCase())) {
      return (2, 'tag');
    }
  }
  if (note.body.toLowerCase().contains(q)) return (1, 'body');
  // Word-overlap fallback so multi-word queries still score lexically.
  final words = q.split(RegExp(r'\s+')).where((w) => w.length > 2).toSet();
  if (words.isEmpty) return (0, null);
  final haystack =
      '${note.title}\n${note.tags.join(' ')}\n${note.body}'.toLowerCase();
  final hits = words.where(haystack.contains).length / words.length;
  if (hits <= 0) return (0, null);
  return (hits < 0.5 ? 1 : 2, null);
}

/// Parse one note file; [file] names it in errors. Only the fixed-key shape
/// is accepted (C9).
MemoryNote parseNote(String file, String text) {
  final lines = const LineSplitter().convert(text);
  if (lines.isEmpty || lines.first.trim() != '---') {
    throw NoteFormatException(file, 'missing front-matter block');
  }
  final keys = ['id', 'title', 'tags', 'created', 'updated'];
  final values = <String, String>{};
  var index = 1;
  for (final key in keys) {
    if (index >= lines.length || !lines[index].startsWith('$key:')) {
      throw NoteFormatException(file, 'missing front-matter key: $key');
    }
    values[key] = lines[index].substring(key.length + 1).trim();
    index++;
  }
  if (index >= lines.length || lines[index].trim() != '---') {
    throw NoteFormatException(file, 'unterminated front-matter block');
  }
  index++;
  while (index < lines.length && lines[index].trim().isEmpty) {
    index++;
  }
  final idPattern = RegExp(r'^[a-z0-9-]+$');
  final id = values['id']!;
  if (!idPattern.hasMatch(id)) {
    throw NoteFormatException(file, 'id is not a slug: $id');
  }
  final body = lines.skip(index).join('\n');
  return MemoryNote(
    id: id,
    title: values['title']!,
    tags: [
      for (final tag in values['tags']!.split(','))
        if (tag.trim().isNotEmpty) tag.trim(),
    ],
    created: DateTime.parse(values['created']!),
    updated: DateTime.parse(values['updated']!),
    body: body,
  );
}

/// The slug for a title when `memory_write` omits the id (C9).
String slugFrom(String title) {
  final slug = title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return slug.isEmpty ? 'note' : slug;
}
