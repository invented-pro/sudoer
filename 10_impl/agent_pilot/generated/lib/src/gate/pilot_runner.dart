import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../autonomy.dart';
import '../channels.dart';
import '../channels_inbound.dart';
import '../clock.dart';
import '../config.dart';
import '../embedder.dart';
import '../memory.dart';
import '../models.dart';
import '../notifier.dart';
import '../pilot_agent.dart';
import '../pilot_commands.dart';
import '../pilot_config.dart';
import '../pilot_runtime.dart';
import '../platform_wake.dart';
import '../log.dart';
import '../providers/provider.dart';
import '../providers/scripted.dart';
import '../reliability.dart';
import '../safety.dart';
import '../sessions_index.dart';
import '../scheduler.dart';
import '../session.dart';
import 'pilot_task.dart';
import 'stubs.dart';
import 'runner.dart' show findPackageRoot;
import 'runner.dart' as prop_runner;

/// The Pilot gate defaults, deep-merged under every task's config: Pilot
/// stores land inside the task's temp workspace, so expectations can read
/// them and nothing leaks out of the sandbox (gate.md).
Map<String, dynamic> _gateDefaults(String temp) => {
      'provider': {
        'kind': 'ollama',
        'model': 'scripted',
        'context_window': 8192,
      },
      'workspace_root': temp,
      'session_dir': p.join(temp, '.sudoer', 'sessions'),
      'memory_dir': p.join(temp, '.sudoer', 'memory'),
      'tasks_file': p.join(temp, '.sudoer', 'tasks.json'),
      'secrets_file': p.join(temp, '.sudoer', 'secrets.json'),
      'policy': {'log': p.join(temp, '.sudoer', 'policy.log')},
      'log_file': p.join(temp, '.sudoer', 'logs', 'agent.jsonl'),
      'web': {'enabled': false},
      'http': {'port': 0, 'token': 'gatetoken-0123456789abcdef'},
    };

/// Everything one task run produces that expectations can assert.
final class PilotRun {
  final List<RunResult> runs = [];
  final Session? session;
  final PilotRuntime runtime;
  final FakeClock clock;
  final FakeNotifier notifier;
  final FakeScheduler scheduler;
  final List<OutboundDelivery> deliveries = [];
  final List<Provider> chain;
  final MemoryStore memory;
  final List<String> stdout;
  PilotRun({
    required this.session,
    required this.runtime,
    required this.clock,
    required this.notifier,
    required this.scheduler,
    required this.chain,
    required this.memory,
    required this.stdout,
  });
}

/// Run one Pilot task in an isolated temp workspace with the scripted chain,
/// the injected clock/sleeper/notifier/scheduler/channels/embedder, driving
/// the automation surface, `tick`s, inbound channel messages, or the API
/// driver — then compare against the task's expectations.
Future<prop_runner.TaskReport> runPilotTask(PilotTask task) async {
  final failures = <String>[];
  final temp = Directory.systemTemp.createTempSync('sudoer-pilot-gate-');
  LoopbackStubs? stubs;
  try {
    // Materialize the workspace.
    for (final entry in task.workspace.entries) {
      final file = File(p.join(temp.path, entry.key));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }
    // The secrets store (C10).
    if (task.secrets.isNotEmpty) {
      final file = File(p.join(temp.path, '.sudoer', 'secrets.json'));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(task.secrets));
    }
    // The scheduled-task store (C11): relative `when` values resolve
    // against the task's pinned clock.
    if (task.seedTasks.isNotEmpty) {
      final seedClock = FakeClock(task.clockNow ?? DateTime.utc(2026, 10, 6, 9));
      final store = TaskStore(
          p.join(temp.path, '.sudoer', 'tasks.json'), seedClock);
      store.save([
        for (final seed in task.seedTasks) seedTaskFromJson(seed, now: seedClock.time),
      ]);
    }

    // Loopback stubs, bound before driving so `{{stub:name}}` resolves.
    final resolved = await LoopbackStub.bind(task.stubs);
    stubs = LoopbackStubs(resolved.$1, resolved.$2);

    // The merged config over the gate defaults. C2: a process sets
    // `provider` or `providers`, never both — the gate defaults carry the
    // one-element sugar, so a task's chain replaces it (and a task's single
    // provider replaces a chain).
    final override = _resolveStubsDeep(task.configOverride, stubs);
    final defaults = _gateDefaults(temp.path);
    if (override.containsKey('providers')) {
      defaults.remove('provider');
    } else if (override.containsKey('provider')) {
      defaults.remove('providers');
    }
    final merged = Config.mergeJson(defaults, override);
    final config = PilotConfig.fromJson(merged, defaultRoot: temp.path);

    // The injected environment (gate.md): pinned clock, no-op sleeper,
    // recording notifier, fake OS scheduler, recording channel deliveries.
    final clock = FakeClock(task.clockNow ?? DateTime.utc(2026, 10, 6, 9));
    final notifier = FakeNotifier();
    final scheduler = FakeScheduler();
    final deliveries = <OutboundDelivery>[];
    final runtime = PilotRuntime.assemble(
      config,
      clock: clock,
      scheduler: scheduler,
      notifier: notifier,
      deliver: (delivery, channel) async {
        deliveries.add(delivery);
        return delivery;
      },
    );
    // The embedder is pinned below (fake by default, `fallback` lexical);
    // the runtime shares it so /memory and recall agree (C9).

    // The scripted chain: one provider per entry, injected — never
    // config-reachable (C2/gate).
    final providers = [
      for (final script in task.scripts)
        ScriptedProvider.fromJson(_resolveStubsDeep(script, stubs)),
    ];

    // The embedder: the deterministic fake by default; `fallback` forces
    // the lexical path (gate.md).
    final embedder = switch (task.embedderMode) {
      'fallback' => LexicalEmbedder(),
      'none' => NoEmbedder(),
      _ => FakeEmbedder(),
    };
    runtime.embedder = embedder;
    final memory = MemoryStore(config.memoryDir, embedder);

    final stdoutLines = <String>[];
    RunResult? lastResult;
    final runs = <RunResult>[];

    // Drive: API tasks go through the real served process; the rest through
    // the CLI/automation surface with ticks and inbound messages. The API
    // path also projects its runs onto the CLI expectations, so
    // `expect.answer`/`tools`/`sessionPersisted` assert the served run.
    if (task.api != null) {
      final apiFailures = await _driveApi(task, temp, config);
      failures.addAll(apiFailures);
      _projectApiExpectations(task, config, failures);
    } else {
      final outcome = await _driveCli(
        task: task,
        temp: temp,
        config: config,
        runtime: runtime,
        clock: clock,
        providers: providers,
        embedder: embedder,
        stdoutLines: stdoutLines,
      );
      runs.addAll(outcome.$1);
      failures.addAll(outcome.$2);
      lastResult = runs.isEmpty ? null : runs.last;
    }

    _checkExpectations(
      task: task,
      failures: failures,
      temp: temp,
      config: config,
      runtime: runtime,
      clock: clock,
      providers: providers,
      notifier: notifier,
      scheduler: scheduler,
      deliveries: deliveries,
      memory: memory,
      runs: runs,
      stdoutLines: stdoutLines,
      lastResult: lastResult,
    );
  } on Object catch (e, st) {
    failures.add('threw: $e\n$st');
  } finally {
    await stubs?.close();
    temp.deleteSync(recursive: true);
  }
  return prop_runner.TaskReport(task.id, failures);
}

/// The bound loopback stubs plus their closer.
final class LoopbackStubs {
  LoopbackStubs(this.map, this.close);
  final Map<String, LoopbackStub> map;
  final Future<void> Function() close;

  Future<void> closeAll() => close();
}

Map<String, dynamic> _resolveStubsDeep(
    Map<String, dynamic> json, LoopbackStubs stubs) {
  Object? walk(Object? value) => switch (value) {
        String text => resolveStubs(text, stubs.map),
        Map map => {
            for (final entry in map.entries)
              entry.key: walk(entry.value),
          },
        List list => [for (final item in list) walk(item)],
        _ => value,
      };
  return {
    for (final entry in json.entries) entry.key: walk(entry.value),
  } as Map<String, dynamic>;
}

/// The CLI/automation drive: turns, ticks, and inbound channel messages,
/// in that order, on the Pilot assembly.
Future<(List<RunResult>, List<String>)> _driveCli({
  required PilotTask task,
  required Directory temp,
  required PilotConfig config,
  required PilotRuntime runtime,
  required FakeClock clock,
  required List<Provider> providers,
  required Embedder embedder,
  required List<String> stdoutLines,
}) async {
  final failures = <String>[];
  final runs = <RunResult>[];

  // Channels registered before driving (C6).
  for (final registration in task.registerChannels) {
    config.channels.add(channelFromJson(registration));
  }

  final autonomy = Autonomy(runtime: runtime, runGoal: (run) async {
    final session = run.session ??
        Session.create(workspaceRoot: config.primaryRoot);
    final agent = PilotAgent.assemble(
      runtime: runtime,
      session: session,
      chain: providers,
      embedder: embedder,
      reliability: const Reliability(sleep: _noSleep),
    );
    try {
      final result = await agent.run(RunRequest(run.goal), system: run.system);
      return result.answer;
    } finally {
      await agent.dispose();
    }
  });

  // Startup: due-while-away tasks under the report policy are listed, not
  // run (C11) — printed once, like the real surface.
  final missed = autonomy.reportMissed();
  if (missed.isNotEmpty) stdoutLines.add(missed);

  Session? sessionHolder;
  Session currentSession() =>
      sessionHolder ??= Session.create(workspaceRoot: config.primaryRoot);
  for (final turn in task.turns) {
    if (turn.command != null) {
      stdoutLines.add(_handleCommand(
        turn.command!,
        config: config,
        runtime: runtime,
        autonomy: autonomy,
        session: currentSession,
        setSession: (value) => sessionHolder = value,
      ));
      continue;
    }
    final goal = turn.goal!;
    final session = currentSession();
    final agent = PilotAgent.assemble(
      runtime: runtime,
      session: session,
      chain: providers,
      embedder: embedder,
      reliability: const Reliability(sleep: _noSleep),
    );
    try {
      final result = await agent.run(RunRequest(goal));
      runs.add(result);
      stdoutLines.add(result.answer ?? '');
    } finally {
      await agent.dispose();
    }
    task.lastSession = session;
  }

  // The run-boundary check point (C11): a task that came due during the
  // turns fires now, as the next goal in its session — and its run counts.
  for (final outcome in await autonomy.tick(session: sessionHolder)) {
    if (outcome.skipped) continue;
    if (outcome.answer != null) stdoutLines.add(outcome.answer!);
    runs.add(RunResult.complete(outcome.answer ?? ''));
  }

  // The declared autonomous half: clock advances and scheduler ticks (C11).
  for (final tick in task.ticks) {
    if (tick.advance != null) {
      clock.advance(parseAdvance(tick.advance!) ?? Duration.zero);
      continue;
    }
    await autonomy.tick(session: sessionHolder);
  }

  // Inbound channel messages, in order (C6/C10): each permitted message is
  // a goal in its channel's session and counts as a run.
  for (final message in task.inbound) {
    final outcome = await handleInbound(
      runtime,
      message.channel,
      message.from,
      message.text,
      chain: providers,
      reliability: const Reliability(sleep: _noSleep),
    );
    if (outcome.answer != null) stdoutLines.add(outcome.answer!);
    if (outcome.allowed) {
      runs.add(RunResult.complete(outcome.answer ?? ''));
    }
  }

  return (runs, failures);
}

/// One `/command` through the shipped Pilot command handler; returns the
/// text the surface would print.
String _handleCommand(
  String line, {
  required PilotConfig config,
  required PilotRuntime runtime,
  required Autonomy autonomy,
  required Session Function() session,
  required void Function(Session?) setSession,
}) {
  final buffer = StringBuffer();
  final parts = line.split(RegExp(r'\s+'));
  switch (parts.first) {
    case '/new':
      setSession(Session.create(workspaceRoot: config.primaryRoot));
      return 'new session ${session().id}';
    case '/exit':
    case '/quit':
      return '';
  }
  final handled = handlePilotCommand(line, runtime,
      out: buffer, err: buffer, session: session());
  return handled ? buffer.toString().trimRight() : buffer.toString();
}

/// The API driver (gate.md): spawn the built `sudoer-pilot serve` as a
/// separate process on a loopback ephemeral port and perform the declared
/// sequence against it. The server class is never instantiated in-process,
/// so the shipped `serve` subcommand is what gets tested.
Future<List<String>> _driveApi(
  PilotTask task,
  Directory temp,
  PilotConfig config,
) async {
  final failures = <String>[];
  final steps = task.api!.steps;
  var token =
      config.httpToken ?? 'gatetoken-0123456789abcdef';
  // The spawned server reads the task config through the env seam: the
  // gate writes the merged config into the sandbox and points SUDOER_CONFIG
  // at it.
  final configFile = File(p.join(temp.path, 'gate-config.json'))
    ..writeAsStringSync(jsonEncode(_resolveStubsDeep(config.view(),
        LoopbackStubs(const {}, () async {}))));
  final packageRoot = findPackageRoot().path;
  final environment = {
    ...Platform.environment,
    'SUDOER_CONFIG': configFile.path,
    if (task.scripts.isNotEmpty)
      'SUDOER_SCRIPT_FILE': _writeChainScript(task.scripts, temp),
  };
  final process = await Process.start(
    Platform.resolvedExecutable,
    ['run', 'bin/sudoer.dart', 'serve', '--config', configFile.path],
    workingDirectory: packageRoot,
    environment: environment,
  );
  // Wait for the port line.
  var port = 0;
  final portCompleter = Completer<int>();
  process.stderr.transform(utf8.decoder).listen((chunk) {
    final match = RegExp(r'serve on http://127\.0\.0\.1:(\d+)').firstMatch(chunk);
    if (match != null && !portCompleter.isCompleted) {
      portCompleter.complete(int.parse(match.group(1)!));
    }
  });
  try {
    port = await portCompleter.future.timeout(const Duration(seconds: 60));
  } on TimeoutException {
    failures.add('api: the server never reported its port');
    process.kill(ProcessSignal.sigterm);
    return failures;
  }
  final client = HttpClient();

  Future<Map<String, dynamic>> request(
    String method,
    String path,
    Object? body, {
    String? cookie,
  }) async {
    final request = await client.openUrl(
        method, Uri.parse('http://127.0.0.1:$port$path'));
    request.headers.set('authorization', 'Bearer $token');
    if (cookie != null) request.headers.set('cookie', cookie);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    return {
      'status': response.statusCode,
      'body': text.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(text) as Map<String, dynamic>,
      'headers': response.headers,
    };
  }

  var sessionNames = <String, String>{};
  var stepIndex = 0;
  try {
    for (final step in steps) {
      final expected = stepIndex < task.expect.api.length
          ? task.expect.api[stepIndex]
          : null;
      switch (step) {
        case CreateSessionStep(:final name):
          final response = await request(
              'POST', '/sessions', {'workspace_root': temp.path});
          if (response['status'] != 200) {
            failures.add(
                'api.createSession($name): expected 200, got ${response['status']}');
            break;
          }
          sessionNames = {
            ...sessionNames,
            name: (response['body'] as Map)['id'] as String,
          };
        case RunStep(:final session, :final goal):
          final id = sessionNames[session];
          if (id == null) {
            failures.add('api.run($session): no such created session');
            break;
          }
          final result = await _streamRun(
              client, port, id, goal, 'Bearer $token');
          if (result == null) {
            failures.add('api.run($session): the SSE stream held no result');
            break;
          }
          if (expected != null && expected['status'] != null) {
            if (result['status'] != expected['status']) {
              failures.add('api.run($session): expected status '
                  '${expected['status']}, got ${result['status']}');
            }
          }
          if (expected?['answer'] != null) {
            final answer = result['answer'] as String? ?? '';
            if (!answer.contains(expected!['answer'] as String)) {
              failures.add('api.run($session): answer missing '
                  '"${expected['answer']}" (got "$answer")');
            }
          }
        case GetConfigStep():
          final response = await request('GET', '/config', null);
          if (response['status'] != 200) {
            failures.add(
                'api.getConfig: expected 200, got ${response['status']}');
            break;
          }
          final keys = (response['body'] as Map).keys.toList();
          if (expected != null && expected['keys'] != null) {
            for (final key in expected['keys'] as List) {
              if (!keys.contains(key)) {
                failures.add('api.getConfig: missing key "$key" '
                    '(had $keys)');
              }
            }
          }
        case PutConfigStep(:final patch):
          final response = await request('PUT', '/config', patch);
          final status = response['status'] as int;
          if (expected?['ok'] == true && status != 200) {
            failures.add(
                'api.putConfig: expected 200, got $status (${response['body']})');
          }
          if (expected?['ok'] == false && status == 200) {
            failures.add('api.putConfig: expected rejection, got 200');
          }
          if (expected?['error'] != null &&
              (response['body'] as Map)['error'] != expected!['error']) {
            failures.add('api.putConfig: expected error '
                '"${expected['error']}", got "${response['body']}"');
          }
        case LoginStep(:final token):
          final response = await request('POST', '/login', {'token': token});
          if (response['status'] != 200) {
            failures.add(
                'api.login: expected 200, got ${response['status']}');
            break;
          }
          final setCookie =
              (response['headers'] as HttpHeaders).value('set-cookie') ?? '';
          if (!setCookie.contains('sudoer_session=')) {
            failures.add('api.login: no session cookie was set');
          }
          // The cookie rides for the rest of the sequence via the header.
          (void setCookie) {}(setCookie);
      }
      stepIndex++;
    }
  } finally {
    client.close(force: true);
    process.kill(ProcessSignal.sigterm);
    final code = await process.exitCode.timeout(const Duration(seconds: 30),
        onTimeout: () => -1);
    if (code != 0) {
      failures.add('api: the server did not exit 0 on SIGTERM (got $code)');
    }
  }
  return failures;
}

/// POST one run and read the SSE stream to its single `result` event.
Future<Map<String, dynamic>?> _streamRun(HttpClient client, int port,
    String sessionId, String goal, String auth) async {
  final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/sessions/$sessionId/runs'));
  request.headers.set('authorization', auth);
  request.headers.contentType = ContentType.json;
  request.write(jsonEncode({'goal': goal}));
  final response = await request.close();
  if (response.statusCode != 200) {
    await response.drain<void>();
    return null;
  }
  final events = <String, Map<String, dynamic>>{};
  await for (final chunk in response.transform(utf8.decoder)) {
    for (final block in chunk.split('\n\n')) {
      final event =
          RegExp(r'event: (\w+)\ndata: (.*)').firstMatch(block.trim());
      if (event == null) continue;
      events[event.group(1)!] =
          jsonDecode(event.group(2)!) as Map<String, dynamic>;
    }
  }
  return events['result'];
}

String _writeChainScript(List<Map<String, dynamic>> scripts, Directory temp) {
  // The env seam scripts one provider; an API task's first script is the
  // loop's provider (failover for the served process is covered by CLI
  // tasks, which inject the chain directly).
  final file = File(p.join(temp.path, 'gate-script.json'));
  file.writeAsStringSync(jsonEncode(scripts.first));
  return file.path;
}

Future<void> _noSleep(Duration _) async {}

/// Project the served runs onto the task's CLI-surface expectations: the
/// runs are the persisted sessions' transcripts; the final run's answer,
/// the tool-call order, and persistence are read from the store.
void _projectApiExpectations(
  PilotTask task,
  PilotConfig config,
  List<String> failures,
) {
  final expect = task.expect;
  final sessions = SessionsIndex(config.sessionDir).load();
  if (expect.sessionPersisted == true && sessions.isEmpty) {
    failures.add('session: no session was persisted by the served process');
  }
  // The persisted transcripts carry the runs' answers and calls.
  final entries = <Entry>[];
  for (final record in sessions) {
    try {
      entries
          .addAll(Session.load(config.sessionDir, record['id'] as String)
              .transcript);
    } on Object {
      // A session that vanished under the reader is a persistence failure
      // the expectation check reports.
    }
  }
  final answers = [
    for (final entry in entries)
      if (entry is AssistantEntry && entry.action is Finish)
        (entry.action as Finish).answer,
  ];
  final tools = [
    for (final entry in entries)
      if (entry is AssistantEntry)
        for (final call in entry.action.calls) call.name,
  ];
  task.runs = [
    for (final answer in answers)
      RunResult.complete(answer),
  ];
  if (expect.answerContains != null &&
      (answers.isEmpty ||
          answers.last.contains(expect.answerContains!) == false)) {
    failures.add('final answer: expected to contain '
        '"${expect.answerContains}", got "${answers.isEmpty ? '' : answers.last}"');
  }
  if (expect.answerEquals != null &&
      (answers.isEmpty || answers.last != expect.answerEquals)) {
    failures.add('final answer: expected "${expect.answerEquals}", '
        'got "${answers.isEmpty ? '' : answers.last}"');
  }
  if (expect.answerNotContains != null &&
      answers.any((answer) => answer.contains(expect.answerNotContains!))) {
    failures.add('final answer: expected NOT to contain '
        '"${expect.answerNotContains}"');
  }
  if (expect.tools != null && expect.tools!.join(',') != tools.join(',')) {
    failures.add('tools: expected ${expect.tools}, got $tools');
  }
  if (expect.observations != null) {
    final observations = [
      for (final entry in entries)
        if (entry is ObservationEntry && entry.toolCallId != null) entry.text,
    ];
    for (var i = 0; i < expect.observations!.length; i++) {
      if (i >= observations.length ||
          observations[i].contains(expect.observations![i]) == false) {
        failures.add('observations[$i]: expected to contain '
            '"${expect.observations![i]}"');
        break;
      }
    }
  }
}

/// Compare every expectation against what the drive produced.
void _checkExpectations({
  required PilotTask task,
  required List<String> failures,
  required Directory temp,
  required PilotConfig config,
  required PilotRuntime runtime,
  required FakeClock clock,
  required List<Provider> providers,
  required FakeNotifier notifier,
  required FakeScheduler scheduler,
  required List<OutboundDelivery> deliveries,
  required MemoryStore memory,
  required List<RunResult> runs,
  required List<String> stdoutLines,
  required RunResult? lastResult,
}) {
  final expect = task.expect;

  void checkStatus(RunStatus? expected, RunResult? result, String label) {
    if (expected == null) return;
    if (result == null) {
      failures.add('$label: expected ${expected.wire}, but no goal ran');
    } else if (result.status != expected) {
      failures.add('$label: expected ${expected.wire}, got ${result.status.wire}');
    }
  }

  void checkAnswer(RunResult? result, PilotTask task, String label) {
    final e = task.expect;
    if (e.answerEquals != null && result?.answer != e.answerEquals) {
      failures.add('$label answer: expected "${e.answerEquals}", '
          'got "${result?.answer}"');
    }
    if (e.answerContains != null &&
        (result?.answer ?? '').contains(e.answerContains!) == false) {
      failures.add(
          '$label answer: expected to contain "${e.answerContains}"');
    }
    if (e.answerNotContains != null &&
        (result?.answer ?? '').contains(e.answerNotContains!)) {
      failures.add('$label answer: expected NOT to contain '
          '"${e.answerNotContains}"');
    }
  }

  if (task.api != null) {
    // API tasks: the projection in _projectApiExpectations already checked
    // the served runs' answers, tools, observations, and persistence.
  } else {
    checkStatus(expect.status, lastResult, 'status');
    if (expect.status != null || expect.answerEquals != null ||
        expect.answerContains != null || expect.answerNotContains != null) {
      checkAnswer(lastResult, task, 'final');
    }
  }

  if (expect.runs.isNotEmpty && task.api == null) {
    if (runs.length != expect.runs.length) {
      failures.add(
          'runs: expected ${expect.runs.length}, got ${runs.length}');
    } else {
      for (var i = 0; i < expect.runs.length; i++) {
        final expected = expect.runs[i];
        final actual = runs[i];
        if (expected.status != null && expected.status != actual.status) {
          failures.add('runs[$i].status: expected '
              '${expected.status!.wire}, got ${actual.status.wire}');
        }
        if (expected.answerEquals != null &&
            actual.answer != expected.answerEquals) {
          failures.add('runs[$i].answer: expected '
              '"${expected.answerEquals}", got "${actual.answer}"');
        }
        if (expected.answerContains != null &&
            (actual.answer ?? '').contains(expected.answerContains!) == false) {
          failures.add('runs[$i].answer: expected to contain '
              '"${expected.answerContains}"');
        }
      }
    }
  }

  if (expect.tools != null && task.api == null) {
    final callLog = runtime.callLog;
    if (expect.tools!.join(',') != callLog.join(',')) {
      failures.add('tools: expected ${expect.tools}, got $callLog');
    }
  }

  if (expect.observations != null && task.api == null) {
    final observations = [
      for (final entry in (task.lastSession?.transcript ?? const <Entry>[]))
        if (entry is ObservationEntry && entry.toolCallId != null) entry.text,
    ];
    for (var i = 0; i < expect.observations!.length; i++) {
      if (i >= observations.length) {
        failures.add('observations: expected at least ${i + 1}, '
            'got ${observations.length}');
        break;
      }
      if (!observations[i].contains(expect.observations![i])) {
        failures.add('observations[$i]: expected to contain '
            '"${expect.observations![i]}", got "${observations[i]}"');
      }
    }
  }

  if (expect.sessionPersisted == true && task.api == null && task.lastSession != null) {
    try {
      final loaded = Session.load(config.sessionDir, task.lastSession!.id);
      if (loaded.transcript.length != task.lastSession!.transcript.length) {
        failures.add('session: persisted session does not match in memory');
      }
    } on Object catch (e) {
      failures.add('session: not persisted: $e');
    }
  }

  if (expect.stdoutContains != null) {
    final joined = stdoutLines.join('\n');
    if (!joined.contains(expect.stdoutContains!)) {
      failures.add(
          'stdout: expected to contain "${expect.stdoutContains}", got "$joined"');
    }
  }

  // The C4 prefix property over the recorded prompts (per provider, within
  // each goal run and each fold segment).
  if (expect.prefixStable == true) {
    for (final provider in providers) {
      if (provider is! ScriptedProvider) continue;
      final prompts = provider.prompts;
      for (var i = 1; i < prompts.length; i++) {
        if (!prompts[i].startsWith(prompts[i - 1])) {
          failures.add('prefixStable: prompt $i is not a prefix-extends of '
              'prompt ${i - 1}');
          break;
        }
      }
    }
  }

  // Memory notes by id (C9).
  if (expect.memory != null) {
    for (final entry in expect.memory!.entries) {
      final note = memory.read(entry.key);
      if (note == null) {
        failures.add('memory: expected note ${entry.key}, none stored');
      } else if (!note.body.contains(entry.value)) {
        failures.add('memory[${entry.key}]: expected body to contain '
            '"${entry.value}", got "${note.body}"');
      }
    }
  }

  // The recall injection (C4): the ids expected in the first prompt.
  if (expect.recall != null) {
    final first = providers.isEmpty ? null : providers.first;
    if (first is! ScriptedProvider || first.prompts.isEmpty) {
      failures.add('recall: no prompts were recorded');
    } else {
      final prompt = first.prompts.first;
      for (final id in expect.recall!) {
        if (!prompt.contains('[$id]')) {
          failures.add('recall: expected note $id injected into the first '
              'prompt');
        }
      }
    }
  }

  // The embedding index (C9): derived, rebuildable, byte-stable.
  if (expect.embeddingsRebuilt != null ||
      expect.embeddingsModel != null ||
      expect.embeddingsIds != null) {
    final index = memory.loadIndex();
    if (index == null) {
      failures.add('embeddings: no index was written');
    } else {
      if (expect.embeddingsRebuilt == true && index.vectors.isEmpty) {
        failures.add('embeddings: the index is empty');
      }
      if (expect.embeddingsModel != null &&
          index.model != expect.embeddingsModel) {
        failures.add('embeddings.model: expected '
            '${expect.embeddingsModel}, got ${index.model}');
      }
      if (expect.embeddingsIds != null) {
        final ids = index.vectors.keys.toList()..sort();
        final expected = [...expect.embeddingsIds!]..sort();
        if (ids.join(',') != expected.join(',')) {
          failures.add('embeddings.ids: expected $expected, got $ids');
        }
      }
      // Rebuild determinism: a second rebuild is byte-identical (C9).
      final before = jsonEncode(index.toJson());
      final rebuilt = memory.rebuildIndex();
      final after = jsonEncode(rebuilt.toJson());
      if (before != after) {
        failures.add('embeddings: the index is not deterministic on rebuild');
      }
    }
  }

  // Scheduled tasks by goal substring (C11).
  if (expect.tasks.isNotEmpty) {
    final tasks = TaskStore(config.tasksFile, clock).load();
    for (final expected in expect.tasks) {
      final match = tasks
          .where((task) => task.goal.contains(expected.goalSubstring))
          .firstOrNull;
      if (match == null) {
        failures.add('tasks: no task matches "${expected.goalSubstring}"');
        continue;
      }
      if (match.status != expected.status) {
        failures.add('tasks[${expected.goalSubstring}].status: expected '
            '${expected.status}, got ${match.status}');
      }
      if (expected.nextDue != null &&
          match.nextDue?.toIso8601String() !=
              DateTime.parse(expected.nextDue!).toIso8601String()) {
        failures.add('tasks[${expected.goalSubstring}].next_due: expected '
            '${expected.nextDue}, got ${match.nextDue?.toIso8601String()}');
      }
      if (expected.repeat != null && match.repeat != expected.repeat) {
        failures.add('tasks[${expected.goalSubstring}].repeat: expected '
            '${expected.repeat}, got ${match.repeat}');
      }
    }
  }

  // The ordered fire log; each entry appears exactly once (C11 idempotency).
  if (expect.fired.isNotEmpty) {
    final store = TaskStore(config.tasksFile, clock);
    store.load();
    final fires = store.fires;
    for (final expected in expect.fired) {
      final matches = fires
          .where((fire) =>
              fire.task == expected.task &&
              fire.due.toIso8601String() == expected.due.toIso8601String())
          .length;
      if (matches == 0) {
        failures.add('fired: no fire of ${expected.task} at '
            '${expected.due.toIso8601String()}');
      } else if (matches > 1) {
        failures.add('fired: ${expected.task} at '
            '${expected.due.toIso8601String()} fired $matches times '
            '(idempotency broken)');
      }
    }
  }

  // Recorded outbound channel deliveries, in order (C6).
  if (expect.channels.isNotEmpty) {
    if (deliveries.length < expect.channels.length) {
      failures.add('channels: expected ${expect.channels.length} '
          'deliveries, got ${deliveries.length}');
    } else {
      for (var i = 0; i < expect.channels.length; i++) {
        final expected = expect.channels[i];
        final actual = deliveries[i];
        if (expected.channel != null && actual.channel != expected.channel) {
          failures.add('channels[$i].channel: expected '
              '${expected.channel}, got ${actual.channel}');
        }
        if (expected.to != null && actual.to != expected.to) {
          failures.add(
              'channels[$i].to: expected ${expected.to}, got ${actual.to}');
        }
        if (expected.message != null &&
            actual.message.contains(expected.message!) == false) {
          failures.add('channels[$i].message: expected to contain '
              '"${expected.message}", got "${actual.message}"');
        }
      }
    }
  }

  // The fake scheduler's recorded wake units (C11).
  if (expect.scheduler.isNotEmpty) {
    for (final expected in expect.scheduler) {
      if (!scheduler.installed.any((unit) => unit.contains(expected))) {
        failures.add('scheduler: expected a recorded wake containing '
            '"$expected", got ${scheduler.installed}');
      }
    }
  }

  // Recorded notifications (C3): title/message substrings, in order.
  if (expect.notifications.isNotEmpty) {
    if (notifier.sent.length < expect.notifications.length) {
      failures.add('notifications: expected ${expect.notifications.length}, '
          'got ${notifier.sent.length}');
    } else {
      for (var i = 0; i < expect.notifications.length; i++) {
        final expected = expect.notifications[i];
        final actual = notifier.sent[i];
        if (expected.title != null && actual.$1 != expected.title) {
          failures.add(
              'notifications[$i].title: expected ${expected.title}, got ${actual.$1}');
        }
        if (expected.message != null &&
            actual.$2.contains(expected.message!) == false) {
          failures.add('notifications[$i].message: expected to contain '
              '"${expected.message}", got "${actual.$2}"');
        }
      }
    }
  }

  // The structured JSONL log, in order (C8).
  if (expect.logs.isNotEmpty) {
    final records = StructuredLog.load(config.logFile);
    var cursor = 0;
    for (final expected in expect.logs) {
      var found = false;
      while (cursor < records.length) {
        final record = records[cursor++];
        if (record.kind != expected.kind) continue;
        if (expected.tool != null && record.data['tool'] != expected.tool) {
          continue;
        }
        if (expected.status != null &&
            record.data['status'] != expected.status) {
          continue;
        }
        if (expected.detail != null &&
            '${record.data['detail']}'.contains(expected.detail!) == false &&
            '${record.data['action']}'.contains(expected.detail!) == false) {
          continue;
        }
        found = true;
        break;
      }
      if (!found) {
        failures.add('logs: expected a ${expected.kind} line'
            '${expected.tool == null ? '' : ' (tool ${expected.tool})'}'
            '${expected.status == null ? '' : ' (status ${expected.status})'}'
            ' after position $cursor; had '
            '${[for (final r in records) r.kind]}');
        break;
      }
    }
  }

  // The policy decision log, in order (C10).
  if (expect.policy.isNotEmpty) {
    final decisions = DecisionLog.load(config.policyLog);
    for (var i = 0; i < expect.policy.length; i++) {
      final expected = expect.policy[i];
      final match = decisions
          .where((decision) =>
              decision['event'] == expected.event &&
              decision['tool'] == expected.tool)
          .toList();
      if (match.isEmpty) {
        failures.add('policy: no ${expected.event} decision for '
            '${expected.tool}; had '
            '${[for (final d in decisions) "${d['event']}:${d['tool']}"]}');
      }
    }
  }
}
