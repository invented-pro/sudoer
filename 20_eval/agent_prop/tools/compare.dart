// Eval comparator: head-to-head report for two recorded labels on one suite.
//
// Usage:
//   dart compare.dart --suite canary --a <labelA> --b <labelB> [--open]
//
// Aggregates check.json verdicts written by check.dart and emits a markdown
// report under reports/: per-task pass rates, mean steps and duration, and a
// per-task winner (pass rate first, then efficiency; ties otherwise).
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
  final a = opt['a'] as String?;
  final b = opt['b'] as String?;
  if (a == null || b == null) {
    stderr.writeln('--a and --b are required');
    exit(2);
  }

  final suiteDir = Directory('$evalDir/suites/$suite');
  if (!suiteDir.existsSync()) {
    stderr.writeln('No such suite: ${suiteDir.path}');
    exit(2);
  }

  final tasks = suiteDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .map((f) => _taskId(f))
      .whereType<String>()
      .toList()
    ..sort();

  final rows = <_Row>[];
  for (final task in tasks) {
    final sa = _aggregate('$evalDir/runs/$a/$suite/$task');
    final sb = _aggregate('$evalDir/runs/$b/$suite/$task');
    rows.add(_Row(task, sa, sb, _winner(sa, sb)));
  }

  final winsB = rows.where((r) => r.winner == 'b').length;
  final winsA = rows.where((r) => r.winner == 'a').length;
  final ties = rows.where((r) => r.winner == 'tie').length;
  final noData = rows.where((r) => r.winner == 'none').length;

  final buf = StringBuffer()
    ..writeln('# Eval compare — suite `$suite`')
    ..writeln('')
    ..writeln('- A: `$a`')
    ..writeln('- B: `$b`')
    ..writeln('- Generated: ${DateTime.now().toUtc().toIso8601String()}')
    ..writeln('')
    ..writeln('| Task | A pass | B pass | A steps | B steps | A ms | B ms | Winner |')
    ..writeln('| --- | --- | --- | --- | --- | --- | --- | --- |');
  for (final r in rows) {
    String w;
    switch (r.winner) {
      case 'a':
        w = 'A';
        break;
      case 'b':
        w = 'B';
        break;
      case 'none':
        w = 'no data';
        break;
      default:
        w = 'tie';
    }
    buf.writeln('| ${r.task} | ${_rate(r.a)} | ${_rate(r.b)} | '
        '${_num(r.a?['meanSteps'])} | ${_num(r.b?['meanSteps'])} | '
        '${_num(r.a?['meanMs'])} | ${_num(r.b?['meanMs'])} | $w |');
  }
  buf
    ..writeln('')
    ..writeln('**Head-to-head:** B wins $winsB · A wins $winsA · ties $ties'
        '${noData > 0 ? ' · no data $noData' : ''}')
    ..writeln('');

  final date = DateTime.now().toUtc().toIso8601String().substring(0, 10);
  final out = File(
      '$evalDir/reports/${date}_${suite}_${_safe(a)}_vs_${_safe(b)}.md');
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(buf.toString());

  stdout.write(buf.toString());
  stdout.writeln('report: ${out.path}');
}

Map<String, dynamic>? _aggregate(String taskDir) {
  final dir = Directory(taskDir);
  if (!dir.existsSync()) return null;
  final checks = <Map<String, dynamic>>[];
  for (final d in dir
      .listSync()
      .whereType<Directory>()
      .where((d) => d.path.contains('/run-'))) {
    final f = File('${d.path}/check.json');
    if (f.existsSync()) {
      checks.add(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
    }
  }
  if (checks.isEmpty) return null;
  final passes = checks.where((c) => c['pass'] == true).length;
  final steps = checks
      .map((c) => ((c['metrics'] as Map)['steps'] as num?) ?? 0)
      .toList();
  final ms = checks
      .map((c) => ((c['metrics'] as Map)['durationMs'] as num?) ?? 0)
      .toList();
  double mean(List<num> xs) => xs.isEmpty ? 0 : xs.reduce((x, y) => x + y) / xs.length;
  return {
    'runs': checks.length,
    'passes': passes,
    'passRate': passes / checks.length,
    'meanSteps': mean(steps),
    'meanMs': mean(ms),
  };
}

String _winner(Map<String, dynamic>? a, Map<String, dynamic>? b) {
  if (a == null && b == null) return 'none';
  if (a == null) return 'b';
  if (b == null) return 'a';
  final pa = a['passRate'] as double;
  final pb = b['passRate'] as double;
  if (pb > pa) return 'b';
  if (pa > pb) return 'a';
  // Equal correctness: fewer steps wins.
  final sa = a['meanSteps'] as double;
  final sb = b['meanSteps'] as double;
  if (sb < sa - 0.001) return 'b';
  if (sa < sb - 0.001) return 'a';
  return 'tie';
}

String _rate(Map<String, dynamic>? s) =>
    s == null ? '—' : '${s['passes']}/${s['runs']}';
String _num(num? v) => v == null ? '—' : v.toStringAsFixed(1);
String _safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

String? _taskId(File f) {
  try {
    return (jsonDecode(f.readAsStringSync()) as Map)['id'] as String? ??
        f.uri.pathSegments.last.replaceAll('.json', '');
  } catch (_) {
    return null;
  }
}

class _Row {
  _Row(this.task, this.a, this.b, this.winner);
  final String task;
  final Map<String, dynamic>? a;
  final Map<String, dynamic>? b;
  final String winner;
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
Eval comparator — head-to-head markdown report for two labels.

Usage:
  dart compare.dart --suite canary --a <labelA> --b <labelB>
''');
}
