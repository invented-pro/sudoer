import 'dart:convert';
import 'dart:io';

import 'package:dart_tui/dart_tui.dart'
    show
        Field,
        Form,
        Group,
        KeyCode,
        KeyPressMsg,
        Msg,
        PasteEndMsg,
        PasteMsg,
        PasteStartMsg,
        ProgramOption,
        TeaKey,
        filter,
        promptConfirm,
        promptSelect,
        withAltScreen,
        withFilter;

import '../config.dart';
import '../errors.dart';
import '../tui_popup.dart';
import 'auth.dart';
import 'discovery.dart';

/// C2: provider setup and listing helpers, shared by the CLI (`--setup`,
/// `--list-providers`, `--list-models`, `--provider`) and the REPL
/// (`/provider`, `/model`).
///
/// The interactive wizard uses dart_tui's one-shot prompts (list selection and
/// a masked password field), so there is no hand-rolled terminal handling
/// here. The prompt functions are injectable for tests.

typedef SelectFn = Future<String?> Function(
  List<String> choices, {
  required String title,
});

typedef InputFn = Future<String?> Function(String label);

/// A fuzzy-filtering picker, used when the model list is long (live
/// discovery can return hundreds of ids).
typedef FilterFn = Future<String?> Function(
  List<String> choices, {
  required String title,
});

typedef SecretFn = Future<String?> Function(String title, {bool optional});

typedef ConfirmFn = Future<bool?> Function(String question);

/// Discovery seam: the default calls the endpoint; tests can supply a list.
typedef DiscoverFn = Future<List<ModelInfo>> Function(
  ProviderPreset preset,
  String? apiKey,
);

/// Build a config with a provider selected by preset, model, base URL, or key
/// overrides. A null [base] creates a config rooted at the current directory.
///
/// When [replaceKey] is true, `api_key` and `api_key_env` are set exactly as
/// passed (including null), so switching from an env reference to a stored key
/// (or the reverse) clears the old field.
Config configWithProvider(
  Config? base, {
  String? presetId,
  String? model,
  String? apiKey,
  String? apiKeyEnv,
  String? baseUrl,
  int? contextWindow,
  bool replaceKey = false,
}) {
  final preset = presetId == null ? null : providerPreset(presetId);
  if (presetId != null && preset == null) {
    throw ConfigException('unknown provider preset: $presetId');
  }
  final previous = base?.provider;
  final same = preset == null || previous?.preset == preset.id;

  // An explicit --provider selects the preset's adapter. Without one, keep
  // the config's adapter even when it overrides a preset's default.
  final kind = presetId != null ? preset?.kind : previous?.kind;
  if (kind == null) {
    throw const ConfigException(
      'a config or --provider <preset> is required to choose a provider',
    );
  }

  final selectedModel =
      model ?? (same ? previous?.model : null) ?? preset?.defaultModel;
  if (selectedModel == null || selectedModel.isEmpty) {
    throw const ConfigException('provider.model is required (use --model)');
  }

  final resolvedBase =
      baseUrl ?? (same ? previous?.baseUrl : null) ?? preset?.baseUrl;
  if (kind == ProviderKind.openAiCompatible &&
      (resolvedBase == null || resolvedBase.isEmpty)) {
    throw const ConfigException(
      'provider.base_url is required for the openai-compatible adapter '
      '(use --base-url)',
    );
  }

  final selectedWindow =
      contextWindow ??
      (same ? previous?.contextWindow : null) ??
      preset?.model(selectedModel)?.contextWindow ??
      (preset == null ? null : kDefaultContextWindow);
  if (selectedWindow == null || selectedWindow < 1) {
    throw const ConfigException(
      'provider.context_window is required (use --context-window)',
    );
  }

  String? nextApiKey;
  String? nextApiKeyEnv;
  if (replaceKey) {
    nextApiKey = apiKey;
    nextApiKeyEnv = apiKeyEnv;
  } else {
    if (apiKey != null) {
      nextApiKey = apiKey;
    } else if (apiKeyEnv != null) {
      nextApiKeyEnv = apiKeyEnv;
    } else if (same) {
      nextApiKey = previous?.apiKey;
      nextApiKeyEnv = previous?.apiKeyEnv;
    }
  }
  if (nextApiKey != null && nextApiKeyEnv != null) {
    throw const ConfigException(
      'set at most one of provider.api_key and provider.api_key_env',
    );
  }
  if (nextApiKey != null && nextApiKey.isNotEmpty) {
    final problem = apiKeyProblem(nextApiKey);
    if (problem != null) {
      throw ConfigException('invalid API key: $problem');
    }
    nextApiKey = nextApiKey.trim();
  }

  final provider = ProviderConfig(
    kind: kind,
    model: selectedModel,
    contextWindow: selectedWindow,
    preset: preset?.id ?? (same ? previous?.preset : null),
    baseUrl: resolvedBase,
    apiKey: nextApiKey,
    apiKeyEnv: nextApiKeyEnv,
    sampling: same ? previous?.sampling : null,
  );

  if (base != null) return base.copyWith(provider: provider);
  final root = Directory.current.path;
  return Config(
    provider: provider,
    workspaceRoot: root,
    sessionDir: defaultSessionsDir(),
  );
}

/// A compact context-window label (`1.0M`, `262K`, `4096`).
String formatContextWindow(int tokens) {
  if (tokens >= 1000000) {
    final value = tokens / 1000000;
    return '${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1)}M';
  }
  if (tokens >= 1000) return '${(tokens / 1000).round()}K';
  return '$tokens';
}

bool _usableKey(String? value) =>
    value != null && value.isNotEmpty && apiKeyProblem(value) == null;

/// The key state of a provider row: the *state*, never a value. An existing
/// but unusable key is called out so a stale paste is easy to spot. Shared by
/// the `--list-providers` table and the `/provider` popup (C6).
String providerKeyState(
  ProviderPreset preset, {
  ProviderConfig? current,
  Map<String, String>? storedKeys,
  String? Function(String name)? lookup,
}) {
  lookup ??= (name) => Platform.environment[name];
  final stored = storedKeys ?? const <String, String>{};
  if (!preset.requiresKey) return 'not required';
  final configKey = current?.preset == preset.id ? current?.apiKey : null;
  if (configKey != null) {
    return _usableKey(configKey) ? 'config' : 'invalid';
  }
  if (stored[preset.id] != null) {
    return _usableKey(stored[preset.id]) ? 'stored' : 'invalid';
  }
  String? envValue;
  for (final name in preset.envKeys) {
    final value = lookup(name);
    if (value != null && value.isNotEmpty) {
      envValue = value;
      break;
    }
  }
  return envValue == null
      ? 'missing'
      : (_usableKey(envValue) ? 'env' : 'invalid');
}

/// Whether a TUI provider switch to [preset] should prompt for an API key
/// (C2/C6): the preset requires one, has a usable base URL baked in, and no
/// key can be resolved (none stored, none in the environment — or a stored
/// value that is unusable, so the prompt offers to replace it). The preset
/// already in effect never prompts; local endpoints (`requiresKey == false`)
/// never do.
bool shouldPromptForKey(
  ProviderPreset preset, {
  ProviderConfig? current,
  AuthStore? store,
  String? Function(String name)? env,
}) {
  if (current?.preset == preset.id) return false;
  if (!preset.requiresKey || preset.baseUrl == null) return false;
  final state = providerKeyState(
    preset,
    current: current,
    storedKeys: (store ?? AuthStore()).read(),
    lookup: env,
  );
  return state == 'missing' || state == 'invalid';
}

/// The `/provider` popup rows (C6): one item per preset, `id — name` as the
/// filter target, the key state as the detail column, and `●` marking the
/// preset in effect. Cancelling changes nothing.
List<TuiPopupItem> providerPopupItems({
  ProviderConfig? current,
  AuthStore? store,
  String? Function(String name)? env,
}) {
  final auth = store ?? AuthStore();
  final storedKeys = auth.read();
  final lookup = env ?? (name) => Platform.environment[name];
  return [
    for (final preset in kProviderPresets)
      TuiPopupItem(
        value: preset.id,
        label: '${preset.id} — ${preset.name}',
        detail: providerKeyState(
          preset,
          current: current,
          storedKeys: storedKeys,
          lookup: lookup,
        ),
        active:
            current != null &&
            (current.preset == preset.id ||
                (current.preset == null &&
                    presetForBaseUrl(current.baseUrl)?.id == preset.id)),
      ),
  ];
}

/// The `--list-providers` table. `*` marks the current provider; the key
/// column never reveals a key.
String providerListText({
  ProviderConfig? current,
  AuthStore? store,
  String? Function(String name)? env,
}) {
  final auth = store ?? AuthStore();
  final storedKeys = auth.read();
  final lookup = env ?? (name) => Platform.environment[name];
  const idWidth = 22;
  const nameWidth = 30;
  String fit(String value, int width) => value.length <= width
      ? value.padRight(width)
      : '${value.substring(0, width - 1)}…';
  final buffer = StringBuffer()
    ..writeln(
      '  ${kProviderPresets.length} presets — OpenAI-compatible '
      'models.dev/OpenCode set + local/custom',
    )
    ..writeln(
      '  ${'ID'.padRight(idWidth)} ${'NAME'.padRight(nameWidth)} '
      '${'KIND'.padRight(18)} KEY',
    );
  for (final preset in kProviderPresets) {
    final active =
        current != null &&
        (current.preset == preset.id ||
            (current.preset == null &&
                presetForBaseUrl(current.baseUrl)?.id == preset.id));
    buffer.writeln(
      '${active ? '*' : ' '} ${fit(preset.id, idWidth)} '
      '${fit(preset.name, nameWidth)} ${preset.kind.wire.padRight(18)} '
      '${providerKeyState(preset, current: current, storedKeys: storedKeys, lookup: lookup)}',
    );
  }
  buffer
    ..writeln()
    ..writeln('  Native-protocol-only providers (Bedrock, Vertex, Azure,')
    ..writeln('  native Anthropic/Google) and per-account-URL endpoints are')
    ..writeln('  not listed; use `custom` or an OpenAI-compatible gateway.');
  return buffer.toString().trimRight();
}

/// The `--list-models` / `/model` table. `*` marks the current model.
String modelListText(
  ProviderPreset preset, {
  String? current,
  List<ModelInfo>? models,
  String? note,
}) {
  final list = models ?? preset.models;
  final buffer = StringBuffer();
  if (list.isEmpty) {
    buffer.writeln('(no model catalog for ${preset.id}; pass --model <id>)');
  } else {
    for (final model in list) {
      final mark = model.id == current ? '*' : ' ';
      buffer.writeln(
        '$mark ${model.id.padRight(42)} '
        '${formatContextWindow(model.contextWindow)}',
      );
    }
  }
  if (note != null && note.isNotEmpty) buffer.writeln(note);
  return buffer.toString().trimRight();
}

/// Write [config] to [path] atomically as pretty JSON.
void writeConfigFile(String path, Config config) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  final json = const JsonEncoder.withIndent('  ').convert(config.toJson());
  final temp = File('$path.tmp');
  temp.writeAsStringSync('$json\n');
  // Windows rename does not replace an existing destination.
  if (Platform.isWindows && file.existsSync()) file.deleteSync();
  temp.renameSync(path);
}

/// Run the interactive provider setup wizard. Returns a process exit code.
///
/// It selects a provider preset, asks for the endpoint (custom only), obtains
/// and stores the key, discovers the endpoint's live models when reachable,
/// selects a model, and writes the config. With [presetId] / [model] /
/// [apiKey] / [baseUrl] supplied, the corresponding prompt is skipped.
Future<int> runProviderSetup({
  required String configPath,
  Config? existing,
  String? presetId,
  String? model,
  String? apiKey,
  String? baseUrl,
  int? contextWindow,
  AuthStore? auth,
  String? Function(String name)? env,
  StringSink? out,
  StringSink? err,
  SelectFn? select,
  InputFn? input,
  SecretFn? secret,
  ConfirmFn? confirm,
  FilterFn? filterChoices,
  DiscoverFn? discover,
}) async {
  final outSink = out ?? stdout;
  final errSink = err ?? stderr;
  final store = auth ?? AuthStore();
  final choose = select ?? _defaultSelect;
  final ask = input ?? _defaultInput;
  final askSecret = secret ?? _defaultSecret;
  final askConfirm = confirm ?? _defaultConfirm;
  final pickModel = filterChoices ?? _defaultFilter;
  final discoverFn = discover ?? _defaultDiscover;

  // A key supplied non-interactively (`--setup --api-key`, or a test) must
  // pass the same check as the wizard's masked field.
  final explicitKey = apiKey?.trim();
  if (explicitKey != null && explicitKey.isNotEmpty) {
    final problem = apiKeyProblem(explicitKey);
    if (problem != null) {
      errSink.writeln('invalid API key: $problem');
      return 1;
    }
  }

  // 1. Provider.
  var preset = providerPreset(presetId);
  if (presetId != null && preset == null) {
    errSink.writeln('unknown provider: $presetId');
    return 2;
  }
  if (preset == null) {
    final choices = [
      for (final candidate in kProviderPresets)
        '${candidate.id} — ${candidate.name}',
    ];
    final picked = choices.length > 12
        ? await pickModel(
            choices,
            title: 'Choose an LLM provider — type to filter',
          )
        : await choose(choices, title: 'Choose an LLM provider');
    if (picked == null) {
      errSink.writeln('cancelled');
      return 1;
    }
    preset = kProviderPresets[choices.indexOf(picked)];
  }

  // 2. Base URL (custom or a preset with no baked-in URL).
  var resolvedBase = baseUrl ?? preset.baseUrl;
  if (resolvedBase == null || resolvedBase.isEmpty) {
    final entered = await ask(
      'Base URL (OpenAI-compatible, usually ending in /v1)',
    );
    if (entered == null || entered.trim().isEmpty) {
      errSink.writeln('cancelled');
      return 1;
    }
    resolvedBase = entered.trim();
  }

  // 3. Key. Local endpoints skip it; custom may optionally use one.
  final keyOptional = preset.id == 'custom';
  final hasExplicitKey = explicitKey != null && explicitKey.isNotEmpty;
  final wantsKey = preset.requiresKey || keyOptional || hasExplicitKey;
  String? envName;
  String? discoveryKey = hasExplicitKey ? explicitKey : null;
  if (wantsKey) {
    if (discoveryKey == null) {
      // Look for an existing key: the auth store first, then env vars. A
      // stored value that is not usable as a bearer token is ignored (and
      // reported) so a stale paste cannot shadow a fresh key.
      String? existingKey;
      String? existingEnv;
      final stored = store.keyFor(preset.id);
      if (stored != null && stored.isNotEmpty) {
        final problem = apiKeyProblem(stored);
        if (problem == null) {
          existingKey = stored.trim();
        } else {
          errSink.writeln(
            'ignoring the stored key for ${preset.id}: '
            '$problem',
          );
        }
      }
      if (existingKey == null) {
        final entry = _firstEnvEntry(preset.envKeys, env);
        if (entry != null) {
          final problem = apiKeyProblem(entry.value);
          if (problem == null) {
            existingKey = entry.value.trim();
            existingEnv = entry.name;
          } else {
            errSink.writeln('ignoring ${entry.name}: $problem');
          }
        }
      }

      var keep = false;
      if (existingKey != null) {
        final answer = await askConfirm(
          'Use the existing key for ${preset.name}?',
        );
        if (answer == null) {
          errSink.writeln('cancelled');
          return 1;
        }
        keep = answer;
      }
      if (keep) {
        discoveryKey = existingKey;
        envName = existingEnv; // null when it came from the auth store
      } else {
        final entered = await askSecret(
          'API key for ${preset.name}'
          '${keyOptional ? ' (Enter to skip)' : ''}',
          optional: keyOptional,
        );
        if (entered == null) {
          errSink.writeln('cancelled');
          return 1;
        }
        final key = entered.trim();
        if (key.isEmpty) {
          if (!keyOptional) {
            errSink.writeln('a key is required for ${preset.name}');
            return 1;
          }
        } else {
          final problem = apiKeyProblem(key);
          if (problem != null) {
            errSink.writeln('invalid API key: $problem');
            return 1;
          }
          discoveryKey = key;
          final choice = await _askKeyStorage(choose, store.path, preset, ask);
          switch (choice) {
            case _CancelKey():
              errSink.writeln('cancelled');
              return 1;
            case _StoreKey():
              store.setKey(preset.id, key);
              envName = null;
            case _EnvKey(:final name):
              // The auth store wins over api_key_env; drop a stale entry so
              // the chosen environment variable is actually the one used.
              store.remove(preset.id);
              envName = name;
          }
        }
      }
    } else {
      // An explicit --api-key: use it and ask where (if anywhere) to keep it.
      final choice = await _askKeyStorage(choose, store.path, preset, ask);
      switch (choice) {
        case _CancelKey():
          errSink.writeln('cancelled');
          return 1;
        case _StoreKey():
          store.setKey(preset.id, discoveryKey);
          envName = null;
        case _EnvKey(:final name):
          store.remove(preset.id);
          envName = name;
      }
    }
  }

  // 4. Model: live discovery when reachable, static catalog otherwise.
  final discoveryPreset = ProviderPreset(
    id: preset.id,
    name: preset.name,
    kind: preset.kind,
    baseUrl: resolvedBase,
    envKeys: preset.envKeys,
    models: preset.models,
    local: preset.local,
    requiresKey: preset.requiresKey,
  );
  var models = discoveryPreset.models;
  var selectedModel = model;
  if (selectedModel == null) {
    try {
      models = await discoverFn(discoveryPreset, discoveryKey);
    } on Object catch (e) {
      outSink.writeln(
        'model discovery unavailable (${e.runtimeType}); '
        'using the built-in list',
      );
      if (e is HttpException &&
          (e.message.contains('401') || e.message.contains('403'))) {
        errSink.writeln(
          'warning: the endpoint rejected the key (${e.message}); '
          'it may be invalid.',
        );
      }
      models = discoveryPreset.models;
    }
    if (models.isEmpty) {
      selectedModel = await ask('Model id');
    } else if (models.length > 12) {
      // A live list can be hundreds of entries. Ask for a pasteable query
      // first: an exact id/name wins immediately; otherwise narrow the list.
      final query = await ask(
        'Model id or name (paste an id, or Enter to browse)',
      );
      if (query == null) {
        errSink.writeln('cancelled');
        return 1;
      }
      final q = query.trim();
      if (q.isEmpty) {
        selectedModel = await _pickModel(models, choose, pickModel, ask);
      } else {
        final exact = models
            .where(
              (candidate) =>
                  candidate.id.toLowerCase() == q.toLowerCase() ||
                  candidate.name.toLowerCase() == q.toLowerCase(),
            )
            .toList();
        final matches = exact.isNotEmpty
            ? exact
            : models
                  .where(
                    (candidate) =>
                        candidate.id.toLowerCase().contains(q.toLowerCase()) ||
                        candidate.name.toLowerCase().contains(q.toLowerCase()),
                  )
                  .toList();
        if (matches.length == 1) {
          selectedModel = matches.single.id;
        } else {
          if (matches.isEmpty) {
            outSink.writeln('no model matches "$q"; showing all');
          }
          selectedModel = await _pickModel(
            matches.isEmpty ? models : matches,
            choose,
            pickModel,
            ask,
          );
        }
      }
      if (selectedModel == null) {
        errSink.writeln('cancelled');
        return 1;
      }
    } else {
      selectedModel = await _pickModel(models, choose, pickModel, ask);
      if (selectedModel == null) {
        errSink.writeln('cancelled');
        return 1;
      }
    }
    if (selectedModel == null || selectedModel.trim().isEmpty) {
      errSink.writeln('cancelled');
      return 1;
    }
    selectedModel = selectedModel.trim();
  }

  // 5. Context window: from the catalog/discovery, else conservative default.
  ModelInfo? info;
  for (final candidate in models) {
    if (candidate.id == selectedModel) {
      info = candidate;
      break;
    }
  }
  info ??= preset.model(selectedModel);
  final window = contextWindow ?? info?.contextWindow ?? kDefaultContextWindow;

  // 6. Write the config and report, without ever echoing the key.
  final Config next;
  try {
    next = configWithProvider(
      existing,
      presetId: preset.id,
      model: selectedModel,
      baseUrl: resolvedBase,
      contextWindow: window,
      apiKeyEnv: envName,
      replaceKey: true,
    );
  } on ConfigException catch (e) {
    errSink.writeln('config error: ${e.message}');
    return 2;
  }
  writeConfigFile(configPath, next);
  outSink
    ..writeln('provider: ${preset.id} (${preset.kind.wire})')
    ..writeln(
      'model:    $selectedModel  '
      '[${formatContextWindow(window)} context]',
    );
  if (envName != null) {
    outSink.writeln('key:      \$$envName (environment)');
  } else if (preset.requiresKey) {
    outSink.writeln('key:      stored in ${store.path}');
  } else {
    outSink.writeln('key:      not required');
  }
  outSink
    ..writeln('config:   $configPath')
    ..writeln()
    ..writeln('Start it with: sudoer-prop -c $configPath');
  return 0;
}

/// Where a newly entered key should be kept.
sealed class _KeyChoice {
  const _KeyChoice();
}

final class _StoreKey extends _KeyChoice {
  const _StoreKey();
}

final class _EnvKey extends _KeyChoice {
  const _EnvKey(this.name);
  final String name;
}

final class _CancelKey extends _KeyChoice {
  const _CancelKey();
}

/// Pick a model from [models], always offering an "Other…" text field so an
/// exact id can be pasted. Long pools use dart_tui's fuzzy filter; short ones
/// use a simple select.
Future<String?> _pickModel(
  List<ModelInfo> models,
  SelectFn choose,
  FilterFn pickModel,
  InputFn ask,
) async {
  const other = 'Other… (enter/paste a model id)';
  final choices = [
    for (final candidate in models)
      '${candidate.id}  (${formatContextWindow(candidate.contextWindow)})',
    other,
  ];
  final title = choices.length > 12
      ? 'Choose a model — type to filter, Other… to paste an id'
      : 'Choose a model';
  final picked = choices.length > 12
      ? await pickModel(choices, title: title)
      : await choose(choices, title: title);
  if (picked == null) return null;
  if (picked == other) return ask('Model id');
  return models[choices.indexOf(picked)].id;
}

Future<_KeyChoice> _askKeyStorage(
  SelectFn choose,
  String authPath,
  ProviderPreset preset,
  InputFn ask,
) async {
  final options = [
    'Save to $authPath (0600)',
    'Reference an environment variable',
  ];
  final picked = await choose(options, title: 'How should the key be kept?');
  if (picked == null) return const _CancelKey();
  if (picked == options[1]) {
    final suggested = preset.envKeys.isNotEmpty
        ? preset.envKeys.first
        : '${preset.id.toUpperCase().replaceAll('-', '_')}_API_KEY';
    final name = await ask('Environment variable name (default $suggested)');
    return _EnvKey(
      (name == null || name.trim().isEmpty) ? suggested : name.trim(),
    );
  }
  return const _StoreKey();
}

({String name, String value})? _firstEnvEntry(
  List<String> names, [
  String? Function(String name)? env,
]) {
  final lookup = env ?? (name) => Platform.environment[name];
  for (final name in names) {
    final value = lookup(name);
    if (value != null && value.isNotEmpty) return (name: name, value: value);
  }
  return null;
}

/// Full-screen prompt options. dart_tui's one-shot widgets default to inline
/// rendering, which leaves stale rows when the content is taller than the
/// prompt; the alternate screen guarantees a full clear/redraw and restores
/// the scrollback when the prompt ends.
List<ProgramOption> _selectOptions() => [withAltScreen()];

/// Text prompts additionally translate a bracketed paste into the printable
/// rune key that `TextInputModel` already inserts. dart_tui's forms ignore
/// `PasteMsg`; this keeps the wizard's fields pasteable without a bespoke
/// text widget.
List<ProgramOption> _textOptions() => [withAltScreen(), _withPaste()];

ProgramOption _withPaste() => withFilter((_, msg) => pasteAsRunes(msg));

/// Convert a bracketed paste into one printable-rune key. CR/LF are dropped
/// because every wizard text field is single-line.
Msg? pasteAsRunes(Msg msg) {
  if (msg is PasteStartMsg || msg is PasteEndMsg) return null;
  if (msg is! PasteMsg) return msg;
  final text = msg.content.replaceAll(RegExp(r'[\r\n]+'), '');
  if (text.isEmpty) return null;
  return KeyPressMsg(TeaKey(code: KeyCode.rune, text: text));
}

Future<String?> _defaultSelect(List<String> choices, {required String title}) =>
    promptSelect(choices, title: title, options: _selectOptions());

Future<String?> _defaultInput(String label) async {
  final values = await Form([
    Group([Field.input(key: 'value', title: label)]),
  ]).run(options: _textOptions());
  return values?.get<String>('value');
}

Future<String?> _defaultFilter(List<String> choices, {required String title}) =>
    filter(choices, title: title, options: _selectOptions());

Future<List<ModelInfo>> _defaultDiscover(
  ProviderPreset preset,
  String? apiKey,
) => discoverModels(preset, apiKey: apiKey);

Future<String?> _defaultSecret(String title, {bool optional = false}) async {
  // Keep the password as the *first* field: a preceding `Field.note` starts
  // the form on a non-input field and swallows the first typed/pasted key
  // before the form refocuses.
  final values = await Form([
    Group([
      Field.password(
        key: 'key',
        title: title,
        validate: (value) {
          final trimmed = value.trim();
          if (trimmed.isEmpty) {
            return optional ? null : 'a key is required';
          }
          return apiKeyProblem(trimmed);
        },
      ),
    ]),
  ]).run(options: _textOptions());
  return values?.get<String>('key');
}

Future<bool?> _defaultConfirm(String question) =>
    promptConfirm(question, options: _selectOptions());
