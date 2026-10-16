import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../channels.dart';
import '../clock.dart';
import '../errors.dart';
import '../log.dart';
import '../models.dart';
import '../notifier.dart';
import '../policy.dart';
import '../reliability.dart';
import '../safety.dart';
import '../scheduler.dart';
import 'tool.dart';

/// The origin a goal arrived from, so `send` and `schedule` can default
/// their channel to where the goal came from (C3, C11).
final class Origin {
  const Origin({this.channel, this.from, this.session});
  final String? channel;
  final String? from;
  final String? session;

  /// The default delivery target: the origin channel, else `notify`.
  String get defaultChannel => channel ?? 'notify';
}

/// The personal-domain tools (C3 `## Pilot`): the `http` connector, the
/// desktop `notify`, the outbound `send`, the `schedule` enrolment, and the
/// `secrets` name list — every one under the C10 policy path.
List<Tool> pilotTools({
  required NetworkPolicy network,
  required ConfirmPolicy confirm,
  required ConfirmSurface surface,
  required Secrets secrets,
  required DecisionLog decisions,
  required Notifier notifier,
  required TaskStore tasks,
  required Clock clock,
  required Map<String, Channel> channels,
  required Future<void> Function(String channelId, String to, String message,
          {String? task})
      deliverToChannel,
  required StructuredLog log,
  Origin origin = const Origin(),
}) =>
    [
      HttpTool(
          network: network,
          confirm: confirm,
          surface: surface,
          secrets: secrets,
          decisions: decisions),
      NotifyTool(notifier),
      SendTool(
        confirm: confirm,
        surface: surface,
        decisions: decisions,
        channels: channels,
        deliver: deliverToChannel,
        origin: origin,
      ),
      ScheduleTool(tasks: tasks, clock: clock, log: log, origin: origin),
      SecretsTool(secrets),
    ];

const _httpMethods = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'];

/// `http` — one HTTP request under the network policy (C3/C10). The request
/// is checked before any socket opens; `auth` names a secret injected as a
/// header at execution; the observation records the name, never the value;
/// and the response text is scrubbed and size-capped like web content.
final class HttpTool extends Tool {
  HttpTool({
    required this.network,
    required this.confirm,
    required this.surface,
    required this.secrets,
    required this.decisions,
    this.client,
  }) : super(WorkspaceGuard('.'));

  final NetworkPolicy network;
  final ConfirmPolicy confirm;
  final ConfirmSurface surface;
  final Secrets secrets;
  final DecisionLog decisions;
  final http.Client? client;

  /// Web-class timeout and the Prop web size cap (gate frozen constants).
  @override
  Duration get timeout => kWebTimeout;

  @override
  String get name => 'http';

  @override
  String get description =>
      'One HTTP request to a configured service. `auth.secret` names a '
      'configured secret injected as a header; its value is never shown. '
      'Mutating methods (POST/PUT/PATCH/DELETE) may require confirmation.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'method': {'type': 'string', 'enum': _httpMethods},
          'url': {'type': 'string'},
          'headers': {
            'type': 'object',
            'additionalProperties': {'type': 'string'},
          },
          'body': {'type': 'string'},
          'auth': {
            'type': 'object',
            'properties': {
              'secret': {'type': 'string'},
              'header': {'type': 'string'},
            },
            'required': ['secret'],
          },
        },
        'required': ['url'],
      };

  @override
  String? validate(Map<String, dynamic> arguments) {
    final url = arguments['url'];
    if (url is! String || url.isEmpty) {
      return 'argument url must be a non-empty string';
    }
    final method = arguments['method'];
    if (method != null &&
        (method is! String || !_httpMethods.contains(method))) {
      return 'argument method must be one of ${_httpMethods.join(", ")}';
    }
    final headers = arguments['headers'];
    if (headers != null && headers is! Map) {
      return 'argument headers must be an object of strings';
    }
    final auth = arguments['auth'];
    if (auth != null) {
      if (auth is! Map) return 'argument auth must be an object';
      if (auth['secret'] is! String) {
        return 'argument auth.secret must be a string';
      }
    }
    return null;
  }

  @override
  Future<ToolOutcome> execute(Map<String, dynamic> arguments) async {
    final method = (arguments['method'] as String?) ?? 'GET';
    final url = Uri.parse(arguments['url'] as String);

    // C10: the policy verdict precedes any socket opening.
    if (!network.allows(url, tool: 'http', decisions: decisions)) {
      return ToolOutcome.guardDenied(
          'http to ${url.host} is denied by network policy',
          guard: GuardArea.network);
    }

    // C10: mutating methods are confirm-matchable.
    if (!confirm.off && _isMutating(method)) {
      final matcher = confirm.matchFor('http', arguments);
      if (matcher != null) {
        final event = await confirm.evaluate(
          matcher,
          surface,
          tool: 'http',
          askInteractive: () async => false,
          askChannel: (_) async => false,
          decisions: decisions,
        );
        if (event == 'confirm_denied') {
          return ToolOutcome.guardDenied(
              'http $method to ${url.host} needs confirmation, which this '
              'surface cannot grant',
              guard: GuardArea.network);
        }
      }
    }

    // C10: resolve the named secret at execution; the value rides the
    // header, the name rides the observation.
    var headerName = 'authorization';
    String? headerValue;
    final auth = arguments['auth'] as Map?;
    if (auth != null) {
      final name = auth['secret'] as String;
      final value = secrets.resolve(name);
      if (value == null) {
        return ToolOutcome.error(
            'no secret named "$name" is configured (secrets_file)');
      }
      headerName = (auth['header'] as String?) ?? 'authorization';
      headerValue =
          headerName.toLowerCase() == 'authorization' ? 'Bearer $value' : value;
    }

    final request = http.Request(method, url)
      ..headers['accept'] = 'text/*, application/json';
    for (final entry in ((arguments['headers'] as Map?) ?? const {})
        .entries) {
      request.headers[entry.key as String] = entry.value as String;
    }
    if (headerValue != null) request.headers[headerName] = headerValue;
    final body = arguments['body'];
    if (body is String && body.isNotEmpty) request.body = body;

    final owned = client ?? http.Client();
    try {
      final response = await owned.send(request).timeout(timeout);
      final text = await response.stream
          .fold<StringBuffer>(
              StringBuffer(), (buffer, chunk) => buffer..write(utf8.decode(chunk,
                  allowMalformed: true)))
          .then((buffer) => buffer.toString())
          .timeout(timeout);
      final capped = text.length > kWebMaxBytes
          ? '${text.substring(0, kWebMaxBytes)}…[truncated]'
          : text;
      final note = 'HTTP ${response.statusCode}'
          '${auth != null ? ' (auth: ${auth['secret']})' : ''}\n\n'
          '${secrets.scrubObservation(capped)}';
      return ToolOutcome.ok(note);
    } on TimeoutException {
      return ToolOutcome.error('http request timed out');
    } on SocketException catch (e) {
      return ToolOutcome.error('http request failed: ${e.message}');
    } on Object catch (e) {
      return ToolOutcome.error('http request failed: $e');
    } finally {
      if (client == null) owned.close();
    }
  }

  static bool _isMutating(String method) =>
      const ['POST', 'PUT', 'PATCH', 'DELETE'].contains(method);
}

/// `notify` — a desktop notification through the host notifier (C3):
/// best-effort; failure is a recoverable observation, not a block.
final class NotifyTool extends Tool {
  NotifyTool(this.notifier) : super(WorkspaceGuard('.'));
  final Notifier notifier;

  @override
  String get name => 'notify';

  @override
  String get description =>
      'Show a desktop notification to the user (title optional). '
      'Best-effort: absence of a notifier is reported, not fatal.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'title': {'type': 'string'},
          'message': {'type': 'string'},
        },
        'required': ['message'],
      };

  @override
  String? validate(Map<String, dynamic> arguments) =>
      arguments['message'] is String
          ? null
          : 'argument message must be a string';

  @override
  Future<ToolOutcome> execute(Map<String, dynamic> arguments) async {
    final title = (arguments['title'] as String?) ?? 'Sudoer';
    final message = arguments['message'] as String;
    if (notifier.notify(title, message)) {
      return ToolOutcome.ok('notified: $title — $message');
    }
    return ToolOutcome.error('no desktop notifier is available');
  }
}

/// `send` — deliver a message to a registered channel (C3/C6), under policy:
/// the channel must exist in the registry, the call is confirm-matchable,
/// and delivery goes through the runtime's outbound path.
final class SendTool extends Tool {
  SendTool({
    required this.confirm,
    required this.surface,
    required this.decisions,
    required this.channels,
    required this.deliver,
    this.origin = const Origin(),
  }) : super(WorkspaceGuard('.'));

  final ConfirmPolicy confirm;
  final ConfirmSurface surface;
  final DecisionLog decisions;
  final Map<String, Channel> channels;
  final Future<void> Function(String channelId, String to, String message,
      {String? task}) deliver;
  final Origin origin;

  @override
  String get name => 'send';

  @override
  String get description =>
      'Send a message to a registered channel (e.g. a messenger adapter). '
      '`channel` defaults to the channel this goal came from. Sending on '
      'the user\'s behalf may require confirmation by policy.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'to': {'type': 'string'},
          'message': {'type': 'string'},
          'channel': {'type': 'string'},
        },
        'required': ['to', 'message'],
      };

  @override
  String? validate(Map<String, dynamic> arguments) {
    for (final key in const ['to', 'message']) {
      if (arguments[key] is! String) return 'argument $key must be a string';
    }
    return null;
  }

  @override
  Future<ToolOutcome> execute(Map<String, dynamic> arguments) async {
    // C10: policy decides before the registry lookup — a denied send never
    // becomes a judgment call about the channel.
    if (!confirm.off) {
      final matcher = confirm.matchFor('send', arguments);
      if (matcher != null) {
        final event = await confirm.evaluate(
          matcher,
          surface,
          tool: 'send',
          askInteractive: () async => false,
          askChannel: (_) async => false,
          decisions: decisions,
        );
        if (event == 'confirm_denied') {
          return ToolOutcome.guardDenied(
              'sending needs confirmation, which this surface cannot grant',
              guard: GuardArea.network);
        }
      }
    }
    final channelId = (arguments['channel'] as String?) ?? origin.defaultChannel;
    final channel = channels[channelId];
    if (channel == null) {
      return ToolOutcome.error(
          'no registered channel "$channelId" (channels: '
          '${channels.keys.isEmpty ? 'none' : channels.keys.join(', ')})');
    }
    await deliver(channelId, arguments['to'] as String,
        arguments['message'] as String);
    return ToolOutcome.ok('sent to $channelId/${arguments['to']}');
  }
}

/// `schedule` — enrol a user task in the scheduler (C11): one-shot or
/// recurring; the agent records, it never invents work.
final class ScheduleTool extends Tool {
  ScheduleTool({
    required this.tasks,
    required this.clock,
    required this.log,
    this.origin = const Origin(),
  }) : super(WorkspaceGuard('.'));

  final TaskStore tasks;
  final Clock clock;
  final StructuredLog log;
  final Origin origin;

  @override
  String get name => 'schedule';

  @override
  String get description =>
      'Enrol a task the user asked for: `when` is an ISO timestamp or a '
      'relative +<n><m|h|d>; `repeat` is +<n><m|h|d>, daily@HH:MM, or '
      'weekly@<mon..sun>@HH:MM; `channel` routes the result (default: this '
      'channel, or a desktop notification). Returns the task id.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'when': {'type': 'string'},
          'goal': {'type': 'string'},
          'repeat': {'type': 'string'},
          'channel': {'type': 'string'},
        },
        'required': ['when', 'goal'],
      };

  @override
  String? validate(Map<String, dynamic> arguments) {
    if (arguments['when'] is! String) return 'argument when must be a string';
    if (arguments['goal'] is! String) return 'argument goal must be a string';
    return null;
  }

  @override
  Future<ToolOutcome> execute(Map<String, dynamic> arguments) async {
    final when = arguments['when'] as String;
    final goal = arguments['goal'] as String;
    final repeat = arguments['repeat'] as String?;
    final now = clock.now();
    final due = resolveWhen(when, now);
    if (due == null) {
      return ToolOutcome.error(
          'cannot resolve `when` "$when" (use an ISO timestamp or +<n><m|h|d>)');
    }
    if (repeat != null && advanceRepeat(repeat, due) == null) {
      return ToolOutcome.error(
          'cannot resolve `repeat` "$repeat" (use +<n><m|h|d>, daily@HH:MM, '
          'or weekly@<mon..sun>@HH:MM)');
    }
    final all = tasks.load();
    final id = _nextId(all, slug(goal));
    final task = ScheduledTask(
      id: id,
      goal: goal,
      when: when,
      nextDue: due,
      repeat: repeat,
      channel: (arguments['channel'] as String?) ?? origin.defaultChannel,
      originChannel: origin.channel,
      originFrom: origin.from,
      originSession: origin.session,
      status: 'pending',
      created: now,
      updated: now,
    );
    all.add(task);
    tasks.save(all);
    log.emitTask(id, 'scheduled', due: due, repeat: repeat);
    return ToolOutcome.ok('scheduled "$goal" as $id, first due '
        '${due.toIso8601String()}${repeat == null ? '' : ', repeating $repeat'}');
  }

  static String slug(String goal) {
    final slug = goal
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'task' : slug.substring(0, slug.length.clamp(0, 32));
  }

  static String _nextId(List<ScheduledTask> tasks, String base) {
    if (!tasks.any((task) => task.id == base)) return base;
    var n = 2;
    while (tasks.any((task) => task.id == '$base-$n')) {
      n++;
    }
    return '$base-$n';
  }
}

/// `secrets` — list secret *names* only (C10): values are never returned.
final class SecretsTool extends Tool {
  SecretsTool(this.secrets) : super(WorkspaceGuard('.'));
  final Secrets secrets;

  @override
  String get name => 'secrets';

  @override
  String get description =>
      'List the names of the configured secrets (for http auth). Values are '
      'never shown.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'action': {'type': 'string', 'enum': ['list']},
        },
      };

  @override
  String? validate(Map<String, dynamic> arguments) {
    final action = arguments['action'];
    if (action != null && action != 'list') {
      return 'argument action must be "list"';
    }
    return null;
  }

  @override
  Future<ToolOutcome> execute(Map<String, dynamic> arguments) async {
    final names = secrets.names;
    return ToolOutcome.ok(names.isEmpty
        ? 'no secrets configured'
        : 'secrets: ${names.join(', ')}');
  }
}
