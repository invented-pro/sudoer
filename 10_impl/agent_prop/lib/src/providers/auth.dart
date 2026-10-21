import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';

/// C2: the local credential store for provider keys.
///
/// Keys entered with `sudoer-prop --setup` are written here, not into the
/// project config, so a config can be shared or committed without a secret.
/// The file is JSON with one entry per provider preset:
///
/// ```json
/// {
///   "openai": { "type": "api", "key": "sk-…" },
///   "anthropic": { "type": "api", "key": "sk-ant-…" }
/// }
/// ```
///
/// On POSIX it is created owner-only (0600 in a 0700 directory). The file is
/// read tolerantly: a bare string value is accepted as the key, and a corrupt
/// file reads as "no stored keys" rather than breaking the CLI.
final class AuthStore {
  AuthStore({String? path}) : path = path ?? defaultAuthPath();

  final String path;

  /// `<app dir>/auth.json` — `~/.config/sudoer/auth.json` on POSIX (XDG),
  /// `%APPDATA%\sudoer\auth.json` on Windows; see [defaultAppDir].
  /// `SUDOER_AUTH_FILE` overrides the location, which is also the seam used
  /// by tests.
  static String defaultAuthPath() {
    final override = Platform.environment['SUDOER_AUTH_FILE'];
    if (override != null && override.isNotEmpty) {
      return p.normalize(p.absolute(override));
    }
    return p.join(defaultAppDir(), 'auth.json');
  }

  /// Every stored key, keyed by provider preset id.
  Map<String, String> read() {
    final file = File(path);
    if (!file.existsSync()) return <String, String>{};
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return <String, String>{};
      final keys = <String, String>{};
      decoded.forEach((id, value) {
        if (id is! String) return;
        if (value is String && value.isNotEmpty) {
          keys[id] = value;
        } else if (value is Map && value['key'] is String) {
          final key = value['key'] as String;
          if (key.isNotEmpty) keys[id] = key;
        }
      });
      return keys;
    } on Object {
      // A corrupt store is not a reason to fail a run: fall through to the
      // environment/config. The next write repairs the file.
      return <String, String>{};
    }
  }

  String? keyFor(String providerId) => read()[providerId];

  bool has(String providerId) => keyFor(providerId) != null;

  /// Store [key] for [providerId]; an empty key removes the entry.
  void setKey(String providerId, String key) {
    if (key.isEmpty) {
      remove(providerId);
      return;
    }
    final keys = read()..[providerId] = key;
    _write(keys);
  }

  void remove(String providerId) {
    final keys = read();
    if (keys.remove(providerId) == null) return;
    _write(keys);
  }

  void _write(Map<String, String> keys) {
    final file = File(path);
    // Create the directory owner-only first, then the file, so there is no
    // window in which a readable directory exposes the store.
    file.parent.createSync(recursive: true);
    if (!Platform.isWindows) {
      try {
        Process.runSync('chmod', ['700', file.parent.path]);
      } on Object {
        // Not fatal: the file's own mode below is the important one.
      }
    }
    final json = const JsonEncoder.withIndent('  ').convert({
      for (final entry in keys.entries)
        entry.key: {'type': 'api', 'key': entry.value},
    });
    final temp = File('${file.path}.tmp');
    temp.writeAsStringSync('$json\n');
    // Windows rename does not replace an existing destination.
    if (Platform.isWindows && file.existsSync()) file.deleteSync();
    temp.renameSync(file.path);
    if (!Platform.isWindows) {
      try {
        Process.runSync('chmod', ['600', file.path]);
      } on Object {
        // Best effort (e.g. a filesystem without POSIX modes).
      }
    }
  }
}

/// A one-line reason [key] cannot be used as an HTTP bearer token, or null.
///
/// API keys are printable ASCII with no whitespace. This catches a pasted
/// terminal transcript (or a multi-line blob) before it reaches an HTTP
/// header, where it would otherwise surface as an opaque `FormatException`.
/// The returned message never includes the key.
String? apiKeyProblem(String? key) {
  if (key == null) return null;
  final value = key.trim();
  if (value.isEmpty) return 'the key is empty';
  if (value.length > 4096) {
    return 'the key is too long (over 4096 characters)';
  }
  for (final rune in value.runes) {
    if (rune < 0x21 || rune > 0x7e) {
      return 'the key contains whitespace or non-ASCII characters';
    }
  }
  return null;
}

/// Trim surrounding whitespace and treat an empty result as absent. A pasted
/// key often carries a trailing newline; that is safe to drop, while internal
/// whitespace is rejected by [apiKeyProblem].
String? _cleanKey(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Resolve the key for [config] with a documented precedence:
///
/// 1. `provider.api_key` (literal, or expanded from `$VAR` at load),
/// 2. the auth store entry for `provider.preset` (a key entered via `--setup`),
/// 3. `provider.api_key_env`,
/// 4. the preset's well-known environment variables (e.g. `OPENAI_API_KEY`).
///
/// Surrounding whitespace is trimmed; a whitespace-only value counts as
/// absent. [store] and [env] are injectable so the precedence is testable
/// without touching the real environment.
String? resolveApiKey(
  ProviderConfig config, {
  AuthStore? store,
  String? Function(String name)? env,
}) {
  final direct = _cleanKey(config.apiKey);
  if (direct != null) return direct;

  final lookup = env ?? (name) => Platform.environment[name];
  final presetId = config.preset;
  if (presetId != null) {
    final stored = _cleanKey((store ?? AuthStore()).keyFor(presetId));
    if (stored != null) return stored;
  }

  final envName = config.apiKeyEnv;
  if (envName != null && envName.isNotEmpty) {
    final value = _cleanKey(lookup(envName));
    if (value != null) return value;
  }

  if (presetId != null) {
    for (final name in providerPreset(presetId)?.envKeys ?? const <String>[]) {
      final value = _cleanKey(lookup(name));
      if (value != null) return value;
    }
  }
  return null;
}

/// Whether [config] is expected to authenticate. A local endpoint (ollama,
/// LM Studio, or an explicit localhost URL) does not need a key; `custom`
/// endpoints are treated as optional.
bool providerNeedsKey(ProviderConfig config) {
  if (config.kind == ProviderKind.ollama) return false;
  final preset = providerPreset(config.preset);
  if (preset != null) return preset.requiresKey;
  // A legacy explicit endpoint is not second-guessed: it may be a local
  // proxy that requires no key. The endpoint reports a 401 if it does.
  return false;
}

/// A one-line, actionable message when [config] needs a key that cannot be
/// resolved, or null when it is ready. Never includes a key value.
String? missingKeyHint(
  ProviderConfig config, {
  AuthStore? store,
  String? Function(String name)? env,
}) {
  if (!providerNeedsKey(config)) return null;
  final key = resolveApiKey(config, store: store, env: env);
  if (key != null) {
    final problem = apiKeyProblem(key);
    if (problem == null) return null;
    return 'the API key for ${config.preset ?? config.baseUrl} is invalid '
        '($problem); run `sudoer-prop --setup`';
  }
  final preset = providerPreset(config.preset);
  final envs = preset?.envKeys ?? const <String>[];
  final envText = envs.isEmpty ? '' : 'set ${envs.join(' or ')}, or ';
  return 'no API key for ${config.preset ?? config.baseUrl}: '
      '${envText}run `sudoer-prop --setup`';
}
