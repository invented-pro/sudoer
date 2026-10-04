import 'dart:io';

import 'package:args/args.dart';
import 'package:sudoer_prop/src/gate/runner.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('tasks', help: 'Directory of gate task JSON files.')
    ..addFlag('smoke', defaultsTo: true, help: 'Run the CLI smoke checks.');

  final results = parser.parse(args);
  final tasksDir = results['tasks'] as String? ??
      '${findRepoRoot().path}/00_bp/agent_prop/tasks';

  print('Prop build gate');
  print('tasks: $tasksDir');
  print('');

  var failures = await runSuite(tasksDir);
  if (results['smoke'] as bool) {
    failures += await cliSmoke(findPackageRoot().path);
  }

  print('');
  if (failures == 0) {
    print('GATE PASSED');
    exit(0);
  }
  stderr.writeln('GATE FAILED ($failures failures)');
  exit(1);
}
