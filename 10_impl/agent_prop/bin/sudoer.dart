import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import 'package:sudoer_prop/src/agent.dart';
import 'package:sudoer_prop/src/build_info.dart';
import 'package:sudoer_prop/src/config.dart';
import 'package:sudoer_prop/src/errors.dart';
import 'package:sudoer_prop/src/interface.dart';
import 'package:sudoer_prop/src/platform.dart';
import 'package:sudoer_prop/src/providers/auth.dart';
import 'package:sudoer_prop/src/providers/discovery.dart';
import 'package:sudoer_prop/src/providers/setup.dart';
import 'package:sudoer_prop/src/session.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.')
    ..addFlag('version',
        negatable: false, help: 'Print the version and the repo, then exit.')
    ..addOption(
      'config',
      abbr: 'c',
      help: 'Path to a JSON config file.',
      defaultsTo:
          Platform.environment['SUDOER_CONFIG'] ?? defaultConfigPath(),
    )
    ..addOption('session', abbr: 's', help: 'Resume (or create) a session by id.')
    ..addFlag('automate', negatable: false,
        help: 'Use the line-oriented surface (for scripts); the default is '
            'the human TUI.')
    ..addFlag('human', negatable: false,
        help: 'Force the human surface even if the terminal is not detected.')
    ..addFlag('inline', negatable: false,
        help: 'Use the inline scrollback surface instead of the full-screen '
            'TUI.')
    ..addFlag('verbose', negatable: false,
        help: 'Emit per-step diagnostics on stderr.')
    ..addOption('provider',
        help: 'Provider preset id (see --list-providers), e.g. openai.')
    ..addOption('model', help: 'Model id for the selected provider.')
    ..addOption('api-key',
        help: 'API key for this process only (prefer --setup or an env var).')
    ..addOption('api-key-env',
        help: 'Name of the environment variable holding the API key.')
    ..addOption('base-url',
        help: 'Override the provider base URL (OpenAI-compatible or ollama).')
    ..addOption('context-window',
        help: 'Context window in tokens (defaults to the model catalog).')
    ..addFlag('list-providers', negatable: false,
        help: 'List provider presets and exit.')
    ..addFlag('list-models', negatable: false,
        help: 'List the selected provider\'s models (live when reachable) '
            'and exit.')
    ..addFlag('setup', negatable: false,
        help: 'Interactive provider, key, and model setup.')
    ..addFlag('login', negatable: false, help: 'Alias for --setup.')
    ..addFlag('save-key', negatable: false,
        help: 'Save --api-key for --provider in the auth store and exit.');

  final ArgResults results;
  try {
    results = parser.parse(args);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    _printUsage(parser, to: stderr);
    exit(2);
  }

  if (results['help'] as bool) {
    _printUsage(parser);
    exit(0);
  }

  if (results['version'] as bool) {
    stdout
      ..writeln('sudoer-prop $kBuildLabel')
      ..writeln(kRepoUrl);
    exit(0);
  }

  final configPath = results['config'] as String;
  // First start: create the app dir (~/.config/sudoer) and its sessions
  // sub-directory when missing, so the config, auth store, and session
  // store all have a home (C5/C6).
  ensureAppDir();
  final providerArg = results['provider'] as String?;
  final modelArg = results['model'] as String?;
  final apiKeyArg = results['api-key'] as String?;
  final apiKeyEnvArg = results['api-key-env'] as String?;
  final baseUrlArg = results['base-url'] as String?;
  int? contextWindowArg;
  final rawWindow = results['context-window'] as String?;
  if (rawWindow != null) {
    contextWindowArg = int.tryParse(rawWindow);
    if (contextWindowArg == null || contextWindowArg < 1) {
      stderr.writeln('--context-window must be a positive integer');
      exit(2);
    }
  }

  // Catalog-only surfaces do not need a config. When one exists, mark the
  // active provider; a bad config does not block the listing.
  if (results['list-providers'] as bool) {
    ProviderConfig? current;
    if (File(configPath).existsSync()) {
      try {
        current = loadConfigFile(configPath).provider;
      } on Object {
        current = null;
      }
    }
    stdout.writeln(providerListText(current: current));
    exit(0);
  }

  final setup = (results['setup'] as bool) || (results['login'] as bool);
  if (setup) {
    if (!stdin.hasTerminal || !stdout.hasTerminal) {
      stderr.writeln('interactive setup needs a terminal. '
          'For scripts use --provider <id> --model <id> --api-key <key>, '
          'or set the provider environment variable.');
      exit(2);
    }
    Config? existing;
    if (File(configPath).existsSync()) {
      try {
        existing = loadConfigFile(configPath);
      } on ConfigException catch (e) {
        stderr.writeln('config error: ${e.message}');
        exit(2);
      }
    }
    exit(await runProviderSetup(
      configPath: configPath,
      existing: existing,
      presetId: providerArg,
      model: modelArg,
      apiKey: apiKeyArg,
      baseUrl: baseUrlArg,
      contextWindow: contextWindowArg,
    ));
  }

  if (results['save-key'] as bool) {
    if (providerArg == null || apiKeyArg == null || apiKeyArg.isEmpty) {
      stderr.writeln('--save-key needs --provider <id> and --api-key <key>');
      exit(2);
    }
    if (providerPreset(providerArg) == null) {
      stderr.writeln('unknown provider: $providerArg');
      exit(2);
    }
    final key = apiKeyArg.trim();
    final problem = apiKeyProblem(key);
    if (problem != null) {
      stderr.writeln('invalid API key: $problem');
      exit(2);
    }
    final store = AuthStore();
    store.setKey(providerArg, key);
    stdout.writeln('saved key for $providerArg in ${store.path}');
    exit(0);
  }

  // A provider flag is enough to run without a config: the preset supplies
  // kind, base URL, and context window.
  Config? baseConfig;
  if (File(configPath).existsSync()) {
    try {
      baseConfig = loadConfigFile(configPath);
    } on ConfigException catch (e) {
      stderr.writeln('config error: ${e.message}');
      exit(2);
    }
  } else if (providerArg == null) {
    stderr.write(missingConfigReport(configPath));
    exit(2);
  }

  final Config config;
  try {
    config = configWithProvider(
      baseConfig,
      presetId: providerArg,
      model: modelArg,
      apiKey: apiKeyArg,
      apiKeyEnv: apiKeyEnvArg,
      baseUrl: baseUrlArg,
      contextWindow: contextWindowArg,
      replaceKey: apiKeyArg != null || apiKeyEnvArg != null,
    );
  } on ConfigException catch (e) {
    stderr.writeln('config error: ${e.message}');
    exit(2);
  }

  if (results['list-models'] as bool) {
    final preset = providerPreset(config.provider.preset) ??
        presetForConfig(config.provider);
    final key = resolveApiKey(config.provider);
    final keyProblem = key == null ? null : apiKeyProblem(key);
    var models = preset.models;
    String? note;
    if (keyProblem != null) {
      note = '(invalid API key: $keyProblem; showing the built-in catalog)';
    } else if (key == null && preset.requiresKey) {
      note = '(no API key: showing the built-in catalog; '
          'authentication is not verified)';
    } else {
      try {
        models = await discoverModels(preset, apiKey: key);
      } on Object catch (e) {
        note = '(live discovery unavailable: $e; '
            'showing the built-in catalog)';
      }
    }
    stdout.writeln(modelListText(
      preset,
      current: config.provider.model,
      models: models,
      note: note,
    ));
    exit(0);
  }

  // A preset that expects a key fails fast with an actionable message. A
  // legacy explicit endpoint is left alone: it may be an unauthenticated
  // local proxy.
  final keyHint = missingKeyHint(config.provider);
  if (keyHint != null) {
    stderr.writeln(keyHint);
    exit(2);
  }

  final goal = results.rest.join(' ').trim();
  final verbose = results['verbose'] as bool;
  final interactive = stdin.hasTerminal && stdout.hasTerminal;
  // Human is the default on a terminal; --automate (or a pipe/redirect)
  // selects the plain line path so scripts and the gate never hang.
  final human = chooseMode(
        automate: results['automate'] as bool,
        human: results['human'] as bool,
        interactive: interactive,
      ) ==
      UiMode.human;
  try {
    // `--session` names the session on every surface, not just the REPL: a
    // one-shot goal must resume it too. Resume the named session if it is
    // saved, otherwise start a new one under that id (so a caller that
    // pins an id gets one stable session across runs).
    final resumeId = results['session'] as String?;
    Session? session;
    if (resumeId != null) {
      try {
        session = Session.load(config.sessionDir, resumeId);
      } on StateError {
        // Not saved yet: start a new session under that id (pinned, so it
        // stays stable across runs; a pinned id never gains keywords).
        session = Session.create(
            workspaceRoot: config.workspaceRoot, id: resumeId);
      }
    }

    // A positional goal is a one-shot convenience.
    if (goal.isNotEmpty) {
      exit(await runCli(
          config: config,
          goal: goal,
          verbose: verbose,
          human: human,
          session: session,
          sessionNamer: _nameSession));
    }

    // Full-screen mode is the default human surface on a terminal. Program
    // owns raw mode, the alternate screen, bracketed paste, and SIGINT; the
    // inline fallback (`--inline`) keeps the older line-editor path and its
    // manual terminal setup.
    final inline = results['inline'] as bool;
    final useTui = human && interactive && !inline;
    final rawMode = human && interactive && !useTui;
    void restoreTerminal() {
      if (!rawMode) return;
      try {
        // Restore the Windows console input mode, then leave bracketed paste
        // mode before the terminal is handed back.
        restoreWindowsRawInput();
        stdout.write('\x1b[?2004l');
        stdin.echoMode = true;
        stdin.lineMode = true;
      } on Object {
        // Not a terminal any more; nothing to restore.
      }
    }

    StreamSubscription<ProcessSignal>? signals;
    if (rawMode) {
      signals = ProcessSignal.sigint.watch().listen((_) {
        restoreTerminal();
        stdout.write('\n');
        exit(130);
      });
      stdin.echoMode = false;
      stdin.lineMode = false;
      // On Windows, echo/line mode alone leaves the legacy console; this puts
      // the input handle into virtual-terminal mode so keys arrive as bytes.
      enableWindowsRawInput();
      // Ask the terminal to delimit pastes with ESC[200~ … ESC[201~ so a
      // multi-line paste is edited as one goal instead of submitting at its
      // first newline.
      stdout.write('\x1b[?2004h');
    }
    final int code;
    try {
      final outcome = await runRepl(
        config: config,
        input: stdin.transform(utf8.decoder).transform(const LineSplitter()),
        rawInput: stdin,
        interactive: interactive,
        tui: useTui,
        session: session,
        verbose: verbose,
        human: human,
        // On a real terminal the tty echoes the input; only echo a goal when
        // the input arrives from a pipe or redirect.
        echoInput: human && !interactive,
        sessionNamer: _nameSession,
      );
      code = outcome.exitCode;
    } finally {
      restoreTerminal();
      await signals?.cancel();
    }
    exit(code);
  } on Object catch (e) {
    stderr.writeln('error: $e');
    exit(1);
  }
}

void _printUsage(ArgParser parser, {IOSink? to}) {
  (to ?? stdout)
    ..writeln('Sudoer — Prop coding agent $kBuildLabel.')
    ..writeln(kRepoUrl)
    ..writeln()
    ..writeln('Usage: sudoer-prop [options] [goal]')
    ..writeln()
    ..writeln(parser.usage)
    ..writeln()
    ..writeln('With a positional goal, runs it once and exits.')
    ..writeln('Without a goal on a terminal, runs the full-screen TUI: a')
    ..writeln('scrollable transcript, a multi-line editor, and a status footer.')
    ..writeln('Enter sends; Shift+Enter or Alt+Enter adds a line;')
    ..writeln('Esc cancels a run;')
    ..writeln('PgUp/PgDn scroll the transcript; /help lists commands.')
    ..writeln('Type !<cmd> to run a shell command directly (no model).')
    ..writeln('Use --inline for the older scrollback line editor.')
    ..writeln('With --automate, or when stdin/stdout is not a terminal, runs the')
    ..writeln('plain CLI: each line is a goal or a command (/help, /plan, /exit…).')
    ..writeln()
    ..writeln('A goal may carry @path tokens to attach images '
        '(png/jpg/jpeg/gif/webp).')
    ..writeln()
    ..writeln('API keys are read from provider.api_key, the auth store')
    ..writeln('(~/.config/sudoer/auth.json), provider.api_key_env, or the')
    ..writeln('preset environment variable (e.g. OPENAI_API_KEY).')
    ..writeln('Config strings may reference environment variables, e.g.')
    ..writeln('"api_key": "\$OPENAI_API_KEY". An unset variable is an error.')
    ..writeln()
    ..writeln('Examples:')
    ..writeln('  sudoer-prop --setup                 # provider + key + model')
    ..writeln('  sudoer-prop --list-providers')
    ..writeln('  sudoer-prop --list-models --provider ollama')
    ..writeln('  sudoer-prop --provider openai --model gpt-6-astra "..."')
    ..writeln('  sudoer-prop -c ollama.json          # interactive session')
    ..writeln('  sudoer-prop -c ollama.json "Read README.md and summarize it"')
    ..writeln('  sudoer-prop -c ollama.json -s s1a2b3 "and now the tests"')
    ..writeln()
    ..writeln('Exit codes: 0 = the final run completed;')
    ..writeln('            1 = the final run was incomplete or blocked,')
    ..writeln('                or a fatal error occurred;')
    ..writeln('            2 = usage or config error.');
}

/// C5: name the session after its first goal — at most five LLM-picked
/// keywords become part of the file name (`YYMMDD-HHmmSS_<keywords>.jsonl`).
Future<String?> _nameSession(PropAgent agent) => summarizeSessionKeywords(
  provider: agent.provider,
  model: agent.config.provider.model,
  goal: sessionGoalSummary(agent.session),
  cancel: agent.session.cancel,
);
