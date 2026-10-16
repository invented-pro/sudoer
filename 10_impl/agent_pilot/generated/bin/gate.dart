import 'dart:io';

import 'package:args/args.dart';

import 'package:sudoer_pilot/src/gate/pilot_smoke.dart'
    show pilotCliSmoke, runPilotSuite;
import 'package:sudoer_pilot/src/gate/runner.dart'
    show runSuite, findRepoRoot, findPackageRoot;

/// The Pilot build gate (C6/`agent_pilot/gate.md`): every Prop task plus
/// every Pilot task, run against the built `sudoer-pilot`, then the CLI
/// smoke — the built binary's own subcommands (`serve`, `tick`, `install`),
/// spawned as processes, never emulated in-process. Green gate = tier done.
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('tasks',
        help: 'Directory of gate task JSON files (repeatable not needed; '
            'the suite runs both task sets).')
    ..addFlag('smoke', defaultsTo: true, help: 'Run the CLI smoke checks.')
    ..addFlag('prop-only',
        defaultsTo: false, hide: true, help: 'Run only the Prop task set.');

  final results = parser.parse(args);
  final repoRoot = findRepoRoot().path;
  final propTasks = results['tasks'] as String? ??
      '$repoRoot/00_bp/agent_prop/tasks';
  final pilotTasks = '$repoRoot/00_bp/agent_pilot/tasks';
  final packageRoot = findPackageRoot().path;

  print('Pilot build gate');
  print('tasks: $propTasks');
  print('       $pilotTasks');
  print('');

  var failures = await runSuite(propTasks);
  failures += await runPilotSuite(pilotTasks);
  if (results['smoke'] as bool) {
    failures += await pilotCliSmoke(packageRoot);
  }

  print('');
  if (failures == 0) {
    print('GATE PASSED');
    exit(0);
  }
  stderr.writeln('GATE FAILED ($failures failures)');
  exit(1);
}
