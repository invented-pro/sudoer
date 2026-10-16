import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'package:sudoer_pilot/src/build_info.dart';
import 'package:sudoer_pilot/src/config.dart';
import 'package:sudoer_pilot/src/diagnostics.dart';
import 'package:sudoer_pilot/src/errors.dart';
import 'package:sudoer_pilot/src/interface.dart';
import 'package:sudoer_pilot/src/models.dart';
import 'package:sudoer_pilot/src/pilot_agent.dart';
import 'package:sudoer_pilot/src/pilot_commands.dart';
import 'package:sudoer_pilot/src/pilot_config.dart';
import 'package:sudoer_pilot/src/pilot_runtime.dart';
import 'package:sudoer_pilot/src/platform.dart';
import 'package:sudoer_pilot/src/scheduler.dart';
import 'package:sudoer_pilot/src/server.dart';
import 'package:sudoer_pilot/src/session.dart';

Future<void> main(List<String> args) async {
  // C6: `serve`, `tick`, `install`, `uninstall`, and `status` are CLI
  // subcommands, dispatched before any goal is parsed.
  if (args.isNotEmpty) {
    switch (args.first) {
      case 'serve':
        exit(await _serve(args.sublist(1)));
      case 'tick':
        exit(await _tick(args.sublist(1)));
      case 'install':
        exit(await _wake(args.sublist(1), install: true));
      case 'uninstall':
        exit(await _wake(args.sublist(1), install: false));
      case 'status':
        exit(await _status(args.sublist(1)));
    }
  }

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
    ..addOption('session', abbr: 's', help: 'Resume (or create) a session by id.')
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
      ..writeln('sudoer-pilot $kBuildLabel')
      ..writeln(kRepoUrl);
    exit(0);
  }

  final PilotConfig config;
  try {
    config = loadPilotConfig(results['config'] as String);
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
  // selects the plain line path so scripts and the gate never hang (C6).
  final human = chooseMode(
        automate: results['automate'] as bool,
        human: results['human'] as bool,
        interactive: interactive,
      ) ==
      UiMode.human;
  try {
    final runtime = PilotRuntime.assemble(config);
    final resumeId = results['session'] as String?;
    Session? session;
    if (resumeId != null) {
      final saved = File(p.join(config.sessionDir, '$resumeId.json'));
      session = saved.existsSync()
          ? Session.load(config.sessionDir, resumeId)
          : Session.create(workspaceRoot: config.primaryRoot, id: resumeId);
    }

    // A positional goal is a one-shot convenience (C6: zero only on
    // `complete`).
    if (goal.isNotEmpty) {
      exit(await runPilotOnce(runtime,
          goal: goal, session: session, verbose: verbose));
    }

    // The interactive / piped REPL with the Pilot hooks (C6: Prop surfaces
    // untouched; the Pilot commands ride the hook seam).
    final rawMode = human && interactive;
    void restoreTerminal() {
      if (!rawMode) return;
      try {
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
      enableWindowsRawInput();
      stdout.write('\x1b[?2004h');
    }
    final int code;
    try {
      final outcome = await runRepl(
        config: propConfigOf(config),
        input: stdin.transform(utf8.decoder).transform(const LineSplitter()),
        rawInput: stdin,
        interactive: rawMode,
        session: session,
        verbose: verbose,
        human: human,
        echoInput: human && !interactive,
        reliability: gateReliability(),
        hooks: pilotHooks(runtime),
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

/// `sudoer-pilot serve` (C6): the resident REST service.
Future<int> _serve(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('config',
        abbr: 'c',
        defaultsTo: Platform.environment['SUDOER_CONFIG'] ?? 'sudoer.json')
    ..addFlag('verbose', abbr: 'v', defaultsTo: false);
  final results = parser.parse(arguments);
  final config = loadPilotConfig(results['config'] as String);
  final runtime = PilotRuntime.assemble(config);
  final server = PilotServer(runtime);
  return server.run(verbose: results['verbose'] as bool);
}

/// `sudoer-pilot tick` (C11): the OS wake — fire due tasks with no
/// interactive session, deliver their results, and exit 0.
Future<int> _tick(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('config',
        abbr: 'c',
        defaultsTo: Platform.environment['SUDOER_CONFIG'] ?? 'sudoer.json');
  final results = parser.parse(arguments);
  final config = loadPilotConfig(results['config'] as String);
  final runtime = PilotRuntime.assemble(config);
  runtime.log.emitService('start');
  try {
    final autonomy = autonomyFor(runtime, null);
    await autonomy.tick();
    final report = autonomy.reportMissed();
    if (report.isNotEmpty) stderr.write(report);
    return 0;
  } finally {
    runtime.log.emitService('stop');
  }
}

/// `sudoer-pilot install` / `uninstall` (C11): the OS wake hook. The
/// scheduler adapter records the unit; the host is touched only by the real
/// adapters, never by the gate's fake.
Future<int> _wake(List<String> arguments, {required bool install}) async {
  final parser = ArgParser()
    ..addOption('config',
        abbr: 'c',
        defaultsTo: Platform.environment['SUDOER_CONFIG'] ?? 'sudoer.json');
  final results = parser.parse(arguments);
  final config = loadPilotConfig(results['config'] as String);
  final runtime = PilotRuntime.assemble(config);
  if (!install) {
    final removed = runtime.scheduler.uninstall();
    stdout.writeln(removed ? 'wake removed' : 'no wake was installed');
    return 0;
  }
  final next = autonomyFor(runtime, null).nextDue();
  if (next == null) {
    stdout.writeln('no pending tasks; nothing to wake for');
    return 0;
  }
  final unit = runtime.scheduler.installWake(next, Directory.current.path);
  stdout.writeln('wake installed for ${next.toIso8601String()}');
  stdout.writeln('unit: $unit');
  return 0;
}

/// `sudoer-pilot status` (C6/C11): the service state and the next fire.
Future<int> _status(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('config',
        abbr: 'c',
        defaultsTo: Platform.environment['SUDOER_CONFIG'] ?? 'sudoer.json');
  final results = parser.parse(arguments);
  final config = loadPilotConfig(results['config'] as String);
  final runtime = PilotRuntime.assemble(config);
  final next = autonomyFor(runtime, null).nextDue();
  final pending = TaskStore(config.tasksFile, runtime.clock)
      .load()
      .where((task) => task.status == 'pending')
      .length;
  stdout.writeln('service: not running (start it with `sudoer-pilot serve`)');
  stdout.writeln('tasks pending: $pending');
  stdout.writeln(
      next == null ? 'next fire: none' : 'next fire: ${next.toIso8601String()}');
  stdout.writeln('channels: ${config.channels.length}');
  return 0;
}

/// One-shot automate run on the PilotAgent assembly (C6 semantics).
Future<int> runPilotOnce(
  PilotRuntime runtime, {
  required String goal,
  Session? session,
  bool verbose = false,
  List<String>? callLog,
}) async {
  final resolved =
      session ?? Session.create(workspaceRoot: runtime.config.primaryRoot);
  final agent = PilotAgent.assemble(
    runtime: runtime,
    session: resolved,
    chain: gateChain(),
    reliability: gateReliability(),
    diagnostics: verbose
        ? Diagnostics(enabled: true, sink: stderr.writeln)
        : Diagnostics.silent,
    callLog: callLog,
  );
  try {
    final result = await agent.run(RunRequest(goal));
    if (result.reason == 'cancelled') {
      stderr.writeln('cancelled');
      return 1;
    }
    switch (result.status) {
      case RunStatus.complete:
        stdout.writeln(result.answer ?? '');
        return 0;
      case RunStatus.incomplete:
        stdout.writeln(result.answer ?? '');
        stderr.writeln('incomplete: ${result.reason ?? 'incomplete'}');
      case RunStatus.blocked:
        stderr.writeln('blocked: ${result.reason ?? 'unknown'}');
    }
    return 1;
  } finally {
    await agent.dispose();
  }
}

void _printUsage(ArgParser parser, {IOSink? to}) {
  (to ?? stdout)
    ..writeln('Sudoer — Pilot personal assistant $kBuildLabel.')
    ..writeln(kRepoUrl)
    ..writeln()
    ..writeln('Usage: sudoer-pilot [options] [goal]')
    ..writeln()
    ..writeln(parser.usage)
    ..writeln()
    ..writeln('Subcommands:')
    ..writeln('  serve            run the resident REST service (the spine)')
    ..writeln('  tick             fire due tasks now and exit (the OS wake)')
    ..writeln('  install          register the OS wake for the next due time')
    ..writeln('  uninstall        remove the OS wake')
    ..writeln('  status           report the service and the next fire')
    ..writeln()
    ..writeln('With a positional goal, runs it once and exits.')
    ..writeln('Without a goal on a terminal, runs the styled human CLI.')
    ..writeln('With --automate, or when stdin/stdout is not a terminal, runs')
    ..writeln('the plain CLI: each line is a goal or a command.')
    ..writeln()
    ..writeln('Pilot commands: /schedule /remind /tasks /memory /model '
        '/channels (/help lists all).')
    ..writeln()
    ..writeln('Examples:')
    ..writeln('  sudoer-pilot -c sudoer.json "Remember I prefer oat milk"')
    ..writeln('  sudoer-pilot serve')
    ..writeln('  sudoer-pilot tick')
    ..writeln()
    ..writeln('Exit codes: 0 = the final run completed (or the subcommand '
        'succeeded);')
    ..writeln('            1 = the final run was incomplete or blocked,')
    ..writeln('                or a fatal error occurred;')
    ..writeln('            2 = usage or config error.');
}
