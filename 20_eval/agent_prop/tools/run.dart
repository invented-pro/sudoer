// Eval runner: drive one agent binary through a suite of live tasks.
//
// Usage:
//   dart run.dart --bin <path-to-binary> [--suite canary] [--label <name>]
//                 [--runs N] [--config <path>] [--tasks id1,id2] [--timeout SEC]
//
// For every task x run: materialize the workspace in a fresh temp dir, feed
// the turns (plus /exit) to the binary's automate surface over stdin, capture
// stdout/stderr/exit code/duration and the persisted session, then archive
// everything under runs/<label>/<suite>/<task>/run-N/ plus run.json.
// The binary is copied to versions/<label>/ so a label is self-contained.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final opt = _parseArgs(args);
  if (opt == null || opt['help'] == true) {
    _usage();
    exit(opt == null ? 2 : 0);
  }

  final toolsDir = File(Platform.script.toFilePath()).parent.parent;
  final evalDir = toolsDir.path;
  final repoRoot = _findRepoRoot(evalDir);

  final suite = opt['suite'] as String? ?? 'canary';
  final suiteDir = Directory('$evalDir/suites/$suite');
  if (!suiteDir.existsSync()) {
    stderr.writeln('No such suite: ${suiteDir.path}');
    exit(2);
  }
  final onlyTasks = _splitTasks(opt['tasks'] as String?);

  final binArg = opt['bin'] as String? ?? '$evalDir/sudoer-prop';
  final binSrc = File(binArg);
  if (!binSrc.existsSync()) {
    stderr.writeln('Agent binary not found: ${binSrc.path}');
    stderr.writeln('Build it first: (cd 10_impl/agent_prop && mise run build)');
    exit(2);
  }

  final configArg = opt['config'] as String? ?? '$evalDir/sudoer.json';
  final configFile = File(configArg);
  if (!configFile.existsSync()) {
    stderr.writeln('Provider config not found: ${configFile.path}');
    stderr.writeln('Decrypt it first: sops -d sudoer.enc.json > sudoer.json'
        '  (see 10_impl/AGENTS.md)');
    exit(2);
  }

  final runsPerTask = int.parse(opt['runs'] as String? ?? '3');
  final timeoutSec = int.parse(opt['timeout'] as String? ?? '900');

  final label = opt['label'] as String? ?? _defaultLabel(repoRoot);
  final gitSha = _gitShortSha(repoRoot);
  final binCopy = await _pinVersion(evalDir, label, binSrc, gitSha);

  final taskFiles = suiteDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  var executed = 0;
  var executionFailures = 0;

  for (final taskFile in taskFiles) {
    final task = _loadTask(taskFile);
    if (task == null) {
      stderr.writeln('Skip unreadable task: ${taskFile.path}');
      continue;
    }
    if (onlyTasks != null && !onlyTasks.contains(task['id'])) continue;

    for (var i = 1; i <= runsPerTask; i++) {
      executed++;
      final ok = await _runOnce(
        evalDir: evalDir,
        suite: suite,
        task: task,
        runIndex: i,
        label: label,
        bin: binCopy,
        config: configFile,
        timeoutSec: timeoutSec,
      );
      if (!ok) executionFailures++;
      stdout.write(ok ? '.' : 'x');
    }
    stdout.writeln('  ${task['id']}');
  }

  stdout.writeln('');
  stdout.writeln('label:      $label');
  stdout.writeln('git sha:    $gitSha');
  stdout.writeln('runs:       $executed ($executionFailures execution failures)');
  stdout.writeln('artifacts:  runs/$label/$suite/');
  exit(executionFailures == 0 ? 0 : 1);
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
Eval runner — one binary x one suite x N runs.

Usage:
  dart run.dart --bin <path> [--suite canary] [--label <name>]
                [--runs 3] [--config <path>] [--tasks id1,id2] [--timeout 900]

Defaults: --bin <evalDir>/sudoer-prop, --config <evalDir>/sudoer.json,
          --suite canary, --runs 3, label <gitsha>-<timestamp>.

Artifacts:
  versions/<label>/meta.json + pinned binary copy
  runs/<label>/<suite>/<task>/run-N/run.json  (+ workspace/ copy)
''');
}

Map<String, dynamic>? _loadTask(File f) {
  try {
    final raw = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    raw['id'] ??= f.uri.pathSegments.last.replaceAll('.json', '');
    if (raw['goal'] is String) {
      raw['turns'] = [
        {'goal': raw['goal']}
      ];
    }
    if (raw['turns'] is! List || (raw['turns'] as List).isEmpty) return null;
    return raw;
  } catch (_) {
    return null;
  }
}

Future<bool> _runOnce({
  required String evalDir,
  required String suite,
  required Map<String, dynamic> task,
  required int runIndex,
  required String label,
  required String bin,
  required File config,
  required int timeoutSec,
}) async {
  final taskId = task['id'] as String;
  final runDir =
      Directory('$evalDir/runs/$label/$suite/$taskId/run-$runIndex');
  runDir.createSync(recursive: true);

  final tmp = await Directory.systemTemp.createTemp('sudoer-eval-');
  var ok = true;
  try {
    final workspace = (task['workspace'] as Map<String, dynamic>?) ?? const {};
    workspace.forEach((rel, content) {
      final f = File('${tmp.path}/$rel');
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(content as String);
    });

    final lines = <String>[
      for (final turn in (task['turns'] as List)) (turn as Map)['goal'] as String? ?? (turn)['command'] as String,
      '/exit',
    ];

    final startedAt = DateTime.now().toUtc().toIso8601String();
    final sw = Stopwatch()..start();
    final proc = await Process.start(
      bin,
      ['--config', config.absolute.path],
      workingDirectory: tmp.path,
      environment: {'TERM': 'dumb'},
    );
    proc.stdin.writeln(lines.join('\n'));
    await proc.stdin.flush();
    await proc.stdin.close();

    final stdoutBuf = StringBuffer();
    final stderrBuf = StringBuffer();
    final outDone = proc.stdout
        .transform(utf8.decoder)
        .listen(stdoutBuf.write)
        .asFuture<void>();
    final errDone = proc.stderr
        .transform(utf8.decoder)
        .listen(stderrBuf.write)
        .asFuture<void>();

    var timedOut = false;
    Timer? killer;
    killer = Timer(Duration(seconds: timeoutSec), () {
      timedOut = true;
      proc.kill(ProcessSignal.sigkill);
    });
    final exitCode = await proc.exitCode;
    killer.cancel();
    await Future.wait([outDone, errDone]);
    sw.stop();

    final session = _readNewestSession('${tmp.path}/.sudoer/sessions');
    final runJson = {
      'task': taskId,
      'suite': suite,
      'label': label,
      'runIndex': runIndex,
      'startedAt': startedAt,
      'durationMs': sw.elapsedMilliseconds,
      'timedOut': timedOut,
      'exitCode': exitCode,
      'stdout': stdoutBuf.toString(),
      'stderr': stderrBuf.toString(),
      'runs': session == null ? null : _summarize(session),
      'session': session,
    };
    File('${runDir.path}/run.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(runJson));

    _copyDir(tmp, Directory('${runDir.path}/workspace'));
  } catch (e) {
    stderr.writeln('Execution error on $taskId run $runIndex: $e');
    ok = false;
  } finally {
    tmp.deleteSync(recursive: true);
  }
  return ok;
}

Map<String, dynamic>? _readNewestSession(String dirPath) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) return null;
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
  if (files.isEmpty) return null;
  try {
    return jsonDecode(files.first.readAsStringSync()) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

/// Per-goal summaries derived from the C5 session transcript (user / assistant
/// / observation entries; assistant actions are finish or tool_calls).
List<Map<String, dynamic>> _summarize(Map<String, dynamic> session) {
  final out = <Map<String, dynamic>>[];
  Map<String, dynamic>? cur;
  for (final entry in (session['transcript'] as List? ?? const [])) {
    final e = entry as Map<String, dynamic>;
    switch (e['role']) {
      case 'user':
        cur = {
          'goal': e['text'],
          'steps': 0,
          'toolCalls': <String>[],
          'errors': 0,
          'finished': false,
          'answer': null,
        };
        out.add(cur);
        break;
      case 'assistant':
        if (cur == null) break;
        cur['steps'] = (cur['steps'] as int) + 1;
        final action = e['action'];
        if (action is Map) {
          if (action['type'] == 'finish') {
            cur['finished'] = true;
            cur['answer'] = action['answer'];
          } else if (action['type'] == 'tool_calls') {
            for (final call in (action['tool_calls'] as List? ?? const [])) {
              (cur['toolCalls'] as List).add((call as Map)['name']);
            }
          }
        }
        break;
      case 'observation':
        if (cur != null && e['outcome'] != 'ok') {
          cur['errors'] = (cur['errors'] as int) + 1;
        }
        break;
    }
  }
  return out;
}

Future<String> _pinVersion(
    String evalDir, String label, File binSrc, String gitSha) async {
  final versionDir = Directory('$evalDir/versions/$label');
  versionDir.createSync(recursive: true);
  final copy = File('${versionDir.path}/sudoer-prop');
  binSrc.copySync(copy.path);
  try {
    Process.runSync('chmod', ['+x', copy.path]);
  } catch (_) {}
  File('${versionDir.path}/meta.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'label': label,
        'gitSha': gitSha,
        'binOriginalPath': binSrc.absolute.path,
        'binSha256': _sha256(binSrc),
        'capturedAt': DateTime.now().toUtc().toIso8601String(),
      }));
  return copy.path;
}

String _sha256(File f) {
  try {
    final r = Process.runSync('sha256sum', [f.path]);
    if (r.exitCode == 0) {
      return (r.stdout as String).split(' ').first.trim();
    }
  } catch (_) {}
  return 'size:${f.lengthSync()}';
}

String _defaultLabel(String repoRoot) {
  final now = DateTime.now();
  final ts = now.toUtc().toIso8601String().substring(0, 16);
  final sha = _gitShortSha(repoRoot);
  final safeTs = ts.replaceAll(RegExp('[:T]'), '-');
  return sha == 'unknown' ? 'local-$safeTs' : '$sha-$safeTs';
}

String _gitShortSha(String repoRoot) {
  try {
    final r = Process.runSync('git', ['rev-parse', '--short', 'HEAD'],
        workingDirectory: repoRoot);
    if (r.exitCode == 0) return (r.stdout as String).trim();
  } catch (_) {}
  return 'unknown';
}

String _findRepoRoot(String from) {
  var dir = Directory(from);
  while (true) {
    if (Directory('${dir.path}/.git').existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) return from;
    dir = parent;
  }
}

void _copyDir(Directory src, Directory dst) {
  dst.createSync(recursive: true);
  for (final e in src.listSync(recursive: true)) {
    final rel = e.path.substring(src.path.length + 1);
    final target = '${dst.path}/$rel';
    if (e is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (e is File) {
      File(target).parent.createSync(recursive: true);
      e.copySync(target);
    }
  }
}

Set<String>? _splitTasks(String? csv) =>
    csv == null || csv.isEmpty ? null : csv.split(',').toSet();
