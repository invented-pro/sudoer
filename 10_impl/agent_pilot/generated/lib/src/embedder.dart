import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

/// C9: the memory embedder, an injected adapter. `kind` selects the source
/// (`ollama` endpoint, the bundled `local` deterministic model, or `none`);
/// any failure or absence degrades to the deterministic [lexicalEmbed]
/// fallback and is reported (`degraded`) — retrieval never fails.
abstract class Embedder {
  Embedder(this.model);

  /// The embedder identity recorded in the index; a change invalidates it.
  final String model;

  /// True when this call is running on the lexical fallback instead of the
  /// configured source (C9: degradation is reported, not silent).
  bool degraded = false;

  List<double> embed(String text);
}

/// The deterministic gate embedder: a fixed hash-to-vector function, so
/// "similar" notes can be authored to collide and ranking is byte-stable.
/// Model identity `fake-embed` (pinned by the gate tasks).
final class FakeEmbedder extends Embedder {
  FakeEmbedder() : super('fake-embed');

  @override
  List<double> embed(String text) => fakeEmbed(text);
}

/// The lexical fallback: hashed bag-of-words, deterministic everywhere.
final class LexicalEmbedder extends Embedder {
  LexicalEmbedder() : super('lexical-fallback') {
    degraded = true;
  }

  @override
  List<double> embed(String text) => lexicalEmbed(text);
}

/// `none`: no semantic path; lexical only (reported, not silent).
final class NoEmbedder extends Embedder {
  NoEmbedder() : super('none') {
    degraded = true;
  }

  @override
  List<double> embed(String text) => lexicalEmbed(text);
}

/// The bundled on-device model: a deterministic hashing embedder shipped
/// with the build — offline, byte-stable, no download.
final class LocalEmbedder extends Embedder {
  LocalEmbedder() : super('local-hash-v1');

  @override
  List<double> embed(String text) => hashEmbed(text, 0x9e3779b9);
}

/// A real embedder over an ollama-compatible `/api/embeddings` endpoint
/// (the default `memory.embedder`). Bounded by a short timeout; a transport
/// failure or malformed reply degrades to the lexical fallback and reports
/// it, so memory retrieval never fails (C9).
final class OllamaEmbedder extends Embedder {
  OllamaEmbedder({required this.baseUrl, required String modelName})
      : super(modelName);

  final String baseUrl;

  static const _timeout = Duration(seconds: 5);

  @override
  List<double> embed(String text) {
    final client = http.Client();
    try {
      final response = client.post(
        Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/api/embeddings'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'model': model, 'prompt': text}),
      ).timeout(_timeout);
      final decoded = jsonDecode((response as http.Response).body);
      final embedding = decoded['embedding'];
      if (embedding is List && embedding.isNotEmpty) {
        return [for (final v in embedding) (v as num).toDouble()];
      }
    } on Object {
      // fall through to the deterministic fallback
    } finally {
      client.close();
    }
    degraded = true;
    return lexicalEmbed(text);
  }
}

/// The embedding dimension used by every bundled/fake embedder. A real
/// endpoint's vectors keep their own dimension (recorded in the index).
const int kEmbeddingDim = 16;

/// Top-K notes recalled/injected/searched — compiled-in (C9, gate table).
const int kMemoryTopK = 10;

/// The C9 lexical fallback: a hashed bag-of-words vector, deterministic on
/// every platform (FNV-1a word hashing, L2-normalized).
List<double> lexicalEmbed(String text) => hashEmbed(text, 0x811c9dc5);

/// The gate's fake semantic embedder: a different fixed hash seed than the
/// lexical fallback, so the two are distinguishable while both stay
/// deterministic and collision-tunable by word choice.
List<double> fakeEmbed(String text) => hashEmbed(text, 0x9e3779b9);

/// The shared deterministic hashing embedder. Seeded FNV-1a per word, mixed
/// into [kEmbeddingDim] buckets, L2-normalized.
List<double> hashEmbed(String text, int seed) {
  final vector = List<double>.filled(kEmbeddingDim, 0);
  final words = text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty);
  for (final word in words) {
    var hash = seed;
    for (final code in word.codeUnits) {
      hash ^= code;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
      hash = ((hash << 13) | (hash >> 19)) & 0xFFFFFFFF;
    }
    vector[hash % kEmbeddingDim] += 1;
  }
  final norm = math.sqrt(vector.fold<double>(0, (sum, v) => sum + v * v));
  if (norm == 0) return vector;
  return [for (final v in vector) v / norm];
}

/// Cosine similarity over two equal-length vectors; 0 on mismatch or when
/// either is the zero vector.
double cosine(List<double> a, List<double> b) {
  if (a.length != b.length || a.isEmpty) return 0;
  var dot = 0.0;
  var na = 0.0;
  var nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na == 0 || nb == 0) return 0;
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

/// Build an [Embedder] from the `memory.embedder` config shape. [fallback]
/// (harness-only, never config-reachable) forces the lexical path for the
/// gate's `embedder: "fallback"` tasks.
Embedder embedderFromConfig(Map<String, dynamic>? json, {bool fallback = false}) {
  if (fallback) return LexicalEmbedder();
  final kind = json?['kind'];
  return switch (kind) {
    'none' => NoEmbedder(),
    'local' => LocalEmbedder(),
    'ollama' => OllamaEmbedder(
        baseUrl: (json?['base_url'] as String?) ?? 'http://localhost:11434',
        modelName: (json?['model'] as String?) ?? 'nomic-embed-text',
      ),
    // Unset kind: the local default — the bundled deterministic model.
    _ => LocalEmbedder(),
  };
}

/// A stable digest of the (note ids + updated timestamps) set, so index
/// staleness is detectable (C9). Order-independent; not a secret.
String indexHash(Iterable<(String, String)> entries) {
  final sorted = entries.map((e) => '${e.$1}\u0000${e.$2}').toList()..sort();
  var hash = 0xcbf29ce484222325;
  for (final line in sorted) {
    for (final code in utf8.encode(line)) {
      hash ^= code;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
  }
  return hash.toRadixString(36);
}
