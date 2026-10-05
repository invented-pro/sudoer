import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import 'package:sudoer_prop/src/build_info.dart';
import 'package:sudoer_prop/src/config.dart';
import 'package:sudoer_prop/src/errors.dart';
import 'package:sudoer_prop/src/interface.dart';
import 'package:sudoer_prop/src/platform.dart';
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
      defaultsTo: Platform.environment['SUDOER_CONFIG'] ?? 'sudoer.json',
    )
    ..addOption('session', abbr: 's', help: 'Resume a saved session by id.')
    ..addFlag('automate', negatable: false,
        help: 'Use the line-oriented surface (for scripts); the default is '
            'the human TUI.')
    ..addFlag('human', negatable: false,
        help: 'Force the human TUI even if the terminal is not detected.')
    ..addFlag('verbose', negatable: false,
        help: 'Emit per-step diagnostics on stderr.');

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

  final Config config;
  try {
    config = loadConfigFile(results['config'] as String);
  } on ConfigNotFoundException catch (e) {
    stderr.write(missingConfigReport(e.path));
    exit(2);
  } on ConfigException catch (e) {
    stderr.writeln('config error: ${e.message}');
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
    // A positional goal is a one-shot convenience.
    if (goal.isNotEmpty) {
      exit(await runCli(
          config: config, goal: goal, verbose: verbose, human: human));
    }

    Session? session;
    final resumeId = results['session'] as String?;
    if (resumeId != null) {
      session = Session.load(config.sessionDir, resumeId);
    }

    // On a real terminal the human surface reads raw keys itself (line
    // editing, history, multi-line, double-Esc interrupt), so it needs raw
    // mode; restore the terminal on the way out. Ctrl+C still terminates the
    // process (it is not delivered as a key when ISIG is on), so a SIGINT
    // handler restores the terminal too, keeping the user's shell usable.
    final rawMode = human && interactive;
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

    final signals = ProcessSignal.sigint.watch().listen((_) {
      restoreTerminal();
      stdout.write('\n');
      exit(130);
    });
    if (rawMode) {
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
        interactive: rawMode,
        session: session,
        verbose: verbose,
        human: human,
        // On a real terminal the tty echoes the input; only echo a goal when
        // the input arrives from a pipe or redirect.
        echoInput: human && !interactive,
      );
      code = outcome.exitCode;
    } finally {
      restoreTerminal();
      await signals.cancel();
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
    ..writeln('Without a goal on a terminal, runs the styled human CLI')
    ..writeln('(streamed replies, spinner, status line; inline, not full-screen).')
    ..writeln('End a line with \\ to continue a goal on the next line;')
    ..writeln('type !<cmd> to run a shell command directly (no model);')
    ..writeln('press Esc twice to interrupt a run; /help lists commands.')
    ..writeln('With --automate, or when stdin/stdout is not a terminal, runs the')
    ..writeln('plain CLI: each line is a goal or a command (/help, /plan, /exit…).')
    ..writeln()
    ..writeln('A goal may carry @path tokens to attach images '
        '(png/jpg/jpeg/gif/webp).')
    ..writeln()
    ..writeln('Config strings may reference environment variables, e.g.')
    ..writeln('"api_key": "\$OPENAI_API_KEY". An unset variable is an error.')
    ..writeln()
    ..writeln('Examples:')
    ..writeln('  sudoer-prop -c ollama.json          # interactive session')
    ..writeln('  sudoer-prop -c ollama.json "Read README.md and summarize it"')
    ..writeln('  sudoer-prop -c ollama.json -s s1a2b3 # resume a session')
    ..writeln()
    ..writeln('Exit codes: 0 = clean exit (incomplete included);')
    ..writeln('            1 = fatal error, or the final run was blocked;')
    ..writeln('            2 = usage or config error.');
}
