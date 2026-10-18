import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'auth.dart';

/// C2: best-effort discovery of the models an endpoint actually serves.
///
/// The static catalog is the offline fallback; a reachable endpoint's
/// `GET /models` (OpenAI-compatible) or `GET /api/tags` (ollama) gives the
/// live list. Known ids keep their curated name and context window; unknown
/// ids get the id as the label and a conservative fallback window. Discovery
/// never decides the model — it only feeds the selection UI.

/// Parse an OpenAI-compatible `GET /models` body into model ids.
List<String> parseOpenAiModels(String body) {
  final decoded = jsonDecode(body);
  final data = decoded is Map ? decoded['data'] : decoded;
  if (data is! List) return const [];
  final ids = <String>[];
  for (final item in data) {
    if (item is String && item.isNotEmpty) {
      ids.add(item);
    } else if (item is Map && item['id'] is String) {
      final id = item['id'] as String;
      if (id.isNotEmpty) ids.add(id);
    }
  }
  return ids;
}

/// Parse an ollama `GET /api/tags` body into model names.
List<String> parseOllamaModels(String body) {
  final decoded = jsonDecode(body);
  final models = decoded is Map ? decoded['models'] : null;
  if (models is! List) return const [];
  final ids = <String>[];
  for (final item in models) {
    if (item is Map) {
      final name = item['name'] ?? item['model'];
      if (name is String && name.isNotEmpty) ids.add(name);
    }
  }
  return ids;
}

/// Merge a live id list over [preset]'s static catalog. An empty [live] list
/// returns the static catalog unchanged (discovery found nothing).
List<ModelInfo> mergeModels(
  Iterable<String> live,
  ProviderPreset preset, {
  int fallbackWindow = kDefaultContextWindow,
}) {
  final ids = live.toList();
  if (ids.isEmpty) return preset.models;
  final liveSet = ids.toSet();
  final out = <ModelInfo>[];
  final seen = <String>{};
  // Curated entries first, in catalog order, when the endpoint serves them.
  for (final model in preset.models) {
    if (liveSet.contains(model.id) && seen.add(model.id)) out.add(model);
  }
  // Everything else the endpoint reported, alphabetically.
  final rest = [for (final id in ids) if (seen.add(id)) id]..sort();
  for (final id in rest) {
    out.add(ModelInfo(
      id,
      id,
      preset.model(id)?.contextWindow ?? fallbackWindow,
    ));
  }
  return out;
}

/// Build an ad-hoc preset for a config that predates presets (or names an
/// endpoint not in the catalog), so discovery and listing still work.
ProviderPreset presetForConfig(ProviderConfig config) {
  final known = providerPreset(config.preset);
  if (known != null) return known;
  return ProviderPreset(
    id: config.preset ?? 'custom',
    name: config.preset ?? config.display,
    kind: config.kind,
    baseUrl: config.baseUrl,
    models: const [],
    requiresKey: false,
  );
}

/// Fetch the endpoint's live model list. Throws on a transport error or a
/// non-200 status; callers fall back to [preset.models].
Future<List<ModelInfo>> discoverModels(
  ProviderPreset preset, {
  String? apiKey,
  http.Client? client,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final base = preset.baseUrl?.replaceAll(RegExp(r'/+$'), '');
  if (base == null || base.isEmpty) return preset.models;
  final httpClient = client ?? http.Client();
  try {
    if (preset.kind == ProviderKind.ollama) {
      final response =
          await httpClient.get(Uri.parse('$base/api/tags')).timeout(timeout);
      if (response.statusCode != 200) {
        throw HttpException(
            'model discovery failed: HTTP ${response.statusCode}');
      }
      return mergeModels(parseOllamaModels(response.body), preset);
    }
    final key = apiKey?.trim();
    if (key != null && key.isNotEmpty) {
      final problem = apiKeyProblem(key);
      if (problem != null) {
        throw FormatException('invalid API key: $problem');
      }
    }
    final response = await httpClient.get(
      Uri.parse('$base/models'),
      headers: {
        if (key != null && key.isNotEmpty) 'authorization': 'Bearer $key',
      },
    ).timeout(timeout);
    if (response.statusCode != 200) {
      final hint = (response.statusCode == 401 || response.statusCode == 403) &&
              key != null &&
              key.isNotEmpty
          ? minimaxRegionHint(presetId: preset.id, baseUrl: preset.baseUrl)
          : '';
      throw HttpException(
          'model discovery failed: HTTP ${response.statusCode}'
          '${hint.isEmpty ? '' : ' $hint'}');
    }
    return mergeModels(parseOpenAiModels(response.body), preset);
  } finally {
    if (client == null) httpClient.close();
  }
}
