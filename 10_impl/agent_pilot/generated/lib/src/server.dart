import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import 'autonomy.dart';
import 'cancellation.dart';
import 'config.dart';
import 'dart:math';
import 'pilot_agent.dart';
import 'models.dart';
import 'channels_inbound.dart' show handleInbound;
import 'pilot_commands.dart';
import 'pilot_config.dart';
import 'pilot_runtime.dart';
import 'scheduler.dart';
import 'session.dart';
import 'sessions_index.dart';


/// C6: the Pilot REST server — the spine. One single-owner process hosts
/// the built-in web page and every endpoint the messenger adapters and
/// scripts use (`http-api.schema.json`): sessions (list/search/new/info),
/// one streamed run per session (SSE `delta`/`tool`/`result`), cancel,
/// channels (list/register/remove, inbound messages), scheduled tasks,
/// non-secret config get/update, secret names, and service status. One
/// bearer token (or the web session cookie) gates it; a busy session is
/// 409, unauthorized 401, disallowed sender 403, unknown channel 404.
final class PilotServer {
  PilotServer(this.runtime);

  final PilotRuntime runtime;

  HttpServer? _server;
  final _busy = <String>{};
  final _cancelSignals = <String, CancelSignal>{};

  PilotConfig get config => runtime.config;
  Autonomy get _autonomy => _autonomyFor();

  Autonomy _autonomyFor() => Autonomy(runtime: runtime, runGoal: _runGoal);

  Future<String?> _runGoal(GoalRun run) async {
    final agent = PilotAgent.assemble(
      runtime: runtime,
      session: run.session ??
          Session.create(workspaceRoot: config.primaryRoot),
      chain: gateChain(),
      reliability: gateReliability(),
    );
    try {
      final result = await agent.run(RunRequest(run.goal), system: run.system);
      return result.answer;
    } finally {
      await agent.dispose();
    }
  }

  /// Boot and serve until SIGTERM; exit 0 on a clean shutdown (C8).
  Future<int> run({bool verbose = false}) async {
    final token = config.httpToken ?? _generateToken();
    final server = await HttpServer.bind(config.httpBind, config.httpPort);
    _server = server;
    final port = server.port;
    runtime.log.emitService('start', nextDue: _autonomy.nextDue());
    stderr.writeln('sudoer-pilot serve on http://${config.httpBind}:$port');
    if (config.httpToken == null) {
      // Generated once, printed once (C6).
      stderr.writeln('token: $token');
    }
    // C11: the service reloads the task store, re-arms the next wake, and
    // resumes unfinished background runs on start (C8).
    await _autonomy.tick();
    final next = _autonomy.nextDue();
    if (next != null) {
      runtime.scheduler.installWake(next, Directory.current.path);
    }
    final report = _autonomy.reportMissed();
    if (report.isNotEmpty) stderr.write(report);

    final done = Completer<int>();
    ProcessSignal.sigterm.watch().listen((_) {
      done.complete(_shutdown());
    });
    runZonedGuarded(() {
      server.listen((request) async {
        try {
          await _handle(request, token);
        } on Object catch (e) {
          _json(request, HttpStatus.internalServerError, {'error': '$e'});
        }
      });
    }, (e, st) {
      stderr.writeln('serve error: $e');
    });
    return done.future;
  }

  Future<int> _shutdown() async {
    runtime.log.emitService('stop');
    final server = _server;
    if (server != null) await server.close(force: false);
    return 0;
  }

  String _generateToken() {
    final random = Random.secure();
    return base64Url.encode(List<int>.generate(24, (_) => random.nextInt(256)));
  }

  // ---- routing ----

  Future<void> _handle(HttpRequest request, String token) async {
    final path = request.uri.path;
    final method = request.method;

    // The login page and the static web page are the only unauthenticated
    // surfaces (C10); everything else requires the bearer token or cookie.
    if (path == '/' && method == 'GET') {
      _html(request, _webPage());
      return;
    }
    if (path == '/login' && method == 'POST') {
      final body = await _body(request);
      if (body['token'] == token) {
        final cookie = _sessionCookie(token);
        request.response.cookies.add(Cookie('sudoer_session', cookie)
          ..httpOnly = true
          ..sameSite = SameSite.lax
          ..path = '/');
        _json(request, HttpStatus.ok, {'ok': true});
        runtime.decisions.add('config_changed', 'login', detail: 'session');
        return;
      }
      runtime.decisions.add('auth_failed', 'login');
      _json(request, HttpStatus.unauthorized, {'error': 'invalid token'});
      return;
    }

    if (!_authorized(request, token)) {
      runtime.decisions.add('auth_failed', 'http');
      _json(request, HttpStatus.unauthorized, {'error': 'unauthorized'});
      return;
    }

    // Sessions.
    if (path == '/sessions' && method == 'GET') {
      _json(request, HttpStatus.ok,
          {'sessions': runtime.sessions.search(request.uri.queryParameters['q'])});
      return;
    }
    if (path == '/sessions' && method == 'POST') {
      final body = await _body(request);
      final root = (body['workspace_root'] as String?) ?? config.primaryRoot;
      final channel = body['channel'] as String?;
      final session = Session.create(workspaceRoot: root, channel: channel);
      session.save(config.sessionDir);
      runtime.sessions.upsert(
        id: session.id,
        title: sessionTitle(session.id),
        workspaceRoot: session.workspaceRoot,
        channel: session.channel,
        created: session.createdAt,
        updated: session.updatedAt,
        runs: 0,
      );
      _json(request, HttpStatus.ok, {
        'id': session.id,
        'title': sessionTitle(session.id),
        'workspace_root': session.workspaceRoot,
        'channel': ?channel,
        'updated': session.updatedAt.toIso8601String(),
      });
      return;
    }
    final sessionMatch = RegExp(r'^/sessions/([^/]+)$').firstMatch(path);
    if (sessionMatch != null && method == 'GET') {
      final id = sessionMatch.group(1)!;
      final record = runtime.sessions.byId(id);
      if (record == null) {
        _json(request, HttpStatus.notFound, {'error': 'no such session'});
        return;
      }
      _json(request, HttpStatus.ok, record);
      return;
    }
    final runMatch = RegExp(r'^/sessions/([^/]+)/runs$').firstMatch(path);
    if (runMatch != null && method == 'POST') {
      await _run(request, runMatch.group(1)!);
      return;
    }
    final cancelMatch = RegExp(r'^/sessions/([^/]+)/cancel$').firstMatch(path);
    if (cancelMatch != null && method == 'POST') {
      final signal = _cancelSignals[cancelMatch.group(1)!];
      signal?.cancel();
      _json(request, HttpStatus.accepted, {'ok': true});
      return;
    }

    // Channels.
    if (path == '/channels' && method == 'GET') {
      _json(request, HttpStatus.ok, {
        'channels': [for (final channel in config.channels) channel.toJson()],
      });
      return;
    }
    if (path == '/channels' && method == 'POST') {
      final body = await _body(request);
      final channel = ChannelConfig.fromJson(body.cast<String, dynamic>());
      config.channels.add(channel);
      _json(request, HttpStatus.ok, channel.toJson());
      return;
    }
    final channelMessage =
        RegExp(r'^/channels/([^/]+)/messages$').firstMatch(path);
    if (channelMessage != null && method == 'POST') {
      await _inbound(request, channelMessage.group(1)!);
      return;
    }
    final channelRemove = RegExp(r'^/channels/([^/]+)$').firstMatch(path);
    if (channelRemove != null && method == 'DELETE') {
      final id = channelRemove.group(1)!;
      config.channels.removeWhere((channel) => channel.id == id);
      _json(request, HttpStatus.ok, {'ok': true});
      return;
    }

    // Scheduled tasks.
    if (path == '/tasks' && method == 'GET') {
      final store = TaskStore(config.tasksFile, runtime.clock);
      _json(request, HttpStatus.ok, {
        'tasks': [
          for (final task in store.load())
            {
              'id': task.id,
              'goal': task.goal,
              'status': task.status,
              'repeat': task.repeat,
              'channel': task.channel,
              'next_due': task.nextDue?.toIso8601String(),
              'last_run': task.lastRun?.toIso8601String(),
            },
        ],
      });
      return;
    }
    if (path == '/tasks' && method == 'POST') {
      final body = await _body(request);
      final when = body['when'] as String?;
      final goal = body['goal'] as String?;
      if (when == null || goal == null) {
        _json(request, HttpStatus.badRequest,
            {'error': 'when and goal are required'});
        return;
      }
      final clock = runtime.clock;
      final due = resolveWhen(when, clock.now());
      if (due == null) {
        _json(request, HttpStatus.badRequest, {'error': 'cannot resolve when'});
        return;
      }
      final store = TaskStore(config.tasksFile, clock);
      final tasks = store.load();
      final task = ScheduledTask(
        id: 'task-${tasks.length + 1}',
        goal: goal,
        when: when,
        nextDue: due,
        repeat: body['repeat'] as String?,
        channel: body['channel'] as String?,
        status: 'pending',
        created: clock.now(),
        updated: clock.now(),
      );
      tasks.add(task);
      store.save(tasks);
      runtime.log.emitTask(task.id, 'scheduled', due: due, repeat: task.repeat);
      _json(request, HttpStatus.ok, {'id': task.id});
      return;
    }
    final taskCancel = RegExp(r'^/tasks/([^/]+)/cancel$').firstMatch(path);
    if (taskCancel != null && method == 'POST') {
      final ok = _autonomy.cancel(taskCancel.group(1)!);
      _json(request, ok ? HttpStatus.ok : HttpStatus.notFound,
          ok ? {'ok': true} : {'error': 'no pending task'});
      return;
    }

    // Config, secrets, status.
    if (path == '/config' && method == 'GET') {
      _json(request, HttpStatus.ok, config.view());
      return;
    }
    if (path == '/config' && method == 'PUT') {
      final body = await _body(request);
      _putConfig(request, body);
      return;
    }
    if (path == '/secrets' && method == 'GET') {
      _json(request, HttpStatus.ok, {'names': runtime.secrets.names});
      return;
    }
    if (path == '/status' && method == 'GET') {
      final store = TaskStore(config.tasksFile, runtime.clock);
      final pending =
          store.load().where((task) => task.status == 'pending').length;
      _json(request, HttpStatus.ok, {
        'running': true,
        'tasks_pending': pending,
        'next_due': _autonomy.nextDue()?.toIso8601String(),
        'wake_installed': true,
        'channels': config.channels.length,
      });
      return;
    }

    _json(request, HttpStatus.notFound, {'error': 'not found'});
  }

  // ---- handlers ----

  /// One streamed run per session (C6): SSE `delta`/`tool` events, then
  /// exactly one `result`. A run POSTed to a busy session is 409 (C5/C8:
  /// runs within one session serialize by rejection).
  Future<void> _run(HttpRequest request, String id) async {
    if (_busy.contains(id)) {
      _json(request, HttpStatus.conflict,
          {'error': 'session is busy; runs within a session serialize'});
      return;
    }
    final record = runtime.sessions.byId(id);
    if (record == null) {
      _json(request, HttpStatus.notFound, {'error': 'no such session'});
      return;
    }
    final body = await _body(request);
    final goal = body['goal'] as String?;
    if (goal == null || goal.isEmpty) {
      _json(request, HttpStatus.badRequest, {'error': 'goal is required'});
      return;
    }
    _busy.add(id);
    final response = request.response;
    response.headers.set('content-type', 'text/event-stream');
    response.headers.set('cache-control', 'no-cache');
    response.bufferOutput = false;

    Session? session;
    try {
      session = Session.load(config.sessionDir, id);
    } on Object {
      _json(request, HttpStatus.notFound, {'error': 'no such session'});
      _busy.remove(id);
      return;
    }
    final signal = CancelSignal();
    _cancelSignals[id] = signal;
    session.cancel = signal;
    final agent = PilotAgent.assemble(
      runtime: runtime,
      session: session,
      chain: gateChain(),
      reliability: gateReliability(),
    );
    final observer = _SseObserver(
      onEvent: (event, data) {
        response.write('event: $event\ndata: ${jsonEncode(data)}\n\n');
      },
    );
    try {
      final result = await agent.run(RunRequest(goal), observer: observer);
      response.write('event: result\ndata: ${jsonEncode({
            'status': result.status.wire,
            if (result.answer != null) 'answer': result.answer,
          })}\n\n');
      await response.flush();
      await response.close();
    } on Object catch (e) {
      response.write('event: result\ndata: ${jsonEncode({
            'status': 'blocked',
            'answer': 'server error: $e',
          })}\n\n');
      await response.close();
    } finally {
      _busy.remove(id);
      _cancelSignals.remove(id);
      await agent.dispose();
    }
  }

  /// Inbound channel message (C6/C10) through the shared handler.
  Future<void> _inbound(HttpRequest request, String channelId) async {
    final body = await _body(request);
    final from = body['from'] as String?;
    final text = body['text'] as String?;
    if (from == null || text == null) {
      _json(request, HttpStatus.badRequest,
          {'error': 'from and text are required'});
      return;
    }
    final outcome = await handleInbound(runtime, channelId, from, text,
        chain: gateChain(), reliability: gateReliability());
    if (!outcome.allowed) {
      _json(request,
          outcome.reason == 'unknown channel' ? HttpStatus.notFound : HttpStatus.forbidden,
          {'error': outcome.reason});
      return;
    }
    _json(request, HttpStatus.ok, {
      'session': outcome.sessionId,
      if (channelId == 'web') 'answer': outcome.answer,
    });
  }

  /// `PUT /config`: a partial non-secret patch, merged and validated before
  /// it takes effect (C6/C10). A patch touching a secret value is rejected.
  void _putConfig(HttpRequest request, Map<String, dynamic> body) {
    const secretKeys = {'secrets_file', 'api_key'};
    String? offending;
    void scan(Map<String, dynamic> patch) {
      for (final entry in patch.entries) {
        if (secretKeys.contains(entry.key)) {
          offending ??= entry.key;
        } else if (entry.value is Map) {
          scan((entry.value as Map).cast<String, dynamic>());
        }
      }
    }

    scan(body);
    if (offending != null) {
      runtime.log.emitConfigChanged([offending!]);
      runtime.decisions.add('config_changed', 'config',
          detail: 'rejected $offending');
      _json(request, HttpStatus.badRequest, {
        'ok': false,
        'error': 'secret',
        'detail': '$offending cannot be set over HTTP (C10)',
      });
      return;
    }
    try {
      final merged = Config.mergeJson(config.view(), body);
      final updated = PilotConfig.fromJson(merged,
          defaultRoot: config.primaryRoot);
      runtime.config = updated;
      runtime.log.emitConfigChanged([...body.keys]);
      runtime.decisions.add('config_changed', 'config',
          detail: body.keys.join(','));
      _json(request, HttpStatus.ok, {'ok': true});
    } on Object catch (e) {
      _json(request, HttpStatus.badRequest, {'error': 'invalid config: $e'});
    }
  }

  // ---- plumbing ----

  bool _authorized(HttpRequest request, String token) {
    final header = request.headers.value('authorization');
    if (header == 'Bearer $token') return true;
    final cookies = request.cookies;
    for (final cookie in cookies) {
      if (cookie.name == 'sudoer_session' &&
          cookie.value == _sessionCookie(token)) {
        return true;
      }
    }
    return false;
  }

  /// The signed web session cookie: HMAC(token, 'sudoer-session') — the
  /// token itself never rides the cookie (C10).
  String _sessionCookie(String token) =>
      crypto.sha256.convert(utf8.encode('sudoer-session:$token')).toString();

  Future<Map<String, dynamic>> _body(HttpRequest request) async {
    final text = await utf8.decoder.bind(request).join();
    if (text.isEmpty) return {};
    final decoded = jsonDecode(text);
    return decoded is Map ? decoded.cast<String, dynamic>() : {};
  }

  void _json(HttpRequest request, int status, Object? body) {
    request.response.statusCode = status;
    request.response.headers.set('content-type', 'application/json');
    request.response.write(jsonEncode(body));
    request.response.close();
  }

  void _html(HttpRequest request, String body) {
    request.response.headers.set('content-type', 'text/html; charset=utf-8');
    request.response.write(body);
    request.response.close();
  }

  /// The built-in web page (C6): a client of the REST API — login, chat,
  /// config, status — basic server-rendered HTML.
  String _webPage() => '''<!doctype html>
<html>
<head><meta charset="utf-8"><title>sudoer-pilot</title></head>
<body>
<h1>Sudoer Pilot</h1>
<section id="login">
  <h2>Sign in</h2>
  <input id="token" type="password" placeholder="token"/>
  <button onclick="login()">Sign in</button>
</section>
<section id="chat" hidden>
  <h2>Chat</h2>
  <div id="log"></div>
  <input id="goal" placeholder="Ask anything"/>
  <button onclick="chat()">Send</button>
</section>
<section id="status" hidden><h2>Status</h2><pre id="statusBody"></pre></section>
<script>
async function login() {
  const token = document.getElementById('token').value;
  const r = await fetch('/login', {method: 'POST',
      headers: {'content-type': 'application/json'},
      body: JSON.stringify({token})});
  if (r.ok) {
    document.getElementById('login').hidden = true;
    document.getElementById('chat').hidden = false;
    document.getElementById('status').hidden = false;
  }
}
async function chat() {
  const goal = document.getElementById('goal').value;
  const r = await fetch('/sessions', {method: 'POST',
      headers: {'content-type': 'application/json'},
      body: JSON.stringify({channel: 'web'})});
  const {id} = await r.json();
  const run = await fetch('/sessions/' + id + '/runs', {method: 'POST',
      headers: {'content-type': 'application/json'},
      body: JSON.stringify({goal})});
  const reader = run.body.getReader();
  const decoder = new TextDecoder();
  let text = '';
  for (;;) {
    const {done, value} = await reader.read();
    if (done) break;
    text += decoder.decode(value, {stream: true});
  }
  const result = text.split('\\n').filter(l => l.startsWith('data: ')).pop();
  document.getElementById('log').textContent +=
      (result ? JSON.parse(result.slice(6)).answer : '(no answer)') + '\\n';
}
</script>
</body>
</html>''';
}

/// The run observer that streams C6 SSE events.
final class _SseObserver implements RunObserver {
  _SseObserver({required this.onEvent});
  final void Function(String event, Map<String, dynamic> data) onEvent;

  @override
  void onDelta(String text) => onEvent('delta', {'text': text});

  @override
  void onReasoning(String text) {}

  @override
  void onStep(int step, int stalls, int stallBudget) {}

  @override
  void onContext(int usedTokens, int windowTokens) {}

  @override
  void onCompaction(int steps, int beforeTokens, int afterTokens) {}

  @override
  void onTool(String name, Map<String, dynamic> arguments) =>
      onEvent('tool', {'name': name, 'arguments': arguments});

  @override
  void onResponse(Duration elapsed) {}

  @override
  void onObservation(Outcome outcome, String text, {Duration? elapsed}) {}

  @override
  void onPhase(String phase) {}
}
