import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_tui/dart_tui.dart'
    show
        Field,
        Form,
        Group,
        KeyCode,
        KeyPressMsg,
        PasteEndMsg,
        PasteMsg,
        PasteStartMsg,
        RgbColor,
        TextInputModel,
        stripAnsi;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sudoer_prop/sudoer_prop.dart';
import 'package:test/test.dart';

Config _config({
  String kind = 'ollama',
  int window = 8192,
  Map<String, dynamic> extra = const {},
  String? workspaceRoot,
  String? sessionDir,
}) {
  final root = workspaceRoot ?? Directory.systemTemp.path;
  return Config.fromJson({
    'provider': {
      'kind': kind,
      'model': 'scripted',
      'context_window': window,
      ...extra,
    },
    'workspace_root': root,
    'session_dir': ?sessionDir,
  });
}

/// A command that blocks long enough for a cancel or timeout test to
/// interrupt it, using each platform's host shell syntax (C3).
String _blockingCommand() =>
    Platform.isWindows ? 'ping -n 30 127.0.0.1 > NUL' : 'sleep 30';

/// Delete a temp directory, tolerating Windows holding a just-killed
/// process's working directory inside it for a moment (errno 32).
Future<void> _deleteTemp(Directory dir) async {
  for (var attempt = 0;; attempt++) {
    try {
      dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      if (attempt >= 10) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}

/// The rightmost cursor-forward column (`ESC[nC`) written so far — the column
/// the editor last placed the cursor at, counting the two-column prompt.
int? _lastCursorColumn(StringBuffer out) {
  final matches = RegExp(r'\x1b\[(\d+)C').allMatches(out.toString());
  return matches.isEmpty ? null : int.parse(matches.last.group(1)!);
}

/// A [RunObserver] that records the timing signals the loop emits (C1/C6).
class _RecordingObserver implements RunObserver {
  final List<Duration> responses = [];
  final List<Duration?> observations = [];
  final List<String> phases = [];
  final List<String> compactions = [];

  @override
  void onDelta(String text) {}
  @override
  void onReasoning(String text) {}
  @override
  void onStep(int step, int stalls, int stallBudget) {}
  @override
  void onContext(int usedTokens, int windowTokens) {}
  @override
  void onCompaction(int steps, int beforeTokens, int afterTokens) =>
      compactions.add('$steps:$beforeTokens:$afterTokens');
  @override
  void onTool(String name, Map<String, dynamic> arguments) {}
  @override
  void onResponse(Duration elapsed) => responses.add(elapsed);
  @override
  void onObservation(Outcome outcome, String text, {Duration? elapsed}) =>
      observations.add(elapsed);
  @override
  void onPhase(String phase) => phases.add(phase);
}

void main() {
  group('config (C6)', () {
    test('parses a valid ollama config', () {
      final config = _config();
      expect(config.provider.kind, ProviderKind.ollama);
      expect(config.provider.contextWindow, 8192);
    });

    test('requires base_url for openai-compatible', () {
      expect(() => _config(kind: 'openai-compatible'),
          throwsA(isA<ConfigException>()));
    });

    test('rejects a non-positive context window', () {
      expect(() => _config(window: 0), throwsA(isA<ConfigException>()));
    });

    test('a missing config reports the path and a sample', () {
      final dir = Directory.systemTemp.createTempSync('sudoer_cfg');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, 'sudoer.json');
      expect(
        () => loadConfigFile(path),
        throwsA(isA<ConfigNotFoundException>()
            .having((e) => e.path, 'path', path)),
      );
      final report = missingConfigReport(path);
      expect(report, contains(path));
      expect(report, contains('"provider"'));
      expect(report, contains('"base_url"'));
    });

    test('the sample config matches the README shape', () {
      final decoded = jsonDecode(kSampleConfig) as Map<String, dynamic>;
      expect(decoded['provider'], isA<Map>());
      expect(decoded['web'], isA<Map>());
    });

    test('relative paths in a config file resolve against its directory',
        () {
      final dir = Directory.systemTemp.createTempSync('sudoer_cfg');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, 'sudoer.json');
      File(path).writeAsStringSync(jsonEncode({
        'provider': {
          'kind': 'ollama',
          'model': 'llama3.1',
          'context_window': 8192,
        },
        'workspace_root': 'ws',
        'session_dir': 'ws/sessions',
      }));
      final config = loadConfigFile(path);
      expect(config.workspaceRoot, p.join(dir.path, 'ws'));
      expect(config.sessionDir, p.join(dir.path, 'ws', 'sessions'));
    });

    test('defaults session_dir under the workspace', () {
      final config = _config(workspaceRoot: '/tmp/ws');
      expect(config.sessionDir,
          p.join(config.workspaceRoot, '.sudoer', 'sessions'));
    });

    test('defaults workspace_root to the working directory', () {
      final config = Config.fromJson({
        'provider': {'kind': 'ollama', 'model': 'm', 'context_window': 100},
      });
      expect(config.workspaceRoot,
          p.normalize(p.absolute(Directory.current.path)));
    });

    test('copyWith changes the workspace but keeps session_dir', () {
      final config = _config(workspaceRoot: '/tmp/ws', sessionDir: '/tmp/sess');
      final moved = config.copyWith(workspaceRoot: '/tmp/other');
      expect(moved.workspaceRoot, '/tmp/other');
      expect(moved.sessionDir, '/tmp/sess');
    });
  });

  group('completion normalization (C2)', () {
    test('text with no tool call becomes a finish', () {
      final response = parseCompletion(const Completion(text: 'hi'));
      expect(response.action, isA<Finish>());
      expect((response.action as Finish).answer, 'hi');
    });

    test('a tool call is taken as the action', () {
      final response = parseCompletion(const Completion(
        text: 'reading',
        toolCalls: [ToolCall(name: 'read', arguments: {'path': 'a.txt'})],
      ));
      expect(response.action, isA<ToolBatch>());
      expect((response.action as ToolBatch).calls.single.name, 'read');
    });

    test('a plan update rides alongside the action', () {
      final response = parseCompletion(const Completion(
        text: 'planning',
        toolCalls: [ToolCall(name: 'read', arguments: {'path': 'a.txt'})],
        plan: [PlanItem(text: 'read it')],
      ));
      expect(response.plan, isNotNull);
      expect(response.plan!.single.text, 'read it');
    });
  });

  group('tools (C3)', () {
    test('a path outside the workspace root resolves and reads (anchor)', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final workspace = Directory('${temp.path}/ws')..createSync();
      File('${temp.path}/secret.txt').writeAsStringSync('top secret');
      final registry = ToolRegistry(workspaceRoot: workspace.path);
      final outcome = await registry.dispatch(
        const ToolCall(name: 'read', arguments: {'path': '../secret.txt'}),
      );
      // The root is an anchor, not a fence: the read is an ordinary path.
      expect(outcome.outcome, Outcome.ok);
      expect(outcome.text, contains('top secret'));
    });

    test('a missing file is a recoverable error', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final registry = ToolRegistry(workspaceRoot: temp.path);
      final outcome = await registry.dispatch(
        const ToolCall(name: 'read', arguments: {'path': 'nope.txt'}),
      );
      expect(outcome.outcome, Outcome.error);
    });

    test('run_command uses the build timeout class', () {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final registry = ToolRegistry(workspaceRoot: temp.path);
      expect(registry.timeoutFor('run_command'), kBuildTimeout);
      expect(registry.timeoutFor('read'), kModelTimeout);
    });
  });

  group('web tools (C3)', () {
    WorkspaceGuard guard() => WorkspaceGuard(Directory.systemTemp.path);

    test('are denied when web is disabled', () async {
      final tool = WebFetchTool(guard(), NetworkGuard(enabled: false));
      final outcome = await tool.execute({'url': 'https://example.com'});
      expect(outcome.outcome, Outcome.guardDenied);
      expect(outcome.guard, GuardArea.network);
    });

    test('deny a host on the blacklist', () async {
      final tool = WebFetchTool(
          guard(), NetworkGuard(denyHosts: ['blocked.com']));
      final outcome = await tool.execute({'url': 'https://blocked.com'});
      expect(outcome.outcome, Outcome.guardDenied);
    });

    test('allow any host by default (empty blacklist)', () async {
      final tool = WebFetchTool(
        guard(),
        NetworkGuard(),
        client: MockClient((_) async =>
            http.Response('ok', 200, headers: {'content-type': 'text/plain'})),
      );
      final outcome = await tool.execute({'url': 'https://anywhere.example'});
      expect(outcome.outcome, Outcome.ok);
      expect(outcome.text, contains('ok'));
    });

    test('fetch HTML, stripping tags and scripts', () async {
      final tool = WebFetchTool(
        guard(),
        NetworkGuard(enabled: true),
        client: MockClient((_) async => http.Response(
              '<html><body><h1>Hi</h1><script>evil()</script>'
              '<p>A &amp; B</p></body></html>',
              200,
              headers: {'content-type': 'text/html'},
            )),
      );
      final outcome = await tool.execute({'url': 'https://example.com/'});
      expect(outcome.outcome, Outcome.ok);
      expect(outcome.text, contains('Hi'));
      expect(outcome.text, contains('A & B'));
      expect(outcome.text, isNot(contains('evil()')));
      expect(outcome.text, isNot(contains('<h1>')));
      expect(outcome.text, contains('untrusted'));
    });

    test('truncate a large body to the cap', () async {
      final body = 'a' * (kWebMaxBytes + 5000);
      final tool = WebFetchTool(
        guard(),
        NetworkGuard(enabled: true),
        client: MockClient((_) async => http.Response(body, 200,
            headers: {'content-type': 'text/plain'})),
      );
      final outcome = await tool.execute({'url': 'https://example.com/big'});
      expect(outcome.outcome, Outcome.ok);
      expect(outcome.text.length, lessThanOrEqualTo(kWebMaxBytes + 64));
    });

    test('reject a non-text content type', () async {
      final tool = WebFetchTool(
        guard(),
        NetworkGuard(enabled: true),
        client: MockClient((_) async => http.Response('PNG', 200,
            headers: {'content-type': 'image/png'})),
      );
      final outcome = await tool.execute({'url': 'https://example.com/i.png'});
      expect(outcome.outcome, Outcome.error);
      expect(outcome.text, contains('content type'));
    });

    test('follow a redirect to the final page', () async {
      var calls = 0;
      final tool = WebFetchTool(
        guard(),
        NetworkGuard(enabled: true),
        client: MockClient((_) async {
          calls++;
          if (calls == 1) {
            return http.Response('', 302, headers: {'location': '/final'});
          }
          return http.Response('done', 200,
              headers: {'content-type': 'text/plain'});
        }),
      );
      final outcome = await tool.execute({'url': 'https://example.com/start'});
      expect(outcome.outcome, Outcome.ok, reason: outcome.text);
      expect(outcome.text, contains('done'));
      expect(calls, 2);
    });

    test('search formats results from the backend', () async {
      final web =
          WebConfig(enabled: true, searchUrl: 'http://localhost:8080');
      final tool = WebSearchTool(
        guard(),
        NetworkGuard(enabled: true),
        web,
        client: MockClient((request) async {
          expect(request.url.path, '/search');
          expect(request.url.queryParameters['q'], 'dart');
          expect(request.url.queryParameters['format'], 'json');
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'title': 'Dart',
                  'url': 'https://dart.dev',
                  'content': 'lang',
                }
              ]
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final outcome = await tool.execute({'query': 'dart'});
      expect(outcome.outcome, Outcome.ok);
      expect(outcome.text, contains('Dart'));
      expect(outcome.text, contains('https://dart.dev'));
      expect(outcome.text, contains('untrusted'));
    });

    test('search reports when no backend is configured', () async {
      final tool = WebSearchTool(
        guard(),
        NetworkGuard(enabled: true),
        const WebConfig(enabled: true),
      );
      final outcome = await tool.execute({'query': 'x'});
      expect(outcome.outcome, Outcome.error);
      expect(outcome.text, contains('not configured'));
    });

    test('web is enabled by default and can be turned off', () {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));

      final defaults =
          _config(workspaceRoot: temp.path, sessionDir: temp.path);
      expect(defaults.web.enabled, isTrue);
      final onAgent = PropAgent.assemble(
          config: defaults, provider: ScriptedProvider.fromJson({'steps': []}));
      expect(onAgent.tools.definitions.map((d) => d.name),
          containsAll(['web_search', 'web_fetch']));

      final off = Config.fromJson({
        'provider': {
          'kind': 'ollama',
          'model': 'scripted',
          'context_window': 8192,
        },
        'workspace_root': temp.path,
        'session_dir': temp.path,
        'web': {'enabled': false, 'deny_hosts': ['example.com']},
      });
      expect(off.web.enabled, isFalse);
      expect(off.web.denyHosts, ['example.com']);
      final offAgent = PropAgent.assemble(
          config: off, provider: ScriptedProvider.fromJson({'steps': []}));
      expect(offAgent.tools.definitions.map((d) => d.name),
          isNot(contains('web_fetch')));
    });
  });

  group('session (C5)', () {
    test('saves and reloads transcript and plan', () {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final session = Session.create(workspaceRoot: temp.path)
        ..plan.add(const PlanItem(text: 'step one'))
        ..transcript.add(const UserEntry('do it'))
        ..transcript.add(const ObservationEntry(
            text: 'ok', outcome: Outcome.ok));

      final path = session.save(temp.path);
      final loaded = Session.load(temp.path, session.id);
      expect(File(path).existsSync(), isTrue);
      expect(loaded.id, session.id);
      expect(loaded.transcript.length, 2);
      expect(loaded.plan.single.text, 'step one');
    });

    test('a new id is a readable UTC timestamp plus a suffix', () {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final a = Session.create(workspaceRoot: temp.path);
      final b = Session.create(workspaceRoot: temp.path);
      expect(a.id, matches(RegExp(r'^\d{8}-\d{6}-[0-9a-z]{2}$')));
      // Two sessions opened back to back never collide.
      expect(a.id, isNot(b.id));
    });
  });

  group('loop (C1)', () {
    test('runs a scripted read then finish end to end', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      File('${temp.path}/README.md').writeAsStringSync('hello\n');

      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
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
          {'complete': {'text': 'hello'}},
        ]
      });

      final agent =
          PropAgent.assemble(config: config, provider: provider);
      final result = await agent.run(const RunRequest('read it'));

      expect(result.status, RunStatus.complete);
      expect(result.answer, 'hello');
      expect(agent.session.transcript, isNotEmpty);
    });

    test('an unrecoverable provider error blocks the run', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {'error': 'unrecoverable'}
        ]
      });
      final result =
          await PropAgent.assemble(config: config, provider: provider)
              .run(const RunRequest('do it'));
      expect(result.status, RunStatus.blocked);
    });

    test('the workspace root is an anchor, not a fence (C3)', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final workspace = Directory('${temp.path}/ws')..createSync();
      File('${temp.path}/secret.txt').writeAsStringSync('top secret');
      final config =
          _config(workspaceRoot: workspace.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {
            'complete': {
              'text': 'reading',
              'tool_calls': [
                {
                  'type': 'tool_call',
                  'name': 'read',
                  'arguments': {'path': '../secret.txt'},
                }
              ],
            }
          },
          {'complete': {'text': 'got it'}},
        ]
      });
      final agent = PropAgent.assemble(config: config, provider: provider);
      final result = await agent.run(const RunRequest('read it'));

      // A path outside the workspace root is an ordinary path: the read
      // succeeds and the run completes; only the network guard denies.
      expect(result.status, RunStatus.complete);
      final observation =
          agent.session.transcript.whereType<ObservationEntry>().first;
      expect(observation.outcome, Outcome.ok);
      expect(observation.text, contains('top secret'));
    });

    test('applies a plan update from the completion', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      File('${temp.path}/a.txt').writeAsStringSync('x');
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {
            'complete': {
              'text': 'planning',
              'plan': [
                {'text': 'read a.txt', 'done': false},
                {'text': 'answer', 'done': false},
              ],
              'tool_calls': [
                {
                  'type': 'tool_call',
                  'name': 'read',
                  'arguments': {'path': 'a.txt'},
                }
              ],
            }
          },
          {
            'complete': {
              'text': 'done',
              'plan': [
                {'text': 'read a.txt', 'done': true},
                {'text': 'answer', 'done': true},
              ],
            }
          },
        ]
      });
      final agent = PropAgent.assemble(config: config, provider: provider);
      await agent.run(const RunRequest('read and answer'));
      expect([for (final item in agent.session.plan) item.text],
          ['read a.txt', 'answer']);
      expect(agent.session.plan.every((item) => item.done), isTrue);
    });

    test('sustained productive steps run past the old step cap', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final reads = <Map<String, dynamic>>[];
      for (var i = 0; i < 20; i++) {
        File('${temp.path}/f$i.txt').writeAsStringSync('file $i');
        reads.add({
          'complete': {
            'text': 'reading f$i',
            'tool_calls': [
              {
                'type': 'tool_call',
                'name': 'read',
                'arguments': {'path': 'f$i.txt'},
              }
            ],
          }
        });
      }
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
        'steps': [...reads, {'complete': {'text': 'done'}}]
      });
      final result =
          await PropAgent.assemble(config: config, provider: provider)
              .run(const RunRequest('read every file'));
      expect(result.status, RunStatus.complete);
      expect(result.answer, 'done');
    });

    test('repeated identical steps stall and end incomplete', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      File('${temp.path}/a.txt').writeAsStringSync('static');
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final read = {
        'complete': {
          'text': 'reading',
          'tool_calls': [
            {
              'type': 'tool_call',
              'name': 'read',
              'arguments': {'path': 'a.txt'},
            }
          ],
        }
      };
      final provider = ScriptedProvider.fromJson({
        'steps': [
          read,
          read,
          read,
          read,
          {'complete': {'text': 'a.txt contains static'}},
        ]
      });
      final agent = PropAgent.assemble(config: config, provider: provider);
      final result = await agent.run(const RunRequest('read it repeatedly'));

      expect(result.status, RunStatus.incomplete);
      expect(result.answer, 'a.txt contains static');
      expect(result.reason, contains('stalled'));
      expect(
          agent.session.transcript.whereType<ObservationEntry>().length, 4);
    });

    test('a re-fetch recovering a cleared observation is progress, not a stall',
        () async {
      if (Platform.isWindows) {
        // The bulky command that pushes the read out of the tail is POSIX
        // shell syntax; the clearing logic itself is platform-neutral.
        return;
      }
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      // A big file read, then bulky non-refetchable output pushing it out of
      // the verbatim tail: C4 clears the read to a placeholder, and the
      // model's re-fetch must count as recovery progress (C8), not a repeat.
      File('${temp.path}/a.txt')
          .writeAsStringSync(List.filled(1300, 'filler line').join('\n'));
      final config = _config(
          workspaceRoot: temp.path, sessionDir: temp.path, window: 8000);
      final read = {
        'complete': {
          'text': 'reading',
          'tool_calls': [
            {
              'type': 'tool_call',
              'name': 'read',
              'arguments': {'path': 'a.txt'},
            }
          ],
        }
      };
      final provider = ScriptedProvider.fromJson({
        'steps': [
          read,
          {
            'complete': {
              'text': 'building',
                  'tool_calls': [
                {
                  'type': 'tool_call',
                  'name': 'run_command',
                  'arguments': {
                    'command':
                        "i=0; while [ \$i -lt 150 ]; do echo \"report line \$i\"; i=\$((i+1)); done"
                  },
                }
              ],
            }
          },
          read,
          {'complete': {'text': 'a.txt recovered'}},
        ]
      });
      final agent = PropAgent.assemble(config: config, provider: provider);
      final result = await agent.run(const RunRequest('read it again'));

      expect(result.status, RunStatus.complete);
      expect(result.answer, 'a.txt recovered');
    });

    test('a stalled run with no best-effort answer summarizes locally',
        () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      File('${temp.path}/a.txt').writeAsStringSync('static');
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final read = {
        'complete': {
          'text': 'reading',
          'tool_calls': [
            {
              'type': 'tool_call',
              'name': 'read',
              'arguments': {'path': 'a.txt'},
            }
          ],
        }
      };
      final provider = ScriptedProvider.fromJson({
        'steps': [
          read,
          read,
          read,
          read,
          {'error': 'timeout'},
        ]
      });
      final result =
          await PropAgent.assemble(config: config, provider: provider)
              .run(const RunRequest('read it repeatedly'));

      expect(result.status, RunStatus.incomplete);
      expect(result.answer, contains('Last observation'));
      expect(result.answer, contains('static'));
    });

    test('a provider timeout retries in place before it counts as a stall',
        () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {'error': 'timeout'},
          {'error': 'timeout'},
          {'complete': {'text': 'recovered'}}
        ]
      });
      final agent = PropAgent.assemble(
        config: config,
        provider: provider,
        // The backoff is real in production; tests never wait (C8).
        reliability: Reliability(sleep: (Duration _) async {}),
      );
      final result = await agent.run(const RunRequest('do it'));

      expect(result.status, RunStatus.complete);
      expect(result.answer, 'recovered');
      expect(provider.calls, 3);
      // A recovered timeout is invisible: no error observation is recorded.
      expect(
          agent.session.transcript
              .whereType<ObservationEntry>()
              .any((o) => o.text.contains('provider error')),
          isFalse);
    });

    test('an empty finish is nudged instead of completing silently', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {'complete': {'text': ''}},
          {'complete': {'text': 'the answer'}},
        ]
      });
      final agent = PropAgent.assemble(config: config, provider: provider);
      final result = await agent.run(const RunRequest('answer me'));

      expect(result.status, RunStatus.complete);
      expect(result.answer, 'the answer');
      // The model was told its response had no answer.
      expect(
          agent.session.transcript.whereType<ObservationEntry>().any(
              (o) => o.text.contains('no answer')),
          isTrue);
    });

    test('repeated empty finishes stall to best-effort, never empty', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {'complete': {'text': ''}},
          {'complete': {'text': ''}},
          {'complete': {'text': ''}},
          {'complete': {'text': 'a best-effort answer'}},
        ]
      });
      final result =
          await PropAgent.assemble(config: config, provider: provider)
              .run(const RunRequest('answer me'));

      expect(result.status, RunStatus.incomplete);
      expect(result.answer, 'a best-effort answer');
    });

    test('an invisible-only finish is nudged, not completed', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {'complete': {'text': '\u200b'}},
          {'complete': {'text': 'a real answer'}},
        ]
      });
      final result =
          await PropAgent.assemble(config: config, provider: provider)
              .run(const RunRequest('answer me'));
      expect(result.status, RunStatus.complete);
      expect(result.answer, 'a real answer');
    });

    test('a completed answer is persisted as an assistant turn', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {'complete': {'text': 'first answer'}},
        ]
      });
      final agent = PropAgent.assemble(config: config, provider: provider);
      await agent.run(const RunRequest('one'));

      final finishes = agent.session.transcript
          .whereType<AssistantEntry>()
          .where((entry) => entry.action is Finish)
          .toList();
      expect(finishes, hasLength(1));
      expect(finishes.single.thought, 'first answer');
    });

    test('a completed plan is cleared for the next goal', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {
            'complete': {
              'text': 'done one',
              'plan': [
                {'text': 'step one', 'done': true},
              ],
            }
          },
          {'complete': {'text': 'done two'}},
        ]
      });
      final agent = PropAgent.assemble(config: config, provider: provider);
      await agent.run(const RunRequest('one'));
      expect(agent.session.plan, isNotEmpty);
      await agent.run(const RunRequest('two'));
      expect(agent.session.plan, isEmpty);
    });

    test('an unfinished plan is kept across goals', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {
            'complete': {
              'text': 'done one',
              'plan': [
                {'text': 'step one', 'done': true},
                {'text': 'step two', 'done': false},
              ],
            }
          },
          {'complete': {'text': 'done two'}},
        ]
      });
      final agent = PropAgent.assemble(config: config, provider: provider);
      await agent.run(const RunRequest('one'));
      await agent.run(const RunRequest('two'));
      expect([for (final item in agent.session.plan) item.text],
          ['step one', 'step two']);
    });

    test('records a timing for each response, tool call, and the run total',
        () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      File('${temp.path}/README.md').writeAsStringSync('hello\n');
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
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
          {'complete': {'text': 'hello'}},
        ]
      });
      final observer = _RecordingObserver();
      final agent = PropAgent.assemble(config: config, provider: provider);
      final result =
          await agent.run(const RunRequest('read it'), observer: observer);

      final labels = [for (final timing in result.timings) timing.label];
      expect(labels.where((label) => label == 'response').length, 2);
      expect(labels, contains('read'));
      expect(labels.last, 'run');
      expect(result.timings.every((t) => !t.duration.isNegative), isTrue);
      expect(observer.responses.length, 2);
      expect(observer.observations.single, isNotNull);
    });

    test('automation records timings without a human observer', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      File('${temp.path}/README.md').writeAsStringSync('hello\n');
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
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
          {'complete': {'text': 'hello'}},
        ]
      });
      final result = await PropAgent.assemble(config: config, provider: provider)
          .run(const RunRequest('read it'));
      final labels = [for (final timing in result.timings) timing.label];
      expect(labels, containsAll(['response', 'read', 'run']));
    });

    test('a warranted fold calls the model for a brief, tools withheld',
        () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = _config(
          window: 2000, workspaceRoot: temp.path, sessionDir: temp.path);
      final session = Session.create(workspaceRoot: temp.path);
      session.transcript.add(const UserEntry('earlier goal'));
      for (var i = 0; i < 12; i++) {
        session.transcript
            .add(ObservationEntry(text: 'x' * 400, outcome: Outcome.ok));
      }
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {'complete': {'text': 'BRIEF: worked on lib/a.dart'}},
          {'complete': {'text': 'final answer'}},
        ]
      });
      final observer = _RecordingObserver();
      final agent = PropAgent.assemble(
          config: config, provider: provider, session: session);
      final result =
          await agent.run(const RunRequest('new goal'), observer: observer);

      expect(result.status, RunStatus.complete);
      expect(result.answer, 'final answer');
      expect(provider.calls, 2); // one brief call, one real step
      expect(observer.compactions, isNotEmpty);
    });

    test('a failed brief call falls back to the local digest', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = _config(
          window: 2000, workspaceRoot: temp.path, sessionDir: temp.path);
      final session = Session.create(workspaceRoot: temp.path);
      session.transcript.add(const UserEntry('earlier goal'));
      for (var i = 0; i < 12; i++) {
        session.transcript
            .add(ObservationEntry(text: 'x' * 400, outcome: Outcome.ok));
      }
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {'error': 'unrecoverable'},
          {'complete': {'text': 'final answer'}},
        ]
      });
      final observer = _RecordingObserver();
      final agent = PropAgent.assemble(
          config: config, provider: provider, session: session);
      final result =
          await agent.run(const RunRequest('new goal'), observer: observer);

      expect(result.status, RunStatus.complete);
      expect(result.answer, 'final answer');
      expect(observer.compactions, isNotEmpty);
    });
  });

  group('context (C4)', () {
    test('keeps earlier turns while the prompt fits the window', () {
      final assembler =
          ContextAssembler(contextWindow: 100000, systemPrompt: 'sys');
      final transcript = <Entry>[
        const UserEntry('old goal'),
        const AssistantEntry(thought: 'thinking', action: Finish('old answer')),
        const ObservationEntry(text: 'old result', outcome: Outcome.ok),
        const UserEntry('current goal'),
      ];
      final request = assembler.assemble(
        model: 'scripted',
        tools: const [],
        transcript: transcript,
      );
      expect(
        request.messages.whereType<UserEntry>().map((e) => e.text),
        containsAll(['old goal', 'current goal']),
      );
      expect(
        request.messages
            .whereType<ObservationEntry>()
            .any((o) => o.text.startsWith('Earlier session summary')),
        isFalse,
      );
    });

    test('clips an oversized observation, even in the recent tail', () {
      final assembler =
          ContextAssembler(contextWindow: 100000, systemPrompt: 'sys');
      // Head and tail are wider than the clip keeps, so both survive intact
      // while the middle is elided (C4).
      final text = 'H' * 10000 + 'M' * 4000 + 'T' * 7000;
      final transcript = <Entry>[
        const UserEntry('goal'),
        AssistantEntry(
            thought: '',
            action: ToolBatch(
                [ToolCall(name: 'run_command', arguments: {'command': 'make'})])),
        ObservationEntry(text: text, outcome: Outcome.ok, toolCallId: 'c1'),
      ];
      final request = assembler.assemble(
          model: 'm', tools: const [], transcript: transcript);
      final shown = request.messages.whereType<ObservationEntry>().single.text;
      expect(shown, contains('HHHH'));
      expect(shown, contains('TTTT'));
      expect(shown, contains('tokens elided'));
      expect(shown.contains('MMMM'), isFalse);
      expect(shown.length, lessThanOrEqualTo(kObservationCapTokens * 4 + 60));
      // Clipping is a view; the stored transcript is unchanged.
      expect((transcript[2] as ObservationEntry).text, same(text));
    });

    test('clears stale re-fetchable results outside the verbatim tail', () {
      final assembler =
          ContextAssembler(contextWindow: 600, systemPrompt: 'sys');
      final transcript = <Entry>[
        const UserEntry('goal'),
        AssistantEntry(
            thought: '',
            action: ToolBatch([ToolCall(name: 'read', arguments: {'path': 'lib/a.dart'})])),
        ObservationEntry(text: 'a' * 800, outcome: Outcome.ok, toolCallId: 'c0'),
        AssistantEntry(
            thought: '',
            action: ToolBatch(
                [ToolCall(name: 'read', arguments: {'path': 'lib/missing.dart'})])),
        ObservationEntry(
            text: 'E' * 800, outcome: Outcome.error, toolCallId: 'c1'),
        AssistantEntry(
            thought: '',
            action: ToolBatch([ToolCall(name: 'read', arguments: {'path': 'lib/c.dart'})])),
        ObservationEntry(text: 'c' * 800, outcome: Outcome.ok, toolCallId: 'c2'),
        const UserEntry('current goal'),
      ];
      final request = assembler.assemble(
          model: 'm', tools: const [], transcript: transcript);
      final texts =
          request.messages.whereType<ObservationEntry>().map((o) => o.text);
      // The middle read is a one-line, re-runnable placeholder...
      expect(texts.first, contains('[cleared: read lib/a.dart'));
      expect(texts.first, contains('re-run to recover the output'));
      // ...an error observation survives verbatim even for a re-fetchable
      // tool, and the recent tail is untouched.
      expect(texts.skip(1).first, contains('EEEE'));
      expect(texts.last, contains('cccc'));
      expect(assembler.lastCompaction, isNull);
      // The clearing is queryable so the loop can credit a re-fetch of
      // cleared content as progress rather than a repeat stall (C8).
      expect(assembler.clearedInLastView('read', {'path': 'lib/a.dart'}),
          isTrue);
      expect(assembler.clearedInLastView('read', {'path': 'lib/c.dart'}),
          isFalse);
      // The exchange stays paired and the stored transcript is unchanged.
      expect(
          request.messages.whereType<AssistantEntry>().map((a) => a.action),
          everyElement(isA<ToolBatch>()));
      expect((transcript[2] as ObservationEntry).text, 'a' * 800);
    });

    test('compacts at a goal boundary past the watermark, not mid-run', () {
      List<Entry> history(int n) => [
            const UserEntry('old goal'),
            for (var i = 0; i < n; i++)
              ObservationEntry(text: 'x' * 400, outcome: Outcome.ok),
          ];
      final assembler =
          ContextAssembler(contextWindow: 1000, systemPrompt: 'sys');
      // ~80% used and the last entry is a fresh goal: a compactable boundary.
      assembler.assemble(
        model: 'm',
        tools: const [],
        transcript: [...history(8), const UserEntry('current goal')],
      );
      expect(assembler.lastCompaction, isNotNull);

      // Same pressure but mid-run (a step after the goal): leave it alone.
      assembler.assemble(
        model: 'm',
        tools: const [],
        transcript: [
          ...history(8),
          const UserEntry('current goal'),
          ObservationEntry(text: 'x' * 100, outcome: Outcome.ok),
        ],
      );
      expect(assembler.lastCompaction, isNull);
    });

    test('forces compaction mid-run only at the high-water mark', () {
      final assembler =
          ContextAssembler(contextWindow: 1000, systemPrompt: 'sys');
      assembler.assemble(
        model: 'm',
        tools: const [],
        transcript: [
          const UserEntry('old goal'),
          for (var i = 0; i < 9; i++)
            ObservationEntry(text: 'x' * 400, outcome: Outcome.ok),
          const UserEntry('current goal'),
          ObservationEntry(text: 'x' * 400, outcome: Outcome.ok),
        ],
      );
      expect(assembler.lastCompaction, isNotNull);
    });

    test('pins the goal and compacts older history', () {
      final assembler =
          ContextAssembler(contextWindow: 200, systemPrompt: 'sys');
      final transcript = <Entry>[
        const UserEntry('old goal'),
        for (var i = 0; i < 20; i++)
          ObservationEntry(text: 'x' * 200, outcome: Outcome.ok),
        const UserEntry('current goal'),
      ];
      final request = assembler.assemble(
        model: 'scripted',
        tools: const [],
        transcript: transcript,
      );
      expect(
        request.messages.whereType<UserEntry>().map((e) => e.text),
        contains('current goal'),
      );
    });

    test('folding keeps a structured working set, goals, and errors', () {
      final assembler =
          ContextAssembler(contextWindow: 200, systemPrompt: 'sys');
      final transcript = <Entry>[
        const UserEntry('old goal'),
        AssistantEntry(
            thought: '',
            action: ToolBatch([ToolCall(
                name: 'read', arguments: {'path': 'lib/a.dart'})])),
        ObservationEntry(text: 'x' * 400, outcome: Outcome.ok, toolCallId: 'c1'),
        AssistantEntry(
            thought: '',
            action: ToolBatch([ToolCall(
                name: 'edit', arguments: {'path': 'lib/a.dart'})])),
        ObservationEntry(
            text: 'x' * 800, outcome: Outcome.error, toolCallId: 'c2'),
        const UserEntry('current goal'),
      ];
      final request = assembler
          .assemble(model: 'm', tools: const [], transcript: transcript);
      final digest = request.messages.whereType<ObservationEntry>().first;
      expect(digest.text, contains('Goals: old goal'));
      expect(digest.text, contains('lib/a.dart'));
      expect(digest.text, contains('Errors:'));
      expect(assembler.lastCompaction, isNotNull);
      expect(assembler.lastUsedTokens, lessThanOrEqualTo(200));
    });

    test('folding never splits a tool call from its observation', () {
      final assembler =
          ContextAssembler(contextWindow: 500, systemPrompt: 'sys');
      final transcript = <Entry>[
        const UserEntry('goal'),
        for (var i = 0; i < 6; i++) ...[
          AssistantEntry(
              thought: '',
              action: ToolBatch([ToolCall(
                  id: 'c$i',
                  name: 'run_command',
                  arguments: {'command': 'cmd $i'})])),
          ObservationEntry(
              text: 'x' * 400, outcome: Outcome.ok, toolCallId: 'c$i'),
        ],
        const UserEntry('current goal'),
      ];
      final request = assembler
          .assemble(model: 'm', tools: const [], transcript: transcript);
      final ids = <String>{};
      for (final entry in request.messages) {
        if (entry is AssistantEntry && entry.action is ToolBatch) {
          for (final call in entry.action.calls) {
            final id = call.id;
            if (id != null) ids.add(id);
          }
        } else if (entry is ObservationEntry && entry.toolCallId != null) {
          expect(ids, contains(entry.toolCallId),
              reason: 'observation ${entry.toolCallId} lost its tool call');
        }
      }
    });

    test('folding is sticky across later steps', () {
      List<Entry> history(int n) => [
            const UserEntry('old goal'),
            for (var i = 0; i < n; i++)
              ObservationEntry(text: 'x' * 400, outcome: Outcome.ok),
          ];
      final assembler =
          ContextAssembler(contextWindow: 1000, systemPrompt: 'sys');
      assembler.assemble(
        model: 'm',
        tools: const [],
        transcript: [...history(8), const UserEntry('current goal')],
      );
      expect(assembler.lastCompaction, isNotNull);

      final second = assembler.assemble(
        model: 'm',
        tools: const [],
        transcript: [
          ...history(8),
          const UserEntry('current goal'),
          ObservationEntry(text: 'x' * 100, outcome: Outcome.ok),
        ],
      );
      // No new fold was needed, but the earlier fold is still applied rather
      // than re-expanding the raw history.
      expect(assembler.lastCompaction, isNull);
      expect(
        second.messages
            .whereType<ObservationEntry>()
            .any((o) => o.text.startsWith('Earlier session summary')),
        isTrue,
      );
    });

    test('a long single goal folds its own run too', () {
      final assembler =
          ContextAssembler(contextWindow: 1000, systemPrompt: 'sys');
      final transcript = <Entry>[
        const UserEntry('only goal'),
        for (var i = 0; i < 12; i++)
          ObservationEntry(text: 'x' * 400, outcome: Outcome.ok),
      ];
      final request = assembler
          .assemble(model: 'm', tools: const [], transcript: transcript);
      expect(assembler.lastCompaction, isNotNull);
      expect(
        request.messages
            .whereType<ObservationEntry>()
            .any((o) => o.text.startsWith('Earlier session summary')),
        isTrue,
      );
      // The goal is pinned even though the fold boundary moved past it.
      expect(
        request.messages.whereType<UserEntry>().map((e) => e.text),
        contains('only goal'),
      );
    });

    test('planCompaction returns a tools-withheld model task', () {
      final assembler =
          ContextAssembler(contextWindow: 200, systemPrompt: 'sys');
      final transcript = <Entry>[
        const UserEntry('old goal'),
        for (var i = 0; i < 10; i++)
          ObservationEntry(text: 'x' * 400, outcome: Outcome.ok),
        const UserEntry('current goal'),
      ];
      final task = assembler.planCompaction(
          model: 'm', tools: const [], transcript: transcript);
      expect(task, isNotNull);
      expect(task!.prompt.tools, isEmpty);
      expect(task.prompt.system, contains('brief'));
      final region = task.prompt.messages.single as UserEntry;
      expect(region.text, contains('xxxx'));
    });

    test('a model brief is used verbatim and not re-folded', () {
      final assembler =
          ContextAssembler(contextWindow: 200, systemPrompt: 'sys');
      final transcript = <Entry>[
        const UserEntry('old goal'),
        for (var i = 0; i < 10; i++)
          ObservationEntry(text: 'x' * 400, outcome: Outcome.ok),
        const UserEntry('current goal'),
      ];
      final task = assembler.planCompaction(
          model: 'm', tools: const [], transcript: transcript)!;
      assembler.applyCompaction(
          transcript, task.through, 'BRIEF: edited lib/a.dart');
      final request = assembler
          .assemble(model: 'm', tools: const [], transcript: transcript);
      final digest = request.messages.whereType<ObservationEntry>().first;
      expect(digest.text, 'BRIEF: edited lib/a.dart');
      // The loop already reported it; assemble does not fold again.
      expect(assembler.lastCompaction, isNull);
    });

    test('an empty brief falls back to the deterministic digest', () {
      final assembler =
          ContextAssembler(contextWindow: 200, systemPrompt: 'sys');
      final transcript = <Entry>[
        const UserEntry('old goal'),
        AssistantEntry(
            thought: '',
            action: ToolBatch([ToolCall(name: 'edit', arguments: {'path': 'lib/a.dart'})])),
        ObservationEntry(text: 'x' * 400, outcome: Outcome.ok, toolCallId: 'c1'),
        for (var i = 0; i < 10; i++)
          ObservationEntry(text: 'x' * 400, outcome: Outcome.ok),
        const UserEntry('current goal'),
      ];
      final task = assembler.planCompaction(
          model: 'm', tools: const [], transcript: transcript)!;
      assembler.applyCompaction(transcript, task.through, '   ');
      final request = assembler
          .assemble(model: 'm', tools: const [], transcript: transcript);
      final digest = request.messages.whereType<ObservationEntry>().first;
      expect(digest.text, startsWith('Earlier session summary'));
    });

    test('the compaction prompt carries tool paths and commands', () {
      final assembler =
          ContextAssembler(contextWindow: 400, systemPrompt: 'sys');
      final transcript = <Entry>[
        const UserEntry('old goal'),
        AssistantEntry(
            thought: '',
            action: ToolBatch([ToolCall(
                name: 'edit', arguments: {'path': 'lib/a.dart'})])),
        ObservationEntry(text: 'x' * 400, outcome: Outcome.ok, toolCallId: 'c1'),
        AssistantEntry(
            thought: '',
            action: ToolBatch([ToolCall(
                name: 'run_command', arguments: {'command': 'dart test'})])),
        ObservationEntry(text: 'x' * 400, outcome: Outcome.ok, toolCallId: 'c2'),
        for (var i = 0; i < 4; i++)
          ObservationEntry(text: 'x' * 400, outcome: Outcome.ok),
        const UserEntry('current goal'),
      ];
      final task = assembler.planCompaction(
          model: 'm', tools: const [], transcript: transcript)!;
      final body = (task.prompt.messages.single as UserEntry).text;
      expect(body, contains('lib/a.dart'));
      expect(body, contains('dart test'));
    });

    test('a later fold folds new work into the existing brief', () {
      final assembler =
          ContextAssembler(contextWindow: 200, systemPrompt: 'sys');
      final transcript = <Entry>[
        const UserEntry('old goal'),
        for (var i = 0; i < 10; i++)
          ObservationEntry(text: 'x' * 400, outcome: Outcome.ok),
        const UserEntry('current goal'),
      ];
      final task = assembler.planCompaction(
          model: 'm', tools: const [], transcript: transcript)!;
      assembler.applyCompaction(transcript, task.through, 'BRIEF: first');

      final grown = <Entry>[
        ...transcript,
        for (var i = 0; i < 10; i++)
          ObservationEntry(text: 'y' * 400, outcome: Outcome.ok),
        const UserEntry('next goal'),
      ];
      final forced = assembler.planCompaction(
          model: 'm',
          tools: const [],
          transcript: grown,
          force: true)!;
      final body = (forced.prompt.messages.single as UserEntry).text;
      expect(body, contains('Existing brief:'));
      expect(body, contains('BRIEF: first'));
    });
  });

  group('interface (C6)', () {
    test('embeddedCommand flags a command on a continuation line', () {
      expect(embeddedCommand('/help'), isNull);
      expect(embeddedCommand('foo\n/help'), '/help');
      expect(embeddedCommand('foo\nbar'), isNull);
      expect(embeddedCommand('foo\n/notacommand'), isNull);
    });

    test('a compaction is logged as command output', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final session = Session.create(workspaceRoot: temp.path);
      session.transcript
        ..add(const UserEntry('old goal'))
        ..addAll([
          for (var i = 0; i < 40; i++)
            ObservationEntry(text: 'x' * 200, outcome: Outcome.ok),
        ]);
      final config =
          _config(window: 1000, workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {
            'complete': {'text': 'done'}
          }
        ]
      });
      final out = StringBuffer();
      await runRepl(
        config: config,
        input: Stream.fromIterable(['new goal', '/exit']),
        out: out,
        err: StringBuffer(),
        human: true,
        session: session,
        providerFactory: (_) => provider,
      );
      expect(out.toString(), contains('compacted'));
    });

    test('handles commands and prints the plan', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final session = Session.create(workspaceRoot: temp.path)
        ..plan.add(const PlanItem(text: 'step one'));
      final out = StringBuffer();
      final err = StringBuffer();

      await runRepl(
        config: config,
        input: Stream.fromIterable(['/help', '/plan', '/status', '/exit']),
        out: out,
        err: err,
        providerFactory: (_) => ScriptedProvider.fromJson({'steps': []}),
        session: session,
      );
      expect(out.toString(), contains('Commands:'));
      expect(out.toString(), contains('- [ ] step one'));
      expect(out.toString(), contains('/compact'));
      expect(out.toString(), contains('session'));
    });

    test('/compact folds context on demand and reports it', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = _config(
          window: 2000, workspaceRoot: temp.path, sessionDir: temp.path);
      final session = Session.create(workspaceRoot: temp.path);
      session.transcript.add(const UserEntry('earlier goal'));
      for (var i = 0; i < 12; i++) {
        session.transcript
            .add(ObservationEntry(text: 'x' * 400, outcome: Outcome.ok));
      }
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {'complete': {'text': 'BRIEF: worked on lib/a.dart'}},
        ]
      });
      final out = StringBuffer();
      await runRepl(
        config: config,
        input: Stream.fromIterable(['/compact', '/exit']),
        out: out,
        err: StringBuffer(),
        providerFactory: (_) => provider,
        session: session,
      );
      expect(out.toString(), contains('compacted'));
      expect(provider.calls, 1);
    });

    test('/compact with nothing foldable says so', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final out = StringBuffer();
      await runRepl(
        config: config,
        input: Stream.fromIterable(['/compact', '/exit']),
        out: out,
        err: StringBuffer(),
        providerFactory: (_) => ScriptedProvider.fromJson({'steps': []}),
      );
      expect(out.toString(), contains('nothing to compact'));
    });

    test('changes the workspace root on the fly', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final other = Directory(p.join(temp.path, 'other'))..createSync();
      File(p.join(other.path, 'note.txt')).writeAsStringSync('hi');

      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {
            'complete': {
              'text': 'reading',
              'tool_calls': [
                {
                  'type': 'tool_call',
                  'name': 'read',
                  'arguments': {'path': 'note.txt'},
                }
              ],
            }
          },
          {'complete': {'text': 'done'}},
        ]
      });
      final out = StringBuffer();
      final err = StringBuffer();

      await runRepl(
        config: config,
        input: Stream.fromIterable(
            ['/workspace ${other.path}', 'read note.txt', '/exit']),
        out: out,
        err: err,
        providerFactory: (_) => provider,
      );
      expect(err.toString(), isNot(contains('blocked')));
      expect(out.toString(), contains('workspace ${other.path}'));
      expect(out.toString(), contains('done'));
    });

    test('automate prints measured timings to stderr, not stdout', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      File('${temp.path}/README.md').writeAsStringSync('hello\n');
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
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
          {'complete': {'text': 'hello'}},
        ]
      });
      final out = StringBuffer();
      final err = StringBuffer();
      await runRepl(
        config: config,
        input: Stream.fromIterable(['read it', '/exit']),
        out: out,
        err: err,
        providerFactory: (_) => provider,
      );
      expect(out.toString(), 'hello\n');
      // Without verbose there is no inline C2/tool trace, so the run total is
      // the only timing line; per-call timings require the automate trace.
      expect(err.toString(), contains('timing: run '));
      expect(err.toString(), isNot(contains('timing: read ')));
      expect(err.toString(), isNot(contains('timing: response ')));
    });
  });

  group('full-screen TUI (C6)', () {
    test('the console keeps a transcript, spinner, and status', () {
      final console = TuiConsole(width: 80);
      var changes = 0;
      console.onChange = () => changes++;
      console.user('hello');
      console.startThinking('thinking');
      console.setDetail('step 1');
      console.delta('world\n');
      console.endLine();
      console.tool('read', {'path': 'a.txt'});
      console.observation(Outcome.ok, 'contents', label: 'read');
      console.status('complete #1', kind: 'complete');
      console.close();

      final text = stripAnsi(console.transcript.join('\n'));
      expect(text, contains('› hello'));
      expect(text, contains('world'));
      expect(text, contains('→ read'));
      expect(text, contains('✓ read contents'));
      expect(console.statusText, 'complete #1');
      expect(console.statusKind, 'complete');
      expect(changes, greaterThan(0));
    });

    test('replaying a session does not duplicate a finish as reasoning', () {
      final console = TuiConsole(width: 60);
      console.replay(const [
        UserEntry('old goal'),
        AssistantEntry(thought: 'old answer', action: Finish('old answer')),
        AssistantEntry(
          thought: 'checking',
          action: ToolBatch([
            ToolCall(name: 'read', arguments: {'path': 'a.txt'}),
          ]),
        ),
        ObservationEntry(text: 'contents', outcome: Outcome.ok),
      ]);
      final text = stripAnsi(console.transcript.join('\n'));
      expect(text, contains('› old goal'));
      expect(text, contains('old answer'));
      expect(text, isNot(contains('│ old answer')));
      expect(text, contains('│ checking'));
      expect(text, contains('→ read'));
      expect(text, contains('✓ contents'));
    });

    test('the frame fills the terminal and keeps the editor cursor', () {
      final frame = TuiFrame(
        width: 60,
        height: 24,
        header: const ['  Sudoer dev', '  workspace /tmp'],
        transcript: const ['› hello', 'an answer'],
        partial: '',
        inputLines: const ['draft'],
        cursorRow: 0,
        cursorColumn: 5,
        status: '  ready',
        hint: '  Enter send',
        running: false,
        scrollOffset: 0,
        follow: true,
      ).render();
      final lines = frame.content.split('\n');
      expect(lines, hasLength(24));
      expect(stripAnsi(frame.content), contains('Sudoer dev'));
      expect(stripAnsi(frame.content), contains('message'));
      expect(stripAnsi(frame.content), contains('draft'));
      expect(stripAnsi(frame.content), contains('Enter send'));
      expect(frame.cursor.y, greaterThan(0));
      expect(frame.cursor.x, 9);
      for (final line in lines) {
        expect(stripAnsi(line).length, lessThanOrEqualTo(60));
      }
    });

    test('the frame follows the bottom and supports a scroll offset', () {
      final long = List<String>.generate(100, (i) => 'line $i');
      final bottom = TuiFrame(
        width: 40,
        height: 16,
        header: const ['  h1', '  h2'],
        transcript: long,
        partial: '',
        inputLines: const [''],
        cursorRow: 0,
        cursorColumn: 0,
        status: '',
        hint: '',
        running: false,
        scrollOffset: 0,
        follow: true,
      ).render();
      expect(stripAnsi(bottom.content), contains('line 99'));
      expect(stripAnsi(bottom.content), isNot(contains('line 0')));

      final top = TuiFrame(
        width: 40,
        height: 16,
        header: const ['  h1', '  h2'],
        transcript: long,
        partial: '',
        inputLines: const [''],
        cursorRow: 0,
        cursorColumn: 0,
        status: '',
        hint: '',
        running: false,
        scrollOffset: 0,
        follow: false,
      ).render();
      expect(stripAnsi(top.content), contains('line 0'));
      expect(stripAnsi(top.content), isNot(contains('line 99')));
    });
  });

  group('goal attachments (C7)', () {
    test('strips @path tokens and loads image bytes', () {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final image = File(p.join(temp.path, 'shot.png'))
        ..writeAsBytesSync([1, 2, 3]);
      final parsed = parseGoal('fix this @${image.path} now');
      expect(parsed.text, 'fix this now');
      expect(parsed.images, hasLength(1));
      expect(parsed.images.single.path, image.path);
      expect(parsed.images.single.bytes, [1, 2, 3]);
    });

    test('rejects a missing or non-image token', () {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      File(p.join(temp.path, 'notes.txt')).writeAsStringSync('x');
      expect(() => parseGoal('look @${temp.path}/nope.png'),
          throwsA(isA<FormatException>()));
      expect(() => parseGoal('look @${temp.path}/notes.txt'),
          throwsA(isA<FormatException>()));
    });

    test('leaves a bare @ and non-leading tokens alone', () {
      final parsed = parseGoal('email me at a@b.com, or just @');
      expect(parsed.text, 'email me at a@b.com, or just @');
      expect(parsed.images, isEmpty);
    });

    test('the transcript keeps a text reference only', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final image = File(p.join(temp.path, 'shot.png'))
        ..writeAsBytesSync([1, 2, 3]);
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final agent = PropAgent.assemble(
        config: config,
        provider: ScriptedProvider.fromJson({
          'steps': [
            {'complete': {'text': 'seen'}}
          ]
        }),
      );
      await agent.run(RunRequest('look',
          images: [ImageAttachment(path: image.path, bytes: [1, 2, 3])]));
      final goal = agent.session.transcript.first;
      expect(goal, isA<UserEntry>());
      expect((goal as UserEntry).images, [image.path]);
      // Only the path is persisted; the bytes never enter the session file.
      expect(goal.toJson()['images'], [image.path]);
      expect(jsonEncode(agent.session.toJson()), isNot(contains('base64')));
    });
  });

  group('provider wire mapping (C2)', () {
    test('binds tool results by id and never dangles', () {
      const request = ProviderRequest(
        model: 'm',
        system: 'sys',
        messages: [
          UserEntry('go'),
          AssistantEntry(
            thought: 't',
            action: ToolBatch([ToolCall(id: 'abc', name: 'read', arguments: {'path': 'a'})]),
          ),
          ObservationEntry(
              text: 'ok', outcome: Outcome.ok, toolCallId: 'abc'),
          AssistantEntry(thought: 'done', action: Finish('done')),
          UserEntry('again'),
          ObservationEntry(
              text: 'provider error: timeout', outcome: Outcome.error),
        ],
        tools: [],
      );
      final messages = openAiMessages(request);
      final toolMessages =
          messages.where((m) => m['role'] == 'tool').toList();
      expect(toolMessages, hasLength(1));
      expect(toolMessages.single['tool_call_id'], 'abc');
      expect(messages.last['role'], 'user');
      expect(messages.last['content'] as String, contains('observation:'));
    });

    test('replays a nameless tool call as text, never a dangling tool call',
        () {
      const request = ProviderRequest(
        model: 'm',
        system: 'sys',
        messages: [
          UserEntry('go'),
          AssistantEntry(
            thought: 'let me look',
            action: ToolBatch([ToolCall(id: 'ghost', name: '', arguments: {'command': 'ls'})]),
          ),
          ObservationEntry(
            text: 'tool call is missing a name',
            outcome: Outcome.error,
            toolCallId: 'ghost',
          ),
        ],
        tools: [],
      );
      final messages = openAiMessages(request);
      final assistant = messages.firstWhere((m) => m['role'] == 'assistant');
      expect(assistant.containsKey('tool_calls'), isFalse);
      expect(assistant['content'], 'let me look');
      expect(messages.any((m) => m['role'] == 'tool'), isFalse);
      expect(messages.last['role'], 'user');
      expect(messages.any((m) => m['tool_call_id'] == 'ghost'), isFalse);
    });

    test('attach goal images to the last user message (openai-compatible)',
        () {
      const request = ProviderRequest(
        model: 'm',
        system: 'sys',
        messages: [
          UserEntry('first'),
          AssistantEntry(thought: 't', action: Finish('t')),
          UserEntry('look'),
        ],
        tools: [],
        images: [
          ImageAttachment(path: 'shot.png', bytes: [1, 2, 3]),
        ],
      );
      final messages = openAiMessages(request);
      final last = messages.last;
      expect(last['role'], 'user');
      final content = last['content'] as List;
      expect(content.first, {'type': 'text', 'text': 'look'});
      final part = content.last as Map<String, dynamic>;
      expect(part['type'], 'image_url');
      expect((part['image_url'] as Map)['url'],
          startsWith('data:image/png;base64,'));
      // Earlier user entries keep plain text.
      expect(messages[1]['content'], 'first');
    });

    test('attach goal images to the last user message (ollama)', () {
      const request = ProviderRequest(
        model: 'm',
        system: 'sys',
        messages: [
          UserEntry('first'),
          AssistantEntry(thought: 't', action: Finish('t')),
          UserEntry('look'),
        ],
        tools: [],
        images: [
          ImageAttachment(path: 'shot.png', bytes: [1, 2, 3]),
        ],
      );
      final messages = ollamaMessages(request);
      expect(messages.last['images'], [base64Encode([1, 2, 3])]);
      expect(messages[1].containsKey('images'), isFalse);
    });

    test('dispatch names the catalog when the tool name is empty', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final registry = ToolRegistry(workspaceRoot: temp.path);
      final missing =
          await registry.dispatch(const ToolCall(name: '', arguments: {}));
      expect(missing.outcome, Outcome.error);
      expect(missing.text, contains('missing a name'));
      expect(missing.text, contains('run_command'));
      final unknown =
          await registry.dispatch(const ToolCall(name: 'nope', arguments: {}));
      expect(unknown.text, contains('unknown tool: nope'));
    });

    test('the loop binds a tool call id to its observation', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      File('${temp.path}/a.txt').writeAsStringSync('x');
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {
            'complete': {
              'text': 'reading',
              'tool_calls': [
                {
                  'type': 'tool_call',
                  'name': 'read',
                  'arguments': {'path': 'a.txt'},
                }
              ],
            }
          },
          {'complete': {'text': 'done'}},
        ]
      });
      final agent = PropAgent.assemble(config: config, provider: provider);
      await agent.run(const RunRequest('read'));
      final assistant =
          agent.session.transcript.whereType<AssistantEntry>().first;
      final call = (assistant.action as ToolBatch).calls.single;
      expect(call.id, isNotNull);
      final observation =
          agent.session.transcript.whereType<ObservationEntry>().first;
      expect(observation.toolCallId, call.id);
    });
  });

  group('plan convention (C2)', () {
    test('extracts a fenced plan block and strips it from the text', () {
      final parsed = parsePlanBlock(
          'planning\n```plan\n- [ ] read a.txt\n- [x] answer\n```\n');
      expect(parsed.text, 'planning');
      expect(
        [for (final item in parsed.plan!) '${item.text}:${item.done}'],
        ['read a.txt:false', 'answer:true'],
      );
    });

    test('leaves text untouched when there is no plan block', () {
      final parsed = parsePlanBlock('just an answer');
      expect(parsed.text, 'just an answer');
      expect(parsed.plan, isNull);
    });

    test('does not touch other fenced blocks', () {
      const text = 'here\n```dart\n- [ ] not a plan\n```';
      final parsed = parsePlanBlock(text);
      expect(parsed.text, text);
      expect(parsed.plan, isNull);
    });

    test('an empty plan block means no change', () {
      final parsed = parsePlanBlock('x\n```plan\n\n```');
      expect(parsed.plan, isNull);
      expect(parsed.text, 'x');
    });

    test('the openai adapter parses and strips a plan block', () async {
      final config = _config(
          kind: 'openai-compatible', extra: {'base_url': 'http://x'});
      // The adapter always streams on the wire (C8: inactivity-bounded),
      // so the mock serves SSE even for a callback-less one-shot call.
      final body = 'data: ${jsonEncode({
            'choices': [
              {
                'delta': {
                  'role': 'assistant',
                  'content': 'planning\n```plan\n- [ ] a\n- [x] b\n```',
                }
              }
            ]
          })}\n\ndata: [DONE]\n\n';
      final client = MockClient((_) async => http.Response(body, 200));
      final provider =
          OpenAiCompatibleProvider(config.provider, client: client);
      final response = await provider.complete(const ProviderRequest(
          model: 'm', system: 's', messages: [UserEntry('go')], tools: []));
      expect(response.thought, 'planning');
      expect(
        [for (final item in response.plan!) '${item.text}:${item.done}'],
        ['a:false', 'b:true'],
      );
    });

    test('the ollama adapter parses and strips a plan block', () async {
      final config = _config();
      final client = MockClient((_) async => http.Response(
            jsonEncode({
              'message': {
                'role': 'assistant',
                'content': 'planning\n```plan\n- [ ] a\n- [x] b\n```',
              }
            }),
            200,
          ));
      final provider = OllamaProvider(config.provider, client: client);
      final response = await provider.complete(const ProviderRequest(
          model: 'm', system: 's', messages: [UserEntry('go')], tools: []));
      expect(response.thought, 'planning');
      expect(
        [for (final item in response.plan!) '${item.text}:${item.done}'],
        ['a:false', 'b:true'],
      );
    });

    test('an invalid key fails as a StepFailure before it reaches HTTP',
        () async {
      final config = ProviderConfig.fromJson({
        'preset': 'openai',
        'model': 'gpt-test',
        'api_key': 'pasted ┃ transcript',
      });
      final client = MockClient((_) async {
        fail('the client must not be called with an invalid header');
      });
      final provider = OpenAiCompatibleProvider(config, client: client);
      await expectLater(
        provider.complete(const ProviderRequest(
            model: 'm', system: 's', messages: [UserEntry('go')], tools: [])),
        throwsA(isA<StepFailure>()
            .having((e) => e.message, 'message', contains('invalid'))),
      );
    });

    test('a MiniMax 401 explains the region mismatch', () async {
      final config = ProviderConfig.fromJson({
        'preset': 'minimax',
        'model': 'MiniMax-M3',
        'api_key': 'sk-test',
      });
      final client = MockClient((_) async => http.Response(
            '{"type":"error","error":{"type":"authorized_error",'
            '"message":"invalid api key (2049)","http_code":"401"}}',
            401,
          ));
      final provider = OpenAiCompatibleProvider(config, client: client);
      await expectLater(
        provider.complete(const ProviderRequest(
            model: 'm', system: 's', messages: [UserEntry('go')], tools: [])),
        throwsA(isA<StepFailure>()
            .having((e) => e.message, 'message', contains('region-specific'))
            .having((e) => e.message, 'message', contains('minimax-cn'))),
      );
    });
  });

  group('diagnostics (C6)', () {
    test('a disabled sink drops events; enabled forwards with the component id',
        () {
      final lines = <String>[];
      final diagnostics = Diagnostics(sink: lines.add);
      diagnostics.event('C1 loop', 'ignored');
      expect(lines, isEmpty);
      diagnostics.enabled = true;
      diagnostics.event('C1 loop', 'step 1/8');
      expect(lines.single, '[C1 loop] step 1/8');
    });

    test('off by default; /verbose on emits routing and results', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      File('${temp.path}/a.txt').writeAsStringSync('x');
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      Provider scripted() => ScriptedProvider.fromJson({
            'steps': [
              {
                'complete': {
                  'text': 'reading',
                  'tool_calls': [
                    {
                      'type': 'tool_call',
                      'name': 'read',
                      'arguments': {'path': 'a.txt'},
                    }
                  ],
                }
              },
              {'complete': {'text': 'done'}},
            ]
          });

      final quietErr = StringBuffer();
      await runRepl(
        config: config,
        input: Stream.fromIterable(['read a.txt', '/exit']),
        out: StringBuffer(),
        err: quietErr,
        providerFactory: (_) => scripted(),
      );
      expect(quietErr.toString(), isNot(contains('[C1 loop]')));

      final loudOut = StringBuffer();
      final loudErr = StringBuffer();
      await runRepl(
        config: config,
        input: Stream.fromIterable(['/verbose on', 'read a.txt', '/exit']),
        out: loudOut,
        err: loudErr,
        providerFactory: (_) => scripted(),
      );
      expect(loudOut.toString(), contains('verbose on'));
      expect(loudErr.toString(), contains('[C1 loop]'));
      expect(loudErr.toString(), contains('[C3 tools]'));
      expect(loudErr.toString(), contains('[C4 context]'));
      expect(loudErr.toString(), contains('[C5 session]'));
    });

    test('the result diagnostic prints the block reason, not the object',
        () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = Config.fromJson({
        'provider': {
          'kind': 'ollama',
          'model': 'scripted',
          'context_window': 8192,
        },
        'workspace_root': temp.path,
        'session_dir': temp.path,
        'web': {
          'enabled': true,
          'deny_hosts': ['evil.example'],
        },
      });
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {
            'complete': {
              'text': 'fetching',
              'tool_calls': [
                {
                  'type': 'tool_call',
                  'name': 'web_fetch',
                  'arguments': {'url': 'http://evil.example/notes'},
                }
              ],
            }
          }
        ]
      });
      final err = StringBuffer();
      await runRepl(
        config: config,
        input: Stream.fromIterable(
            ['/verbose on', 'fetch http://evil.example/notes', '/exit']),
        out: StringBuffer(),
        err: err,
        providerFactory: (_) => provider,
      );
      final text = err.toString();
      expect(text, contains(
          '[C6 interface] result blocked (web egress to evil.example'));
      expect(text, isNot(contains('Instance of')));
    });
  });

  group('automate log format (C6)', () {
    final stamp = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z ');

    test('StampingSink prefixes every line; blank lines pass through', () {
      final sink = StringBuffer();
      final stamped = StampingSink(sink);
      stamped.writeln('first');
      stamped.writeln('multi\nline');
      stamped.writeln();
      stamped.writeln('');
      final text = sink.toString();
      expect(text.split('\n').first, matches(stamp));
      for (final line in text.split('\n').where((l) => l.isNotEmpty)) {
        expect(line, matches(stamp));
      }
      expect(text, contains(' first\n'));
      expect(text, contains(' multi\n'));
      expect(text, contains(' line\n'));
      // Empty writes stay blank separators.
      expect(text, contains('\n\n'));
      // write() forwards untouched: not a line-oriented log write.
      sink.clear();
      stamped.write('not a log line');
      expect(sink.toString(), 'not a log line');
    });

    test('logTimestamp is UTC with millisecond precision', () {
      expect(
        logTimestamp(DateTime.parse('2026-10-06T02:21:53.123Z')),
        '2026-10-06T02:21:53.123Z',
      );
      expect(
        logTimestamp(DateTime.parse('2026-01-02T03:04:05.006Z')),
        '2026-01-02T03:04:05.006Z',
      );
    });

    test('verbose automate stderr is timestamped and traces LLM traffic',
        () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      File('${temp.path}/a.txt').writeAsStringSync('x');
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {
            'complete': {
              'text': 'reading',
              'tool_calls': [
                {
                  'type': 'tool_call',
                  'name': 'read',
                  'arguments': {'path': 'a.txt'},
                }
              ],
            }
          },
          {'complete': {'text': 'done text'}},
        ]
      });
      final out = StringBuffer();
      final err = StringBuffer();
      await runCli(
        config: config,
        goal: 'read a.txt',
        out: out,
        err: err,
        providerFactory: (_) => provider,
        verbose: true,
      );
      // stdout stays the clean answer surface.
      expect(out.toString(), 'done text\n');
      final text = err.toString();
      // Every non-blank stderr line carries a timestamp prefix.
      for (final line in text.split('\n').where((l) => l.isNotEmpty)) {
        expect(line, matches(stamp));
      }
      // The request/response traffic is on the record, with context.
      expect(text, contains('── request step 1 ──'));
      expect(text, contains('── request step 2 ──'));
      expect(text, contains('ctx ~'));
      expect(text, contains('messages=1 new=1'));
      expect(text, contains('── system'));
      expect(text, contains('[C2 provider]   You are Sudoer'));
      expect(text, contains('── user'));
      expect(text, contains('[C2 provider]   read a.txt'));
      expect(text, contains('── tool_calls ──'));
      expect(text, contains('── observation ok for '));
      expect(text, contains('── finish'));
      expect(text, contains('[C2 provider]   done text'));
      // The second request diffs instead of re-dumping: the goal is not
      // reprinted and the new tail is announced.
      expect('── system'.allMatches(text).length, 1);
      expect(text, contains('earlier message unchanged'));
      expect(text, contains('── assistant'));
      // Timings ride inline with the response and each tool result.
      expect(text, contains('timing: response '));
      expect(text, contains('timing: read '));
      expect(text, contains(RegExp(r'Z \[C2 provider\] timing: response ')));
    });

    test('the human surface is never stamped nor traced', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider =
          ScriptedProvider.fromJson({'steps': [{'complete': {'text': 'ok'}}]});
      final err = StringBuffer();
      await runCli(
        config: config,
        goal: 'hi',
        out: StringBuffer(),
        err: err,
        providerFactory: (_) => provider,
        verbose: true,
        human: true,
      );
      final text = stripAnsi(err.toString());
      expect(text, contains('[C1 loop]'));
      expect(text, isNot(contains('── system')));
      expect(text, isNot(contains('── finish')));
      expect(text, isNot(contains('timing: response ')));
      for (final line in text.split('\n').where((l) => l.trim().isNotEmpty)) {
        expect(line, isNot(matches(stamp)));
      }
    });

    test('the automate surface logs the session id to resume', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final session = Session.create(workspaceRoot: temp.path, id: 'fixed-id');
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await runCli(
        config: config,
        goal: 'hi',
        out: out,
        err: err,
        session: session,
        providerFactory: (_) =>
            ScriptedProvider.fromJson({'steps': [{'complete': {'text': 'ok'}}]}),
      );
      expect(code, 0);
      // The answer surface stays clean; the resume hint lands on the log.
      expect(out.toString(), 'ok\n');
      expect(err.toString(),
          contains('session fixed-id (resume: --session fixed-id)'));
    });
  });

  group('plan stream (C2)', () {
    test('withholds an arriving plan block across chunks', () {
      final stream = PlanTextStream();
      expect(stream.add('x\n```p'), 'x\n');
      expect(stream.add('lan\n- [ ] a'), '');
      expect(stream.add('\n```'), '');
      expect(stream.flush(), '');
      expect(stream.plan!.single.text, 'a');
    });

    test('streamed visible text matches the one-shot parse', () {
      const raw = 'hello\n```plan\n- [ ] x\n```\nworld';
      final stream = PlanTextStream();
      final out = StringBuffer();
      for (final ch in raw.split('')) {
        out.write(stream.add(ch));
      }
      out.write(stream.flush());
      expect(out.toString(), parsePlanBlock(raw).text);
      expect(out.toString(), 'hello\nworld');
    });

    test('leaves non-plan fences intact while streaming', () {
      const raw = 'here\n```dart\ncode\n```\nend';
      final stream = PlanTextStream();
      final out = StringBuffer();
      for (final ch in raw.split('')) {
        out.write(stream.add(ch));
      }
      out.write(stream.flush());
      expect(out.toString(), raw);
      expect(stream.plan, isNull);
    });
  });

  group('think convention (C2)', () {
    test('extracts a think block and strips it from the text', () {
      final parsed =
          parseThinkBlock('answer\n<think>\nhidden\nreason\n</think>\ntail');
      expect(parsed.text, 'answer\n\ntail');
      expect(parsed.reasoning, '\nhidden\nreason\n');
    });

    test('leaves text untouched when there is no think block', () {
      final parsed = parseThinkBlock('just an answer');
      expect(parsed.text, 'just an answer');
      expect(parsed.reasoning, '');
    });

    test('is case-insensitive and strips an unclosed block', () {
      expect(parseThinkBlock('<THINK>hush</THINK>ok').text, 'ok');
      expect(parseThinkBlock('ok\n<think>still going').text, 'ok');
      expect(parseThinkBlock('ok\n<think>still going').reasoning,
          'still going');
    });

    test('the openai adapter strips a think block one-shot', () async {
      final config = _config(
          kind: 'openai-compatible', extra: {'base_url': 'http://x'});
      // The adapter always streams on the wire (C8: inactivity-bounded),
      // so the mock serves SSE even for a callback-less one-shot call.
      final body = 'data: ${jsonEncode({
            'choices': [
              {
                'delta': {
                  'role': 'assistant',
                  'content': '<think>deliberating</think>answer',
                }
              }
            ]
          })}\n\ndata: [DONE]\n\n';
      final client = MockClient((_) async => http.Response(body, 200));
      final provider =
          OpenAiCompatibleProvider(config.provider, client: client);
      final response = await provider.complete(const ProviderRequest(
          model: 'm', system: 's', messages: [UserEntry('go')], tools: []));
      expect(response.thought, 'answer');
      expect(response.reasoning, 'deliberating');
    });
  });

  group('think stream (C2)', () {
    test('withholds a partial think tag across chunks', () {
      final stream = ThinkTextStream();
      expect(stream.add('a<thi').visible, 'a');
      expect(stream.add('nk>hidden</thi').reasoning, 'hidden');
      expect(stream.add('nk>b').visible, 'b');
      expect(stream.flush().isEmpty, isTrue);
      expect(stream.reasoning, 'hidden');
    });

    test('streamed text matches the one-shot parse', () {
      const raw = 'hello<think>secret</think> world';
      final stream = ThinkTextStream();
      final visible = StringBuffer();
      final reasoning = StringBuffer();
      for (final ch in raw.split('')) {
        final chunk = stream.add(ch);
        visible.write(chunk.visible);
        reasoning.write(chunk.reasoning);
      }
      final tail = stream.flush();
      visible.write(tail.visible);
      reasoning.write(tail.reasoning);
      final parsed = parseThinkBlock(raw);
      expect(visible.toString(), parsed.text);
      expect(reasoning.toString(), parsed.reasoning);
    });
  });

  group('streaming adapters (C2)', () {
    test('openai streams content and hides the plan block', () async {
      final config = _config(
          kind: 'openai-compatible', extra: {'base_url': 'http://x'});
      final client = _StreamClient([
        'data: {"choices":[{"delta":{"content":"planning"}}]}\n\n',
        'data: {"choices":[{"delta":{"content":"\\n```plan\\n- [ ] a\\n"}}]}\n\n',
        'data: {"choices":[{"delta":{"content":"- [x] b\\n```"}}]}\n\n',
        'data: [DONE]\n\n',
      ]);
      final provider =
          OpenAiCompatibleProvider(config.provider, client: client);
      final deltas = <String>[];
      final response = await provider.complete(
        const ProviderRequest(
            model: 'm', system: 's', messages: [UserEntry('go')], tools: []),
        onDelta: deltas.add,
      );
      expect(response.thought, 'planning');
      expect([for (final i in response.plan!) '${i.text}:${i.done}'],
          ['a:false', 'b:true']);
      expect(deltas.join(), isNot(contains('```')));
      expect(deltas.join().trim(), 'planning');
    });

    test('openai reassembles streamed tool calls', () async {
      final config = _config(
          kind: 'openai-compatible', extra: {'base_url': 'http://x'});
      final client = _StreamClient([
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_x","function":{"name":"read","arguments":"{\\"pa"}}]}}]}\n\n',
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\\":\\"a.txt\\"}"}}]}}]}\n\n',
        'data: [DONE]\n\n',
      ]);
      final provider =
          OpenAiCompatibleProvider(config.provider, client: client);
      final response = await provider.complete(
        const ProviderRequest(
            model: 'm', system: 's', messages: [UserEntry('go')], tools: []),
        onDelta: (_) {},
      );
      final call = (response.action as ToolBatch).calls.single;
      expect(call.id, 'call_x');
      expect(call.name, 'read');
      expect(call.arguments, {'path': 'a.txt'});
    });

    test('openai keeps name/id when later chunks repeat them empty', () async {
      final config = _config(
          kind: 'openai-compatible', extra: {'base_url': 'http://x'});
      // MiniMax sends the name on the first chunk, then repeats the call on
      // the arguments chunk with empty strings for id and function.name.
      final client = _StreamClient([
        'data: {"choices":[{"delta":{"tool_calls":[{"id":"call_01a","type":"function","function":{"name":"run_command","arguments":""},"index":0}]}}]}\n\n',
        'data: {"choices":[{"delta":{"tool_calls":[{"id":"","type":"","function":{"name":"","arguments":"{\\"command\\":\\"ls\\"}"},"index":0}]}}]}\n\n',
        'data: [DONE]\n\n',
      ]);
      final provider =
          OpenAiCompatibleProvider(config.provider, client: client);
      final response = await provider.complete(
        const ProviderRequest(
            model: 'm', system: 's', messages: [UserEntry('go')], tools: []),
        onDelta: (_) {},
      );
      final call = (response.action as ToolBatch).calls.single;
      expect(call.id, 'call_01a');
      expect(call.name, 'run_command');
      expect(call.arguments, {'command': 'ls'});
    });

    test('openai streams reasoning separately and hides it from the answer',
        () async {
      final config = _config(
          kind: 'openai-compatible', extra: {'base_url': 'http://x'});
      final client = _StreamClient([
        'data: {"choices":[{"delta":{"content":"<thi"}}]}\n\n',
        'data: {"choices":[{"delta":{"content":"nk>planning</think>hello"}}]}\n\n',
        'data: [DONE]\n\n',
      ]);
      final provider =
          OpenAiCompatibleProvider(config.provider, client: client);
      final deltas = <String>[];
      final reasoning = <String>[];
      final response = await provider.complete(
        const ProviderRequest(
            model: 'm', system: 's', messages: [UserEntry('go')], tools: []),
        onDelta: deltas.add,
        onReasoning: reasoning.add,
      );
      expect(reasoning.join(), 'planning');
      expect(deltas.join(), 'hello');
      expect(response.thought, 'hello');
      expect(response.reasoning, 'planning');
    });

    test('ollama streams reasoning separately and hides it from the answer',
        () async {
      final config = _config();
      final client = _StreamClient([
        '{"message":{"role":"assistant","content":"<think>why</think>answer"},"done":false}\n',
        '{"message":{"role":"assistant","content":""},"done":true}\n',
      ]);
      final provider = OllamaProvider(config.provider, client: client);
      final deltas = <String>[];
      final reasoning = <String>[];
      final response = await provider.complete(
        const ProviderRequest(
            model: 'm', system: 's', messages: [UserEntry('go')], tools: []),
        onDelta: deltas.add,
        onReasoning: reasoning.add,
      );
      expect(reasoning.join(), 'why');
      expect(deltas.join(), 'answer');
      expect(response.thought, 'answer');
      expect(response.reasoning, 'why');
    });

    test('ollama streams content and hides the plan block', () async {
      final config = _config();
      final client = _StreamClient([
        '{"message":{"role":"assistant","content":"planning"},"done":false}\n',
        '{"message":{"role":"assistant","content":"\\n```plan\\n- [ ] a\\n- [x] b\\n```"},"done":false}\n',
        '{"message":{"role":"assistant","content":""},"done":true}\n',
      ]);
      final provider = OllamaProvider(config.provider, client: client);
      final deltas = <String>[];
      final response = await provider.complete(
        const ProviderRequest(
            model: 'm', system: 's', messages: [UserEntry('go')], tools: []),
        onDelta: deltas.add,
      );
      expect(response.thought, 'planning');
      expect([for (final i in response.plan!) '${i.text}:${i.done}'],
          ['a:false', 'b:true']);
      expect(deltas.join(), isNot(contains('```')));
    });
  });

  group('mode selection (C6)', () {
    test('automate wins, human forces, else terminal decides', () {
      expect(
          chooseMode(automate: true, human: false, interactive: true),
          UiMode.automate);
      expect(
          chooseMode(automate: false, human: true, interactive: false),
          UiMode.human);
      expect(
          chooseMode(automate: false, human: false, interactive: false),
          UiMode.automate);
      expect(
          chooseMode(automate: false, human: false, interactive: true),
          UiMode.human);
    });
  });

  group('build identity (C6)', () {
    test('the repo constant is baked in; dart test injects no version', () {
      expect(kRepoUrl, 'https://github.com/invented-pro/sudoer');
      // `dart test` compiles without defines, so the version is the dev
      // label; the release build injects it via -DSUDOER_VERSION.
      expect(kPropVersion, isEmpty);
      expect(kBuildLabel, 'dev');
    });

    test('the human greeting leads with version and repo link', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final err = StringBuffer();
      await runRepl(
        config: config,
        input: Stream.fromIterable(['/exit']),
        out: StringBuffer(),
        err: err,
        human: true,
        providerFactory: (_) =>
            ScriptedProvider.fromJson({'steps': const []}),
      );
      final flat = stripAnsi(err.toString());
      expect(flat, contains('Sudoer $kBuildLabel'));
      expect(flat.indexOf('Sudoer $kBuildLabel'),
          lessThan(flat.indexOf(kRepoUrl)));
      expect(flat, contains(kRepoUrl));
    });
  });

  group('console (C6)', () {
    test('context bar fills in proportion', () {
      expect(contextBar(5, 10, 10), '[█████░░░░░]');
      expect(contextBar(0, 0, 10), '');
    });

    test('briefText flattens whitespace and caps length', () {
      expect(briefText('a\n\n b   c'), 'a b c');
      expect(briefText('abcdef', 3), 'abc…');
    });

    test('shortPath keeps the tail', () {
      expect(shortPath('/aaaa/bbbb/cccc', 8), '…bb/cccc');
    });

    test('outcome marks', () {
      expect(outcomeMark(Outcome.ok), '✓');
      expect(outcomeMark(Outcome.guardDenied), '⛔');
    });

    test('styling is identity when ansi is off, SGR when on', () {
      final plain = Console(out: StringBuffer(), err: StringBuffer(), ansi: false);
      expect(plain.style('hi', bold: true, italic: true), 'hi');
      final pretty = Console(out: StringBuffer(), err: StringBuffer(), ansi: true);
      final styled = pretty.style('hi', bold: true, fg: const RgbColor(1, 2, 3));
      expect(styled, contains('\x1b['));
      expect(stripAnsi(styled), 'hi');
    });

    test('human REPL streams inline without an alt-screen takeover', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      File('${temp.path}/a.txt').writeAsStringSync('x');
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {
            'complete': {
              'text': 'reading',
              'tool_calls': [
                {
                  'type': 'tool_call',
                  'name': 'read',
                  'arguments': {'path': 'a.txt'},
                }
              ],
            }
          },
          {'complete': {'text': 'done'}},
        ]
      });
      final out = StringBuffer();
      final err = StringBuffer();
      await runRepl(
        config: config,
        input: Stream.fromIterable(['read a.txt and answer', '/exit']),
        out: out,
        err: err,
        human: true,
        providerFactory: (_) => provider,
      );
      expect(out.toString(), contains('done'));
      expect(out.toString(), contains('› '));
      expect(out.toString(), contains('\x1b['));
      expect(out.toString(), isNot(contains('\x1b[?1049h'))); // no alt screen
    });

    test('an idle spinner stop emits nothing (cannot erase the reply)', () {
      final err = StringBuffer();
      final console =
          Console(out: StringBuffer(), err: err, ansi: true, spinner: true);
      console.stopThinking();
      expect(err.toString(), isEmpty);

      console.startThinking('thinking');
      // Visible output stops the spinner; extra stops must not clear again.
      console.delta('the answer\n');
      final clears =
          RegExp(r'\x1b\[2K').allMatches(err.toString()).length;
      console.stopThinking();
      console.stopThinking();
      expect(RegExp(r'\x1b\[2K').allMatches(err.toString()).length, clears);
    });

    test('the spinner stays live while a reply block buffers', () {
      final err = StringBuffer();
      final console =
          Console(out: StringBuffer(), err: err, ansi: true, spinner: true);
      console.startThinking('thinking');
      // A partial line renders nothing; the spinner must not stop.
      console.delta('still typing the first line');
      final clears =
          RegExp(r'\x1b\[2K').allMatches(err.toString()).length;
      console.stopThinking();
      expect(
          RegExp(r'\x1b\[2K').allMatches(err.toString()).length, clears + 1);
    });

    test('command output never shares a line with the spinner', () {
      final out = StringBuffer();
      final err = StringBuffer();
      final console =
          Console(out: out, err: err, ansi: true, spinner: true);
      console.startThinking('thinking');
      console.info('↺ compacted 47 steps');
      // The message is its own line on stdout...
      expect(stripAnsi(out.toString()), endsWith('↺ compacted 47 steps\n'));
      // ...and never leaks onto the spinner's stream.
      expect(err.toString(), isNot(contains('compacted')));
      // The spinner was resumed: stopping it now clears a live line.
      final clears =
          RegExp(r'\x1b\[2K').allMatches(err.toString()).length;
      console.stopThinking();
      expect(RegExp(r'\x1b\[2K').allMatches(err.toString()).length, clears + 1);
    });

    test('command output is quiet on stderr when no spinner runs', () {
      final err = StringBuffer();
      final console =
          Console(out: StringBuffer(), err: err, ansi: true, spinner: true);
      console.info('help');
      expect(err.toString(), isEmpty);
    });

    test('a diagnostic never shares a line with the spinner', () {
      final err = StringBuffer();
      final console =
          Console(out: StringBuffer(), err: err, ansi: true, spinner: true);
      console.startThinking('thinking');
      console.diagnostic('[C4 context] prompt 1 messages, no compaction');
      // The spinner line is cleared before the diagnostic is written.
      final clears = RegExp(r'\x1b\[2K').allMatches(err.toString()).length;
      expect(clears, greaterThanOrEqualTo(2));
      expect(stripAnsi(err.toString()), contains('[C4 context]'));
      // The spinner resumes: stopping it now clears a live line.
      console.stopThinking();
      expect(RegExp(r'\x1b\[2K').allMatches(err.toString()).length, clears + 1);
    });

    test('reasoning is a dim italic gutter block on stderr', () {
      final out = StringBuffer();
      final err = StringBuffer();
      final console = Console(out: out, err: err, ansi: true, spinner: true);
      console.reasoning('line one\nline two');
      final flat = stripAnsi(err.toString());
      expect(err.toString(), contains('\x1b['));
      expect(flat, contains('│ line one'));
      expect(flat, contains('│ line two'));
      expect(out.toString(), isEmpty);
    });

    test('a diagnostic styles the tag only when ansi is on', () {
      final plain = StringBuffer();
      Console(out: StringBuffer(), err: plain, ansi: false)
          .diagnostic('[C1 loop] step 1/8');
      expect(plain.toString(), '[C1 loop] step 1/8\n');

      final styled = StringBuffer();
      Console(out: StringBuffer(), err: styled, ansi: true)
          .diagnostic('[C3 tools] read -> ok');
      expect(styled.toString(), contains('\x1b['));
      expect(stripAnsi(styled.toString()), contains('[C3 tools] read -> ok'));
    });

    test('multi-line results indent the body beneath the first line', () {
      final err = StringBuffer();
      final console = Console(out: StringBuffer(), err: err, ansi: false);
      console.observation(Outcome.ok, 'first\nsecond\nthird',
          label: 'run_command');
      final lines = err.toString().trimRight().split('\n');
      expect(lines.first, contains('run_command'));
      expect(lines.first, contains('first'));
      expect(lines[1].trimLeft(), '│ second');
      expect(lines[2].trimLeft(), '│ third');
    });

    test('successful result bodies are dimmed under a gutter', () {
      final err = StringBuffer();
      final console = Console(out: StringBuffer(), err: err, ansi: true);
      console.observation(Outcome.ok, 'first\nsecond', label: 'run_command');
      final bodyLine = err.toString().split('\n')[1];
      expect(stripAnsi(bodyLine).trimLeft(), '│ second');
      expect(bodyLine, contains('108;112;134')); // slate gutter
      expect(bodyLine, contains('\x1b[2')); // dim
    });

    test('error result bodies stay red', () {
      final err = StringBuffer();
      final console = Console(out: StringBuffer(), err: err, ansi: true);
      console.observation(Outcome.error, 'first\nsecond', label: 'run_command');
      final bodyLine = err.toString().split('\n')[1];
      expect(bodyLine, contains('243;139;168')); // red
    });

    test('formatDuration renders ms, seconds, and minutes', () {
      expect(formatDuration(const Duration(milliseconds: 840)), '840ms');
      expect(formatDuration(const Duration(milliseconds: 3200)), '3.2s');
      expect(formatDuration(const Duration(seconds: 123)), '2m03s');
    });

    test('timing suffixes render on tool and result lines', () {
      final err = StringBuffer();
      final console = Console(out: StringBuffer(), err: err, ansi: false);
      console.tool('read', {'path': 'a.dart'},
          elapsed: const Duration(milliseconds: 2400));
      console.observation(Outcome.ok, 'contents',
          label: 'read', elapsed: const Duration(milliseconds: 42));
      final lines = err.toString().trimRight().split('\n');
      expect(lines[0], contains('· 2.4s'));
      expect(lines[1], contains('· 42ms'));
    });

    test('model output is magenta, command output yellow, input default', () {
      final out = StringBuffer();
      final err = StringBuffer();
      final console =
          Console(out: out, err: err, ansi: true, spinner: false);
      console.prompt();
      console.user('goal');
      console.info('help');
      console.delta('answer');
      console.endLine();
      expect(out.toString(), contains('38;2;249;226;175')); // yellow (command)
      expect(out.toString(), contains('38;2;245;194;231')); // magenta (model)
      expect(stripAnsi(out.toString()), contains('answer'));
      // The user's prompt/echo carry no color of their own.
      expect(err.toString(), isNot(contains('38;2;245;194;231')));
      expect(out.toString(), contains('› '));
    });

    test('the spinner shows the interrupt hint', () {
      final err = StringBuffer();
      final console =
          Console(out: StringBuffer(), err: err, ansi: true, spinner: true);
      console.setHint('press Esc twice to interrupt');
      console.startThinking('thinking');
      expect(stripAnsi(err.toString()),
          contains('press Esc twice to interrupt'));
      console.setHint(null);
      console.stopThinking();
    });

    test('spinner renders the phase then its detail', () async {
      final err = StringBuffer();
      final console =
          Console(out: StringBuffer(), err: err, ansi: true, spinner: true);
      console.startThinking('thinking');
      console.setDetail('step 2 · stalled 1/3');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      console.stopThinking();
      expect(stripAnsi(err.toString()),
          contains('thinking · step 2 · stalled 1/3'));
    });

    test('status line numbers responses and shows a ctx percentage', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {
            'complete': {'text': 'one'}
          },
          {
            'complete': {'text': 'two'}
          },
        ]
      });
      final err = StringBuffer();
      await runRepl(
        config: config,
        input: Stream.fromIterable(['first', 'second', '/exit']),
        out: StringBuffer(),
        err: err,
        human: true,
        providerFactory: (_) => provider,
      );
      final flat = stripAnsi(err.toString());
      // The status word is replaced by the run total, e.g. `3ms #1`.
      expect(flat, contains(RegExp(r'\d(ms|s) #1')));
      expect(flat, contains('#2'));
      expect(flat, contains('%'));
      expect(flat, contains('8.2K')); // window 8192 -> K
    });

    test('status line renders a large context window in M', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = _config(
          workspaceRoot: temp.path, sessionDir: temp.path, window: 1000000);
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {
            'complete': {'text': 'ok'}
          }
        ]
      });
      final err = StringBuffer();
      await runRepl(
        config: config,
        input: Stream.fromIterable(['go', '/exit']),
        out: StringBuffer(),
        err: err,
        human: true,
        providerFactory: (_) => provider,
      );
      final flat = stripAnsi(err.toString());
      expect(flat, contains('/1M '));
      expect(flat, contains(RegExp(r'\(\d+(\.\d)?%\)')));
    });

    test('human REPL shows reasoning on stderr, answer on stdout', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {
            'complete': {'text': 'done', 'reasoning': 'ponder'}
          }
        ]
      });
      final out = StringBuffer();
      final err = StringBuffer();
      await runRepl(
        config: config,
        input: Stream.fromIterable(['go', '/exit']),
        out: out,
        err: err,
        human: true,
        providerFactory: (_) => provider,
      );
      expect(out.toString(), contains('done'));
      expect(out.toString(), isNot(contains('ponder')));
      expect(err.toString(), contains('ponder'));
    });
  });

  group('markdown render (C6)', () {
    test('renders headings, emphasis and inline code', () {
      expect(renderMarkdown('# Title\n\nbody', _plainStyle),
          'Title\n─────\n\nbody');
      expect(renderMarkdown('a **b** *c* `d`', _plainStyle), 'a b c d');
    });

    test('renders a fenced code block with a language tag', () {
      expect(
        renderMarkdown('```dart\nvar x = 1;\n```', _plainStyle),
        '  ╭─ dart\n  │ var x = 1;\n  ╰─',
      );
    });

    test('renders lists, quotes, rules and links', () {
      expect(renderMarkdown('- one\n- two', _plainStyle), '• one\n• two');
      expect(renderMarkdown('1. one\n2. two', _plainStyle), '1. one\n2. two');
      expect(renderMarkdown('> quote', _plainStyle), '│ quote');
      expect(renderMarkdown('---', _plainStyle), '─' * 78);
      expect(renderMarkdown('[text](http://x)', _plainStyle),
          'text (http://x)');
    });

    test('renders a table with aligned columns', () {
      final rendered =
          renderMarkdown('| a | b |\n|---|---|\n| 1 | 2 |', _plainStyle);
      expect(rendered, contains('│ a │ b │'));
      expect(rendered, contains('├───┼───┤'));
      expect(rendered, contains('│ 1 │ 2 │'));
    });

    test('a stream emits prose lines as they complete', () {
      final stream = MarkdownStream();
      expect(stream.add('para one', _plainStyle), '');
      expect(stream.add('\n', _plainStyle), 'para one\n');
      expect(stream.add('\n', _plainStyle), '');
      expect(stream.add('tail', _plainStyle), '');
      expect(stream.flush(_plainStyle), 'tail\n');
    });

    test('a stream renders code as its fence and lines arrive', () {
      final stream = MarkdownStream();
      expect(stream.add('```dart\n', _plainStyle), '  ╭─ dart\n');
      expect(stream.add('var x = 1;\n', _plainStyle), '  │ var x = 1;\n');
      expect(stream.add('```\n', _plainStyle), '  ╰─\n');
    });

    test('a stream closes an unterminated code block on flush', () {
      final stream = MarkdownStream();
      expect(stream.add('```\ncode without end', _plainStyle), '  ╭─\n');
      expect(stream.flush(_plainStyle), '  │ code without end\n  ╰─\n');
    });

    test('a stream renders a list-indented code fence', () {
      final stream = MarkdownStream();
      expect(stream.add('- static binary:\n', _plainStyle), '• static binary:\n');
      expect(stream.add('  ```bash\n', _plainStyle), '  ╭─ bash\n');
      expect(stream.add('  gcc -O2 main.c\n', _plainStyle), '  │ gcc -O2 main.c\n');
      expect(stream.add('  ```\n', _plainStyle), '  ╰─\n');
    });

    test('a stream repairs a fence glued to a heading', () {
      final stream = MarkdownStream();
      final head = stream.add('## Steps```bash\n', _plainStyle);
      expect(head, contains('Steps'));
      expect(head, contains('  ╭─ bash\n'));
      expect(stream.add('echo hi\n', _plainStyle), '  │ echo hi\n');
      expect(stream.add('```\n', _plainStyle), '  ╰─\n');
    });

    test('a stream leaves an inline triple-backtick run alone', () {
      final stream = MarkdownStream();
      final out = stream.add('use ```code``` here\n', _plainStyle);
      expect(out, isNot(contains('╭─')));
      expect(out, contains('code'));
    });

    test('a stream buffers a table until the block ends', () {
      final stream = MarkdownStream();
      expect(stream.add('| a | b |\n', _plainStyle), '');
      expect(stream.add('|---|---|\n', _plainStyle), '');
      expect(stream.add('| 1 | 2 |\n', _plainStyle), '');
      final rendered = stream.flush(_plainStyle);
      expect(rendered, contains('│ a │ b │'));
      expect(rendered, contains('│ 1 │ 2 │'));
    });

    test('console renders streamed markdown to stdout with styling', () {
      final out = StringBuffer();
      final console =
          Console(out: out, err: StringBuffer(), ansi: true, spinner: false);
      console.delta('**bold**');
      expect(out.toString(), isEmpty);
      console.endLine();
      expect(out.toString(), contains('\x1b['));
      expect(stripAnsi(out.toString()), contains('bold'));
      expect(out.toString(), isNot(contains('**')));
    });

    test('human REPL renders the markdown answer, not the raw source',
        () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {
            'complete': {'text': '# done\n\nwith **weight**'}
          }
        ]
      });
      final out = StringBuffer();
      await runRepl(
        config: config,
        input: Stream.fromIterable(['go', '/exit']),
        out: out,
        err: StringBuffer(),
        human: true,
        providerFactory: (_) => provider,
      );
      final flat = stripAnsi(out.toString());
      expect(flat, contains('done'));
      expect(flat, contains('weight'));
      expect(flat, isNot(contains('**')));
      expect(flat, isNot(contains('# done')));
    });
  });

  group('terminal keys (C6)', () {
    test('decodes arrow key sequences', () async {
      final reader = KeyReader(Stream.fromIterable([
        [0x1b, 0x5b, 0x41, 0x1b, 0x5b, 0x42, 0x1b, 0x5b, 0x43, 0x1b, 0x5b, 0x44],
      ]));
      final keys = <Key>[];
      await for (final key in reader.keys) {
        keys.add(key);
        if (keys.length == 4) break;
      }
      expect(keys.map((k) => k.kind),
          [KeyKind.up, KeyKind.down, KeyKind.right, KeyKind.left]);
      await reader.close();
    });

    test('a lone ESC is emitted after the timeout', () async {
      final reader = KeyReader(Stream.fromIterable([[0x1b]]),
          escTimeout: const Duration(milliseconds: 10));
      final key = await reader.keys.first;
      expect(key.kind, KeyKind.esc);
      await reader.close();
    });

    test('decodes control keys', () async {
      final reader = KeyReader(Stream.fromIterable([[13, 127, 3, 4]]));
      final keys = <Key>[];
      await for (final key in reader.keys) {
        keys.add(key);
        if (keys.length == 4) break;
      }
      expect(keys.map((k) => k.kind),
          [KeyKind.enter, KeyKind.backspace, KeyKind.ctrlC, KeyKind.ctrlD]);
      await reader.close();
    });

    test('decodes a multi-byte rune', () async {
      final reader = KeyReader(Stream.fromIterable([utf8.encode('中')]));
      final key = await reader.keys.first;
      expect(key.kind, KeyKind.rune);
      expect(String.fromCharCode(key.rune), '中');
      await reader.close();
    });

    test('bracketed paste arrives as one paste key, not submits', () async {
      final bytes = [
        ...utf8.encode('\x1b[200~'),
        ...utf8.encode('foo\nbar'),
        ...utf8.encode('\x1b[201~'),
        13,
      ];
      final reader = KeyReader(Stream.fromIterable([bytes]));
      final keys = <Key>[];
      await for (final key in reader.keys) {
        keys.add(key);
        if (keys.length == 2) break;
      }
      expect(keys[0].kind, KeyKind.paste);
      expect(keys[0].text, 'foo\nbar');
      expect(keys[1].kind, KeyKind.enter);
      await reader.close();
    });

    test('a paste with CRLF and control bytes is normalized', () async {
      final bytes = [
        ...utf8.encode('\x1b[200~'),
        ...utf8.encode('a\r\nb\u0007c'),
        ...utf8.encode('\x1b[201~'),
      ];
      final reader = KeyReader(Stream.fromIterable([bytes]));
      final key = await reader.keys.first;
      expect(key.kind, KeyKind.paste);
      expect(key.text, 'a\nbc');
      await reader.close();
    });

    test('a paste split across reads is delivered whole', () async {
      final reader = KeyReader(Stream.fromIterable([
        [...utf8.encode('\x1b[200~foo'), 10],
        [...utf8.encode('bar'), ...utf8.encode('\x1b[201~')],
      ]));
      final key = await reader.keys.first;
      expect(key.kind, KeyKind.paste);
      expect(key.text, 'foo\nbar');
      await reader.close();
    });

    test('a malformed paste still delivers on end of input', () async {
      final reader = KeyReader(
          Stream.fromIterable([utf8.encode('\x1b[200~unterminated')]));
      final key = await reader.keys.first;
      expect(key.kind, KeyKind.paste);
      expect(key.text, 'unterminated');
      await reader.close();
    });

    test('a newline with printable text behind it is a paste break', () async {
      final reader = KeyReader(Stream.fromIterable([utf8.encode('foo\nbar')]));
      final keys = <Key>[];
      await for (final key in reader.keys) {
        keys.add(key);
        if (keys.length == 7) break;
      }
      expect(keys.map((k) => k.kind), [
        KeyKind.rune, KeyKind.rune, KeyKind.rune, KeyKind.newline,
        KeyKind.rune, KeyKind.rune, KeyKind.rune,
      ]);
      await reader.close();
    });

    test('a lone newline is still the submit gesture', () async {
      final reader = KeyReader(Stream.fromIterable([[13, 127, 3, 4]]));
      final keys = <Key>[];
      await for (final key in reader.keys) {
        keys.add(key);
        if (keys.length == 4) break;
      }
      expect(keys.first.kind, KeyKind.enter);
      await reader.close();
    });

    test('decodes PageUp and PageDown', () async {
      final reader =
          KeyReader(Stream.fromIterable([utf8.encode('\x1b[5~\x1b[6~')]));
      final keys = <Key>[];
      await for (final key in reader.keys) {
        keys.add(key);
        if (keys.length == 2) break;
      }
      expect(keys.map((k) => k.kind), [KeyKind.pageUp, KeyKind.pageDown]);
      await reader.close();
    });

    test('decodes Alt+Enter and Kitty Shift+Enter as newline', () async {
      final reader = KeyReader(Stream.fromIterable([
        [0x1b, 0x0d, 0x1b, 0x0a],
        utf8.encode('\x1b[13;2u'),
      ]));
      final keys = <Key>[];
      await for (final key in reader.keys) {
        keys.add(key);
        if (keys.length == 3) break;
      }
      expect(keys.map((k) => k.kind), [
        KeyKind.altEnter,
        KeyKind.altEnter,
        KeyKind.altEnter,
      ]);
      await reader.close();
    });
  });

  group('line editor (C6)', () {
    late StringBuffer out;
    late LineEditor editor;

    setUp(() {
      out = StringBuffer();
      editor = LineEditor(write: out.write, stylePrompt: (prompt) => prompt);
    });

    EditResult typeInto(LineEditor e, String text) {
      var result = const EditResult.pending();
      for (final rune in text.runes) {
        result = e.handle(Key(KeyKind.rune, rune));
      }
      return result;
    }

    test('left arrow moves the cursor so text is inserted', () {
      editor.begin();
      typeInto(editor, 'abc');
      editor.handle(const Key(KeyKind.left));
      typeInto(editor, 'X');
      expect(editor.text, 'abXc');
    });

    test('backspace deletes before the cursor', () {
      editor.begin();
      typeInto(editor, 'ab');
      editor.handle(const Key(KeyKind.backspace));
      expect(editor.text, 'a');
    });

    test('home and end move the cursor', () {
      editor.begin();
      typeInto(editor, 'abc');
      editor.handle(const Key(KeyKind.home));
      typeInto(editor, 'Z');
      editor.handle(const Key(KeyKind.end));
      typeInto(editor, '!');
      expect(editor.text, 'Zabc!');
    });

    test('up/down walk the history and restore the draft', () {
      editor.begin();
      typeInto(editor, 'first');
      editor.handle(const Key(KeyKind.enter));
      editor.begin();
      typeInto(editor, 'second');
      editor.handle(const Key(KeyKind.enter));
      editor.begin();
      editor.handle(const Key(KeyKind.up));
      expect(editor.text, 'second');
      editor.handle(const Key(KeyKind.up));
      expect(editor.text, 'first');
      editor.handle(const Key(KeyKind.down));
      expect(editor.text, 'second');
      editor.handle(const Key(KeyKind.down));
      expect(editor.text, '');
    });

    test('a trailing backslash continues onto the next line', () {
      editor.begin();
      typeInto(editor, 'foo\\');
      final first = editor.handle(const Key(KeyKind.enter));
      expect(first.kind, EditKind.pending);
      typeInto(editor, 'bar');
      final second = editor.handle(const Key(KeyKind.enter));
      expect(second.kind, EditKind.submit);
      expect(second.text, 'foo\nbar');
    });

    test('a pasted newline breaks the line without submitting', () {
      editor.begin();
      typeInto(editor, 'foo');
      final broke = editor.handle(const Key(KeyKind.newline));
      expect(broke.kind, EditKind.pending);
      typeInto(editor, 'bar');
      expect(editor.text, 'foo\nbar');
      final submit = editor.handle(const Key(KeyKind.enter));
      expect(submit.kind, EditKind.submit);
      expect(submit.text, 'foo\nbar');
    });

    test('a pasted newline splits at the cursor', () {
      editor.begin();
      typeInto(editor, 'foobar');
      editor.handle(const Key(KeyKind.left));
      editor.handle(const Key(KeyKind.left));
      editor.handle(const Key(KeyKind.left));
      editor.handle(const Key(KeyKind.newline));
      expect(editor.text, 'foo\nbar');
    });

    test('a paste inserts its whole text at the cursor in one edit', () {
      editor.begin();
      typeInto(editor, 'foobar');
      editor.handle(const Key(KeyKind.left));
      editor.handle(const Key(KeyKind.left));
      editor.handle(const Key(KeyKind.left));
      final result = editor.handle(const Key(KeyKind.paste, 0, 'X\nY'));
      expect(result.kind, EditKind.pending);
      expect(editor.text, 'fooX\nYbar');
    });

    test('a paste keeps multi-byte runes intact', () {
      editor.begin();
      editor.handle(const Key(KeyKind.paste, 0, '中\n文'));
      expect(editor.text, '中\n文');
    });

    test('ctrl+C clears the current line', () {
      editor.begin();
      typeInto(editor, 'junk');
      editor.handle(const Key(KeyKind.ctrlC));
      expect(editor.text, '');
    });

    test('ctrl+D is EOF only on an empty line', () {
      editor.begin();
      typeInto(editor, 'x');
      expect(editor.handle(const Key(KeyKind.ctrlD)).kind, EditKind.pending);
      editor.handle(const Key(KeyKind.ctrlC));
      expect(editor.handle(const Key(KeyKind.ctrlD)).kind, EditKind.eof);
    });

    test('the cursor column counts wide runes as two cells', () {
      editor.begin();
      typeInto(editor, '其实');
      expect(_lastCursorColumn(out), 6); // `› ` + 2 + 2
    });

    test('the cursor column mixes narrow and wide runes', () {
      editor.begin();
      typeInto(editor, 'a其b');
      expect(_lastCursorColumn(out), 6); // 2 + 1 + 2 + 1
    });

    test('left arrow then insert splits between wide runes', () {
      editor.begin();
      typeInto(editor, '其实');
      editor.handle(const Key(KeyKind.left));
      expect(_lastCursorColumn(out), 4); // cursor between 其 and 实
      typeInto(editor, 'X');
      expect(editor.text, '其X实');
    });

    test('home returns the cursor to the prompt column', () {
      editor.begin();
      typeInto(editor, '其实');
      editor.handle(const Key(KeyKind.home));
      expect(_lastCursorColumn(out), 2);
    });

    test('an astral emoji is wide and backspaces as one rune', () {
      editor.begin();
      typeInto(editor, '😀');
      expect(editor.text, '😀');
      expect(_lastCursorColumn(out), 4); // 2 + 2
      editor.handle(const Key(KeyKind.backspace));
      expect(editor.text, '');
    });

    test('a combining mark adds no cursor width', () {
      editor.begin();
      typeInto(editor, 'é');
      expect(_lastCursorColumn(out), 3); // 2 + 1 + 0
    });

    test('an emoji variation selector widens a narrow base', () {
      editor.begin();
      typeInto(editor, '❤️');
      expect(_lastCursorColumn(out), 4); // 2 + 2
    });

    test('finish parks the cursor after the wide text', () {
      editor.begin();
      typeInto(editor, '其实');
      editor.handle(const Key(KeyKind.enter));
      out.clear();
      editor.finish();
      expect(out.toString(), contains('\x1b[6C'));
    });
  });

  group('display width (C6)', () {
    test('runeWidth classifies narrow, wide, and zero-width runes', () {
      expect(runeWidth(0x61), 1); // a
      expect(runeWidth(0x4E2D), 2); // 中
      expect(runeWidth(0xFF21), 2); // fullwidth Ａ
      expect(runeWidth(0x3002), 2); // 。
      expect(runeWidth(0x0301), 0); // combining acute accent
      expect(runeWidth(0x1F3FB), 0); // emoji skin-tone modifier
      expect(runeWidth(0xFE0F), 0); // variation selector
    });

    test('runesWidth sums display cells across kinds', () {
      expect(runesWidth('其实a'.runes), 5); // 2 + 2 + 1
      expect(runesWidth('❤️'.runes), 2); // narrow base widened by VS16
      expect(runesWidth(''.runes), 0);
    });
  });

  group('interrupt gesture (C6)', () {
    test('two Esc within the window interrupt; slow presses reset', () {
      final now = DateTime(2026, 1, 1);
      final esc = DoubleEsc(window: const Duration(milliseconds: 700));
      expect(esc.press(now), isFalse);
      expect(esc.press(now.add(const Duration(milliseconds: 300))), isTrue);
      expect(esc.press(now.add(const Duration(seconds: 5))), isFalse);
      expect(esc.press(now.add(const Duration(seconds: 5, milliseconds: 100))),
          isTrue);
    });
  });

  group('cancellation (C8)', () {
    test('the signal fires once and can be reset', () async {
      final signal = CancelSignal();
      expect(signal.isCancelled, isFalse);
      var fired = 0;
      signal.whenCancelled.then((_) => fired++);
      signal.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(signal.isCancelled, isTrue);
      expect(fired, 1);
      signal.reset();
      expect(signal.isCancelled, isFalse);
    });

    test('raceCancel fails with a cancelled StepFailure', () async {
      final signal = CancelSignal();
      final pending = Completer<void>();
      final raced = raceCancel(pending.future, signal);
      signal.cancel();
      await expectLater(
        raced,
        throwsA(isA<StepFailure>()
            .having((e) => e.kind, 'kind', FailureKind.cancelled)),
      );
    });

    test('raceCancel passes through an un-cancelled future', () async {
      expect(await raceCancel(Future.value(7), CancelSignal()), 7);
    });

    test('the loop ends at once when the provider call is cancelled', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = _BlockingProvider();
      final agent = PropAgent.assemble(config: config, provider: provider);
      final run = agent.run(const RunRequest('do a thing'));
      await provider.started.future;
      agent.session.cancel.cancel();
      final result = await run;
      expect(result.status, RunStatus.incomplete);
      expect(result.reason, 'cancelled');
    });

    test('the openai adapter aborts a streaming call on cancel', () async {
      final config = _config(
          kind: 'openai-compatible', extra: {'base_url': 'http://x'});
      final client = _HangingClient();
      addTearDown(client.dispose);
      final provider =
          OpenAiCompatibleProvider(config.provider, client: client);
      final signal = CancelSignal();
      final future = provider.complete(
        const ProviderRequest(
            model: 'm', system: 's', messages: [UserEntry('go')], tools: []),
        onDelta: (_) {},
        cancel: signal,
      );
      signal.cancel();
      await expectLater(
        future,
        throwsA(isA<StepFailure>()
            .having((e) => e.kind, 'kind', FailureKind.cancelled)),
      );
    });

    test('a cancelled command returns an error outcome', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final tool = RunCommandTool(WorkspaceGuard(temp.path));
      final signal = CancelSignal();
      final future =
          tool.executeCancellable({'command': _blockingCommand()}, signal);
      signal.cancel();
      final outcome = await future;
      expect(outcome.outcome, Outcome.error);
      expect(outcome.text, contains('cancelled'));
    });

    test('a mid-run /cancel on the piped surface aborts the run', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = _BlockingProvider();
      final input = StreamController<String>();
      final out = StringBuffer();
      final err = StringBuffer();
      final repl = runRepl(
        config: config,
        input: input.stream,
        out: out,
        err: err,
        providerFactory: (_) => provider,
      );
      input.add('do a thing');
      await provider.started.future;
      input.add('/cancel');
      input.add('/exit');
      await input.close();
      final outcome = await repl;
      expect(out.toString(), isEmpty);
      expect(err.toString(), contains('cancelled'));
      expect(outcome.session.transcript.whereType<UserEntry>().length, 1);
    });

    test('the help lists /cancel only on the automate surface', () {
      expect(helpLines(interactive: true).join('\n'), isNot(contains('/cancel')));
      expect(helpLines(interactive: false).join('\n'), contains('/cancel'));
    });

    test('the human help notes the backslash line continuation', () {
      expect(
          helpLines(interactive: true).join('\n'),
          contains(
              'end a line with \\ to continue the goal on the next line'));
      expect(
          helpLines(interactive: false).join('\n'),
          isNot(contains('continue the goal on the next line')));
    });

    test('the TUI help teaches the multi-line editor instead', () {
      final text = helpLines(interactive: true, tui: true).join('\n');
      expect(text, contains('Shift+Enter or Alt+Enter adds a line'));
      expect(text, isNot(contains('end a line with \\')));
    });

    test('a /cancel sent while idle does not leak into the next goal',
        () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final out = StringBuffer();
      final outcome = await runRepl(
        config: config,
        input: Stream.fromIterable(['/cancel', 'do a thing', '/exit']),
        out: out,
        err: StringBuffer(),
        providerFactory: (_) => ScriptedProvider.fromJson({
          'steps': [
            {'complete': {'text': 'ok'}}
          ]
        }),
      );
      expect(out.toString(), contains('ok'));
      expect(outcome.exitCode, 0);
    });
  });

  group('direct shell (C6)', () {
    test('runShellCommand forwards stdout, stderr and the exit code', () async {
      final out = StringBuffer();
      final err = StringBuffer();
      final command = Platform.isWindows
          ? 'echo out & echo err 1>&2 & exit /b 3'
          : 'echo out; echo err 1>&2; exit 3';
      final code = await runShellCommand(
        command: command,
        workingDirectory: Directory.systemTemp.path,
        out: out,
        err: err,
      );
      expect(out.toString().trim(), 'out');
      expect(err.toString().trim(), 'err');
      expect(code, 3);
    });

    test('the human help lists ! but the automate help does not', () {
      expect(helpLines(interactive: true).join('\n'), contains('!<command>'));
      expect(helpLines(interactive: false).join('\n'),
          isNot(contains('!<command>')));
    });

    test('a ! line runs directly in the interactive CLI, never the model',
        () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final raw = StreamController<List<int>>();
      final out = StringBuffer();
      final repl = runRepl(
        config: config,
        input: const Stream<String>.empty(),
        rawInput: raw.stream,
        interactive: true,
        human: true,
        out: out,
        err: StringBuffer(),
        providerFactory: (_) => ScriptedProvider.fromJson({'steps': []}),
      );
      raw.add(utf8.encode('!echo hi\r'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      raw.add([4]); // Ctrl+D: end of input.
      await raw.close();
      final outcome = await repl;
      expect(out.toString(), contains('hi'));
      expect(outcome.runs, isEmpty);
    });
  });

  group('host shell (C3)', () {
    test('runs a command and captures stdout and the exit code', () async {
      final shell = HostShell();
      final (process, _) =
          await shell.start('echo hello', Directory.systemTemp.path);
      final out = await process.stdout.transform(utf8.decoder).join();
      final code = await process.exitCode;
      expect(out.trim(), 'hello');
      expect(code, 0);
    });

    test('killTree ends a running command tree', () async {
      final shell = HostShell();
      final (process, grouped) =
          await shell.start(_blockingCommand(), Directory.systemTemp.path);
      await shell.killTree(process, grouped);
      final code = await process.exitCode;
      expect(code, isNot(0));
    });
  });

  group('environment expansion (C6)', () {
    test('expands a set variable', () {
      final path = Platform.environment['PATH'];
      expect(path, isNotNull);
      expect(expandEnv(r'${PATH}'), path);
    });

    test('throws on an unset variable', () {
      expect(
        () => expandEnv(r'$SUDOER_DEFINITELY_UNSET_VAR'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('expands nested config values', () {
      final config = Config.fromJson({
        'provider': {
          'kind': 'openai-compatible',
          'base_url': 'https://example.test/v1',
          'api_key': r'${PATH}',
          'model': 'm',
          'context_window': 100,
        },
          'workspace_root': Directory.systemTemp.path,
      });
      expect(config.provider.apiKey, Platform.environment['PATH']);
    });
  });

  group('batch actions (C1/C2)', () {
    test('the wire shape round-trips a tool_calls batch', () {
      const action = ToolBatch([
        ToolCall(id: 'a', name: 'read', arguments: {'path': 'x'}),
        ToolCall(id: 'b', name: 'glob', arguments: {'pattern': '*.md'}),
      ]);
      final json = action.toJson();
      expect(json['type'], 'tool_calls');
      expect((json['tool_calls'] as List).length, 2);
      final back = Action.fromJson((jsonDecode(jsonEncode(json)) as Map)
          .cast<String, dynamic>());
      expect(back, isA<ToolBatch>());
      expect((back as ToolBatch).calls.length, 2);
      expect(back.calls[1].name, 'glob');
    });

    test('a legacy single tool_call action loads as a batch of one', () {
      final action = Action.fromJson({
        'type': 'tool_call',
        'id': 'old',
        'name': 'read',
        'arguments': {'path': 'a'},
      });
      expect(action, isA<ToolBatch>());
      expect((action as ToolBatch).calls.single.id, 'old');
    });

    test('one step dispatches a read-only batch and answers every call', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-batch-');
      addTearDown(() => temp.deleteSync(recursive: true));
      File(p.join(temp.path, 'a.txt')).writeAsStringSync('A');
      File(p.join(temp.path, 'b.txt')).writeAsStringSync('B');
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {
            'complete': {
              'text': 'reading both',
              'tool_calls': [
                {
                  'type': 'tool_call',
                  'name': 'read',
                  'arguments': {'path': 'a.txt'},
                },
                {
                  'type': 'tool_call',
                  'name': 'read',
                  'arguments': {'path': 'b.txt'},
                },
              ],
            }
          },
          {'complete': {'text': 'done'}},
        ]
      });
      final callLog = <String>[];
      final agent = PropAgent.assemble(
          config: config, provider: provider, callLog: callLog);
      final result = await agent.run(const RunRequest('read both'));
      expect(result.status, RunStatus.complete);
      expect(callLog, ['read', 'read']);
      // One assistant decision carrying both calls...
      final decisions =
          agent.session.transcript.whereType<AssistantEntry>().toList();
      expect(decisions.length, 2); // the batch step and the finish
      expect((decisions[0].action as ToolBatch).calls.length, 2);
      // ...followed by one observation per call, in the listed order.
      final observations = agent.session.transcript
          .whereType<ObservationEntry>()
          .map((o) => o.text)
          .toList();
      expect(observations, ['A', 'B']);
      // ids bind each observation to its call for replay.
      final ids =
          (decisions[0].action as ToolBatch).calls.map((c) => c.id).toList();
      expect(
          agent.session.transcript
              .whereType<ObservationEntry>()
              .map((o) => o.toolCallId),
          ids);
    });

    test('a sibling timeout does not discard completed observations (C8)',
        () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-batch-');
      addTearDown(() => _deleteTemp(temp));
      File(p.join(temp.path, 'a.txt')).writeAsStringSync('A');
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {
            'complete': {
              'text': 'mixed batch',
              'tool_calls': [
                {
                  'type': 'tool_call',
                  'name': 'read',
                  'arguments': {'path': 'a.txt'},
                },
                {
                  'type': 'tool_call',
                  'name': 'run_command',
                  'arguments': {'command': _blockingCommand()},
                },
              ],
            }
          },
          {'complete': {'text': 'recovered'}},
        ]
      });
      final agent = PropAgent.assemble(
          config: config,
          provider: provider,
          reliability:
              const Reliability(buildTimeout: Duration(seconds: 1)));
      final result = await agent.run(const RunRequest('mixed'));
      expect(result.status, RunStatus.complete);
      final observations = agent.session.transcript
          .whereType<ObservationEntry>()
          .map((o) => o.text)
          .toList();
      expect(observations.first, 'A');
      expect(observations[1], contains('timed out'));
    });
  });

  group('tool catalog additions (C3)', () {
    late Directory temp;
    late ToolRegistry registry;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('sudoer-tools-');
      registry = ToolRegistry(workspaceRoot: temp.path);
    });

    tearDown(() => temp.deleteSync(recursive: true));

    test('read returns a 0-based line range as text', () async {
      File(p.join(temp.path, 'd.txt')).writeAsStringSync('L0\nL1\nL2\nL3\n');
      final outcome = await registry.dispatch(const ToolCall(
          name: 'read',
          arguments: {'path': 'd.txt', 'offset': 1, 'limit': 2}));
      expect(outcome.outcome, Outcome.ok);
      expect(outcome.text, 'L1\nL2');
    });

    test('edit replace_all rewrites every occurrence', () async {
      final file = File(p.join(temp.path, 'a.txt'))..writeAsStringSync('x x x\n');
      final outcome = await registry.dispatch(const ToolCall(
          name: 'edit',
          arguments: {'path': 'a.txt', 'old': 'x', 'new': 'y', 'replace_all': true}));
      expect(outcome.outcome, Outcome.ok);
      expect(file.readAsStringSync(), 'y y y\n');
    });

    test('an ambiguous edit without replace_all is an error', () async {
      File(p.join(temp.path, 'a.txt')).writeAsStringSync('cat\ncat\n');
      final outcome = await registry.dispatch(const ToolCall(
          name: 'edit', arguments: {'path': 'a.txt', 'old': 'cat', 'new': 'dog'}));
      expect(outcome.outcome, Outcome.error);
      expect(outcome.text, contains('ambiguous'));
    });

    test('multi_edit applies an ordered batch atomically', () async {
      final file = File(p.join(temp.path, 'a.txt'))
        ..writeAsStringSync('foo\nbar\nfoo\n');
      final outcome = await registry.dispatch(const ToolCall(
          name: 'multi_edit',
          arguments: {
            'path': 'a.txt',
            'edits': [
              {'old': 'foo', 'new': 'baz', 'replace_all': true},
              {'old': 'bar', 'new': 'qux'},
            ]
          }));
      expect(outcome.outcome, Outcome.ok);
      expect(file.readAsStringSync(), 'baz\nqux\nbaz\n');
    });

    test('multi_edit writes nothing when a later edit fails', () async {
      final file = File(p.join(temp.path, 'a.txt'))..writeAsStringSync('one\n');
      final outcome = await registry.dispatch(const ToolCall(
          name: 'multi_edit',
          arguments: {
            'path': 'a.txt',
            'edits': [
              {'old': 'one', 'new': 'two'},
              {'old': 'missing', 'new': 'three'},
            ]
          }));
      expect(outcome.outcome, Outcome.error);
      expect(outcome.text, contains('edit 2'));
      expect(file.readAsStringSync(), 'one\n');
    });

    test('glob finds paths by pattern, skipping build trees', () async {
      File(p.join(temp.path, 'README.md')).writeAsStringSync('r');
      Directory(p.join(temp.path, 'src')).createSync();
      File(p.join(temp.path, 'src', 'main.txt')).writeAsStringSync('m');
      Directory(p.join(temp.path, 'node_modules', 'dep'))
          .createSync(recursive: true);
      File(p.join(temp.path, 'node_modules', 'dep', 'x.txt'))
          .writeAsStringSync('x');
      final outcome = await registry.dispatch(const ToolCall(
          name: 'glob', arguments: {'pattern': '**/*.txt'}));
      expect(outcome.outcome, Outcome.ok);
      expect(outcome.text, 'src/main.txt');
    });

    test('glob matching spans directories and single segments', () {
      expect(globMatch('**/*.txt', 'a.txt'), isTrue);
      expect(globMatch('**/*.txt', 'src/deep/a.txt'), isTrue);
      expect(globMatch('src/*.dart', 'src/a.dart'), isTrue);
      expect(globMatch('src/*.dart', 'lib/a.dart'), isFalse);
      expect(globMatch('src/**/*.dart', 'src/a/b.dart'), isTrue);
      expect(globMatch('*.md', 'README.md'), isTrue);
      expect(globMatch('*.md', 'src/README.md'), isFalse);
      expect(globMatch('a?c.txt', 'abc.txt'), isTrue);
      expect(globMatch('a?c.txt', 'ac.txt'), isFalse);
    });
  });

  group('workspace baseline (C3/C5)', () {
    test('diff reports changes and restore reverts them', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-baseline-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = File(p.join(temp.path, 'a.txt'))..writeAsStringSync('orig\n');
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {
            'complete': {
              'tool_calls': [
                {
                  'type': 'tool_call',
                  'name': 'write',
                  'arguments': {'path': 'a.txt', 'content': 'changed\n'},
                }
              ],
            }
          },
          {
            'complete': {
              'tool_calls': [
                {
                  'type': 'tool_call',
                  'name': 'diff',
                  'arguments': {'path': 'a.txt'},
                }
              ],
            }
          },
          {
            'complete': {
              'tool_calls': [
                {
                  'type': 'tool_call',
                  'name': 'restore',
                  'arguments': {'path': 'a.txt'},
                }
              ],
            }
          },
          {'complete': {'text': 'done'}},
        ]
      });
      final agent = PropAgent.assemble(config: config, provider: provider);
      final result = await agent.run(const RunRequest('change, review, undo'));
      expect(result.status, RunStatus.complete);
      final observations = agent.session.transcript
          .whereType<ObservationEntry>()
          .map((o) => o.text)
          .toList();
      expect(observations[0], contains('wrote'));
      expect(observations[1], contains('- orig'));
      expect(observations[1], contains('+ changed'));
      expect(observations[2], contains('restored'));
      expect(file.readAsStringSync(), 'orig\n');
      // The session records the baseline handle (C5) and it persists.
      expect(agent.session.baseline, isNotNull);
      expect(
          File(p.join(config.sessionDir, agent.session.baseline!)).existsSync(),
          isTrue);
      final reloaded = Session.load(config.sessionDir, agent.session.id);
      expect(reloaded.baseline, agent.session.baseline);
    });

    test('restore without a path removes files added since the baseline',
        () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-baseline-');
      addTearDown(() => temp.deleteSync(recursive: true));
      File(p.join(temp.path, 'keep.txt')).writeAsStringSync('keep\n');
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {
            'complete': {
              'tool_calls': [
                {
                  'type': 'tool_call',
                  'name': 'write',
                  'arguments': {'path': 'new.txt', 'content': 'new'},
                }
              ],
            }
          },
          {
            'complete': {
              'tool_calls': [
                {'type': 'tool_call', 'name': 'restore', 'arguments': {}},
              ],
            }
          },
          {'complete': {'text': 'done'}},
        ]
      });
      final agent = PropAgent.assemble(config: config, provider: provider);
      final result = await agent.run(const RunRequest('write then undo'));
      expect(result.status, RunStatus.complete);
      expect(File(p.join(temp.path, 'keep.txt')).existsSync(), isTrue);
      expect(File(p.join(temp.path, 'new.txt')).existsSync(), isFalse);
    });
  });

  group('background jobs (C3/C8)', () {
    test('start, poll, and stop a background command by id', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-job-');
      addTearDown(() => _deleteTemp(temp));
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final command = Platform.isWindows
          ? 'echo job-output & ping -n 30 127.0.0.1 > NUL'
          : 'echo job-output; sleep 30';
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {
            'complete': {
              'tool_calls': [
                {
                  'type': 'tool_call',
                  'name': 'job',
                  'arguments': {
                    'action': 'start',
                    'command': command,
                  },
                }
              ],
            }
          },
          {
            'complete': {
              'tool_calls': [
                {'type': 'tool_call', 'name': 'job', 'arguments': {'action': 'poll', 'id': 'job1'}},
              ],
            }
          },
          {
            'complete': {
              'tool_calls': [
                {'type': 'tool_call', 'name': 'job', 'arguments': {'action': 'stop', 'id': 'job1'}},
              ],
            }
          },
          {'complete': {'text': 'done'}},
        ]
      });
      final agent = PropAgent.assemble(config: config, provider: provider);
      final result = await agent.run(const RunRequest('run a job'));
      expect(result.status, RunStatus.complete);
      final observations = agent.session.transcript
          .whereType<ObservationEntry>()
          .map((o) => o.text)
          .toList();
      // Every stage answers with the job's status line, which always names
      // the id (the poll's output capture is asserted deterministically in
      // the unit test below, free of an output-arrival race).
      expect(observations[0], contains('job1'));
      expect(observations[1], contains('job1'));
      expect(observations[2], contains('job1'));
      await agent.dispose();
    });

    test('a job captures its output between polls and dies on stop', () async {
      final registry = JobRegistry();
      final job = await registry.start(
        Platform.isWindows ? 'echo job-output' : 'echo job-output',
        Directory.systemTemp.createTempSync('sudoer-job-').path,
      );
      await job.outputClosed.timeout(const Duration(seconds: 10));
      expect(job.drainOutput(), contains('job-output'));
      // The job has exited on its own; stop is a no-op that still reports.
      await job.stop();
      expect(job.statusLine(), contains('job1'));
    });

    test('validate rejects a poll without an id', () async {
      final registry = ToolRegistry(
          workspaceRoot: Directory.systemTemp.createTempSync('sudoer-job-').path);
      final outcome = await registry.dispatch(
          const ToolCall(name: 'job', arguments: {'action': 'poll'}));
      expect(outcome.outcome, Outcome.error);
      expect(outcome.text, contains('id'));
    });
  });

  group('sampling config (C2)', () {
    test('parses and validates sampling parameters', () {
      final sampling = SamplingConfig.fromJson({
        'temperature': 0.2,
        'top_p': 0.9,
        'top_k': 40,
        'seed': 7,
        'max_tokens': 1024,
      });
      expect(sampling.openAiJson(), containsPair('max_tokens', 1024));
      expect(sampling.openAiJson(), isNot(contains('top_k')));
      expect(sampling.ollamaJson(), containsPair('num_predict', 1024));
      expect(sampling.ollamaJson(), containsPair('top_k', 40));
      expect(() => SamplingConfig.fromJson({'nope': 1}),
          throwsA(isA<ConfigException>()));
      expect(() => SamplingConfig.fromJson({'temperature': 9}),
          throwsA(isA<ConfigException>()));
    });

    test('the provider config round-trips sampling', () {
      final config = Config.fromJson({
        'provider': {
          'kind': 'ollama',
          'model': 'm',
          'context_window': 100,
          'sampling': {'temperature': 0.3},
        },
      });
      expect(config.provider.sampling?.temperature, 0.3);
      expect(
        (config.provider.toJson()['sampling'] as Map)['temperature'],
        0.3,
      );
    });
  });

  group('/diff command (C6)', () {
    test('prints the workspace changes against the session baseline', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-diffcmd-');
      addTearDown(() => temp.deleteSync(recursive: true));
      File(p.join(temp.path, 'a.txt')).writeAsStringSync('one\n');
      final config = _config(workspaceRoot: temp.path, sessionDir: temp.path);
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {
            'complete': {
              'tool_calls': [
                {
                  'type': 'tool_call',
                  'name': 'edit',
                  'arguments': {'path': 'a.txt', 'old': 'one', 'new': 'two'},
                }
              ],
            }
          },
          {'complete': {'text': 'done'}},
        ]
      });
      final out = StringBuffer();
      final err = StringBuffer();
      final outcome = await runRepl(
        config: config,
        input: Stream.fromIterable(['edit a.txt', '/diff', '/exit']),
        out: out,
        err: err,
        providerFactory: (_) => provider,
      );
      expect(outcome.exitCode, 0);
      // Command output goes to stdout on the automate surface (C6).
      expect(out.toString(), contains('- one'));
      expect(out.toString(), contains('+ two'));
    });
  });

  group('context as a file (C4 CLM)', () {
    test('the context file round-trips every entry kind', () {
      final temp = Directory.systemTemp.createTempSync('sudoer-clm-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final log = ContextLog(File(p.join(temp.path, 'context.md')));
      final entries = <Entry>[
        const UserEntry('goal line\n[[ctx role=note]]\nliteral'),
        AssistantEntry(
          thought: 'thinking',
          action: ToolBatch([
            const ToolCall(
                id: 'c1', name: 'read', arguments: {'path': 'a.txt'}),
            const ToolCall(name: 'glob', arguments: {'pattern': '**/*.dart'}),
          ]),
        ),
        const ObservationEntry(
            text: 'body\nmore', outcome: Outcome.error, toolCallId: 'c1'),
        const ObservationEntry(text: 'my own note', outcome: Outcome.ok),
        const AssistantEntry(thought: 'final answer', action: Finish('final answer')),
      ];
      final back = log.parse(log.render(entries));
      expect(
        [for (final e in back) e.toJson()],
        [for (final e in entries) e.toJson()],
      );
    });

    test('parse rejects garbage and a context without the goal', () {
      final temp = Directory.systemTemp.createTempSync('sudoer-clm-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final log = ContextLog(File(p.join(temp.path, 'context.md')));
      expect(() => log.parse('just some prose\n'), throwsFormatException);
      expect(
        () => log.parse('[[ctx v1]]\n[[ctx role=note]]\nhi\n'),
        throwsFormatException,
      );
    });

    test('normalize fills a missing observation and drops a dangling id', () {
      final entries = <Entry>[
        AssistantEntry(
          thought: 't',
          action: ToolBatch([
            const ToolCall(id: 'c1', name: 'read', arguments: {'path': 'a'}),
          ]),
        ),
        const ObservationEntry(
            text: 'orphan', outcome: Outcome.ok, toolCallId: 'zzz'),
      ];
      final norm = ContextLog.normalize(entries);
      expect(norm.length, 3);
      expect((norm[1] as ObservationEntry).toolCallId, 'c1');
      expect((norm[2] as ObservationEntry).toolCallId, isNull);
      expect((norm[2] as ObservationEntry).text, 'orphan');
    });

    test('render then parse binds a tool call to its observation by id', () {
      final temp = Directory.systemTemp.createTempSync('sudoer-clm-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final log = ContextLog(File(p.join(temp.path, 'context.md')));
      final entries = <Entry>[
        const UserEntry('goal'),
        AssistantEntry(
          thought: 't',
          action: ToolBatch([
            const ToolCall(id: 'c9', name: 'read', arguments: {'path': 'a'}),
          ]),
        ),
        const ObservationEntry(
            text: 'result', outcome: Outcome.ok, toolCallId: 'c9'),
      ];
      final back = ContextLog.normalize(log.parse(log.render(entries)));
      // No placeholder was inserted: the id survived the round-trip.
      expect(back.whereType<ObservationEntry>().length, 1);
      expect((back.last as ObservationEntry).toolCallId, 'c9');
    });

    test('a run in CLM mode adopts a model rewrite of its context file',
        () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-clm-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = Config.fromJson({
        'provider': {'kind': 'ollama', 'model': 'scripted', 'context_window': 8192},
        'workspace_root': temp.path,
        'session_dir': p.join(temp.path, '.sudoer', 'sessions'),
        'context': {'mode': 'clm'},
      });
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {
            'complete': {
              'text': 'rewriting',
              'tool_calls': [
                {
                  'type': 'tool_call',
                  'name': 'write',
                  'arguments': {
                    'path': '.sudoer/context.md',
                    'content':
                        '[[ctx v1]]\n[[ctx role=user]]\nnote it\n'
                            '[[ctx role=note]]\nKEEP-ME\n',
                  },
                }
              ],
            }
          },
          {'complete': {'text': 'done'}},
        ]
      });
      final out = StringBuffer();
      final err = StringBuffer();
      final outcome = await runRepl(
        config: config,
        input: Stream.fromIterable(['note it', '/exit']),
        out: out,
        err: err,
        providerFactory: (_) => provider,
      );
      expect(outcome.exitCode, 0);
      final ctx = File(p.join(temp.path, '.sudoer', 'context.md'));
      expect(ctx.existsSync(), isTrue);
      expect(ctx.readAsStringSync(), contains('KEEP-ME'));
      expect(jsonEncode(outcome.session.toJson()), contains('KEEP-ME'));
    });

    test('CLM sends the context verbatim; the harness ladder clips (C4)', () {
      final big = 'x' * (kObservationCapTokens * 4 + 200);
      final transcript = <Entry>[
        const UserEntry('goal'),
        ObservationEntry(text: big, outcome: Outcome.ok),
      ];
      final clm = ContextAssembler(
          contextWindow: 1000000, modelManagedContext: true);
      final clmPrompt =
          clm.assemble(model: 'm', tools: const [], transcript: transcript);
      expect((clmPrompt.messages[1] as ObservationEntry).text.length,
          big.length);

      final harness = ContextAssembler(contextWindow: 1000000);
      final harnessPrompt =
          harness.assemble(model: 'm', tools: const [], transcript: transcript);
      expect((harnessPrompt.messages[1] as ObservationEntry).text.length,
          lessThan(big.length));
    });

    test('config parses and round-trips the context block', () {
      final config = Config.fromJson({
        'provider': {'kind': 'ollama', 'model': 'm', 'context_window': 100},
        'context': {
          'mode': 'clm',
          'file': 'ctx/live.md',
          'strategy': 'keep it small',
        },
      });
      expect(config.context.mode, ContextMode.clm);
      expect(config.context.file, 'ctx/live.md');
      expect(config.context.strategy, 'keep it small');
      expect(config.toJson()['context'], {
        'mode': 'clm',
        'file': 'ctx/live.md',
        'strategy': 'keep it small',
      });
      expect(
        () => Config.fromJson({
          'provider': {'kind': 'ollama', 'model': 'm', 'context_window': 100},
          'context': {'mode': 'nonsense'},
        }),
        throwsA(isA<ConfigException>()),
      );
    });

    test('/context switches between harness and clm at runtime', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-ctxcmd-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = Config.fromJson({
        'provider': {
          'kind': 'ollama',
          'model': 'scripted',
          'context_window': 8192
        },
        'workspace_root': temp.path,
        'session_dir': p.join(temp.path, '.sudoer', 'sessions'),
      });
      final out = StringBuffer();
      final err = StringBuffer();
      final outcome = await runRepl(
        config: config,
        input: Stream.fromIterable([
          '/context',
          '/context clm',
          '/context',
          '/context harness',
          '/context',
          '/context nonsense',
          '/exit',
        ]),
        out: out,
        err: err,
        providerFactory: (_) =>
            ScriptedProvider.fromJson({'steps': <dynamic>[]}),
      );
      expect(outcome.exitCode, 0);
      // harness -> clm -> harness, so each is reported more than once.
      expect('context: harness'.allMatches(out.toString()).length,
          greaterThanOrEqualTo(2));
      expect('context: clm'.allMatches(out.toString()).length,
          greaterThanOrEqualTo(2));
      expect(err.toString(), contains('usage: /context'));
    });

    test('the default context file lives under the workspace .sudoer', () {
      final config = Config.fromJson({
        'provider': {'kind': 'ollama', 'model': 'm', 'context_window': 100},
        'workspace_root': p.join(Directory.systemTemp.path, 'ws'),
      });
      expect(
        ContextLog.fileFor(config).path,
        p.join(Directory.systemTemp.path, 'ws', '.sudoer', 'context.md'),
      );
    });
  });

  group('provider catalog and credentials (C2)', () {
    test('a preset fills kind, base URL, and context window', () {
      final config = Config.fromJson({
        'provider': {'preset': 'openai', 'model': 'gpt-6-astra'},
      });
      expect(config.provider.kind, ProviderKind.openAiCompatible);
      expect(config.provider.baseUrl, 'https://api.openai.com/v1');
      expect(config.provider.contextWindow, 1050000);
      expect(config.provider.preset, 'openai');
      expect(config.toJson()['provider'], containsPair('preset', 'openai'));
    });

    test('a legacy explicit provider block still parses', () {
      final config = Config.fromJson({
        'provider': {
          'kind': 'openai-compatible',
          'base_url': 'https://example.test/v1',
          'model': 'm',
          'context_window': 4096,
        },
      });
      expect(config.provider.kind, ProviderKind.openAiCompatible);
      expect(config.provider.preset, isNull);
      expect(config.provider.contextWindow, 4096);
    });

    test('invalid provider shapes are rejected', () {
      expect(
        () => Config.fromJson({
          'provider': {'preset': 'nope', 'model': 'm'},
        }),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => Config.fromJson({
          'provider': {'model': 'm', 'context_window': 10},
        }),
        throwsA(isA<ConfigException>()), // kind required
      );
      expect(
        () => Config.fromJson({
          'provider': {'kind': 'ollama', 'model': 'm'},
        }),
        throwsA(isA<ConfigException>()), // window required without a preset
      );
      expect(
        () => Config.fromJson({
          'provider': {
            'preset': 'openai',
            'model': 'm',
            'api_key': 'a',
            'api_key_env': 'B',
          },
        }),
        throwsA(isA<ConfigException>()),
      );
    });

    test('the catalog exposes presets, models, and URL lookups', () {
      final deepseek = providerPreset('deepseek');
      expect(deepseek, isNotNull);
      expect(deepseek!.defaultModel, 'deepseek-v4-pro');
      expect(deepseek.model('deepseek-v4-flash')!.contextWindow, 1000000);
      expect(deepseek.model('does-not-exist'), isNull);
      expect(providerPreset('nope'), isNull);
      expect(presetForBaseUrl('https://api.deepseek.com/')!.id, 'deepseek');

      final minimax = providerPreset('minimax')!;
      final minimaxCn = providerPreset('minimax-cn')!;
      expect(minimax.baseUrl, 'https://api.minimax.io/v1');
      expect(minimaxCn.baseUrl, 'https://api.minimax.cn/v1');
      expect(presetForBaseUrl('https://api.minimax.cn/v1')!.id, 'minimax-cn');
      expect(
        minimaxRegionHint(presetId: minimax.id, baseUrl: minimax.baseUrl),
        contains('minimax-cn'),
      );
      expect(
        minimaxRegionHint(presetId: minimaxCn.id, baseUrl: minimaxCn.baseUrl),
        contains('minimax preset'),
      );
      expect(minimaxRegionHint(presetId: 'openai'), isEmpty);

      // The generated catalog carries the full OpenAI-compatible
      // models.dev/OpenCode provider set, not just the curated core.
      expect(kProviderPresets.length, greaterThan(150));
      final ids = [for (final preset in kProviderPresets) preset.id];
      expect(ids.toSet().length, ids.length);
      expect(providerPreset('nvidia'), isNotNull);
      expect(providerPreset('opencode')!.baseUrl, contains('opencode.ai'));
      expect(providerPreset('zai-coding-plan'), isNotNull);
      expect(providerPreset('minimax-cn-coding-plan'), isNotNull);
      expect(providerPreset('fireworks')!.id, 'fireworks-ai');
      expect(providerPreset('togetherai')!.baseUrl, 'https://api.together.xyz/v1');
      for (final preset in kProviderPresets) {
        if (preset.baseUrl != null) {
          expect(preset.baseUrl, isNot(contains(r'${')), reason: preset.id);
        }
        if (preset.id != 'custom') {
          expect(preset.models, isNotEmpty, reason: preset.id);
        }
      }
    });

    test('the auth store round-trips keys and restricts the file', () {
      final temp = Directory.systemTemp.createTempSync('sudoer-auth-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final path = p.join(temp.path, 'auth.json');
      final store = AuthStore(path: path);
      expect(store.keyFor('openai'), isNull);
      store.setKey('openai', 'sk-test');
      expect(store.keyFor('openai'), 'sk-test');
      final raw = File(path).readAsStringSync();
      expect(raw, contains('"type": "api"'));
      expect(raw, contains('sk-test'));
      if (!Platform.isWindows) {
        expect(File(path).statSync().mode & 0x1FF, 0x180); // 0600
      }
      store.remove('openai');
      expect(store.keyFor('openai'), isNull);
    });

    test('key precedence is config > store > api_key_env > preset env', () {
      final temp = Directory.systemTemp.createTempSync('sudoer-auth-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final store = AuthStore(path: p.join(temp.path, 'auth.json'));
      final direct = ProviderConfig.fromJson({
        'preset': 'openai',
        'model': 'gpt-6-astra',
        'api_key': 'direct',
      });
      expect(
        resolveApiKey(direct, store: store, env: (_) => 'env'),
        'direct',
      );
      store.setKey('openai', 'stored');
      final envRef = ProviderConfig.fromJson({
        'preset': 'openai',
        'model': 'gpt-6-astra',
        'api_key_env': 'MY_KEY',
      });
      expect(resolveApiKey(envRef, store: store, env: (_) => 'env'), 'stored');
      store.remove('openai');
      expect(
        resolveApiKey(
          envRef,
          store: store,
          env: (name) => name == 'MY_KEY' ? 'my-key' : 'openai-env',
        ),
        'my-key',
      );
      expect(
        resolveApiKey(
          ProviderConfig.fromJson(
              {'preset': 'openai', 'model': 'gpt-6-astra'}),
          store: store,
          env: (name) => name == 'OPENAI_API_KEY' ? 'openai-env' : null,
        ),
        'openai-env',
      );
    });

    test('the missing-key hint names the env var and never the key', () {
      final temp = Directory.systemTemp.createTempSync('sudoer-auth-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final store = AuthStore(path: p.join(temp.path, 'auth.json'));
      final openai = ProviderConfig.fromJson(
          {'preset': 'openai', 'model': 'gpt-6-astra'});
      final hint = missingKeyHint(openai, store: store, env: (_) => null);
      expect(hint, contains('OPENAI_API_KEY'));
      expect(hint, contains('--setup'));
      expect(hint, isNot(contains('sk-')));
      store.setKey('openai', 'sk-hidden');
      expect(missingKeyHint(openai, store: store, env: (_) => null), isNull);
      final ollama = ProviderConfig.fromJson(
          {'preset': 'ollama', 'model': 'llama3.1:8b'});
      expect(missingKeyHint(ollama, store: store, env: (_) => null), isNull);
    });

    test('API keys are printable ASCII without whitespace', () {
      expect(apiKeyProblem('sk-test_123.abc'), isNull);
      expect(apiKeyProblem('  sk-test\n'), isNull);
      expect(apiKeyProblem(''), contains('empty'));
      expect(apiKeyProblem('   '), contains('empty'));
      expect(apiKeyProblem('sk test'), contains('whitespace'));
      expect(apiKeyProblem('sk-test\nmore'), contains('whitespace'));
      expect(apiKeyProblem('┃ pasted transcript'), contains('non-ASCII'));
      expect(apiKeyProblem('a'.padRight(4097, 'a')), contains('too long'));
    });

    test('an invalid stored key is reported, never sent or echoed', () {
      final temp = Directory.systemTemp.createTempSync('sudoer-auth-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final store = AuthStore(path: p.join(temp.path, 'auth.json'));
      final openai = ProviderConfig.fromJson(
          {'preset': 'openai', 'model': 'gpt-6-astra'});
      store.setKey('openai', 'Bearer ┃ pasted transcript');
      final hint = missingKeyHint(openai, store: store, env: (_) => null);
      expect(hint, contains('invalid'));
      expect(hint, contains('--setup'));
      expect(hint, isNot(contains('pasted transcript')));
      expect(hint, isNot(contains('Bearer')));
      final listed =
          providerListText(current: openai, store: store, env: (_) => null);
      expect(listed, contains('invalid'));
      expect(listed, isNot(contains('pasted transcript')));
    });

    test('resolveApiKey trims surrounding whitespace and ignores blanks', () {
      final temp = Directory.systemTemp.createTempSync('sudoer-auth-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final store = AuthStore(path: p.join(temp.path, 'auth.json'));
      final config = ProviderConfig.fromJson({
        'preset': 'openai',
        'model': 'gpt-6-astra',
        'api_key': '  sk-padded \n',
      });
      expect(resolveApiKey(config, store: store, env: (_) => null), 'sk-padded');
      final blank = ProviderConfig.fromJson({
        'preset': 'openai',
        'model': 'gpt-6-astra',
        'api_key': '   ',
      });
      expect(
        resolveApiKey(blank, store: store, env: (_) => null),
        isNull,
      );
    });

    test('model discovery parses both wire shapes and merges the catalog', () {
      expect(parseOpenAiModels('{"data":[{"id":"a"},{"id":"b"}]}'), ['a', 'b']);
      expect(parseOllamaModels('{"models":[{"name":"x:1"},{"model":"y"}]}'),
          ['x:1', 'y']);
      const preset = ProviderPreset(
        id: 'test',
        name: 'Test',
        kind: ProviderKind.openAiCompatible,
        baseUrl: 'https://example.test/v1',
        models: [ModelInfo('a', 'A', 1000)],
      );
      final merged = mergeModels(['b', 'a'], preset);
      expect(merged.map((m) => m.id), ['a', 'b']);
      expect(merged.first.contextWindow, 1000);
      expect(merged.last.contextWindow, kDefaultContextWindow);
      expect(mergeModels(const [], preset).map((m) => m.id), ['a']);
    });

    test('discovery sends the bearer key and merges the live list', () async {
      const preset = ProviderPreset(
        id: 'test',
        name: 'Test',
        kind: ProviderKind.openAiCompatible,
        baseUrl: 'https://example.test/v1',
        models: [ModelInfo('a', 'A', 1000)],
      );
      final client = MockClient((request) async {
        expect(request.url.toString(), 'https://example.test/v1/models');
        expect(request.headers['authorization'], 'Bearer sk-test');
        return http.Response('{"data":[{"id":"a"},{"id":"new"}]}', 200);
      });
      final models =
          await discoverModels(preset, apiKey: 'sk-test', client: client);
      expect(models.map((m) => m.id), ['a', 'new']);
      expect(models.first.contextWindow, 1000);
      expect(models.last.contextWindow, kDefaultContextWindow);

      final rejected = MockClient((_) async => http.Response('nope', 401));
      expect(
        () => discoverModels(preset, apiKey: 'sk-test', client: rejected),
        throwsA(isA<HttpException>()),
      );
    });

    test('bracketed paste becomes a printable key for text inputs', () {
      final pasted = pasteAsRunes(PasteMsg('sk-test\r\n'));
      expect(pasted, isA<KeyPressMsg>());
      final key = (pasted as KeyPressMsg).keyEvent;
      expect(key.code, KeyCode.rune);
      expect(key.text, 'sk-test');
      expect(pasteAsRunes(PasteStartMsg()), isNull);
      expect(pasteAsRunes(PasteEndMsg()), isNull);
      expect(pasteAsRunes(PasteMsg('\r\n')), isNull);

      // This is exactly the path a Form's TextInputModel takes for a typed
      // rune, so a paste inserts at the cursor.
      final input = TextInputModel(value: 'sk-', cursorPos: 3);
      final (next, _) = input.update(pasted);
      expect((next as TextInputModel).value, 'sk-sk-test');
      expect(next.cursorPos, 10);

      // The wizard's secret field is the first field in its form, so the
      // synthetic key reaches it directly (no note field to swallow it).
      final form = Form([
        Group([
          Field.password(key: 'key', title: 'API key'),
        ]),
      ]);
      final (formNext, _) = form.update(pasted);
      expect((formNext as Form).values.get<String>('key'), 'sk-test');
    });

    test('configWithProvider switches presets and honors overrides', () {
      final base = Config.fromJson({
        'provider': {'preset': 'openai', 'model': 'gpt-6-astra'},
      });
      final next = configWithProvider(base, presetId: 'deepseek');
      expect(next.provider.preset, 'deepseek');
      expect(next.provider.model, 'deepseek-v4-pro');
      expect(next.provider.baseUrl, 'https://api.deepseek.com');
      expect(next.provider.contextWindow, 1000000);
      final over = configWithProvider(
        base,
        presetId: 'deepseek',
        model: 'deepseek-v4-flash',
        contextWindow: 5000,
        apiKey: 'sk-override',
        replaceKey: true,
      );
      expect(over.provider.model, 'deepseek-v4-flash');
      expect(over.provider.contextWindow, 5000);
      expect(over.provider.apiKey, 'sk-override');
      final fresh = configWithProvider(null, presetId: 'ollama');
      expect(fresh.provider.preset, 'ollama');
      expect(fresh.provider.kind, ProviderKind.ollama);

      // No --provider: an explicit legacy provider is preserved untouched.
      final legacy = Config.fromJson({
        'provider': {
          'kind': 'openai-compatible',
          'base_url': 'https://example.test/v1',
          'model': 'm',
          'context_window': 4096,
        },
      });
      final preserved = configWithProvider(legacy);
      expect(preserved.provider.kind, ProviderKind.openAiCompatible);
      expect(preserved.provider.baseUrl, 'https://example.test/v1');
      expect(preserved.provider.model, 'm');
      expect(preserved.provider.contextWindow, 4096);
    });

    test('list text marks the current provider/model and hides keys', () {
      final temp = Directory.systemTemp.createTempSync('sudoer-auth-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final store = AuthStore(path: p.join(temp.path, 'auth.json'));
      store.setKey('openai', 'sk-never-print');
      final current = ProviderConfig.fromJson(
          {'preset': 'openai', 'model': 'gpt-6-astra'});
      final providers =
          providerListText(current: current, store: store, env: (_) => null);
      expect(providers, contains('* openai'));
      expect(providers, contains('stored'));
      expect(providers, isNot(contains('sk-never-print')));
      final models = modelListText(providerPreset('deepseek')!,
          current: 'deepseek-v4-pro');
      expect(models, contains('* deepseek-v4-pro'));
    });

    test('writeConfigFile round-trips through loadConfigFile', () {
      final temp = Directory.systemTemp.createTempSync('sudoer-cfg-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final base = Config.fromJson({
        'provider': {'preset': 'openai', 'model': 'gpt-6-astra'},
        'workspace_root': temp.path,
      });
      final next = configWithProvider(base, presetId: 'deepseek');
      final path = p.join(temp.path, 'sudoer.json');
      writeConfigFile(path, next);
      final loaded = loadConfigFile(path);
      expect(loaded.provider.preset, 'deepseek');
      expect(loaded.provider.model, 'deepseek-v4-pro');
      expect(loaded.workspaceRoot, p.normalize(p.absolute(temp.path)));
    });

    test('the setup wizard writes config plus key without echoing it',
        () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-setup-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final store = AuthStore(path: p.join(temp.path, 'auth.json'));
      final configPath = p.join(temp.path, 'sudoer.json');
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await runProviderSetup(
        configPath: configPath,
        presetId: 'deepseek',
        model: 'deepseek-v4-flash',
        auth: store,
        env: (_) => null,
        out: out,
        err: err,
        select: (choices, {required title}) async => choices.first,
        input: (label) async => null,
        secret: (title, {bool optional = false}) async => 'sk-test',
        confirm: (question) async => false,
      );
      expect(code, 0, reason: err.toString());
      expect(store.keyFor('deepseek'), 'sk-test');
      final loaded = loadConfigFile(configPath);
      expect(loaded.provider.preset, 'deepseek');
      expect(loaded.provider.model, 'deepseek-v4-flash');
      expect(loaded.provider.apiKey, isNull);
      expect(loaded.provider.apiKeyEnv, isNull);
      expect(out.toString(), contains('stored in'));
      expect(out.toString(), isNot(contains('sk-test')));
    });

    test('the setup wizard accepts an exact model query on a long list',
        () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-setup-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final store = AuthStore(path: p.join(temp.path, 'auth.json'));
      final configPath = p.join(temp.path, 'sudoer.json');
      final out = StringBuffer();
      final err = StringBuffer();
      final models = <ModelInfo>[
        for (var i = 0; i < 15; i++)
          ModelInfo('model-$i', 'Model $i', 100000 + i),
        const ModelInfo('gpt-6-astra', 'GPT-6 Astra', 1050000),
      ];
      final inputs = <String>['gpt-6-astra'];
      final code = await runProviderSetup(
        configPath: configPath,
        presetId: 'openai',
        auth: store,
        env: (_) => null,
        out: out,
        err: err,
        discover: (preset, apiKey) async => models,
        select: (choices, {required title}) async => choices.first,
        input: (label) async => inputs.isEmpty ? null : inputs.removeAt(0),
        secret: (title, {bool optional = false}) async => 'sk-test',
        confirm: (question) async => false,
      );
      expect(code, 0, reason: err.toString());
      final loaded = loadConfigFile(configPath);
      expect(loaded.provider.model, 'gpt-6-astra');
      expect(loaded.provider.contextWindow, 1050000);
      expect(out.toString(), contains('stored in'));
      expect(out.toString(), isNot(contains('sk-test')));
    });

    test('the setup wizard rejects an invalid key before writing', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-setup-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final store = AuthStore(path: p.join(temp.path, 'auth.json'));
      final configPath = p.join(temp.path, 'sudoer.json');
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await runProviderSetup(
        configPath: configPath,
        presetId: 'openai',
        apiKey: 'pasted ┃ transcript',
        auth: store,
        env: (_) => null,
        out: out,
        err: err,
        select: (choices, {required title}) async => fail('no prompt'),
        input: (label) async => fail('no prompt'),
        secret: (title, {bool optional = false}) async => fail('no prompt'),
        confirm: (question) async => fail('no prompt'),
      );
      expect(code, 1);
      expect(err.toString(), contains('invalid API key'));
      expect(err.toString(), isNot(contains('pasted transcript')));
      expect(File(configPath).existsSync(), isFalse);
    });

    test('/provider lists and switches; /model switches model', () async {
      final temp = Directory.systemTemp.createTempSync('sudoer-cmd-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final config = Config.fromJson({
        'provider': {
          'preset': 'ollama',
          'model': 'scripted',
          'context_window': 8192,
        },
        'workspace_root': temp.path,
        'session_dir': p.join(temp.path, '.sudoer', 'sessions'),
      });
      final provider = ScriptedProvider.fromJson({
        'steps': [
          {'complete': {'text': 'hi'}},
        ]
      });
      final out = StringBuffer();
      final err = StringBuffer();
      final outcome = await runRepl(
        config: config,
        input: Stream.fromIterable([
          '/provider',
          '/model',
          '/model qwen2.5-coder:7b',
          '/provider openai',
          'hi',
          '/exit',
        ]),
        out: out,
        err: err,
        providerFactory: (_) => provider,
      );
      expect(outcome.exitCode, 0, reason: err.toString());
      expect(out.toString(), contains('ollama'));
      expect(out.toString(), contains('qwen2.5-coder:7b'));
      expect(out.toString(), contains('provider: openai'));
      expect(out.toString(), contains('model: qwen2.5-coder:7b'));
      expect(outcome.runs.length, 1);
    });
  });
}

/// A no-op stylize for markdown tests, so assertions can ignore ANSI.
String _plainStyle(
  String text, {
  bool bold = false,
  bool dim = false,
  bool italic = false,
  bool reverse = false,
  RgbColor? fg,
}) =>
    text;

/// A streamed HTTP client for adapter tests: each string is emitted as one
/// chunk, so partial SSE/NDJSON frames span chunk boundaries.
final class _StreamClient extends http.BaseClient {
  _StreamClient(this.chunks);
  final List<String> chunks;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        Stream.fromIterable(chunks.map(utf8.encode)),
        200,
      );
}

/// A provider that blocks until its call is cancelled, so a test can drive the
/// cancel signal and observe the loop ending at once (C8).
final class _BlockingProvider implements Provider {
  final Completer<void> started = Completer<void>();

  @override
  Future<ProviderResponse> complete(
    ProviderRequest request, {
    void Function(String delta)? onDelta,
    void Function(String delta)? onReasoning,
    CancelSignal? cancel,
  }) async {
    if (!started.isCompleted) started.complete();
    await cancel!.whenCancelled;
    throw const StepFailure.cancelled('cancelled by user');
  }
}

/// A client whose response stream opens but never emits, so a cancel must cut
/// the call off (C8).
final class _HangingClient extends http.BaseClient {
  final _controller = StreamController<List<int>>();

  Future<void> dispose() => _controller.close();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(_controller.stream, 200);
}
