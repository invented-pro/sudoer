import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Regenerate `lib/src/providers/catalog_generated.dart` from a downloaded
/// `https://models.dev/api.json`.
///
/// Usage:
///   dart run tool/generate_catalog.dart /path/to/models.dev-api.json
///
/// The generated catalog is the OpenAI-compatible provider subset (the source
/// OpenCode uses). Native-protocol providers, providers whose endpoint needs a
/// per-account `${…}` placeholder, entries already hand-curated in
/// `catalog.dart`, and providers with no text model are skipped. Each provider
/// keeps up to 12 of its newest text/tool models; live discovery fills in the
/// rest for reachable endpoints.
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/generate_catalog.dart <api.json>');
    exit(2);
  }
  final input = File(args.single);
  if (!input.existsSync()) {
    stderr.writeln('no such file: ${input.path}');
    exit(2);
  }
  final raw = jsonDecode(input.readAsStringSync());
  if (raw is! Map) {
    stderr.writeln('expected a JSON object');
    exit(2);
  }

  const curated = {
    'openai',
    'anthropic',
    'google',
    'openrouter',
    'groq',
    'deepseek',
    'mistral',
    'xai',
    'zhipuai',
    'moonshotai',
    'minimax',
    'minimax-cn',
    'minimax-coding-plan',
    'minimax-cn-coding-plan',
    'cohere',
    'fireworks-ai',
    'deepinfra',
    'cerebras',
    'ollama-cloud',
    'ollama',
    'lmstudio',
    'custom',
  };
  // Known OpenAI-compatible bases for providers whose models.dev `api` is null
  // because the SDK carries the default.
  const baseOverrides = {
    'togetherai': 'https://api.together.xyz/v1',
    'venice': 'https://api.venice.ai/api/v1',
    'aihubmix': 'https://aihubmix.com/v1',
    'perplexity': 'https://api.perplexity.ai',
  };
  const specialNotes = {
    'github-copilot': 'Requires a GitHub Copilot token; OAuth may be needed.',
  };

  final entries = <_Entry>[];
  for (final item in raw.entries) {
    final id = item.key;
    if (item.value is! Map) continue;
    final provider = (item.value as Map).cast<String, dynamic>();
    if (curated.contains(id)) continue;
    final npm = provider['npm'] as String? ?? '';
    final base = baseOverrides[id] ?? provider['api'] as String? ?? '';
    if (base.isEmpty || base.contains(r'${') || base.startsWith(r'$')) {
      continue;
    }
    final openAiCompatible =
        npm == '@ai-sdk/openai-compatible' ||
        npm == '@ai-sdk/openai' ||
        baseOverrides.containsKey(id);
    if (!openAiCompatible) continue;
    final models = _models(provider['models']);
    if (models.isEmpty) continue;
    final env = [
      for (final value in (provider['env'] as List? ?? const []))
        if (value is String && value.isNotEmpty && !value.contains(r'$')) value,
    ];
    final local = _local(base);
    entries.add(
      _Entry(
        id: id,
        name: provider['name'] as String? ?? id,
        baseUrl: base,
        env: env,
        docs: provider['doc'] as String?,
        local: local,
        note: specialNotes[id],
        models: models,
      ),
    );
  }
  entries.sort((a, b) => a.id.compareTo(b.id));

  final out = StringBuffer()
    ..writeln("part of 'catalog.dart';")
    ..writeln()
    ..writeln(
      '// Generated from https://models.dev/api.json on '
      '${DateTime.now().toIso8601String().split('T').first}.',
    )
    ..writeln('//')
    ..writeln('// The catalog carries the OpenAI-compatible providers from')
    ..writeln('// models.dev (the source OpenCode uses), excluding')
    ..writeln('// native-protocol providers, endpoints that need a per-account')
    ..writeln('// URL, and entries already curated by hand in catalog.dart.')
    ..writeln('// Each provider keeps up to 12 of its newest text/tool models;')
    ..writeln('// live discovery adds the rest when the endpoint is reachable.')
    ..writeln('// Regenerate rather than editing this file:')
    ..writeln('//   dart run tool/generate_catalog.dart <api.json>')
    ..writeln('const List<ProviderPreset> kGeneratedProviderPresets = [');
  for (final entry in entries) {
    out
      ..writeln('  ProviderPreset(')
      ..writeln("    id: ${_q(entry.id)},")
      ..writeln("    name: ${_q(entry.name)},")
      ..writeln('    kind: ProviderKind.openAiCompatible,')
      ..writeln("    baseUrl: ${_q(entry.baseUrl)},");
    if (entry.env.isNotEmpty) {
      out.writeln('    envKeys: [${entry.env.map(_q).join(', ')}],');
    }
    if (entry.local) {
      out
        ..writeln('    local: true,')
        ..writeln('    requiresKey: false,');
    } else {
      out.writeln('    requiresKey: ${entry.env.isNotEmpty},');
    }
    if (entry.docs != null) {
      out.writeln("    docs: ${_q(entry.docs!)},");
    }
    if (entry.note != null) {
      out.writeln("    note: ${_q(entry.note!)},");
    }
    out.writeln('    models: [');
    for (final model in entry.models) {
      out.writeln(
        '      ModelInfo(${_q(model.id)}, ${_q(model.name)}, '
        '${model.context}),',
      );
    }
    out
      ..writeln('    ],')
      ..writeln('  ),');
  }
  out.writeln('];');

  final pkg = p.dirname(p.dirname(Platform.script.toFilePath()));
  final output = File(
    p.join(pkg, 'lib', 'src', 'providers', 'catalog_generated.dart'),
  );
  output.writeAsStringSync(out.toString());
  stdout.writeln(
    'wrote ${output.path}: ${entries.length} providers, '
    '${entries.fold<int>(0, (sum, e) => sum + e.models.length)} models',
  );
}

List<_Model> _models(Object? raw) {
  if (raw is! Map) return const [];
  final rows = <_Model>[];
  for (final value in raw.values) {
    if (value is! Map) continue;
    final model = value.cast<String, dynamic>();
    final status = model['status'];
    if (status == 'deprecated') continue;
    final modalities = model['modalities'];
    if (modalities is! Map) continue;
    final input = modalities['input'];
    final output = modalities['output'];
    if (input is! List || !input.contains('text')) continue;
    if (output is! List || !output.contains('text')) continue;
    final limit = model['limit'];
    final context = limit is Map ? limit['context'] : null;
    if (context is! int || context < 1) continue;
    final id = model['id'];
    if (id is! String || id.isEmpty) continue;
    rows.add(
      _Model(
        id: id,
        name: model['name'] as String? ?? id,
        context: context,
        toolCall: model['tool_call'] == true,
        releaseDate: model['release_date'] as String? ?? '',
      ),
    );
  }
  rows.sort((a, b) {
    final date = b.releaseDate.compareTo(a.releaseDate);
    return date != 0 ? date : b.id.compareTo(a.id);
  });
  final tools = rows.where((model) => model.toolCall).toList();
  return (tools.isEmpty ? rows : tools).take(12).toList();
}

bool _local(String base) {
  final url = base.toLowerCase();
  return url.contains('localhost') ||
      url.contains('127.0.0.1') ||
      url.startsWith('http://0.0.0.0');
}

String _q(String value) =>
    "'${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$').replaceAll('\n', ' ').replaceAll('\r', '')}'";

final class _Entry {
  _Entry({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.env,
    required this.docs,
    required this.local,
    required this.note,
    required this.models,
  });

  final String id;
  final String name;
  final String baseUrl;
  final List<String> env;
  final String? docs;
  final bool local;
  final String? note;
  final List<_Model> models;
}

final class _Model {
  _Model({
    required this.id,
    required this.name,
    required this.context,
    required this.toolCall,
    required this.releaseDate,
  });

  final String id;
  final String name;
  final int context;
  final bool toolCall;
  final String releaseDate;
}
