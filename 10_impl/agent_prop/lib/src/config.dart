import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'errors.dart';

/// Provider adapter selected by configuration (C2).
enum ProviderKind { openAiCompatible, ollama }

ProviderKind _parseKind(Object? value) => switch (value) {
      'openai-compatible' => ProviderKind.openAiCompatible,
      'ollama' => ProviderKind.ollama,
      _ => throw ConfigException('provider.kind must be one of '
          '"openai-compatible", "ollama" (got: $value)'),
    };

/// Sampling parameters for the configured model (C2): part of Prop's model
/// config where the adapter supports them. Optional; omitted keys use the
/// endpoint's defaults.
final class SamplingConfig {
  const SamplingConfig({
    this.temperature,
    this.topP,
    this.topK,
    this.seed,
    this.maxTokens,
  });

  final double? temperature;
  final double? topP;
  final int? topK;
  final int? seed;

  /// OpenAI `max_tokens` / ollama `num_predict`.
  final int? maxTokens;

  /// The keys this config accepts, mapping an alias to its canonical name.
  static const Map<String, String> _keys = {
    'temperature': 'temperature',
    'top_p': 'top_p',
    'top_k': 'top_k',
    'seed': 'seed',
    'max_tokens': 'max_tokens',
  };

  factory SamplingConfig.fromJson(Map<String, dynamic> json) {
    for (final key in json.keys) {
      if (!_keys.containsKey(key)) {
        throw ConfigException(
            'provider.sampling.$key is not a sampling parameter '
            '(expected one of: ${_keys.keys.join(', ')})');
      }
    }
    double? asDouble(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! num) {
        throw ConfigException('provider.sampling.$key must be a number');
      }
      return value.toDouble();
    }

    int? asInt(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! int) {
        throw ConfigException('provider.sampling.$key must be an integer');
      }
      return value;
    }

    final temperature = asDouble('temperature');
    if (temperature != null && (temperature < 0 || temperature > 2)) {
      throw const ConfigException(
          'provider.sampling.temperature must be within 0..2');
    }
    final topP = asDouble('top_p');
    if (topP != null && (topP < 0 || topP > 1)) {
      throw const ConfigException('provider.sampling.top_p must be within 0..1');
    }
    final topK = asInt('top_k');
    if (topK != null && topK < 1) {
      throw const ConfigException(
          'provider.sampling.top_k must be an integer >= 1');
    }
    final maxTokens = asInt('max_tokens');
    if (maxTokens != null && maxTokens < 1) {
      throw const ConfigException(
          'provider.sampling.max_tokens must be an integer >= 1');
    }
    return SamplingConfig(
      temperature: temperature,
      topP: topP,
      topK: topK,
      seed: asInt('seed'),
      maxTokens: maxTokens,
    );
  }

  Map<String, dynamic> toJson() => {
        if (temperature != null) 'temperature': temperature,
        if (topP != null) 'top_p': topP,
        if (topK != null) 'top_k': topK,
        if (seed != null) 'seed': seed,
        if (maxTokens != null) 'max_tokens': maxTokens,
      };

  /// The chat-completions body keys for these parameters.
  Map<String, dynamic> openAiJson() => {
        if (temperature != null) 'temperature': temperature,
        if (topP != null) 'top_p': topP,
        if (seed != null) 'seed': seed,
        if (maxTokens != null) 'max_tokens': maxTokens,
      };

  /// The ollama `options` map for these parameters.
  Map<String, dynamic> ollamaJson() => {
        if (temperature != null) 'temperature': temperature,
        if (topP != null) 'top_p': topP,
        if (topK != null) 'top_k': topK,
        if (seed != null) 'seed': seed,
        if (maxTokens != null) 'num_predict': maxTokens,
      };
}

final class ProviderConfig {
  const ProviderConfig({
    required this.kind,
    required this.model,
    required this.contextWindow,
    this.baseUrl,
    this.apiKey,
    this.sampling,
  });

  final ProviderKind kind;
  final String model;
  final int contextWindow;
  final String? baseUrl;
  final String? apiKey;

  /// Optional sampling parameters (C2); null means endpoint defaults.
  final SamplingConfig? sampling;

  /// Parse and validate against `config.schema.json` (hand-checked; the
  /// schema remains the source of truth).
  factory ProviderConfig.fromJson(Map<String, dynamic> json) {
    final kind = _parseKind(json['kind']);
    final model = json['model'];
    if (model is! String || model.isEmpty) {
      throw const ConfigException('provider.model must be a non-empty string');
    }
    final window = json['context_window'];
    if (window is! int || window < 1) {
      throw const ConfigException(
          'provider.context_window must be an integer >= 1');
    }
    final baseUrl = json['base_url'];
    if (baseUrl != null && baseUrl is! String) {
      throw const ConfigException('provider.base_url must be a string');
    }
    if (kind == ProviderKind.openAiCompatible && baseUrl == null) {
      throw const ConfigException(
          'provider.base_url is required for the openai-compatible adapter');
    }
    final apiKey = json['api_key'];
    if (apiKey != null && apiKey is! String) {
      throw const ConfigException('provider.api_key must be a string');
    }
    final sampling = json['sampling'];
    if (sampling != null && sampling is! Map) {
      throw const ConfigException('provider.sampling must be an object');
    }
    return ProviderConfig(
      kind: kind,
      model: model,
      contextWindow: window,
      baseUrl: baseUrl as String?,
      apiKey: apiKey as String?,
      sampling: sampling == null
          ? null
          : SamplingConfig.fromJson(sampling.cast<String, dynamic>()),
    );
  }

  Map<String, dynamic> toJson() => {
        'kind': switch (kind) {
          ProviderKind.openAiCompatible => 'openai-compatible',
          ProviderKind.ollama => 'ollama',
        },
        'model': model,
        'context_window': contextWindow,
        if (baseUrl != null) 'base_url': baseUrl,
        if (apiKey != null) 'api_key': apiKey,
        if (sampling != null) 'sampling': sampling!.toJson(),
      };
}

/// Network capability for the web tools (C3). Enabled and open by default
/// (any host); [denyHosts] is an empty blacklist reserved for later policy. A
/// denial is a hard block — there is no interactive override.
final class WebConfig {
  const WebConfig({
    this.enabled = true,
    this.searchUrl,
    this.denyHosts = const [],
  });

  final bool enabled;

  /// Base URL of a SearXNG instance (or compatible) used by `web_search`; when
  /// absent, `web_fetch` still works but `web_search` reports it is unset.
  final String? searchUrl;

  /// Hosts the model may not reach. Empty by default; an entry may be an exact
  /// host (`example.com`) or a suffix (`.example.com`).
  final List<String> denyHosts;

  factory WebConfig.fromJson(Map<String, dynamic> json) {
    final enabled = json['enabled'];
    if (enabled != null && enabled is! bool) {
      throw const ConfigException('web.enabled must be a boolean');
    }
    final searchUrl = json['search_url'];
    if (searchUrl != null && (searchUrl is! String || searchUrl.isEmpty)) {
      throw const ConfigException(
          'web.search_url must be a non-empty string when set');
    }
    final hosts = json['deny_hosts'];
    if (hosts != null && hosts is! List) {
      throw const ConfigException('web.deny_hosts must be an array of strings');
    }
    return WebConfig(
      enabled: enabled as bool? ?? true,
      searchUrl: searchUrl as String?,
      denyHosts: [
        for (final host in (hosts as List? ?? const []))
          if (host is String && host.isNotEmpty) host,
      ],
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        if (searchUrl != null) 'search_url': searchUrl,
        if (denyHosts.isNotEmpty) 'deny_hosts': denyHosts,
      };
}

/// Which context-management strategy C4 uses (C4). `harness` (the default)
/// fits the prompt with the built-in clip/clear/fold ladder; `clm` gives the
/// model control of its live context through an editable file, following
/// Context Language Models.
enum ContextMode { harness, clm }

ContextMode _parseContextMode(Object? value) => switch (value) {
      null || 'harness' => ContextMode.harness,
      'clm' => ContextMode.clm,
      _ => throw ConfigException(
          'context.mode must be one of "harness", "clm" (got: $value)'),
    };

/// Context assembly and management (C4). `harness` is the default pinned
/// ladder; `clm` mirrors the live context to [file] and lets the model edit
/// it, with optional [strategy] natural-language steering (a context-skills
/// document the model is told to follow).
final class ContextConfig {
  const ContextConfig({
    this.mode = ContextMode.harness,
    this.file,
    this.strategy = '',
  });

  final ContextMode mode;

  /// The live context file (CLM only). Relative paths resolve against the
  /// workspace root; defaults to `<workspace_root>/.sudoer/context.md`.
  final String? file;

  /// Optional natural-language context-management instruction (CLM only),
  /// appended to the CLM prompt section so the user can steer the strategy
  /// without rebuilding the agent.
  final String strategy;

  factory ContextConfig.fromJson(Map<String, dynamic> json) {
    final mode = _parseContextMode(json['mode']);
    final file = json['file'];
    if (file != null && (file is! String || file.isEmpty)) {
      throw const ConfigException(
          'context.file must be a non-empty string when set');
    }
    final strategy = json['strategy'];
    if (strategy != null && strategy is! String) {
      throw const ConfigException('context.strategy must be a string');
    }
    return ContextConfig(
      mode: mode,
      file: file as String?,
      strategy: (strategy as String?) ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'mode': mode == ContextMode.clm ? 'clm' : 'harness',
        if (file != null) 'file': file,
        if (strategy.isNotEmpty) 'strategy': strategy,
      };

  /// A copy with a different [mode], keeping the file and strategy, so the
  /// interface can switch strategy at runtime (`/context clm|harness`, C6).
  ContextConfig copyWith({ContextMode? mode, String? file, String? strategy}) =>
      ContextConfig(
        mode: mode ?? this.mode,
        file: file ?? this.file,
        strategy: strategy ?? this.strategy,
      );
}

final class Config {
  const Config({
    required this.provider,
    required this.workspaceRoot,
    required this.sessionDir,
    this.web = const WebConfig(),
    this.context = const ContextConfig(),
  });

  final ProviderConfig provider;
  final String workspaceRoot;
  final String sessionDir;
  final WebConfig web;
  final ContextConfig context;

  factory Config.fromJson(Map<String, dynamic> json) {
    final expanded = _expandEnvDeep(json);
    final provider = expanded['provider'];
    if (provider is! Map) {
      throw const ConfigException('provider must be an object');
    }
    final root = expanded['workspace_root'];
    if (root != null && (root is! String || root.isEmpty)) {
      throw const ConfigException(
          'workspace_root must be a non-empty string when set');
    }
    // Default to the working directory the agent was invoked from (C6).
    final workspaceRoot =
        p.normalize(p.absolute((root as String?) ?? Directory.current.path));
    final sessionDir = expanded['session_dir'];
    if (sessionDir != null && (sessionDir is! String || sessionDir.isEmpty)) {
      throw const ConfigException(
          'session_dir must be a non-empty string when set');
    }
    final web = expanded['web'];
    if (web != null && web is! Map) {
      throw const ConfigException('web must be an object');
    }
    final context = expanded['context'];
    if (context != null && context is! Map) {
      throw const ConfigException('context must be an object');
    }
    return Config(
      provider: ProviderConfig.fromJson(provider.cast<String, dynamic>()),
      workspaceRoot: workspaceRoot,
      sessionDir:
          (sessionDir as String?) ?? p.join(workspaceRoot, '.sudoer', 'sessions'),
      web: web == null
          ? const WebConfig()
          : WebConfig.fromJson(web.cast<String, dynamic>()),
      context: context == null
          ? const ContextConfig()
          : ContextConfig.fromJson(context.cast<String, dynamic>()),
    );
  }

  Map<String, dynamic> toJson() => {
        'provider': provider.toJson(),
        'workspace_root': workspaceRoot,
        'session_dir': sessionDir,
        'web': web.toJson(),
        'context': context.toJson(),
      };

  /// A copy with a new [workspaceRoot] and/or [context] strategy, keeping the
  /// provider, the session directory, and the network policy fixed for the
  /// process (C6).
  Config copyWith({String? workspaceRoot, ContextConfig? context}) => Config(
        provider: provider,
        workspaceRoot: workspaceRoot ?? this.workspaceRoot,
        sessionDir: sessionDir,
        web: web,
        context: context ?? this.context,
      );

  /// Deep-merge an override map (gate tasks) over this config, then validate.
  Config merge(Map<String, dynamic> override) =>
      Config.fromJson(mergeJson(toJson(), override));

  /// Deep-merge [over] onto [base]; returns a fresh map.
  static Map<String, dynamic> mergeJson(
    Map<String, dynamic> base,
    Map<String, dynamic> over,
  ) {
    final out = Map<String, dynamic>.of(base);
    over.forEach((key, value) {
      final existing = out[key];
      if (existing is Map && value is Map) {
        out[key] = mergeJson(
          existing.cast<String, dynamic>(),
          value.cast<String, dynamic>(),
        );
      } else {
        out[key] = value;
      }
    });
    return out;
  }
}

/// A minimal, copy-pasteable config, matching the example in `README.md`.
const String kSampleConfig = '''
{
  "provider": {
    "kind": "openai-compatible",
    "base_url": "https://api.llm.com/v1",
    "api_key": "your-api-key-here",
    "model": "your-model-name",
    "context_window": 1000000
  },
  "web": {
    "search_url": "https://ws.sudo8.com"
  }
}''';

/// The stderr report for a missing config (C6): where we looked and a sample
/// to create there. Kept in one place so every surface prints it identically.
String missingConfigReport(String path) => '''
config error: config file not found: $path

Create $path with a provider and optional web settings, for example:

$kSampleConfig
''';

/// Load configuration from a JSON file, validating against the schema.
/// Relative path values (`workspace_root`, `session_dir`) are resolved
/// against the config file's directory, so configs stay portable — no
/// absolute machine paths required.
Config loadConfigFile(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw ConfigNotFoundException(path);
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } on FormatException catch (e) {
    throw ConfigException('config is not valid JSON: ${e.message}');
  }
  if (decoded is! Map) {
    throw const ConfigException('config must be a JSON object');
  }
  final expanded = _expandEnvDeep(decoded.cast<String, dynamic>());
  return Config.fromJson(_resolvePaths(expanded,
      p.normalize(p.absolute(file.parent.path))));
}

/// Rewrite relative path values as absolute, anchored at [base] (the
/// config file's directory). Absolute values pass through normalized.
Map<String, dynamic> _resolvePaths(Map<String, dynamic> json, String base) {
  for (final key in const ['workspace_root', 'session_dir']) {
    final value = json[key];
    if (value is String && value.isNotEmpty) {
      json[key] = p.isAbsolute(value)
          ? p.normalize(value)
          : p.normalize(p.join(base, value));
    }
  }
  return json;
}

/// Expand `$VAR` and `${VAR}` references in [value] from the environment.
/// A referenced variable that is unset is an error.
String expandEnv(String value) {
  final pattern =
      RegExp(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)');
  return value.replaceAllMapped(pattern, (match) {
    final name = match.group(1) ?? match.group(2)!;
    final resolved = Platform.environment[name];
    if (resolved == null) {
      throw ConfigException('environment variable not set: $name');
    }
    return resolved;
  });
}

Map<String, dynamic> _expandEnvDeep(Map<String, dynamic> json) =>
    _expandValue(json) as Map<String, dynamic>;

Object? _expandValue(Object? value) {
  if (value is String) return expandEnv(value);
  if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key as String: _expandValue(entry.value),
    };
  }
  if (value is List) return [for (final item in value) _expandValue(item)];
  return value;
}
