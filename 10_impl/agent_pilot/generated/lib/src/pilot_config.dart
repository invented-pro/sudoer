
import 'package:path/path.dart' as p;

import 'config.dart';
import 'errors.dart';

/// C2: an ordered provider chain. Index 0 is primary; later entries are
/// failover targets in order. The Prop `provider` key stays valid as the
/// one-element form; a process sets one or the other, never both.
List<ProviderConfig> providerChainFromJson(Map<String, dynamic> json) {
  final single = json['provider'];
  final chain = json['providers'];
  if (single != null && chain != null) {
    throw const ConfigException(
        'set `provider` or `providers`, never both (C2)');
  }
  final entries = <dynamic>[
    if (chain != null) ...chain as List,
    if (chain == null && single != null) single,
  ];
  if (entries.isEmpty) {
    throw const ConfigException('provider must be an object');
  }
  return [
    for (final entry in entries)
      ProviderConfig.fromJson((entry as Map).cast<String, dynamic>()),
  ];
}

/// C2: the named role catalog — `main` (default index 0) serves the loop;
/// `fast`, when set, serves the tools-withheld compaction brief; `embed`,
/// when set, is the memory embedder's provider+model. A role may override
/// the entry's model.
final class RoleConfig {
  RoleConfig({required this.provider, this.model});
  final int provider;
  final String? model;

  factory RoleConfig.fromJson(Map<String, dynamic> json) {
    final provider = json['provider'];
    if (provider is! int || provider < 0) {
      throw const ConfigException('role.provider must be a chain index >= 0');
    }
    final model = json['model'];
    if (model != null && (model is! String || model.isEmpty)) {
      throw const ConfigException('role.model must be a non-empty string');
    }
    return RoleConfig(provider: provider, model: model as String?);
  }

  Map<String, dynamic> toJson() => {
        'provider': provider,
        if (model != null) 'model': model,
      };
}

/// C10: one confirm matcher — a tool name and an optional argument substring.
final class ConfirmMatcherConfig {
  ConfirmMatcherConfig({required this.tool, this.arg});
  final String tool;
  final String? arg;

  factory ConfirmMatcherConfig.fromJson(Map<String, dynamic> json) {
    final tool = json['tool'];
    if (tool is! String || tool.isEmpty) {
      throw const ConfigException('policy.confirm[].tool must be a non-empty string');
    }
    return ConfirmMatcherConfig(tool: tool, arg: json['arg'] as String?);
  }

  Map<String, dynamic> toJson() => {
        'tool': tool,
        if (arg != null) 'arg': arg,
      };
}

/// C6: one registered channel (`channel.schema.json` `channel`).
final class ChannelConfig {
  ChannelConfig({
    required this.id,
    this.kind,
    this.outboundUrl,
    this.outboundSecret,
    this.allowFrom = const [],
    this.enabled = true,
  });

  final String id;
  final String? kind;
  final String? outboundUrl;
  final String? outboundSecret;
  final List<String> allowFrom;
  final bool enabled;

  factory ChannelConfig.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || !RegExp(r'^[a-z0-9][a-z0-9-]*$').hasMatch(id)) {
      throw const ConfigException(
          'channel id must match ^[a-z0-9][a-z0-9-]*\$');
    }
    return ChannelConfig(
      id: id,
      kind: json['kind'] as String?,
      outboundUrl: json['outbound_url'] as String?,
      outboundSecret: json['outbound_secret'] as String?,
      allowFrom: [
        for (final from in (json['allow_from'] as List? ?? const []))
          from as String,
      ],
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        if (kind != null) 'kind': kind,
        if (outboundUrl != null) 'outbound_url': outboundUrl,
        if (outboundSecret != null) 'outbound_secret': outboundSecret,
        if (allowFrom.isNotEmpty) 'allow_from': allowFrom,
        'enabled': enabled,
      };
}

/// C9: the memory embedder selection (`config-pilot.schema.json` `embedder`).
final class EmbedderConfig {
  EmbedderConfig({required this.kind, this.baseUrl, this.model});
  final String kind;
  final String? baseUrl;
  final String? model;

  factory EmbedderConfig.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'];
    if (kind is! String || !const ['ollama', 'local', 'none'].contains(kind)) {
      throw const ConfigException(
          'memory.embedder.kind must be "ollama", "local", or "none"');
    }
    return EmbedderConfig(
      kind: kind,
      baseUrl: json['base_url'] as String?,
      model: json['model'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'kind': kind,
        if (baseUrl != null) 'base_url': baseUrl,
        if (model != null) 'model': model,
      };
}

/// The Pilot configuration object (`config-pilot.schema.json`): every Prop
/// key keeps its meaning; Pilot adds the chain and roles, the anchor list,
/// memory, tasks and autonomy, policy and secrets, the REST server, the
/// channel registry, and the structured log destination.
final class PilotConfig {
  PilotConfig({
    required this.chain,
    required this.roles,
    required this.workspaceRoots,
    required this.sessionDir,
    required this.memoryDir,
    required this.embedder,
    required this.tasksFile,
    this.catchUp = 'report',
    required this.secretsFile,
    required this.networkDenyHosts,
    required this.networkAllowHosts,
    required this.confirmMatchers,
    required this.policyLog,
    required this.httpBind,
    required this.httpPort,
    this.httpToken,
    required this.channels,
    required this.logFile,
    required this.web,
  });

  final List<ProviderConfig> chain;
  final Map<String, RoleConfig> roles;
  final List<String> workspaceRoots;
  final String sessionDir;
  final String memoryDir;
  final EmbedderConfig? embedder;
  final String tasksFile;
  final String catchUp;
  final String secretsFile;
  final List<String> networkDenyHosts;
  final List<String> networkAllowHosts;
  final List<ConfirmMatcherConfig> confirmMatchers;
  final String policyLog;
  final String httpBind;
  final int httpPort;
  final String? httpToken;
  final List<ChannelConfig> channels;
  final String logFile;
  final WebConfig web;

  String get primaryRoot => workspaceRoots.first;

  ProviderConfig get primary => chain.isNotEmpty ? chain.first : chainProvider;

  /// Never reached: [PilotConfig.fromJson] requires a chain.
  ProviderConfig get chainProvider => throw StateError('no provider');

  /// The effective model for a role name, resolving the chain index and the
  /// role's optional model override (C2).
  String modelFor(String role, String fallback) {
    final config = roles[role];
    if (config == null || config.provider >= chain.length) return fallback;
    return config.model ?? chain[config.provider].model;
  }

  /// The effective context window for a role (the entry's, per the schema).
  int windowFor(String role) {
    final config = roles[role];
    if (config == null || config.provider >= chain.length) {
      return primary.contextWindow;
    }
    return chain[config.provider].contextWindow;
  }

  /// The JSON view `GET /config` serves: the effective non-secret config.
  Map<String, dynamic> view() => toJson();

  Map<String, dynamic> toJson() => {
        'provider': chain.first.toJson(),
        if (chain.length > 1)
          'providers': [for (final entry in chain) entry.toJson()],
        if (roles.isNotEmpty) 'roles': {
          for (final entry in roles.entries) entry.key: entry.value.toJson(),
        },
        'workspace_roots': workspaceRoots,
        'session_dir': sessionDir,
        'memory_dir': memoryDir,
        'memory': {
          'embedder': (embedder ??
              EmbedderConfig(kind: 'local', model: 'local-hash-v1'))
              .toJson(),
        },
        'tasks_file': tasksFile,
        'autonomy': {'catch_up': catchUp},
        'secrets_file': secretsFile,
        'policy': {
          'network': {
            'deny_hosts': networkDenyHosts,
            'allow_hosts': networkAllowHosts,
          },
          if (confirmMatchers.isNotEmpty)
            'confirm': [
              for (final matcher in confirmMatchers) matcher.toJson(),
            ],
          'log': policyLog,
        },
        'http': {
          'bind': httpBind,
          'port': httpPort,
          if (httpToken != null) 'token': httpToken,
        },
        'channels': [for (final channel in channels) channel.toJson()],
        'log_file': logFile,
        'web': web.toJson(),
      };

  /// Validate and build from a (deep-merged) config object.
  factory PilotConfig.fromJson(Map<String, dynamic> json,
      {required String defaultRoot}) {
    final chain = providerChainFromJson(json);

    final rootsRaw = json['workspace_roots'];
    final rootSingle = json['workspace_root'];
    final roots = <String>[
      if (rootsRaw is List)
        for (final root in rootsRaw) _abs(root as String, defaultRoot),
      if (rootsRaw == null && rootSingle is String)
        _abs(rootSingle, defaultRoot),
    ];
    if (roots.isEmpty) roots.add(p.normalize(p.absolute(defaultRoot)));

    String defaultUnder(String key, String Function() compute) {
      final value = json[key];
      if (value is String && value.isNotEmpty) return _abs(value, defaultRoot);
      return compute();
    }

    final rolesRaw = json['roles'];
    final roles = <String, RoleConfig>{
      if (rolesRaw is Map)
        for (final entry in rolesRaw.entries)
          entry.key as String: RoleConfig.fromJson(
              (entry.value as Map).cast<String, dynamic>()),
    };

    final memory = json['memory'];
    final embedderRaw = memory is Map ? memory['embedder'] : null;
    final embedder = embedderRaw == null
        ? null
        : EmbedderConfig.fromJson((embedderRaw as Map).cast<String, dynamic>());

    final autonomy = json['autonomy'];
    final catchUp = autonomy is Map ? autonomy['catch_up'] : null;
    if (catchUp != null && catchUp != 'fire' && catchUp != 'report') {
      throw const ConfigException('autonomy.catch_up must be "fire" or "report"');
    }

    final policy = json['policy'];
    final network = policy is Map ? policy['network'] : null;
    final confirm = policy is Map ? policy['confirm'] : null;
    List<String> hostList(String key) => [
          for (final host in (network is Map ? network[key] as List? : null) ??
              const [])
            if (host is String && host.isNotEmpty) host,
        ];

    final http = json['http'];
    final token = http is Map ? http['token'] : null;
    if (token != null && (token is! String || token.length < 16)) {
      throw const ConfigException('http.token must be a string of >= 16 chars');
    }
    final bind = http is Map ? http['bind'] : null;
    if (bind != null && bind is! String) {
      throw const ConfigException('http.bind must be a string');
    }
    final port = http is Map ? http['port'] : null;
    if (port != null && (port is! int || port < 0 || port > 65535)) {
      throw const ConfigException('http.port must be an integer 0..65535');
    }

    final webRaw = json['web'];
    final web = webRaw == null
        ? const WebConfig()
        : WebConfig.fromJson((webRaw as Map).cast<String, dynamic>());

    return PilotConfig(
      chain: chain,
      roles: roles,
      workspaceRoots: roots,
      sessionDir: defaultUnder(
          'session_dir', () => p.join(roots.first, '.sudoer', 'sessions')),
      memoryDir:
          defaultUnder('memory_dir', () => p.join(roots.first, '.sudoer', 'memory')),
      embedder: embedder,
      tasksFile:
          defaultUnder('tasks_file', () => p.join(roots.first, '.sudoer', 'tasks.json')),
      catchUp: catchUp as String? ?? 'report',
      secretsFile: defaultUnder(
          'secrets_file', () => p.join(roots.first, '.sudoer', 'secrets.json')),
      networkDenyHosts: hostList('deny_hosts'),
      networkAllowHosts: hostList('allow_hosts'),
      confirmMatchers: [
        for (final matcher in (confirm as List? ?? const []))
          ConfirmMatcherConfig.fromJson((matcher as Map).cast<String, dynamic>()),
      ],
      policyLog:
          defaultUnder('policy', () => p.join(roots.first, '.sudoer', 'policy.log')),
      httpBind: (bind as String?) ?? '127.0.0.1',
      httpPort: port ?? 7363,
      httpToken: token as String?,
      channels: [
        for (final channel in (json['channels'] as List? ?? const []))
          ChannelConfig.fromJson((channel as Map).cast<String, dynamic>()),
      ],
      logFile: defaultUnder('log_file',
          () => p.join(roots.first, '.sudoer', 'logs', 'agent.jsonl')),
      web: web,
    );
  }

  static String _abs(String value, String base) => p.isAbsolute(value)
      ? p.normalize(value)
      : p.normalize(p.join(base, value));
}
