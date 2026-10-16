import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'pilot_runner.dart' show runPilotTask;
import 'pilot_task.dart';

/// Run every Pilot task in [tasksDir]. Returns the number of failures.
Future<int> runPilotSuite(String tasksDir) async {
  final files = Directory(tasksDir)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) {
    stderr.writeln('no pilot tasks found in $tasksDir');
    return 1;
  }
  var failed = 0;
  for (final file in files) {
    final task = PilotTask.fromJson(
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
    if (task.hostShellPosix && Platform.isWindows) {
      print('SKIP  ${task.id} (POSIX host shell)');
      continue;
    }
    final report = await runPilotTask(task);
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
  print('${files.length} pilot tasks, ${files.length - failed} passed');
  return failed;
}

/// The Pilot CLI smoke (C6): every check spawns the real `sudoer-pilot`
/// (via the scripted-provider seam — no real LLM, no network), never an
/// in-process shortcut. Identity, `serve`, the web login + channel
/// round-trip, config get/reject, `tick`, and `install`.
Future<int> pilotCliSmoke(String packageRoot) async {
  final failures = <String>[];

  // The Prop smoke, on the Pilot binary: one-shot complete exits 0; blocked
  // exits non-zero; interactive goal + /exit exits 0.
  failures.addAll(await _propSmoke(packageRoot));

  // Identity: --version names sudoer-pilot; --help names the Pilot agent
  // and shows `Usage: sudoer-pilot …`.
  final version = await _runSudoer(packageRoot, ['--version']);
  if (!version.stdout.contains('sudoer-pilot')) {
    failures.add(
        'identity: --version must print sudoer-pilot, got "${version.stdout}"');
  }
  final help = await _runSudoer(packageRoot, ['--help']);
  if (!help.stdout.contains('Pilot')) {
    failures.add('identity: --help must name the Pilot agent');
  }
  if (!help.stdout.contains('Usage: sudoer-pilot')) {
    failures.add('identity: --help must show "Usage: sudoer-pilot"');
  }
  if (help.stdout.contains('sudoer-prop') ||
      help.stdout.contains('Prop coding agent')) {
    failures.add('identity: --help still speaks Prop\'s name');
  }

  // `tick`: with a due task it fires it and exits 0.
  final tickDir = await _sandboxDir();
  try {
    final config = _tickConfig(tickDir);
    File(p.join(tickDir.path, '.sudoer', 'tasks.json'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({
        'tasks': [
          {
            // Due 30 seconds ago: the wake fired on time, so the default
            // report policy (missed-while-away) does not apply (C11).
            'id': 'smoke',
            'when': DateTime.now()
                .toUtc()
                .subtract(const Duration(seconds: 30))
                .toIso8601String(),
            'next_due': DateTime.now()
                .toUtc()
                .subtract(const Duration(seconds: 30))
                .toIso8601String(),
            'goal': 'Smoke: say done',
            'channel': 'notify',
            'status': 'pending',
            'created': '2026-10-05T08:00:00Z',
            'updated': '2026-10-05T08:00:00Z',
          },
        ],
        'fires': [],
      }));
    final scriptFile = File(p.join(tickDir.path, 'script.json'))
      ..writeAsStringSync(jsonEncode({
        'steps': [
          {
            'complete': {
              'text': 'Reminder delivered.',
              'tool_calls': [
                {
                  'type': 'tool_call',
                  'name': 'notify',
                  'arguments': {'message': 'Smoke: say done'},
                }
              ],
            }
          },
        ],
      }));
    final tick = await _runSudoer(packageRoot, [
      'tick',
      '--config', config.path,
    ],
        env: {'SUDOER_SCRIPT_FILE': scriptFile.path});
    if (tick.exit != 0) {
      failures.add('tick: expected exit 0, got ${tick.exit} '
          '(stderr: ${tick.stderr})');
    }
    final tasks = jsonDecode(
        File(p.join(tickDir.path, '.sudoer', 'tasks.json')).readAsStringSync());
    final status = (tasks['tasks'][0] as Map)['status'];
    if (status != 'done' && status != 'fired') {
      failures.add('tick: the due task did not fire (status: $status)');
    }

    // `install`: reports the recorded wake unit without touching the host —
    // exercised through the same binary; the fake is pinned by the suite,
    // so here we assert the command shape.
    final install = await _runSudoer(packageRoot, [
      'install',
      '--config', config.path,
    ]);
    if (install.exit != 0) {
      failures.add('install: expected exit 0, got ${install.exit}');
    }
    if (!install.stdout.contains('wake installed') &&
        !install.stdout.contains('no pending tasks')) {
      failures.add(
          'install: expected a wake report, got "${install.stdout}"');
    }
  } finally {
    tickDir.deleteSync(recursive: true);
  }

  // `serve`: boots the REST server, serves one API run to its SSE result,
  // logs in with the token for a session cookie, rejects a secret-valued
  // config patch, and exits 0 on SIGTERM.
  failures.addAll(await _serveSmoke(packageRoot));

  if (failures.isEmpty) {
    print('PASS  pilot-cli-smoke (identity, serve, tick, install, '
        'web/channel, config)');
    return 0;
  }
  print('FAIL  pilot-cli-smoke');
  for (final failure in failures) {
    print('      $failure');
  }
  return failures.length;
}

/// The Prop smoke checks, driven through the Pilot entrypoint.
Future<List<String>> _propSmoke(String packageRoot) async {
  final failures = <String>[];
  final dir = await _sandbox();
  try {
    final workspace = Directory(p.join(dir.path, 'ws'))..createSync();
    File(p.join(workspace.path, 'README.md')).writeAsStringSync('hello world\n');
    final config = File(p.join(dir.path, 'config.json'))
      ..writeAsStringSync(jsonEncode({
        'provider': {
          'kind': 'ollama',
          'model': 'scripted',
          'context_window': 8192,
        },
        'workspace_root': workspace.path,
        'session_dir': p.join(dir.path, 'sessions'),
      }));
    final script = File(p.join(dir.path, 'script.json'));
    void write(String text) => script.writeAsStringSync(text);

    write(jsonEncode({
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
    final complete = await _runSudoer(
      packageRoot,
      ['--automate', '--config', config.path, 'Read README.md.'],
      env: {'SUDOER_SCRIPT_FILE': script.path},
    );
    if (complete.exit != 0) {
      failures.add('complete run: expected exit 0, got ${complete.exit}');
    }
    if (!complete.stdout.contains('hello world')) {
      failures.add('complete run: stdout missing answer');
    }

    write(jsonEncode({
      'steps': [
        {'error': 'unrecoverable'}
      ]
    }));
    final blocked = await _runSudoer(
      packageRoot,
      ['--automate', '--config', config.path, 'Do anything.'],
      env: {'SUDOER_SCRIPT_FILE': script.path},
    );
    if (blocked.exit == 0) failures.add('blocked run: expected non-zero exit');
    if (!blocked.stderr.contains('blocked')) {
      failures.add('blocked run: stderr missing diagnostic');
    }

    write(jsonEncode({
      'steps': [
        {'complete': {'text': 'hello world'}},
      ]
    }));
    final interactive = await Process.start(
      Platform.resolvedExecutable,
      ['run', 'bin/sudoer.dart', '--automate', '--config', config.path],
      workingDirectory: packageRoot,
      environment: {
        ...Platform.environment,
        'SUDOER_SCRIPT_FILE': script.path,
      },
    );
    interactive.stdin.writeln('Read README.md and answer with its contents.');
    interactive.stdin.writeln('/exit');
    await interactive.stdin.close();
    final out = await interactive.stdout.transform(utf8.decoder).join();
    final code = await interactive.exitCode;
    if (code != 0) failures.add('interactive: expected exit 0, got $code');
    if (!out.contains('hello world')) {
      failures.add('interactive: stdout missing answer');
    }
  } finally {
    dir.deleteSync(recursive: true);
  }
  return failures;
}

/// The `serve` smoke: the real subcommand, on a loopback ephemeral port.
Future<List<String>> _serveSmoke(String packageRoot) async {
  final failures = <String>[];
  final dir = await _sandbox();
  try {
    final workspace = Directory(p.join(dir.path, 'ws'))..createSync();
    File(p.join(workspace.path, 'notes.txt')).writeAsStringSync('7\n');
    final token = 'smoketoken-0123456789abcdef';
    final config = File(p.join(dir.path, 'config.json'))
      ..writeAsStringSync(jsonEncode({
        'provider': {
          'kind': 'ollama',
          'model': 'scripted',
          'context_window': 8192,
        },
        'workspace_root': workspace.path,
        'session_dir': p.join(dir.path, 'sessions'),
        'memory_dir': p.join(dir.path, 'memory'),
        'tasks_file': p.join(dir.path, 'tasks.json'),
        'secrets_file': p.join(dir.path, 'secrets.json'),
        'policy': {'log': p.join(dir.path, 'policy.log')},
        'log_file': p.join(dir.path, 'agent.jsonl'),
        'http': {'token': token, 'port': 0},
        'channels': [
          {'id': 'telegram', 'kind': 'telegram', 'allow_from': ['42']}
        ],
      }));
    final script = File(p.join(dir.path, 'script.json'))
      ..writeAsStringSync(jsonEncode({
        'steps': [
          {'complete': {'text': 'The number is 7.'}},
        ]
      }));
    final process = await Process.start(
      Platform.resolvedExecutable,
      ['run', 'bin/sudoer.dart', 'serve', '--config', config.path],
      workingDirectory: packageRoot,
      environment: {
        ...Platform.environment,
        'SUDOER_SCRIPT_FILE': script.path,
      },
    );
    final portCompleter = Completer<int>();
    process.stderr
        .transform(utf8.decoder)
        .listen((chunk) {
      final match =
          RegExp(r'serve on http://127\.0\.0\.1:(\d+)').firstMatch(chunk);
      if (match != null && !portCompleter.isCompleted) {
        portCompleter.complete(int.parse(match.group(1)!));
      }
    });
    int port;
    try {
      port = await portCompleter.future
          .timeout(const Duration(seconds: 60));
    } on TimeoutException {
      failures.add('serve: the server never reported its port');
      process.kill(ProcessSignal.sigterm);
      return failures;
    }
    final client = HttpClient();
    /// POST one run and read the SSE stream to its single `result` event.
    Future<Map<String, dynamic>?> sseRun(String sessionId, String goal) async {
      final req = await client.postUrl(
          Uri.parse('http://127.0.0.1:$port/sessions/$sessionId/runs'));
      req.headers.set('authorization', 'Bearer $token');
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'goal': goal}));
      final response = await req.close();
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      Map<String, dynamic>? result;
      await for (final chunk in response.transform(utf8.decoder)) {
        for (final block in chunk.split('\n\n')) {
          final event =
              RegExp(r'event: (\w+)\ndata: (.*)').firstMatch(block.trim());
          if (event == null) continue;
          if (event.group(1) == 'result') {
            result = jsonDecode(event.group(2)!) as Map<String, dynamic>;
          }
        }
      }
      return result;
    }

    Future<Map<String, dynamic>> request(String method, String path,
        Object? body,
        {bool useCookie = false, String? cookieOverride}) async {
      final req = await client.openUrl(
          method, Uri.parse('http://127.0.0.1:$port$path'));
      if (!useCookie) req.headers.set('authorization', 'Bearer $token');
      if (cookieOverride != null) req.headers.set('cookie', cookieOverride);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final response = await req.close();
      final text = await response.transform(utf8.decoder).join();
      return {
        'status': response.statusCode,
        'body': text.isEmpty ? <String, dynamic>{} : jsonDecode(text),
        'setCookie': response.headers.value('set-cookie') ?? '',
      };
    }

    try {
      // Web login exchanges the token for a session cookie.
      final login =
          await request('POST', '/login', {'token': token});
      if (login['status'] != 200) {
        failures.add('serve: login expected 200, got ${login['status']}');
      }
      final cookie =
          (login['setCookie'] as String).split(';').first;
      if (!cookie.startsWith('sudoer_session=')) {
        failures.add('serve: the login did not set a session cookie');
      }
      // The cookie authorizes the next call (no bearer header).
      final viaCookie = await request('GET', '/config', null,
          useCookie: true, cookieOverride: cookie);
      if (viaCookie['status'] != 200) {
        failures.add(
            'serve: the session cookie did not authorize /config '
            '(${viaCookie['status']})');
      }
      // The inbound channel endpoint round-trips (404 for the unknown,
      // 403 for a denied sender — the refused text never reaches a model).
      final unknown = await request('POST', '/channels/nope/messages',
          {'from': '42', 'text': 'hi'});
      if (unknown['status'] != 404) {
        failures.add(
            'serve: unknown channel expected 404, got ${unknown['status']}');
      }
      final denied = await request('POST', '/channels/telegram/messages',
          {'from': '99', 'text': 'hi'});
      if (denied['status'] != 403) {
        failures.add(
            'serve: denied sender expected 403, got ${denied['status']}');
      }
      // GET /config returns the effective non-secret config.
      final configView = await request('GET', '/config', null);
      if (configView['status'] != 200) {
        failures.add('serve: GET /config expected 200');
      }
      if (!(configView['body'] as Map).containsKey('http')) {
        failures.add('serve: GET /config is missing the http key');
      }
      // PUT /config rejects a secret value.
      final reject = await request(
          'PUT', '/config', {'secrets_file': '/tmp/leak.json'});
      if (reject['status'] == 200) {
        failures.add('serve: PUT /config accepted a secret value');
      }
      // One API run streams to its SSE result.
      final create = await request('POST', '/sessions', null);
      final sessionId = (create['body'] as Map)['id'] as String;
      final result =
          await sseRun(sessionId, 'Read notes.txt and tell me the number.');
      if (result == null) {
        failures.add('serve: the SSE stream held no result event');
      } else if (result['status'] != 'complete') {
        failures.add(
            'serve: the served run did not complete (got ${result['status']})');
      } else if ('${result['answer']}'.contains('7') == false) {
        failures.add('serve: the served run answer is missing the number (7)');
      }
    } finally {
      client.close(force: true);
      process.kill(ProcessSignal.sigterm);
      final code = await process.exitCode
          .timeout(const Duration(seconds: 30), onTimeout: () => -1);
      if (code != 0) {
        failures.add('serve: expected exit 0 on SIGTERM, got $code');
      }
    }
  } finally {
    dir.deleteSync(recursive: true);
  }
  return failures;
}

/// A disposable sandbox directory for one smoke group.
Future<Directory> _sandbox() async {
  final dir =
      await Directory.systemTemp.createTemp('sudoer-pilot-smoke-');
  Directory(p.join(dir.path, '.sudoer', 'sessions'))
      .createSync(recursive: true);
  return dir;
}

Future<Directory> _sandboxDir() => _sandbox();

File _tickConfig(Directory dir) {
  final file = File(p.join(dir.path, 'config.json'))
    ..writeAsStringSync(jsonEncode({
      'provider': {
        'kind': 'ollama',
        'model': 'scripted',
        'context_window': 8192,
      },
      'workspace_root': dir.path,
      'session_dir': p.join(dir.path, '.sudoer', 'sessions'),
      'memory_dir': p.join(dir.path, '.sudoer', 'memory'),
      'tasks_file': p.join(dir.path, '.sudoer', 'tasks.json'),
      'secrets_file': p.join(dir.path, '.sudoer', 'secrets.json'),
      'policy': {'log': p.join(dir.path, '.sudoer', 'policy.log')},
      'log_file': p.join(dir.path, '.sudoer', 'agent.jsonl'),
    }));
  return file;
}

/// Run the real binary: `dart run bin/sudoer.dart <args>`.
Future<_RunResult> _runSudoer(
  String packageRoot,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String> env = const {},
}) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', 'bin/sudoer.dart', ...arguments],

    workingDirectory: workingDirectory ?? packageRoot,
    environment: {
      ...Platform.environment,
      ...env,
    },
  );
  return _RunResult(
    result.exitCode,
    result.stdout.toString(),
    result.stderr.toString(),
  );
}

final class _RunResult {
  _RunResult(this.exit, this.stdout, this.stderr);
  final int exit;
  final String stdout;
  final String stderr;
}

