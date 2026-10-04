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

final class ProviderConfig {
  const ProviderConfig({
    required this.kind,
    required this.model,
    required this.contextWindow,
    this.baseUrl,
    this.apiKey,
  });

  final ProviderKind kind;
  final String model;
  final int contextWindow;
  final String? baseUrl;
  final String? apiKey;

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
    return ProviderConfig(
      kind: kind,
      model: model,
      contextWindow: window,
      baseUrl: baseUrl as String?,
      apiKey: apiKey as String?,
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

final class Config {
  const Config({
    required this.provider,
    required this.workspaceRoot,
    required this.sessionDir,
    this.web = const WebConfig(),
  });

  final ProviderConfig provider;
  final String workspaceRoot;
  final String sessionDir;
  final WebConfig web;

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
    return Config(
      provider: ProviderConfig.fromJson(provider.cast<String, dynamic>()),
      workspaceRoot: workspaceRoot,
      sessionDir:
          (sessionDir as String?) ?? p.join(workspaceRoot, '.sudoer', 'sessions'),
      web: web == null
          ? const WebConfig()
          : WebConfig.fromJson(web.cast<String, dynamic>()),
    );
  }

  Map<String, dynamic> toJson() => {
        'provider': provider.toJson(),
        'workspace_root': workspaceRoot,
        'session_dir': sessionDir,
        'web': web.toJson(),
      };

  /// A copy with a new [workspaceRoot], keeping the provider, the session
  /// directory, and the network policy fixed for the process (C6).
  Config copyWith({String? workspaceRoot}) => Config(
        provider: provider,
        workspaceRoot: workspaceRoot ?? this.workspaceRoot,
        sessionDir: sessionDir,
        web: web,
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
  return Config.fromJson(decoded.cast<String, dynamic>());
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
