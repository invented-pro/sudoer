// Eval checker: score recorded runs against their task's `check` block.
//
// Usage:
//   dart check.dart --label <name> [--suite canary] [--tasks id1,id2]
//
// Reads runs/<label>/<suite>/<task>/run-N/run.json (+ the archived workspace
// copy) and writes a check.json verdict next to each run. Checks are all
// optional and deterministic; a run passes when every declared check passes.
//
// Supported check keys:
//   finished        true — the last goal in the session reached a finish action
//   answerEquals / answerContains    against the last finish answer
//   stdoutContains  against the run's captured stdout
//   files           { path: "substr" | {contains|equals} } in the final workspace
//   command / commandContains        run a verify command (POSIX shell) in the
//                   final workspace copy and match its output
//   maxSteps / maxErrors             efficiency guards (summed over the session)
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final opt = _parseArgs(args);
  if (opt == null || opt['help'] == true) {
    _usage();
    exit(opt == null ? 2 : 0);
  }

  final evalDir = File(Platform.script.toFilePath()).parent.parent.path;
  final suite = opt['suite'] as String? ?? 'canary';
  final label = opt['label'] as String?;
  if (label == null) {
    stderr.writeln('--label is required');
    exit(2);
  }
  final onlyTasks = _splitCsv(opt['tasks'] as String?);

  final suiteDir = Directory('$evalDir/suites/$suite');
  if (!suiteDir.existsSync()) {
    stderr.writeln('No such suite: ${suiteDir.path}');
    exit(2);
  }

  final taskFiles = suiteDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final perTask = <String, List<bool>>{};

  for (final taskFile in taskFiles) {
    final task = _loadTask(taskFile);
    if (task == null) continue;
    final id = task['id'] as String;
    if (onlyTasks != null && !onlyTasks.contains(id)) continue;

    final taskRunsDir = Directory('$evalDir/runs/$label/$suite/$id');
    if (!taskRunsDir.existsSync()) {
      if (onlyTasks != null) continue; // excluded from this invocation
      stdout.writeln('$id: no recorded runs (did run.dart execute it?)');
      perTask[id] = [];
      continue;
    }

    final verdicts = <bool>[];
    final runDirs = taskRunsDir
        .listSync()
        .whereType<Directory>()
        .where((d) => d.path.contains('/run-'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final runDir in runDirs) {
      final runFile = File('${runDir.path}/run.json');
      if (!runFile.existsSync()) continue;
      final run = jsonDecode(runFile.readAsStringSync()) as Map<String, dynamic>;
      final verdict = _score(task, run, Directory('${runDir.path}/workspace'));
      File('${runDir.path}/check.json').writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(verdict));
      verdicts.add(verdict['pass'] as bool);
      final mark = verdict['pass'] as bool ? 'PASS' : 'FAIL';
      stdout.writeln('$id run-${run['runIndex']}: $mark');
      for (final f in verdict['failures'] as List<String>) {
        stdout.writeln('    - $f');
      }
    }
    perTask[id] = verdicts;
  }

  stdout.writeln('');
  stdout.writeln('label: $label  suite: $suite');
  var allPass = true;
  for (final e in perTask.entries) {
    if (e.value.isEmpty) {
      stdout.writeln('  ${e.key}: NO RUNS');
      allPass = false;
      continue;
    }
    final passes = e.value.where((p) => p).length;
    if (passes < e.value.length) allPass = false;
    stdout.writeln('  ${e.key}: $passes/${e.value.length} pass');
  }
  exit(allPass ? 0 : 1);
}

Map<String, dynamic> _score(
    Map<String, dynamic> task, Map<String, dynamic> run, Directory workspace) {
  final check = (task['check'] as Map<String, dynamic>?) ?? const {};
  final failures = <String>[];
  final summaries =
      (run['runs'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? [];
  final last = summaries.isEmpty ? null : summaries.last;

  if (run['timedOut'] == true) failures.add('run timed out');
  if (check['finished'] == true) {
    if (last == null) {
      failures.add('no session transcript captured');
    } else if (last['finished'] != true) {
      failures.add('last goal did not reach a finish action');
    }
  }

  final answer = last?['answer'];
  if (check['answerEquals'] is String) {
    if (answer != check['answerEquals']) {
      failures.add("answer equals '${check['answerEquals']}' — got: $answer");
    }
  }
  if (check['answerContains'] is String) {
    if (answer is! String || !answer.contains(check['answerContains'])) {
      failures.add(
          "answer contains '${check['answerContains']}' — got: $answer");
    }
  }
  if (check['stdoutContains'] is String) {
    final so = run['stdout'] as String? ?? '';
    if (!so.contains(check['stdoutContains'])) {
      failures.add("stdout contains '${check['stdoutContains']}'");
    }
  }

  for (final e in ((check['files'] as Map<String, dynamic>?) ?? const {})
      .entries) {
    final path = e.key;
    final expect = e.value;
    final f = File('${workspace.path}/$path');
    if (!f.existsSync()) {
      failures.add("file missing: $path");
      continue;
    }
    final content = f.readAsStringSync().replaceAll('\r\n', '\n');
    final want = expect is Map<String, dynamic>
        ? (expect['equals'] ?? expect['contains'])
        : expect;
    final mode = expect is Map<String, dynamic> && expect['equals'] != null
        ? 'equals'
        : 'contains';
    final norm = want is String ? want.replaceAll('\r\n', '\n') : want;
    if (mode == 'equals' ? content.trim() != norm.toString().trim()
        : !content.contains(norm.toString())) {
      failures.add("file $path $mode '$norm'");
    }
  }

  if (check['command'] is String) {
    if (!Platform.isLinux && !Platform.isMacOS) {
      failures.add('command check requires a POSIX shell');
    } else {
      final r = Process.runSync('/bin/sh', ['-c', check['command'] as String],
          workingDirectory: workspace.path, runInShell: false);
      final output = '${r.stdout}${r.stderr}'.trim();
      String snippet(String s) => s.length > 200 ? '${s.substring(0, 200)}…' : s;
      if (r.exitCode != 0) {
        failures.add("command '${check['command']}' exited ${r.exitCode}: "
            '${snippet(output)}');
      } else if (check['commandContains'] is String &&
          !output.contains(check['commandContains'])) {
        failures.add("command output contains '${check['commandContains']}' — "
            'got: ${snippet(output)}');
      }
    }
  }

  final metrics = {
    'steps': summaries.fold<int>(0, (n, s) => n + (s['steps'] as int? ?? 0)),
    'toolCalls': summaries.fold<int>(0, (n, s) => n + (s['toolCalls'] as List).length),
    'errors': summaries.fold<int>(0, (n, s) => n + (s['errors'] as int? ?? 0)),
    'durationMs': run['durationMs'],
  };
  if (check['maxSteps'] is int && (metrics['steps'] as int) > check['maxSteps']) {
    failures.add("steps ${metrics['steps']} > maxSteps ${check['maxSteps']}");
  }
  if (check['maxErrors'] is int && (metrics['errors'] as int) > check['maxErrors']) {
    failures.add("errors ${metrics['errors']} > maxErrors ${check['maxErrors']}");
  }

  return {'pass': failures.isEmpty, 'failures': failures, 'metrics': metrics};
}

Map<String, dynamic>? _loadTask(File f) {
  try {
    final raw = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    raw['id'] ??= f.uri.pathSegments.last.replaceAll('.json', '');
    return raw;
  } catch (_) {
    return null;
  }
}

Map<String, dynamic>? _parseArgs(List<String> args) {
  final out = <String, dynamic>{};
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--help' || a == '-h') {
      out['help'] = true;
      continue;
    }
    if (!a.startsWith('--') || i + 1 >= args.length) return null;
    out[a.substring(2)] = args[++i];
  }
  return out;
}

void _usage() {
  stdout.writeln('''
Eval checker — score recorded runs of one label against task checks.

Usage:
  dart check.dart --label <name> [--suite canary] [--tasks id1,id2]

Writes check.json next to each run.json; exit 0 only if every run passes.
''');
}

Set<String>? _splitCsv(String? csv) =>
    csv == null || csv.isEmpty ? null : csv.split(',').toSet();
