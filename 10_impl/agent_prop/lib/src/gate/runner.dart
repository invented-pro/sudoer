import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../interface.dart';
import '../models.dart';
import '../providers/scripted.dart';
import '../session.dart';
import 'task.dart';

const Map<String, dynamic> _gateDefaults = {
  'provider': {'kind': 'ollama', 'model': 'scripted', 'context_window': 8192},
  'workspace_root': '.',
  // The gate is offline: keep the web tools out of every task.
  'web': {'enabled': false},
};

final class TaskReport {
  TaskReport(this.id, this.failures);
  final String id;
  final List<String> failures;
  bool get passed => failures.isEmpty;
}

/// Run one task in an isolated temp workspace with the scripted provider,
/// driving the interactive session (C6) with the task's turns.
Future<TaskReport> runTask(Task task) async {
  final failures = <String>[];
  final temp = Directory.systemTemp.createTempSync('sudoer-gate-');
  try {
    for (final entry in task.workspace.entries) {
      final file = File(p.join(temp.path, entry.key));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }

    final merged = Config.mergeJson(_gateDefaults, task.configOverride);
    merged['workspace_root'] = temp.path;
    merged['session_dir'] = p.join(temp.path, '.sudoer', 'sessions');
    final config = Config.fromJson(merged);

    final callLog = <String>[];
    final provider = ScriptedProvider.fromJson(task.script);
    final out = StringBuffer();
    final err = StringBuffer();
    final lines = <String>[
      for (final turn in task.turns) turn.goal ?? turn.command!,
      '/exit',
    ];

    final outcome = await runRepl(
      config: config,
      input: Stream<String>.fromIterable(lines),
      out: out,
      err: err,
      providerFactory: (_) => provider,
      callLog: callLog,
    );

    final last = outcome.runs.isEmpty ? null : outcome.runs.last;

    if (task.expect.status != null) {
      if (last == null) {
        failures.add(
            'status: expected ${task.expect.status!.wire}, but no goal ran');
      } else if (last.status != task.expect.status) {
        failures.add(
            'status: expected ${task.expect.status!.wire}, got ${last.status.wire}');
      }
    }
    _checkAnswer(
      failures,
      'answer',
      last?.answer,
      task.expect.answerEquals,
      task.expect.answerContains,
    );

    if (task.expect.runs.isNotEmpty) {
      if (outcome.runs.length != task.expect.runs.length) {
        failures.add(
            'runs: expected ${task.expect.runs.length}, got ${outcome.runs.length}');
      } else {
        for (var i = 0; i < task.expect.runs.length; i++) {
          final expected = task.expect.runs[i];
          final actual = outcome.runs[i];
          if (expected.status != null && expected.status != actual.status) {
            failures.add(
                'runs[$i].status: expected ${expected.status!.wire}, got ${actual.status.wire}');
          }
          _checkAnswer(
            failures,
            'runs[$i].answer',
            actual.answer,
            expected.answerEquals,
            expected.answerContains,
          );
        }
      }
    }

    if (task.expect.plan != null) {
      final actual = [for (final item in outcome.session.plan) item.text];
      if (actual.join('\u0000') != task.expect.plan!.join('\u0000')) {
        failures.add('plan: expected ${task.expect.plan}, got $actual');
      }
    }

    if (task.expect.sessionPersisted == true) {
      try {
        final loaded = Session.load(config.sessionDir, outcome.session.id);
        if (loaded.id != outcome.session.id ||
            loaded.transcript.length != outcome.session.transcript.length) {
          failures.add('session: persisted session does not match in memory');
        }
      } on Object catch (e) {
        failures.add('session: not persisted: $e');
      }
    }

    if (task.expect.stdoutContains != null &&
        !out.toString().contains(task.expect.stdoutContains!)) {
      failures.add(
          'stdout: expected to contain "${task.expect.stdoutContains}"');
    }

    if (task.expect.tools != null &&
        task.expect.tools!.join(',') != callLog.join(',')) {
      failures.add('tools: expected ${task.expect.tools}, got $callLog');
    }

    if (task.expect.files != null) {
      for (final entry in task.expect.files!.entries) {
        final file = File(p.join(temp.path, entry.key));
        final actual = file.existsSync() ? file.readAsStringSync() : null;
        if (actual != entry.value) {
          failures.add(
              'file ${entry.key}: expected ${jsonEncode(entry.value)}, got ${jsonEncode(actual)}');
        }
      }
    }
  } on Object catch (e, st) {
    failures.add('threw: $e\n$st');
  } finally {
    temp.deleteSync(recursive: true);
  }
  return TaskReport(task.id, failures);
}

void _checkAnswer(
  List<String> failures,
  String label,
  String? actual,
  String? equals,
  String? contains,
) {
  if (equals != null && actual != equals) {
    failures.add('$label: expected "$equals", got "$actual"');
  }
  if (contains != null && (actual == null || !actual.contains(contains))) {
    failures.add('$label: expected to contain "$contains", got "$actual"');
  }
}

/// Run every task in [tasksDir]. Returns the number of failures.
Future<int> runSuite(String tasksDir) async {
  final files = Directory(tasksDir)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) {
    stderr.writeln('no tasks found in $tasksDir');
    return 1;
  }
  var failed = 0;
  for (final file in files) {
    final task = Task.fromJson(
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
    final report = await runTask(task);
    if (report.passed) {
      print('PASS  ${report.id}');
    } else {
      failed++;
      print('FAIL  ${report.id}');
      for (final failure in report.failures) {
        print('      $failure');
      }
    }
  }
  print('');
  print('${files.length - failed}/${files.length} tasks passed');
  return failed;
}

/// CLI smoke: spawn the real `bin/sudoer.dart` offline via the scripted seam.
Future<int> cliSmoke(String packageRoot) async {
  final failures = <String>[];
  final temp = Directory.systemTemp.createTempSync('sudoer-smoke-');
  try {
    final workspace = Directory(p.join(temp.path, 'ws'))..createSync();
    File(p.join(workspace.path, 'README.md')).writeAsStringSync('hello world\n');

    final configFile = File(p.join(temp.path, 'config.json'))
      ..writeAsStringSync(jsonEncode({
        'provider': {
          'kind': 'ollama',
          'model': 'scripted',
          'context_window': 8192,
        },
        'workspace_root': workspace.path,
      }));

    final scriptFile = File(p.join(temp.path, 'script.json'));
    void writeScript(String scriptJson) =>
        scriptFile.writeAsStringSync(scriptJson);
    Map<String, String> env() => {
          ...Platform.environment,
          'SUDOER_SCRIPT_FILE': scriptFile.path,
        };

    // One-shot complete.
    writeScript(jsonEncode({
      'steps': [
        {
          'complete': {
            'text': 'reading',
            'tool_calls': [
              {
                'type': 'tool_call',
                'name': 'read',
                'arguments': {'path': 'README.md'},
              }
            ],
          }
        },
        {'complete': {'text': 'hello world'}},
      ]
    }));
    final complete = Process.runSync(
      Platform.resolvedExecutable,
      ['run', 'bin/sudoer.dart', '--config', configFile.path,
        'Read README.md and answer with its contents.'],
      workingDirectory: packageRoot,
      environment: env(),
    );
    if (complete.exitCode != 0) {
      failures.add('complete run: expected exit 0, got ${complete.exitCode}');
    }
    if (!complete.stdout.toString().contains('hello world')) {
      failures.add('complete run: stdout missing answer: ${complete.stdout}');
    }

    // One-shot blocked.
    writeScript(jsonEncode({
      'steps': [
        {'error': 'unrecoverable'}
      ]
    }));
    final blocked = Process.runSync(
      Platform.resolvedExecutable,
      ['run', 'bin/sudoer.dart', '--config', configFile.path, 'Do anything.'],
      workingDirectory: packageRoot,
      environment: env(),
    );
    if (blocked.exitCode == 0) {
      failures.add('blocked run: expected non-zero exit');
    }
    if (!blocked.stderr.toString().contains('blocked')) {
      failures.add('blocked run: stderr missing diagnostic: ${blocked.stderr}');
    }

    // Interactive session over stdin: goal then /exit.
    writeScript(jsonEncode({
      'steps': [
        {
          'complete': {
            'text': 'reading',
            'tool_calls': [
              {
                'type': 'tool_call',
                'name': 'read',
                'arguments': {'path': 'README.md'},
              }
            ],
          }
        },
        {'complete': {'text': 'hello world'}},
      ]
    }));
    final interactive = await Process.start(
      Platform.resolvedExecutable,
      ['run', 'bin/sudoer.dart', '--automate', '--config', configFile.path],
      workingDirectory: packageRoot,
      environment: env(),
    );
    interactive.stdin.writeln('Read README.md and answer with its contents.');
    interactive.stdin.writeln('/exit');
    await interactive.stdin.close();
    final interactiveOut =
        await interactive.stdout.transform(utf8.decoder).join();
    final interactiveErr =
        await interactive.stderr.transform(utf8.decoder).join();
    final interactiveCode = await interactive.exitCode;
    if (interactiveCode != 0) {
      failures.add('interactive: expected exit 0, got $interactiveCode');
    }
    if (!interactiveOut.contains('hello world')) {
      failures.add('interactive: stdout missing answer: $interactiveOut');
    }
    if (interactiveErr.contains('Unknown')) {
      failures.add('interactive: stderr reported an error: $interactiveErr');
    }
  } finally {
    temp.deleteSync(recursive: true);
  }

  if (failures.isEmpty) {
    print('PASS  cli-smoke (one-shot complete + blocked; interactive)');
    return 0;
  }
  print('FAIL  cli-smoke');
  for (final failure in failures) {
    print('      $failure');
  }
  return failures.length;
}

/// Walk up from [start] until [predicate] matches.
Directory findUpwards(String start, bool Function(Directory) predicate) {
  var dir = Directory(start).absolute;
  while (true) {
    if (predicate(dir)) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('could not locate directory upward from $start');
    }
    dir = parent;
  }
}

Directory findRepoRoot([String? from]) => findUpwards(
      from ?? Directory.current.path,
      (d) =>
          Directory(p.join(d.path, '00_bp', 'agent_prop', 'tasks')).existsSync(),
    );

Directory findPackageRoot([String? from]) => findUpwards(
      from ?? Directory.current.path,
      (d) => File(p.join(d.path, 'pubspec.yaml')).existsSync(),
    );
